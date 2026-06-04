# 사이트 이탈 후 실시간 반응 정지 문제 분석 보고서

- 작성일: 2026-06-04
- 대상 프로젝트: `game01`
- 대상 화면: 로비, 대기방, Mafia 게임, Liar 게임, Catchmind 게임

## 1. 문제 발생

사용자가 사이트 또는 탭을 벗어난 뒤 다시 돌아오면, 새로고침하기 전까지 다른 사용자의 행동이나 게임 진행 상태가 화면에 즉시 반영되지 않는 문제가 발생했다.

관찰된 영향 범위는 다음과 같다.

- 방 목록, 친구 상태, 초대, 채팅 등 로비 실시간 반응이 지연되거나 멈출 수 있음
- 대기방 참가자 상태와 게임 시작 전환이 즉시 갱신되지 않을 수 있음
- Mafia/Liar/Catchmind 게임 진행 상태, 채팅, 라운드 진행이 새로고침 전까지 반영되지 않을 수 있음
- Catchmind의 경우 캔버스 그리기 이벤트가 Supabase broadcast 기반이라, 채널이 끊기면 DB polling만으로 복구되지 않음

## 2. 발생 원인 분석 및 조사

### 2.1 브라우저 백그라운드 타이머 제한

게임 화면과 대기방은 `setInterval` 기반으로 heartbeat를 호출한다.

- `heartbeat_room_presence`
- `cleanup_stale_room_players`
- 화면별 polling timer

브라우저는 탭이 background 상태가 되면 `setInterval` 실행을 강하게 지연시킬 수 있다. 이 프로젝트의 서버 로직은 일정 시간 heartbeat가 없으면 참가자를 stale 상태로 판단한다.

확인한 DB 로직:

- `remote_admin.sql`의 `heartbeat_room_presence`
  - `room_players.connection_status = 'active'`
  - `last_seen_at = now()`
  - `disconnected_at = null`
- `remote_admin.sql`의 `cleanup_stale_room_players`
  - 대기방: 오래된 참가자 삭제
  - 게임 중: 오래된 참가자를 `connection_status = 'disconnected'`로 변경

따라서 사용자가 오래 이탈하면 heartbeat가 밀리고, 복귀 시점에 `getRoom()` 또는 목록 조회가 stale cleanup을 먼저 실행하면서 사용자가 disconnected로 처리될 수 있다.

### 2.2 Supabase realtime 채널 복구 부재

여러 화면에서 Supabase realtime 채널을 구독하고 있었지만, 복귀 시 채널을 재생성하는 로직이 없었다.

조사한 구독 경로:

- `src/api/roomApi.js`
  - `subscribeToRooms`
  - `subscribeToRoom`
  - `subscribeToGame`
- `src/api/chatApi.js`
  - `subscribeToPublicChat`
  - `subscribeToRoomChat`
  - `subscribeToGameMessages`
- `src/api/liarGameApi.js`
  - `subscribeToLiarMatch`
- `src/api/catchmindApi.js`
  - `subscribeToCatchmind`
  - `subscribeToCatchmindCanvas`

대부분의 구독 함수는 `SUBSCRIBED`, `CHANNEL_ERROR`, `TIMED_OUT`, `CLOSED` 같은 상태를 받을 수 있지만, 화면 복귀 시 자동으로 구독을 다시 붙이지 않았다.

특히 다음 문제가 있었다.

- 채널이 닫혀도 기존 unsubscribe 변수는 살아 있어 화면은 재구독했다고 판단하지 못함
- DB polling으로 일부 데이터는 회복되지만, broadcast 기반 채팅/캔버스 이벤트는 놓친 이벤트를 복원할 수 없음
- Catchmind 캔버스는 `snapshot-request`가 구독 성공 시에만 보내지므로, 채널이 죽은 상태에서는 새로고침 전까지 그림 상태 복구가 어렵다

### 2.3 Catchmind 참가자 제거 흐름

Catchmind는 다른 게임보다 증상이 더 치명적으로 나타날 수 있다.

확인한 DB 로직:

- `catchmind-game.sql`의 `private.reconcile_catchmind_match`
  - `room_players.connection_status = 'active'`가 아닌 사용자를 `catchmind_players`에서 삭제
  - 남은 참가자가 1명 이하이면 게임 종료 처리

즉, 사이트 이탈로 heartbeat가 늦어지고 `connection_status`가 `disconnected`가 된 뒤, 복귀 과정에서 `reconcile_catchmind_match`가 먼저 실행되면 참가자가 게임에서 제거될 수 있다.

### 2.4 다른 후보 조사

