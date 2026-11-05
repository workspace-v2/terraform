# Burgerpedia 검색 실험

데이터 생성, 부하테스트, 검색 품질 평가 도구를 Terraform 저장소에서 관리한다. 앱 검색 코드는 변경하지 않는다. 기존 smoke용 `scripts/burger-loadtest.sh`와 기존 프로젝트의 시나리오·결과를 유지한다.

## 1. 데이터 생성

Python 3 표준 라이브러리만 사용한다. 생성기는 AWS·DB에 접속하지 않고 SQL과 실험 산출물만 만든다.

```sh
cd /Users/xezi/workspace/workspace-v2/terraform
python3 monitoring/burger/dataset.py \
  --profile 10k --seed 20261105 \
  --output loadtest-data/burger/10k
```

| 항목 | 기본값·옵션 |
|---|---|
| 브랜드·메뉴 | 합성 브랜드 100개, 합성 메뉴 3,000개 |
| 리뷰 | `--profile 10k`, `100k`, `1m` |
| 작성자 | 검색 전용 합성 작성자 1,000명, 로그인 불가 비밀번호 |
| 댓글 | 기본 0개. `--comments-per-review 1` 또는 `2`; 100만 리뷰에서 최대 200만 댓글 |
| ID 범위 | 기본 `1000000000 + 일련번호`, `--id-base`로 변경 가능 |
| 시간 | 2026년 1월의 고정 합성 시각. 현재 시각을 사용하지 않음 |

산출물:

- `dataset.sql`: 기존 MySQL V6 스키마용 INSERT. 250행 단위 트랜잭션, 스트리밍 생성.
- `manifest.json`: seed·버전·규모·ID 범위·건수·데이터 SHA-256·검색어 SHA-256.
- `catalog.json`: 메뉴/브랜드와 데이터 출처. 기본 데이터는 전부 SYNTHETIC이다.
- `workload.json`: 일반어·태그·메뉴명·긴 질의·미검색 의도를 섞은 가중치 검색어 목록.
- `judgments-template.json`: 기본 합성 카탈로그 기준 100개 검수 양식. 모든 항목은 `judged=false`, 정답 등급은 비워 둔다.

동일 seed·ID 기준·카탈로그이면 규모가 커져도 앞쪽 리뷰의 내용은 같다. 리뷰별 독립 난수를 사용하며 약 70%를 앞쪽 20% 메뉴에 배정한다. 식사 맥락·식감·평가·가격 의견·재구매 의도를 조합한다. 이는 통제된 합성 분포이며 실제 사용자 분포를 대변하지 않는다. 합성 데이터에서 얻은 품질 결과를 실제 서비스의 검색 정확도로 일반화하지 않는다.

가격/재료 설명은 합성 메뉴의 설정이고 태그는 합성 작성자의 주관적 평가다. 재료 제외의 정답이나 실제 영양 정보로 쓰지 않는다. SQL 문자열은 UTF-8 hex literal로 출력해 따옴표/백슬래시에 따른 SQL mode 차이를 피한다. 산출물은 Git에서 제외한다.

### 실제 메뉴 입력

직접 수집하고 사용 조건·내용을 검수한 CSV를 넣을 수 있다. 이 도구는 메뉴를 수집하거나 출처의 정확성을 대신 검증하지 않는다.

```csv
brand,name,description,price,source_url
검수한 브랜드,검수한 메뉴,검수한 설명,6900,https://example.com/verified-menu
```

```sh
python3 monitoring/burger/dataset.py --profile 10k \
  --real-catalog /절대경로/검수한-메뉴.csv \
  --output loadtest-data/burger/real-10k
```

CSV는 1~3,000개 메뉴를 지원한다. 가격이 미확인이면 빈 값으로 두고 NULL로 저장한다. 메뉴는 REAL, 리뷰는 계속 SYNTHETIC이다. 아래 원격 `seed` 명령은 합성 카탈로그 전용이다. 실제 CSV 산출물은 별도 데이터 전송/SQL 적재 절차와 적재 manifest 등록이 필요하며, 자동으로 AWS에 전송하지 않는다.

### 양쪽 DB에 동일 데이터 적재

