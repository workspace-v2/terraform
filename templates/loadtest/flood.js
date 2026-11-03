// 플러딩 사용자가 정상 사용자 전송에 주는 영향 측정 (k6, Raw WebSocket) — [진행8]
//
// 정상 사용자: PAIRS 개 1:1 방, 두 사용자를 서로 다른 서버에 연결, 각자 RATE/초로 전송 (chat-consistency 와 같은 방식)
// 플러딩 사용자: FLOODERS 개 1:1 방, 보내는 쪽이 STEPS 에 적힌 속도(초당 메시지 수)로 단계마다 STEP 초씩 전송
//   (상대는 다른 서버에 연결해 수신만 → 수신 서버 브로드캐스트 부하도 포함)
// 결과: 단계(플러딩 속도)별 정상 사용자 전달률·지연(p50/p95/p99)·거절, 플러딩 사용자 전송·거절
//   → 정상 사용자 지연이 나빠지기 시작하는 플러딩 속도 = 전송 제한 값의 근거
//
// 실행: SCRIPT=flood.js chattest <main|dev>
// 환경 변수
//   PAIRS      정상 방 수 (기본 10, 사용자 0..2*PAIRS-1)
//   RATE       정상 사용자당 초당 전송 수 (기본 1)
//   FLOODERS   플러딩 방 수 (기본 1, 사용자 FLOOD_BASE.. 부터 2명씩)
//   FLOOD_BASE 플러딩 사용자 시작 위치 (기본 80: 다른 시나리오 사용자와 겹치지 않게)
//   STEPS      단계별 플러딩 속도, 쉼표 (기본 0,20,50,100,200 msg/s)
//   STEP       단계 길이 초 (기본 30)
//   DRAIN      전송 종료 후 수신 대기 초 (기본 5)
import http from 'k6/http';
import ws from 'k6/ws';
import exec from 'k6/execution';
import { fail, sleep } from 'k6';
import { Counter, Trend } from 'k6/metrics';

const IPS = (__ENV.TASK_IPS || '').split(',').map((s) => s.trim()).filter(Boolean);
if (IPS.length < 2) fail('TASK_IPS 에 서버가 2개 이상 필요');
const USERS = JSON.parse(open(__ENV.USERS_FILE));
const PAIRS = parseInt(__ENV.PAIRS || '10', 10);
const RATE = parseFloat(__ENV.RATE || '1');
const FLOODERS = parseInt(__ENV.FLOODERS || '1', 10);
const FLOOD_BASE = parseInt(__ENV.FLOOD_BASE || '80', 10);
const STEPS = (__ENV.STEPS || '0,20,50,100,200').split(',').map((s) => parseFloat(s.trim()));
const STEP_S = parseInt(__ENV.STEP || '30', 10);
const DRAIN_S = parseInt(__ENV.DRAIN || '5', 10);
const DEV_SECRET = __ENV.DEV_SECRET;
const DURATION_S = STEPS.length * STEP_S;
const TICK_MS = 100; // 플러딩은 0.1초마다 (속도/10)개씩 묶어서 보낸다 (k6 타이머 정밀도)
if (USERS.length < Math.max(PAIRS * 2, FLOOD_BASE + FLOODERS * 2)) fail(`seeded users ${USERS.length} 부족 (loadtest-seed.sh)`);

const nSent = new Counter('flood_normal_sent');           // 정상 사용자 전송 (step)
const nErrors = new Counter('flood_normal_errors');       // 정상 사용자 전송 거절 (step, code)
const nReceived = new Counter('flood_normal_received');   // 정상 메시지 수신 (에코 + 상대, step = 보낸 시점 단계)
const nLatency = new Trend('flood_normal_latency_ms', true); // 정상 상대 메시지 전송 -> 수신 (step)
const fSent = new Counter('flood_flooder_sent');          // 플러딩 전송 (step)
const fErrors = new Counter('flood_flooder_errors');      // 플러딩 전송 거절 (step)
const fReceived = new Counter('flood_flooder_partner_received'); // 플러딩 상대가 받은 수 (step)
const closedEarly = new Counter('flood_ws_closed_early');  // 측정 중 서버가 연결을 닫음 (role)

const thresholds = {};
STEPS.forEach((_, i) => {
  for (const m of ['flood_normal_sent', 'flood_normal_errors', 'flood_normal_received', 'flood_flooder_sent', 'flood_flooder_errors', 'flood_flooder_partner_received']) {
    thresholds[`${m}{step:${i}}`] = ['count>=0'];
  }
  thresholds[`flood_normal_latency_ms{step:${i}}`] = ['p(99)>=0'];
});
thresholds['flood_ws_closed_early{role:normal}'] = ['count>=0'];
thresholds['flood_ws_closed_early{role:flooder}'] = ['count>=0'];

