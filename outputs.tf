output "environments" {
  description = "Per-environment endpoints and hosts."
  value = {
    for env in keys(var.environments) : env => {
      branch              = env
      api_url             = "https://${local.hosts[env].domain}"
      swagger_url         = "https://${local.hosts[env].domain}/swagger-ui/index.html"
      ecs_cluster         = aws_ecs_cluster.main.name
      ecs_service         = aws_ecs_service.backend[env].name
      task_family         = aws_ecs_task_definition.backend[env].family
      backend_dns         = local.hosts[env].backend_dns
      backend_log_group   = aws_cloudwatch_log_group.backend[env].name
      legacy_backend = {
        instance_id = aws_instance.backend[env].id
        public_ip   = aws_eip.backend[env].public_ip
        private_ip  = local.hosts[env].legacy_backend_ip
        state       = lookup(var.legacy_backend_state, env, "stopped")
        url         = "https://${local.hosts[env].legacy_domain}"
        nip_url     = "https://${local.hosts[env].nip_domain}"
      }
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
  description = "Grafana URL (ALB HTTPS), accessible only from admin_cidr (user: admin)."
  value       = "https://monitoring.${var.domain_name}"
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

output "load_generator" {
  description = "부하 발생기 접속 (SSM). 접속 후: loadtest dev /opt/loadtest/smoke.js"
  value = var.enable_load_generator ? {
    instance_id = aws_instance.load_generator[0].id
    connect     = "aws ssm start-session --profile ${var.aws_profile} --region ${var.aws_region} --target ${aws_instance.load_generator[0].id}"
  } : null
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

output "alb_dns_name" {
  description = "ALB DNS 이름 (Route53 <env>.<domain> 이 alias 로 가리킨다)."
  value       = aws_lb.main.dns_name
}

output "data_host_config" {
  description = "DB/Redis 런타임 설정값. 기존 호스트는 user_data 변경을 무시하므로 scripts/sync-data-host-config.sh 로 적용한다."
  value = {
    for env, cfg in var.environments : env => {
      mysql_buffer_pool_mb = cfg.mysql_buffer_pool_mb
      redis_maxmemory_mb   = cfg.redis_maxmemory_mb
    }
  }
}

output "fis_experiment_templates" {
  description = "FIS 실험 템플릿 ID. 실행: aws fis start-experiment --experiment-template-id <id>"
  value = {
    for env in keys(var.environments) : env => {
      "redis-blackhole-one-task" = try(aws_fis_experiment_template.redis_blackhole_one_task[env].id, null)
      "kill-one-task"            = try(aws_fis_experiment_template.kill_one_task[env].id, null)
      "redis-stop"               = try(aws_fis_experiment_template.redis_stop[env].id, null)
    }
  }
}
