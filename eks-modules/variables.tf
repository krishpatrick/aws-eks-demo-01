variable "aws_profile" {
  type    = string
  default = "default"
}

variable "region" {
  type    = string
  default = "eu-central-1"
}

variable "cluster_version" {
  default = "1.30"
}

variable "cluster_name" {
  default = "my-eks-cluster"
}

#variable "cluster_endpoint" {
#  type        = string
#  sensitive   = true
#  description = "The cluster endpoint"
#}

#variable "cluster_certificate_authority_data" {
#  type        = string
#  sensitive   = true
#  description = "The Cluster certificate data"
#}

#variable "oidc_provider_arn" {
#  description = "OIDC Provider ARN used for IRSA "
#  type        = string
#  sensitive   = true
#}
