// 새 채팅방 생성 시 다른 서버 사용자의 자동 구독 측정 (k6, Raw WebSocket) — [진행6]
//
// 그룹 A 사용자는 서버 IPS[0], 그룹 B 사용자는 IPS[1] 에 WebSocket 으로 먼저 연결해 둔다.
// 라운드마다 A 가 새 파트너 B 와 채팅방을 만들고(HTTP), 바로 그 방에 메시지를 보낸다.
// 서버는 방 생성 이벤트로 두 참여자의 세션을 찾아 새 방에 구독시켜야 한다.
//   - A 의 전송이 거절되거나(NOT_SUBSCRIBED) 에코가 안 오면 → A 세션이 구독되지 않음
//   - B 가 메시지를 못 받으면 → B 세션(다른 서버)이 구독되지 않음
// 세션 레지스트리가 다른 서버의 세션을 지우면 다음 라운드부터 구독이 실패한다.
//
// 실행: SCRIPT=room-created.js chattest <main|dev>
// 환경 변수
//   GROUP      그룹당 사용자 수 (기본 10, 사용자 2배 필요)
//   BASE       시드 사용자 목록에서 시작 위치 (기본 40: chat-consistency 의 사용자 0..39 와 겹치지 않게)
//   ROUNDS     라운드 수 (기본 3)
//   OFFSET     파트너 오프셋 (기본 0). 같은 두 사용자의 방은 이미 있어 이벤트가 나지 않으므로 실행할 때마다 늘린다
//              (라운드 r 에서 A_i 의 파트너 = B_((i + OFFSET + r) % GROUP), 결과에 다음 OFFSET 을 출력)
//   ROUND_GAP  라운드 간격 초 (기본 5)
import http from 'k6/http';
import ws from 'k6/ws';
import exec from 'k6/execution';
import { fail, sleep } from 'k6';
import { Counter } from 'k6/metrics';

const IPS = (__ENV.TASK_IPS || '').split(',').map((s) => s.trim()).filter(Boolean);
if (IPS.length < 2) fail('TASK_IPS 에 서버가 2개 이상 필요 (다른 서버 사용자 간 방 생성 측정)');
const USERS = JSON.parse(open(__ENV.USERS_FILE));
const GROUP = parseInt(__ENV.GROUP || '10', 10);
const BASE = parseInt(__ENV.BASE || '40', 10);
const ROUNDS = parseInt(__ENV.ROUNDS || '3', 10);
const OFFSET = parseInt(__ENV.OFFSET || '0', 10);
const ROUND_GAP_S = parseInt(__ENV.ROUND_GAP || '5', 10);
const DEV_SECRET = __ENV.DEV_SECRET;
if (USERS.length < BASE + GROUP * 2) fail(`need ${BASE + GROUP * 2} users, seeded ${USERS.length}`);
if (OFFSET + ROUNDS > GROUP) console.warn(`OFFSET+ROUNDS(${OFFSET + ROUNDS}) > GROUP(${GROUP}): 이전 실행과 같은 파트너가 나와 방이 이미 있을 수 있음`);

const created = new Counter('room_created');        // 새로 만든 방 (round)
const found = new Counter('room_found');            // 이미 있던 방 (이벤트 없음, 집계 제외)
const createErrors = new Counter('room_create_errors');
const sent = new Counter('room_sent');              // A 가 새 방에 보낸 메시지
const rejected = new Counter('room_send_rejected'); // A 전송이 서버 에러 (구독 안 됨 등)
const echo = new Counter('room_echo_received');     // A 가 자기 메시지를 받음 (A 세션 구독됨)
const partner = new Counter('room_partner_received'); // B 가 A 메시지를 받음 (다른 서버 B 세션 구독됨)

const thresholds = {};
for (let r = 0; r < ROUNDS; r++) {
  for (const m of ['room_created', 'room_sent', 'room_send_rejected', 'room_echo_received', 'room_partner_received']) {
    thresholds[`${m}{round:${r}}`] = ['count>=0'];
  }
}

