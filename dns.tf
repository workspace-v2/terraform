# Route53
#   main.<domain>       -> ALB (alias, Host 헤더로 main 대상 그룹)
#   dev.<domain>        -> ALB (alias, Host 헤더로 dev 대상 그룹)
#   one-main.<domain>   -> 기존 main 단일 서버 EC2 EIP (Caddy TLS)
#   one-dev.<domain>    -> 기존 dev 단일 서버 EC2 EIP
#   monitoring.<domain> -> ALB (alias) -> Grafana :3000 (admin_cidr 에서만)

resource "aws_route53_zone" "main" {
  count = var.domain_name != "" && var.create_hosted_zone ? 1 : 0

  name = var.domain_name
}

data "aws_route53_zone" "main" {
  count = var.domain_name != "" && !var.create_hosted_zone ? 1 : 0

  name         = var.domain_name
  private_zone = false
}

locals {
  zone_id = var.domain_name == "" ? null : (
    var.create_hosted_zone ? aws_route53_zone.main[0].zone_id : data.aws_route53_zone.main[0].zone_id
  )
}

resource "aws_route53_record" "backend" {
  for_each = var.domain_name != "" ? var.environments : {}

  zone_id = local.zone_id
  name    = "${each.key}.${var.domain_name}"
  type    = "A"

  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "monitoring" {
  count = var.domain_name != "" ? 1 : 0

  zone_id = local.zone_id
  name    = "monitoring.${var.domain_name}"
  type    = "A"

  # ALB(HTTPS) -> Grafana. 직접 접속(:3000)은 모니터링 EIP 로 계속 가능
  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "legacy_backend" {
  for_each = var.environments

  zone_id = local.zone_id
  name    = local.hosts[each.key].legacy_domain
  type    = "A"
  ttl     = 300
  records = [aws_eip.backend[each.key].public_ip]
}
