variable "elasticsearch_version" {
  type    = string
  default = "9.2.8"
}
variable "elasticsearch_instance_type" {
  type    = string
  default = "t3.medium"
}

data "aws_subnet" "elasticsearch" { id = var.subnet_ids[0] }

resource "random_password" "elasticsearch" {
  for_each = toset(["admin", "reader", "monitor"])
  length   = 32
  special  = false
}
resource "aws_ssm_parameter" "elasticsearch" {
  for_each = random_password.elasticsearch
  name     = "/burger/search/${each.key}_password"
  type     = "SecureString"
  value    = each.value.result
  tags     = { Project = "burger", Role = "elasticsearch" }
}
resource "aws_iam_role" "elasticsearch" {
  name               = "burger-elasticsearch"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }] })
}
resource "aws_iam_role_policy_attachment" "elasticsearch_ssm" {
  role       = aws_iam_role.elasticsearch.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
resource "aws_iam_role_policy" "elasticsearch_bootstrap" {
  name   = "bootstrap-passwords"
  role   = aws_iam_role.elasticsearch.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = ["ssm:GetParameter"], Resource = [for p in aws_ssm_parameter.elasticsearch : p.arn] }] })
}
resource "aws_iam_instance_profile" "elasticsearch" {
  name = "burger-elasticsearch"
  role = aws_iam_role.elasticsearch.name
}
resource "aws_security_group" "elasticsearch" {
  name   = "burger-elasticsearch"
  vpc_id = var.vpc_id
  ingress {
    description     = "Authenticated search API inside VPC only"
    from_port       = 9200
    to_port         = 9200
    protocol        = "tcp"
    security_groups = concat([for g in aws_security_group.app : g.id], [aws_security_group.data["dev"].id], var.load_generator_sg_id == null ? [] : [var.load_generator_sg_id])
  }
  dynamic "ingress" {
    for_each = [9100, 9114]
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
  tags = { Project = "burger", Role = "elasticsearch" }
}
resource "aws_ebs_volume" "elasticsearch" {
  availability_zone = data.aws_subnet.elasticsearch.availability_zone
  size              = 30
  type              = "gp3"
  encrypted         = true
  tags              = { Name = "burger-elasticsearch-data", Project = "burger", Role = "elasticsearch" }
  lifecycle { prevent_destroy = true }
}
resource "aws_instance" "elasticsearch" {
  ami                         = var.ami_id
  instance_type               = var.elasticsearch_instance_type
  subnet_id                   = var.subnet_ids[0]
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.elasticsearch.id]
  iam_instance_profile        = aws_iam_instance_profile.elasticsearch.name
  user_data_base64 = base64gzip(templatefile("${path.module}/elasticsearch.sh.tftpl", {
    common        = templatefile("${var.templates_path}/common.sh.tftpl", { name_prefix = "burger-search", hostname = "burger-elasticsearch", swap_mb = 0 })
    region        = var.region
    volume_id     = aws_ebs_volume.elasticsearch.id
    version       = var.elasticsearch_version
    admin_param   = aws_ssm_parameter.elasticsearch["admin"].name
    reader_param  = aws_ssm_parameter.elasticsearch["reader"].name
    monitor_param = aws_ssm_parameter.elasticsearch["monitor"].name
  }))
  metadata_options { http_tokens = "required" }
  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }
  credit_specification { cpu_credits = "standard" }
  tags = { Name = "burger-elasticsearch", Project = "burger", Env = "shared", Role = "elasticsearch" }
  lifecycle { ignore_changes = [ami, user_data_base64] }
  depends_on = [aws_iam_role_policy.elasticsearch_bootstrap, aws_iam_role_policy_attachment.elasticsearch_ssm]
}
resource "aws_volume_attachment" "elasticsearch" {
  device_name = "/dev/sdf"
  instance_id = aws_instance.elasticsearch.id
  volume_id   = aws_ebs_volume.elasticsearch.id
}
output "search" {
  value = {
    instance_id       = aws_instance.elasticsearch.id
    private_ip        = aws_instance.elasticsearch.private_ip
    url               = "http://${aws_instance.elasticsearch.private_ip}:9200"
    version           = var.elasticsearch_version
    instance_type     = var.elasticsearch_instance_type
    volume_id         = aws_ebs_volume.elasticsearch.id
    reader_username   = "burger_search"
    reader_parameter  = aws_ssm_parameter.elasticsearch["reader"].name
    admin_parameter   = aws_ssm_parameter.elasticsearch["admin"].name
    monitor_parameter = aws_ssm_parameter.elasticsearch["monitor"].name
    heap_mb           = 1024
    container_mb      = 2048
  }
}

# ECS injects only the reader secret, never the Elasticsearch admin credential.
resource "aws_iam_role_policy" "elasticsearch_reader" {
  for_each = local.environments
  role     = aws_iam_role.execution[each.key].id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = ["ssm:GetParameters"], Resource = [aws_ssm_parameter.elasticsearch["reader"].arn] }]
  })
}
