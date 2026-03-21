output "vpc_id" {
  description = "Created VPC ID."
  value       = aws_vpc.main.id
}

output "public_subnet_id" {
  description = "Created public subnet ID."
  value       = aws_subnet.public.id
}

output "security_group_id" {
  description = "Security group ID."
  value       = aws_security_group.web.id
}

output "instance_id" {
  description = "EC2 instance ID."
  value       = aws_instance.zwanga_api.id
}

output "elastic_ip" {
  description = "Elastic IP attached to EC2."
  value       = aws_eip.app.public_ip
}

output "ssh_command" {
  description = "SSH command to connect to the EC2 instance."
  value       = "ssh ubuntu@${aws_eip.app.public_ip}"
}

output "app_url" {
  description = "Public application URL."
  value       = var.domain_name != "" ? "https://${var.domain_name}" : "http://${aws_eip.app.public_ip}"
}

output "health_url" {
  description = "Public health URL."
  value       = var.domain_name != "" ? "https://${var.domain_name}/health" : "http://${aws_eip.app.public_ip}/health"
}

output "cloudwatch_log_group_app" {
  description = "CloudWatch log group for app logs."
  value       = aws_cloudwatch_log_group.app.name
}

output "cloudwatch_log_group_caddy" {
  description = "CloudWatch log group for Caddy logs."
  value       = aws_cloudwatch_log_group.caddy.name
}

output "deploy_admin_cidr" {
  description = "Admin CIDR passed to Ansible."
  value       = var.admin_cidr
}

output "deploy_backend_repo" {
  description = "Backend Git repository URL used by Ansible."
  value       = var.backend_repo
}

output "deploy_backend_ref" {
  description = "Backend Git ref used by Ansible."
  value       = var.backend_ref
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

output "ssm_parameter_names" {
  description = "Created SSM parameter names."
  value       = [for p in aws_ssm_parameter.secure_params : p.name]
  sensitive   = true
}