main/dev에 버거 도메인 코드가 배포되어 V6 스키마가 있어야 한다. DB 서버가 실행 중이어야 한다. 원격 적재는 DB EC2의 SSM을 통해 로컬 소켓의 MySQL root로 실행하며, 비밀번호를 스크립트나 로그에 넣지 않는다.

```sh
python3 scripts/burger-experiment.py seed main loadtest-data/burger/10k
python3 scripts/burger-experiment.py seed dev  loadtest-data/burger/10k
```

명령은 비동기로 제출된다. 출력된 `Receipt:` 경로를 사용해 각각 완료를 확인한다.

```sh
python3 scripts/burger-experiment.py status '출력된-receipt.json-경로' --wait
```

적재 전 V6 컬럼과 예약 ID 범위 충돌을 확인한다. 디스크는 최소 4GiB, SQL 크기에 따라 더 큰 여유 공간을 요구한다. 서버에서 같은 생성기를 실행하고 로컬 manifest와 데이터 SHA-256이 일치해야 INSERT한다. 적재 후 테이블별 건수가 일치해야 `loaded.json` 성공 표식을 남긴다. 기존 데이터 삭제·TRUNCATE·INSERT IGNORE는 하지 않는다.

성공한 동일 데이터는 중복 적재하지 않는다. 적재가 일부 실패한 경우 부분 INSERT가 남을 수 있으며 재시도는 ID 충돌로 거부한다. 자동 롤백·정리 기능은 없다. `10k → 100k → 1m`은 기존 데이터에 자동 덧붙이는 방식이 아니므로 각 규모의 깨끗한 실험 DB/스냅샷을 준비한다. 임의로 ID 범위를 바꿔 누적하면 규모가 달라져 비교할 수 없다. 명시적 ID INSERT로 AUTO_INCREMENT가 증가하므로 실험 데이터 적재 대상 DB를 분리·관리한다.

## 2. 검색 부하테스트

공통 부하테스트기와 모니터링을 사용한다. 새 리소스나 Elasticsearch를 생성하지 않는다.

```sh
./scripts/env-power.sh monitoring start
./scripts/env-power.sh load-generator start
```

기존 서버의 k6·Python 3·flock을 사용한다. 실행기는 Terraform 출력에서 대상 URL/인스턴스/모니터링 주소를 읽는다. `AWS_PROFILE_NAME` 기본값은 `personal-project`다.

먼저 main에 실행한다.

```sh
python3 scripts/burger-experiment.py load main loadtest-data/burger/10k \
  --experiment like-baseline-r1 --endpoint mixed \
  --rps 10 --warmup 60 --seconds 300
```

출력된 receipt로 **완료를 기다린 다음** 같은 조건으로 dev를 실행한다.

```sh
python3 scripts/burger-experiment.py status 'main에서-출력된-receipt.json-경로' --wait
python3 scripts/burger-experiment.py load dev loadtest-data/burger/10k \
  --experiment like-baseline-r1 --endpoint mixed \
  --rps 10 --warmup 60 --seconds 300
```

| 옵션 | 의미 |
|---|---|
| `--endpoint mixed` | 메뉴·리뷰·통합 검색을 결정적 순서로 혼합 |
| `--endpoint menus` | `/v1/menus`, 일부 질의에 brandId 필터 |
| `--endpoint reviews` | `/v1/posts/search`, 일부 질의에 menuId 필터 |
| `--endpoint combined` | `/v1/search`, 메뉴·리뷰 각각 첫 페이지 |
| `--rps` | 초당 예약 요청 수. 응답 RPS와 구분 |
| `--warmup` / `--seconds` | 워밍업 / 본 측정 시간(초) |
| `--vus` / `--max-vus` | 미리 준비할 VU / 최대 VU, 기본 50 / 500 |
| `--limit` | 페이지 크기, 기본 10, 최대 100 |
| `--experiment` | main/dev에 동일하게 넣는 실험·반복 식별자 |

constant-arrival-rate로 요청을 예약한다. VU 스케줄에 독립적인 iteration 번호와 seed로 질의를 선택한다. 한 iteration에서 HTTP 요청은 한 번이다. 워밍업의 최대 10초 종료 여유 뒤 본 측정을 시작하고, 검색 지연·오류율·요청 수 사용자 지표에는 본 측정만 넣는다. CPU 수집도 본 측정 시각을 기준으로 한다.