export const options = {
  scenarios: { rooms: { executor: 'per-vu-iterations', vus: GROUP * 2, iterations: 1, maxDuration: `${ROUNDS * ROUND_GAP_S + 90}s` } },
  setupTimeout: '3m',
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

export function setup() {
  if (!DEV_SECRET) fail('DEV_SECRET is empty');
  const a = [];
  const b = [];
  for (let i = 0; i < GROUP; i++) {
    a.push({ id: USERS[BASE + i], token: devToken(USERS[BASE + i]) });
    b.push({ id: USERS[BASE + GROUP + i], token: devToken(USERS[BASE + GROUP + i]) });
  }
  console.log(`setup: group A ${GROUP} -> ${IPS[0]}, group B ${GROUP} -> ${IPS[1]}, rounds=${ROUNDS}, offset=${OFFSET}`);
  return { a, b, runId: Date.now(), startAt: Date.now() + 8000 };
}

export default function (data) {
  const vu = exec.vu.idInTest - 1;
  const isA = vu < GROUP;
  const i = isA ? vu : vu - GROUP;
  const me = isA ? data.a[i] : data.b[i];
  const ip = isA ? IPS[0] : IPS[1];
  const closeAt = data.startAt + ROUNDS * ROUND_GAP_S * 1000 + 8000;

  const tokenRes = http.post(`${api(ip)}/api/v1/auth/ws-token`, null, { headers: { Authorization: `Bearer ${me.token}` }, tags: { name: 'ws_token' } });
  const wsToken = tokenRes.json('data.wsToken');
  if (!wsToken) fail(`ws-token failed user=${me.id} status=${tokenRes.status}`);

  const roundOfRoom = {}; // A: roomId -> round

  ws.connect(`ws://${ip}:8080/ws/chat?token=${wsToken}`, { tags: { server: ip } }, (socket) => {
    socket.on('open', () => {
      if (isA) {
        for (let r = 0; r < ROUNDS; r++) {
          socket.setTimeout(() => {
            const target = data.b[(i + OFFSET + r) % GROUP];
            const res = http.post(`${api(ip)}/api/v1/chat-rooms`, JSON.stringify({ targetUserId: target.id }), {
              headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${me.token}` }, tags: { name: 'create_room' },
            });
            if (res.status === 201) {
              created.add(1, { round: String(r) });
            } else if (res.status === 200) {
              found.add(1, { round: String(r) });
              return; // 기존 방: 생성 이벤트가 없어 측정 대상 아님
            } else {
              createErrors.add(1, { round: String(r), status: String(res.status) });
              return;
            }
            const roomId = res.json('data.roomId');
            roundOfRoom[roomId] = r;
            socket.setTimeout(() => { // 방 생성 이벤트가 두 서버에 전달될 시간
              const content = JSON.stringify({ lt: 2, run: data.runId, round: r, from: me.id });
              socket.send(JSON.stringify({ type: 'SEND', roomId, content }));
              sent.add(1, { round: String(r) });
            }, 1500);
          }, Math.max(1, data.startAt + r * ROUND_GAP_S * 1000 - Date.now()));
        }
      }
      socket.setTimeout(() => socket.close(), Math.max(1, closeAt - Date.now()));
    });

    socket.on('message', (raw) => {
      let msg;
      try { msg = JSON.parse(raw); } catch (e) { return; }
      if (msg.type === 'CHAT_MESSAGE') {
        let body;
        try { body = JSON.parse(msg.content); } catch (e) { return; }
        if (!body || body.lt !== 2 || body.run !== data.runId) return;
        const round = String(body.round);
        if (body.from === me.id) echo.add(1, { round });
        else partner.add(1, { round });
      } else if (msg.type === 'ERROR' && isA) {
        // 이 연결에서 보내는 요청은 새 방 SEND 뿐이다. 마지막으로 만든 방의 라운드로 집계한다
        const lastRound = Object.values(roundOfRoom).pop();
        if (lastRound !== undefined) rejected.add(1, { round: String(lastRound), code: String(msg.code) });
      }
    });
  });
  sleep(1);
}

const c = (m, name) => (m[name] ? m[name].values.count : 0);

export function handleSummary(data) {
  const m = data.metrics;
  const lines = ['================ room created subscription ================'];
  lines.push(`servers: A=${IPS[0]} B=${IPS[1]}   group: ${GROUP}   rounds: ${ROUNDS}   offset: ${OFFSET}   (next OFFSET=${OFFSET + ROUNDS})`);
  lines.push(`rooms: created ${c(m, 'room_created')}   already existed ${c(m, 'room_found')}   create errors ${c(m, 'room_create_errors')}`);
  let tc = 0, te = 0, tp = 0;
  for (let r = 0; r < ROUNDS; r++) {
    const cr = c(m, `room_created{round:${r}}`);
    const se = c(m, `room_sent{round:${r}}`);
    const rj = c(m, `room_send_rejected{round:${r}}`);
    const ec = c(m, `room_echo_received{round:${r}}`);
    const pa = c(m, `room_partner_received{round:${r}}`);
    tc += cr; te += ec; tp += pa;
    const pct = (x) => (cr > 0 ? ((100 * x) / cr).toFixed(1) : '-');
    lines.push(`  round ${r}: created ${cr}  sent ${se}  rejected ${rj}  | A(sender) subscribed ${ec}/${cr} (${pct(ec)}%)  B(other server) received ${pa}/${cr} (${pct(pa)}%)`);
  }
  const pct = (x) => (tc > 0 ? ((100 * x) / tc).toFixed(1) : '-');
  lines.push(`total: A subscribed ${te}/${tc} (${pct(te)}%)   B received ${tp}/${tc} (${pct(tp)}%)`);
  lines.push('============================================================');
  const text = lines.join('\n') + '\n';
  return {
    stdout: text,
    [`/opt/loadtest/results/${__ENV.TEST_ID || 'room'}.txt`]: text,
    [`/opt/loadtest/results/${__ENV.TEST_ID || 'room'}.json`]: JSON.stringify(data, null, 2),
  };
}
