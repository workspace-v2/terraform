# Bangjjack 인프라 (main / dev)

`personal-project` AWS CLI 프로필로 서울 리전(`ap-northeast-2`)에 배포합니다.
Git 브랜치 이름이 곧 환경 이름입니다 (`main`, `dev`).

```
                     ┌────────── VPC 10.20.0.0/16 · public subnets 10.20.1.0/24 (a), 10.20.2.0/24 (c) ──────────┐
 internet ─443/80─▶  │  ALB (ACM TLS, Host 헤더 분기)                                                           │
                     │   ├─ main.pattie.cloud ─▶ ECS main 서비스 (Fargate 태스크 ×N, :8080 app, :8081 actuator)  │
                     │   │        ├─3306─▶ main-database .12 (MySQL 8 + mysqld_exporter :9104)                │
                     │   │        └─6379─▶ main-redis    .13 (Redis 7  + redis_exporter  :9121)               │
                     │   └─ dev.pattie.cloud  ─▶ ECS dev 서비스                                                 │
                     │            ├─3306─▶ dev-database  .22                                                  │
                     │            └─6379─▶ dev-redis     .23                                                  │
 admin IP ─3000──▶   │  monitoring .5 (Prometheus · Grafana · Blackbox) ──scrape──▶ 전 호스트, 태스크(Cloud Map)  │
                     │  load-generator .6 (k6) ──▶ <env>-backend.bangjjack.internal:8080 (태스크 직접)          │
                     └──────────────────────────────────────────────────────────────────────────────────────────┘
 GitHub Actions ──OIDC──▶ IAM role(브랜치별) ──▶ ECR push ──▶ 태스크 정의 리비전 등록 ──▶ ECS 서비스 롤링 배포
```

| 구성 | 내용 |
| --- | --- |
| 환경 격리 | 환경마다 보안 그룹·IAM 역할·SSM 파라미터 경로·ECS 서비스가 분리됨. dev 백엔드는 main DB/Redis에 접근 불가, dev 브랜치 워크플로는 main 서비스에 배포 불가 |
| 도메인 | Route53 `main.pattie.cloud`, `dev.pattie.cloud` → ALB(alias), `monitoring.pattie.cloud` → ALB(alias) → Grafana (HTTPS, `admin_cidr`에서만) |
| 백엔드 | ECS Fargate. 환경별 태스크 수 2 (main·dev, 생성 시 `backend_desired_count`). TLS는 ALB(ACM, DNS 검증) |
| 단일 서버 백엔드 | 기존 EC2(Docker + Caddy) `.11`, `.21`을 `one-main.pattie.cloud`, `one-dev.pattie.cloud`로 보관. 기본 중지 (`legacy_backend_state`), CD 배포 대상 아님 (`scripts/legacy-backend.sh`로 수동 배포) |
| 서비스 디스커버리 | Cloud Map `<env>-backend.bangjjack.internal` → 실행 중인 모든 태스크 IP (Prometheus, 부하기가 사용) |
| 장애 주입 | `enable_fault_injection = true` 면 태스크 정의에 FIS 준비(enableFaultInjection, pidMode=task, SSM agent 사이드카) |
| DB | EC2 위 MySQL 8 (utf8mb4, KST, slow query log, performance_schema) |
| Redis | 비밀번호, AOF, maxmemory(volatile-lru) |
| 시크릿 | SSM Parameter Store `/bangjjack/<env>/*` (SecureString). 태스크 정의 `secrets`로 컨테이너 환경 변수에 주입 |
| 배포 | GitHub OIDC → ECR → ECS 롤링 배포. 새 태스크가 헬스 체크를 통과하지 못하면 deployment circuit breaker가 자동 롤백 |
| 접근 | SSH 미개방. EC2 접속은 SSM Session Manager, 앱 로그는 CloudWatch Logs `/ecs/bangjjack-<env>-backend` |

## EC2 백엔드 → ECS 전환 (1회)

1. MySQL 앱 계정 접속 호스트를 VPC 대역으로 넓힌다 (기존 DB는 user_data 변경을 무시하므로 스크립트로 적용).
   ```sh
   ./scripts/migrate-mysql-app-host.sh main
   ./scripts/migrate-mysql-app-host.sh dev
   ```
2. `terraform apply` — ALB, ECS 서비스가 생기고 `<env>.pattie.cloud`가 ALB를 가리키게 된다.
   기존 백엔드 EC2·EIP는 삭제하지 않고 **중지 상태로 보관**하고, `one-<env>.pattie.cloud`가 EIP를 가리킨다.
   모니터링·부하기 호스트는
   설정이 바뀌어 교체된다 (Prometheus 이력 초기화, Grafana 비밀번호는 `terraform output` 값으로 초기화).
   Route53 레코드가 ALB로 바뀌는 동안 수 분간 접속이 끊길 수 있다.