실험 전 적재 성공 manifest, ECS 실행 수·단일 task revision, CodeDeploy 진행 여부를 확인하고 이미지 digest·태스크 정의·태스크 CPU/메모리·DB/Redis 인스턴스 유형을 기록한다. 이 기록은 적재 시점의 데이터 지문이며 DB가 나중에 수정되지 않았음을 증명하지는 않는다. 실험 중 쓰기·데이터 변경·배포를 중지하고 양쪽 데이터 상태를 직접 유지한다.

- 성공 응답의 JSON 구조도 검사한다. HTTP 200만으로 성공 처리하지 않는다.
- 본 측정 오류율 1% 미만, dropped iterations 0을 요구한다. 실패한 실행은 정상 성능 개선 비교에서 제외한다.
- `completedRps`는 완료 요청 수 / 설정된 본 측정 시간이다. 종료 후 최대 10초 동안 마무리된 요청도 포함될 수 있다. 짧은 smoke 실행에서 경계 요청 때문에 목표 RPS와 정확히 같지 않을 수 있다.
- 태그는 `project`, `env`, `testid`, `experiment`, `endpoint`, `phase`로 분리한다. 결과에는 p95/p99·오류율·빈 결과 비율·실행 조건을 남긴다. 빈 결과 비율은 검색 품질 지표가 아니다.
- 같은 공통 부하 서버의 새 Burgerpedia 실험은 flock으로 동시 실행을 거부한다. 기존 프로젝트 부하 스크립트는 이 잠금을 사용하지 않으므로 운영자가 별도로 동시 실행을 피해야 한다.

RPS 10 → 25 → 50 → 100은 각 실행이 끝난 뒤 단계적으로 올린다. 처음부터 100만 건·높은 RPS를 동시에 적용하지 않는다. 같은 조건으로 최소 3회 반복하고 main→dev, dev→main 순서를 바꾼다. t3 CPU 크레딧, 동일 서버의 다른 부하, JVM/DB 캐시 상태도 확인한다. main/dev가 같은 커밋일 때부터 환경 편차를 먼저 확인한다.

### 결과와 CPU·DB 지표 회수

```sh
python3 scripts/burger-experiment.py fetch 'main에서-출력된-receipt.json-경로' \
  --output loadtest-results/burger/main-r1
python3 scripts/burger-experiment.py fetch 'dev에서-출력된-receipt.json-경로' \
  --output loadtest-results/burger/dev-r1
python3 monitoring/burger/compare.py \
  loadtest-results/burger/main-r1/summary.json \
  loadtest-results/burger/dev-r1/summary.json
```

실행 중에는 회수를 거부한다. 실패한 실행도 회수할 수 있다. 원격 결과는 `/opt/loadtest/burger/<runId>/`, 로컬 receipt는 `loadtest-results/burger/receipts/`에 보관한다. SSM 출력 길이 제한을 넘지 않도록 압축 결과를 여러 조각으로 가져온다. 기존 로컬 파일은 덮어쓰지 않는다. 결과 요약과 마지막 100줄의 로그를 가져온다.

`summary.json`은 실행 조건·배포 이미지·측정값, `monitoring.json`은 Prometheus의 JVM 프로세스 CPU·heap·DB 연결/질의·호스트 CPU·scrape 상태 시계열이다. CPU는 Fargate 전체 컨테이너 CPU가 아니다. `rate[1m]`은 측정 시작 전 1분의 lookback을 포함한다. 수집 실패/빈 시계열을 0으로 만들지 않고 `failed`/`no-data`로 남긴다. CPU 자료가 없으면 CPU 개선을 주장하지 않는다.

비교기는 데이터/검색어 SHA-256, seed, endpoint, RPS, 워밍업/본 측정 시간, limit, VU 설정, 서버 사양, experiment가 다르면 거부한다. 지연 변화율이 음수이면 감소다. 단일 실행의 변화율은 통계적 유의성을 뜻하지 않는다. CPU는 monitoring.json/Grafana에서 같은 측정 구간을 별도로 비교한다. 자동적인 CPU 개선율 계산이나 유의성 검정은 하지 않는다.

## 3. 검색 품질 평가 — 부하와 별도 실행

