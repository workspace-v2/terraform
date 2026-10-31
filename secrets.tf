resource "random_password" "db" {
  for_each = var.environments

  length  = 32
  special = false
}

resource "random_password" "db_exporter" {
  for_each = var.environments

  length  = 24
  special = false
}

resource "random_password" "redis" {
  for_each = var.environments

  length  = 32
  special = false
}

# JwtProvider decodes the secret with Decoders.BASE64, so only [A-Za-z0-9] with a
# length divisible by 4 is used (64 chars -> 48 bytes -> HS384-capable key).
resource "random_password" "jwt" {
  for_each = var.environments

  length  = 64
  special = false
}

resource "random_password" "dev_secret" {
  for_each = var.environments

  length  = 32
  special = false
}

resource "random_password" "grafana" {
  length  = 24
  special = false
}

locals {
  # Static key lists: keys() of a map holding sensitive values is itself sensitive and
  # cannot drive for_each.
  managed_parameter_keys = [
    "SPRING_PROFILES_ACTIVE", "APP_ENV", "DB_URL", "DB_USER", "DB_PASSWORD",
    "REDIS_HOST", "REDIS_PASSWORD", "SERVER_FORWARD_HEADERS_STRATEGY", "JAVA_OPTS",
  ]
  bootstrap_parameter_keys = [
    "SERVER_URI", "FRONT_URI", "GOOGLE_REDIRECT_URI", "GOOGLE_CLIENT_ID",
    "GOOGLE_CLIENT_SECRET", "AI_MATCH_API_BASE_URL", "JWT_ACCESS", "DEV_SECRET",
  ]

  # Values Terraform owns. Changing infrastructure updates them automatically.
  managed_parameters = {
    for env, cfg in var.environments : env => {
      SPRING_PROFILES_ACTIVE          = "dev"
      APP_ENV                         = env
      DB_URL                          = "jdbc:mysql://${local.hosts[env].database_ip}:3306/${local.db_name}?serverTimezone=Asia/Seoul&characterEncoding=UTF-8&useSSL=false&allowPublicKeyRetrieval=true"
      DB_USER                         = local.db_user
      DB_PASSWORD                     = random_password.db[env].result
      REDIS_HOST                      = local.hosts[env].redis_ip
      REDIS_PASSWORD                  = random_password.redis[env].result
      SERVER_FORWARD_HEADERS_STRATEGY = "framework"
      JAVA_OPTS                       = cfg.java_opts
    }
  }

  # Initial values only. Terraform ignores later changes, so set the real values with
  # scripts/put-app-secrets.sh (or the AWS console) and they survive future applies.
  bootstrap_parameters = {
    for env, cfg in var.environments : env => {
      SERVER_URI            = "https://${local.hosts[env].domain}"
      FRONT_URI             = cfg.front_uri
      GOOGLE_REDIRECT_URI   = "https://${local.hosts[env].domain}/auth/login/google"
      # Google 로그인, AI 매칭은 사용하지 않음. 앱 기동에 값만 필요해서 더미값을 넣는다.
      GOOGLE_CLIENT_ID      = "not-used"
      GOOGLE_CLIENT_SECRET  = "not-used"
      AI_MATCH_API_BASE_URL = "http://not-used.invalid"
      JWT_ACCESS            = random_password.jwt[env].result
      DEV_SECRET            = random_password.dev_secret[env].result
    }
  }
}

resource "aws_ssm_parameter" "managed" {
  # Keys only: for_each must not contain sensitive values (passwords).
  for_each = toset(flatten([
    for env in keys(var.environments) : [
      for key in local.managed_parameter_keys : "${env}/${key}"
    ]
  ]))

  name  = "${local.parameter_path[split("/", each.key)[0]]}/${split("/", each.key)[1]}"
  type  = "SecureString"
  value = local.managed_parameters[split("/", each.key)[0]][split("/", each.key)[1]]

  tags = { Env = split("/", each.key)[0] }
}

resource "aws_ssm_parameter" "bootstrap" {
  # Keys only: for_each must not contain sensitive values (passwords).
  for_each = toset(flatten([
    for env in keys(var.environments) : [
      for key in local.bootstrap_parameter_keys : "${env}/${key}"
    ]
  ]))

  name  = "${local.parameter_path[split("/", each.key)[0]]}/${split("/", each.key)[1]}"
  type  = "SecureString"
  value = local.bootstrap_parameters[split("/", each.key)[0]][split("/", each.key)[1]]

  tags = { Env = split("/", each.key)[0] }

  lifecycle {
    ignore_changes = [value]
  }
}
