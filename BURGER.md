# Burgerpedia: backend load-test infrastructure

이 구성은 기존 Bangjjack 인프라에 **추가**됩니다. 기존 VPC·Route53 영역·OIDC 제공자와
공통 모니터링·부하테스트기만 재사용하며, Burgerpedia main/dev의 앱·MySQL·Redis는 분리합니다.
프런트엔드·ArgoCD·Elasticsearch·ElastiCache는 생성하지 않습니다.

| 브랜치 | 주소 | 앱 | 데이터 서버 |
|---|---|---|---|
| main | https://main-burger.pattie.cloud | burger / burger-main Fargate | burger-main-database, burger-main-redis EC2 |
| dev | https://dev-burger.pattie.cloud | burger / burger-dev Fargate | burger-dev-database, burger-dev-redis EC2 |

앱은 환경마다 1 vCPU / 2 GiB 태스크 1개입니다. 배포 중 새 태스크가 추가로 실행됩니다.
MySQL은 환경별 t3.small, Redis는 t3.micro이며 중지/시작 시 EBS 데이터와 사설 IP를 유지합니다.
EC2는 패키지 설치를 위해 공인 IP를 받지만 외부 인바운드는 열지 않습니다. 3306/6379는
같은 환경 앱 SG만, exporter 포트는 공통 모니터링 SG만 접근할 수 있습니다.
MySQL 앱 계정은 burgerpedia 스키마만 접근합니다. Terraform 상태에는 생성 비밀번호가
포함되므로 기존 상태 보관 정책을 유지하고 상태·plan 파일을 커밋하지 않습니다.

## 배포 구조

GitHub main/dev push → H2·MySQL 테스트 → 검증한 JAR 패키징 → 환경별 ECR →
CodeDeploy 블루/그린 → ALB readiness 통과 → HTTPS 트래픽 전환 → 이전 태스크 5분 보관.
환경별 ALB·리스너·blue/green 대상 그룹을 사용하므로 한 환경의 전환이 다른 환경을 바꾸지 않습니다.
대상 그룹 5xx 경보·배포 실패 시 CodeDeploy 자동 롤백을 설정합니다.
상세한 API 동작 검증은 별도의 테스트이며, readiness와 경보가 모든 회귀를 탐지하지는 않습니다.
DB 스키마는 두 버전이 동시에 동작하는 expand/contract 방식으로 변경해야 합니다.
파괴적 Flyway 변경은 앱 롤백만으로 되돌릴 수 없습니다.

현재 AWS provider 5.100.0을 유지하기 위해 CodeDeploy 방식으로 추가했습니다.
기존 환경의 롤링 배포·FIS·IAM·DNS는 변경하지 않습니다. 생성한 역할은 이 저장소의
main/dev OIDC subject를 구분하며, 각 브랜치는 자신의 ECR·배포 그룹·태스크 역할만 사용합니다.
GitHub Environment는 설정하지 않습니다. 사용하면 OIDC subject 형식도 함께 변경해야 합니다.

커뮤니티의 기존 GHCR·GitOps·EC2 배포·정리 워크플로 5개는 job 조건을 false로 고정합니다.
파일은 보존합니다. 별도 Bangjjack 저장소의 CI/CD와 실행 중인 ArgoCD는 조작하지 않습니다.

## 최초 구성 순서 — 사용자가 실행

신규 환경을 처음 구축할 때의 순서입니다. 비용이 발생하는 AWS 리소스를
만들기 전에 반드시 기존 변경까지 포함한 전체 plan을 확인합니다.

```sh
cd /Users/xezi/workspace/workspace-v2/terraform
terraform init
terraform plan -var='burger_services_enabled=false'
terraform apply -var='burger_services_enabled=false'
```

`false`는 **처음 ECR·데이터 서버·인증서 등을 준비할 때만** 사용합니다.
이미 서비스를 만든 환경에 다시 false를 적용하면 서비스·배포 그룹 제거가 계획되므로 사용하지 않습니다.
공인 DNS 인증과 새 데이터 서버의 cloud-init 초기 구성이 완료돼야 합니다.

```sh
# ../community-service의 현재 코드로 테스트·bootJar 후 amd64 bootstrap 이미지를 업로드합니다.
./scripts/bootstrap-burger-images.sh ../community-service

# 기본값 true: 실제 앱 서비스와 CodeDeploy 배포 그룹을 생성합니다.
terraform plan
terraform apply

./scripts/burger-power.sh main start
./scripts/burger-power.sh dev start
./scripts/install-burger-monitoring.sh
./scripts/set-burger-github-vars.sh
```

