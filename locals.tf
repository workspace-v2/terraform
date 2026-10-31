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
  subnet_cidr = cidrsubnet(var.vpc_cidr, 8, 1)

  monitoring_ip     = cidrhost(local.subnet_cidr, 5)
  load_generator_ip = cidrhost(local.subnet_cidr, 6)

  db_name = replace(var.name_prefix, "-", "_")
  db_user = replace(var.name_prefix, "-", "_")

  hosts = {
    for env, cfg in var.environments : env => {
      backend_ip  = cidrhost(local.subnet_cidr, cfg.ip_base + 1)
      database_ip = cidrhost(local.subnet_cidr, cfg.ip_base + 2)
      redis_ip    = cidrhost(local.subnet_cidr, cfg.ip_base + 3)
      # nip.io resolves <ip>.nip.io to <ip>, which lets Caddy obtain a Let's Encrypt
      # certificate without owning a domain.
      domain = "${aws_eip.backend[env].public_ip}.nip.io"
    }
  }

  parameter_path = { for env in keys(var.environments) : env => "/${var.name_prefix}/${env}" }
}
