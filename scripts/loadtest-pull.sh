#!/usr/bin/env bash
# 부하 발생기의 k6 결과(/opt/loadtest/results)를 로컬로 내려받는다 (SSM, SSH 불필요).
# Usage: ./scripts/loadtest-pull.sh [저장 폴더=./loadtest-results] [파일명 패턴=*]
#   예) ./scripts/loadtest-pull.sh ~/Desktop/k6-results 'chat-main-1101-*'
set -euo pipefail
export AWS_PAGER=""
cd "$(dirname "$0")/.."
PROFILE="${AWS_PROFILE_NAME:-personal-project}"
REGION="${AWS_REGION:-ap-northeast-2}"
PREFIX="${NAME_PREFIX:-bangjjack}"
DEST="${1:-./loadtest-results}"
PATTERN="${2:-*}"
CHUNK=20000   # SSM 표준 출력 한도(24000자) 안쪽

LG=$(aws ec2 describe-instances --profile "$PROFILE" --region "$REGION" \
  --filters "Name=tag:Project,Values=$PREFIX" "Name=tag:Role,Values=load-generator" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
[ "$LG" != "None" ] || { echo "load generator is not running (./scripts/env-power.sh load-generator start)"; exit 1; }

run() {  # 원격 명령 실행 후 표준 출력 반환
  local params cmd
  params=$(jq -nc --arg c "$1" '{commands: [$c]}')
  cmd=$(aws ssm send-command --profile "$PROFILE" --region "$REGION" --instance-ids "$LG" \
    --document-name AWS-RunShellScript --comment "pull loadtest results" \
    --parameters "$params" --query Command.CommandId --output text)
  aws ssm wait command-executed --profile "$PROFILE" --region "$REGION" --command-id "$cmd" --instance-id "$LG" 2>/dev/null || true
  aws ssm get-command-invocation --profile "$PROFILE" --region "$REGION" --command-id "$cmd" --instance-id "$LG" \
    --query StandardOutputContent --output text
}

# 원격에서 결과 폴더를 tar.gz + base64 로 묶어 두고 크기 확인
size=$(run "set -e; cd /opt/loadtest/results; ls $PATTERN >/dev/null; tar -czf - $PATTERN | base64 -w0 > /tmp/lt-pull.b64; wc -c < /tmp/lt-pull.b64" | tr -d '[:space:]')
[[ "$size" =~ ^[0-9]+$ ]] || { echo "원격 압축 실패 (패턴: $PATTERN): $size"; exit 1; }
echo "archive base64 size: $size bytes ($(( (size + CHUNK - 1) / CHUNK )) chunks)"

tmp=$(mktemp)
off=0
while [ "$off" -lt "$size" ]; do
  run "tail -c +$((off + 1)) /tmp/lt-pull.b64 | head -c $CHUNK" | tr -d '\n' >> "$tmp"
  off=$((off + CHUNK))
  printf '.'
done
echo
run "rm -f /tmp/lt-pull.b64" >/dev/null

got=$(wc -c < "$tmp" | tr -d ' ')
[ "$got" -eq "$size" ] || { echo "크기 불일치: expected $size, got $got"; rm -f "$tmp"; exit 1; }

mkdir -p "$DEST"
base64 -d < "$tmp" | tar -xzf - -C "$DEST"   # macOS base64 는 -d 지원
rm -f "$tmp"
echo "saved to $DEST:"
ls -l "$DEST"