3. ECR에 `<env>-latest` 이미지가 있으면 서비스가 그 이미지로 뜬다. 이후 배포는 CD가 한다.

## main(개선 전) vs dev(개선 후) 비교 조건

main과 dev는 같은 사양이다 (ECS 1 vCPU/2GB ×2, DB t3.small·버퍼 풀 768MB, Redis maxmemory 384MB).
DB·Redis 호스트는 user_data 변경을 무시하므로 버퍼 풀·maxmemory 변경은 apply 후 스크립트로 적용한다.

```sh
terraform apply
./scripts/sync-data-host-config.sh dev     # 재시작 없이 적용 + 설정 파일에 기록
```

## 채팅 정합성 측정 (k6 + FIS)

```sh
terraform apply                                   # FIS 실험 템플릿 생성 (fis.tf)
./scripts/env-power.sh load-generator start
./scripts/loadtest-push.sh                        # 시나리오(chat-consistency.js)·chattest 래퍼를 부하기에 올림
./scripts/loadtest-seed.sh main 200               # 테스트 사용자 200명 + DEV_SECRET 전달 (dev 도 같이)
./scripts/loadtest-seed.sh dev 200

# 부하기 접속 후
PAIRS=50 RATE=2 DURATION=180 chattest main        # 방 50개, 사용자 100명이 서버 2대에 나뉘어 접속

# 측정 중 다른 터미널에서 장애 주입
aws fis start-experiment --experiment-template-id $(terraform output -json fis_experiment_templates | jq -r '.main["redis-blackhole-one-task"]')
./scripts/ws-sessions.sh main watch 10            # Redis 에 남은 WebSocket 세션 수 추이 (좀비 세션)
./scripts/loadtest-seed.sh main reset             # 측정 사이 테스트 채팅 데이터 정리
```

| 실험 템플릿 | 내용 | 보는 지표 |
| --- | --- | --- |
| `redis-blackhole-one-task` | 태스크 1개만 Redis 6379 차단 (60초) | 서버별 delivery, server inconsistency |
| `kill-one-task` | 태스크 1개 java SIGKILL | overall delivery/loss, reconnects, 좀비 세션 |
| `redis-stop` | Redis EC2 중지 → 2분 뒤 시작 | overall delivery, 복구 시간 |

결과는 콘솔 요약과 부하기 `/opt/loadtest/results/<testid>.txt|json`, Grafana k6 대시보드(`testid`)에 남는다.

## 단일 서버(EC2) 백엔드 사용 — 단일 서버 한계 측정 등

같은 DB/Redis를 쓰므로 **ECS와 단일 서버는 한 번에 한쪽만 켜고 측정**한다.

```sh
terraform apply -var 'legacy_backend_state={main="running"}'   # 켜기 (기본값은 stopped)
aws ecs update-service --cluster bangjjack --service bangjjack-main-backend --desired-count 0 --profile personal-project  # ECS 끄기
./scripts/legacy-backend.sh main caddy                 # 최초 1회: Caddy 도메인을 one-main.pattie.cloud 로
./scripts/legacy-backend.sh main deploy main-<git sha>  # ECS와 같은 이미지로 맞추기
terraform apply                                         # 끄기 (stopped, ECS 태스크 수 원복)
```

Grafana 개요 대시보드의 `환경`에서 `one-main`, `one-dev`를 고르면 단일 서버 지표(JVM, HTTP, node)를 본다.
DB·Redis 지표는 `main`/`dev` 라벨이므로 `one-main`과 `main`을 함께 선택한다. 평소 중지 상태라
`one-*` 환경은 수집 실패(TargetDown)·헬스 체크 알림에서 제외된다.
부하기에서는 `loadtest one-main <script>`(내부망 `10.20.1.11:8080`), `TARGET=public loadtest one-main ...`로 측정한다.

## 1. 사전 준비

```sh
brew install terraform awscli gh jq   # 없으면
aws sts get-caller-identity --profile personal-project
gh auth login                          # GitHub 변수 자동 설정용 (선택)
```

Grafana는 `admin_cidr`(기본 `211.244.225.211/32`)에서만 열립니다. IP가 바뀌었으면
`terraform.tfvars`에 `admin_cidr = "<내 IP>/32"`를 넣으세요 (`scripts/apply.sh`가 다르면 알려줌).

## 2. 배포

