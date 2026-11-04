resource "random_password" "db" {
  for_each = local.environments
  length   = 32
  special  = false
}
resource "random_password" "redis" {
  for_each = local.environments
  length   = 32
  special  = false
}
resource "random_password" "jwt" {
  for_each = local.environments
  length   = 64
  special  = false
}

resource "random_password" "exporter" {
  for_each = local.environments
  length   = 24
  special  = false
}
resource "aws_iam_role" "data" {
  name = "burger-data-hosts"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}
resource "aws_iam_role_policy_attachment" "data_ssm" {
  role       = aws_iam_role.data.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
resource "aws_iam_instance_profile" "data" {
  name = "burger-data-hosts"
  role = aws_iam_role.data.name
}
locals {
  # Reuse the existing, tested MySQL/Redis bootstraps, without modifying the original hosts.
  host_init = { for env in local.environments : env => {
    for role in ["database", "redis"] : role => templatefile("${var.templates_path}/common.sh.tftpl", {
      name_prefix = "burger", hostname = "burger-${env}-${role}", swap_mb = role == "database" ? 1024 : 0
    })
  } }
}
resource "aws_instance" "database" {
  for_each                    = local.environments
  ami                         = var.ami_id
  instance_type               = "t3.small"
  subnet_id                   = var.subnet_ids[0]
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.data[each.key].id]
  iam_instance_profile        = aws_iam_instance_profile.data.name
  user_data_base64 = base64gzip(templatefile("${var.templates_path}/mysql.sh.tftpl", {
    common         = local.host_init[each.key].database, name_prefix = "burger", private_ip = "0.0.0.0"
    app_host       = "%", db_name = "burgerpedia", db_user = "burger"
    db_password    = random_password.db[each.key].result, exporter_password = random_password.exporter[each.key].result
    buffer_pool_mb = 768, exporter_version = var.exporter_versions.mysqld_exporter
  }))
  metadata_options { http_tokens = "required" }
  root_block_device {
    volume_size           = 30
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = false
  }
  tags = { Project = "burger", Env = each.key, Role = "database", Name = "burger-${each.key}-database" }
  lifecycle { ignore_changes = [ami, user_data_base64] }
  depends_on = [aws_iam_role_policy_attachment.data_ssm]
}
resource "aws_instance" "redis" {
  for_each                    = local.environments
  ami                         = var.ami_id
  instance_type               = "t3.micro"
  subnet_id                   = var.subnet_ids[0]
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.data[each.key].id]
  iam_instance_profile        = aws_iam_instance_profile.data.name
  user_data_base64 = base64gzip(templatefile("${var.templates_path}/redis.sh.tftpl", {
    common         = local.host_init[each.key].redis, private_ip = "0.0.0.0"
    redis_password = random_password.redis[each.key].result
    maxmemory_mb   = 384, exporter_version = var.exporter_versions.redis_exporter
  }))
  metadata_options { http_tokens = "required" }
  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = false
  }
  tags = { Project = "burger", Env = each.key, Role = "redis", Name = "burger-${each.key}-redis" }
  lifecycle { ignore_changes = [ami, user_data_base64] }
  depends_on = [aws_iam_role_policy_attachment.data_ssm]
}

locals {
  secret_keys = toset(["DB_PASSWORD", "REDIS_PASSWORD", "JWT_SECRET"])
  secrets = {
    for env in local.environments : env => {
      DB_PASSWORD    = random_password.db[env].result
      REDIS_PASSWORD = random_password.redis[env].result
      JWT_SECRET     = random_password.jwt[env].result
    }
  }
}
resource "aws_ssm_parameter" "app" {
  for_each = toset(flatten([for env in local.environments : [for key in local.secret_keys : "${env}/${key}"]]))
  name     = "/burger/${each.key}"
  type     = "SecureString"
  value    = local.secrets[split("/", each.key)[0]][split("/", each.key)[1]]
}
