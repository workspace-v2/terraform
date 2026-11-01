#!/usr/bin/env bash
# Grafana 화면에서 만든/고친 대시보드를 레포 파일로 내보내고, 모니터링 서버의 프로비저닝 폴더에도 넣는다.
#   레포 파일(monitoring/dashboards/<name>.json)은 모니터링 서버가 새로 만들어질 때 자동으로 들어간다.
#   프로비저닝 폴더에 넣어 두면 Grafana DB 가 초기화돼도 다시 로드된다.
#
# Usage: ./scripts/export-grafana-dashboard.sh [uid=bangjjack-chat] [name=bangjjack-chat]
set -euo pipefail
export AWS_PAGER=""
cd "$(dirname "$0")/.."

UID_="${1:-bangjjack-chat}"
NAME="${2:-$UID_}"
OUT="monitoring/dashboards/$NAME.json"
PROFILE="${AWS_PROFILE_NAME:-personal-project}"
REGION="${AWS_REGION:-ap-northeast-2}"
PREFIX="${NAME_PREFIX:-bangjjack}"

MON=$(aws ec2 describe-instances --profile "$PROFILE" --region "$REGION" \
  --filters "Name=tag:Project,Values=$PREFIX" "Name=tag:Role,Values=monitoring" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
[ "$MON" != "None" ] || { echo "monitoring is not running"; exit 1; }

script="set -e
PW=\$(docker inspect grafana --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^GF_SECURITY_ADMIN_PASSWORD=//p')
curl -fsS -u \"admin:\$PW\" http://localhost:3000/api/dashboards/uid/$UID_ \
  | python3 -c 'import json,sys; d=json.load(sys.stdin)[\"dashboard\"]; [d.pop(k,None) for k in (\"id\",\"version\")]; print(json.dumps(d,ensure_ascii=False,indent=2))' \
  > /tmp/$NAME.json
DIR=\$(docker inspect grafana --format '{{range .Mounts}}{{if eq .Destination \"/etc/grafana/dashboards\"}}{{.Source}}{{end}}{{end}}')
install -m 644 /tmp/$NAME.json \"\$DIR/$NAME.json\"
gzip -9c /tmp/$NAME.json | base64 -w0"
params=$(jq -nc --arg c "$script" '{commands: [$c]}')
cmd=$(aws ssm send-command --profile "$PROFILE" --region "$REGION" --instance-ids "$MON" \
  --document-name AWS-RunShellScript --comment "export grafana dashboard $UID_" \
  --parameters "$params" --query Command.CommandId --output text)
aws ssm wait command-executed --profile "$PROFILE" --region "$REGION" --command-id "$cmd" --instance-id "$MON" || true
status=$(aws ssm get-command-invocation --profile "$PROFILE" --region "$REGION" --command-id "$cmd" --instance-id "$MON" --query Status --output text)
if [ "$status" != "Success" ]; then
  aws ssm get-command-invocation --profile "$PROFILE" --region "$REGION" --command-id "$cmd" --instance-id "$MON" \
    --query StandardErrorContent --output text >&2
  exit 1
fi
aws ssm get-command-invocation --profile "$PROFILE" --region "$REGION" --command-id "$cmd" --instance-id "$MON" \
  --query StandardOutputContent --output text | tr -d '\n' | base64 -d | gunzip > "$OUT"
echo "written: $OUT ($(wc -c < "$OUT") bytes), 모니터링 서버 프로비저닝 폴더에도 반영됨"
