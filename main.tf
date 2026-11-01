# EC2 hosts
#   per environment (main, dev): MySQL, Redis, legacy backend (중지 보관)   (서비스 백엔드는 ECS Fargate: ecs.tf)
#   shared: monitoring (Prometheus + Grafana + Blackbox), optional load generator
#
# AMI lookups use most_recent, so `ami` is ignored after creation to avoid replacing
# hosts whenever Canonical publishes a new image. Database and Redis hosts also ignore
# user_data changes so data is never wiped by a template edit; monitoring and load-generator
# hosts are stateless and are replaced when their bootstrap script changes.

locals {
  common_init = {
    for host, cfg in merge(
      merge([for env, _ in var.environments : {
        "${env}-backend"  = { swap_mb = 2048 }
        "${env}-database" = { swap_mb = 1024 }
        "${env}-redis"    = { swap_mb = 0 }
      }]...),
      {
        monitoring       = { swap_mb = 1024 }
        "load-generator" = { swap_mb = 0 }
      }
    ) :
    host => templatefile("${path.module}/templates/common.sh.tftpl", {
      name_prefix = var.name_prefix
      hostname    = "${var.name_prefix}-${host}"
      swap_mb     = cfg.swap_mb
    })
  }
}

# ---------------------------------------------------------------------------
# Legacy backend (EC2, Docker + Caddy) - ECS 전환 후에도 삭제하지 않고 남겨 둔다.
#   - 도메인: one-<env>.<domain> -> EIP (<env>.<domain> 은 ALB/ECS). 모니터링 환경 이름: one-<env>
#   - 상태는 var.legacy_backend_state 로 관리 (기본 stopped). CD는 이 서버에 배포하지 않는다:
#     ./scripts/legacy-backend.sh <env> deploy <image-tag> 로 수동 배포, ... caddy 로 도메인 설정.
#   - user_data 변경은 무시해 템플릿 수정으로 인스턴스가 교체되지 않게 한다.
# ---------------------------------------------------------------------------
resource "aws_eip" "backend" {
  for_each = var.environments

  domain = "vpc"
  tags   = { Name = "${var.name_prefix}-${each.key}-backend", Env = each.key }
}

resource "aws_instance" "backend" {
  for_each = var.environments

  ami                    = data.aws_ami.ubuntu.id
  instance_type          = each.value.backend_instance_type
  subnet_id              = aws_subnet.public.id
  private_ip             = local.hosts[each.key].legacy_backend_ip
  vpc_security_group_ids = [aws_security_group.backend[each.key].id]
  iam_instance_profile   = aws_iam_instance_profile.backend[each.key].name

  user_data_base64 = base64gzip(templatefile("${path.module}/templates/backend.sh.tftpl", {
    common             = local.common_init["${each.key}-backend"]
    name_prefix        = var.name_prefix
    env                = each.key
    aws_region         = var.aws_region
    parameter_path     = local.parameter_path[each.key]
    app_domain         = join(", ", distinct([local.hosts[each.key].domain, local.hosts[each.key].nip_domain]))
    ecr_repository_url = aws_ecr_repository.backend.repository_url
    deploy_script      = file("${path.module}/templates/deploy.sh")
  }))
  user_data_replace_on_change = true

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    Name = "${var.name_prefix}-${each.key}-backend"
    Env  = each.key
    Role = "backend"
  }

  lifecycle {
    ignore_changes = [ami, user_data, user_data_base64]
  }

  # Parameters must exist before the first boot-time deploy attempt; DNS records before
  # Caddy requests certificates.
  depends_on = [aws_ssm_parameter.managed, aws_ssm_parameter.bootstrap, aws_route53_record.backend]
}

resource "aws_eip_association" "backend" {
  for_each = var.environments

  allocation_id = aws_eip.backend[each.key].id
  instance_id   = aws_instance.backend[each.key].id
}

resource "aws_ec2_instance_state" "legacy_backend" {
  for_each = var.environments

  instance_id = aws_instance.backend[each.key].id
  state       = lookup(var.legacy_backend_state, each.key, "stopped")
}

# ---------------------------------------------------------------------------
# MySQL
# ---------------------------------------------------------------------------
resource "aws_instance" "database" {
  for_each = var.environments

  ami                    = data.aws_ami.ubuntu.id
  instance_type          = each.value.database_instance_type
  subnet_id              = aws_subnet.public.id
  private_ip             = local.hosts[each.key].database_ip
  vpc_security_group_ids = [aws_security_group.database[each.key].id]
  iam_instance_profile   = aws_iam_instance_profile.base.name

  user_data_base64 = base64gzip(templatefile("${path.module}/templates/mysql.sh.tftpl", {
    common            = local.common_init["${each.key}-database"]
    name_prefix       = var.name_prefix
    private_ip        = local.hosts[each.key].database_ip
    app_host          = local.db_app_host
    db_name           = local.db_name
    db_user           = local.db_user
    db_password       = random_password.db[each.key].result
    exporter_password = random_password.db_exporter[each.key].result
    buffer_pool_mb    = each.value.mysql_buffer_pool_mb
    exporter_version  = var.image_versions.mysqld_exporter
  }))

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_size           = 30
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    Name = "${var.name_prefix}-${each.key}-database"
    Env  = each.key
    Role = "database"
  }

  lifecycle {
    ignore_changes = [ami, user_data, user_data_base64]
  }
}