마지막 스크립트는 BURGER_* 변수만 설정하고 배포 스위치는 false로 둡니다.
서비스 기동과 모니터링 확인 후 켭니다.

```sh
gh variable set BURGER_DEPLOY_ENABLED --repo workspace-v2/community-service --body true
```

워크플로와 필요한 앱 설정을 main에 커밋·푸시한 다음 dev 브랜치를 생성합니다.
이 작업에서는 dev 브랜치를 생성하지 않습니다. 이후 각 브랜치 push 또는 그 브랜치에서
수동 실행하면 해당 환경만 배포됩니다. PR은 테스트만 수행합니다.
중지한 환경에 push하면 검증은 실행되지만 배포는 실패 처리하며 서버를 자동으로 켜지 않습니다.

새 저장소를 다시 만들면 burger.tf의 immutable OIDC prefix도 새 GitHub 저장소 ID로 갱신합니다.
`AWS_PROFILE_NAME` 기본값은 기존과 같은 personal-project입니다.

## 켜기·끄기

```sh
./scripts/burger-power.sh main status
./scripts/burger-power.sh main stop
./scripts/burger-power.sh main start
./scripts/burger-power.sh dev stop
./scripts/burger-power.sh all stop   # Burgerpedia main/dev만 중지
./scripts/burger-power.sh all start
```

- 중지: 배포 진행 여부 확인 → 태스크 수 기록 → 0으로 축소 → 태스크 실제 종료 확인 → DB·Redis 중지.
- 시작: DB·Redis 시작 → 인스턴스 상태·cloud-init·서비스 확인 → 태스크 수 복원 → 공개 API가 HTTP 200이 될 때까지 확인. 일시적인 502·503·연결 오류는 5초 간격으로 최대 60회 재확인하며, 실패해도 서버를 다시 끄지는 않습니다.
- 진행 중인 CodeDeploy 배포를 찾거나 상태 확인에 실패하면 전원 변경을 중단합니다.
- 재적용으로 중지 환경을 켜지 않도록 desired_count와 저장 태그는 Terraform drift 검사에서 제외합니다.
- 공통 모니터링·부하테스트기는 이 스크립트가 중지하지 않습니다.
- 중지는 비용 0원이 아닙니다. ALB, EBS, ECR, S3 등 보관 리소스 비용은 남습니다.
- 삭제 작업이 아닙니다. EC2 볼륨·데이터는 보존하며, 데이터 서버를 새로 생성하는 경우의 이관·백업은 별도입니다.

공통 서버도 직접 켜야 하는 경우에는 기존 스크립트를 사용합니다. 다른 프로젝트도 쓰므로
다른 실험이 진행 중인지 확인한 뒤 조작합니다.

```sh
./scripts/env-power.sh monitoring start
./scripts/env-power.sh load-generator start
```

## 공통 모니터링

`install-burger-monitoring.sh`는 기존 모니터링 EC2에 SSM으로 추가 설정을 설치합니다.
기존 Prometheus scrape job을 보존하고 promtool 검증 후 reload하며, Grafana 데이터는 삭제하지 않습니다.
공통 서버를 다시 생성하면 이 설치 스크립트를 다시 실행합니다.

- 15초마다 ECS 태스크 목록을 조회해 Prometheus file_sd를 갱신합니다. 배포 중 blue/green 태스크 모두 수집합니다.
- 조회 실패 시 이전 target 파일을 보존합니다. 워커 오류는 `journalctl -u burger-discovery.service`로 확인합니다.
- 앱 3000은 API, 8081은 내부 management 전용입니다. ALB는 8081 readiness로 검사합니다.
- Prometheus/JVM/HTTP histogram을 활성화하고 management endpoint는 ALB·모니터링 SG로만 접근합니다.
- DB·Redis·node exporter를 함께 수집합니다.
- Grafana의 `Burgerpedia backend and load tests` 대시보드에서 main/dev를 선택합니다.
- `project="burger"` 라벨로 기존 서비스와 분리합니다.
- API RPS, p95/p99, JVM heap, 프로세스 CPU, Hikari 연결, MySQL 연결·slow query,
  Redis 메모리, 데이터 서버 CPU, k6 지표를 표시합니다.
- 프로세스 CPU는 Fargate 태스크 전체 CPU 사용률과 다른 지표입니다. 컨테이너·네트워크 전체 지표는 후속 확장 대상입니다.

