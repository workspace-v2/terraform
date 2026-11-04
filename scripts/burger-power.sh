#!/usr/bin/env bash
# Usage: burger-power.sh <main|dev|all> <start|stop|status>
# 'all' means Burgerpedia main+dev ONLY. Shared monitoring/load-generator never stop here.
set -euo pipefail
selected="${1:-}"; action="${2:-}"
case "$selected" in main|dev|all) ;; *) echo "usage: $0 <main|dev|all> <start|stop|status>" >&2; exit 2 ;; esac
case "$action" in start|stop|status) ;; *) echo "unknown action: $action" >&2; exit 2 ;; esac
source "$(dirname "$0")/burger-common.sh"

power() {
  local env="$1" service db redis arn count saved tasks remaining ids state
  service=$(burger_value ".environments.$env.service")
  db=$(burger_value ".environments.$env.database_id")
  redis=$(burger_value ".environments.$env.redis_id")
  if [ "$action" = status ]; then
    burger_aws ec2 describe-instances --instance-ids "$db" "$redis" --query 'Reservations[].Instances[].{id:InstanceId,state:State.Name,name:Tags[?Key==`Name`]|[0].Value}' --output table
    burger_aws ecs describe-services --cluster burger --services "$service" --query 'services[].{service:serviceName,desired:desiredCount,running:runningCount,pending:pendingCount}' --output table
    return
  fi
  # Fail closed if CodeDeploy cannot be queried. Never power off during a traffic shift.
  ids=$(burger_aws deploy list-deployments --application-name burger --deployment-group-name "burger-$env" \
    --include-only-statuses Created Queued InProgress Ready Baking --query deployments --output json)
  [ "$(jq length <<< "$ids")" = 0 ] || { echo "Active deployment in $env; power operation refused." >&2; return 1; }
  arn=$(burger_aws ecs describe-services --cluster burger --services "$service" --query 'services[?status==`ACTIVE`]|[0].serviceArn' --output text)
  [ -n "$arn" ] && [ "$arn" != None ] || { echo "Service not created; finish bootstrap first." >&2; return 1; }
  if [ "$action" = stop ]; then
    count=$(burger_aws ecs describe-services --cluster burger --services "$service" --query 'services[0].desiredCount' --output text)
    if [ "$count" -gt 0 ]; then
      burger_aws ecs tag-resource --resource-arn "$arn" --tags "key=PowerOffDesiredCount,value=$count"
    fi
    tasks=$(burger_aws ecs list-tasks --cluster burger --service-name "$service" --query taskArns --output json)
    burger_aws ecs update-service --cluster burger --service "$service" --desired-count 0 >/dev/null
    # Wait for actual STOPPED, including graceful shutdown, before stopping dependencies.
    if [ "$(jq length <<< "$tasks")" -gt 0 ]; then
      read -r -a ids <<< "$(jq -r 'join(" ")' <<< "$tasks")"
      remaining=1
      for _ in $(seq 1 120); do
        remaining=$(burger_aws ecs describe-tasks --cluster burger --tasks "${ids[@]}" --query 'length(tasks[?lastStatus!=`STOPPED`])' --output text)
        [ "$remaining" = 0 ] && break
        sleep 5
      done
      [ "$remaining" = 0 ] || { echo "Tasks still stopping; data servers left running." >&2; return 1; }
    fi
    # Re-check after scaling to catch unexpected tasks before stopping databases.
    remaining=$(burger_aws ecs list-tasks --cluster burger --service-name "$service" --query 'length(taskArns)' --output text)
    [ "$remaining" = 0 ] || { echo "Tasks still exist; data servers left running." >&2; return 1; }
    burger_aws ec2 stop-instances --instance-ids "$db" "$redis" >/dev/null
    burger_aws ec2 wait instance-stopped --instance-ids "$db" "$redis"
    echo "Burgerpedia $env stopped. Shared hosts, ALBs and stored data remain."
  else
    for id in "$db" "$redis"; do
      state=$(burger_aws ec2 describe-instances --instance-ids "$id" --query 'Reservations[0].Instances[0].State.Name' --output text)
      if [ "$state" = stopping ]; then burger_aws ec2 wait instance-stopped --instance-ids "$id"; state=stopped; fi
      case "$state" in
        stopped) burger_aws ec2 start-instances --instance-ids "$id" >/dev/null ;;
        running|pending) ;;
        *) echo "Unexpected instance state $state: $id" >&2; return 1 ;;
      esac
    done
    burger_aws ec2 wait instance-status-ok --instance-ids "$db" "$redis"
    burger_ssm "$db" 'set -eu; cloud-init status --wait; systemctl is-active --quiet mysql'
    burger_ssm "$redis" 'set -eu; cloud-init status --wait; systemctl is-active --quiet redis-server'
    saved=$(burger_aws ecs list-tags-for-resource --resource-arn "$arn" --query 'tags[?key==`PowerOffDesiredCount`].value|[0]' --output text)
    case "$saved" in ''|None) saved=1 ;; esac
    [[ "$saved" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid saved desired count" >&2; return 1; }
    burger_aws ecs update-service --cluster burger --service "$service" --desired-count "$saved" >/dev/null
    remaining=1
    for _ in $(seq 1 120); do
      state=$(burger_aws ecs describe-services --cluster burger --services "$service" --output json)
      if jq -e --argjson desired "$saved" '.failures == [] and (.services | length == 1) and .services[0].runningCount == $desired and .services[0].pendingCount == 0' <<< "$state" >/dev/null; then
        remaining=0; break
      fi
      sleep 5
    done
    [ "$remaining" = 0 ] || { echo "App did not reach the desired running count; inspect ECS events." >&2; return 1; }
    curl --fail --silent --show-error --retry 6 --retry-delay 5 --max-time 30 "$(burger_value ".environments.$env.url")/v1/posts/cursor?limit=1" >/dev/null
    echo "Burgerpedia $env ready."
  fi
}
if [ "$selected" = all ]; then power main; power dev; else power "$selected"; fi
