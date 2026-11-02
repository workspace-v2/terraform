#!/usr/bin/env bash
# S3 백업으로 모니터링 데이터(Prometheus TSDB + Grafana DB)를 복원한다 (SSM).
# 기존 데이터는 지우지 않고 <volume>/_data.before-restore-<시각> 으로 옮겨 둔다.
# Usage: ./scripts/monitoring-restore.sh [S3 키, 기본 monitoring/latest.tar.gz]
#   백업 목록: aws s3 ls s3://bangjjack-monitoring-backup-<account>/monitoring/
set -euo pipefail
export AWS_PAGER=""
cd "$(dirname "$0")/.."
PROFILE="${AWS_PROFILE_NAME:-personal-project}"
REGION="${AWS_REGION:-ap-northeast-2}"
PREFIX="${NAME_PREFIX:-bangjjack}"
KEY="${1:-monitoring/latest.tar.gz}"

ACCOUNT=$(aws sts get-caller-identity --profile "$PROFILE" --query Account --output text)
BUCKET="${PREFIX}-monitoring-backup-${ACCOUNT}"
MON=$(aws ec2 describe-instances --profile "$PROFILE" --region "$REGION" \
  --filters "Name=tag:Project,Values=$PREFIX" "Name=tag:Role,Values=monitoring" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
[ "$MON" != "None" ] || { echo "monitoring is not running"; exit 1; }
TS=$(date +%Y%m%d-%H%M%S)

remote="set -eu
V=/var/lib/docker/volumes
F=/tmp/restore-${TS}.tar.gz
trap 'docker start prometheus grafana >/dev/null 2>&1 || true; rm -f \$F' EXIT
docker run --rm --network host -v /tmp:/tmp amazon/aws-cli s3 cp s3://${BUCKET}/${KEY} \$F --region ${REGION} --only-show-errors
docker stop prometheus grafana >/dev/null
for v in prometheus-data grafana-data; do
  [ -d \$V/\$v/_data ] && mv \$V/\$v/_data \$V/\$v/_data.before-restore-${TS}
done
tar -C \$V -xzf \$F
docker start prometheus grafana >/dev/null
echo restored s3://${BUCKET}/${KEY}"

params=$(jq -nc --arg c "$remote" '{commands: [$c], executionTimeout: ["3600"]}')
cmd=$(aws ssm send-command --profile "$PROFILE" --region "$REGION" --instance-ids "$MON" \
  --document-name AWS-RunShellScript --comment "monitoring restore $TS" --timeout-seconds 3600 \
  --parameters "$params" --query Command.CommandId --output text)
echo "restore running on $MON (command $cmd) ..."
while :; do
  st=$(aws ssm get-command-invocation --profile "$PROFILE" --region "$REGION" --command-id "$cmd" --instance-id "$MON" --query Status --output text 2>/dev/null || echo Pending)
  case "$st" in Pending|InProgress|Delayed) sleep 5 ;; *) break ;; esac
done
aws ssm get-command-invocation --profile "$PROFILE" --region "$REGION" --command-id "$cmd" --instance-id "$MON" \
  --query '[StandardOutputContent, StandardErrorContent]' --output text
[ "$st" = "Success" ] || { echo "restore failed: $st"; exit 1; }
