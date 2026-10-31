variable "aws_profile" {
  description = "AWS CLI profile used for deployment."
  type        = string
  default     = "personal-project"
}

variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "ap-northeast-2"
}

variable "name_prefix" {
  description = "Prefix used for resource names, tags and SSM parameter paths."
  type        = string
  default     = "bangjjack"
}

variable "admin_cidr" {
  description = "Public CIDR allowed to access Grafana. Host administration uses AWS Systems Manager."
  type        = string
  default     = "211.244.225.211/32"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "github_repository" {
  description = "GitHub repository (owner/name) whose main/dev branches may deploy via OIDC."
  type        = string
  default     = "workspace-v2/Bangjjack-Backend-chatting"
}

variable "create_github_oidc_provider" {
  description = "Create the GitHub Actions OIDC provider. Set false if the AWS account already has one for token.actions.githubusercontent.com."
  type        = bool
  default     = true
}

variable "environments" {
  description = <<-EOT
    Deployment environments keyed by Git branch name. Each environment gets its own
    backend, MySQL and Redis EC2 hosts, security groups, IAM role and SSM parameters.
    ip_base picks the private IP block (backend = +1, database = +2, redis = +3).
  EOT
  type = map(object({
    ip_base                = number
    backend_instance_type  = string
    database_instance_type = string
    redis_instance_type    = string
    mysql_buffer_pool_mb   = number
    redis_maxmemory_mb     = number
    java_opts              = string
    front_uri              = string
  }))

  default = {
    main = {
      ip_base                = 10
      backend_instance_type  = "t3.small"
      database_instance_type = "t3.small"
      redis_instance_type    = "t3.micro"
      mysql_buffer_pool_mb   = 768
      redis_maxmemory_mb     = 384
      java_opts              = "-XX:MaxRAMPercentage=65 -XX:+UseG1GC -Duser.timezone=Asia/Seoul"
      front_uri              = "https://bangjjack.vercel.app"
    }
    dev = {
      ip_base                = 20
      backend_instance_type  = "t3.small"
      database_instance_type = "t3.micro"
      redis_instance_type    = "t3.micro"
      mysql_buffer_pool_mb   = 256
      redis_maxmemory_mb     = 256
      java_opts              = "-XX:MaxRAMPercentage=65 -XX:+UseG1GC -Duser.timezone=Asia/Seoul"
      front_uri              = "http://localhost:5173"
    }
  }

  validation {
    condition     = alltrue([for k, v in var.environments : v.ip_base >= 10 && v.ip_base <= 240])
    error_message = "ip_base must be between 10 and 240."
  }
}

variable "monitoring_instance_type" {
  description = "Instance type for Prometheus, Grafana and Blackbox exporter."
  type        = string
  default     = "t3.small"
}

variable "enable_load_generator" {
  description = "Create the load-generator host (wrk, ab, sysbench) for load testing."
  type        = bool
  default     = false
}

variable "load_generator_instance_type" {
  description = "Instance type for the load generator."
  type        = string
  default     = "t3.small"
}

variable "image_versions" {
  description = "Pinned versions of monitoring components."
  type = object({
    prometheus      = string
    grafana         = string
    blackbox        = string
    mysqld_exporter = string
    redis_exporter  = string
  })
  default = {
    prometheus      = "v3.14.0"
    grafana         = "12.4.13"
    blackbox        = "v0.28.0"
    mysqld_exporter = "0.20.0"
    redis_exporter  = "v1.94.0"
  }
}
