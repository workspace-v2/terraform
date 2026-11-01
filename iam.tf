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
# ECS backend roles per environment
#   execution role: ECR pull, CloudWatch Logs, read only its own environment's
#                   parameters (/<prefix>/<env>/*) to inject them as container secrets
#   task role:      what the running containers may call (FIS SSM sidecar only)
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "ecs_execution" {
  for_each = var.environments

  name               = "${var.name_prefix}-${each.key}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy_attachment" "ecs_execution" {
  for_each = var.environments

  role       = aws_iam_role.ecs_execution[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "ecs_execution_parameters" {
  for_each = var.environments

  statement {
    sid     = "ReadOwnEnvironmentParameters"
    actions = ["ssm:GetParameters", "ssm:GetParameter"]
    resources = [
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

resource "aws_iam_role_policy" "ecs_execution_parameters" {
  for_each = var.environments

  name   = "read-${each.key}-parameters"
  role   = aws_iam_role.ecs_execution[each.key].id
  policy = data.aws_iam_policy_document.ecs_execution_parameters[each.key].json
}

resource "aws_iam_role" "ecs_task" {
  for_each = var.environments

  name               = "${var.name_prefix}-${each.key}-ecs-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

# ---------------------------------------------------------------------------
# AWS FIS ECS task actions (enable_fault_injection)
#   사이드카가 태스크 역할로 SSM hybrid activation 을 만들고, 태스크를 이 관리형 인스턴스
#   역할로 SSM 에 등록한다. FIS 는 등록된 태스크에 SSM 문서로 장애를 주입한다.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "ssm_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ssm.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "fis_managed_instance" {
  count = var.enable_fault_injection ? 1 : 0

  name               = "${var.name_prefix}-fis-ssm-managed-instance"
  assume_role_policy = data.aws_iam_policy_document.ssm_assume.json
}

resource "aws_iam_role_policy_attachment" "fis_managed_instance_ssm" {
  count = var.enable_fault_injection ? 1 : 0

  role       = aws_iam_role.fis_managed_instance[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "fis_sidecar_cleanup" {
  statement {
    sid       = "CleanupOwnRegistration"
    actions   = ["ssm:DeleteActivation", "ssm:DeregisterManagedInstance"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "fis_managed_instance_cleanup" {
  count = var.enable_fault_injection ? 1 : 0

  name   = "fis-sidecar-cleanup"
  role   = aws_iam_role.fis_managed_instance[0].id
  policy = data.aws_iam_policy_document.fis_sidecar_cleanup.json
}

data "aws_iam_policy_document" "ecs_task_fis_sidecar" {
  count = var.enable_fault_injection ? 1 : 0

  statement {
    sid       = "RegisterTaskAsManagedInstance"
    actions   = ["ssm:CreateActivation", "ssm:AddTagsToResource"]
    resources = ["*"]
  }

  # 태스크 종료 시 사이드카의 term_handler 가 태스크 역할 자격 증명으로 정리한다.
  statement {
    sid       = "CleanupOwnRegistration"
    actions   = ["ssm:DeleteActivation", "ssm:DeregisterManagedInstance"]
    resources = ["*"]
  }

  statement {
    sid       = "PassManagedInstanceRole"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.fis_managed_instance[0].arn]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ssm.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "ecs_task_fis_sidecar" {
  for_each = var.enable_fault_injection ? var.environments : {}

  name   = "fis-ssm-sidecar"
  role   = aws_iam_role.ecs_task[each.key].id
  policy = data.aws_iam_policy_document.ecs_task_fis_sidecar[0].json
}
