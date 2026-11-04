# Additive Burgerpedia stack. Existing Bangjjack resources are not renamed or disabled.
variable "burger_services_enabled" {
  description = "Set false ONLY for the first infrastructure bootstrap; build bootstrap images, then apply with the default true."
  type        = bool
  default     = true
}

variable "burger_github_repository" {
  type    = string
  default = "workspace-v2/community-service"
}

variable "burger_github_oidc_sub_prefix" {
  description = "Immutable GitHub OIDC subject prefix; update if the repository is recreated."
  type        = string
  default     = "repo:workspace-v2@350646484/community-service@1445713043"
}

module "burger" {
  source = "./modules/burger"

  region                 = var.aws_region
  account_id             = local.account_id
  vpc_id                 = aws_vpc.main.id
  subnet_ids             = local.app_subnet_ids
  zone_id                = local.zone_id
  domain                 = var.domain_name
  oidc_provider_arn      = local.github_oidc_provider_arn
  github_repository      = var.burger_github_repository
  github_oidc_sub_prefix = var.burger_github_oidc_sub_prefix
  services_enabled       = var.burger_services_enabled
  ami_id                 = data.aws_ami.ubuntu.id
  templates_path         = abspath("${path.module}/templates")
  exporter_versions      = var.image_versions
  monitoring_sg_id       = aws_security_group.monitoring.id
  load_generator_sg_id   = var.enable_load_generator ? aws_security_group.load_generator[0].id : null
}

output "burger_deployment" {
  description = "Non-secret configuration for bootstrap and GitHub Actions."
  value = merge(module.burger.deployment, {
    monitoring_instance_id = aws_instance.monitoring.id
    monitoring_ip          = local.monitoring_ip
    load_generator_id      = var.enable_load_generator ? aws_instance.load_generator[0].id : null
  })
}

# Read only the Burgerpedia task list for Prometheus file discovery. No deploy rights.
resource "aws_iam_role_policy" "burger_monitoring_discovery" {
  name = "burger-monitoring-discovery"
  role = aws_iam_role.base.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = "ecs:ListTasks", Resource = "*", Condition = { ArnEquals = { "ecs:cluster" = module.burger.deployment.cluster_arn } } },
      { Effect = "Allow", Action = "ecs:DescribeTasks", Resource = "arn:aws:ecs:${var.aws_region}:${local.account_id}:task/burger/*" }
    ]
  })
}
