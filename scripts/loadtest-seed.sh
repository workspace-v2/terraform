#!/usr/bin/env bash
# 채팅 측정용 테스트 사용자를 DB 에 만들고, 사용자 ID 목록과 DEV_SECRET 을 부하 발생기에 전달한다.
#   사용자: provider_id 'loadtest-00001' ... (이미 있으면 그대로 둔다)
#   채팅방은 k6 setup() 이 API 로 만든다 (이미 있으면 기존 방 사용).
#
# Usage:
#   ./scripts/loadtest-seed.sh <main|dev> [users=200]
#   ./scripts/loadtest-seed.sh <main|dev> reset     # 테스트 사용자의 채팅 메시지/방 삭제 (사용자는 유지)
set -euo pipefail
export AWS_PAGER=""
cd "$(dirname "$0")/.."

ENV_NAME="${1:?usage: $0 <main|dev> [users|reset]}"
ARG="${2:-200}"
PROFILE="${AWS_PROFILE_NAME:-personal-project}"
REGION="${AWS_REGION:-ap-northeast-2}"
PREFIX="${NAME_PREFIX:-bangjjack}"
DB_NAME="${PREFIX//-/_}"

instance() { # instance <role> [env]
  local filters=("Name=tag:Project,Values=$PREFIX" "Name=tag:Role,Values=$1" "Name=instance-state-name,Values=running")
  [ -n "${2:-}" ] && filters+=("Name=tag:Env,Values=$2")
  aws ec2 describe-instances --profile "$PROFILE" --region "$REGION" --filters "${filters[@]}" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text
}

run() { # run <instance> <comment> <shell command>  -> stdout
  local params cmd status
  params=$(jq -nc --arg c "$3" '{commands: [$c]}')
  cmd=$(aws ssm send-command --profile "$PROFILE" --region "$REGION" --instance-ids "$1" \
    --document-name AWS-RunShellScript --comment "$2" --parameters "$params" --query Command.CommandId --output text)
  aws ssm wait command-executed --profile "$PROFILE" --region "$REGION" --command-id "$cmd" --instance-id "$1" || true
  status=$(aws ssm get-command-invocation --profile "$PROFILE" --region "$REGION" --command-id "$cmd" --instance-id "$1" --query Status --output text)
  if [ "$status" != "Success" ]; then
    aws ssm get-command-invocation --profile "$PROFILE" --region "$REGION" --command-id "$cmd" --instance-id "$1" \
      --query '[StandardOutputContent, StandardErrorContent]' --output text >&2
    echo "[$2] $status" >&2; exit 1
  fi
  aws ssm get-command-invocation --profile "$PROFILE" --region "$REGION" --command-id "$cmd" --instance-id "$1" \
    --query StandardOutputContent --output text
}

DB=$(instance database "$ENV_NAME")
[ "$DB" != "None" ] || { echo "$ENV_NAME database is not running"; exit 1; }

LT_USERS="SELECT id FROM users WHERE provider_id LIKE 'loadtest-%'"
LT_ROOMS="SELECT DISTINCT room_id FROM chat_room_participant WHERE user_id IN ($LT_USERS)"

if [ "$ARG" = "reset" ]; then
  echo "== $ENV_NAME: 테스트 사용자의 채팅 메시지/참여자/방 삭제"
  run "$DB" "loadtest reset ($ENV_NAME)" "mysql --protocol=socket -uroot $DB_NAME <<'SQL'
CREATE TEMPORARY TABLE lt_rooms AS $LT_ROOMS;
DELETE FROM chat WHERE room_id IN (SELECT room_id FROM lt_rooms);
DELETE FROM chat_room_participant WHERE room_id IN (SELECT room_id FROM lt_rooms);
DELETE FROM chat_room WHERE id IN (SELECT room_id FROM lt_rooms);
SELECT CONCAT('deleted rooms: ', COUNT(*)) FROM lt_rooms;
SQL"
  echo "주의: 실행 중인 서버의 WebSocket 구독 캐시는 남아 있으므로, 다음 측정 전 재연결만 하면 된다 (k6 가 새로 연결)."
  exit 0
fi

USERS="$ARG"
[[ "$USERS" =~ ^[0-9]+$ ]] && [ "$USERS" -ge 2 ] || { echo "users must be a number >= 2"; exit 1; }

echo "== $ENV_NAME: 테스트 사용자 ${USERS}명 준비"
ids=$(run "$DB" "loadtest seed ($ENV_NAME)" "mysql --protocol=socket -uroot -N $DB_NAME <<'SQL'
SET SESSION cte_max_recursion_depth = 100000;
SET SESSION group_concat_max_len = 10000000;
INSERT IGNORE INTO users (provider_id, username, email, is_onboarded, is_checklist_registered,
                          is_roommate_preference_registered, created_at, updated_at, deleted)
WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < $USERS)
SELECT CONCAT('loadtest-', LPAD(n, 5, '0')), CONCAT('lt', n), CONCAT('lt', n, '@loadtest.local'),
       0, 0, 0, NOW(), NOW(), 0
FROM seq;
SELECT GROUP_CONCAT(id ORDER BY provider_id) FROM (
  SELECT id, provider_id FROM users
  WHERE provider_id LIKE 'loadtest-%' AND deleted = 0
  ORDER BY provider_id LIMIT $USERS
) t;
SQL" | tr -d '[:space:]')
count=$(tr ',' '\n' <<<"$ids" | grep -c .)
echo "users: $count (first ids: ${ids:0:40}...)"

SECRET=$(aws ssm get-parameter --profile "$PROFILE" --region "$REGION" --with-decryption \
  --name "/$PREFIX/$ENV_NAME/DEV_SECRET" --query Parameter.Value --output text)

LG=$(instance load-generator)
[ "$LG" != "None" ] || { echo "load generator is not running (./scripts/env-power.sh load-generator start)"; exit 1; }
echo "== load generator($LG) 에 사용자 목록 / DEV_SECRET 전달"
run "$LG" "loadtest data ($ENV_NAME)" "set -e
mkdir -p /opt/loadtest/data
echo '[$ids]' > /opt/loadtest/data/users-$ENV_NAME.json
printf '%s' '$SECRET' > /opt/loadtest/data/$ENV_NAME.secret
chmod -R a+rwX /opt/loadtest
echo \"users-$ENV_NAME.json: \$(tr ',' '\n' < /opt/loadtest/data/users-$ENV_NAME.json | wc -l) ids\"" >/dev/null
echo "done. 부하 발생기에서: PAIRS=$((count / 2)) chattest $ENV_NAME"
