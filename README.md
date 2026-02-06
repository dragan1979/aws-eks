# AWS EKS Infrastructure-as-Code Pipeline

This repository contains a  **GitOps pipeline** and **Terraform** configuration to deploy a fully functional Amazon EKS (Elastic Kubernetes Service) cluster. It includes integrated security scanning, automated PR feedback, and an approval-based deployment workflow.



## Architecture Overview
The infrastructure is modularized for scalability and follows AWS best practices:
* **Networking:** Custom VPC with public subnets, Internet Gateway, and optimized Route Tables.
* **EKS Cluster:** Managed Kubernetes control plane with **API and ConfigMap** authentication mode.
* **Node Group:** Managed EC2 node group using `t3.medium` instances.
* **Storage:** Automated deployment of the **EBS CSI Driver** and configuration of a default `gp3` StorageClass.
* **Add-ons:** Includes **External Secrets Operator (ESO)** with Pod Identity for secure AWS SSM Parameter Store integration.
* **Application:** Automated deployment of a standalone **MongoDB** instance via Helm, with passwords securely generated and stored in AWS SSM.



## CI/CD Pipeline (Jenkins)
The `Jenkinsfile` implements a robust multi-stage pipeline:

1.  **Static Analysis:** Runs `terraform fmt` and `terraform validate` in parallel to ensure code quality.
2.  **Security Scan:** Uses **AquaSec Trivy** to scan for high/critical vulnerabilities.
3.  **Plan:** Generates a binary `tfplan` to ensure the exact code reviewed is the code deployed.
4.  **Post Plan to PR:** Automatically comments the Terraform plan summary back to the GitHub Pull Request.
5.  **Approval Gate:** Pauses for manual intervention on the `master` branch before applying changes.
6.  **Terraform Apply:** Executes the deployment using the previously generated `tfplan` with `-auto-approve`.



## Project Structure
```text
.
├── Jenkinsfile              # Declarative CI/CD pipeline
├── terraform/
│   ├── main.tf              # Root module calling EKS and Add-ons
│   ├── provider.tf          # Provider and S3 Backend configuration
│   ├── module_eks/          # EKS Cluster, VPC, and IAM resources
│   └── module_addons/       # Helm charts and K8s operators
└── README.md