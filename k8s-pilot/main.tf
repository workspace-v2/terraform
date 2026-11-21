terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

variable "aws_profile" {
  type    = string
  default = "personal-project"
}

variable "region" {
  type    = string
  default = "ap-northeast-2"
}

variable "subnet_id" {
  type        = string
  description = "Public subnet with IPv4 outbound access to package and image repositories."
}

variable "name_prefix" {
  type    = string
  default = "k8s-pilot-replay"
}

provider "aws" {
  profile = var.aws_profile
  region  = var.region

  default_tags {
    tags = { Project = var.name_prefix, ManagedBy = "Terraform" }
  }
}

data "aws_subnet" "lab" {
  id = var.subnet_id
}

data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

locals {
  nodes = {
    control  = { group = "control", size = "t3.large", disk = 30 }
    worker-a = { group = "worker", size = "t3.medium", disk = 16 }
    worker-b = { group = "worker", size = "t3.medium", disk = 16 }
  }
  ingress = {
    api             = { dst = "control", src = "worker", protocol = "tcp", port = 6443 }
    nfs             = { dst = "control", src = "worker", protocol = "tcp", port = 2049 }
    kubelet         = { dst = "worker", src = "control", protocol = "tcp", port = 10250 }
    vxlan-to-master = { dst = "control", src = "worker", protocol = "udp", port = 8472 }
    vxlan-to-worker = { dst = "worker", src = "control", protocol = "udp", port = 8472 }
    vxlan-workers   = { dst = "worker", src = "worker", protocol = "udp", port = 8472 }
  }
}

resource "aws_security_group" "nodes" {
  for_each    = toset(["control", "worker"])
  name        = "${var.name_prefix}-${each.key}"
  description = "Private cluster traffic for k8s-pilot"
  vpc_id      = data.aws_subnet.lab.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "cluster" {
  for_each                     = local.ingress
  security_group_id            = aws_security_group.nodes[each.value.dst].id
  referenced_security_group_id = aws_security_group.nodes[each.value.src].id
  ip_protocol                  = each.value.protocol
  from_port                    = each.value.port
  to_port                      = each.value.port
}

resource "aws_vpc_security_group_egress_rule" "outbound" {
  for_each          = aws_security_group.nodes
  security_group_id = each.value.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_iam_role" "node" {
  name = "${var.name_prefix}-node-ssm"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "no_parameter_reads" {
  name = "DenyParameterStoreReads"
  role = aws_iam_role.node.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Deny"
      Action   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
      Resource = "*"
    }]
  })
}

resource "aws_iam_instance_profile" "node" {
  name = aws_iam_role.node.name
  role = aws_iam_role.node.name
}

resource "aws_instance" "node" {
  for_each                    = local.nodes
  ami                         = data.aws_ssm_parameter.ubuntu.value
  instance_type               = each.value.size
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.nodes[each.value.group].id]
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.node.name

  user_data = join("\n", [
    file("${path.module}/scripts/node-base.sh"),
    each.key == "control" ? file("${path.module}/scripts/control-plane.sh") : "touch /var/lib/k8s-pilot-worker-ready"
  ])

  root_block_device {
    encrypted   = true
    volume_type = "gp3"
    volume_size = each.value.disk
  }

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  credit_specification {
    cpu_credits = "standard"
  }

  tags = { Name = "${var.name_prefix}-${each.key}", KubeRole = each.value.group }

  depends_on = [
    aws_iam_role_policy_attachment.ssm,
    aws_iam_role_policy.no_parameter_reads,
    aws_vpc_security_group_ingress_rule.cluster,
    aws_vpc_security_group_egress_rule.outbound
  ]
}

output "instance_ids" {
  value = { for key, node in aws_instance.node : key => node.id }
}

output "private_ips" {
  value = { for key, node in aws_instance.node : key => node.private_ip }
}
