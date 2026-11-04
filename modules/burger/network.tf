resource "aws_security_group" "alb" {
  for_each = local.environments
  name     = "burger-${each.key}-alb"
  vpc_id   = var.vpc_id
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "app" {
  for_each = local.environments
  name     = "burger-${each.key}-app"
  vpc_id   = var.vpc_id
  ingress {
    from_port       = 8081
    to_port         = 8081
    protocol        = "tcp"
    security_groups = [aws_security_group.alb[each.key].id, var.monitoring_sg_id]
  }
  dynamic "ingress" {
    for_each = var.load_generator_sg_id == null ? [] : [var.load_generator_sg_id]
    content {
      from_port       = 3000
      to_port         = 3000
      protocol        = "tcp"
      security_groups = [ingress.value]
    }
  }
  ingress {
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb[each.key].id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "data" {
  for_each = local.environments
  name     = "burger-${each.key}-data"
  vpc_id   = var.vpc_id
  dynamic "ingress" {
    for_each = [9100, 9104, 9121]
    content {
      from_port       = ingress.value
      to_port         = ingress.value
      protocol        = "tcp"
      security_groups = [var.monitoring_sg_id]
    }
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.app[each.key].id]
  }
  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.app[each.key].id]
  }
}

# One listener per deployment group: deployments cannot change another environment's routes.
resource "aws_lb" "app" {
  for_each           = local.environments
  name               = "burger-${each.key}"
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb[each.key].id]
  subnets            = var.subnet_ids
}

resource "aws_lb_target_group" "app" {
  for_each             = local.colors
  name                 = "burger-${each.value.env}-${each.value.color}"
  vpc_id               = var.vpc_id
  target_type          = "ip"
  protocol             = "HTTP"
  port                 = 3000
  deregistration_delay = 30
  health_check {
    path                = "/actuator/health/readiness"
    port                = "8081"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_acm_certificate" "app" {
  for_each          = local.environments
  domain_name       = local.domains[each.key]
  validation_method = "DNS"
  lifecycle { create_before_destroy = true }
}

resource "aws_route53_record" "validation" {
  for_each        = local.environments
  zone_id         = var.zone_id
  name            = tolist(aws_acm_certificate.app[each.key].domain_validation_options)[0].resource_record_name
  type            = tolist(aws_acm_certificate.app[each.key].domain_validation_options)[0].resource_record_type
  records         = [tolist(aws_acm_certificate.app[each.key].domain_validation_options)[0].resource_record_value]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "app" {
  for_each                = local.environments
  certificate_arn         = aws_acm_certificate.app[each.key].arn
  validation_record_fqdns = [aws_route53_record.validation[each.key].fqdn]
}

resource "aws_lb_listener" "http" {
  for_each          = local.environments
  load_balancer_arn = aws_lb.app[each.key].arn
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
  for_each          = local.environments
  load_balancer_arn = aws_lb.app[each.key].arn
  port              = 443
  protocol          = "HTTPS"
  certificate_arn   = aws_acm_certificate_validation.app[each.key].certificate_arn
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app["${each.key}/blue"].arn
  }
  # CodeDeploy owns the active color after the first deployment.
  lifecycle { ignore_changes = [default_action] }
}

resource "aws_route53_record" "app" {
  for_each = local.environments
  zone_id  = var.zone_id
  name     = local.domains[each.key]
  type     = "A"
  alias {
    name                   = aws_lb.app[each.key].dns_name
    zone_id                = aws_lb.app[each.key].zone_id
    evaluate_target_health = true
  }
}
