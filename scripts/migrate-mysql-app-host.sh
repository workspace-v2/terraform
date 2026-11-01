#!/usr/bin/env bash
# ECS 전환 1회성 작업: MySQL 앱 계정 접속 허용 호스트를 이전 EC2 백엔드 고정 IP에서
# VPC 대역 와일드카드(예: '10.20.%')로 넓힌다. ECS 태스크 IP가 동적이기 때문이다.
#
# DB 호스트는 user_data 변경을 무시(데이터 보호)하므로 기존 DB에는 이 스크립트로 적용한다.
# 비밀번호는 다루지 않는다: 기존 계정의 인증 해시를 그대로 복사해 새 호스트 계정을 만든다.
# 실제 접근 제어는 보안 그룹(백엔드 태스크 SG -> DB SG 3306)이 한다.
#
# Usage: ./scripts/migrate-mysql-app-host.sh <main|dev>
#   terraform apply 전에 실행해도 되고(새 계정 추가만 함), 이전 계정은 남겨 둔다.
set -euo pipefail
export AWS_PAGER="" # aws cli v2 의 less 페이저로 결과가 사라지지 않게
cd "$(dirname "$0")/.."

ENV_NAME="${1:?usage: $0 <main|dev>}"
PROFILE="${AWS_PROFILE_NAME:-personal-project}"
REGION="${AWS_REGION:-ap-northeast-2}"
PREFIX="${NAME_PREFIX:-bangjjack}"

DB_USER="${PREFIX//-/_}"
DB_NAME="${PREFIX//-/_}"
VPC_CIDR="${VPC_CIDR:-10.20.0.0/16}"
APP_HOST="$(echo "$VPC_CIDR" | cut -d. -f1-2).%"

case "$ENV_NAME" in
  main) IP_BASE=10 ;;
  dev)  IP_BASE=20 ;;
  *) echo "unknown env: $ENV_NAME"; exit 1 ;;
esac
SUBNET_PREFIX="$(echo "$VPC_CIDR" | cut -d. -f1-2).1"
LEGACY_HOST="${SUBNET_PREFIX}.$((IP_BASE + 1))"

instance_id=$(aws ec2 describe-instances --profile "$PROFILE" --region "$REGION" \
  --filters "Name=tag:Project,Values=$PREFIX" "Name=tag:Env,Values=$ENV_NAME" "Name=tag:Role,Values=database" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
[ "$instance_id" != "None" ] || { echo "running $ENV_NAME database instance not found"; exit 1; }

echo "env=$ENV_NAME db=$instance_id user=$DB_USER '$LEGACY_HOST' -> '$APP_HOST'"

read -r -d '' SQL <<SQL || true
SELECT plugin, HEX(authentication_string) INTO @plugin, @hash FROM mysql.user WHERE user='${DB_USER}' AND host='${LEGACY_HOST}';
SET @create = CONCAT("CREATE USER IF NOT EXISTS '${DB_USER}'@'${APP_HOST}' IDENTIFIED WITH ", @plugin, " AS 0x", @hash);
PREPARE stmt FROM @create; EXECUTE stmt; DEALLOCATE PREPARE stmt;
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'${APP_HOST}';
FLUSH PRIVILEGES;
SELECT user, host, plugin FROM mysql.user WHERE user='${DB_USER}';
SQL

params=$(jq -n --arg sql "$SQL" '{commands: ["mysql --protocol=socket -uroot <<'"'"'SQL_EOF'"'"'\n" + $sql + "\nSQL_EOF"]}')

command_id=$(aws ssm send-command --profile "$PROFILE" --region "$REGION" \
  --instance-ids "$instance_id" --document-name AWS-RunShellScript \
  --comment "migrate mysql app host ($ENV_NAME)" \
  --parameters "$params" --query 'Command.CommandId' --output text)

aws ssm wait command-executed --profile "$PROFILE" --region "$REGION" \
  --command-id "$command_id" --instance-id "$instance_id" || true
aws ssm get-command-invocation --profile "$PROFILE" --region "$REGION" \
  --command-id "$command_id" --instance-id "$instance_id" \
  --query '[Status, StandardOutputContent, StandardErrorContent]' --output text
