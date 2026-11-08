#!/usr/bin/env bash
# Shared search node only. Data volume and existing main/dev services remain intact.
set -euo pipefail
action="${1:-status}"
case "$action" in start|stop|status) ;; *) echo "usage: $0 <start|stop|status>" >&2; exit 2 ;; esac
source "$(dirname "$0")/burger-common.sh"
search=$(cd "$BURGER_TF_ROOT" && terraform output -json burger_search)
instance=$(jq -er .instance_id <<< "$search")
state=$(burger_aws ec2 describe-instances --instance-ids "$instance" --query 'Reservations[0].Instances[0].State.Name' --output text)
if [ "$action" = status ]; then
  burger_aws ec2 describe-instances --instance-ids "$instance" --query 'Reservations[].Instances[].{id:InstanceId,state:State.Name,type:InstanceType,privateIp:PrivateIpAddress}' --output table
  exit
fi
if [ "$action" = stop ]; then
  loadgen=$(jq -r '.load_generator_id // empty' <<< "$BURGER_CONFIG")
  if [ -n "$loadgen" ] && [ "$(burger_aws ec2 describe-instances --instance-ids "$loadgen" --query 'Reservations[0].Instances[0].State.Name' --output text)" = running ]; then
    burger_ssm "$loadgen" 'if pgrep -x k6 >/dev/null; then echo "Active load test; search shutdown refused" >&2; exit 1; fi'
  fi
  if [ "$state" = running ]; then
    burger_ssm "$instance" 'set -eu; flock -n /var/lock/burger-search-maintenance.lock sh -c "systemctl stop burger-search; sync"'
    burger_aws ec2 stop-instances --instance-ids "$instance" >/dev/null
  elif [ "$state" != stopped ] && [ "$state" != stopping ]; then
    echo "Unexpected state $state; no action taken" >&2; exit 1
  fi
  burger_aws ec2 wait instance-stopped --instance-ids "$instance"
  echo 'Search node stopped; its EBS data remains. EBS storage still incurs charges.'
else
  if [ "$state" = stopping ]; then burger_aws ec2 wait instance-stopped --instance-ids "$instance"; state=stopped; fi
  case "$state" in
    stopped) burger_aws ec2 start-instances --instance-ids "$instance" >/dev/null ;;
    pending|running) ;;
    *) echo "Unexpected state $state" >&2; exit 1 ;;
  esac
  burger_aws ec2 wait instance-status-ok --instance-ids "$instance"
  burger_ssm "$instance" 'set -eu; cloud-init status --wait || test -f /opt/burger-search/bootstrap-complete; systemctl start burger-search; systemctl is-active --quiet burger-search'
  echo 'Search node ready. Existing main/dev and shared monitoring were not restarted.'
fi
