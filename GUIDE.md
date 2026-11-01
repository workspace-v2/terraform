# Bangjjack 인프라 운영 가이드

모든 명령은 `~/workspace/workspace-v2/terraform` 에서 실행합니다. (AWS 프로필: `personal-project`)

## 주소

| 대상 | 주소 |
| --- | --- |
| main API | https://main.pattie.cloud (Swagger: `/swagger-ui/index.html`) |
| dev API | https://dev.pattie.cloud |
| Grafana | https://monitoring.pattie.cloud (관리자 IP `admin_cidr` 에서만, 그 외 403) |

## 1. 부하테스트기 접속

사전 준비(최초 1회): `brew install --cask session-manager-plugin`

```sh
# 접속 (SSH 아님, SSM 세션)
$(terraform output -json load_generator | jq -r .connect)

# 접속 후
loadtest dev /opt/loadtest/smoke.js                          # 내부망으로 태스크 :8080 직접
TARGET=public loadtest dev /opt/loadtest/smoke.js            # https://dev.pattie.cloud 경유
loadtest main /opt/loadtest/smoke.js --vus 100 --duration 3m # k6 옵션 덮어쓰기
```

- 시나리오 파일은 `/opt/loadtest/` 에 작성하고 `__ENV.BASE_URL` 로 대상 주소를 씁니다.
- 결과는 Grafana **k6 Prometheus** 대시보드에서 서버 지표와 함께 봅니다.
- 부하기가 꺼져 있으면 먼저 `./scripts/env-power.sh load-generator start`.

## 2. Grafana 로그인

- 아이디: `admin`
- 비밀번호:
  ```sh
  terraform output -raw grafana_admin_password
  ```
  Grafana에서 비밀번호를 바꿨다면 바꾼 값을 씁니다. 모니터링 서버가 교체되면 위 값으로 초기화됩니다.
- 홈 대시보드 **Bangjjack 서비스 개요** 상단 `환경` 에서 main / dev 선택.

## 3. 서버 전부 끄기 / 켜기

```sh
# 전부 끄기
for t in main dev load-generator monitoring; do ./scripts/env-power.sh $t stop; done

# 전부 켜기 (DB·Redis 먼저 켜고 ECS 태스크 수는 스크립트가 복원)
for t in monitoring main dev; do ./scripts/env-power.sh $t start; done
./scripts/env-power.sh load-generator start   # 부하테스트할 때만

# 상태 확인
for t in main dev monitoring load-generator; do ./scripts/env-power.sh $t status; done
```

- 꺼도 도메인, 내부 IP, DB 데이터는 그대로입니다. 켜면 DB/Redis/모니터링이 올라오고 ECS 태스크 수가 복원됩니다 (2~3분).
- 꺼진 동안에도 ALB, EBS 디스크, 모니터링 고정 IP(EIP) 요금은 나갑니다.
- 완전히 지우려면 `terraform destroy` (DB 데이터까지 삭제됨).

## 배포

- dev 브랜치에 push → dev 서버 자동 배포
- main 브랜치에 merge → main 서버 자동 배포
- 수동 재배포: `gh workflow run cd.yaml --ref dev` (main은 `--ref main`)
