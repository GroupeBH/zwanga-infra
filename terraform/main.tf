terraform {
  required_version = ">= 1.5.0"

  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "ubuntu_jammy" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  selected_az = var.availability_zone != "" ? var.availability_zone : data.aws_availability_zones.available.names[0]
  ami_id      = var.ami_id != "" ? var.ami_id : data.aws_ami.ubuntu_jammy.id
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.instance_name}-vpc"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.instance_name}-igw"
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  map_public_ip_on_launch = true
  availability_zone       = local.selected_az

  tags = {
    Name = "${var.instance_name}-public-subnet"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "${var.instance_name}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "web" {
  name        = "${var.instance_name}-sg"
  description = "Allow SSH from personal IP and HTTP/HTTPS from internet"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH from personal IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.instance_name}-sg"
  }
}

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2_ssm_cw" {
  name               = "${var.instance_name}-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2_ssm_cw.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.ec2_ssm_cw.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.instance_name}-instance-profile"
  role = aws_iam_role.ec2_ssm_cw.name
}

resource "aws_instance" "zwanga_api" {
  ami                         = local.ami_id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  key_name                    = var.key_name
  vpc_security_group_ids      = [aws_security_group.web.id]
  iam_instance_profile        = aws_iam_instance_profile.ec2.name
  associate_public_ip_address = true

  user_data = <<-EOF
              #!/bin/bash
              set -eux
              apt-get update -y
              apt-get install -y python3 python3-apt
              EOF

  tags = {
    Name = var.instance_name
  }
}

resource "aws_eip" "app" {
  domain   = "vpc"
  instance = aws_instance.zwanga_api.id

  tags = {
    Name = "${var.instance_name}-eip"
  }
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/${var.instance_name}/app"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "caddy" {
  name              = "/${var.instance_name}/caddy"
  retention_in_days = var.log_retention_days
}

locals {
  # Terraform cannot iterate directly over a sensitive map, so we only expose
  # the parameter names to for_each and keep the values sensitive.
  ssm_secure_parameter_names = nonsensitive(toset(keys(var.ssm_secure_parameters)))
}

resource "aws_ssm_parameter" "secure_params" {
  for_each = local.ssm_secure_parameter_names

  name      = "/${var.instance_name}/${each.value}"
  type      = "SecureString"
  value     = var.ssm_secure_parameters[each.value]
  overwrite = true
  tier      = "Standard"

  tags = {
    Name = "${var.instance_name}-${each.value}"
  }
}

