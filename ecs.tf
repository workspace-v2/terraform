# ECS Fargate backend (환경별 서비스 1개, 태스크 수는 var.environments[*].backend_desired_count)
#
#   ALB(<env>.<domain>) -> 대상 그룹(ip) -> 태스크 :8080 (app) / :8081 (actuator)
#   Cloud Map: <env>-backend.<namespace> -> 모든 태스크 IP (Prometheus, 부하기가 사용)
#   환경 변수: SSM Parameter Store(/<prefix>/<env>/*) -> 태스크 정의 secrets
#
# 배포(CD)는 패밀리의 최신 리비전을 기준으로 이미지만 바꾼 리비전을 등록하고 서비스를 갱신한다.
# Terraform 이 태스크 정의(CPU, 메모리, secrets 등)를 바꾸면 새 리비전이 최신이 되므로 다음 CD 에 반영된다.
# 바로 반영하려면: aws ecs update-service --cluster bangjjack --service <svc> --task-definition <family>
# 서비스의 task_definition 변경은 무시한다 (lifecycle).

resource "aws_ecs_cluster" "main" {
  name = var.name_prefix

  setting {
    name  = "containerInsights"
    value = "disabled"
  }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }
}

resource "aws_cloudwatch_log_group" "backend" {
  for_each = var.environments

  name              = "/ecs/${var.name_prefix}-${each.key}-backend"
  retention_in_days = var.ecs_log_retention_days

  tags = { Env = each.key }
}

resource "aws_cloudwatch_log_group" "fis_sidecar" {
  for_each = var.enable_fault_injection ? var.environments : {}

  name              = "/ecs/${var.name_prefix}-${each.key}-fis-ssm-agent"
  retention_in_days = 3

  tags = { Env = each.key }
}

# ---------------------------------------------------------------------------
# Service discovery (Cloud Map, private DNS)
# ---------------------------------------------------------------------------
resource "aws_service_discovery_private_dns_namespace" "main" {
  name        = var.private_dns_namespace
  description = "${var.name_prefix} internal service discovery"
  vpc         = aws_vpc.main.id
}

resource "aws_service_discovery_service" "backend" {
  for_each = var.environments

  name = "${each.key}-backend"

  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.main.id
    routing_policy = "MULTIVALUE"

    dns_records {
      type = "A"
      ttl  = 10
    }
  }

  tags = { Env = each.key }
}

# ---------------------------------------------------------------------------
# Task definition
# ---------------------------------------------------------------------------
locals {
  app_parameter_keys = concat(local.managed_parameter_keys, local.bootstrap_parameter_keys)

  app_container = {
    for env, cfg in var.environments : env => {
      name      = "app"
      image     = "${aws_ecr_repository.backend.repository_url}:${env}-latest"
      essential = true

      portMappings = [
        { name = "app", containerPort = 8080, protocol = "tcp" },
        { name = "actuator", containerPort = 8081, protocol = "tcp" },
      ]

      # /<prefix>/<env>/KEY -> 환경 변수 KEY
      secrets = [
        for key in local.app_parameter_keys : {
          name = key
          valueFrom = contains(local.managed_parameter_keys, key) ? (
            aws_ssm_parameter.managed["${env}/${key}"].arn
          ) : aws_ssm_parameter.bootstrap["${env}/${key}"].arn
        }
      ]

      # WebSocket 동시 접속 부하 테스트 대비 파일 디스크립터 상한
      ulimits = [{ name = "nofile", softLimit = 65535, hardLimit = 65535 }]

      stopTimeout = 30

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.backend[env].name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "app"
        }
      }
    }
  }

  fis_sidecar_container = {
    for env, cfg in var.environments : env => {
      name        = "amazon-ssm-agent"
      image       = "public.ecr.aws/amazon-ssm-agent/amazon-ssm-agent:latest"
      cpu         = 0
      essential   = false
      entryPoint  = []
      command     = ["/bin/bash", "-c", file("${path.module}/templates/fis-ssm-agent-sidecar.sh")]
      environment = [{ name = "MANAGED_INSTANCE_ROLE_NAME", value = one(aws_iam_role.fis_managed_instance[*].name) }]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.fis_sidecar[env].name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "ssm-agent"
        }
      }
    } if var.enable_fault_injection
  }
}

resource "aws_ecs_task_definition" "backend" {
  for_each = var.environments

  family                   = "${var.name_prefix}-${each.key}-backend"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = tostring(each.value.backend_cpu)
  memory                   = tostring(each.value.backend_memory)
  execution_role_arn       = aws_iam_role.ecs_execution[each.key].arn
  task_role_arn            = aws_iam_role.ecs_task[each.key].arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  # FIS task-kill-process / task-network-* 액션 요구 사항
  enable_fault_injection = var.enable_fault_injection
  pid_mode               = var.enable_fault_injection ? "task" : null

  container_definitions = jsonencode(concat(
    [local.app_container[each.key]],
    var.enable_fault_injection ? [local.fis_sidecar_container[each.key]] : []
  ))

  tags = { Env = each.key, Role = "backend" }
}

# ---------------------------------------------------------------------------
# Service
# ---------------------------------------------------------------------------
resource "aws_ecs_service" "backend" {
  for_each = var.environments

  name             = "${var.name_prefix}-${each.key}-backend"
  cluster          = aws_ecs_cluster.main.id
  task_definition  = aws_ecs_task_definition.backend[each.key].arn
  desired_count    = each.value.backend_desired_count
  launch_type      = "FARGATE"
  platform_version = "LATEST"

  # 롤링 배포: 새 태스크가 healthy 해진 뒤 이전 태스크를 내린다. 실패하면 자동 롤백.
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  health_check_grace_period_seconds  = var.backend_health_check_grace_seconds

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  # FIS ECS 태스크 액션은 ECS Exec 이 켜져 있으면 동작하지 않는다.
  enable_execute_command = false

  network_configuration {
    subnets          = local.app_subnet_ids
    security_groups  = [aws_security_group.ecs_backend[each.key].id]
    assign_public_ip = true # NAT 없이 ECR, SSM, CloudWatch Logs 에 나가기 위함
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.backend[each.key].arn
    container_name   = "app"
    container_port   = 8080
  }

  service_registries {
    registry_arn = aws_service_discovery_service.backend[each.key].arn
  }

  propagate_tags = "SERVICE"

  tags = { Env = each.key, Role = "backend" }

  lifecycle {
    # task_definition: CD가 새 리비전을 등록해 갱신한다. apply 가 이전 리비전으로 되돌리지 않게 한다.
    # desired_count + PowerOffDesiredCount 태그: scripts/env-power.sh 가 끄고 켤 때 바꾼다.
    #   backend_desired_count 는 서비스를 처음 만들 때만 쓰인다. 바꾸려면 aws ecs update-service --desired-count.
    ignore_changes = [
      task_definition,
      desired_count,
      tags["PowerOffDesiredCount"],
      tags_all["PowerOffDesiredCount"],
    ]
  }

  depends_on = [aws_lb_listener_rule.backend]
}