export const options = {
  scenarios: {
    flood: { executor: 'per-vu-iterations', vus: PAIRS * 2 + FLOODERS * 2, iterations: 1, maxDuration: `${DURATION_S + DRAIN_S + 90}s` },
  },
  setupTimeout: '3m',
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(95)', 'p(99)'],
  thresholds,
};

const api = (ip) => `http://${ip}:8080`;

function devToken(userId) {
  const res = http.post(`${api(IPS[0])}/api/v1/dev/token/user`, JSON.stringify({ userId }), {
    headers: { 'Content-Type': 'application/json', 'X-Dev-Secret': DEV_SECRET }, tags: { name: 'dev_token' },
  });
  if (res.status < 200 || res.status >= 300) fail(`dev token failed user=${userId} status=${res.status}`);
  return res.json('data.accessToken');
}

function room(a, b) {
  const ta = devToken(a);
  const tb = devToken(b);
  const res = http.post(`${api(IPS[0])}/api/v1/chat-rooms`, JSON.stringify({ targetUserId: b }), {
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${ta}` }, tags: { name: 'create_room' },
  });
  const roomId = res.status === 200 ? res.json('data.roomId') : null; // 새 방(201)·기존 방(200) 모두 data.roomId
  if (!roomId) fail(`create room failed ${a}-${b} status=${res.status} body=${res.body}`);
  return { roomId, a: { id: a, token: ta }, b: { id: b, token: tb } };
}

export function setup() {
  if (!DEV_SECRET) fail('DEV_SECRET is empty');
  const normal = [];
  for (let i = 0; i < PAIRS; i++) normal.push(room(USERS[i * 2], USERS[i * 2 + 1]));
  const flood = [];
  for (let i = 0; i < FLOODERS; i++) flood.push(room(USERS[FLOOD_BASE + i * 2], USERS[FLOOD_BASE + i * 2 + 1]));
  console.log(`setup: normal ${PAIRS} rooms rate=${RATE}/s, flooders ${FLOODERS}, steps=${STEPS.join(',')} msg/s x ${STEP_S}s, servers=${IPS.join(',')}`);
  return { normal, flood, runId: Date.now(), startAt: Date.now() + 5000 };
}

function stepAt(data, t) {
  const i = Math.floor((t - data.startAt) / (STEP_S * 1000));
  return Math.min(Math.max(i, 0), STEPS.length - 1);
}

export default function (data) {
  const vu = exec.vu.idInTest - 1;
  const isFlood = vu >= PAIRS * 2;
  const idx = isFlood ? vu - PAIRS * 2 : vu;
  const pairIndex = Math.floor(idx / 2);
  const side = idx % 2 === 0 ? 'a' : 'b';
  const pair = isFlood ? data.flood[pairIndex] : data.normal[pairIndex];
  const me = pair[side];
  const role = isFlood ? (side === 'a' ? 'flooder' : 'flood_partner') : 'normal';
  // 방의 두 사용자를 서로 다른 서버에 (정상 방은 방마다 번갈아, 플러딩 보내는 쪽은 IPS[0])
  const ip = isFlood ? IPS[side === 'a' ? 0 : 1] : IPS[(pairIndex + (side === 'a' ? 0 : 1)) % IPS.length];
  const sendUntil = data.startAt + DURATION_S * 1000;
  const closeAt = sendUntil + DRAIN_S * 1000;

  const tokenRes = http.post(`${api(ip)}/api/v1/auth/ws-token`, null, { headers: { Authorization: `Bearer ${me.token}` }, tags: { name: 'ws_token' } });
  const wsToken = tokenRes.json('data.wsToken');
  if (!wsToken) fail(`ws-token failed user=${me.id} status=${tokenRes.status}`);
  let closing = false;
  let seq = 0;

  ws.connect(`ws://${ip}:8080/ws/chat?token=${wsToken}`, { tags: { server: ip, role } }, (socket) => {
    socket.on('open', () => {
      const send = (step) => {
        seq += 1;
        const content = JSON.stringify({ lt: 4, run: data.runId, step, ts: Date.now(), from: me.id, role });
        socket.send(JSON.stringify({ type: 'SEND', roomId: pair.roomId, content }));
      };
      if (role === 'normal') {
        const offset = Math.random() * (1000 / RATE);
        socket.setTimeout(() => {
          socket.setInterval(() => {
            const now = Date.now();
            if (now >= sendUntil) return;
            const step = stepAt(data, now);
            send(step);
            nSent.add(1, { step: String(step) });
          }, 1000 / RATE);
        }, Math.max(1, data.startAt + offset - Date.now()));
      } else if (role === 'flooder') {
        let carry = 0;
        socket.setTimeout(() => {
          socket.setInterval(() => {
            const now = Date.now();
            if (now >= sendUntil) return;
            const step = stepAt(data, now);
            carry += (STEPS[step] * TICK_MS) / 1000;
            const n = Math.floor(carry);
            carry -= n;
            for (let k = 0; k < n; k++) send(step);
            if (n > 0) fSent.add(n, { step: String(step) });
          }, TICK_MS);
        }, Math.max(1, data.startAt - Date.now()));
      }
      socket.setTimeout(() => { closing = true; socket.close(); }, Math.max(1, closeAt - Date.now()));
    });

    socket.on('message', (raw) => {
      let msg;
      try { msg = JSON.parse(raw); } catch (e) { return; }
      if (msg.type === 'CHAT_MESSAGE') {
        let body;
        try { body = JSON.parse(msg.content); } catch (e) { return; }
        if (!body || body.lt !== 4 || body.run !== data.runId) return;
        const step = String(body.step);
        if (body.role === 'normal') {
          nReceived.add(1, { step });
          if (body.from !== me.id) nLatency.add(Date.now() - body.ts, { step });
        } else if (role === 'flood_partner') {
          fReceived.add(1, { step });
        }
      } else if (msg.type === 'ERROR') {
        const step = String(stepAt(data, Date.now()));
        if (role === 'normal') nErrors.add(1, { step, code: String(msg.code) });
        else if (role === 'flooder') fErrors.add(1, { step, code: String(msg.code) });
      }
    });

    socket.on('close', () => {
      if (!closing) closedEarly.add(1, { role: role === 'normal' ? 'normal' : 'flooder' });
    });
  });
  sleep(1);
}

