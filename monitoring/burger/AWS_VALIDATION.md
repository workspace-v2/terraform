# AWS 검색 실험 실행 검증 — 2026-11-05

프로필 `personal-project`, 리전 `ap-northeast-2`에서 데이터 생성·적재·SSM 실행·k6·Prometheus·결과 회수 경로를 검증했다. 낮은 부하의 실행 검증이며 성능 최적화 성과나 처리량 한계를 측정한 실험은 아니다.

## 적재 데이터

- 환경마다 합성 브랜드 100개, 합성 메뉴 3,000개, 합성 작성자 1,000명, 합성 리뷰 10,000건. 댓글 0건.
- seed: `20261105`, ID 기준: `1000000000`, Flyway V6 적용 확인.
- 양쪽 적재 후 테이블별 건수 검증 및 동일 manifest 확인.
- 데이터 SHA-256: `e23a636dbf1952a70a3de9cd518800d9bbfaa3608862ab0e733dc743292fbe21`.
- 기존 데이터를 삭제하거나 초기화하지 않았다. 생성된 실험 작성자는 로그인할 수 없다.

## 실행 조건

- 앱 코드: main/dev 모두 `fe0e393` 기준. 환경별 별도 이미지 빌드이며 실제 image digest는 각 summary에 기록.
- Fargate: 각 1개, 1 vCPU / 2 GiB. MySQL t3.small, Redis t3.micro.
- 같은 공통 부하기에서 main 완료 후 dev 실행. `mixed` 검색, 목표 2 RPS, 워밍업 15초, 본 측정 30초, VU 5~10, limit 10.
- 워밍업은 본 측정 검색 통계에서 제외. 두 환경의 데이터/검색어 해시와 자원/실행 조건 비교 검증 통과.

## 관측값

| 환경 | 완료 요청 | 본 측정 완료 RPS | p95 (ms) | p99 (ms) | 오류율 | dropped iterations |
|---|---:|---:|---:|---:|---:|---:|
| main | 61 | 2.033 | 151.31 | 167.81 | 0% | 0 |
| dev | 60 | 2.000 | 169.08 | 174.51 | 0% | 0 |

짧은 실행의 경계 요청과 종료 여유로 main은 61건, dev는 60건이다. 완료 RPS는 완료 건수 / 설정한 30초로 계산한다. 같은 코드의 단일 짧은 실행이므로 두 지연값의 차이를 개선 또는 회귀로 해석하지 않는다. 반복·교차 순서 실험이 필요하다.

- 양쪽 모두 JVM 프로세스 CPU, heap, DB 연결, DB 질의율, 호스트 CPU, scrape 상태의 6개 Prometheus 쿼리가 데이터를 반환했다.
- 수집 구간에서 양쪽 각 5개 scrape 대상이 모두 UP이었다. 앱 프로세스 CPU와 Fargate 전체 CPU는 구분한다.
- 품질 평가용 정답은 아직 사람 검수 전이므로 Precision/NDCG 측정값은 생성하지 않았다.

## 도구 전달과 산출물

- 공통 부하기의 `/opt/loadtest/burger/tools/`에 dataset.py, search.js, quality.py, collect_metrics.py, compare.py와 SOURCE_REVISION을 전달했다.
- 원격 실행별 디렉터리에 설정·summary·monitoring·output.log를 보존했다.
- 로컬 원본: `loadtest-results/burger/aws-smoke-main-r1/`, `loadtest-results/burger/aws-smoke-dev-r1/`.
- 조건 비교 결과: `loadtest-results/burger/aws-smoke-comparison-r1.json`.
- SQL 번들·원본 결과는 Git 제외 대상이다. 이 문서는 원본 결과에서 추출한 요약이다.
- 실행 절차: [EXPERIMENTS.md](EXPERIMENTS.md).

## 적용 범위

이번 실험 도구는 SSM으로 직접 전달했으며 신규 AWS 리소스가 필요하지 않아 Terraform apply를 수행하지 않았다. 기존 variables.tf의 별도 FIS 시간 변경은 이번 커밋/적용에서 제외했다.

검증 종료 후 활성 k6 프로세스가 없음을 확인하고 공통 부하기는 원래의 중지 상태로 복원했다. main/dev 앱·DB·Redis와 공통 모니터링은 실행 상태를 유지한다. 다음 부하 실행 전에 `./scripts/env-power.sh load-generator start`로 부하기를 켠다.
