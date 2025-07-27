terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region  = var.aws_region
}

# Random ID for unique resource names
resource "random_id" "id" {
  byte_length = 8
}

# Get default VPC and subnets (no permissions needed to create VPC)
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

# Security Groups for containers
resource "aws_security_group" "edmp_container_sg" {
  name_prefix = "edmp-container-sg"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 5000
    to_port     = 5000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Docker Registry"
  }

  ingress {
    from_port   = 10001
    to_port     = 10001
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Grafana"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "edmp-container-sg"
    Environment = var.environment
  }
}

# Reference the existing key pair (created by deploy.sh)
data "aws_key_pair" "edmp_key" {
  key_name = var.key_pair_name
}

# Get the latest Amazon Linux 2 AMI
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]
  
  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
  
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# IAM Role for EC2 to allow SSM to manage it
resource "aws_iam_role" "edmp_ssm_role" {
  name = "edmp-ssm-role-${random_id.id.hex}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_policy_attachment" {
  role       = aws_iam_role.edmp_ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "edmp_instance_profile" {
  name = "edmp-instance-profile-${random_id.id.hex}"
  role = aws_iam_role.edmp_ssm_role.name
}

# Simple EC2 instance to run docker containers
resource "aws_instance" "edmp_server" {
  ami           = data.aws_ami.amazon_linux.id
  instance_type = var.instance_type
  
  vpc_security_group_ids = [aws_security_group.edmp_container_sg.id]
  subnet_id              = data.aws_subnets.default.ids[0]
  
  associate_public_ip_address = true
  key_name = data.aws_key_pair.edmp_key.key_name
  
  user_data = file("${path.module}/user-data-complete.sh")
  iam_instance_profile = aws_iam_instance_profile.edmp_instance_profile.name

  tags = {
    Name = "edmp-server"
    Environment = var.environment
  }
}

# RDS removed - using embedded H2 database
