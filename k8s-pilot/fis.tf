data "aws_caller_identity" "current" {}

locals {
  worker_arns = [
    aws_instance.node["worker-a"].arn,
    aws_instance.node["worker-b"].arn
  ]
}

resource "aws_iam_role" "fis" {
  name = "${var.name_prefix}-fis-reboot-one"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "fis.amazonaws.com" }
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
        ArnLike      = { "aws:SourceArn" = "arn:aws:fis:${var.region}:${data.aws_caller_identity.current.account_id}:experiment/*" }
      }
    }]
  })
}

resource "aws_iam_role_policy" "fis" {
  name = "RebootLabWorkersOnly"
  role = aws_iam_role.fis.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = "ec2:RebootInstances", Resource = local.worker_arns },
      { Effect = "Allow", Action = "ec2:DescribeInstances", Resource = "*" }
    ]
  })
}

resource "aws_fis_experiment_template" "worker" {
  description = "k8s-pilot: reboot exactly one lab worker"
  role_arn    = aws_iam_role.fis.arn
  tags        = { Name = "${var.name_prefix}-reboot-one-worker" }

  stop_condition {
    source = "none"
  }

  target {
    name           = "Worker"
    resource_type  = "aws:ec2:instance"
    selection_mode = "COUNT(1)"
    resource_arns  = local.worker_arns
  }

  action {
    name      = "RebootWorker"
    action_id = "aws:ec2:reboot-instances"

    target {
      key   = "Instances"
      value = "Worker"
    }
  }

  depends_on = [aws_iam_role_policy.fis]
}

output "fis_reboot_template_id" {
  value = aws_fis_experiment_template.worker.id
}
