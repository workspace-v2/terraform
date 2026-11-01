# Each environment has its own security groups so a dev backend can never reach the
# main database or Redis (and vice versa).

resource "aws_security_group" "backend" {
  for_each = var.environments

  name        = "${var.name_prefix}-${each.key}-backend"
  description = "${each.key} backend: HTTPS from the internet, app/metrics from monitoring"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-${each.key}-backend", Env = each.key }
}

# ecs_backend: ECS 백엔드 태스크(ENI)에 붙는다. 인터넷 트래픽은 ALB 를 통해서만 들어온다.
# (backend SG 는 중지 보관 중인 기존 EC2 백엔드용으로 그대로 둔다)
resource "aws_security_group" "ecs_backend" {
  for_each = var.environments

  name        = "${var.name_prefix}-${each.key}-ecs-backend"
  description = "${each.key} ECS backend tasks: app/health from ALB, metrics from monitoring"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-${each.key}-ecs-backend", Env = each.key }
}

resource "aws_security_group" "database" {
  for_each = var.environments

  name        = "${var.name_prefix}-${each.key}-database"
  description = "${each.key} MySQL: only from the ${each.key} backend"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-${each.key}-database", Env = each.key }
}

resource "aws_security_group" "redis" {
  for_each = var.environments

  name        = "${var.name_prefix}-${each.key}-redis"
  description = "${each.key} Redis: only from the ${each.key} backend"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-${each.key}-redis", Env = each.key }
}

resource "aws_security_group" "monitoring" {
  name        = "${var.name_prefix}-monitoring"
  description = "Grafana restricted to the administrator"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-monitoring" }
}

resource "aws_security_group" "load_generator" {
  count = var.enable_load_generator ? 1 : 0

  name        = "${var.name_prefix}-load-generator"
  description = "Load generator with no inbound internet access"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-load-generator" }
}

