variable "aws_region" {
  description = "AWS region for resources"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "dev"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "edmp-cluster"
}

variable "kubernetes_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.28"
}

variable "instance_type" {
  description = "EC2 instance type for the server"
  type        = string
  default     = "t3.medium"
}

variable "db_username" {
  description = "Database username"
  type        = string
  default     = "sonar"
}

variable "db_password" {
  description = "Database password"
  type        = string
  sensitive   = true
  default     = "sonar123!"
}

variable "key_pair_name" {
  description = "Name of the AWS key pair to use"
  type        = string
  default     = "edmp-key"
}