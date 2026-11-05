#!/usr/bin/env bash
# Sourced by Burgerpedia operational scripts; never prints secrets or changes infrastructure.
set -euo pipefail
export AWS_PAGER=""
BURGER_TF_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BURGER_CONFIG=$(cd "$BURGER_TF_ROOT" && terraform output -json burger_deployment)
BURGER_REGION=$(jq -er .region <<< "$BURGER_CONFIG")
BURGER_PROFILE="${AWS_PROFILE_NAME:-personal-project}"
burger_aws() { aws --profile "$BURGER_PROFILE" --region "$BURGER_REGION" "$@"; }
burger_value() { jq -er "$1" <<< "$BURGER_CONFIG"; }
burger_ssm() {
  local instance="$1" script="$2" params id status
  params=$(jq -nc --arg script "$script" '{commands:[$script],executionTimeout:["900"]}')
  id=$(burger_aws ssm send-command --instance-ids "$instance" --document-name AWS-RunShellScript \
    --parameters "$params" --query Command.CommandId --output text)
  for _ in $(seq 1 180); do
    status=$(burger_aws ssm get-command-invocation --command-id "$id" --instance-id "$instance" --query Status --output text 2>/dev/null || true)
    case "$status" in
      Success) return 0 ;;
      Failed|Cancelled|TimedOut|Cancelling)
        burger_aws ssm get-command-invocation --command-id "$id" --instance-id "$instance" --query '[Status,StandardOutputContent,StandardErrorContent]' --output text >&2
        return 1 ;;
    esac
    sleep 5
  done
  echo "SSM command timed out: $id" >&2
  return 1
}

# ECS RUNNING does not guarantee that ALB registration and application startup are complete.
burger_wait_for_api() {
  local url="$1" attempt status="000"
  echo "Waiting for public API readiness: $url"
  for attempt in $(seq 1 60); do
    if status=$(curl --silent --output /dev/null --write-out '%{http_code}' \
      --connect-timeout 5 --max-time 5 "$url") && [ "$status" = 200 ]; then
      return 0
    fi
    if [ "$((attempt % 6))" = 0 ]; then
      echo "Still waiting for API readiness ($attempt/60, HTTP $status)."
    fi
    [ "$attempt" = 60 ] || sleep 5
  done
  echo "Public API did not become ready (HTTP $status). Servers remain running; inspect ECS events and ALB target health." >&2
  return 1
}
