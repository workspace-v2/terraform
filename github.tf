# GitHub Actions deploys through OIDC (no long-lived AWS keys in GitHub).
# Each branch can assume only its own environment's role:
#   refs/heads/main -> <prefix>-github-deploy-main -> main ECS service + main 단일 서버 EC2 only
#   refs/heads/dev  -> <prefix>-github-deploy-dev  -> dev ECS service + dev 단일 서버 EC2 only

resource "aws_ecr_repository" "backend" {
  name                 = "${var.name_prefix}-backend"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "backend" {
  repository = aws_ecr_repository.backend.name

  policy = jsonencode({
    rules = concat(
      [for idx, env in keys(var.environments) : {
        rulePriority = idx + 1
        description  = "Keep the latest 10 ${env} images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["${env}-"]
          countType     = "imageCountMoreThan"
          countNumber   = 10
        }
        action = { type = "expire" }
      }],
      [{
        rulePriority = 100
        description  = "Expire untagged images after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      }]
    )
  })
}

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1", "1c58a3a8518e8759bf075b76b750d4f2df264fcd"]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 0 : 1

  url = "https://token.actions.githubusercontent.com"
}

locals {
  github_oidc_provider_arn = var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
}

data "aws_iam_policy_document" "github_assume" {
  for_each = var.environments

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # 기본 형식(repo:owner/name:...)과 불변 형식(repo:owner@id/name@id:...)을 모두 허용.
    # 불변 형식은 ID가 고정돼 있어 같은 이름으로 저장소를 다시 만들어도 통과하지 못한다.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = compact([
        "repo:${var.github_repository}:ref:refs/heads/${each.key}",
        var.github_oidc_sub_prefix == "" ? "" : "${var.github_oidc_sub_prefix}:ref:refs/heads/${each.key}",
      ])
    }
  }
}

resource "aws_iam_role" "github_deploy" {
  for_each = var.environments

  name                 = "${var.name_prefix}-github-deploy-${each.key}"
  assume_role_policy   = data.aws_iam_policy_document.github_assume[each.key].json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "github_deploy" {
  for_each = var.environments

  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "EcrPush"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [aws_ecr_repository.backend.arn]
  }

  # 태스크 정의 조회/등록은 리소스 단위 제한이 없다. 대신 PassRole 을 자기 환경 역할로만
  # 허용해, 다른 환경의 역할(시크릿 접근 권한)을 쓰는 리비전은 등록할 수 없게 한다.
  statement {
    sid       = "TaskDefinitions"
    actions   = ["ecs:DescribeTaskDefinition", "ecs:RegisterTaskDefinition"]
    resources = ["*"]
  }

  statement {
    sid       = "PassOwnEnvironmentTaskRoles"
    actions   = ["iam:PassRole"]
    # 리소스 속성 대신 ARN 을 직접 조합한다: ECS 서비스/역할이 변경 대상일 때 정책이
    # "known after apply" 로 표시돼 plan 에 매번 변경처럼 보이는 것을 막는다.
    resources = [
      "arn:aws:iam::${local.account_id}:role/${var.name_prefix}-${each.key}-ecs-execution",
      "arn:aws:iam::${local.account_id}:role/${var.name_prefix}-${each.key}-ecs-task",
    ]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }

  statement {
    sid       = "DeployOwnEnvironmentServiceOnly"
    actions   = ["ecs:UpdateService", "ecs:DescribeServices"]
    resources = ["arn:aws:ecs:${var.aws_region}:${local.account_id}:service/${var.name_prefix}/${var.name_prefix}-${each.key}-backend"]
  }

  # 단일 서버(기존 EC2, one-<env>) 배포: running 일 때만 SSM RunCommand 로 deploy 스크립트 실행
  statement {
    sid       = "FindLegacyBackendInstance"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }

  statement {
    sid       = "RunDeployOnOwnEnvironmentLegacyBackendOnly"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ec2:${var.aws_region}:${local.account_id}:instance/*"]

    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Env"
      values   = [each.key]
    }

    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Role"
      values   = ["backend"]
    }
  }

  statement {
    sid       = "UseRunShellScriptDocument"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ssm:${var.aws_region}::document/AWS-RunShellScript"]
  }

  statement {
    sid       = "ReadCommandResults"
    actions   = ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "github_deploy" {
  for_each = var.environments

  name   = "deploy-${each.key}"
  role   = aws_iam_role.github_deploy[each.key].id
  policy = data.aws_iam_policy_document.github_deploy[each.key].json
}
