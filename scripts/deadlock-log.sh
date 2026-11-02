#!/usr/bin/env bash
# MySQL 데드락 원인 확인용 (SSM, SSH 불필요).
# Usage:
#   ./scripts/deadlock-log.sh <main|dev> on      # 이후 모든 데드락을 MySQL 에러 로그에 기록 (재시작 시 초기화)
#   ./scripts/deadlock-log.sh <main|dev> latest  # 마지막 데드락 1건 (SHOW ENGINE INNODB STATUS)
#   ./scripts/deadlock-log.sh <main|dev> all [N] # 에러 로그에 쌓인 데드락 중 최근 N건 (기본 3)
set -euo pipefail
export AWS_PAGER=""
cd "$(dirname "$0")/.."
PROFILE="${AWS_PROFILE_NAME:-personal-project}"
REGION="${AWS_REGION:-ap-northeast-2}"
PREFIX="${NAME_PREFIX:-bangjjack}"
ENV_NAME="${1:?usage: deadlock-log.sh <main|dev> <on|latest|all> [N]}"
ACTION="${2:-latest}"
N="${3:-3}"

DB=$(aws ec2 describe-instances --profile "$PROFILE" --region "$REGION" \
  --filters "Name=tag:Project,Values=$PREFIX" "Name=tag:Env,Values=$ENV_NAME" "Name=tag:Role,Values=database" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
[ "$DB" != "None" ] || { echo "$ENV_NAME database is not running"; exit 1; }

case "$ACTION" in
  on)
    remote="mysql --protocol=socket -uroot -e \"SET GLOBAL innodb_print_all_deadlocks=ON; SHOW GLOBAL VARIABLES LIKE 'innodb_print_all_deadlocks';\"" ;;
  latest)
    remote="mysql --protocol=socket -uroot -e 'SHOW ENGINE INNODB STATUS\\G' | sed -n '/LATEST DETECTED DEADLOCK/,/^TRANSACTIONS\$/p' | head -c 20000" ;;
  all)
    remote="log=\$(mysql --protocol=socket -uroot -N -e 'SELECT @@log_error'); [ \"\$log\" = stderr ] && log=/var/log/mysql/error.log; \
awk '/TRANSACTION|WAITING FOR THIS LOCK|HOLDS THE LOCK|WE ROLL BACK|Transactions deadlock detected|^(INSERT|UPDATE|DELETE|SELECT|insert|update|delete|select)/' \"\$log\" | tail -n \$(( $N * 40 )) | head -c 20000" ;;
  *) echo "unknown action: $ACTION"; exit 1 ;;
esac

params=$(jq -nc --arg c "$remote" '{commands: [$c]}')
cmd=$(aws ssm send-command --profile "$PROFILE" --region "$REGION" --instance-ids "$DB" \
  --document-name AWS-RunShellScript --comment "deadlock $ACTION" --parameters "$params" \
  --query Command.CommandId --output text)
aws ssm wait command-executed --profile "$PROFILE" --region "$REGION" --command-id "$cmd" --instance-id "$DB" 2>/dev/null || true
aws ssm get-command-invocation --profile "$PROFILE" --region "$REGION" --command-id "$cmd" --instance-id "$DB" \
  --query '[Status, StandardOutputContent, StandardErrorContent]' --output text
