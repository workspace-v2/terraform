resource "aws_codedeploy_app" "app" {
  name             = "burger"
  compute_platform = "ECS"
}
resource "aws_cloudwatch_metric_alarm" "target_errors" {
  for_each            = local.colors
  alarm_name          = "burger-${each.value.env}-${each.value.color}-5xx"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 5
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  dimensions = {
    LoadBalancer = aws_lb.app[each.value.env].arn_suffix
    TargetGroup  = aws_lb_target_group.app[each.key].arn_suffix
  }
}
resource "aws_codedeploy_deployment_group" "app" {
  for_each               = local.services
  app_name               = aws_codedeploy_app.app.name
  deployment_group_name  = "burger-${each.key}"
  service_role_arn       = aws_iam_role.codedeploy.arn
  deployment_config_name = "CodeDeployDefault.ECSAllAtOnce"
  deployment_style {
    deployment_option = "WITH_TRAFFIC_CONTROL"
    deployment_type   = "BLUE_GREEN"
  }
  blue_green_deployment_config {
    deployment_ready_option { action_on_timeout = "CONTINUE_DEPLOYMENT" }
    terminate_blue_instances_on_deployment_success {
      action                           = "TERMINATE"
      termination_wait_time_in_minutes = 5
    }
  }
  ecs_service {
    cluster_name = aws_ecs_cluster.app.name
    service_name = aws_ecs_service.app[each.key].name
  }
  load_balancer_info {
    target_group_pair_info {
      prod_traffic_route { listener_arns = [aws_lb_listener.https[each.key].arn] }
      target_group { name = aws_lb_target_group.app["${each.key}/blue"].name }
      target_group { name = aws_lb_target_group.app["${each.key}/green"].name }
    }
  }
  alarm_configuration {
    enabled                   = true
    ignore_poll_alarm_failure = false
    alarms                    = [for color in ["blue", "green"] : aws_cloudwatch_metric_alarm.target_errors["${each.key}/${color}"].alarm_name]
  }
  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE", "DEPLOYMENT_STOP_ON_ALARM", "DEPLOYMENT_STOP_ON_REQUEST"]
  }
  depends_on = [aws_iam_role_policy_attachment.codedeploy]
}

output "deployment" {
  value = {
    region         = var.region
    repository     = var.github_repository
    cluster        = aws_ecs_cluster.app.name
    cluster_arn    = aws_ecs_cluster.app.arn
    codedeploy_app = aws_codedeploy_app.app.name
    environments = { for env in local.environments : env => {
      url              = "https://${local.domains[env]}"
      role_arn         = aws_iam_role.github[env].arn
      ecr_repository   = aws_ecr_repository.app[env].name
      ecr_url          = aws_ecr_repository.app[env].repository_url
      task_family      = aws_ecs_task_definition.app[env].family
      service          = "burger-${env}"
      deployment_group = "burger-${env}"
      database_id      = aws_instance.database[env].id
      database_ip      = aws_instance.database[env].private_ip
      redis_id         = aws_instance.redis[env].id
      redis_ip         = aws_instance.redis[env].private_ip
      images_url       = "https://${aws_cloudfront_distribution.images[env].domain_name}"
    } }
  }
}
