resource "aws_ecr_repository" "app" {
  for_each             = local.environments
  name                 = "burger-${each.key}"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = false
  image_scanning_configuration { scan_on_push = true }
  # No automatic deletion of tagged images: active/rollback task images must remain pullable.
}
resource "aws_ecs_cluster" "app" {
  name = "burger"
}
resource "aws_cloudwatch_log_group" "app" {
  for_each          = local.environments
  name              = "/ecs/burger-${each.key}"
  retention_in_days = 14
}
resource "aws_ecs_task_definition" "app" {
  for_each                 = local.environments
  family                   = "burger-${each.key}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "1024"
  memory                   = "2048"
  execution_role_arn       = aws_iam_role.execution[each.key].arn
  task_role_arn            = aws_iam_role.task[each.key].arn
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
  container_definitions = jsonencode([{
    name         = "app"
    image        = "${aws_ecr_repository.app[each.key].repository_url}:bootstrap"
    essential    = true
    portMappings = [{ containerPort = 3000, protocol = "tcp" }, { containerPort = 8081, protocol = "tcp" }]
    stopTimeout  = 60
    environment = [for key, value in {
      SPRING_PROFILES_ACTIVE                      = "production,ecs"
      MANAGEMENT_SERVER_PORT                      = "8081"
      MANAGEMENT_ENDPOINTS_WEB_EXPOSURE_INCLUDE   = "health,prometheus"
      APP_STOCK_SYNC_ENABLED                      = "false"
      SERVER_PORT                                 = "3000"
      SERVER_FORWARD_HEADERS_STRATEGY             = "framework"
      SPRING_DATASOURCE_URL                       = "jdbc:mysql://${aws_instance.database[each.key].private_ip}:3306/burgerpedia?connectionTimeZone=Asia/Seoul&useSSL=false&allowPublicKeyRetrieval=true"
      DB_USERNAME                                 = "burger"
      REDIS_HOST                                  = aws_instance.redis[each.key].private_ip
      REDIS_PORT                                  = "6379"
      REDIS_SSL_ENABLED                           = "false"
      CORS_ALLOWED_ORIGINS                        = "https://${local.domains[each.key]},http://localhost:3000,http://localhost:8080"
      TEST_USER_COUNT                             = "0"
      AWS_REGION                                  = var.region
      S3_BUCKET                                   = aws_s3_bucket.images[each.key].id
      S3_UPLOAD_PREFIX                            = "burger"
      S3_PUBLIC_BASE_URL                          = "https://${aws_cloudfront_distribution.images[each.key].domain_name}"
      JAVA_TOOL_OPTIONS                           = "-XX:MaxRAMPercentage=65 -XX:+UseG1GC -Duser.timezone=Asia/Seoul"
      SPRING_LIFECYCLE_TIMEOUT_PER_SHUTDOWN_PHASE = "45s"
      SERVER_SHUTDOWN                             = "graceful"
    } : { name = key, value = value }]
    secrets = [for key in local.secret_keys : {
      name = key, valueFrom = aws_ssm_parameter.app["${each.key}/${key}"].arn
    }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.app[each.key].name
        awslogs-region        = var.region
        awslogs-stream-prefix = "app"
      }
    }
  }])
}
resource "aws_ecs_service" "app" {
  for_each                          = local.services
  name                              = "burger-${each.key}"
  cluster                           = aws_ecs_cluster.app.id
  task_definition                   = aws_ecs_task_definition.app[each.key].arn
  desired_count                     = 1
  launch_type                       = "FARGATE"
  platform_version                  = "1.4.0"
  health_check_grace_period_seconds = 300
  tags                              = { Project = "burger", Env = each.key }
  deployment_controller { type = "CODE_DEPLOY" }
  network_configuration {
    subnets         = var.subnet_ids
    security_groups = [aws_security_group.app[each.key].id]
    # Existing NAT-free VPC: outbound ECR/SSM access; no direct internet ingress.
    assign_public_ip = true
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.app["${each.key}/blue"].arn
    container_name   = "app"
    container_port   = 3000
  }
  lifecycle { ignore_changes = [task_definition, load_balancer, desired_count, tags["PowerOffDesiredCount"], tags_all["PowerOffDesiredCount"]] }
  depends_on = [aws_lb_listener.https, aws_iam_role_policy.parameters, aws_iam_role_policy_attachment.execution]
}