MySQL·Redis가 꺼져 있으면 exporter up=0이 정상입니다. 앱 검색 부하가 없으면 일부 패널은
데이터가 없을 수 있습니다. 기존 Bangjjack 경보는 변경하지 않았고, Burgerpedia용
호스트 장애 알림 라우팅은 별도로 추가해야 합니다. CodeDeploy의 5xx 롤백 경보는 포함되어 있습니다.

## 공통 부하테스트기

```sh
./scripts/burger-loadtest.sh main 10 1m
./scripts/burger-loadtest.sh dev 50 5m '/v1/posts/search?keyword=burger&limit=20'
```

실제 검색 API의 파라미터 계약을 확인하고 path를 지정합니다. 기본 시나리오는 공개 게시글
목록을 호출하는 인프라 smoke용이며, 검색 최적화 성과를 측정하는 최종 시나리오가 아닙니다.
기존 서버의 k6를 사용하고 기존 테스트 파일·결과는 덮어쓰지 않습니다.
결과는 공통 Prometheus로 전송하며 project/env/testid를 붙입니다.
동일한 공통 부하기에서 기존 프로젝트 테스트와 동시에 실행하면 자원 경쟁이 생기므로
비교 측정은 실험을 분리해서 수행합니다.
결과 파일은 공통 부하기의 `/opt/loadtest/burger/<testid>/`에 남습니다.
스크립트가 출력하는 SSM 명령 ID로 실행 상태를 확인하고, 중단은 해당 SSM 명령에
`aws ssm cancel-command`를 사용합니다. 취소 후 k6 프로세스 종료 여부도 확인합니다.

## 이미지·데이터·후속 검색 작업

Fargate 로컬 디스크에 업로드 파일을 보관하지 않습니다. 환경별 private S3와
CloudFront OAC를 사용하며 이미지 경로만 CDN에서 읽을 수 있습니다.
로그는 환경별 CloudWatch Log Group에 14일 보관합니다.
MySQL·Redis의 EC2/EBS 스냅샷 정기 백업은 이번 구성에 추가하지 않았습니다.

기존 게시글 CRUD는 메뉴·평점·태그가 있는 버거 리뷰로 전환했습니다. 메뉴·리뷰 검색은 MySQL LIKE 기반이며, 커뮤니티 내부 종목 조회·동기화 코드는 제거했습니다. 새 배포에는 종목 서버 연결이 필요 없습니다.
Elasticsearch는 Redis/ElastiCache와 다른 검색엔진이며 이번에 생성하지 않습니다.
검색 도입 때 전용 검색 노드와 동기화·모니터링을 별도 추가합니다.

## 로컬 검증

```sh
terraform fmt -check -recursive modules/burger
terraform validate
python3 -m unittest discover -s tests -v
# community-service에서:
./gradlew test bootJar
```

## 실제 적용 검증

- 새 plan의 추가 리소스만 검증한 뒤 86개 + 4개를 단계적으로 적용했습니다.
- 기존 인프라 리소스의 변경·삭제는 없었습니다.
- main/dev HTTPS 게시글 API의 HTTP 200과 전용 MySQL·Redis exporter 정상 연결을 확인했습니다.
- 공통 Prometheus의 기존 24개 대상을 유지하고 Burgerpedia 10개 대상이 모두 up인 것을 확인했습니다.
- JVM·HTTP·Hikari·MySQL·Redis 지표와 Grafana의 12개 패널 대시보드 로딩을 확인했습니다.
- main/dev에서 동일 이미지의 새 리비전으로 CodeDeploy 블루·그린 전환을 실행해 모두 Succeeded를 확인했습니다.
- 사용자 승인 후 BURGER_DEPLOY_ENABLED=true를 설정했습니다. 워크플로를 원격에 푸시하면 브랜치별 자동 배포가 활성화됩니다.
- GitHub Actions의 실제 OIDC 실행은 해당 워크플로 커밋을 원격에 푸시한 뒤 검증해야 합니다.
- 장애를 주입하는 자동 롤백 검증과 데이터 복구 실험은 별도 작업입니다.

## 검색 실험 데이터·부하·품질 평가

버거 도메인 전환 이후의 재현 가능한 데이터 생성, main/dev 검색 부하 비교, 수동 정답 기반 품질 평가는 [검색 실험 가이드](monitoring/burger/EXPERIMENTS.md)를 참고합니다. 기존 `burger-loadtest.sh`는 인프라 smoke용으로 유지하며 새 검색 실험은 `scripts/burger-experiment.py`로 실행합니다.
