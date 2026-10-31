#!/bin/bash
# Usage: <prefix>-deploy <image>
# Pulls the image, renders the env file from SSM Parameter Store, swaps the container,
# waits for /actuator/health and rolls back to the previous image on failure.
set -euo pipefail
source __CONF__

IMAGE="${1:?usage: $0 <image>}"
AWS=/snap/bin/aws
ENV_FILE="$APP_DIR/app.env"
HEALTH_URL="http://127.0.0.1:8081/actuator/health"
log() { echo "[deploy $(date '+%F %T')] $*"; }

exec 9>/var/lock/app-deploy.lock
flock -w 600 9 || { log "another deploy is running"; exit 1; }

log "env=$APP_ENV image=$IMAGE"

# 1) Environment variables from SSM Parameter Store (/<prefix>/<env>/KEY -> KEY=value)
tmp=$(mktemp)
$AWS ssm get-parameters-by-path --region "$AWS_REGION" --path "$PARAM_PATH" \
  --recursive --with-decryption --output json \
  | jq -r '.Parameters[] | "\(.Name | split("/") | last)=\(.Value)"' > "$tmp"
if [ ! -s "$tmp" ]; then log "no parameters under $PARAM_PATH"; rm -f "$tmp"; exit 1; fi
placeholders=$(grep -E '=CHANGE_ME$' "$tmp" | cut -d= -f1 | tr '\n' ' ' || true)
[ -n "$placeholders" ] && log "WARN placeholder values still set: $placeholders"
install -m 600 "$tmp" "$ENV_FILE"
rm -f "$tmp"

# 2) Pull
registry="${IMAGE%%/*}"
if [[ "$registry" == *.amazonaws.com ]]; then
  $AWS ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$registry" >/dev/null
fi
docker pull "$IMAGE"

previous=$(docker inspect --format '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null || true)

start() {
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  docker run -d --name "$CONTAINER_NAME" --restart unless-stopped \
    --env-file "$ENV_FILE" \
    -p 8080:8080 -p 8081:8081 \
    --label "env=$APP_ENV" \
    "$1" >/dev/null
}

healthy() {
  for _ in $(seq 1 60); do
    if curl -fsS -m 3 "$HEALTH_URL" 2>/dev/null | grep -q '"status":"UP"'; then return 0; fi
    if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)" != "true" ]; then
      log "container exited"; return 1
    fi
    sleep 3
  done
  return 1
}

# 3) Swap + health check
start "$IMAGE"
if healthy; then
  log "healthy: $IMAGE"
  docker image prune -af --filter "until=168h" >/dev/null || true
  exit 0
fi

log "health check failed - last logs:"
docker logs --tail 150 "$CONTAINER_NAME" 2>&1 || true

if [ -n "$previous" ] && [ "$previous" != "$IMAGE" ]; then
  log "rolling back to $previous"
  start "$previous"
  healthy && log "rollback healthy" || log "rollback also unhealthy"
fi
exit 1
