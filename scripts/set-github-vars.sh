#!/usr/bin/env bash
# Store the OIDC deploy role ARNs as GitHub Actions repository variables.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="${GITHUB_REPOSITORY:-workspace-v2/Bangjjack-Backend-chatting}"
roles=$(terraform output -json github_deploy_role_arns)

gh variable set AWS_ROLE_ARN_MAIN --repo "$REPO" --body "$(jq -r .main <<<"$roles")"
gh variable set AWS_ROLE_ARN_DEV  --repo "$REPO" --body "$(jq -r .dev  <<<"$roles")"
gh variable set AWS_REGION        --repo "$REPO" --body "ap-northeast-2"
gh variable set ECR_REPOSITORY    --repo "$REPO" --body "$(terraform output -raw ecr_repository_url | cut -d/ -f2)"
echo "GitHub variables updated on $REPO"
gh variable list --repo "$REPO"
