// 다중 서버 채팅 정합성/유실/지연 측정 시나리오 (k6, Raw WebSocket)
//
// 방(1:1) 하나에 사용자 2명을 두고, 두 사용자를 서로 다른 서버(태스크 IP)에 고정해 연결한다.
// 각 사용자는 일정 간격으로 메시지를 보내고, 같은 방의 모든 메시지(내 에코 + 상대 메시지)를
// 받아야 정상이다. 서버별 수신율이 다르면 "서버 간 불일치", 100% 미만이면 "유실".
//
// 실행: chattest <main|dev|one-main|one-dev> [k6 options...]   (TASK_IPS, 사용자, DEV_SECRET 자동 설정)
//
// 환경 변수
//   TASK_IPS       서버 IP 목록 (쉼표). 방 i 의 사용자 A -> IPS[i % n], B -> IPS[(i + 1) % n]
//   USERS_FILE     시드된 사용자 ID 목록 JSON (scripts/loadtest-seed.sh 가 생성)
//   DEV_SECRET     /api/v1/dev/token/user 호출용
//   PAIRS          방 수 (기본 20, 사용자는 2배)
//   RATE           사용자당 초당 전송 수 (기본 1)
//   DURATION       전송 시간 (기본 120s 형식: 초 단위 숫자, 예 120)
//   DRAIN          전송 종료 후 수신 대기 시간 초 (기본 5)
//   RECONNECT      연결이 끊기면 다른 서버로 재연결 (기본 1)
//   JITTER         1(기본): 사용자마다 전송 시작 시각을 전송 간격 안에서 무작위로 어긋나게 (실제 채팅처럼)
//                  0: 모든 사용자가 같은 순간에 전송 -> 같은 방 동시 전송으로 DB 락 경합 재현 (4위 실험)
import http from 'k6/http';
import ws from 'k6/ws';
import exec from 'k6/execution';
import { check, fail, sleep } from 'k6';
import { Counter, Trend } from 'k6/metrics';

const IPS = (__ENV.TASK_IPS || '').split(',').map((s) => s.trim()).filter(Boolean);
if (IPS.length === 0) fail('TASK_IPS is empty');
const USERS = JSON.parse(open(__ENV.USERS_FILE));
const PAIRS = parseInt(__ENV.PAIRS || '20', 10);
const RATE = parseFloat(__ENV.RATE || '1');
const DURATION_S = parseInt(__ENV.DURATION || '120', 10);
const DRAIN_S = parseInt(__ENV.DRAIN || '5', 10);
const RECONNECT = (__ENV.RECONNECT || '1') === '1';
const DEV_SECRET = __ENV.DEV_SECRET;
const JITTER = (__ENV.JITTER || '1') === '1';
if (USERS.length < PAIRS * 2) fail(`need ${PAIRS * 2} users, seeded ${USERS.length} (loadtest-seed.sh 로 늘리기)`);

// 서버(IP)별 지표. receiver_server: 메시지를 받은 사용자가 붙은 서버.
const sent = new Counter('chat_sent');                 // 보낸 SEND (server: 보낸 사람이 붙은 서버)
const sendErrors = new Counter('chat_send_errors');     // 서버 에러 응답 (WebSocketErrorResponse) = 저장 안 된 메시지
const expected = new Counter('chat_expected');         // 받아야 할 수신 수 (receiver_server 별, 방의 두 사용자 서버 기준)
const expectedErrors = new Counter('chat_expected_errors'); // 에러로 저장 안 된 메시지만큼 기대 수신에서 뺄 값
const received = new Counter('chat_received');         // 받은 CHAT_MESSAGE (중복 제외)
const duplicates = new Counter('chat_duplicates');      // 같은 메시지를 두 번 이상 받음
const reconnects = new Counter('chat_ws_reconnects');   // 비정상 종료 후 재연결
const tokenFailures = new Counter('chat_ws_token_failures'); // ws-token 발급 실패
const connects = new Counter('chat_ws_connects');       // WebSocket 연결 성공(open)
const connectFailures = new Counter('chat_ws_connect_failures'); // 핸드셰이크 실패
let logged = 0;
function logOnce(msg) {
  if (logged < 2) { console.warn(msg); logged += 1; } // VU 마다 최대 2줄
}
const latency = new Trend('chat_latency_ms', true);     // 전송 -> 수신 (상대 메시지만)

const thresholds = {};
for (const ip of IPS) {
  thresholds[`chat_received{receiver_server:${ip}}`] = ['count>=0'];
  thresholds[`chat_expected{receiver_server:${ip}}`] = ['count>=0'];
  thresholds[`chat_expected_errors{receiver_server:${ip}}`] = ['count>=0'];
}

export const options = {
  scenarios: {
    chat: {
      executor: 'per-vu-iterations',
      vus: PAIRS * 2,
      iterations: 1,
      maxDuration: `${DURATION_S + DRAIN_S + 120}s`,
    },
  },
  setupTimeout: '5m',
  // VU 들이 거의 동시에 시작하므로 JITTER 로 전송 시각을 흩는다
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(95)', 'p(99)'],
  thresholds,
};

