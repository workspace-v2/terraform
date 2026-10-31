output "environments" {
  description = "Per-environment endpoints and hosts."
  value = {
    for env in keys(var.environments) : env => {
      branch              = env
      api_url             = "https://${local.hosts[env].domain}"
      swagger_url         = "https://${local.hosts[env].domain}/swagger-ui/index.html"
      backend_public_ip   = aws_eip.backend[env].public_ip
      backend_instance_id = aws_instance.backend[env].id
      backend_private_ip  = local.hosts[env].backend_ip
      database_private_ip = local.hosts[env].database_ip
      redis_private_ip    = local.hosts[env].redis_ip
      database_instance   = aws_instance.database[env].id
      redis_instance      = aws_instance.redis[env].id
      parameter_path      = local.parameter_path[env]
      github_deploy_role  = aws_iam_role.github_deploy[env].arn
    }
  }
}

output "github_deploy_role_arns" {
  description = "Set these as GitHub repository variables AWS_ROLE_ARN_MAIN / AWS_ROLE_ARN_DEV."
  value       = { for env in keys(var.environments) : env => aws_iam_role.github_deploy[env].arn }
}

output "ecr_repository_url" {
  description = "ECR repository the CD pipeline pushes to."
  value       = aws_ecr_repository.backend.repository_url
}

output "grafana_url" {
  description = "Grafana URL, accessible only from admin_cidr (user: admin)."
  value       = var.domain_name != "" ? "http://monitoring.${var.domain_name}:3000" : "http://${aws_eip.monitoring.public_ip}:3000"
}

output "hosted_zone_name_servers" {
  description = "create_hosted_zone = true 일 때 도메인 등록 기관에 설정할 네임서버."
  value       = var.create_hosted_zone && var.domain_name != "" ? aws_route53_zone.main[0].name_servers : null
}

output "grafana_admin_password" {
  description = "Generated Grafana administrator password."
  value       = random_password.grafana.result
  sensitive   = true
}

output "prometheus_tunnel_command" {
  description = "Port-forward Prometheus (bound to localhost on the monitoring host) through SSM."
  value       = "aws ssm start-session --profile ${var.aws_profile} --region ${var.aws_region} --target ${aws_instance.monitoring.id} --document-name AWS-StartPortForwardingSession --parameters portNumber=9090,localPortNumber=9090"
}

output "db_passwords" {
  description = "Generated MySQL application passwords per environment."
  value       = { for env in keys(var.environments) : env => random_password.db[env].result }
  sensitive   = true
}

output "redis_passwords" {
  description = "Generated Redis passwords per environment."
  value       = { for env in keys(var.environments) : env => random_password.redis[env].result }
  sensitive   = true
}