locals {
  ingress_rules = merge(
    # Public traffic to the backend reverse proxy (Caddy).
    merge([for env, _ in var.environments : {
      "${env}-backend-http" = {
        sg   = aws_security_group.backend[env].id, port = 80, cidr = "0.0.0.0/0", source_sg = null
        desc = "HTTP (ACME challenge, redirect to HTTPS)"
      }
      "${env}-backend-https" = {
        sg   = aws_security_group.backend[env].id, port = 443, cidr = "0.0.0.0/0", source_sg = null
        desc = "HTTPS API and WebSocket"
      }
      "${env}-database-mysql" = {
        sg   = aws_security_group.database[env].id, port = 3306, cidr = null, source_sg = aws_security_group.backend[env].id
        desc = "MySQL from ${env} backend"
      }
      "${env}-redis-redis" = {
        sg   = aws_security_group.redis[env].id, port = 6379, cidr = null, source_sg = aws_security_group.backend[env].id
        desc = "Redis from ${env} backend"
      }
      "${env}-backend-app-mon" = {
        sg   = aws_security_group.backend[env].id, port = 8080, cidr = null, source_sg = aws_security_group.monitoring.id
        desc = "App port probe from monitoring"
      }
      "${env}-backend-actuator" = {
        sg   = aws_security_group.backend[env].id, port = 8081, cidr = null, source_sg = aws_security_group.monitoring.id
        desc = "Spring actuator (prometheus, health) from monitoring"
      }
      "${env}-backend-node" = {
        sg   = aws_security_group.backend[env].id, port = 9100, cidr = null, source_sg = aws_security_group.monitoring.id
        desc = "node_exporter from monitoring"
      }
      "${env}-database-node" = {
        sg   = aws_security_group.database[env].id, port = 9100, cidr = null, source_sg = aws_security_group.monitoring.id
        desc = "node_exporter from monitoring"
      }
      "${env}-database-exporter" = {
        sg   = aws_security_group.database[env].id, port = 9104, cidr = null, source_sg = aws_security_group.monitoring.id
        desc = "mysqld_exporter from monitoring"
      }
      "${env}-redis-node" = {
        sg   = aws_security_group.redis[env].id, port = 9100, cidr = null, source_sg = aws_security_group.monitoring.id
        desc = "node_exporter from monitoring"
      }
      "${env}-redis-exporter" = {
        sg   = aws_security_group.redis[env].id, port = 9121, cidr = null, source_sg = aws_security_group.monitoring.id
        desc = "redis_exporter from monitoring"
      }
    }]...),
    # ECS backend tasks (ALB -> task, task -> DB/Redis, monitoring -> task)
    {
      "alb-http" = {
        sg   = aws_security_group.alb.id, port = 80, cidr = "0.0.0.0/0", source_sg = null
        desc = "HTTP (redirect to HTTPS)"
      }
      "alb-https" = {
        sg   = aws_security_group.alb.id, port = 443, cidr = "0.0.0.0/0", source_sg = null
        desc = "HTTPS API and WebSocket"
      }
    },
    merge([for env, _ in var.environments : {
      "${env}-ecs-backend-app-alb" = {
        sg   = aws_security_group.ecs_backend[env].id, port = 8080, cidr = null, source_sg = aws_security_group.alb.id
        desc = "App (HTTP, WebSocket) from ALB"
      }
      "${env}-ecs-backend-health-alb" = {
        sg   = aws_security_group.ecs_backend[env].id, port = 8081, cidr = null, source_sg = aws_security_group.alb.id
        desc = "Actuator health check from ALB"
      }
      "${env}-ecs-backend-app-mon" = {
        sg   = aws_security_group.ecs_backend[env].id, port = 8080, cidr = null, source_sg = aws_security_group.monitoring.id
        desc = "App port probe from monitoring"
      }
      "${env}-ecs-backend-actuator" = {
        sg   = aws_security_group.ecs_backend[env].id, port = 8081, cidr = null, source_sg = aws_security_group.monitoring.id
        desc = "Spring actuator (prometheus, health) from monitoring"
      }
      "${env}-database-mysql-ecs" = {
        sg   = aws_security_group.database[env].id, port = 3306, cidr = null, source_sg = aws_security_group.ecs_backend[env].id
        desc = "MySQL from ${env} ECS backend"
      }
      "${env}-redis-redis-ecs" = {
        sg   = aws_security_group.redis[env].id, port = 6379, cidr = null, source_sg = aws_security_group.ecs_backend[env].id
        desc = "Redis from ${env} ECS backend"
      }
    }]...),
    {
      "monitoring-grafana" = {
        sg   = aws_security_group.monitoring.id, port = 3000, cidr = var.admin_cidr, source_sg = null
        desc = "Grafana from administrator"
      }
      "monitoring-grafana-alb" = {
        sg   = aws_security_group.monitoring.id, port = 3000, cidr = null, source_sg = aws_security_group.alb.id
        desc = "Grafana from ALB (https monitoring domain)"
      }
    },
    var.enable_load_generator ? merge(
      {
        "load-generator-node" = {
          sg   = aws_security_group.load_generator[0].id, port = 9100, cidr = null, source_sg = aws_security_group.monitoring.id
          desc = "node_exporter from monitoring"
        }
        "monitoring-prometheus-rw" = {
          sg   = aws_security_group.monitoring.id, port = 9090, cidr = null, source_sg = aws_security_group.load_generator[0].id
          desc = "k6 Prometheus remote write from load generator"
        }
      },
      [for env, _ in var.environments : {
        "${env}-backend-app-loadgen" = {
          sg   = aws_security_group.backend[env].id, port = 8080, cidr = null, source_sg = aws_security_group.load_generator[0].id
          desc = "App port from load generator"
        }
        "${env}-ecs-backend-app-loadgen" = {
          sg   = aws_security_group.ecs_backend[env].id, port = 8080, cidr = null, source_sg = aws_security_group.load_generator[0].id
          desc = "App port (ECS task) from load generator"
        }
      }]...
    ) : {}
  )
}

resource "aws_vpc_security_group_ingress_rule" "this" {
  for_each = local.ingress_rules

  security_group_id            = each.value.sg
  from_port                    = each.value.port
  to_port                      = each.value.port
  ip_protocol                  = "tcp"
  cidr_ipv4                    = each.value.cidr
  referenced_security_group_id = each.value.source_sg
  description                  = each.value.desc

  tags = { Name = each.key }
}
