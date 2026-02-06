# ============================================================================
# External Secrets Operator (ESO) IAM Role
# ============================================================================

data "aws_caller_identity" "current" {}

# ESO IAM Role using Pod Identity
resource "aws_iam_role" "eso_role" {
  name = "${var.cluster_name}-eso-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })

  tags = {
    Project   = "Infrastructure-Core"
    Component = "Secret-Management"
    Cluster   = var.cluster_name
  }
}

# IAM policy for ESO to read from AWS Secrets Manager and SSM Parameter Store
# Using wildcard for SSM parameters - can be tightened later
resource "aws_iam_policy" "eso_secrets_policy" {
  name        = "${var.cluster_name}-eso-secrets-policy"
  description = "Allows ESO to read secrets from AWS Secrets Manager and SSM Parameter Store"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
          "secretsmanager:ListSecretVersionIds"
        ]
        Resource = "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:*"
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath"
        ]
        Resource = "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/*"
      }
    ]
  })
}

# Attach the policy to the role
resource "aws_iam_role_policy_attachment" "eso_attach" {
  role       = aws_iam_role.eso_role.name
  policy_arn = aws_iam_policy.eso_secrets_policy.arn
}

# EKS Pod Identity Association
# This tells AWS: "Pods in external-secrets namespace using external-secrets SA get this IAM role"
resource "aws_eks_pod_identity_association" "eso_association" {
  cluster_name    = var.cluster_name
  namespace       = "external-secrets"
  service_account = "external-secrets"
  role_arn        = aws_iam_role.eso_role.arn
}

# ============================================================================
# Deploy External Secrets Operator via Helm
# ============================================================================

resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  namespace        = "external-secrets"
  create_namespace = true
  version          = "0.9.11"

  values = [
    yamlencode({
      installCRDs = true
      serviceAccount = {
        create = true
        name   = "external-secrets"
      }
    })
  ]

  # Ensure Pod Identity association exists before deploying
  depends_on = [aws_eks_pod_identity_association.eso_association]
}

# ============================================================================
# ClusterSecretStore for AWS Parameter Store
# ============================================================================

resource "null_resource" "apply_manifest" {
  depends_on = [helm_release.external_secrets]

  # triggers = {
  #   always_run = timestamp()
  # }

  provisioner "local-exec" {
    # Specify the bash interpreter
    interpreter = ["/bin/bash", "-c"]

    command = <<EOT
      # Update kubeconfig
      aws eks update-kubeconfig --region ${var.region} --name ${var.cluster_name}
      
      # Apply the manifest using a 'here-document' to pipe directly to kubectl
      cat <<EOF | kubectl apply -f -
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: aws-parameter-store
spec:
  provider:
    aws:
      service: ParameterStore
      region: ${var.region}
EOF
EOT
  }
}

