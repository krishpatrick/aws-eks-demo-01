provider "aws" {
  region = "eu-central-1"
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.cluster.token
  }
}

# did not work - Cycle error
#provider "kubernetes" {
#  host                   = module.eks.cluster.endpoint
#  cluster_ca_certificate = base64decode(module.eks.cluster.certificateAuthority.data)
#
#  exec {
#    api_version = "client.authentication.k8s.io/v1beta1"
#    command     = "aws"
#    # This requires the awscli to be installed locally where Terraform is executed
#    args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
#  }
#}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  token                  = data.aws_eks_cluster_auth.main.token
  cluster_ca_certificate = base64decode(module.eks.cluster_ca_certificate)
}

#provider "kubernetes" {
#  host                   = var.cluster_endpoint
#  cluster_ca_certificate = base64decode(var.cluster_certificate_authority_data)
#  exec {
#    api_version = "client.authentication.k8s.io/v1beta1"
#    command     = "aws"
#    # This requires the awscli to be installed locally where Terraform is executed
#    args = ["eks", "get-token", "--cluster-name", var.cluster_name]
#  }
#}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.8.1"  # Latest version

  name = "eks-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["eu-central-1a", "eu-central-1b"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true
}

module "eks" {
  source          = "terraform-aws-modules/eks/aws"
  version         = "19.12.0"  # Latest stable version
  cluster_name    = "my-eks-cluster"
  cluster_version = "1.30"  # Latest supported version by EKS module
  subnet_ids      = module.vpc.private_subnets
  vpc_id          = module.vpc.vpc_id
  cluster_addons = {
    coredns                = {
        cluster_name      = "${module.eks.cluster_name}"
        #resolve_conflicts_on_create = "OVERWRITE"
        resolve_conflicts_on_update = "OVERWRITE"
        resolve_conflicts = "OVERWRITE"
    }
   }
  fargate_profiles = {
    default = {
      selectors = [{
        namespace = "default"
      }]
    }
    kube_system = {
      selectors = [
        { namespace = "kube-system" }
      ]
    }
    staging = {
      selectors = [
        { namespace = "staging" }
      ]
    }
  }

  tags = {
    Environment = "dev"
  }
}

data "aws_eks_cluster" "cluster" {
  name = module.eks.cluster_name
}

data "aws_eks_cluster_auth" "cluster" {
  name = module.eks.cluster_name
}

#example data.aws_eks_cluster_auth.cluster.token

data "tls_certificate" "eks_oidc" {
  url = module.eks.cluster_oidc_issuer_url
}

#example - data.tls_certificate.eks_oidc.certificates[0].sha1_fingerprint

data "aws_caller_identity" "current" {}

# Exammple usage data.aws_caller_identity.current.account_id

resource "kubernetes_service_account" "aws_load_balancer_controller" {
  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"
  }
}

resource "aws_iam_role" "alb_ingress_controller" {
  name = "alb-ingress-controller"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "eks.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_openid_connect_provider" "oidc_provider" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks_oidc.certificates[0].sha1_fingerprint]
  url             = module.eks.cluster_oidc_issuer_url

  lifecycle {
    create_before_destroy = true
    ignore_changes = [
      client_id_list,
      thumbprint_list,
      url,
    ]
  }
}

resource "aws_iam_role" "eks_role" {
  name = "eks-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.oidc_provider.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${aws_iam_openid_connect_provider.oidc_provider.url}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
        }
      }
    }]
  })
}

resource "null_resource" "kubectl_config" {
  provisioner "local-exec" {
    command = <<-EOT
      aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}
      kubectl config use-context arn:aws:eks:${var.region}:${data.aws_caller_identity.current.account_id}:cluster/${module.eks.cluster_name}
    EOT

    environment = {
      AWS_PROFILE = var.aws_profile  # Optional, if you are using named profiles
    }
  }

  depends_on = [
    module.eks
  ]
}

resource "null_resource" "wait_for_cluster" {
  provisioner "local-exec" {
    command = <<-EOT
      for i in $(seq 1 30); do
        kubectl get nodes && exit 0 || sleep 10
      done
      exit 1
    EOT

    environment = {
      KUBECONFIG = "~/.kube/config"
    }
  }

  depends_on = [
    null_resource.kubectl_config
  ]
}

resource "helm_release" "metrics-server" {
  name = "metrics-server"

  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  namespace  = "kube-system"
  version    = "3.8.4"

  set {
    name  = "metrics.enabled"
    value = false
  }

  depends_on = [
    null_resource.wait_for_cluster
  ]
}

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"

  values = [
    <<EOF
    clusterName: ${module.eks.cluster_name}
    serviceAccount:
      create: false
      name: aws-load-balancer-controller
    EOF
  ]

  depends_on = [
    null_resource.wait_for_cluster
  ]
}
