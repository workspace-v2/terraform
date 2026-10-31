# Route53
#   main.<domain>       -> main 백엔드 EIP
#   dev.<domain>        -> dev 백엔드 EIP
#   monitoring.<domain> -> 모니터링 EIP (Grafana :3000)

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
  ttl     = 300
  records = [aws_eip.backend[each.key].public_ip]
}

resource "aws_route53_record" "monitoring" {
  count = var.domain_name != "" ? 1 : 0

  zone_id = local.zone_id
  name    = "monitoring.${var.domain_name}"
  type    = "A"
  ttl     = 300
  records = [aws_eip.monitoring.public_ip]
}