function api(ip) {
  return `http://${ip}:8080`;
}

function devToken(ip, userId) {
  const res = http.post(`${api(ip)}/api/v1/dev/token/user`, JSON.stringify({ userId }), {
    headers: { 'Content-Type': 'application/json', 'X-Dev-Secret': DEV_SECRET },
    tags: { name: 'dev_token' },
  });
  if (res.status < 200 || res.status >= 300) fail(`dev token failed user=${userId} status=${res.status} body=${res.body}`);
  return res.json('data.accessToken');
}

export function setup() {
  if (!DEV_SECRET) fail('DEV_SECRET is empty');
  const pairs = [];
  for (let i = 0; i < PAIRS; i++) {
    const a = USERS[i * 2];
    const b = USERS[i * 2 + 1];
    const tokenA = devToken(IPS[0], a);
    const tokenB = devToken(IPS[0], b);
    const res = http.post(`${api(IPS[0])}/api/v1/chat-rooms`, JSON.stringify({ targetUserId: b }), {
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${tokenA}` },
      tags: { name: 'create_room' },
    });
    if (res.status < 200 || res.status >= 300) fail(`create room failed ${a}-${b} status=${res.status} body=${res.body}`);
    pairs.push({ roomId: res.json('data.roomId'), a: { id: a, token: tokenA }, b: { id: b, token: tokenB } });
  }
  console.log(`setup: ${PAIRS} rooms, servers=${IPS.join(',')}, rate=${RATE}/s/user, duration=${DURATION_S}s`);
  return { pairs, startAt: Date.now() + 5000 }; // 모든 VU 가 연결할 여유를 두고 동시에 전송 시작
}

function wsToken(ip, accessToken) {
  const res = http.post(`${api(ip)}/api/v1/auth/ws-token`, null, {
    headers: { Authorization: `Bearer ${accessToken}` },
    tags: { name: 'ws_token' },
  });
  if (res.status < 200 || res.status >= 300) { // ws-token 은 201 Created 를 반환한다
    tokenFailures.add(1, { server: ip, status: String(res.status) });
    logOnce(`ws-token failed server=${ip} status=${res.status} body=${String(res.body).slice(0, 300)}`);
    return null;
  }
  const t = res.json('data.wsToken');
  if (!t) logOnce(`ws-token empty server=${ip} body=${String(res.body).slice(0, 300)}`);
  return t;
}

export default function (data) {
  const vu = exec.vu.idInTest - 1;
  const pairIndex = Math.floor(vu / 2);
  const side = vu % 2 === 0 ? 'a' : 'b';
  const pair = data.pairs[pairIndex];
  const me = pair[side];
  const roomId = pair.roomId;
  let serverIdx = (pairIndex + (side === 'a' ? 0 : 1)) % IPS.length;
  // 방의 두 사용자가 처음 배정된 서버. 메시지 1건은 두 서버(같으면 한 서버에 2건)에서 수신돼야 한다.
  const roomServers = [IPS[pairIndex % IPS.length], IPS[(pairIndex + 1) % IPS.length]];

  const sendUntil = data.startAt + DURATION_S * 1000;
  const closeAt = sendUntil + DRAIN_S * 1000;
  const seen = new Set(); // messageId
  let seq = 0;

  while (Date.now() < closeAt) {
    const ip = IPS[serverIdx];
    const token = wsToken(ip, me.token);
    if (!token) {
      serverIdx = (serverIdx + 1) % IPS.length;
      sleep(1);
      continue;
    }
    let closedNormally = false;

    const res = ws.connect(`ws://${ip}:8080/ws/chat?token=${token}`, { tags: { server: ip } }, (socket) => {
      socket.on('error', (e) => {
        logOnce(`ws error server=${ip} user=${me.id}: ${e.error ? e.error() : e}`);
      });

      socket.on('open', () => {
        connects.add(1, { server: ip });
        // 연결 시 서버가 내가 속한 방을 자동 구독한다 (ChatWebSocketHandler.afterConnectionEstablished).
        // SUBSCRIBE 를 따로 보내지 않는 이유: ERROR 응답이 어느 요청의 것인지 구분할 수 없어서.
        const offset = JITTER ? Math.random() * (1000 / RATE) : 0;
        // 재연결 시에는 시작 시각이 이미 지나 0 이 된다. k6 타이머는 0 을 허용하지 않아 최소 1ms.
        const wait = Math.max(1, data.startAt + offset - Date.now());
        socket.setTimeout(() => {
          socket.setInterval(() => {
            if (Date.now() >= sendUntil) return;
            seq += 1;
            const content = JSON.stringify({ lt: 1, seq, ts: Date.now(), from: me.id });
            socket.send(JSON.stringify({ type: 'SEND', roomId, content }));
            sent.add(1, { server: ip, side });
            for (const rs of roomServers) expected.add(1, { receiver_server: rs });
          }, 1000 / RATE);
        }, wait);
        socket.setTimeout(() => {
          closedNormally = true;
          socket.close();
        }, Math.max(1, closeAt - Date.now()));
      });

      socket.on('message', (raw) => {
        let msg;
        try { msg = JSON.parse(raw); } catch (e) { return; }
        if (msg.type === 'CHAT_MESSAGE' && msg.roomId === roomId) {
          let body;
          try { body = JSON.parse(msg.content); } catch (e) { return; }
          if (!body || body.lt !== 1) return;
          if (seen.has(msg.messageId)) {
            duplicates.add(1, { receiver_server: ip });
            return;
          }
          seen.add(msg.messageId);
          const kind = body.from === me.id ? 'echo' : 'partner';
          received.add(1, { receiver_server: ip, kind });
          if (kind === 'partner') latency.add(Date.now() - body.ts, { receiver_server: ip });
        } else if (msg.type === 'ERROR') {
          // WebSocketErrorResponse: 이 연결에서 보내는 요청은 SEND 뿐이라 SEND 거부(저장 안 됨)로 본다
          sendErrors.add(1, { server: ip, code: String(msg.code) });
          logOnce(`send rejected server=${ip} user=${me.id} code=${msg.code} message=${msg.message}`);
          for (const rs of roomServers) expectedErrors.add(1, { receiver_server: rs });
        }
      });
    });

    const ok = check(res, { 'ws handshake 101': (r) => r && r.status === 101 });
    if (!ok) {
      connectFailures.add(1, { server: ip, status: String(res && res.status) });
      logOnce(`ws handshake failed server=${ip} status=${res && res.status} body=${res && String(res.body).slice(0, 300)}`);
    }
    if (closedNormally || Date.now() >= closeAt || !RECONNECT) break;
    reconnects.add(1, { server: ip });
    serverIdx = (serverIdx + 1) % IPS.length; // 끊긴 서버 대신 다른 서버로
    sleep(1);
  }
}

