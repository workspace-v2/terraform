// HTTP API 처리량·병목 측정 (k6) — [진행8]
//
// 로그인한 사용자들이 채팅 API 를 호출하는 상황을 초당 요청 수(RPS)를 단계적으로 올리며 재현한다.
//   요청 구성(가중치): 채팅방 목록 GET /chat-rooms (ROOMS) / 메시지 조회 GET /chat-rooms/{id}/messages (MESSAGES)
//                     / WebSocket 토큰 발급 POST /auth/ws-token (WSTOKEN)
// 결과: 단계(목표 RPS)별 실제 처리 RPS, 실패율(2xx 아님·타임아웃), 지연 p50/p95/p99, API 별 p99
//   → 지연·실패가 급격히 나빠지는 RPS = 처리 한계. 그때 Grafana 에서 먼저 포화된 자원 = 병목
//
// 실행: SCRIPT=http-load.js chattest <main|dev>
//   기본: 태스크 IP 로 직접 (ALB 제외, 서버 자체 한계)
//   BASE_URL=https://main.<도메인> : ALB 경유 (WAF 붙인 뒤 비교할 때)
// 환경 변수
//   STEPS      단계별 목표 RPS, 쉼표 (기본 50,100,200,400,800)
//   STEP       단계 유지 초 (기본 60, 단계 사이 5초 상승 구간은 집계에서 제외)
//   USERS      사용할 시드 사용자 수 (기본 200)
//   MAX_VUS    최대 VU (기본 1000. 부족하면 dropped_iterations 가 늘고 목표 RPS 를 못 채움)
//   ROOMS / MESSAGES / WSTOKEN  요청 가중치 (기본 5 / 4 / 1)
//   TIMEOUT    요청 타임아웃 (기본 5s)
import http from 'k6/http';
import exec from 'k6/execution';
import { fail } from 'k6';
import { Counter, Trend } from 'k6/metrics';

const IPS = (__ENV.TASK_IPS || '').split(',').map((s) => s.trim()).filter(Boolean);
const BASE_URL = (__ENV.BASE_URL || '').replace(/\/$/, '');
if (!BASE_URL && IPS.length === 0) fail('TASK_IPS 또는 BASE_URL 필요');
const USERS = JSON.parse(open(__ENV.USERS_FILE));
const STEPS = (__ENV.STEPS || '50,100,200,400,800').split(',').map((s) => parseInt(s.trim(), 10));
const STEP_S = parseInt(__ENV.STEP || '60', 10);
const RAMP_S = 5;
const N_USERS = Math.min(parseInt(__ENV.USERS || '200', 10), USERS.length);
const MAX_VUS = parseInt(__ENV.MAX_VUS || '1000', 10);
const W = { rooms: parseInt(__ENV.ROOMS || '5', 10), messages: parseInt(__ENV.MESSAGES || '4', 10), wstoken: parseInt(__ENV.WSTOKEN || '1', 10) };
const TIMEOUT = __ENV.TIMEOUT || '5s';
const DEV_SECRET = __ENV.DEV_SECRET;

const reqs = new Counter('http_load_requests');     // 측정 구간 요청 수 (step, api)
const fails = new Counter('http_load_failures');    // 2xx 아님 또는 타임아웃 (step, api, status)
const lat = new Trend('http_load_latency_ms', true); // 측정 구간 지연 (step, api)

const stages = [];
STEPS.forEach((rps) => {
  stages.push({ target: rps, duration: `${RAMP_S}s` });
  stages.push({ target: rps, duration: `${STEP_S}s` });
});
const thresholds = { dropped_iterations: ['count>=0'] };
STEPS.forEach((_, i) => {
  thresholds[`http_load_requests{step:${i}}`] = ['count>=0'];
  thresholds[`http_load_failures{step:${i}}`] = ['count>=0'];
  thresholds[`http_load_latency_ms{step:${i}}`] = ['p(99)>=0'];
  for (const api of ['rooms', 'messages', 'wstoken']) thresholds[`http_load_latency_ms{step:${i},api:${api}}`] = ['p(99)>=0'];
});

export const options = {
  scenarios: {
    http: {
      executor: 'ramping-arrival-rate',
      startRate: STEPS[0],
      timeUnit: '1s',
      preAllocatedVUs: Math.min(200, MAX_VUS),
      maxVUs: MAX_VUS,
      stages,
    },
  },
  setupTimeout: '5m',
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(95)', 'p(99)'],
  thresholds,
};

// 요청마다 대상 서버: BASE_URL(ALB) 또는 태스크 IP 를 번갈아
function base(i) {
  return BASE_URL || `http://${IPS[i % IPS.length]}:8080`;
}

