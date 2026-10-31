# Bangjjack 인프라 (main / dev)

`personal-project` AWS CLI 프로필로 서울 리전(`ap-northeast-2`)에 배포합니다.
Git 브랜치 이름이 곧 환경 이름입니다 (`main`, `dev`).

```
                    ┌──────────── VPC 10.20.0.0/16 · public subnet 10.20.1.0/24 ────────────┐
 internet ─443/80─▶ │  main-backend  .11  (Caddy TLS → Spring :8080, actuator :8081)         │
                    │     ├─3306─▶ main-database .12 (MySQL 8 + mysqld_exporter :9104)       │
                    │     └─6379─▶ main-redis    .13 (Redis 7  + redis_exporter  :9121)      │
 internet ─443/80─▶ │  dev-backend   .21                                                      │
                    │     ├─3306─▶ dev-database  .22                                         │
                    │     └─6379─▶ dev-redis     .23                                         │
 admin IP ─3000──▶  │  monitoring    .5  (Prometheus · Grafana · Blackbox) ──scrape──▶ 전 호스트 │
                    └────────────────────────────────────────────────────────────────────────┘
 GitHub Actions ──OIDC──▶ IAM role(브랜치별) ──▶ ECR push ──▶ SSM RunCommand ──▶ <env>-backend
```

| 구성 | 내용 |
| --- | --- |
| 환경 격리 | 환경마다 보안 그룹·IAM 역할·SSM 파라미터 경로가 분리됨. dev 백엔드는 main DB/Redis에 접근 불가, dev 브랜치 워크플로는 main 서버에 배포 불가 |
| 백엔드 | Docker + Caddy. `<EIP>.nip.io` 도메인으로 Let's Encrypt 인증서 자동 발급 (HTTPS/WebSocket) |
| DB | EC2 위 MySQL 8 (utf8mb4, KST, slow query log, performance_schema) |
| Redis | 비밀번호, AOF, maxmemory(volatile-lru) |
| 시크릿 | SSM Parameter Store `/bangjjack/<env>/*` (SecureString). 배포 시 서버가 직접 읽어 env 파일 생성 |
| 배포 | GitHub OIDC → ECR → SSM RunCommand. 헬스체크 실패 시 이전 이미지로 자동 롤백 |
| 접근 | SSH 미개방. 서버 접속은 SSM Session Manager |

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
| `DB_URL`, `DB_USER`, `DB_PASSWORD`, `REDIS_HOST`, `REDIS_PASSWORD`, `SPRING_PROFILES_ACTIVE`, `APP_ENV`, `JAVA_OPTS`, `SERVER_FORWARD_HEADERS_STRATEGY` | Terraform (덮어쓰면 다음 apply 때 원복) |
| `SERVER_URI`, `FRONT_URI`, `GOOGLE_REDIRECT_URI`, `JWT_ACCESS`, `DEV_SECRET` | Terraform이 초기값만 생성, 이후 자유롭게 수정 |
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
`role`(backend/database/redis/monitoring) 라벨이 붙고 `instance`는 `main-backend`처럼 읽기 쉬운 이름입니다.

알림 규칙 23개(`monitoring/alert-rules.yml`)는 Prometheus가 평가하고 개요 대시보드의 "발생 중인 알림"
패널과 Grafana Alerting 화면에서 확인합니다. Prometheus UI가 필요하면:

```sh
$(terraform output -raw prometheus_tunnel_command)   # → http://localhost:9090
```

## 5. 운영

```sh
# 서버 접속 (SSH 대신)
aws ssm start-session --profile personal-project --target <instance-id>

# 백엔드에서 수동 배포 / 로그
sudo bangjjack-deploy <ecr-url>:main-latest
sudo docker logs -f bangjjack
sudo tail -f /var/log/bangjjack-bootstrap.log
```

- 백엔드·모니터링 호스트는 상태가 없어서 부트스트랩 스크립트가 바뀌면 교체됩니다
  (백엔드는 부팅 시 `<env>-latest` 이미지를 자동 배포).
- DB·Redis 호스트는 `user_data`/AMI 변경을 무시하므로 템플릿 수정으로 데이터가 날아가지 않습니다.
  인스턴스 타입 변경은 재시작만 일어납니다.
- `terraform destroy`는 DB 데이터까지 삭제합니다. 필요하면 먼저 `mysqldump`로 백업하세요.

## 중지 / 시작

안 쓸 때는 환경 단위로 중지합니다. 고정 IP(백엔드, 모니터링)와 내부 IP, 디스크 데이터는 유지됩니다.

```sh
./scripts/env-power.sh dev stop          # dev 백엔드·DB·Redis 중지
./scripts/env-power.sh dev start         # DB·Redis 먼저 켜고 백엔드 시작
./scripts/env-power.sh main status
./scripts/env-power.sh monitoring stop
```

중지 중에도 EBS 디스크와 고정 IP(EIP) 요금은 나갑니다. 앱 컨테이너, MySQL, Redis, exporter, Caddy는
부팅 시 자동으로 올라옵니다.

## 비용 참고 (서울, 온디맨드, 월 기준 대략)

기본 구성은 t3.small ×4(main backend·DB, dev backend, monitoring), t3.micro ×3(main redis, dev DB·redis),
EIP 3개 + 퍼블릭 IPv4 4개, gp3 약 170GB입니다. 사용하지 않을 때는 dev를 `terraform destroy -target`으로
내리거나 인스턴스를 중지하세요 (EIP 요금은 계속 발생).

State 파일에는 생성된 비밀번호가 들어 있으니 커밋하지 마세요.
