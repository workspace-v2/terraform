#!/usr/bin/env bash
# 실제 DB 의 스키마(데이터 제외)를 Flyway baseline SQL 로 추출한다.
#   기존 DB 에는 baseline-on-migrate 로 실행되지 않고, 새 DB(로컬, 새 환경)를 만들 때 쓰인다.
#
# Usage: ./scripts/dump-schema.sh <main|dev> [out=../Bangjjack-flyway/src/main/resources/db/migration/V1__baseline.sql]
set -euo pipefail
export AWS_PAGER=""
cd "$(dirname "$0")/.."

ENV_NAME="${1:?usage: $0 <main|dev> [out]}"
OUT="${2:-../Bangjjack-flyway/src/main/resources/db/migration/V1__baseline.sql}"
PROFILE="${AWS_PROFILE_NAME:-personal-project}"
REGION="${AWS_REGION:-ap-northeast-2}"
PREFIX="${NAME_PREFIX:-bangjjack}"
DB_NAME="${PREFIX//-/_}"

DB=$(aws ec2 describe-instances --profile "$PROFILE" --region "$REGION" \
  --filters "Name=tag:Project,Values=$PREFIX" "Name=tag:Env,Values=$ENV_NAME" "Name=tag:Role,Values=database" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
[ "$DB" != "None" ] || { echo "$ENV_NAME database is not running"; exit 1; }

# SSM 출력은 약 24KB 에서 잘리므로 gzip + base64 로 받는다.
# AUTO_INCREMENT 값, DEFINER, flyway_schema_history 는 제외한다.
script="set -e
mysqldump --protocol=socket -uroot --no-data --skip-comments --skip-add-drop-table --skip-add-locks \
  --skip-set-charset --single-transaction --set-gtid-purged=OFF --ignore-table=$DB_NAME.flyway_schema_history $DB_NAME \
  | sed -E -e 's/ AUTO_INCREMENT=[0-9]+//' -e '/^\\/\\*!40[0-9]{3} SET /d' -e '/^\\/\\*!50[0-9]{3} SET /d' \
  | gzip -9 | base64 -w0"
params=$(jq -nc --arg c "$script" '{commands: [$c]}')
cmd=$(aws ssm send-command --profile "$PROFILE" --region "$REGION" --instance-ids "$DB" \
  --document-name AWS-RunShellScript --comment "dump schema ($ENV_NAME)" \
  --parameters "$params" --query Command.CommandId --output text)
aws ssm wait command-executed --profile "$PROFILE" --region "$REGION" --command-id "$cmd" --instance-id "$DB" || true
status=$(aws ssm get-command-invocation --profile "$PROFILE" --region "$REGION" --command-id "$cmd" --instance-id "$DB" --query Status --output text)
if [ "$status" != "Success" ]; then
  aws ssm get-command-invocation --profile "$PROFILE" --region "$REGION" --command-id "$cmd" --instance-id "$DB" \
    --query StandardErrorContent --output text >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT")"
{
  echo "-- Flyway baseline: $ENV_NAME DB 스키마 덤프 ($(date +%F), scripts/dump-schema.sh)"
  echo "-- 기존 DB(main/dev)는 baseline-on-migrate 로 이 파일을 실행하지 않는다. 새 DB 를 만들 때만 실행된다."
  echo
  aws ssm get-command-invocation --profile "$PROFILE" --region "$REGION" --command-id "$cmd" --instance-id "$DB" \
    --query StandardOutputContent --output text | tr -d '\n' | base64 -d | gunzip
} > "$OUT"
echo "written: $OUT ($(grep -c '^CREATE TABLE' "$OUT") tables)"
