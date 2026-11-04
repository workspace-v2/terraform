resource "aws_iam_role" "execution" {
  for_each = local.environments
  name     = "burger-${each.key}-execution"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ecs-tasks.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}
resource "aws_iam_role_policy_attachment" "execution" {
  for_each   = local.environments
  role       = aws_iam_role.execution[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}
resource "aws_iam_role_policy" "parameters" {
  for_each = local.environments
  role     = aws_iam_role.execution[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameters"]
      Resource = [for key in local.secret_keys : aws_ssm_parameter.app["${each.key}/${key}"].arn]
    }]
  })
}
resource "aws_iam_role" "task" {
  for_each           = local.environments
  name               = "burger-${each.key}-task"
  assume_role_policy = aws_iam_role.execution[each.key].assume_role_policy
}
resource "aws_iam_role_policy" "images" {
  for_each = local.environments
  role     = aws_iam_role.task[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"]
      Resource = "${aws_s3_bucket.images[each.key].arn}/burger/*"
    }]
  })
}

resource "aws_iam_role" "codedeploy" {
  name = "burger-codedeploy"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "codedeploy.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}
resource "aws_iam_role_policy_attachment" "codedeploy" {
  role       = aws_iam_role.codedeploy.name
  policy_arn = "arn:aws:iam::aws:policy/AWSCodeDeployRoleForECS"
}

resource "aws_iam_role" "github" {
  for_each = local.environments
  name     = "burger-github-${each.key}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = { StringEquals = {
        "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        "token.actions.githubusercontent.com:sub" = compact([
          "repo:${var.github_repository}:ref:refs/heads/${each.key}",
          var.github_oidc_sub_prefix == "" ? "" : "${var.github_oidc_sub_prefix}:ref:refs/heads/${each.key}"
        ])
      } }
    }]
  })
}
resource "aws_iam_role_policy" "github" {
  for_each = local.environments
  role     = aws_iam_role.github[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = "ecr:GetAuthorizationToken", Resource = "*" },
      {
        Effect   = "Allow"
        Action   = ["ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:CompleteLayerUpload", "ecr:GetDownloadUrlForLayer", "ecr:InitiateLayerUpload", "ecr:PutImage", "ecr:UploadLayerPart", "ecr:DescribeImages"]
        Resource = aws_ecr_repository.app[each.key].arn
      },
      { Effect = "Allow", Action = ["ecs:DescribeTaskDefinition", "ecs:RegisterTaskDefinition"], Resource = "*" },
      {
        Effect    = "Allow", Action = "iam:PassRole"
        Resource  = [aws_iam_role.execution[each.key].arn, aws_iam_role.task[each.key].arn]
        Condition = { StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" } }
      },
      {
        Effect   = "Allow", Action = "ecs:DescribeServices"
        Resource = "arn:aws:ecs:${var.region}:${var.account_id}:service/burger/burger-${each.key}"
      },
      {
        Effect   = "Allow"
        Action   = ["codedeploy:CreateDeployment", "codedeploy:GetDeploymentGroup"]
        Resource = "arn:aws:codedeploy:${var.region}:${var.account_id}:deploymentgroup:burger/burger-${each.key}"
      },
      {
        Effect   = "Allow", Action = ["codedeploy:GetApplication", "codedeploy:GetApplicationRevision", "codedeploy:RegisterApplicationRevision"]
        Resource = "arn:aws:codedeploy:${var.region}:${var.account_id}:application:burger"
      },
      { Effect = "Allow", Action = "codedeploy:GetDeploymentConfig", Resource = "arn:aws:codedeploy:${var.region}:${var.account_id}:deploymentconfig:CodeDeployDefault.ECSAllAtOnce" },
      # Deployment IDs are generated dynamically; read-only status permission.
      { Effect = "Allow", Action = "codedeploy:GetDeployment", Resource = "*" }
    ]
  })
}
