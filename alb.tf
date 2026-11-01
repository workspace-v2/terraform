# Application Load Balancer (main/dev 공용, Host 헤더로 환경 분기)
#   https://main.<domain>       -> main 대상 그룹 (ECS 태스크 IP:8080)
#   https://dev.<domain>        -> dev 대상 그룹
#   https://monitoring.<domain> -> 모니터링 EC2 Grafana :3000 (admin_cidr 에서만, 그 외 403. 기본 전체 허용)
# TLS는 ALB(ACM 인증서)에서 종료한다. 이전 Caddy(Let's Encrypt)를 대체한다.
# WebSocket(/ws 등)은 HTTP 리스너에서 Upgrade 로 그대로 전달된다.

resource "aws_security_group" "alb" {
  name        = "${var.name_prefix}-alb"
  description = "Public ALB: HTTP/HTTPS from the internet"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-alb" }
}

resource "aws_lb" "main" {
  name               = "${var.name_prefix}-alb"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]
  subnets            = local.app_subnet_ids
  idle_timeout       = var.alb_idle_timeout

  tags = { Name = "${var.name_prefix}-alb" }
}

resource "aws_lb_target_group" "backend" {
  for_each = var.environments

  name                 = "${var.name_prefix}-${each.key}-backend"
  vpc_id               = aws_vpc.main.id
  target_type          = "ip"
  protocol             = "HTTP"
  port                 = 8080
  deregistration_delay = 30

  # 앱 포트(8080)가 아닌 actuator 포트(8081)로 헬스 체크한다.
  health_check {
    path                = "/actuator/health"
    port                = "8081"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = { Name = "${var.name_prefix}-${each.key}-backend", Env = each.key }
}

# ---------------------------------------------------------------------------
# ACM certificate (모든 환경 도메인을 SAN 으로 담은 인증서 1개, DNS 검증)
# ---------------------------------------------------------------------------
locals {
  monitoring_domain = "monitoring.${var.domain_name}"
  alb_domains       = concat([for env in sort(keys(var.environments)) : local.hosts[env].domain], [local.monitoring_domain])
}

resource "aws_acm_certificate" "alb" {
  domain_name               = local.alb_domains[0]
  subject_alternative_names = slice(local.alb_domains, 1, length(local.alb_domains))
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = "${var.name_prefix}-alb" }
}

resource "aws_route53_record" "acm_validation" {
  for_each = {
    for dvo in aws_acm_certificate.alb.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }

  zone_id         = local.zone_id
  name            = each.value.name
  type            = each.value.type
  ttl             = 60
  records         = [each.value.record]
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "alb" {
  certificate_arn         = aws_acm_certificate.alb.arn
  validation_record_fqdns = [for r in aws_route53_record.acm_validation : r.fqdn]
}

# ---------------------------------------------------------------------------
# Listeners
# ---------------------------------------------------------------------------
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.alb.certificate_arn

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "not found"
      status_code  = "404"
    }
  }
}

resource "aws_lb_listener_rule" "backend" {
  for_each = var.environments

  listener_arn = aws_lb_listener.https.arn
  priority     = 100 + index(sort(keys(var.environments)), each.key)

  condition {
    host_header {
      values = [local.hosts[each.key].domain]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend[each.key].arn
  }

  tags = { Name = "${var.name_prefix}-${each.key}-backend", Env = each.key }
}

# ---------------------------------------------------------------------------
# Grafana (https://monitoring.<domain>, admin_cidr 에서만)
# ---------------------------------------------------------------------------
resource "aws_lb_target_group" "grafana" {
  name                 = "${var.name_prefix}-grafana"
  vpc_id               = aws_vpc.main.id
  target_type          = "instance"
  protocol             = "HTTP"
  port                 = 3000
  deregistration_delay = 10

  health_check {
    path    = "/api/health"
    matcher = "200"
  }

  tags = { Name = "${var.name_prefix}-grafana" }
}

resource "aws_lb_target_group_attachment" "grafana" {
  target_group_arn = aws_lb_target_group.grafana.arn
  target_id        = aws_instance.monitoring.id
  port             = 3000
}

resource "aws_lb_listener_rule" "grafana" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 10

  condition {
    host_header {
      values = [local.monitoring_domain]
    }
  }

  condition {
    source_ip {
      values = [var.admin_cidr]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.grafana.arn
  }

  tags = { Name = "${var.name_prefix}-grafana" }
}

# admin_cidr 이 아닌 곳에서 온 monitoring.<domain> 요청은 거부
resource "aws_lb_listener_rule" "grafana_deny" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 11

  condition {
    host_header {
      values = [local.monitoring_domain]
    }
  }

  action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "forbidden"
      status_code  = "403"
    }
  }

  tags = { Name = "${var.name_prefix}-grafana-deny" }
}
