output "vpc_id" {
  description = "Created VPC ID."
  value       = aws_vpc.main.id
}

output "public_subnet_id" {
  description = "Primary public subnet ID."
  value       = aws_subnet.public.id
}

output "secondary_public_subnet_id" {
  description = "Secondary public subnet ID."
  value       = try(aws_subnet.public_secondary[0].id, "")
}

output "public_subnet_ids" {
  description = "Public subnet IDs keyed by role."
  value = merge(
    {
      primary = aws_subnet.public.id
    },
    var.secondary_instance_enabled ? {
      secondary = aws_subnet.public_secondary[0].id
    } : {}
  )
}

output "security_group_id" {
  description = "Security group ID."
  value       = aws_security_group.web.id
}

output "instance_id" {
  description = "Primary EC2 instance ID."
  value       = aws_instance.zwanga_api.id
}

output "secondary_instance_id" {
  description = "Secondary EC2 instance ID."
  value       = try(aws_instance.zwanga_api_secondary[0].id, "")
}

output "instance_ids" {
  description = "EC2 instance IDs keyed by role."
  value       = { for role, instance in local.monitored_instances : role => instance.id }
}

output "elastic_ip" {
  description = "Primary Elastic IP attached to EC2."
  value       = aws_eip.app.public_ip
}

output "secondary_elastic_ip" {
  description = "Secondary Elastic IP attached to the failover EC2 node."
  value       = try(aws_eip.app_secondary[0].public_ip, "")
}

output "elastic_ips" {
  description = "Elastic IPs keyed by role."
  value       = { for role, instance in local.monitored_instances : role => instance.public_ip }
}

output "ssh_command" {
  description = "SSH command to connect to the primary EC2 instance."
  value       = "ssh ubuntu@${aws_eip.app.public_ip}"
}

output "secondary_ssh_command" {
  description = "SSH command to connect to the secondary EC2 instance."
  value       = var.secondary_instance_enabled ? "ssh ubuntu@${aws_eip.app_secondary[0].public_ip}" : ""
}

output "ssh_commands" {
  description = "SSH commands keyed by role."
  value = merge(
    {
      primary = "ssh ubuntu@${aws_eip.app.public_ip}"
    },
    var.secondary_instance_enabled ? {
      secondary = "ssh ubuntu@${aws_eip.app_secondary[0].public_ip}"
    } : {}
  )
}

output "external_dns_failover_targets" {
  description = "Public IPs to use as primary/secondary targets in an external DNS provider."
  value = merge(
    {
      primary = aws_eip.app.public_ip
    },
    var.secondary_instance_enabled ? {
      secondary = aws_eip.app_secondary[0].public_ip
    } : {}
  )
}

output "app_url" {
  description = "Public application URL. Uses the custom domain when configured, otherwise the primary Elastic IP."
  value       = var.domain_name != "" ? "https://${var.domain_name}" : "http://${aws_eip.app.public_ip}"
}

output "health_url" {
  description = "Documented public health URL. Keep app_healthcheck_path aligned with your API if you expose one publicly."
  value       = var.domain_name != "" ? "https://${var.domain_name}${var.app_healthcheck_path}" : "http://${aws_eip.app.public_ip}${var.app_healthcheck_path}"
}

output "cloudwatch_log_group_app" {
  description = "CloudWatch log group for app logs."
  value       = aws_cloudwatch_log_group.app.name
}

output "cloudwatch_log_group_caddy" {
  description = "CloudWatch log group for Caddy logs."
  value       = aws_cloudwatch_log_group.caddy.name
}

output "ops_alerts_topic_arn" {
  description = "SNS topic ARN used for infra alerts when email endpoints are configured."
  value       = length(var.alarm_email_endpoints) > 0 ? aws_sns_topic.ops[0].arn : ""
}

output "deploy_admin_cidr" {
  description = "Admin CIDR passed to Ansible."
  value       = var.admin_cidr
}

output "deploy_app_image_repository" {
  description = "Docker Hub image repository used by Ansible."
  value       = var.app_image_repository
}

output "deploy_app_image_tag" {
  description = "Docker image tag used by Ansible."
  value       = var.app_image_tag
}

output "deploy_caddy_email" {
  description = "Caddy email used by Ansible."
  value       = var.caddy_email
}

output "deploy_domain_name" {
  description = "Domain name passed to Ansible."
  value       = var.domain_name
}

output "deploy_instance_name" {
  description = "Logical instance name used for the deployment."
  value       = var.instance_name
}

output "deploy_region" {
  description = "AWS region used for the deployment."
  value       = var.aws_region
}

output "deploy_primary_public_ip" {
  description = "Primary public IP used by deploy.sh to build the Ansible inventory."
  value       = aws_eip.app.public_ip
}

output "deploy_secondary_public_ip" {
  description = "Secondary public IP used by deploy.sh when the failover node is enabled."
  value       = try(aws_eip.app_secondary[0].public_ip, "")
}

output "deploy_secondary_enabled" {
  description = "Whether the low-cost failover node is enabled."
  value       = var.secondary_instance_enabled
}

output "ssm_parameter_names" {
  description = "Created SSM parameter names."
  value       = [for p in aws_ssm_parameter.secure_params : p.name]
  sensitive   = true
}
