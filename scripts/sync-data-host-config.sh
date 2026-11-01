#!/usr/bin/env bash
# 기존 DB/Redis 호스트에 variables.tf 의 설정값을 적용한다 (재시작 없이, 설정 파일에도 기록).
#   DB/Redis 호스트는 데이터 보호를 위해 user_data 변경을 무시하므로 terraform apply 만으로는
#   innodb_buffer_pool_size, maxmemory 가 바뀌지 않는다. 인스턴스 타입 변경은 apply 로 된다.
#
# Usage: ./scripts/sync-data-host-config.sh <main|dev>    (terraform apply 후 실행)
set -euo pipefail
export AWS_PAGER=""
cd "$(dirname "$0")/.."

ENV_NAME="${1:?usage: $0 <main|dev>}"
PROFILE="${AWS_PROFILE_NAME:-personal-project}"
REGION="${AWS_REGION:-ap-northeast-2}"
PREFIX="${NAME_PREFIX:-bangjjack}"

cfg=$(terraform output -json data_host_config | jq -c --arg e "$ENV_NAME" '.[$e]')
[ "$cfg" != "null" ] || { echo "unknown env: $ENV_NAME"; exit 1; }
BUFFER_POOL_MB=$(jq -r .mysql_buffer_pool_mb <<<"$cfg")
MAXMEMORY_MB=$(jq -r .redis_maxmemory_mb <<<"$cfg")
echo "env=$ENV_NAME innodb_buffer_pool_size=${BUFFER_POOL_MB}M redis maxmemory=${MAXMEMORY_MB}mb"

instance() { # instance <role>
  aws ec2 describe-instances --profile "$PROFILE" --region "$REGION" \
    --filters "Name=tag:Project,Values=$PREFIX" "Name=tag:Env,Values=$ENV_NAME" "Name=tag:Role,Values=$1" \
              "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text
}

run() { # run <instance> <comment> <shell command>
  local params cmd
  params=$(jq -nc --arg c "$3" '{commands: [$c]}')
  cmd=$(aws ssm send-command --profile "$PROFILE" --region "$REGION" --instance-ids "$1" \
    --document-name AWS-RunShellScript --comment "$2" \
    --parameters "$params" --query Command.CommandId --output text)
  aws ssm wait command-executed --profile "$PROFILE" --region "$REGION" --command-id "$cmd" --instance-id "$1" || true
  aws ssm get-command-invocation --profile "$PROFILE" --region "$REGION" --command-id "$cmd" --instance-id "$1" \
    --query '[Status, StandardOutputContent, StandardErrorContent]' --output text
}

DB=$(instance database); REDIS=$(instance redis)
[ "$DB" != "None" ] && [ "$REDIS" != "None" ] || { echo "$ENV_NAME database/redis must be running"; exit 1; }

echo "== MySQL ($DB)"
run "$DB" "sync buffer pool ($ENV_NAME)" "set -e
sed -i -E 's/^innodb_buffer_pool_size\s*=.*/innodb_buffer_pool_size   = ${BUFFER_POOL_MB}M/' /etc/mysql/mysql.conf.d/zz-${PREFIX}.cnf
mysql --protocol=socket -uroot -e 'SET GLOBAL innodb_buffer_pool_size = ${BUFFER_POOL_MB} * 1024 * 1024'
sleep 3
mysql --protocol=socket -uroot -N -e 'SELECT CONCAT(\"innodb_buffer_pool_size=\", @@innodb_buffer_pool_size DIV 1048576, \"M\")'
grep innodb_buffer_pool_size /etc/mysql/mysql.conf.d/zz-${PREFIX}.cnf"

echo "== Redis ($REDIS)"
run "$REDIS" "sync maxmemory ($ENV_NAME)" "set -e
sed -i -E 's/^maxmemory [0-9]+mb$/maxmemory ${MAXMEMORY_MB}mb/' /etc/redis/redis.conf
export REDISCLI_AUTH=\$(awk '/^requirepass /{print \$2}' /etc/redis/redis.conf)
redis-cli CONFIG SET maxmemory ${MAXMEMORY_MB}mb
redis-cli CONFIG GET maxmemory | tail -1 | awk '{printf \"maxmemory=%dmb\\n\", \$1/1048576}'
grep '^maxmemory ' /etc/redis/redis.conf"