다음 후보도 함께 확인했다.

- 인증 세션 만료
  - `src/stores/auth.js`에서 `TOKEN_REFRESHED` 이벤트를 처리하고 있어 단일 원인 가능성은 낮음
- Supabase realtime publication 누락
  - `catchmind-game.sql`에서 Catchmind 관련 public 테이블을 `supabase_realtime` publication에 추가하는 블록이 존재함
  - 따라서 publication 누락만으로 보기 어려움
- polling 부재
  - 게임 화면들은 polling을 일부 갖고 있었음
  - 하지만 background timer 제한과 realtime 채널 종료에는 충분하지 않았음
- SQL 권한/RLS 문제
  - 관련 RPC와 select policy가 존재함
  - 증상이 새로고침 후 회복된다는 점에서 권한 문제보다는 클라이언트 복구 흐름 문제에 더 가까움

## 3. 조사 결과

가장 가능성이 높고 실제 코드상으로 확인된 원인은 다음 두 가지의 결합이다.

1. 사이트 이탈 중 heartbeat와 polling timer가 지연된다.
2. 복귀 후 realtime/broadcast 채널이 자동 재연결되지 않는다.

이로 인해 복귀 직후 다음 상태가 발생할 수 있다.

- heartbeat가 먼저 복구되지 않아 참가자가 stale/disconnected로 보임
- `getRoom()` 또는 game sync가 stale cleanup을 유발함
- 화면은 기존 구독 변수를 유지하고 있어 realtime 채널을 다시 만들지 않음
- DB 기반 상태 일부는 polling으로 늦게 회복될 수 있지만, broadcast 기반 이벤트는 새로고침 전까지 회복되지 않음

Catchmind는 이 흐름에서 `reconcile_catchmind_match`가 disconnected 참가자를 실제 게임 참가자에서 제거할 수 있어 가장 위험도가 높다.

## 4. 조치 결과

복귀 이벤트를 명시적으로 처리하도록 화면별 보강을 적용했다.

공통 조치:

- `visibilitychange`
- `window.focus`
- `window.online`

위 이벤트가 발생하면 다음 순서로 복구한다.

1. 현재 시간이 반영되도록 timer tick 갱신
2. heartbeat를 먼저 호출해 `room_players`를 active 상태로 복구
3. 기존 realtime/broadcast 구독 제거
4. 새 realtime/broadcast 구독 생성
5. DB 기반 상태와 메시지 즉시 재조회

수정 파일:

- `src/views/HomeView.vue`
  - 로비 복귀 시 방 목록, 친구, 초대, 공개 채팅 구독 재생성
  - 방 목록/친구/초대 즉시 재조회
  - presence를 lobby 상태로 재전송
- `src/views/GameRoomView.vue`
  - 대기방 복귀 시 room 구독 재생성
  - forced heartbeat 후 room resync
- `src/views/GamePlayView.vue`
  - Mafia 게임 복귀 시 room/game/message 구독 재생성
  - 게임 상태와 메시지 즉시 재조회
- `src/views/LiarGamePlayView.vue`
  - 복귀 시 heartbeat 선행
  - room/match/message 구독 재생성
  - Liar match 상태 즉시 재조회
- `src/views/CatchmindGamePlayView.vue`
  - 복귀 시 heartbeat 선행
  - Catchmind state/message/canvas 구독 재생성
  - 상태와 메시지 즉시 재조회
  - canvas 구독 성공 시 snapshot request를 다시 보내도록 기존 흐름 활용

## 5. 검증

실행한 검증:

```bash
npm run build
```

결과:

- Vite production build 성공
- Vue 컴포넌트 문법 및 import 오류 없음
- 수정 범위는 화면 복귀/구독 복구 로직에 한정됨

## 6. 잔여 리스크 및 추가 권장 사항

이번 조치는 클라이언트 복귀 복구를 보강한 것이다. 다만 다음 개선을 추가하면 안정성이 더 좋아진다.

- Supabase 구독 status가 `CHANNEL_ERROR`, `TIMED_OUT`, `CLOSED`일 때 즉시 재구독하는 공통 유틸 도입
- Catchmind 캔버스 stroke를 DB 또는 storage에 주기적으로 snapshot 저장해 broadcast 유실에도 완전 복구 가능하게 개선
- `cleanup_stale_room_players`가 게임 중 참가자를 너무 빨리 disconnected 처리하지 않도록 grace period 재검토
- Catchmind `reconcile_catchmind_match`가 일시 disconnected 사용자를 즉시 `catchmind_players`에서 삭제하지 않도록 완충 로직 추가

