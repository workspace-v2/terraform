#!/usr/bin/env bash
# templates/loadtest 의 시나리오와 chattest 래퍼를 부하 발생기에 올린다 (인스턴스 교체 없이 갱신).
# Usage: ./scripts/loadtest-push.sh
set -euo pipefail
export AWS_PAGER=""
cd "$(dirname "$0")/.."
PROFILE="${AWS_PROFILE_NAME:-personal-project}"
REGION="${AWS_REGION:-ap-northeast-2}"
PREFIX="${NAME_PREFIX:-bangjjack}"

LG=$(aws ec2 describe-instances --profile "$PROFILE" --region "$REGION" \
  --filters "Name=tag:Project,Values=$PREFIX" "Name=tag:Role,Values=load-generator" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
[ "$LG" != "None" ] || { echo "load generator is not running (./scripts/env-power.sh load-generator start)"; exit 1; }

payload=$(LC_ALL=C COPYFILE_DISABLE=1 tar -C templates/loadtest -czf - chat-consistency.js smoke.js chattest.sh | base64 | tr -d '\n')
script="set -e
mkdir -p /opt/loadtest/data /opt/loadtest/results /tmp/lt-push
echo '$payload' | base64 -d | tar -xzf - -C /tmp/lt-push
install -m 644 /tmp/lt-push/chat-consistency.js /tmp/lt-push/smoke.js /opt/loadtest/
install -m 755 /tmp/lt-push/chattest.sh /usr/local/bin/chattest
chmod -R a+rwX /opt/loadtest
rm -rf /tmp/lt-push
ls -l /opt/loadtest /usr/local/bin/chattest"
params=$(jq -nc --arg c "$script" '{commands: [$c]}')
cmd=$(aws ssm send-command --profile "$PROFILE" --region "$REGION" --instance-ids "$LG" \
  --document-name AWS-RunShellScript --comment "push loadtest files" \
  --parameters "$params" --query Command.CommandId --output text)
aws ssm wait command-executed --profile "$PROFILE" --region "$REGION" --command-id "$cmd" --instance-id "$LG" || true
aws ssm get-command-invocation --profile "$PROFILE" --region "$REGION" --command-id "$cmd" --instance-id "$LG" \
  --query '[Status, StandardOutputContent, StandardErrorContent]' --output text
