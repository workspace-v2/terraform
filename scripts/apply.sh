#!/usr/bin/env bash
# One-shot deploy: terraform init/plan/apply, then wire GitHub Actions variables.
# Usage: ./scripts/apply.sh            (interactive approval)
#        ./scripts/apply.sh -auto-approve
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${AWS_PROFILE_NAME:-personal-project}"

command -v terraform >/dev/null || { echo "terraform not found (brew install terraform)"; exit 1; }
command -v aws >/dev/null || { echo "aws cli not found (brew install awscli)"; exit 1; }

echo "== AWS identity ($PROFILE)"
aws sts get-caller-identity --profile "$PROFILE" --output table

# Grafana is restricted to admin_cidr - warn when the current IP differs.
my_ip=$(curl -fsS -m 5 https://checkip.amazonaws.com || true)
if [ -n "$my_ip" ] && grep -q '^admin_cidr' terraform.tfvars 2>/dev/null && ! grep -q "$my_ip" terraform.tfvars; then
  echo "!! current public IP $my_ip differs from admin_cidr. Grafana will be unreachable from here."
  echo "   add to terraform.tfvars:  admin_cidr = \"$my_ip/32\""
fi

# An account can hold only one GitHub OIDC provider.
if aws iam list-open-id-connect-providers --profile "$PROFILE" --output text \
     | grep -q "token.actions.githubusercontent.com" \
   && ! grep -q "create_github_oidc_provider" terraform.tfvars 2>/dev/null \
   && ! terraform state list 2>/dev/null | grep -q "aws_iam_openid_connect_provider.github"; then
  echo "== GitHub OIDC provider already exists in this account -> create_github_oidc_provider = false"
  echo 'create_github_oidc_provider = false' >> terraform.tfvars
fi

terraform init -input=false
terraform validate
terraform apply "$@"

echo
echo "== Outputs"
terraform output environments
terraform output grafana_url
echo "Grafana admin password: $(terraform output -raw grafana_admin_password)"

if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  ./scripts/set-github-vars.sh
else
  echo "gh CLI not logged in - run ./scripts/set-github-vars.sh later (needs: gh auth login)"
fi

cat <<'EOF'

Next:
  1) Push the dev branch (and merge to main) - GitHub Actions builds, pushes to ECR
     and rolls out a new ECS task definition revision.
  2) EC2 hosts (DB, Redis, monitoring) finish bootstrapping ~5 minutes after apply.
EOF
