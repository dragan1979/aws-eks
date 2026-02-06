variable "region" {
  description = "AWS Region"
  type        = string
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
}

variable "public_subnets" {
  description = "List of public subnet CIDR blocks"
  type        = list(string)
}

variable "eks_instance_types" {
  description = "List of EC2 instance types for the EKS node group"
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_scaling_config" {
  description = "Scaling configuration for the EKS node group"
  type = object({
    desired_size = number
    max_size     = number
    min_size     = number
  })
  default = {
    desired_size = 1
    max_size     = 2
    min_size     = 1
  }
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "dev"
}

variable "console_user_arn" {
  description = "ARN of the IAM user for console access"
  type        = string
  default     = "arn:aws:iam::477568783935:user/eks-user"
}
