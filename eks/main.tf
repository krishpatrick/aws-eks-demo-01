provider "aws" {
  region = local.region
}

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

data "aws_iam_session_context" "current" {
  # This data source provides information on the IAM source role of an STS assumed role
  # For non-role ARNs, this data source simply passes the ARN through issuer ARN
  # Ref https://github.com/terraform-aws-modules/terraform-aws-eks/issues/2327#issuecomment-1355581682
  # Ref https://github.com/hashicorp/terraform-provider-aws/issues/28381
  arn = data.aws_caller_identity.current.arn
}

locals {
  #name           = "ex-${basename(path.cwd)}"
  cluster_version = "1.30"
  region          = "eu-central-1"
  partition       = data.aws_partition.current.partition

  tags = {
    Test       = var.cluster_name
    GithubRepo = "terraform-aws-eks"
    GithubOrg  = "terraform-aws-modules"
  }
}

################################################################################
# VPC Module
################################################################################

module "vpc" {
  source = "./modules/vpc"

  main-region = var.main-region
  profile     = var.profile
}

################################################################################
# EKS Cluster Module
################################################################################

module "eks" {
  source = "./modules/eks-cluster"

  main-region = var.main-region
  profile     = var.profile
  rolearn     = var.rolearn

  vpc_id          = module.vpc.vpc_id
  private_subnets = module.vpc.private_subnets
}

################################################################################
# AWS fargate profile
################################################################################

module "fargate_profile" {
  source = "./modules/fargate-profile"

  name         = "default-fargate-profile"
  cluster_name = module.eks.cluster_name

  subnet_ids = module.vpc.private_subnets
  selectors = [{
    namespace = "kube-system"
  }]

  tags = merge(local.tags, { Separate = "fargate-profile" })
  #tags = "fargate-profile"
}

################################################################################
# AWS ALB Controller
################################################################################

module "aws_alb_controller" {
  source = "./modules/aws-alb-controller"

  main-region  = var.main-region
  env_name     = var.env_name
  cluster_name = var.cluster_name

  vpc_id            = module.vpc.vpc_id
  oidc_provider_arn = module.eks.oidc_provider_arn
}


################################################################################
# AWS S3 Object type bucket
################################################################################


#module "s3_bucket" {
#  source = "./modules/object"
#
#  bucket = "demo-s3-bucket"
#  acl    = "private"
#
#  control_object_ownership = true
#  object_ownership         = "ObjectWriter"
#
#  versioning = {
#    enabled = false
#  }
#}
