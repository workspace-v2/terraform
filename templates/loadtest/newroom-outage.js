// Redis 장애 중 생성된 채팅방의 구독 복구 측정 (k6, Raw WebSocket) — [진행7]
//
// 그룹 A 는 서버 IPS[0], 그룹 B 는 IPS[1] 에 WebSocket 으로 연결해 둔다 (측정 내내 재연결 없음).
// FIS 로 태스크 1개의 Redis 경로를 막은 상태에서 방을 만들고, Redis 복구 뒤 그 방에 메시지를 보낸다.
// 어느 서버가 차단될지 모르므로 방은 양방향으로 만든다 (만든 사람의 서버로 HTTP 요청).
//   - AtoB: A_i 가 B 와 방 생성 (생성 이벤트 발행 = IPS[0])
//   - BtoA: B_i 가 A 와 방 생성 (생성 이벤트 발행 = IPS[1])
// 차단된 서버는 그동안 발행된 방 생성 이벤트를 받지 못하고(차단된 서버가 발행한 이벤트는 양쪽 다 못 받음),
// 복구 뒤에도 재연결 전까지 그 방에 구독되지 않는다. 복구 후 전송에서
//   - 만든 사람 에코가 없거나 전송이 거절되면 → 만든 사람 세션 미구독
//   - 상대가 못 받으면 → 상대 세션 미구독
//
// 실행 순서: FIS redis-blackhole-one-task 시작 → 바로 `SCRIPT=newroom-outage.js OFFSET=0 chattest <env>`
//   기본 타이밍(FIS 차단 60초 기준): 연결 후 CREATE_AT 초에 방 생성(차단 중), SEND_AT 초에 전송(복구 후)
// 환경 변수
//   GROUP     그룹당 사용자 수 (기본 10)
//   BASE      시드 사용자 목록 시작 위치 (기본 60: chat-consistency 0..39, room-created 40..59 와 겹치지 않게)
//   OFFSET    파트너 오프셋 (기본 0). 실행마다 2씩 쓴다 (결과에 다음 OFFSET 출력)
//   CREATE_AT 방 생성 시각, 연결 후 초 (기본 35: Redisson 이 끊김을 감지한 뒤가 되도록)
//   SEND_AT   전송 시각, 연결 후 초 (기본 100: 차단 종료 후 재구독까지 여유)
import http from 'k6/http';
import ws from 'k6/ws';
import exec from 'k6/execution';
import { fail, sleep } from 'k6';
import { Counter } from 'k6/metrics';

const IPS = (__ENV.TASK_IPS || '').split(',').map((s) => s.trim()).filter(Boolean);
if (IPS.length < 2) fail('TASK_IPS 에 서버가 2개 이상 필요');
const USERS = JSON.parse(open(__ENV.USERS_FILE));
const GROUP = parseInt(__ENV.GROUP || '10', 10);
const BASE = parseInt(__ENV.BASE || '60', 10);
const OFFSET = parseInt(__ENV.OFFSET || '0', 10);
const CREATE_AT_S = parseInt(__ENV.CREATE_AT || '35', 10);
const SEND_AT_S = parseInt(__ENV.SEND_AT || '100', 10);
const DEV_SECRET = __ENV.DEV_SECRET;
if (USERS.length < BASE + GROUP * 2) fail(`need ${BASE + GROUP * 2} users, seeded ${USERS.length}`);
if (OFFSET + 2 > GROUP) console.warn(`OFFSET+2(${OFFSET + 2}) > GROUP(${GROUP}): 이전 실행과 같은 쌍이 나와 방이 이미 있을 수 있음`);

const DIRS = ['AtoB', 'BtoA'];
const created = new Counter('outage_room_created');
const found = new Counter('outage_room_found');
const createErrors = new Counter('outage_room_create_errors');
const sent = new Counter('outage_sent');
const rejected = new Counter('outage_send_rejected');
const echo = new Counter('outage_creator_received');
const partner = new Counter('outage_partner_received');
const syncSignals = new Counter('outage_sync_required');
const closes = new Counter('outage_ws_closed_early');

const thresholds = {};
for (const d of DIRS) {
  for (const m of ['outage_room_created', 'outage_sent', 'outage_send_rejected', 'outage_creator_received', 'outage_partner_received']) {
    thresholds[`${m}{dir:${d}}`] = ['count>=0'];
  }
}
thresholds['outage_sync_required{group:A}'] = ['count>=0'];
thresholds['outage_sync_required{group:B}'] = ['count>=0'];

export const options = {
  scenarios: { rooms: { executor: 'per-vu-iterations', vus: GROUP * 2, iterations: 1, maxDuration: `${SEND_AT_S + 60}s` } },
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
  console.log(`setup: group A ${GROUP} -> ${IPS[0]}, group B ${GROUP} -> ${IPS[1]}, offset=${OFFSET}, create at +${CREATE_AT_S}s, send at +${SEND_AT_S}s`);
  return { a, b, runId: Date.now(), startAt: Date.now() + 3000 };
}