```sh
./scripts/apply.sh
```

`terraform init → validate → apply` 후 출력값을 보여주고, `gh`가 로그인돼 있으면 GitHub
저장소 변수(`AWS_ROLE_ARN_MAIN`, `AWS_ROLE_ARN_DEV`, `AWS_REGION`, `ECR_REPOSITORY`)까지 설정합니다.
계정에 GitHub OIDC 공급자가 이미 있으면 자동으로 `create_github_oidc_provider = false`를 씁니다.

호스트 부트스트랩(패키지 설치, MySQL/Redis/exporter, Grafana 대시보드 다운로드)은 apply 후 약 5분 걸립니다.

## 3. 앱 설정값

Terraform이 필요한 값을 전부 자동으로 넣으므로 따로 입력할 것은 없습니다.
Google 로그인과 AI 매칭은 사용하지 않아 더미값이 들어갑니다. 값을 바꾸고 싶을 때만:

```sh
echo 'FRONT_URI=https://...' > main.env
./scripts/put-app-secrets.sh main main.env --redeploy
```

`*.env` 파일은 `.gitignore`에 포함돼 있습니다.

| 키 | 관리 주체 |
| --- | --- |
| `DB_URL`, `DB_USER`, `DB_PASSWORD`, `REDIS_HOST`, `REDIS_PASSWORD`, `SPRING_PROFILES_ACTIVE`, `APP_ENV`, `JAVA_OPTS`, `SERVER_FORWARD_HEADERS_STRATEGY`, `SERVER_URI`, `GOOGLE_REDIRECT_URI` | Terraform (덮어쓰면 다음 apply 때 원복) |
| `FRONT_URI`, `JWT_ACCESS`, `DEV_SECRET` | Terraform이 초기값만 생성, 이후 자유롭게 수정 |
| `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `AI_MATCH_API_BASE_URL` | 더미값 (Google 로그인·AI 매칭 미사용) |

## 4. 모니터링

`terraform output grafana_url` (ID `admin`, 비밀번호 `terraform output -raw grafana_admin_password`).
홈 대시보드 **Bangjjack 서비스 개요 (main / dev)** 상단의 `환경` 드롭다운으로 main/dev를 따로 또는 겹쳐 봅니다.

| 영역 | 수집 경로 | 주요 지표 |
| --- | --- | --- |
| 상태 | `up`, Blackbox | 타깃 UP/DOWN, `/actuator/health`(DB·Redis 포함), 공개 HTTPS 응답, TLS 만료일, 발생 중 알림 |
| HTTP | Spring actuator `:8081/actuator/prometheus` | RPS(상태코드별), p50/p95/p99, 4xx/5xx, API별 응답시간·호출량 Top 15, 배포 시점 주석 |
| JVM | 〃 | Heap/Non-heap, GC 일시정지, 스레드(blocked, Tomcat busy), 프로세스 CPU |
| DB 풀 | 〃 | HikariCP active/idle/pending/max, 커넥션 획득 시간, ERROR/WARN 로그 발생률 |
| 호스트 | node_exporter (전 호스트) | CPU, **CPU steal(T3 크레딧 소진)**, 메모리, 디스크, I/O, 네트워크, load, swap, systemd 서비스 실패 |
| MySQL | mysqld_exporter | QPS, 명령 유형별, 커넥션/실행 스레드, 슬로우 쿼리, row lock 대기, 버퍼 풀 히트율, 테이블 크기 |
| Redis | redis_exporter | 메모리/최대, 처리량, 클라이언트, **Pub/Sub 채널 수**, 히트율, 키 수, 만료/eviction, 명령별 지연 |

`Bangjjack` 폴더에 커뮤니티 상세 대시보드도 함께 들어갑니다: Node Exporter Full, Spring Boot Statistics,
JVM (Micrometer), MySQL Exporter, Redis Exporter, Blackbox Exporter. 모든 시계열에 `env`(main/dev/shared),
`role`(backend/database/redis/monitoring) 라벨이 붙고 `instance`는 `main-database`처럼 읽기 쉬운 이름입니다.
백엔드는 태스크마다 `instance=main-backend-<태스크 IP>`로 나뉩니다 (Cloud Map DNS로 자동 수집).

알림 규칙 23개(`monitoring/alert-rules.yml`)는 Prometheus가 평가하고 개요 대시보드의 "발생 중인 알림"
패널과 Grafana Alerting 화면에서 확인합니다. Prometheus UI가 필요하면:

```sh
$(terraform output -raw prometheus_tunnel_command)   # → http://localhost:9090
```

## 5. 운영

```sh
# EC2(DB, Redis, 모니터링, 부하기) 접속 (SSH 대신)
aws ssm start-session --profile personal-project --target <instance-id>

