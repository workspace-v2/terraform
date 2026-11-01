#!/bin/bash
# 부하 테스트 실행 래퍼: 결과를 Prometheus로 보내 Grafana(k6 대시보드, 서비스 개요)에서 서버 지표와 함께 본다.
#
# Usage: loadtest <main|dev|one-main|one-dev> <script.js> [k6 options...]
#   main/dev: ECS (내부망은 Cloud Map DNS), one-main/one-dev: 기존 EC2 단일 서버
#   TARGET=public loadtest dev smoke.js     # Caddy(HTTPS) 경유. 기본은 내부망 :8080 직접
#   loadtest dev /opt/loadtest/smoke.js --vus 50 --duration 2m
#
# 스크립트 안에서는 __ENV.BASE_URL 로 대상 주소를 쓴다.
set -euo pipefail
source /etc/loadtest.env

ENV_NAME="${1:?usage: loadtest <main|dev> <script.js> [k6 options...]}"
SCRIPT="${2:?usage: loadtest <main|dev> <script.js> [k6 options...]}"
shift 2

key="${ENV_NAME^^}"; key="${key//-/_}"   # one-main -> ONE_MAIN
if [ "${TARGET:-internal}" = "public" ]; then
  var="${key}_PUBLIC_URL"
else
  var="${key}_INTERNAL_URL"
fi
BASE_URL="${!var:-}"
[ -n "$BASE_URL" ] || { echo "unknown env: $ENV_NAME"; exit 1; }

TEST_ID="${ENV_NAME}-$(date +%m%d-%H%M%S)"
echo "target=$BASE_URL testid=$TEST_ID"

export BASE_URL
export K6_PROMETHEUS_RW_SERVER_URL="$PROMETHEUS_RW_URL"
export K6_PROMETHEUS_RW_TREND_STATS="p(50),p(95),p(99),avg,max"
exec k6 run -o experimental-prometheus-rw \
  --tag testid="$TEST_ID" --tag target_env="$ENV_NAME" \
  "$@" "$SCRIPT"
