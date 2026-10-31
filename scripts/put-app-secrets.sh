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

ENV_NAME="${1:?usage: $0 <main|dev> <file.env> [--redeploy]}"
FILE="${2:?usage: $0 <main|dev> <file.env> [--redeploy]}"
REDEPLOY="${3:-}"
PROFILE="${AWS_PROFILE_NAME:-personal-project}"
REGION="${AWS_REGION:-ap-northeast-2}"
PREFIX="${NAME_PREFIX:-bangjjack}"
MANAGED="SPRING_PROFILES_ACTIVE APP_ENV DB_URL DB_USER DB_PASSWORD REDIS_HOST REDIS_PASSWORD SERVER_FORWARD_HEADERS_STRATEGY JAVA_OPTS"

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
  instance=$(aws ec2 describe-instances --profile "$PROFILE" --region "$REGION" \
    --filters "Name=tag:Project,Values=$PREFIX" "Name=tag:Env,Values=$ENV_NAME" \
              "Name=tag:Role,Values=backend" "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].InstanceId' --output text)
  image=$(aws ecr describe-repositories --profile "$PROFILE" --region "$REGION" \
    --repository-names "$PREFIX-backend" --query 'repositories[0].repositoryUri' --output text):$ENV_NAME-latest
  cmd=$(aws ssm send-command --profile "$PROFILE" --region "$REGION" --instance-ids "$instance" \
    --document-name AWS-RunShellScript --comment "restart with new secrets" \
    --parameters "{\"commands\":[\"/usr/local/bin/$PREFIX-deploy $image\"]}" \
    --query Command.CommandId --output text)
  echo "redeploy requested on $instance (command $cmd)"
fi