export default function (data) {
  const vu = exec.vu.idInTest - 1;
  const isA = vu < GROUP;
  const i = isA ? vu : vu - GROUP;
  const me = isA ? data.a[i] : data.b[i];
  const ip = isA ? IPS[0] : IPS[1];
  const dir = isA ? 'AtoB' : 'BtoA';
  // 쌍 (A_j, B_k) 의 차이 k - j: AtoB 는 OFFSET, BtoA 는 OFFSET + 1 → 두 방향이 같은 쌍을 만들지 않는다
  const target = isA ? data.b[(i + OFFSET) % GROUP] : data.a[(i - OFFSET - 1 + GROUP * 2) % GROUP];
  const closeAt = data.startAt + (SEND_AT_S + 10) * 1000;

  const tokenRes = http.post(`${api(ip)}/api/v1/auth/ws-token`, null, { headers: { Authorization: `Bearer ${me.token}` }, tags: { name: 'ws_token' } });
  const wsToken = tokenRes.json('data.wsToken');
  if (!wsToken) fail(`ws-token failed user=${me.id} status=${tokenRes.status}`);

  let myRoomId = null;
  let closing = false;

  ws.connect(`ws://${ip}:8080/ws/chat?token=${wsToken}`, { tags: { server: ip } }, (socket) => {
    socket.on('open', () => {
      socket.setTimeout(() => {
        const res = http.post(`${api(ip)}/api/v1/chat-rooms`, JSON.stringify({ targetUserId: target.id }), {
          headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${me.token}` }, tags: { name: 'create_room' },
        });
        // HTTP 상태는 항상 200, 본문 code 로 구분: 201 = 새 방, 200 = 기존 방
        const code = res.status === 200 ? res.json('code') : null;
        if (code === 201) {
          created.add(1, { dir });
          myRoomId = res.json('data.roomId');
        } else if (code === 200) {
          found.add(1, { dir });
        } else {
          createErrors.add(1, { dir, status: String(res.status) });
        }
      }, Math.max(1, data.startAt + CREATE_AT_S * 1000 - Date.now()));

      socket.setTimeout(() => {
        if (myRoomId === null) return;
        const content = JSON.stringify({ lt: 3, run: data.runId, dir, from: me.id });
        socket.send(JSON.stringify({ type: 'SEND', roomId: myRoomId, content }));
        sent.add(1, { dir });
      }, Math.max(1, data.startAt + SEND_AT_S * 1000 - Date.now()));

      socket.setTimeout(() => { closing = true; socket.close(); }, Math.max(1, closeAt - Date.now()));
    });

    socket.on('message', (raw) => {
      let msg;
      try { msg = JSON.parse(raw); } catch (e) { return; }
      if (msg.type === 'CHAT_MESSAGE') {
        let body;
        try { body = JSON.parse(msg.content); } catch (e) { return; }
        if (!body || body.lt !== 3 || body.run !== data.runId) return;
        if (body.from === me.id) echo.add(1, { dir: body.dir });
        else partner.add(1, { dir: body.dir });
      } else if (msg.type === 'SYNC_REQUIRED') {
        syncSignals.add(1, { group: isA ? 'A' : 'B' });
      } else if (msg.type === 'ERROR' && myRoomId !== null) {
        // 이 연결에서 보내는 요청은 새 방 SEND 하나뿐
        rejected.add(1, { dir, code: String(msg.code) });
      }
    });

    socket.on('close', () => { if (!closing) closes.add(1, { server: ip }); });
  });
  sleep(1);
}

const c = (m, name) => (m[name] ? m[name].values.count : 0);

export function handleSummary(data) {
  const m = data.metrics;
  const lines = ['================ new room during redis outage ================'];
  lines.push(`servers: A=${IPS[0]} B=${IPS[1]}   group: ${GROUP}   offset: ${OFFSET}   (next OFFSET=${OFFSET + 2})   create +${CREATE_AT_S}s   send +${SEND_AT_S}s`);
  lines.push(`rooms: created ${c(m, 'outage_room_created')}   already existed ${c(m, 'outage_room_found')}   create errors ${c(m, 'outage_room_create_errors')}`);
  lines.push(`ws closed early (reconnect 필요 상황): ${c(m, 'outage_ws_closed_early')}   SYNC_REQUIRED received: A ${c(m, 'outage_sync_required{group:A}')}  B ${c(m, 'outage_sync_required{group:B}')}`);
  const label = { AtoB: `creator A@${IPS[0]} -> partner B@${IPS[1]}`, BtoA: `creator B@${IPS[1]} -> partner A@${IPS[0]}` };
  for (const d of DIRS) {
    const cr = c(m, `outage_room_created{dir:${d}}`);
    const se = c(m, `outage_sent{dir:${d}}`);
    const rj = c(m, `outage_send_rejected{dir:${d}}`);
    const ec = c(m, `outage_creator_received{dir:${d}}`);
    const pa = c(m, `outage_partner_received{dir:${d}}`);
    const pct = (x) => (cr > 0 ? ((100 * x) / cr).toFixed(1) : '-');
    lines.push(`  ${d} (${label[d]}): created ${cr}  sent ${se}  rejected ${rj}  | creator subscribed ${ec}/${cr} (${pct(ec)}%)  partner received ${pa}/${cr} (${pct(pa)}%)`);
  }
  lines.push('(차단된 서버는 FIS 실험 대상 태스크 또는 Grafana 재구독 메트릭으로 확인)');
  lines.push('================================================================');
  const text = lines.join('\n') + '\n';
  return {
    stdout: text,
    [`/opt/loadtest/results/${__ENV.TEST_ID || 'newroom'}.txt`]: text,
    [`/opt/loadtest/results/${__ENV.TEST_ID || 'newroom'}.json`]: JSON.stringify(data, null, 2),
  };
}
