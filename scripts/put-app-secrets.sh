#!/usr/bin/env bash
# Upload KEY=VALUE lines from a dotenv file to SSM Parameter Store (SecureString)
# under /<prefix>/<env>/KEY. The backend's deploy script reads these on every deploy.
#
# Usage: ./scripts/put-app-secrets.sh <main|dev> <file.env> [--redeploy]
#
# Example main.env:
#   FRONT_URI=https://bangjjack.vercel.app
#
# Keys managed by Terraform (DB_*, REDIS_*, JAVA_OPTS, ...) are refused here so they
# don't drift from the actual infrastructure.
set -euo pipefail
export AWS_PAGER="" # aws cli v2 의 less 페이저로 결과가 사라지지 않게

ENV_NAME="${1:?usage: $0 <main|dev> <file.env> [--redeploy]}"
FILE="${2:?usage: $0 <main|dev> <file.env> [--redeploy]}"
REDEPLOY="${3:-}"
PROFILE="${AWS_PROFILE_NAME:-personal-project}"
REGION="${AWS_REGION:-ap-northeast-2}"
PREFIX="${NAME_PREFIX:-bangjjack}"
MANAGED="SPRING_PROFILES_ACTIVE APP_ENV DB_URL DB_USER DB_PASSWORD REDIS_HOST REDIS_PASSWORD SERVER_FORWARD_HEADERS_STRATEGY JAVA_OPTS SERVER_URI GOOGLE_REDIRECT_URI"

[ -f "$FILE" ] || { echo "no such file: $FILE"; exit 1; }

while IFS= read -r line || [ -n "$line" ]; do
  line="${line%$'\r'}"
  [[ -z "$line" || "$line" == \#* ]] && continue
  key="${line%%=*}"
  value="${line#*=}"
  value="${value%\"}"; value="${value#\"}"
  if [[ " $MANAGED " == *" $key "* ]]; then
    echo "skip  $key (managed by Terraform)"
    continue
  fi
  aws ssm put-parameter --profile "$PROFILE" --region "$REGION" \
    --name "/$PREFIX/$ENV_NAME/$key" --type SecureString --overwrite \
    --value "$value" >/dev/null
  echo "set   /$PREFIX/$ENV_NAME/$key"
done < "$FILE"

if [ "$REDEPLOY" = "--redeploy" ]; then
  # ECS 는 태스크 기동 시점에 SSM 파라미터를 읽으므로, 새 태스크로 교체하면 반영된다.
  aws ecs update-service --profile "$PROFILE" --region "$REGION" \
    --cluster "$PREFIX" --service "$PREFIX-$ENV_NAME-backend" --force-new-deployment \
    --query 'service.deployments[0].id' --output text
  echo "redeploy requested on ECS service $PREFIX-$ENV_NAME-backend"
fi
