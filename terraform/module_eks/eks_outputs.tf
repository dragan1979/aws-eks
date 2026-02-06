output "cluster_certificate_authority_data" {
  # This maps to the data attribute you were trying to call
  value = aws_eks_cluster.main.certificate_authority[0].data
}
output "cluster_endpoint" {
  value = aws_eks_cluster.main.endpoint
}
output "cluster_name" {
  value = aws_eks_cluster.main.name
}

output "cluster_arn" {
  value = aws_eks_cluster.main.arn
}