# ---------------------------------------------------------------------------
# Redis
# ---------------------------------------------------------------------------
resource "aws_instance" "redis" {
  for_each = var.environments

  ami                    = data.aws_ami.ubuntu.id
  instance_type          = each.value.redis_instance_type
  subnet_id              = aws_subnet.public.id
  private_ip             = local.hosts[each.key].redis_ip
  vpc_security_group_ids = [aws_security_group.redis[each.key].id]
  iam_instance_profile   = aws_iam_instance_profile.base.name

  user_data_base64 = base64gzip(templatefile("${path.module}/templates/redis.sh.tftpl", {
    common           = local.common_init["${each.key}-redis"]
    private_ip       = local.hosts[each.key].redis_ip
    redis_password   = random_password.redis[each.key].result
    maxmemory_mb     = each.value.redis_maxmemory_mb
    exporter_version = var.image_versions.redis_exporter
  }))

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    Name = "${var.name_prefix}-${each.key}-redis"
    Env  = each.key
    Role = "redis"
  }

  lifecycle {
    ignore_changes = [ami, user_data, user_data_base64]
  }
}

# ---------------------------------------------------------------------------
# Monitoring
# ---------------------------------------------------------------------------
resource "aws_eip" "monitoring" {
  domain = "vpc"
  tags   = { Name = "${var.name_prefix}-monitoring" }
}

resource "aws_instance" "monitoring" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.monitoring_instance_type
  subnet_id              = aws_subnet.public.id
  private_ip             = local.monitoring_ip
  vpc_security_group_ids = [aws_security_group.monitoring.id]
  iam_instance_profile   = aws_iam_instance_profile.base.name

  user_data_base64 = base64gzip(templatefile("${path.module}/templates/monitoring.sh.tftpl", {
    common = local.common_init["monitoring"]
    prometheus_config = templatefile("${path.module}/monitoring/prometheus.yml.tftpl", {
      name_prefix = var.name_prefix
      environments = [for env in sort(keys(var.environments)) : {
        name              = env
        backend_dns       = local.hosts[env].backend_dns
        database_ip       = local.hosts[env].database_ip
        redis_ip          = local.hosts[env].redis_ip
        domain            = local.hosts[env].domain
        legacy_name       = "one-${env}"
        legacy_backend_ip = local.hosts[env].legacy_backend_ip
        legacy_domain     = local.hosts[env].legacy_domain
      }]
      monitoring_ip     = local.monitoring_ip
      load_generator_ip = var.enable_load_generator ? local.load_generator_ip : ""
    })
    alert_rules                = file("${path.module}/monitoring/alert-rules.yml")
    blackbox_config            = file("${path.module}/monitoring/blackbox.yml")
    grafana_datasource         = file("${path.module}/monitoring/grafana-datasource.yml")
    grafana_dashboard_provider = file("${path.module}/monitoring/grafana-dashboards.yml")
    overview_dashboard         = file("${path.module}/monitoring/dashboards/bangjjack-overview.json")
    # Grafana 에서 만든 채팅 측정 대시보드 (scripts/export-grafana-dashboard.sh 로 내보낸 파일)
    chat_dashboard = fileexists("${path.module}/monitoring/dashboards/bangjjack-chat.json") ? file("${path.module}/monitoring/dashboards/bangjjack-chat.json") : ""
    grafana_admin_password     = random_password.grafana.result
    prometheus_version         = var.image_versions.prometheus
    grafana_version            = var.image_versions.grafana
    blackbox_version           = var.image_versions.blackbox
  }))
  user_data_replace_on_change = true

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_size           = 30
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    Name = "${var.name_prefix}-monitoring"
    Role = "monitoring"
  }

  # Prometheus 이력(측정 데이터)이 인스턴스 디스크에 있으므로, 설정 템플릿이 바뀌어도 교체하지 않는다.
  # 설정을 반영하려면 의도적으로: terraform apply -replace=aws_instance.monitoring (이력 초기화)
  # 대시보드만이라면 교체 없이: ./scripts/export-grafana-dashboard.sh (Grafana 에서 고친 뒤)
  lifecycle {
    ignore_changes = [ami, user_data, user_data_base64]
  }
}

resource "aws_eip_association" "monitoring" {
  allocation_id = aws_eip.monitoring.id
  instance_id   = aws_instance.monitoring.id
}

# ---------------------------------------------------------------------------
# Load generator (optional)
# ---------------------------------------------------------------------------
resource "aws_instance" "load_generator" {
  count = var.enable_load_generator ? 1 : 0

  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.load_generator_instance_type
  subnet_id              = aws_subnet.public.id
  private_ip             = local.load_generator_ip
  vpc_security_group_ids = [aws_security_group.load_generator[0].id]
  iam_instance_profile   = aws_iam_instance_profile.base.name

  user_data_base64 = base64gzip(templatefile("${path.module}/templates/load-generator.sh.tftpl", {
    common        = local.common_init["load-generator"]
    k6_version    = var.image_versions.k6
    monitoring_ip = local.monitoring_ip
    environments = [for env in sort(keys(var.environments)) : {
      name              = env
      backend_dns       = local.hosts[env].backend_dns
      domain            = local.hosts[env].domain
      legacy_backend_ip = local.hosts[env].legacy_backend_ip
      legacy_domain     = local.hosts[env].legacy_domain
    }]
    loadtest_script = file("${path.module}/templates/loadtest/loadtest.sh")
    smoke_script    = file("${path.module}/templates/loadtest/smoke.js")
  }))
  user_data_replace_on_change = true

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    Name = "${var.name_prefix}-load-generator"
    Role = "load-generator"
  }

  lifecycle {
    ignore_changes = [ami]
  }
}
