#!/usr/bin/env bash
# 기존 모니터링 인스턴스에 Tempo 를 설치(또는 설정 갱신)하고 Grafana 데이터소스를 연결한다 (SSM).
# 모니터링 인스턴스는 user_data 변경을 무시하므로(교체 방지), 새로 추가한 구성은 이 스크립트로 반영한다.
#   - Tempo 컨테이너: OTLP HTTP 4318 수신 (ECS 백엔드 -> 모니터링, security.tf), 데이터는 tempo-data 볼륨
#   - Grafana 데이터소스: monitoring/grafana-datasource.yml 을 올린 뒤 grafana 재시작 (수 초 중단)
# 측정 중에는 실행하지 말 것 (Grafana 재시작).
# Usage: ./scripts/tempo-install.sh
set -euo pipefail
export AWS_PAGER=""
cd "$(dirname "$0")/.."
PROFILE="${AWS_PROFILE_NAME:-personal-project}"
REGION="${AWS_REGION:-ap-northeast-2}"
PREFIX="${NAME_PREFIX:-bangjjack}"
TEMPO_VERSION="${TEMPO_VERSION:-$(sed -n 's/^ *tempo *= *"\(.*\)"/\1/p' variables.tf | head -1)}"
[ -n "$TEMPO_VERSION" ] || { echo "variables.tf 에서 tempo 버전을 찾지 못함"; exit 1; }

MON=$(aws ec2 describe-instances --profile "$PROFILE" --region "$REGION" \
  --filters "Name=tag:Project,Values=$PREFIX" "Name=tag:Role,Values=monitoring" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
[ "$MON" != "None" ] || { echo "monitoring is not running"; exit 1; }

tempo_config=$(gzip -9c monitoring/tempo.yml | base64 | tr -d '\n')
datasource=$(gzip -9c monitoring/grafana-datasource.yml | base64 | tr -d '\n')
script="set -e
BASE=/opt/monitoring
mkdir -p \$BASE/tempo
echo '$tempo_config' | base64 -d | gunzip > \$BASE/tempo/tempo.yml
echo '$datasource' | base64 -d | gunzip > \$BASE/grafana/provisioning/datasources/prometheus.yml
chmod -R a+rX \$BASE/tempo \$BASE/grafana/provisioning
docker rm -f tempo >/dev/null 2>&1 || true
# 이미지 기본 사용자(10001)는 root 소유로 만들어지는 볼륨에 쓰지 못하므로 root 로 실행한다.
docker run -d --restart unless-stopped --name tempo --network monitoring --user 0 \
  -p 4318:4318 \
  -v \$BASE/tempo/tempo.yml:/etc/tempo.yml:ro \
  -v tempo-data:/var/tempo \
  grafana/tempo:$TEMPO_VERSION -config.file=/etc/tempo.yml >/dev/null
docker restart grafana >/dev/null
sleep 5
docker ps --filter name=tempo --format '{{.Names}} {{.Status}}'
docker logs --tail 5 tempo 2>&1 || true
echo 'tempo $TEMPO_VERSION installed, grafana datasource reloaded'"
params=$(jq -nc --arg c "$script" '{commands: [$c]}')
cmd=$(aws ssm send-command --profile "$PROFILE" --region "$REGION" --instance-ids "$MON" \
  --document-name AWS-RunShellScript --comment "install tempo $TEMPO_VERSION" \
  --parameters "$params" --query Command.CommandId --output text)
aws ssm wait command-executed --profile "$PROFILE" --region "$REGION" --command-id "$cmd" --instance-id "$MON" 2>/dev/null || true
aws ssm get-command-invocation --profile "$PROFILE" --region "$REGION" --command-id "$cmd" --instance-id "$MON" \
  --query '[Status, StandardOutputContent, StandardErrorContent]' --output text