function count(metrics, name) {
  const m = metrics[name];
  return m ? m.values.count : 0;
}

export function handleSummary(data) {
  const m = data.metrics;
  const totalSent = count(m, 'chat_sent');
  const totalErrors = count(m, 'chat_send_errors');
  const accepted = totalSent - totalErrors;
  const lines = [];
  lines.push('================ chat consistency ================');
  lines.push(`servers: ${IPS.join(', ')}   rooms: ${PAIRS}   rate: ${RATE}/s/user   duration: ${DURATION_S}s   jitter: ${JITTER ? 'on' : 'off (동시 전송)'}`);
  lines.push(`ws: connects ${count(m, 'chat_ws_connects')}   connect failures ${count(m, 'chat_ws_connect_failures')}   ws-token failures ${count(m, 'chat_ws_token_failures')}   reconnects ${count(m, 'chat_ws_reconnects')}`);
  lines.push(`sent: ${totalSent}   rejected(send errors): ${totalErrors}   accepted: ${accepted}   duplicates: ${count(m, 'chat_duplicates')}`);
  const ratios = [];
  for (const ip of IPS) {
    const r = count(m, `chat_received{receiver_server:${ip}}`);
    const e = count(m, `chat_expected{receiver_server:${ip}}`) - count(m, `chat_expected_errors{receiver_server:${ip}}`);
    const ratio = e > 0 ? (100 * r) / e : 0;
    ratios.push(ratio);
    lines.push(`  receivers on ${ip}: received ${r} / expected ${e}   delivery ${ratio.toFixed(2)}%`);
  }
  const totalRecv = count(m, 'chat_received');
  const overall = accepted > 0 ? (100 * totalRecv) / (accepted * 2) : 0;
  lines.push(`overall delivery: ${overall.toFixed(2)}%   loss: ${(100 - overall).toFixed(2)}%`);
  if (ratios.length > 1) {
    lines.push(`server inconsistency (max-min delivery): ${(Math.max(...ratios) - Math.min(...ratios)).toFixed(2)}%p`);
    if (count(m, 'chat_ws_reconnects') > 0) lines.push('  (재연결이 있으면 서버별 수치는 처음 배정 기준이라 참고용, overall 을 본다)');
  }
  const lat = m.chat_latency_ms;
  if (lat) {
    const v = lat.values;
    lines.push(`latency ms  p50=${v.med.toFixed(1)}  p95=${v['p(95)'].toFixed(1)}  p99=${v['p(99)'].toFixed(1)}  max=${v.max.toFixed(1)}`);
  }
  lines.push('==================================================');
  const text = lines.join('\n') + '\n';
  return {
    stdout: text,
    [`/opt/loadtest/results/${__ENV.TEST_ID || 'chat'}.txt`]: text,
    [`/opt/loadtest/results/${__ENV.TEST_ID || 'chat'}.json`]: JSON.stringify(data, null, 2),
  };
}
