#!/usr/bin/env bash
# Configure only the new Burgerpedia workflow. Never changes legacy/Bangjjack variables.
set -euo pipefail
cd "$(dirname "$0")/.."
config=$(terraform output -json burger_deployment)
repo=$(jq -r .repository <<< "$config")
gh variable set BURGER_AWS_REGION --repo "$repo" --body "$(jq -r .region <<< "$config")"
for env in main dev; do
  upper=$(tr '[:lower:]' '[:upper:]' <<< "$env")
  gh variable set "BURGER_AWS_ROLE_ARN_$upper" --repo "$repo" --body "$(jq -r ".environments.$env.role_arn" <<< "$config")"
  gh variable set "BURGER_URL_$upper" --repo "$repo" --body "$(jq -r ".environments.$env.url" <<< "$config")"
done
# Disabled until bootstrap, service health and monitoring setup are complete.
gh variable set BURGER_DEPLOY_ENABLED --repo "$repo" --body false
echo "Variables configured. Enable after startup checks:"
echo "gh variable set BURGER_DEPLOY_ENABLED --repo $repo --body true"
