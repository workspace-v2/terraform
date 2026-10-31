#!/usr/bin/env bash
# 환경 단위로 EC2를 중지/시작한다. 고정 IP(EIP)와 내부 IP는 유지된다.
# Usage: ./scripts/env-power.sh <main|dev|monitoring|load-generator> <stop|start|status>
#   start 순서: DB, Redis 먼저 -> 실행 상태 확인 후 백엔드 (앱이 DB 접속 실패로 재시작 반복하지 않도록)
set -euo pipefail

ENV_NAME="${1:?usage: $0 <main|dev|monitoring> <stop|start|status>}"
ACTION="${2:?usage: $0 <main|dev|monitoring> <stop|start|status>}"
PROFILE="${AWS_PROFILE_NAME:-personal-project}"
REGION="${AWS_REGION:-ap-northeast-2}"
PREFIX="${NAME_PREFIX:-bangjjack}"

ids() { # ids <role...>
  local roles; roles=$(IFS=,; echo "$*")
  local env_filter=()
  [ "$ENV_NAME" != "monitoring" ] && env_filter=("Name=tag:Env,Values=$ENV_NAME")
  aws ec2 describe-instances --profile "$PROFILE" --region "$REGION" \
    --filters "Name=tag:Project,Values=$PREFIX" "Name=tag:Role,Values=$roles" ${env_filter[@]+"${env_filter[@]}"} \
              "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text
}
aws_ec2() { aws ec2 "$@" --profile "$PROFILE" --region "$REGION"; }

if [ "$ENV_NAME" = "monitoring" ]; then
  data=""; backend=$(ids monitoring)
elif [ "$ENV_NAME" = "load-generator" ]; then
  ENV_NAME=monitoring; data=""; backend=$(ids load-generator)
else
  data=$(ids database redis); backend=$(ids backend)
fi

case "$ACTION" in
  stop)
    aws_ec2 stop-instances --instance-ids $backend $data >/dev/null
    echo "stopping $ENV_NAME: $backend $data"
    ;;
  start)
    if [ -n "$data" ]; then
      aws_ec2 start-instances --instance-ids $data >/dev/null
      echo "starting $ENV_NAME database/redis: $data"
      aws_ec2 wait instance-running --instance-ids $data
      sleep 20 # MySQL/Redis 기동 여유
    fi
    aws_ec2 start-instances --instance-ids $backend >/dev/null
    echo "starting $ENV_NAME backend: $backend"
    aws_ec2 wait instance-running --instance-ids $backend
    echo "running. 앱 기동까지 1~2분 걸립니다."
    ;;
  status)
    aws_ec2 describe-instances --instance-ids $backend $data \
      --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,State.Name]' --output table
    ;;
  *) echo "unknown action: $ACTION"; exit 1 ;;
esac
