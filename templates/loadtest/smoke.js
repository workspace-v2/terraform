// 기본 스모크/부하 시나리오. 인증 없이 열려 있는 API 문서 엔드포인트를 호출한다.
// 실제 API 시나리오(로그인 토큰, WebSocket 채팅)는 이 파일을 복사해서 작성.
import http from 'k6/http';
import { check, sleep } from 'k6';

export const options = {
  stages: [
    { duration: '30s', target: 10 },
    { duration: '1m', target: 10 },
    { duration: '30s', target: 0 },
  ],
  thresholds: {
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(95)<500'],
  },
};

export default function () {
  const res = http.get(`${__ENV.BASE_URL}/v3/api-docs`);
  check(res, { 'status 200': (r) => r.status === 200 });
  sleep(1);
}
