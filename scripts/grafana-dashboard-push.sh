#!/usr/bin/env bash
# 레포의 대시보드 JSON 을 모니터링 서버 Grafana 프로비저닝 폴더에 올린다 (SSM).
# Grafana 는 이 폴더를 주기적으로(60초) 다시 읽어 대시보드를 파일 내용으로 맞추므로,
# API/화면에서 고친 내용은 파일에 반영되지 않으면 되돌아간다. 레포 파일이 기준이다.
# Usage: ./scripts/grafana-dashboard-push.sh [이름=bangjjack-chat]
set -euo pipefail
export AWS_PAGER=""
cd "$(dirname "$0")/.."
PROFILE="${AWS_PROFILE_NAME:-personal-project}"
REGION="${AWS_REGION:-ap-northeast-2}"
PREFIX="${NAME_PREFIX:-bangjjack}"
NAME="${1:-bangjjack-chat}"
FILE="monitoring/dashboards/$NAME.json"
[ -f "$FILE" ] || { echo "$FILE 없음"; exit 1; }
jq empty "$FILE"

MON=$(aws ec2 describe-instances --profile "$PROFILE" --region "$REGION" \
  --filters "Name=tag:Project,Values=$PREFIX" "Name=tag:Role,Values=monitoring" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
[ "$MON" != "None" ] || { echo "monitoring is not running"; exit 1; }

payload=$(gzip -9c "$FILE" | base64 | tr -d '\n')
script="set -e
DIR=\$(docker inspect grafana --format '{{range .Mounts}}{{if eq .Destination \"/etc/grafana/dashboards\"}}{{.Source}}{{end}}{{end}}')
echo '$payload' | base64 -d | gunzip > /tmp/$NAME.json
install -m 644 /tmp/$NAME.json \"\$DIR/$NAME.json\"
rm -f /tmp/$NAME.json
echo \"installed \$DIR/$NAME.json (Grafana 가 60초 안에 다시 읽음)\""
params=$(jq -nc --arg c "$script" '{commands: [$c]}')
cmd=$(aws ssm send-command --profile "$PROFILE" --region "$REGION" --instance-ids "$MON" \
  --document-name AWS-RunShellScript --comment "push grafana dashboard $NAME" \
  --parameters "$params" --query Command.CommandId --output text)
aws ssm wait command-executed --profile "$PROFILE" --region "$REGION" --command-id "$cmd" --instance-id "$MON" 2>/dev/null || true
aws ssm get-command-invocation --profile "$PROFILE" --region "$REGION" --command-id "$cmd" --instance-id "$MON" \
  --query '[Status, StandardOutputContent, StandardErrorContent]' --output text