# 백엔드 로그 / 태스크 / 재배포
aws logs tail /ecs/bangjjack-main-backend --follow --profile personal-project
aws ecs list-tasks --cluster bangjjack --service-name bangjjack-main-backend --profile personal-project
aws ecs update-service --cluster bangjjack --service bangjjack-main-backend --force-new-deployment --profile personal-project
```

- 부하기 호스트는 상태가 없어서 부트스트랩 스크립트가 바뀌면 교체됩니다.
- 모니터링 호스트는 Prometheus 이력(측정 데이터, 30일)을 지키기 위해 스크립트가 바뀌어도 **교체하지 않습니다.**
  설정을 반영하려면 `terraform apply -replace=aws_instance.monitoring` (이력 초기화).
  Grafana 화면에서 만든 대시보드는 `./scripts/export-grafana-dashboard.sh <uid>` 로 레포(`monitoring/dashboards/`)와
  서버 프로비저닝 폴더에 저장합니다 (예: `bangjjack-chat` = 채팅 측정 대시보드).
- 백엔드 태스크 정의는 Terraform이 최초 리비전만 만들고, 이후 리비전은 CD가 등록합니다
  (서비스의 `task_definition` 변경은 Terraform이 무시).
- DB·Redis 호스트는 `user_data`/AMI 변경을 무시하므로 템플릿 수정으로 데이터가 날아가지 않습니다.
  인스턴스 타입 변경은 재시작만 일어납니다.
- `terraform destroy`는 DB 데이터까지 삭제합니다. 필요하면 먼저 `mysqldump`로 백업하세요.

## 부하 테스트

main/dev 공용 부하 발생기 1대(c6i.large, k6·wrk·ab·sysbench). k6 결과는 Prometheus로 전송돼
Grafana의 **k6 Prometheus** 대시보드와 서비스 개요 대시보드에서 서버 지표와 같은 시간축으로 봅니다.

```sh
$(terraform output -json load_generator | jq -r .connect)   # SSM 접속
loadtest dev /opt/loadtest/smoke.js                          # 내부망 태스크 :8080 직접 (ALB 제외)
TARGET=public loadtest dev /opt/loadtest/smoke.js            # https://dev.pattie.cloud 경유
loadtest dev /opt/loadtest/smoke.js --vus 100 --duration 3m  # k6 옵션 덮어쓰기
```

스크립트에서는 `__ENV.BASE_URL`로 대상 주소를 씁니다. 테스트마다 `testid`, `target_env` 태그가 붙습니다.
사용자를 특정 서버(태스크)에 고정하는 다중 서버 실험은 `dig +short $MAIN_BACKEND_DNS`로 태스크 IP 목록을 얻어
`http://<태스크 IP>:8080`으로 직접 접속합니다 (`/etc/loadtest.env`).
안 쓸 때는 `./scripts/env-power.sh load-generator stop`.

## 중지 / 시작

안 쓸 때는 환경 단위로 중지합니다. 내부 IP, 도메인, 디스크 데이터는 유지됩니다.

```sh
./scripts/env-power.sh dev stop          # dev ECS 태스크 수 0 → DB·Redis 중지
./scripts/env-power.sh dev start         # DB·Redis 먼저 켜고 태스크 수 복원
./scripts/env-power.sh main status
./scripts/env-power.sh monitoring stop
./scripts/env-power.sh load-generator stop
```

중지 전 태스크 수는 ECS 서비스 태그(`PowerOffDesiredCount`)에 기록했다가 start 때 복원합니다.
태스크 수는 terraform 이 되돌리지 않습니다 (`backend_desired_count` 는 서비스 생성 시에만 사용).
중지 중에도 ALB, EBS 디스크, 모니터링 EIP 요금은 나갑니다. MySQL, Redis, exporter는 부팅 시 자동으로 올라옵니다.

## 비용 참고 (서울, 온디맨드, 월 기준 대략)

기본 구성은 EC2 t3.small ×2(main DB, monitoring), t3.micro ×3(main redis, dev DB·redis), c6i.large ×1(부하기),
ECS Fargate 1 vCPU / 2 GB 태스크 ×3(main 2, dev 1), ALB 1개(main/dev 공용), 모니터링 EIP입니다.
실험하지 않을 때는 `env-power.sh`로 태스크 수를 0으로 내리세요 (ALB 요금은 계속 발생).

State 파일에는 생성된 비밀번호가 들어 있으니 커밋하지 마세요.
