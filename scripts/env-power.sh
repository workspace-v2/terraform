#!/usr/bin/env bash
# 환경 단위로 서버를 중지/시작한다. 내부 IP, 도메인, DB 데이터는 유지된다.
# Usage: ./scripts/env-power.sh <main|dev|monitoring|load-generator> <stop|start|status>
#   main/dev:
#     stop  : ECS 서비스 태스크 수를 0으로 (이전 값을 서비스 태그에 기록) -> DB, Redis EC2 중지
#     start : DB, Redis 먼저 -> 실행 확인 후 ECS 태스크 수 복원 (앱이 DB 접속 실패로 재시작 반복하지 않도록)
#   태스크 수는 terraform 이 되돌리지 않는다 (ecs.tf lifecycle). backend_desired_count 는 서비스 생성 시에만 쓰인다.
set -euo pipefail
export AWS_PAGER="" # aws cli v2 의 less 페이저로 결과가 사라지지 않게

ENV_NAME="${1:?usage: $0 <main|dev|monitoring|load-generator> <stop|start|status>}"
ACTION="${2:?usage: $0 <main|dev|monitoring|load-generator> <stop|start|status>}"
PROFILE="${AWS_PROFILE_NAME:-personal-project}"
REGION="${AWS_REGION:-ap-northeast-2}"
PREFIX="${NAME_PREFIX:-bangjjack}"
CLUSTER="$PREFIX"
SAVED_TAG="PowerOffDesiredCount"

aws_ec2() { aws ec2 "$@" --profile "$PROFILE" --region "$REGION"; }
aws_ecs() { aws ecs "$@" --profile "$PROFILE" --region "$REGION"; }

ids() { # ids <role...>
  local roles; roles=$(IFS=,; echo "$*")
  local env_filter=()
  [ "$ENV_NAME" != "monitoring" ] && env_filter=("Name=tag:Env,Values=$ENV_NAME")
  aws_ec2 describe-instances \
    --filters "Name=tag:Project,Values=$PREFIX" "Name=tag:Role,Values=$roles" ${env_filter[@]+"${env_filter[@]}"} \
              "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text
}

# ---- monitoring / load-generator: EC2 only ----
if [ "$ENV_NAME" = "monitoring" ] || [ "$ENV_NAME" = "load-generator" ]; then
  role="$ENV_NAME"; ENV_NAME=monitoring
  hosts=$(ids "$role")
  case "$ACTION" in
    stop)   aws_ec2 stop-instances --instance-ids $hosts >/dev/null; echo "stopping $role: $hosts" ;;
    start)  aws_ec2 start-instances --instance-ids $hosts >/dev/null; echo "starting $role: $hosts"
            aws_ec2 wait instance-running --instance-ids $hosts; echo "running" ;;
    status) aws_ec2 describe-instances --instance-ids $hosts \
              --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,State.Name]' --output table ;;
    *) echo "unknown action: $ACTION"; exit 1 ;;
  esac
  exit 0
fi

# ---- main / dev: ECS backend + DB, Redis EC2 ----
SERVICE="${PREFIX}-${ENV_NAME}-backend"
data=$(ids database redis)
# ECS 클러스터/서비스가 아직 없으면(terraform apply 전) 빈 값. stop/start 는 서비스가 있어야 한다.
service_arn=$(aws_ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
  --query 'services[?status==`ACTIVE`] | [0].serviceArn' --output text 2>/dev/null || true)
[ "$service_arn" = "None" ] && service_arn=""
desired() { aws_ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --query 'services[0].desiredCount' --output text; }
require_service() {
  [ -n "$service_arn" ] || { echo "ECS service $SERVICE not found (terraform apply 먼저)"; exit 1; }
}

case "$ACTION" in
  stop)
    require_service
    current=$(desired)
    if [ "$current" != "0" ]; then
      aws_ecs tag-resource --resource-arn "$service_arn" --tags "key=$SAVED_TAG,value=$current"
    fi
    aws_ecs update-service --cluster "$CLUSTER" --service "$SERVICE" --desired-count 0 >/dev/null
    echo "scaling $SERVICE to 0 (was $current), waiting for tasks to stop..."
    aws_ecs wait services-stable --cluster "$CLUSTER" --services "$SERVICE"
    aws_ec2 stop-instances --instance-ids $data >/dev/null
    echo "stopping $ENV_NAME database/redis: $data"
    ;;
  start)
    aws_ec2 start-instances --instance-ids $data >/dev/null
    echo "starting $ENV_NAME database/redis: $data"
    aws_ec2 wait instance-running --instance-ids $data
    sleep 20 # MySQL/Redis 기동 여유
    require_service
    count=$(aws_ecs list-tags-for-resource --resource-arn "$service_arn" \
      --query "tags[?key=='$SAVED_TAG'].value | [0]" --output text)
    [ "$count" = "None" ] || [ -z "$count" ] && count="${DESIRED_COUNT:-1}"
    aws_ecs update-service --cluster "$CLUSTER" --service "$SERVICE" --desired-count "$count" >/dev/null
    echo "scaling $SERVICE to $count. 태스크 기동과 ALB 헬스 체크 통과까지 2~3분 걸립니다."
    ;;
  status)
    aws_ec2 describe-instances --instance-ids $data \
      --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,State.Name]' --output table
    if [ -n "$service_arn" ]; then
      aws_ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
        --query 'services[0].{service:serviceName,desired:desiredCount,running:runningCount,pending:pendingCount}' --output table
    else
      echo "ECS service $SERVICE: 없음 (terraform apply 전)"
    fi
    ;;
  *) echo "unknown action: $ACTION"; exit 1 ;;
esac
