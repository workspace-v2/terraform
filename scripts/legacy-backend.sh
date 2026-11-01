#!/usr/bin/env bash
# 기존 EC2 단일 서버 백엔드(one-<env>) 관리.
#
# Usage:
#   ./scripts/legacy-backend.sh <main|dev> start            # 켜기 (DB·Redis 가 켜져 있어야 앱이 뜬다)
#   ./scripts/legacy-backend.sh <main|dev> stop             # 끄기
#     terraform apply 를 하면 legacy_backend_state(기본 stopped)로 돌아간다.
#   ./scripts/legacy-backend.sh <main|dev> caddy            # Caddy 사이트 주소를 one-<env>.<domain>, <EIP>.nip.io 로 변경
#   ./scripts/legacy-backend.sh <main|dev> deploy <tag>     # ECR <tag> 이미지로 배포 (예: main-<git sha>, main-latest)
#   ./scripts/legacy-backend.sh <main|dev> status
#
# 단일 서버 vs ECS 비교 측정은 두 쪽에 같은 이미지 태그를 배포한 뒤, 한 번에 한쪽만 켜고 측정한다
# (같은 DB/Redis 를 쓰므로 동시에 켜면 결과가 섞인다).
set -euo pipefail
export AWS_PAGER="" # aws cli v2 의 less 페이저로 결과가 사라지지 않게
cd "$(dirname "$0")/.."

ENV_NAME="${1:?usage: $0 <main|dev> <start|stop|caddy|deploy <tag>|status>}"
ACTION="${2:?usage: $0 <main|dev> <start|stop|caddy|deploy <tag>|status>}"
PROFILE="${AWS_PROFILE_NAME:-personal-project}"
REGION="${AWS_REGION:-ap-northeast-2}"
PREFIX="${NAME_PREFIX:-bangjjack}"
DOMAIN="${DOMAIN_NAME:-pattie.cloud}"

read -r INSTANCE_ID STATE PUBLIC_IP < <(aws ec2 describe-instances --profile "$PROFILE" --region "$REGION" \
  --filters "Name=tag:Project,Values=$PREFIX" "Name=tag:Env,Values=$ENV_NAME" "Name=tag:Role,Values=backend" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[0].Instances[0].[InstanceId, State.Name, PublicIpAddress]' --output text)
[ "$INSTANCE_ID" != "None" ] || { echo "$ENV_NAME legacy backend instance not found"; exit 1; }

run() { # run <comment> <shell command>
  local params cmd
  params=$(jq -nc --arg c "$2" '{commands: [$c]}')
  cmd=$(aws ssm send-command --profile "$PROFILE" --region "$REGION" --instance-ids "$INSTANCE_ID" \
    --document-name AWS-RunShellScript --comment "$1" --timeout-seconds 900 \
    --parameters "$params" --query Command.CommandId --output text)
  aws ssm wait command-executed --profile "$PROFILE" --region "$REGION" \
    --command-id "$cmd" --instance-id "$INSTANCE_ID" || true
  aws ssm get-command-invocation --profile "$PROFILE" --region "$REGION" \
    --command-id "$cmd" --instance-id "$INSTANCE_ID" \
    --query '[Status, StandardOutputContent, StandardErrorContent]' --output text
}

require_running() {
  [ "$STATE" = "running" ] || {
    echo "instance $INSTANCE_ID is $STATE. 먼저: ./scripts/legacy-backend.sh $ENV_NAME start"
    exit 1
  }
}

case "$ACTION" in
  start)
    aws ec2 start-instances --profile "$PROFILE" --region "$REGION" --instance-ids "$INSTANCE_ID" >/dev/null
    aws ec2 wait instance-running --profile "$PROFILE" --region "$REGION" --instance-ids "$INSTANCE_ID"
    echo "one-$ENV_NAME ($INSTANCE_ID) running. 앱(Docker) 기동까지 1~2분. https://one-${ENV_NAME}.${DOMAIN}"
    ;;
  stop)
    aws ec2 stop-instances --profile "$PROFILE" --region "$REGION" --instance-ids "$INSTANCE_ID" >/dev/null
    echo "one-$ENV_NAME ($INSTANCE_ID) stopping"
    ;;
  caddy)
    require_running
    SITES="one-${ENV_NAME}.${DOMAIN}, ${PUBLIC_IP}.nip.io"
    echo "Caddy sites -> $SITES"
    run "legacy caddy domain ($ENV_NAME)" "$(cat <<SH
set -e
cat > /etc/caddy/Caddyfile <<'CADDY_EOF'
${SITES} {
	encode gzip
	reverse_proxy 127.0.0.1:8080
	log {
		output file /var/log/caddy/access.log {
			roll_size 50MiB
			roll_keep 5
		}
	}
}
CADDY_EOF
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
systemctl reload caddy
echo "caddy reloaded"
SH
)"
    ;;
  deploy)
    require_running
    TAG="${3:?usage: $0 <main|dev> deploy <image-tag>}"
    REPO=$(aws ecr describe-repositories --profile "$PROFILE" --region "$REGION" \
      --repository-names "$PREFIX-backend" --query 'repositories[0].repositoryUri' --output text)
    echo "deploy $REPO:$TAG -> $INSTANCE_ID"
    run "legacy deploy ($ENV_NAME $TAG)" "/usr/local/bin/${PREFIX}-deploy ${REPO}:${TAG}"
    ;;
  status)
    echo "instance=$INSTANCE_ID state=$STATE public_ip=$PUBLIC_IP url=https://one-${ENV_NAME}.${DOMAIN}"
    ;;
  *) echo "unknown action: $ACTION"; exit 1 ;;
esac
