# ============================================================================
# Local Variables
# ============================================================================

locals {
  cluster_name = var.cluster_name
  common_tags = {
    Project     = "Infrastructure-Core"
    Environment = var.environment
    ManagedBy   = "Terraform"
    Owner       = "DevOps-Team"
    Cluster     = var.cluster_name
  }
}


variable "region" {
  default = "eu-central-1"
}

variable "environment" {
  default = "dev"
}

variable "eks_instance_types" {
  default = ["t3.medium"]
}


variable "cluster_name" {
  default = "my-aks-cluster"
}

variable "namespace" {
  default = "default"
}

variable "db_name" {
  default = "my-db"
}

# ============================================================================
# Step 1: Deploy EKS Cluster (No dependencies)
# ============================================================================

module "eks" {
  source = "./module_eks"

  region         = var.region
  cluster_name   = var.cluster_name
  vpc_cidr       = "10.0.0.0/16"
  public_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  node_scaling_config = {
    desired_size = 1
    max_size     = 1
    min_size     = 1
  }
  environment        = var.environment
  eks_instance_types = var.eks_instance_types
}

# ============================================================================
# Helm and Kubectl Providers (Depend on EKS)
# ============================================================================

# provider "helm" {
#   kubernetes = {
#     host                   = module.eks.cluster_endpoint
#     cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

#     exec = {
#       api_version = "client.authentication.k8s.io/v1beta1"
#       args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
#       command     = "aws"
#     }
#   }
# }

# provider "kubectl" {
#   host                   = module.eks.cluster_endpoint
#   cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
#   load_config_file       = false

#   exec = {
#     api_version = "client.authentication.k8s.io/v1beta1"
#     args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
#     command     = "aws"
#   }
# }

# ============================================================================
# Step 2: Deploy Platform Services (External Secrets) - Depends on EKS
# ============================================================================

module "addons" {
  source = "./module_addons"

  region       = var.region
  cluster_name = module.eks.cluster_name

  # Explicit dependency on EKS cluster
  depends_on = [module.eks]
}

# ============================================================================
# Step 3: MongoDB Password and SSM Parameter - Independent
# ============================================================================

resource "random_password" "mongodb_root_password" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_ssm_parameter" "mongodb_password" {
  name        = "/${var.cluster_name}/mongodb/root-password"
  description = "MongoDB root password for ${var.cluster_name}"
  type        = "SecureString"
  value       = random_password.mongodb_root_password.result

  tags = merge(local.common_tags, { Component = "MongoDB" })
}

# ============================================================================
# Step 4: Deploy MongoDB - Depends on EKS and Addons
# ============================================================================

resource "helm_release" "mongodb" {
  name             = "mongodb"
  repository       = "https://charts.bitnami.com/bitnami"
  chart            = "mongodb"
  namespace        = var.namespace
  create_namespace = true
  wait             = true

  set_sensitive = [
    {
      name  = "auth.rootPassword"
      value = random_password.mongodb_root_password.result
    }
  ]

  set = [
    {
      name  = "auth.databases[0]"
      value = var.db_name
    },
    {
      name  = "auth.usernames[0]"
      value = "admin"
    },
    {
      name  = "persistence.size"
      value = "8Gi"
    },
    {
      name  = "architecture"
      value = "standalone"
    }
  ]
  # Explicit dependencies
  depends_on = [
    module.eks,
    module.addons
  ]
}



