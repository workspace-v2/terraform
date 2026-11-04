terraform {
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 5.0" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
}

variable "region" { type = string }
variable "account_id" { type = string }
variable "vpc_id" { type = string }
variable "subnet_ids" { type = list(string) }
variable "zone_id" { type = string }
variable "domain" { type = string }
variable "oidc_provider_arn" { type = string }
variable "github_repository" { type = string }
variable "github_oidc_sub_prefix" { type = string }
variable "services_enabled" { type = bool }

locals {
  prefix       = "burger"
  environments = toset(["main", "dev"])
  services     = var.services_enabled ? local.environments : toset([])
  domains      = { for env in local.environments : env => "${env}-burger.${var.domain}" }
  colors = merge([for env in local.environments : {
    for color in ["blue", "green"] : "${env}/${color}" => { env = env, color = color }
  }]...)
}

variable "ami_id" { type = string }
variable "templates_path" { type = string }
variable "exporter_versions" { type = map(string) }
variable "monitoring_sg_id" { type = string }
variable "load_generator_sg_id" {
  type     = string
  nullable = true
}
