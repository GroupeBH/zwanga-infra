# Low-Cost Failover Architecture

This document explains the low-cost active-passive edge architecture implemented in this repository.
It is designed for teams that want materially better resilience than a single EC2 node without immediately paying for an ALB, NAT gateways, or a full private-subnet/multi-AZ production stack.

## Goal

The goal is to reduce the biggest single point of failure at the lowest possible AWS cost increase.

Instead of this:

```text
Internet -> EC2 -> Caddy -> Nest.js
```

we now provision this:

```text
Internet
  -> External DNS provider
     -> Active Elastic IP (primary or secondary)
        -> Caddy on the active node
           -> local Nest.js image
           -> peer Nest.js image over private IP
```

This is still not the same thing as a fully managed high-availability setup with an ALB.
It is intentionally a simpler and cheaper compromise.

## What Terraform Creates

Primary resources already existed and remain the canonical production path.
The failover expansion adds a second node without replacing the original one.

Core resources:

- VPC
- internet gateway
- route table for internet-bound traffic
- primary public subnet
- secondary public subnet in another AZ when available
- shared security group
- primary EC2 instance
- secondary EC2 instance when `secondary_instance_enabled = true`
- primary Elastic IP
- secondary Elastic IP
- EC2 IAM role with SSM and CloudWatch permissions
- CloudWatch log groups for `app` and `caddy`
- CloudWatch alarms for EC2 status checks
- optional SNS topic and email subscriptions for alerts
- optional SSM SecureString parameters

## Active-Passive Traffic Model

In normal operation:

- your external DNS provider points the public hostname at the primary Elastic IP
- the primary node handles public ingress
- Caddy on the active node round-robins requests across the local app container and the peer app container over private port `3000`
- the secondary node is warm and ready for failover at the edge layer
- the same Docker image and `.env` are deployed to both nodes

During failover:

- traffic is moved to the secondary Elastic IP manually or via your DNS provider's failover feature
- Caddy and the Nest.js app continue serving from the standby node

## Why This Is Cheaper Than ALB-Based HA

This design avoids:

- ALB hourly charges
- ALB LCU charges
- NAT Gateway charges
- private subnet complexity
- Auto Scaling Group complexity

The tradeoff is that failover is not as seamless and certificate management is more operationally sensitive.

## Key Tradeoffs

### What You Gain

- a second EC2 node in another AZ
- a second Elastic IP ready for DNS cutover
- independent app runtime on each node
- CloudWatch alarms and EC2 recovery for system-level failures
- a deployment model that updates both hosts serially

### What You Do Not Get

- managed load balancing
- AWS-native health-based traffic steering
- guaranteed ingress continuity if the current public edge node itself fails
- instant or transparent failover
- fully seamless TLS behavior under all failover scenarios

## External DNS Setup

Because your DNS is hosted outside AWS, you have three practical modes.

### Mode 1: Manual Failover

This is the cheapest and simplest.

- create `api.example.com`
- point it at the primary Elastic IP
- keep the secondary Elastic IP documented
- set a low TTL, for example `60` or `120` seconds
- when the primary fails, update the A record to the secondary IP

### Mode 2: DNS Active-Active Edge Distribution

If your DNS provider supports weighted or multi-value answers and you are comfortable with both nodes receiving public traffic:

- publish both Elastic IPs for the same hostname
- keep TTL low and pair it with provider-side health checks when possible
- remember that each Caddy node still forwards to both app instances over the private mesh

### Mode 3: Provider-Managed Failover

If your DNS provider supports health checks and primary/secondary routing:

- set the primary Elastic IP as the active target
- set the secondary Elastic IP as the standby target
- configure the provider's health checks according to what your API can expose publicly
- keep TTL low enough for reasonable cutover behavior

Terraform outputs to use:

- `deploy_primary_public_ip`
- `deploy_secondary_public_ip`
- `external_dns_failover_targets`

## HTTPS Behavior With Caddy

This is the most important caveat of the low-cost design.

Caddy can automatically obtain and renew public certificates when:

- a real domain is configured
- the domain resolves to the node handling ACME validation traffic

That means:

- the primary node usually obtains the certificate first, because DNS points at it
- the secondary node may not be able to pre-provision the exact same public certificate while it is passive if ACME traffic never reaches it
- after DNS switches to the secondary node, Caddy can retry certificate issuance there

Operational consequence:

- low-cost failover may involve a short TLS stabilization window after DNS cutover
- if you need seamless failover with public HTTPS, use an ALB-based design or a certificate distribution strategy that does not depend on a single active node during validation

## Terraform Variables To Know

These variables matter most for the failover architecture:

- `secondary_instance_enabled`
  - enables the secondary node; defaults to `true`
- `secondary_availability_zone`
  - optional explicit AZ for the secondary node
- `secondary_public_subnet_cidr`
  - CIDR block for the failover subnet
- `domain_name`
  - enables Caddy's public-domain behavior
- `caddy_email`
  - ACME contact email
- `app_healthcheck_path`
  - purely informational for outputs/docs in the current implementation
- `alarm_email_endpoints`
  - optional email recipients for EC2 status alarms

## Deployment Flow

`deploy.sh` now does the following:

1. runs Terraform
2. reads the primary and secondary public IP outputs
3. generates an Ansible inventory with `primary`, `secondary`, and their private IPs
4. waits for SSH on each target
5. runs the Ansible playbook serially across the two nodes
6. deploys the same Docker Hub image and optional app env file to both hosts

Because the playbook runs serially, one host is fully updated before moving to the next one.
This keeps rollouts easier to reason about during incidents.

## Observability

Logs:

- `/${instance_name}/app`
- `/${instance_name}/caddy`

Per-node log streams:

- `app-primary`
- `app-secondary`
- `caddy-primary`
- `caddy-secondary`

Alarms:

- `StatusCheckFailed_System` per node
- `StatusCheckFailed_Instance` per node
- optional SNS email alerts

The system status check alarm also triggers EC2 automatic recovery.

## When To Upgrade To ALB

Move to an ALB-centric design when any of these become important:

- seamless HTTPS failover
- true active-active load balancing
- automatic removal of unhealthy nodes from the serving path
- easier certificate handling across multiple instances
- cleaner future scaling with Auto Scaling Groups

Until then, this repository's active-passive design is a practical middle ground.
