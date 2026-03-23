variable "aws_region" {
  description = "AWS region to deploy to."
  type        = string
  default     = "us-east-1"
}

variable "availability_zone" {
  description = "Optional AZ override (example: us-east-1a)."
  type        = string
  default     = "us-east-1a"
}

variable "vpc_cidr" {
  description = "VPC CIDR block."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "Public subnet CIDR block."
  type        = string
  default     = "10.0.1.0/24"
}

variable "ami_id" {
  description = "Optional AMI override. Leave empty to auto-select Ubuntu 22.04."
  type        = string
  default     = ""
}

variable "instance_type" {
  description = "EC2 instance type."
  type        = string
  default     = "t3.micro"
}

variable "key_name" {
  description = "Existing AWS EC2 key pair name used for SSH."
  type        = string
}

variable "admin_cidr" {
  description = "Your personal public IP in /32 CIDR format for SSH (example: 203.0.113.10/32)."
  type        = string

  validation {
    condition     = can(cidrhost(var.admin_cidr, 0)) && split("/", var.admin_cidr)[1] == "32"
    error_message = "admin_cidr must be a valid single-host CIDR like 203.0.113.10/32."
  }
}

variable "instance_name" {
  description = "Name prefix for AWS resources."
  type        = string
  default     = "zwanga-api"
}

variable "domain_name" {
  description = "Optional domain name used by Caddy (for outputs and deployment)."
  type        = string
  default     = ""
}

variable "caddy_email" {
  description = "Optional email address used by Caddy for ACME/Let's Encrypt."
  type        = string
  default     = ""
}

variable "app_image_repository" {
  description = "Docker Hub repository for the NestJS image deployed by Ansible."
  type        = string
  default     = ""
}

variable "app_image_tag" {
  description = "Docker image tag deployed by Ansible."
  type        = string
  default     = "latest"
}

variable "log_retention_days" {
  description = "CloudWatch log retention period in days."
  type        = number
  default     = 14
}

variable "ssm_secure_parameters" {
  description = "Map of SecureString parameters to create in SSM (name => value)."
  type        = map(string)
  sensitive   = true
  default     = {}
}