export function setup() {
  if (!DEV_SECRET) fail('DEV_SECRET is empty');
  const users = [];
  for (let i = 0; i < N_USERS; i++) {
    const res = http.post(`${base(0)}/api/v1/dev/token/user`, JSON.stringify({ userId: USERS[i] }), {
      headers: { 'Content-Type': 'application/json', 'X-Dev-Secret': DEV_SECRET }, tags: { name: 'setup' },
    });
    if (res.status < 200 || res.status >= 300) fail(`dev token failed user=${USERS[i]} status=${res.status}`);
    const token = res.json('data.accessToken');
    const list = http.get(`${base(0)}/api/v1/chat-rooms?size=20`, { headers: { Authorization: `Bearer ${token}` }, tags: { name: 'setup' } });
    const rooms = list.status === 200 ? (list.json('data.rooms') || []).map((r) => r.roomId) : [];
    users.push({ token, rooms });
  }
  const withRooms = users.filter((u) => u.rooms.length > 0).length;
  console.log(`setup: users ${users.length} (방 있는 사용자 ${withRooms}), steps=${STEPS.join(',')} rps x ${STEP_S}s, target=${BASE_URL || IPS.join(',')}`);
  return { users, startAt: Date.now() };
}

// 지금 몇 번째 단계인지. 상승 구간이면 -1 (집계 제외)
function stepNow(startAt) {
  const t = (Date.now() - startAt) / 1000;
  const per = RAMP_S + STEP_S;
  const i = Math.floor(t / per);
  if (i >= STEPS.length) return -1;
  return t - i * per < RAMP_S ? -1 : i;
}

function pickApi(user) {
  const total = W.rooms + (user.rooms.length > 0 ? W.messages : 0) + W.wstoken;
  let r = Math.random() * total;
  if ((r -= W.rooms) < 0) return 'rooms';
  if (user.rooms.length > 0 && (r -= W.messages) < 0) return 'messages';
  return 'wstoken';
}

export default function (data) {
  const it = exec.scenario.iterationInTest;
  const user = data.users[it % data.users.length];
  const api = pickApi(user);
  const step = stepNow(data.startAt);
  const params = { headers: { Authorization: `Bearer ${user.token}` }, timeout: TIMEOUT, tags: { name: api } };
  const b = base(it);
  let res;
  if (api === 'rooms') {
    res = http.get(`${b}/api/v1/chat-rooms?size=20`, params);
  } else if (api === 'messages') {
    const roomId = user.rooms[Math.floor(Math.random() * user.rooms.length)];
    res = http.get(`${b}/api/v1/chat-rooms/${roomId}/messages?size=30`, params);
  } else {
    res = http.post(`${b}/api/v1/auth/ws-token`, null, params);
  }
  if (step < 0) return;
  const tags = { step: String(step), api };
  reqs.add(1, tags);
  lat.add(res.timings.duration, tags);
  lat.add(res.timings.duration, { step: String(step) });
  if (res.status < 200 || res.status >= 300) fails.add(1, { step: String(step), api, status: String(res.status) });
}

const c = (m, n) => (m[n] ? m[n].values.count : 0);
const q = (m, n, k) => (m[n] && m[n].values[k] !== undefined ? m[n].values[k].toFixed(0) : '-');

export function handleSummary(data) {
  const m = data.metrics;
  const lines = ['================ http load ================'];
  lines.push(`target: ${BASE_URL || IPS.join(', ')}   users: ${N_USERS}   step: ${STEP_S}s   weights rooms/messages/wstoken: ${W.rooms}/${W.messages}/${W.wstoken}   max VUs: ${MAX_VUS}`);
  lines.push(`dropped iterations (부하기가 목표 RPS 를 못 채움): ${c(m, 'dropped_iterations')}`);
  lines.push('step | target rps | actual rps | fail % | latency ms p50 / p95 / p99 / max | p99 rooms / messages / wstoken');
  STEPS.forEach((rps, i) => {
    const n = c(m, `http_load_requests{step:${i}}`);
    const f = c(m, `http_load_failures{step:${i}}`);
    const L = `http_load_latency_ms{step:${i}}`;
    const a = (api) => q(m, `http_load_latency_ms{step:${i},api:${api}}`, 'p(99)');
    lines.push(`  ${i}  | ${String(rps).padStart(5)} | ${(n / STEP_S).toFixed(1).padStart(7)} | ${n > 0 ? ((100 * f) / n).toFixed(2) : '-'}% | ${q(m, L, 'med')} / ${q(m, L, 'p(95)')} / ${q(m, L, 'p(99)')} / ${q(m, L, 'max')} | ${a('rooms')} / ${a('messages')} / ${a('wstoken')}`);
  });
  lines.push('(각 단계 앞 5초 상승 구간 제외. 실패 = 2xx 아님 또는 타임아웃)');
  lines.push('===========================================');
  const text = lines.join('\n') + '\n';
  return {
    stdout: text,
    [`/opt/loadtest/results/${__ENV.TEST_ID || 'http'}.txt`]: text,
    [`/opt/loadtest/results/${__ENV.TEST_ID || 'http'}.json`]: JSON.stringify(data, null, 2),
  };
}
