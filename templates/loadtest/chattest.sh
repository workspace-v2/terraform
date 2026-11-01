#!/bin/bash
# 채팅 정합성 측정 래퍼 (부하 발생기에서 실행). 결과는 Prometheus -> Grafana(k6 대시보드)와 콘솔/파일로 남는다.
#
# Usage: chattest <main|dev> [k6 options...]
#   PAIRS=50 RATE=2 DURATION=180 chattest dev
#   TASK_IPS=10.20.1.40 chattest main          # 특정 서버만 (기본: Cloud Map 으로 실행 중인 모든 태스크)
#
# 준비: 로컬에서 ./scripts/loadtest-seed.sh <main|dev> 를 먼저 실행 (사용자 시드 + DEV_SECRET 전달)
set -euo pipefail
source /etc/loadtest.env

ENV_NAME="${1:?usage: chattest <main|dev> [k6 options...]}"
shift
BASE_ENV="$ENV_NAME"
key="${ENV_NAME^^}"; key="${key//-/_}"

if [ -z "${TASK_IPS:-}" ]; then
  dns_var="${key}_BACKEND_DNS"; dns="${!dns_var:?unknown env: $ENV_NAME}"
  TASK_IPS=$(getent ahostsv4 "$dns" | awk '{print $1}' | sort -u | paste -sd, -)
fi
if [ -z "${SERVICE_HOST:-}" ]; then
  dns_var="${key}_BACKEND_DNS"; SERVICE_HOST="${!dns_var:-}"   # 태스크가 모두 교체되면 이 이름으로 재연결
fi
[ -n "$TASK_IPS" ] || { echo "no running server found for $ENV_NAME"; exit 1; }

DATA=/opt/loadtest/data
USERS_FILE="$DATA/users-${BASE_ENV}.json"
[ -f "$USERS_FILE" ] || { echo "$USERS_FILE 없음. 로컬에서 ./scripts/loadtest-seed.sh $BASE_ENV 먼저"; exit 1; }
DEV_SECRET=$(cat "$DATA/${BASE_ENV}.secret")

TEST_ID="chat-${ENV_NAME}-$(date +%m%d-%H%M%S)"
mkdir -p /opt/loadtest/results
echo "target=$ENV_NAME servers=$TASK_IPS fallback=${SERVICE_HOST:-none} testid=$TEST_ID"

export TASK_IPS SERVICE_HOST="${SERVICE_HOST:-}" USERS_FILE DEV_SECRET TEST_ID
export K6_PROMETHEUS_RW_SERVER_URL="$PROMETHEUS_RW_URL"
export K6_PROMETHEUS_RW_TREND_STATS="p(50),p(95),p(99),avg,max"
exec k6 run -o experimental-prometheus-rw \
  --tag testid="$TEST_ID" --tag target_env="$ENV_NAME" \
  "$@" /opt/loadtest/chat-consistency.js
