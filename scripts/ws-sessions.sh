#!/usr/bin/env bash
# Redis 에 등록된 WebSocket 세션 수를 센다 (ws:sessions:<userId> Set 의 원소 합).
# 실제 연결 수(k6 VU 수)보다 많이 남아 있으면 정리되지 않은 좀비 세션이다.
#
# Usage:
#   ./scripts/ws-sessions.sh <main|dev>               # 한 번 집계
#   ./scripts/ws-sessions.sh <main|dev> watch 10      # 10초마다 집계 (Ctrl+C 로 종료) — FIS 실험 전후 추이
set -euo pipefail
export AWS_PAGER=""
cd "$(dirname "$0")/.."

ENV_NAME="${1:?usage: $0 <main|dev> [watch <sec>]}"
MODE="${2:-once}"
INTERVAL="${3:-10}"
PROFILE="${AWS_PROFILE_NAME:-personal-project}"
REGION="${AWS_REGION:-ap-northeast-2}"
PREFIX="${NAME_PREFIX:-bangjjack}"

REDIS=$(aws ec2 describe-instances --profile "$PROFILE" --region "$REGION" \
  --filters "Name=tag:Project,Values=$PREFIX" "Name=tag:Env,Values=$ENV_NAME" "Name=tag:Role,Values=redis" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
[ "$REDIS" != "None" ] || { echo "$ENV_NAME redis is not running"; exit 1; }

script='export REDISCLI_AUTH=$(awk "/^requirepass /{print \$2}" /etc/redis/redis.conf)
keys=0; sessions=0; ttl_none=0
for k in $(redis-cli --scan --pattern "ws:sessions:*"); do
  keys=$((keys + 1))
  sessions=$((sessions + $(redis-cli SCARD "$k")))
  [ "$(redis-cli TTL "$k")" = "-1" ] && ttl_none=$((ttl_none + 1))
done
echo "$(date +%T) users(keys)=$keys sessions=$sessions keys_without_ttl=$ttl_none"'

once() {
  local params cmd
  params=$(jq -nc --arg c "$script" '{commands: [$c]}')
  cmd=$(aws ssm send-command --profile "$PROFILE" --region "$REGION" --instance-ids "$REDIS" \
    --document-name AWS-RunShellScript --comment "ws sessions ($ENV_NAME)" \
    --parameters "$params" --query Command.CommandId --output text)
  aws ssm wait command-executed --profile "$PROFILE" --region "$REGION" --command-id "$cmd" --instance-id "$REDIS" || true
  aws ssm get-command-invocation --profile "$PROFILE" --region "$REGION" --command-id "$cmd" --instance-id "$REDIS" \
    --query StandardOutputContent --output text
}

if [ "$MODE" = "watch" ]; then
  while true; do once; sleep "$INTERVAL"; done
else
  once
fi
