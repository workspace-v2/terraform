# AWS FIS 실험 템플릿 (환경별)
#
#   <prefix>-<env>-redis-blackhole-one-task : 태스크 1개만 Redis(6379) 아웃바운드 차단 (기본 60초)
#       -> 그 서버만 Pub/Sub 발행/구독 불가. 서버 간 메시지 불일치(2위), 유실(1위) 재현
#   <prefix>-<env>-kill-one-task            : 태스크 1개의 java 프로세스 SIGKILL
#       -> afterConnectionClosed 가 호출되지 않는 비정상 종료. 좀비 세션(3위), 재연결 유실(1위) 재현
#   <prefix>-<env>-redis-stop               : Redis EC2 중지 후 2분 뒤 자동 시작
#       -> 모든 서버의 Redis 장애 (보조 실험)
#
# 실행: aws fis start-experiment --experiment-template-id $(terraform output -json fis_experiment_templates | jq -r '.main["redis-blackhole-one-task"]')
# ECS 태스크 액션은 태스크 정의의 FIS 준비(enableFaultInjection, pidMode=task, SSM 사이드카)가 필요하다 (ecs.tf).

data "aws_iam_policy_document" "fis_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["fis.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "fis" {
  count = var.enable_fault_injection ? 1 : 0

  name               = "${var.name_prefix}-fis-experiment"
  assume_role_policy = data.aws_iam_policy_document.fis_assume.json
}

data "aws_iam_policy_document" "fis" {
  statement {
    sid       = "EcsTaskActions"
    actions   = ["ecs:DescribeTasks", "ecs:ListTasks", "ssm:SendCommand", "ssm:ListCommands", "ssm:CancelCommand", "ssm:GetCommandInvocation"]
    resources = ["*"]
  }

  # 태그로 대상(ECS 태스크)을 찾을 때 필요
  statement {
    sid       = "ResolveTargetsByTag"
    actions   = ["tag:GetResources", "ecs:DescribeServices", "ecs:ListClusters", "ecs:ListContainerInstances", "ssm:DescribeInstanceInformation"]
    resources = ["*"]
  }

  statement {
    sid       = "Ec2StopStart"
    actions   = ["ec2:StopInstances", "ec2:StartInstances"]
    resources = ["arn:aws:ec2:${var.aws_region}:${local.account_id}:instance/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = [var.name_prefix]
    }
  }

  statement {
    sid       = "Ec2Describe"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }

  # 암호화된 EBS 루트 볼륨을 가진 인스턴스를 다시 시작할 때 필요
  statement {
    sid       = "KmsGrantForEncryptedVolumes"
    actions   = ["kms:CreateGrant"]
    resources = ["*"]
    condition {
      test     = "Bool"
      variable = "kms:GrantIsForAWSResource"
      values   = ["true"]
    }
  }
}

resource "aws_iam_role_policy" "fis" {
  count = var.enable_fault_injection ? 1 : 0

  name   = "fis-experiments"
  role   = aws_iam_role.fis[0].id
  policy = data.aws_iam_policy_document.fis.json
}

# ECS 태스크 대상은 서비스에서 전파된 태그(propagate_tags = SERVICE)로 찾고, 실행 중인 태스크만 고른다.
# (cluster/service parameters 로는 InvalidTarget, 태그만으로는 종료된 태스크가 골라져 실패했다)

resource "aws_fis_experiment_template" "redis_blackhole_one_task" {
  for_each = var.enable_fault_injection ? var.environments : {}

  description = "${each.key}: ECS 태스크 1개만 Redis(6379) 아웃바운드 차단 ${var.fis_blackhole_duration}"
  role_arn    = aws_iam_role.fis[0].arn

  stop_condition {
    source = "none"
  }

  action {
    name      = "blackhole-redis"
    action_id = "aws:ecs:task-network-blackhole-port"

    parameter {
      key   = "duration"
      value = var.fis_blackhole_duration
    }
    parameter {
      key   = "port"
      value = "6379"
    }
    parameter {
      key   = "trafficType"
      value = "egress"
    }
    parameter {
      key   = "protocol"
      value = "tcp"
    }
    parameter {
      key   = "useEcsFaultInjectionEndpoints"
      value = "true"
    }

    target {
      key   = "Tasks"
      value = "one-task"
    }
  }

  target {
    name           = "one-task"
    resource_type  = "aws:ecs:task"
    selection_mode = "COUNT(1)"

    resource_tag {
      key   = "Env"
      value = each.key
    }
    resource_tag {
      key   = "Role"
      value = "backend"
    }

    # 태그 조회는 이미 종료된 태스크도 돌려준다 -> 실행 중인 태스크만 (DescribeTasks lastStatus, 파스칼 표기)
    filter {
      path   = "LastStatus"
      values = ["RUNNING"]
    }
  }

  tags = { Name = "${var.name_prefix}-${each.key}-redis-blackhole-one-task", Env = each.key }
}

resource "aws_fis_experiment_template" "kill_one_task" {
  for_each = var.enable_fault_injection ? var.environments : {}

  description = "${each.key}: ECS 태스크 1개의 java 프로세스 SIGKILL (비정상 종료)"
  role_arn    = aws_iam_role.fis[0].arn

  stop_condition {
    source = "none"
  }

  action {
    name      = "kill-java"
    action_id = "aws:ecs:task-kill-process"

    parameter {
      key   = "processName"
      value = "java"
    }
    parameter {
      key   = "signal"
      value = "SIGKILL"
    }

    target {
      key   = "Tasks"
      value = "one-task"
    }
  }

  target {
    name           = "one-task"
    resource_type  = "aws:ecs:task"
    selection_mode = "COUNT(1)"

    resource_tag {
      key   = "Env"
      value = each.key
    }
    resource_tag {
      key   = "Role"
      value = "backend"
    }

    # 태그 조회는 이미 종료된 태스크도 돌려준다 -> 실행 중인 태스크만 (DescribeTasks lastStatus, 파스칼 표기)
    filter {
      path   = "LastStatus"
      values = ["RUNNING"]
    }
  }

  tags = { Name = "${var.name_prefix}-${each.key}-kill-one-task", Env = each.key }
}

resource "aws_fis_experiment_template" "redis_stop" {
  for_each = var.enable_fault_injection ? var.environments : {}

  description = "${each.key}: Redis EC2 중지 후 ${var.fis_redis_stop_duration} 뒤 자동 시작"
  role_arn    = aws_iam_role.fis[0].arn

  stop_condition {
    source = "none"
  }

  action {
    name      = "stop-redis"
    action_id = "aws:ec2:stop-instances"

    parameter {
      key   = "startInstancesAfterDuration"
      value = var.fis_redis_stop_duration
    }

    target {
      key   = "Instances"
      value = "redis"
    }
  }

  target {
    name           = "redis"
    resource_type  = "aws:ec2:instance"
    selection_mode = "ALL"
    resource_arns  = [aws_instance.redis[each.key].arn]
  }

  tags = { Name = "${var.name_prefix}-${each.key}-redis-stop", Env = each.key }
}
