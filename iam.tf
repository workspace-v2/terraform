data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# ---------------------------------------------------------------------------
# Base role: database, Redis, monitoring and load-generator hosts (SSM only)
# ---------------------------------------------------------------------------
resource "aws_iam_role" "base" {
  name               = "${var.name_prefix}-ec2-base"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "base_ssm" {
  role       = aws_iam_role.base.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "base" {
  name = "${var.name_prefix}-ec2-base"
  role = aws_iam_role.base.name
}

# ---------------------------------------------------------------------------
# Backend role per environment: SSM, ECR pull, and read access to only its own
# environment's parameters (/<prefix>/<env>/*)
# ---------------------------------------------------------------------------
resource "aws_iam_role" "backend" {
  for_each = var.environments

  name               = "${var.name_prefix}-${each.key}-backend"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "backend_ssm" {
  for_each = var.environments

  role       = aws_iam_role.backend[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "backend_ecr" {
  for_each = var.environments

  role       = aws_iam_role.backend[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

data "aws_iam_policy_document" "backend_parameters" {
  for_each = var.environments

  statement {
    sid     = "ReadOwnEnvironmentParameters"
    actions = ["ssm:GetParametersByPath", "ssm:GetParameters", "ssm:GetParameter"]
    resources = [
      "arn:aws:ssm:${var.aws_region}:${local.account_id}:parameter${local.parameter_path[each.key]}",
      "arn:aws:ssm:${var.aws_region}:${local.account_id}:parameter${local.parameter_path[each.key]}/*",
    ]
  }

  statement {
    sid       = "DecryptSecureStringViaSsm"
    actions   = ["kms:Decrypt"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.aws_region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "backend_parameters" {
  for_each = var.environments

  name   = "read-${each.key}-parameters"
  role   = aws_iam_role.backend[each.key].id
  policy = data.aws_iam_policy_document.backend_parameters[each.key].json
}

resource "aws_iam_instance_profile" "backend" {
  for_each = var.environments

  name = "${var.name_prefix}-${each.key}-backend"
  role = aws_iam_role.backend[each.key].name
}