`quality.py`는 서버를 압박하는 스크립트가 아니라 검수한 정답 문서와 상위 10개 검색 결과를 비교하는 도구다. 메뉴와 리뷰는 문서 ID 공간을 구분하며 각각 평가한다. 통합 응답의 두 묶음을 합쳐 전역 순위를 만들지 않는다.

1. 생성된 `judgments-template.json`을 복사한다.
2. 검색 의도를 구체화하고 메뉴·리뷰의 실제 문서를 읽어 관련 문서 ID와 등급을 입력한다.
3. `judged`를 true로 바꾼다. 등급은 0=무관, 1=약한 관련, 2=관련, 3=매우 관련이다.
4. main/dev에서 얻은 후보 문서를 함께 검수한다. 기존 정답 파일에 없는 상위 결과는 재검수 후 양쪽을 다시 평가한다.

예시 구조(숫자는 양식 설명용이며 정답 데이터가 아님):

```json
{
  "schemaVersion": 1,
  "datasetSha256": "manifest.json의 datasetSha256 값",
  "queries": [{
    "id": "menus-001",
    "target": "menus",
    "keyword": "치즈",
    "intent": "메뉴명과 설명에서 치즈가 핵심인 메뉴",
    "judged": true,
    "grades": {"실제문서ID": 3, "검수한무관문서ID": 0},
    "expectedEmpty": false
  }]
}
```

로컬에서 평가할 수도 있다.

```sh
python3 monitoring/burger/quality.py \
  --base-url https://main-burger.pattie.cloud \
  --judgments loadtest-data/burger/judgments-reviewed.json \
  --output loadtest-results/burger/quality-main.json
```

공통 부하테스트 서버에서 실행하려면:

```sh
python3 scripts/burger-experiment.py quality main loadtest-data/burger/10k \
  --judgments loadtest-data/burger/judgments-reviewed.json
python3 scripts/burger-experiment.py quality dev loadtest-data/burger/10k \
  --judgments loadtest-data/burger/judgments-reviewed.json
```

두 명령도 동일한 잠금을 사용하므로 첫 실행 완료를 확인한 뒤 다음을 제출한다. status/fetch는 부하 실행과 같다. 결과 파일 이름은 `quality.json`이다.

Precision@10은 등급 1 이상 문서 수 / 10으로 계산한다. 결과가 10개 미만이어도 분모는 10이다. NDCG@10은 gain=`2^grade-1`, 할인=`log2(rank+1)`, 검수한 관련 문서의 이상적 순서를 사용한다. 정답 풀이 전체 관련 문서를 완전히 포괄하지 않을 수 있으므로 풀 구성과 검수 범위를 함께 기록한다. 결과가 없어야 하는 질의는 `expectedEmpty=true`로 별도 empty accuracy를 계산하고 Precision/NDCG 평균에서 제외한다.

미검수 질의·정답 풀에 없는 검색 결과·조회 실패가 있으면 `complete=false`, aggregate=null, 종료 코드 2로 끝낸다. 양식만으로 정확도 수치를 만들지 않는다. `--allow-unjudged`도 임시 개별 점수만 남기고 최종 평균을 만들지 않는다. 자동 관련도 판정이나 사람 검수 대체는 구현하지 않았다.

## 검증

```sh
python3 -m unittest discover -s tests -v
python3 -m py_compile scripts/burger-experiment.py monitoring/burger/*.py
```

로컬에서 실제 MySQL 8.0에 100브랜드/3,000메뉴/1만 리뷰를 적재하고 댓글 옵션을 검증했다. 10만 건 생성도 확인했다. 실제 k6는 로컬 임시 HTTP 서버로 워밍업 분리·한글 인코딩·측정 요약을 검증했다. 이 결과는 AWS 부하 측정이나 검색 성능 개선 수치가 아니다. 원격 SSM 전달·양쪽 1만 리뷰 적재·낮은 RPS 실행·모니터링/결과 회수도 검증했다. 실제 관측값과 한계는 [AWS 실행 검증 기록](AWS_VALIDATION.md)을 참고한다. 이후 본 측정은 운영자가 동일 조건으로 반복 수행한다.

참고: [k6 시나리오](https://grafana.com/docs/k6/latest/using-k6/scenarios/), [k6 내장 지표](https://grafana.com/docs/k6/latest/using-k6/metrics/reference/).
