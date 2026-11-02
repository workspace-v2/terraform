#!/usr/bin/env bash
# 모니터링 데이터(Prometheus TSDB + Grafana DB)를 S3 에 백업한다 (SSM, SSH 불필요).
#   s3://<bucket>/monitoring/<시각>.tar.gz  와  monitoring/latest.tar.gz (버킷 버전 관리로 이전 것도 남음)
# 일관된 스냅샷을 위해 백업하는 동안(수십 초~수 분) prometheus, grafana 컨테이너를 잠시 멈춘다.
#   측정 중에는 실행하지 말 것 (그 사이 k6 지표가 기록되지 않는다).
# Usage: ./scripts/monitoring-backup.sh [로컬에도 받을 폴더]
#   예) ./scripts/monitoring-backup.sh ~/Desktop/monitoring-backup
set -euo pipefail
export AWS_PAGER=""
cd "$(dirname "$0")/.."
PROFILE="${AWS_PROFILE_NAME:-personal-project}"
REGION="${AWS_REGION:-ap-northeast-2}"
PREFIX="${NAME_PREFIX:-bangjjack}"
LOCAL_DIR="${1:-}"

ACCOUNT=$(aws sts get-caller-identity --profile "$PROFILE" --query Account --output text)
BUCKET="${PREFIX}-monitoring-backup-${ACCOUNT}"
MON=$(aws ec2 describe-instances --profile "$PROFILE" --region "$REGION" \
  --filters "Name=tag:Project,Values=$PREFIX" "Name=tag:Role,Values=monitoring" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
[ "$MON" != "None" ] || { echo "monitoring is not running (./scripts/env-power.sh monitoring start)"; exit 1; }
TS=$(date +%Y%m%d-%H%M%S)
KEY="monitoring/${TS}.tar.gz"

remote="set -eu
V=/var/lib/docker/volumes
F=/tmp/monitoring-${TS}.tar.gz
trap 'docker start prometheus grafana >/dev/null 2>&1 || true; rm -f \$F' EXIT
docker stop prometheus grafana >/dev/null
tar -C \$V -czf \$F prometheus-data/_data grafana-data/_data
docker start prometheus grafana >/dev/null
ls -lh \$F | awk '{print \"archive size:\", \$5}'
aws() { docker run --rm --network host -v /tmp:/tmp amazon/aws-cli \"\$@\"; }
aws s3 cp \$F s3://${BUCKET}/${KEY} --region ${REGION} --only-show-errors
aws s3 cp \$F s3://${BUCKET}/monitoring/latest.tar.gz --region ${REGION} --only-show-errors
echo uploaded s3://${BUCKET}/${KEY}"

params=$(jq -nc --arg c "$remote" '{commands: [$c], executionTimeout: ["3600"]}')
cmd=$(aws ssm send-command --profile "$PROFILE" --region "$REGION" --instance-ids "$MON" \
  --document-name AWS-RunShellScript --comment "monitoring backup $TS" --timeout-seconds 3600 \
  --parameters "$params" --query Command.CommandId --output text)
echo "backup running on $MON (command $cmd) ..."
while :; do
  st=$(aws ssm get-command-invocation --profile "$PROFILE" --region "$REGION" --command-id "$cmd" --instance-id "$MON" --query Status --output text 2>/dev/null || echo Pending)
  case "$st" in Pending|InProgress|Delayed) sleep 5 ;; *) break ;; esac
done
aws ssm get-command-invocation --profile "$PROFILE" --region "$REGION" --command-id "$cmd" --instance-id "$MON" \
  --query '[StandardOutputContent, StandardErrorContent]' --output text
[ "$st" = "Success" ] || { echo "backup failed: $st"; exit 1; }

aws s3 ls "s3://${BUCKET}/monitoring/" --profile "$PROFILE" --region "$REGION" --human-readable | tail -5
if [ -n "$LOCAL_DIR" ]; then
  mkdir -p "$LOCAL_DIR"
  aws s3 cp "s3://${BUCKET}/${KEY}" "$LOCAL_DIR/" --profile "$PROFILE" --region "$REGION"
  echo "local copy: $LOCAL_DIR/${TS}.tar.gz"
fi
