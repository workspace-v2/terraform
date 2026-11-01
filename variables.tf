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
  description = <<-EOT
    Grafana(https://monitoring.<domain>, 직접 :3000) 접속 허용 CIDR. 서버 접속은 SSM 이라 SSH 는 열려 있지 않다.
    기본 0.0.0.0/0: 실험할 때만 켜고 끄는 운영이라 IP 제한 없이 Grafana 로그인(admin)으로만 보호한다.
    특정 IP 로 제한하려면 terraform.tfvars 에 admin_cidr = "x.x.x.x/32".
  EOT
  type    = string
  default = "0.0.0.0/0"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "domain_name" {
  description = "Route53 호스팅 영역 도메인. <env>.<domain>(ALB), monitoring.<domain> 레코드를 만든다. ALB HTTPS 인증서(ACM) 발급에 필요하다."
  type        = string
  default     = "pattie.cloud"

  validation {
    condition     = var.domain_name != ""
    error_message = "ALB HTTPS 리스너의 ACM 인증서를 발급하려면 domain_name 이 필요하다 (nip.io 미지원)."
  }
}

variable "create_hosted_zone" {
  description = "domain_name 호스팅 영역을 새로 만들지 여부. 이미 Route53에 있으면 false (기존 영역을 조회)."
  type        = bool
  default     = false
}

variable "github_repository" {
  description = "GitHub repository (owner/name) whose main/dev branches may deploy via OIDC."
  type        = string
  default     = "workspace-v2/Bangjjack-Backend-chatting"
}

variable "github_oidc_sub_prefix" {
  description = <<-EOT
    OIDC sub 클레임 접두사 (불변 subject 사용 시). 확인:
    gh api repos/<owner>/<repo>/actions/oidc/customization/sub --jq .sub_claim_prefix
  EOT
  type        = string
  default     = "repo:workspace-v2@350646484/Bangjjack-Backend-chatting@1440614699"
}

variable "create_github_oidc_provider" {
  description = "Create the GitHub Actions OIDC provider. Set false if the AWS account already has one for token.actions.githubusercontent.com."
  type        = bool
  default     = true
}

variable "environments" {
  description = <<-EOT
    Deployment environments keyed by Git branch name. Each environment gets its own
    ECS(Fargate) backend service, MySQL and Redis EC2 hosts, security groups, IAM roles
    and SSM parameters.
    ip_base picks the private IP block (legacy backend = +1, database = +2, redis = +3). 백엔드 태스크는 IP가 동적이라
    Cloud Map DNS(<env>-backend.<private_dns_namespace>)로 찾는다.
    backend_instance_type: 기존 EC2 단일 서버 백엔드 타입 (one-<env>, var.legacy_backend_state).
    backend_cpu/backend_memory: Fargate 태스크 크기 (cpu 1024 -> memory 2048~8192, 1024 단위).
      0.5 vCPU(512)에서는 Spring Boot 기동이 2분 이상 걸려 헬스 체크 유예 안에 뜨지 못했다.
    backend_desired_count: 다중 서버 실험(Pub/Sub, FIS)을 하려면 2 이상. 서비스를 처음 만들 때만 적용된다
      (이후 태스크 수는 scripts/env-power.sh 나 aws ecs update-service --desired-count 로 바꾼다).
  EOT
  type = map(object({
    ip_base                = number
    backend_instance_type  = string
    backend_cpu            = number
    backend_memory         = number
    backend_desired_count  = number
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
      backend_cpu            = 1024
      backend_memory         = 2048
      backend_desired_count  = 2
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
      backend_cpu            = 1024
      backend_memory         = 2048
      backend_desired_count  = 2          # main(개선 전)과 같은 조건으로 비교하기 위해 main 과 동일 사양
      database_instance_type = "t3.small"
      redis_instance_type    = "t3.micro"
      mysql_buffer_pool_mb   = 768
      redis_maxmemory_mb     = 384
      java_opts              = "-XX:MaxRAMPercentage=65 -XX:+UseG1GC -Duser.timezone=Asia/Seoul"
      front_uri              = "http://localhost:5173"
    }
  }

  validation {
    condition     = alltrue([for k, v in var.environments : v.ip_base >= 10 && v.ip_base <= 240])
    error_message = "ip_base must be between 10 and 240."
  }

  validation {
    condition     = alltrue([for k, v in var.environments : v.backend_desired_count >= 0])
    error_message = "backend_desired_count must be >= 0."
  }
}

variable "monitoring_instance_type" {
  description = "Instance type for Prometheus, Grafana and Blackbox exporter."
  type        = string
  default     = "t3.small"
}

variable "enable_load_generator" {
  description = "main/dev 공용 부하 발생기(k6, wrk, ab, sysbench) 생성 여부. 평소엔 env-power.sh 로 중지."
  type        = bool
  default     = true
}

variable "load_generator_instance_type" {
  description = "부하 발생기 인스턴스 타입. T 계열은 CPU 크레딧 소진 시 부하기가 병목이 되므로 C 계열 사용."
  type        = string
  default     = "c6i.large"
}

variable "image_versions" {
  description = "Pinned versions of monitoring components."
  type = object({
    prometheus      = string
    grafana         = string
    blackbox        = string
    mysqld_exporter = string
    redis_exporter  = string
    k6              = string
  })
  default = {
    prometheus      = "v3.14.0"
    grafana         = "12.4.13"
    blackbox        = "v0.28.0"
    mysqld_exporter = "0.20.0"
    redis_exporter  = "v1.94.0"
    k6              = "v1.8.2"
  }
}

variable "private_dns_namespace" {
  description = "VPC 내부 서비스 디스커버리(Cloud Map) 네임스페이스. 백엔드 태스크 IP를 <env>-backend.<namespace> A 레코드로 등록한다."
  type        = string
  default     = "bangjjack.internal"
}

variable "alb_idle_timeout" {
  description = <<-EOT
    ALB idle timeout(초). 이 시간 동안 프레임이 오가지 않는 WebSocket 연결은 ALB가 끊는다.
    서버/클라이언트 ping 주기는 이 값보다 짧아야 한다.
  EOT
  type        = number
  default     = 300
}

variable "enable_fault_injection" {
  description = <<-EOT
    ECS 태스크에 AWS FIS 태스크 액션(task-kill-process, task-network-blackhole-port 등) 준비를 한다.
    true면 태스크 정의에 enableFaultInjection, pidMode=task, SSM agent 사이드카를 넣는다.
  EOT
  type        = bool
  default     = true
}

variable "ecs_log_retention_days" {
  description = "백엔드 컨테이너 로그(CloudWatch Logs) 보관 일수."
  type        = number
  default     = 14
}

variable "legacy_backend_state" {
  description = <<-EOT
    기존 EC2 단일 서버 백엔드(Docker + Caddy)의 환경별 상태. ECS 전환 후 삭제하지 않고 보관한다.
    접속: https://one-<env>.<domain>, 모니터링 환경 이름: one-<env>
    stopped(기본): 같은 DB/Redis 를 쓰는 앱이 ECS 와 동시에 떠서 실험 결과가 섞이지 않게 한다.
    running: 단일 서버 한계 측정 등 EC2 백엔드를 쓸 때. 예) -var 'legacy_backend_state={main="running"}'
  EOT
  type    = map(string)
  default = {}

  validation {
    condition     = alltrue([for k, v in var.legacy_backend_state : contains(["running", "stopped"], v)])
    error_message = "legacy_backend_state values must be running or stopped."
  }
}

variable "backend_health_check_grace_seconds" {
  description = "ECS 서비스 헬스 체크 유예(초). 이 시간 안에 ALB 헬스 체크를 통과하지 못하면 태스크를 교체한다. Spring Boot 기동 시간보다 넉넉해야 한다."
  type        = number
  default     = 300
}

variable "fis_blackhole_duration" {
  description = "FIS 태스크 1개 Redis 차단 실험의 차단 시간 (ISO 8601, 예: PT60S)."
  type        = string
  default     = "PT60S"
}

variable "fis_redis_stop_duration" {
  description = "FIS Redis EC2 중지 실험에서 다시 시작하기까지의 시간 (ISO 8601, 최소 PT1M)."
  type        = string
  default     = "PT2M"
}
