# Manual Failover Runbook

This runbook assumes:

- the infrastructure in this repository is deployed
- `secondary_instance_enabled = true`
- your DNS is hosted outside AWS
- your public hostname normally points to the primary Elastic IP

## 1. Keep These Values Handy

Collect them from Terraform outputs after each deployment:

- primary public IP
- secondary public IP
- primary SSH command
- secondary SSH command
- domain name in use
- documented public health URL if your app exposes one

Useful commands:

```bash
terraform -chdir=terraform output -raw deploy_primary_public_ip
terraform -chdir=terraform output -raw deploy_secondary_public_ip
terraform -chdir=terraform output -raw ssh_command
terraform -chdir=terraform output -raw secondary_ssh_command
```

## 2. Normal-Day Checklist

Do this before any incident happens:

- keep DNS TTL low, typically `60` or `120` seconds
- deploy the same image tag to both nodes
- deploy the same `.env` content to both nodes
- confirm both nodes can start the stack cleanly
- confirm the active node's Caddy can still reach the peer app over private port `3000`
- confirm CloudWatch logs arrive for `primary` and `secondary`
- if you configured `alarm_email_endpoints`, confirm the subscription emails were accepted

## 3. Verify The Secondary Node Before You Need It

Check the standby node regularly.

SSH:

```bash
ssh -i ~/.ssh/zwanga.pem ubuntu@<secondary-ip>
```

Containers:

```bash
cd /opt/nestjs-caddy
sudo docker compose ps
sudo docker compose logs app --tail=100
sudo docker compose logs caddy --tail=100
```

Direct HTTP probe by IP:

```bash
curl -i http://<secondary-ip>
```

If you need to simulate the application hostname over plain HTTP:

```bash
curl -i -H 'Host: api.example.com' http://<secondary-ip>
```

For HTTPS, remember the main caveat of this architecture:

- the passive node may not have the public certificate yet if DNS has never pointed to it

## 4. When To Fail Over

Fail over when the primary node is no longer a safe serving target.
Typical triggers:

- EC2 instance unreachable
- repeated Caddy or host-level failure on the current public node
- persistent system status check failures
- networking issue isolated to the current public node
- manual maintenance window where the current public node must be taken out of service

If only the primary app container is unhealthy but the primary node and Caddy are still up, Caddy may continue serving traffic through the secondary app over the private upstream mesh. Validate that path before forcing DNS failover.

## 5. Failover Procedure

### Step 1: Confirm the primary is unhealthy

Check:

- CloudWatch alarms
- application availability from the internet
- SSH reachability
- `docker compose ps` and `docker compose logs` if SSH still works

### Step 2: Confirm the secondary is healthy enough to receive traffic

Check on the secondary:

```bash
ssh -i ~/.ssh/zwanga.pem ubuntu@<secondary-ip> \
'cd /opt/nestjs-caddy && sudo docker compose ps && sudo docker compose logs app --tail=50'
```

You want to see:

- `nestjs-app` running
- `caddy` running
- no obvious startup errors in app logs
- no upstream connectivity errors in Caddy logs

### Step 3: Update the external DNS record

At your DNS provider:

- change `api.example.com` from the primary Elastic IP to the secondary Elastic IP
- keep TTL low
- note the exact change time

### Step 4: Watch propagation and application behavior

From your workstation:

```bash
dig +short api.example.com
curl -i http://api.example.com
```

If HTTPS is configured, also watch Caddy logs on the secondary:

```bash
ssh -i ~/.ssh/zwanga.pem ubuntu@<secondary-ip> \
'cd /opt/nestjs-caddy && sudo docker compose logs caddy --tail=100 -f'
```

This is where you will see certificate issuance/retry behavior after the DNS cutover.

### Step 5: Announce failover complete

Mark the incident with:

- time of cutover
- reason for failover
- current serving node
- any TLS caveat still in progress

## 6. If HTTPS Does Not Recover Immediately On The Secondary

This is the main operational edge case of this design.

Actions:

- confirm DNS really points to the secondary IP
- wait for TTL expiration and DNS propagation
- watch `caddy` logs on the secondary for ACME retries
- keep serving over HTTP only if your clients and risk model allow it temporarily
- if seamless HTTPS is a hard requirement, treat this as a signal to move to an ALB-based design

## 7. Failback Procedure

When the primary has been repaired:

1. redeploy both nodes so they are on the same image tag and config
2. verify the primary is healthy again
3. move DNS back to the primary Elastic IP
4. monitor logs, application behavior, and certificate handling
5. close the incident only after traffic is stable again

## 8. Useful Debug Commands

Primary app logs:

```bash
ssh -i ~/.ssh/zwanga.pem ubuntu@<primary-ip> \
'cd /opt/nestjs-caddy && sudo docker compose logs app --tail=100'
```

Secondary app logs:

```bash
ssh -i ~/.ssh/zwanga.pem ubuntu@<secondary-ip> \
'cd /opt/nestjs-caddy && sudo docker compose logs app --tail=100'
```

Primary Caddy logs:

```bash
ssh -i ~/.ssh/zwanga.pem ubuntu@<primary-ip> \
'cd /opt/nestjs-caddy && sudo docker compose logs caddy --tail=100'
```

Secondary Caddy logs:

```bash
ssh -i ~/.ssh/zwanga.pem ubuntu@<secondary-ip> \
'cd /opt/nestjs-caddy && sudo docker compose logs caddy --tail=100'
```

CloudWatch log groups:

- `/${instance_name}/app`
- `/${instance_name}/caddy`

Expected stream names:

- `app-primary`
- `app-secondary`
- `caddy-primary`
- `caddy-secondary`

## 9. Post-Incident Review Questions

After each failover, review:

- Was the DNS TTL low enough?
- How long did client cutover actually take?
- Did the standby node have any configuration drift?
- Did HTTPS on the secondary recover cleanly?
- Did alerting notify the right people?
- Is the low-cost model still acceptable, or is it time to move to ALB?
