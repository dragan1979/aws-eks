locals {
  common_tags = {
    Project     = "Infrastructure-Core"
    Environment = var.environment
    ManagedBy   = "Terraform"
    Owner       = "DevOps-Team"
    Cluster     = var.cluster_name
  }
}

# Get the OIDC thumbprint from the EKS cluster
data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

# Create the OIDC Provider in IAM
resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

# Trust Policy (Allows EKS to assume this role)
data "aws_iam_policy_document" "ebs_csi_assume_role" {
  statement {
    actions = ["sts:AssumeRole", "sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }

    principals {
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
      type        = "Federated"
    }
  }
}

# The IAM Role
resource "aws_iam_role" "ebs_csi_driver" {
  name               = "${var.cluster_name}-ebs-csi-driver-role"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume_role.json
  tags               = local.common_tags
}

# Attach the standard AmazonEBSCSIDriverPolicy
resource "aws_iam_role_policy_attachment" "ebs_csi_pa" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  role       = aws_iam_role.ebs_csi_driver.name
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = aws_eks_cluster.main.name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = aws_iam_role.ebs_csi_driver.arn
}

# Fetch all available AZs in the current region
data "aws_availability_zones" "available" {
  state = "available"
}

# --- VPC & Networking ---
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(local.common_tags, { Name = "${var.cluster_name}-vpc" })
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = merge(local.common_tags, { Name = "${var.cluster_name}-igw" })
}

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnets[count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name                                        = "${var.cluster_name}-public-${count.index}"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                    = "1"
  })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = merge(local.common_tags, { Name = "${var.cluster_name}-public-rt" })
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# --- IAM Roles for EKS ---
resource "aws_iam_role" "cluster" {
  name = "${var.cluster_name}-cluster-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
    }]
  })
  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.cluster.name
}

resource "aws_iam_role" "nodes" {
  name = "${var.cluster_name}-node-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "node_policies" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  ])
  policy_arn = each.value
  role       = aws_iam_role.nodes.name
}

# --- EKS Cluster ---
resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    subnet_ids              = aws_subnet.public[*].id
    endpoint_public_access  = true # Set to true if you want to run Terraform from your laptop
    endpoint_private_access = true # Always keep true so nodes can talk to the brain
  }

  access_config {
    authentication_mode = "API_AND_CONFIG_MAP"
    # bootstrap_cluster_creator_admin_permissions = false:                         
    # Cluster Creation: Terraform creates the EKS cluster. Because we set bootstrap... = false, AWS creates the cluster but does not automatically create any internal "hidden" admin permissions for the Jenkins role.
    # Resource Wait: Terraform moves to your aws_eks_access_entry.terraform_user block.
    # Clean Creation: Terraform sends a request to EKS: "Create an access entry for the Jenkins Role." Since AWS didn't create one automatically, there is no conflict (no 409 error).
    # Policy Attachment: Terraform then creates the aws_eks_access_policy_association.
    bootstrap_cluster_creator_admin_permissions = false
    # bootstrap_cluster_creator_admin_permissions = true:
    # We have a "Race Condition":
    # AWS tries to create an entry automatically the moment the cluster is ready.
    # Terraform tries to create the same entry based on our code.
    # If AWS wins the race, Terraform hits the 409 ResourceInUse error.
    # By setting it to false, we tell AWS to "stand down," which allows Terraform to be the only one managing the resource.
  }

  depends_on = [aws_iam_role_policy_attachment.cluster_policy]
  tags       = local.common_tags
}

# --- Node Group ---
resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "standard-nodes"
  node_role_arn   = aws_iam_role.nodes.arn
  subnet_ids      = aws_subnet.public[*].id

  scaling_config {
    desired_size = var.node_scaling_config.desired_size
    max_size     = var.node_scaling_config.max_size
    min_size     = var.node_scaling_config.min_size
  }

  instance_types = var.eks_instance_types
  depends_on     = [aws_iam_role_policy_attachment.node_policies]
  tags           = local.common_tags
}


data "aws_iam_role" "jenkins_role" {
  name = "Jenkins-RolesAnywhere-Role"
}


resource "aws_eks_access_entry" "terraform_user" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = data.aws_iam_role.jenkins_role.arn
  type          = "STANDARD"
  depends_on    = [aws_eks_cluster.main]
}

resource "aws_eks_access_policy_association" "admin_policy" {
  cluster_name  = aws_eks_cluster.main.name
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  principal_arn = data.aws_iam_role.jenkins_role.arn

  access_scope {
    type = "cluster"
  }
}

# If needed, we can add more users to the cluster and assign them to Cluster admin policy.

# resource "aws_eks_access_entry" "manual_user" {
#   cluster_name  = aws_eks_cluster.main.name
#   principal_arn = "arn:aws:iam::477568783935:user/eks-user"
#   type          = "STANDARD"
# }

# resource "aws_eks_access_policy_association" "manual_user_admin" {
#   cluster_name  = aws_eks_cluster.main.name
#   policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
#   principal_arn = "arn:aws:iam::477568783935:user/eks-user"

#   access_scope {
#     type = "cluster"
#   }
# }




# Install the Pod Identity Add-on
# We need to add the EKS Add-on to Terraform configuration

resource "aws_eks_addon" "pod_identity_agent" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "eks-pod-identity-agent"
  depends_on   = [aws_eks_cluster.main]
}



resource "null_resource" "apply_storage_class" {
  depends_on = [
    aws_eks_addon.ebs_csi,
    aws_eks_access_policy_association.admin_policy # Ensure Jenkins has permission before running kubectl
  ]

  # triggers = {
  #   always_run = timestamp()
  # }

  provisioner "local-exec" {
    # Switch to the Linux bash interpreter
    interpreter = ["/bin/bash", "-c"]

    command = <<EOT
      # Update kubeconfig context
      aws eks update-kubeconfig --region ${var.region} --name ${var.cluster_name}
      
      # Apply the gp3 StorageClass via heredoc
      cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
allowVolumeExpansion: true
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
parameters:
  type: gp3
  fsType: ext4
EOF

      
      kubectl patch storageclass gp2 -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
EOT
  }
}