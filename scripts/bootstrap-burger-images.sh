#!/usr/bin/env bash
# Run after the FIRST apply with burger_services_enabled=false, before creating services.
set -euo pipefail
cd "$(dirname "$0")/.."
export AWS_PAGER=""
profile="${AWS_PROFILE_NAME:-personal-project}"
config=$(terraform output -json burger_deployment)
region=$(jq -r .region <<< "$config")
source_dir="${1:-../community-service}"
source_dir=$(cd "$source_dir" && pwd)
(cd "$source_dir" && ./gradlew --no-daemon test bootJar)
registry=$(jq -r '.environments.main.ecr_url | split("/")[0]' <<< "$config")
aws ecr get-login-password --profile "$profile" --region "$region" | docker login --username AWS --password-stdin "$registry"
# A dedicated container driver avoids Docker Desktop exporting/pushing the same
# immutable tag twice, and leaves the user's selected builder unchanged.
builder="burger-bootstrap-$$"
docker buildx create --name "$builder" --driver docker-container >/dev/null
trap 'docker buildx rm "$builder" >/dev/null 2>&1 || true' EXIT
for env in main dev; do
  repo=$(jq -r ".environments.$env.ecr_repository" <<< "$config")
  image=$(jq -r ".environments.$env.ecr_url" <<< "$config"):bootstrap
  # Fail closed on auth/network errors; only ImageNotFoundException means build is needed.
  error=$(mktemp)
  if aws ecr describe-images --profile "$profile" --region "$region" --repository-name "$repo" --image-ids imageTag=bootstrap >/dev/null 2>"$error"; then
    echo "Keeping existing immutable bootstrap image: $image"
  elif grep -q ImageNotFoundException "$error"; then
    docker buildx build --builder "$builder" --platform linux/amd64 --file "$source_dir/Dockerfile.ecs" --tag "$image" --push "$source_dir"
  else
    cat "$error" >&2; rm -f "$error"; exit 1
  fi
  rm -f "$error"
done
