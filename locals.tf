data "aws_caller_identity" "current" {}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  subnet_cidr   = cidrsubnet(var.vpc_cidr, 8, 1)
  subnet_cidr_c = cidrsubnet(var.vpc_cidr, 8, 2)

  # MySQL 앱 계정 접속 허용 호스트. ECS 태스크 IP는 동적이라 VPC 대역 와일드카드를 쓰고,
  # 실제 접근 제어는 보안 그룹(백엔드 태스크 SG -> DB SG 3306)으로 한다.
  # 예: 10.20.0.0/16 -> '10.20.%'  (/16 VPC 기준)
  db_app_host = "${join(".", slice(split(".", cidrhost(var.vpc_cidr, 0)), 0, 2))}.%"

  monitoring_ip     = cidrhost(local.subnet_cidr, 5)
  load_generator_ip = cidrhost(local.subnet_cidr, 6)

  db_name = replace(var.name_prefix, "-", "_")
  db_user = replace(var.name_prefix, "-", "_")

  hosts = {
    for env, cfg in var.environments : env => {
      database_ip = cidrhost(local.subnet_cidr, cfg.ip_base + 2)
      redis_ip    = cidrhost(local.subnet_cidr, cfg.ip_base + 3)
      # 대표 도메인: <env>.<domain_name> (Route53 -> ALB)
      domain = "${env}.${var.domain_name}"
      # 백엔드 태스크 내부 DNS (Cloud Map, 태스크 IP 전부를 A 레코드로 반환)
      backend_dns = "${env}-backend.${var.private_dns_namespace}"
    }
  }

  parameter_path = { for env in keys(var.environments) : env => "/${var.name_prefix}/${env}" }
}