const c = (m, name) => (m[name] ? m[name].values.count : 0);
const p = (m, name, k) => (m[name] && m[name].values[k] !== undefined ? m[name].values[k].toFixed(0) : '-');

export function handleSummary(data) {
  const m = data.metrics;
  const lines = ['================ flooding impact ================'];
  lines.push(`servers: ${IPS.join(', ')}   normal rooms: ${PAIRS} x ${RATE}/s/user   flooders: ${FLOODERS}   step: ${STEP_S}s`);
  lines.push(`ws closed early: normal ${c(m, 'flood_ws_closed_early{role:normal}')}  flooder ${c(m, 'flood_ws_closed_early{role:flooder}')}`);
  lines.push('step | flood msg/s | flooder sent / rejected / partner recv | normal sent / rejected | normal delivery | normal latency ms p50 / p95 / p99 / max');
  STEPS.forEach((rate, i) => {
    const ns = c(m, `flood_normal_sent{step:${i}}`);
    const ne = c(m, `flood_normal_errors{step:${i}}`);
    const nr = c(m, `flood_normal_received{step:${i}}`);
    const exp = (ns - ne) * 2; // 에코 + 상대
    const del = exp > 0 ? ((100 * nr) / exp).toFixed(2) : '-';
    const lat = `flood_normal_latency_ms{step:${i}}`;
    lines.push(`  ${i}  | ${String(rate).padStart(5)} | ${c(m, `flood_flooder_sent{step:${i}}`)} / ${c(m, `flood_flooder_errors{step:${i}}`)} / ${c(m, `flood_flooder_partner_received{step:${i}}`)} | ${ns} / ${ne} | ${del}% | ${p(m, lat, 'med')} / ${p(m, lat, 'p(95)')} / ${p(m, lat, 'p(99)')} / ${p(m, lat, 'max')}`);
  });
  lines.push('(normal delivery 는 보낸 시점 단계 기준. 플러딩 거절은 서버 에러 응답 수)');
  lines.push('=================================================');
  const text = lines.join('\n') + '\n';
  return {
    stdout: text,
    [`/opt/loadtest/results/${__ENV.TEST_ID || 'flood'}.txt`]: text,
    [`/opt/loadtest/results/${__ENV.TEST_ID || 'flood'}.json`]: JSON.stringify(data, null, 2),
  };
}
