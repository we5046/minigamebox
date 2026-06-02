# 라이어 게임 추가를 위한 프로젝트 구조 분석

> 참고: 이 문서는 구현 전 구조 분석 기록이다. 라이어 게임의 최종 규칙과 DB/RPC 기준은 `docs/liar-game-spec.md`, 현재 구현 및 적용 순서는 `docs/liar-game-go.md`를 우선한다.

## 0. 문서 범위

이 문서는 현재 저장소에 있는 Vue 코드와 SQL 보정 파일을 기준으로 작성한 정적 분석 문서다. 실제 Supabase 프로젝트의 라이브 스키마를 직접 조회한 결과는 아니다.

현재 저장소에는 전체 기준 스키마가 없다. `README.md`와 `code-review.md`는 `room-admin.sql`, `schema-base.sql`, `game-flow.sql`, `game-read-models.sql`, `game-cron.sql`을 언급하지만, 현재 작업 폴더에서 확인되는 SQL 파일은 다음 세 개다.

- `password-room-fix.sql`
- `stalker-role-fix.sql`
- `mypage-game-records-fix.sql`

따라서 아래 내용은 다음 기준으로 구분한다.

- **확인됨**: 현재 프론트 코드 또는 SQL 파일에서 직접 확인 가능
- **호출됨**: 프론트에서 사용하지만 현재 저장소에는 SQL 정의가 없음
- **제안**: 라이어 게임 구현을 위해 새로 설계할 구조

## 1. 전체 구조 요약

현재 프로젝트는 Vue 3, Pinia, Vue Router, Supabase JS로 구성되어 있다.

| 영역 | 현재 구조 | 라이어 게임 적용 방향 |
| --- | --- | --- |
| 인증 | Supabase Auth와 `profiles` | 그대로 재사용 |
| 메인 로비 | 게임 타입별 방 목록 필터링 | 그대로 재사용 |
| 방 생성과 입장 | `rooms`, `room_players`, RPC | 공통 껍데기는 재사용 |
| 대기방 참가자 | `room_players`, Realtime, heartbeat | 그대로 재사용 |
| 로비와 대기방 채팅 | Supabase Realtime Broadcast | 그대로 재사용 가능 |
| 게임 중 채팅 | `game_messages`, Postgres Changes | 정책 보강 후 재사용 가능 |
| 마피아 게임 진행 | `games`, `room_players.role`, 다수 RPC, `GamePlayView.vue` | 직접 재사용하지 말고 라이어 전용 엔진 추가 |
| 마이페이지 전적 | `game_type` 기반 정규화 통계 | 결과 연결 어댑터를 추가해 재사용 |

현재 `src/views/HomeView.vue`에는 `liar` 게임 카드가 있지만 `isAvailable: false`로 설정되어 있다. 즉, UI 진입점은 준비되어 있으나 방 생성과 실제 플레이는 아직 막혀 있다.

## 2. 현재 방 생성 및 입장 구조

### 2.1 프론트 흐름

메인 로비는 `src/views/HomeView.vue`에서 게임 타입별 방 목록을 필터링한다.

- `selectedGameType`의 기본값은 `mafia`
- `GAME_THEMES`에는 `mafia`, `catchmind`, `liar`가 등록되어 있음
- `selectedGameRooms`는 `room.gameType === selectedGameType` 조건으로 필터링
- 준비 중 게임은 `isAvailable: false` 조건으로 방 생성 폼 진입과 제출을 막음

방 생성 시 `HomeView.vue`의 `createRoom()`이 `src/api/roomApi.js`의 `createRoom()`을 호출한다. API는 Supabase RPC `create_room`을 호출하고, 생성 후 `getRoom()`으로 정규화된 방 정보를 다시 조회한다.

공개방 입장은 `join_room` RPC를 바로 호출한다. 비공개방은 비밀번호 모달을 열고 비밀번호를 전달한다. 초대 수락은 `respond_room_invite` RPC를 호출한 뒤 `/rooms/:roomId?invited=1`로 이동한다.

### 2.2 DB 흐름

`password-room-fix.sql`에서 `public.create_room(...)`과 `public.join_room(uuid, text, boolean)` 정의를 확인할 수 있다.

`create_room`은 다음을 수행한다.

1. `auth.uid()`로 로그인 사용자를 확인한다.
2. 제목, 게임 타입, 인원, 단계 시간, 입장 방식을 검증한다.
3. 8자리 방 코드를 생성한다.
4. `public.rooms`에 방을 추가한다.
5. 생성자를 `public.room_players`에 방장, 준비 완료 상태로 추가한다.

`join_room`은 다음을 수행한다.

1. `auth.uid()`로 로그인 사용자를 확인한다.
2. `rooms` 행을 `for update`로 잠근다.
3. 이미 참가한 사용자라면 연결 상태와 heartbeat 시각만 복구한다.
4. 대기 중 방인지 검사한다.
5. 비공개방 비밀번호를 검사한다.
6. 현재 활성 참가자 수가 정원을 넘지 않는지 검사한다.
7. `room_players`에 참가자를 추가한다.

### 2.3 비공개방 비밀번호

`password-room-fix.sql`은 `pgcrypto`를 `extensions` 스키마에 설치하고 `extensions.crypt`, `extensions.gen_salt`를 사용한다. `hash_room_entry_password` 트리거는 비공개방 비밀번호를 bcrypt 형태로 저장한다.

프론트의 `roomSelect`에는 `entry_password`가 포함되지 않는다. 브라우저로 해시를 내려보내지 않는 현재 형태는 유지해야 한다.

### 2.4 라이어 게임에서 재사용 가능한 부분

다음 방 기능은 게임 규칙과 무관하므로 재사용할 수 있다.

- `rooms.id`, `rooms.title`, `rooms.code`
- `rooms.game_type`
- `rooms.host_user_id`
- `rooms.status`
- `rooms.max_players`
- `rooms.entry_mode`
- 비공개방 비밀번호 트리거와 `join_room`
- 초대, 공개방 입장, 비공개방 입장 UI

다만 현재 `create_room`의 필수 인자는 마피아 설정에 치우쳐 있다.

- `night_time_seconds`
- `vote_time_seconds`
- `discussion_time_seconds`
- `tie_vote_rule`
- `first_night_ability_allowed`
- `role_reveal_mode`
- `role_config`

초기 라이어 구현에서는 호환용 기본값을 전달할 수 있다. 장기적으로는 공통 방 필드와 게임별 설정을 분리하는 편이 안전하다. 예를 들어 `rooms.game_settings jsonb` 또는 게임별 설정 테이블을 둘 수 있다.

## 3. 참가자 목록 관리 방식

### 3.1 영속 참가자 목록

`room_players`가 방 참가자의 영속 상태를 관리한다. `src/api/roomApi.js`의 `roomSelect`와 `normalizeRoom()`에서 다음 필드를 사용한다.

- `user_id`
- `is_host`
- `is_ready`
- `is_alive`
- `connection_status`
- `last_seen_at`
- `disconnected_at`
- `joined_at`
- 연결된 `profiles.nickname`, `avatar`, `level`, `representative_title`

대기 중 방은 연결된 사용자만 목록에 노출한다. 게임 진행 중에는 연결이 끊긴 사용자도 목록에 남긴다.

### 3.2 준비 상태와 방장

- 준비 상태 변경: `setPlayerReady()`가 `room_players.is_ready`를 직접 업데이트
- 방장 확인: `room_players.is_host`와 `rooms.host_user_id`
- 강퇴: `kick_room_player` RPC 호출
- 퇴장: `leave_room` RPC 호출

`leave_room`, `kick_room_player`의 SQL 정의는 현재 저장소에 없다. README가 참조하는 `room-admin.sql`도 현재 폴더에 없다. 실제 DB에 배포된 정의를 별도로 확인해야 한다.

### 3.3 접속 상태

접속 상태는 두 층으로 관리된다.

| 층 | 구현 | 목적 |
| --- | --- | --- |
| 전역 온라인 상태 | `src/api/presenceApi.js`의 Supabase Realtime Presence | 로비, 게임방, 게임 중 상태와 귓속말 가능 여부 표시 |
| 방 참가 상태 | `room_players.connection_status`, `last_seen_at` | 방 정리, 재접속, 강퇴 판단 |

`heartbeat_room_presence` RPC는 대기방과 게임 화면에서 10초 간격으로 호출된다. `cleanup_stale_room_players` RPC는 `getRooms()`와 `getRoom()` 전에 호출된다.

프론트 기준 stale 판정 시간은 다음과 같다.

- 대기방: 25초
- 게임 중: 50초

`heartbeat_room_presence`, `cleanup_stale_room_players`의 SQL 정의도 현재 저장소에는 없다.

### 3.4 실시간 참가자 갱신

`src/stores/room.js`는 로비에서 `rooms`, `room_players`의 Postgres Changes를 구독하고 방 목록을 다시 조회한다.

`src/api/roomApi.js`의 `subscribeToRoom()`은 상세 방에서 다음 변경을 구독한다.

- `rooms`의 해당 방 행
- `room_players`의 해당 방 참가자 행

`src/views/GameRoomView.vue`는 참가자 INSERT, UPDATE, DELETE를 로컬 상태에 먼저 합친 뒤 필요한 경우 방 전체를 다시 조회한다. Realtime 누락에 대비해 대기방에서는 3초 간격 polling도 실행한다.

### 3.5 라이어 게임 적용

라이어 게임도 다음 참가자 기능을 그대로 사용할 수 있다.

- 참가, 퇴장, 재접속
- 준비 완료
- 방장 시작 권한
- 강퇴
- 초대
- 접속 끊김 표시

마피아 전용 상태인 `room_players.role`, `room_players.is_alive`를 라이어의 정답 데이터 저장소로 재사용하는 것은 권장하지 않는다. 라이어 정체와 제시어는 노출 범위가 다르므로 라이어 전용 테이블과 RPC로 분리해야 한다.

## 4. 채팅 저장 및 실시간 반영 방식

### 4.1 로비와 대기방 채팅

`src/api/chatApi.js`는 Supabase Realtime Broadcast 채널을 사용한다.

| 용도 | 채널 |
| --- | --- |
| 공개 로비 | `public-lobby-chat` |
| 대기방 | `room-chat-${roomId}` |
| 미사용 보조 채널 | `game-chat-${roomId}`, `dead-chat-${roomId}` |

Broadcast 메시지는 DB에 저장되지 않는다. 새로 입장한 사용자는 이전 메시지를 복원할 수 없다.

귓속말도 Broadcast payload에 `targetUserId`, `targetNickname`, `isWhisper`를 넣는 방식이다. 화면에서 대상 사용자인지 검사한 뒤 표시한다.

### 4.2 게임 중 채팅

게임 중 채팅은 `game_messages` 테이블에 저장된다.

- 조회: `getGameMessages(roomId, gameId)`
- 추가: `sendGameMessage(...)`
- 실시간 반영: `subscribeToGameMessages(roomId, gameId, callback)`
- 구독 방식: `game_messages` INSERT에 대한 Postgres Changes

메시지에는 다음 정보가 있다.

- `room_id`
- `game_id`
- `round_no`
- `user_id`
- `nickname`
- `content`
- `message_type`
- `channel_type`
- `event_key`
- `is_system`
- `created_at`

현재 마피아 UI는 `channel_type`으로 `public`, `mafia`, `police`, `dead`를 구분한다. `src/views/GamePlayView.vue`의 `canSeeGameMessage()`가 화면 표시 여부를 필터링한다.

게임 종료 시 `game-logs` Storage bucket에 Markdown 로그를 업로드하는 코드도 있다.

### 4.3 라이어 게임 적용

라이어 게임의 대기방 채팅은 기존 Broadcast를 그대로 재사용할 수 있다.

게임 중 대화 기록이 필요하면 `game_messages`도 재사용할 수 있다. 라이어 게임에서는 일반적으로 `public` 채널만 사용하면 충분하다. 투표와 최종 정답 제출은 채팅 payload가 아니라 별도 RPC로 처리해야 한다.

### 4.4 채팅 관련 보안 주의점

현재 게임 채팅 조회는 `game_messages`를 직접 SELECT한 뒤 프론트에서 채널을 필터링한다. DB 정책이 같은 수준으로 제한하지 않으면 사용자가 직접 Data API를 호출해 다른 진영 채팅을 읽을 수 있다.

라이어 게임은 제시어와 라이어 정체를 채팅 payload, Broadcast payload, 공개 Realtime 행에 넣으면 안 된다. 클라이언트 필터는 보안 경계가 아니다.

## 5. 게임 상태 관리 방식

### 5.1 상태 저장 위치

현재 마피아 게임은 세 층으로 상태를 나눈다.

| 저장 위치 | 역할 |
| --- | --- |
| `rooms` | 방 단위의 큰 상태: `waiting`, `starting`, `playing`, `game_over`, `phase` |
| `games` | 한 판의 상세 상태: 단계, 라운드, 시작 시각, 종료 시각 |
| `room_players` | 참가자별 마피아 상태: 역할, 생존 여부, 준비 상태 |

`stalker-role-fix.sql`의 `start_game`은 다음 흐름을 구현한다.

1. 로그인, 방장, 대기방, 최소 인원, 준비 상태를 검증한다.
2. 아직 끝나지 않은 게임이 있는지 검사한다.
3. `rooms.role_config`에서 마피아 역할 수를 읽는다.
4. 역할 덱을 무작위로 섞어 `room_players.role`에 배정한다.
5. 모든 참가자를 생존 상태로 만든다.
6. `games`에 `playing`, `night`, 1라운드 행을 추가한다.
7. `rooms`를 `playing`, `night`로 바꾼다.
8. `game_messages`에 `night_start` 시스템 메시지를 추가한다.

### 5.2 마피아 전용 UI 결합

`src/views/GamePlayView.vue`는 사실상 마피아 전용 화면이다.

- 역할: `citizen`, `mafia`, `police`, `doctor`, `stalker`
- 단계: `role_reveal`, `night`, `day`, `discussion`, `vote`, `final_defense`, `result`
- 행동: `mafia_kill`, `police_check`, `doctor_save`, `track`
- 승리 결과: 마피아 팀 또는 시민 팀
- 보조 UI: 밤 행동, 사후 채팅, 역할 메모, 진영 채팅

`src/views/GameRoomView.vue`도 역할 구성, 첫날 밤 능력, 최후의 변론 등 마피아 규칙을 직접 표시한다.

라우트 자체는 공통이다.

- 대기방: `/rooms/:roomId`
- 플레이: `/rooms/:roomId/game`

하지만 현재 플레이 라우트는 항상 `GamePlayView.vue`를 연다. 라이어 게임을 추가할 때 게임 타입에 따른 화면 분기가 필요하다.

### 5.3 상태 동기화 방식

`GamePlayView.vue`는 다음 방식을 함께 사용한다.

- `getRoom`, `getCurrentGame`, `getMyGameRole` RPC 조회
- `rooms`, `games`, `game_messages` Postgres Changes 구독
- 2초 간격 게임 상태 polling
- 1초 간격 타이머 갱신
- 단계 종료 시 `process_due_game_phases` RPC 호출
- 10초 간격 방 heartbeat

즉, Realtime만 의존하지 않고 polling과 RPC 재동기화를 함께 사용한다.

### 5.4 현재 프론트에서 호출하는 게임 RPC

| RPC | 용도 | 로컬 SQL 정의 |
| --- | --- | --- |
| `start_game` | 게임 시작 | 있음 |
| `submit_night_action` | 밤 행동 제출 | 있음 |
| `get_my_role_info` | 역할별 보조 정보 | 있음 |
| `end_game` | 강제 종료 | 없음 |
| `skip_current_phase` | 방장 단계 스킵 | 없음 |
| `process_due_game_phases` | 만료 단계 진행 | 없음 |
| `submit_vote` | 처형 투표 | 없음 |
| `submit_final_defense_vote` | 최후 변론 투표 | 없음 |
| `get_current_game` | 현재 판 조회 | 없음 |
| `get_game_result` | 결과 조회 | 없음 |
| `award_game_rewards` | 보상 반영 | 없음 |
| `return_room_to_lobby` | 종료 후 대기방 복귀 | 없음 |
| `get_my_game_role` | 내 역할 조회 | 없음 |
| `get_visible_team_members` | 공개 가능한 팀원 조회 | 없음 |
| `get_vote_status` | 투표 상태 조회 | 없음 |

로컬 SQL 정의가 없다는 의미는 실제 Supabase DB에도 없다는 뜻은 아니다. 다만 현재 저장소만으로는 전체 게임 엔진을 재현할 수 없다.

## 6. Supabase/PostgreSQL 사용 목록

### 6.1 공통 테이블

| 테이블 | 확인 근거 | 용도 |
| --- | --- | --- |
| `profiles` | 프론트와 SQL | 사용자 프로필 |
| `rooms` | 프론트와 SQL | 방 메타데이터 |
| `room_players` | 프론트와 SQL | 방 참가자와 연결 상태 |
| `room_invites` | 프론트 | 방 초대 |
| `friendships` | 프론트 | 친구 관계 |

### 6.2 마피아 게임 테이블

| 테이블 | 확인 근거 | 용도 |
| --- | --- | --- |
| `games` | 프론트와 SQL | 판 상태와 단계 |
| `game_messages` | 프론트와 SQL | 게임 중 채팅과 시스템 이벤트 |
| `game_actions` | SQL | 밤 행동 |
| `role_types` | SQL | 역할 메타데이터 |
| `room_role_configs` | SQL | 정규화된 역할 구성 |
| `game_result_players` | SQL 보정 파일과 리뷰 문서 | 참가자별 결과 |
| `game_result_player_logs` | SQL 보정 파일과 리뷰 문서 | 참가자별 행동 로그 |

### 6.3 마이페이지 테이블

| 테이블 | 용도 |
| --- | --- |
| `player_game_match_records` | 게임 타입별 영속 전적 원본 |
| `player_game_stats` | 사용자와 게임 타입별 집계 |
| `player_game_role_stats` | 사용자, 게임 타입, 역할별 집계 |
| `player_stats` | 전체 및 마피아 호환 집계 |
| `player_role_stats` | 기존 마피아 호환 역할 집계 |
| `player_recent_matches` | 최근 게임 표시용 읽기 모델 |
| `player_achievements` | 업적 |
| `player_cosmetics` | 꾸미기 |

`mypage-game-records-fix.sql`은 `rooms.game_type`을 읽어 게임별 전적을 만들도록 작성되어 있다. `liar` 표시명도 이미 분기에 포함되어 있다.

### 6.4 공통 방 RPC

| RPC | 용도 | 로컬 SQL 정의 |
| --- | --- | --- |
| `create_room` | 방 생성 | 있음 |
| `join_room` | 방 입장과 재접속 | 있음 |
| `leave_room` | 방 퇴장 | 없음 |
| `kick_room_player` | 강퇴 | 없음 |
| `heartbeat_room_presence` | 접속 상태 갱신 | 없음 |
| `cleanup_stale_room_players` | stale 참가자 정리 | 없음 |
| `send_room_invite` | 방 초대 | 없음 |
| `respond_room_invite` | 방 초대 응답 | 없음 |

## 7. 라이어 게임 추가 시 재사용 가능한 구조

### 7.1 그대로 재사용

| 대상 | 이유 |
| --- | --- |
| `src/api/supabaseClient.js` | Supabase 연결과 에러 래핑 |
| `src/stores/auth.js` | 로그인 사용자 상태 |
| `src/router/index.js`의 인증 가드 | 로그인 보호 라우트 |
| `src/views/HomeView.vue`의 게임 선택기 | `game_type` 기반 게임 분리 |
| `src/stores/room.js` | 방 목록 조회와 Realtime 갱신 |
| `src/api/roomInviteApi.js` | 게임 타입과 무관한 방 초대 |
| `src/api/presenceApi.js` | 로비, 게임방, 게임 중 접속 표시 |
| `rooms`의 공통 필드 | 제목, 코드, 방장, 정원, 입장 방식 |
| `room_players`의 멤버십 필드 | 참가, 준비, 방장, 연결 상태 |
| 비공개방 비밀번호 처리 | 게임 타입과 무관 |
| 로비와 대기방 Broadcast 채팅 | 게임 시작 전 채팅 |
| `player_game_*` 전적 테이블 | `game_type`으로 분리 가능 |

### 7.2 조건부 재사용

| 대상 | 조건 |
| --- | --- |
| `/rooms/:roomId` 대기방 라우트 | 게임 타입별 설정 패널 분리 필요 |
| `/rooms/:roomId/game` 플레이 라우트 | 게임 타입에 따라 마피아 또는 라이어 화면 선택 필요 |
| `games` | 공통 판 ID와 상태만 사용하고 라이어 비밀 데이터는 별도 저장 |
| `game_messages` | 라이어 참가자만 읽고 쓸 수 있도록 RLS와 INSERT 정책 확인 필요 |
| `game_result_players` | 라이어 결과 형식을 공통 결과 모델에 맞출 수 있을 때 재사용 |
| `award_game_rewards` | 게임 타입별 보상 규칙 분기가 가능할 때 재사용 |
| `return_room_to_lobby` | 라이어 종료 상태도 처리하도록 분기 확인 필요 |

### 7.3 직접 재사용하면 안 되는 부분

| 대상 | 이유 |
| --- | --- |
| `GamePlayView.vue` | 마피아 단계, 역할, 밤 행동, 사후 채팅에 강하게 결합 |
| 현재 `start_game` 구현 | 마피아 역할 덱과 밤 단계로 고정 |
| `room_players.role` | 라이어 비밀 정보 저장소로 사용하면 노출 위험 |
| `rooms.role_config` | 라이어 설정 모델과 의미가 다름 |
| 클라이언트 필터만 사용하는 비밀 정보 처리 | 직접 API 호출로 우회 가능 |

## 8. 라이어 게임 추가 시 새로 필요한 구조

### 8.1 권장 게임 흐름

최소 흐름은 다음과 같이 잡을 수 있다.

1. `role_reveal`: 일반 참가자는 제시어를 확인하고 라이어는 라이어 안내만 확인
2. `discussion`: 참가자들이 순서대로 또는 자유롭게 설명
3. `vote`: 라이어로 의심되는 참가자에게 투표
4. `liar_guess`: 라이어가 지목된 경우 제시어 맞히기 기회 제공
5. `result`: 라이어 또는 일반 참가자 승리 결과 저장
6. `waiting`: 기존 대기방으로 복귀

동점 처리, 라이어 인원 수, 설명 순서 강제 여부, 최종 제시어 정답 기회는 구현 전에 규칙으로 확정해야 한다.

### 8.2 권장 신규 프론트 파일

| 파일 | 역할 |
| --- | --- |
| `src/api/liarGameApi.js` | 라이어 전용 RPC 호출과 읽기 모델 정규화 |
| `src/views/LiarGamePlayView.vue` | 제시어 확인, 토론 안내, 투표, 정답 제출, 결과 화면 |
| `src/components/LiarRoomSettings.vue` | 카테고리, 라이어 수, 토론 시간 등 라이어 방 설정 |

라우팅은 다음 둘 중 하나로 구성할 수 있다.

1. `/rooms/:roomId/game` 진입 시 `room.game_type`을 읽어 전용 화면 컴포넌트를 선택한다.
2. `/rooms/:roomId/liar` 같은 전용 라우트를 추가한다.

현재 구조와 주소 호환성을 유지하려면 첫 번째 방식이 더 자연스럽다.

### 8.3 권장 신규 DB 테이블

비밀 정보는 공개 스키마에 그대로 두지 않는 것이 핵심이다.

| 테이블 | 권장 스키마 | 역할 |
| --- | --- | --- |
| `liar_word_sets` | `private` | 카테고리와 제시어 원본 |
| `liar_game_secrets` | `private` | `game_id`, 제시어, 라이어 사용자 ID |
| `liar_game_states` | `public` 또는 `private` | 라이어 게임의 공개 가능한 단계 상태 |
| `liar_game_players` | `public` 또는 `private` | 참가자 순서, 투표 완료 여부 등 |
| `liar_votes` | `public` 또는 `private` | 투표자와 대상 |

`liar_game_states`, `liar_game_players`, `liar_votes`를 `public`에 둘 경우 RLS를 반드시 활성화하고 참가자별 SELECT, INSERT, UPDATE 정책을 설계해야 한다.

제시어와 라이어 ID는 행 전체를 읽을 수 있는 공개 테이블에 함께 저장하지 않는 것이 좋다. 일반 참가자와 라이어에게 서로 다른 payload를 반환하는 RPC가 필요하다.

채팅만으로 설명을 진행한다면 별도 `liar_clues` 테이블은 필요하지 않다. 설명을 구조화하거나 발언 순서를 강제하려면 `liar_clues`를 추가할 수 있다.

### 8.4 권장 신규 RPC

| RPC | 역할 |
| --- | --- |
| `start_liar_game(p_room_id)` | 참가자 검증, 제시어와 라이어 선정, 초기 상태 생성 |
| `get_current_liar_game(p_room_id)` | 공개 가능한 라이어 판 상태 반환 |
| `get_my_liar_assignment(p_room_id)` | 사용자별로 가려진 제시어 또는 라이어 안내 반환 |
| `submit_liar_vote(p_room_id, p_target_user_id)` | 투표 저장 |
| `submit_liar_guess(p_room_id, p_guess)` | 지목된 라이어의 최종 정답 제출 |
| `advance_liar_phase(p_room_id)` | 시간 만료 또는 조건 충족 시 단계 전환 |
| `finish_liar_game(p_room_id)` | 승패 계산과 공통 결과 모델 저장 |

기존 UI 흐름을 최대한 유지하려면 `start_game`, `get_current_game`, `process_due_game_phases`, `return_room_to_lobby` 같은 공통 RPC가 `rooms.game_type`을 기준으로 내부 구현을 분기하도록 리팩터링할 수 있다.

초기 구현에서는 라이어 전용 RPC를 직접 호출하고, 안정화 후 공통 dispatcher를 도입하는 방식도 가능하다.

### 8.5 결과 및 전적 연결

`mypage-game-records-fix.sql`은 `game_result_players` 변경을 `player_game_match_records`로 동기화한다. 라이어 게임 종료 시 공통 결과 모델에 다음 정보를 넣으면 기존 마이페이지 집계를 재사용할 수 있다.

- `game_id`
- `user_id`
- 라이어 게임 역할 키: 예를 들어 `liar`, `citizen`
- 승리 여부
- 생존 여부 대신 결과 화면에서 사용할 호환 값

장기적으로는 `survived`, `citizen_win_rate`, `mafia_win_rate`처럼 마피아 의미가 남은 필드를 게임별 통계 JSON 또는 게임별 확장 테이블로 분리하는 것이 좋다.

## 9. 예상 위험 요소

### 9.1 기준 스키마와 배포 파일 부재

현재 저장소만으로는 라이브 DB를 재현할 수 없다. README가 요구하는 `room-admin.sql`도 폴더에 없다.

라이어 구현 전에 실제 Supabase 프로젝트에서 다음을 덤프하거나 문서화해야 한다.

- 테이블과 컬럼
- 인덱스와 제약 조건
- RLS 활성화 여부와 정책
- 함수 정의
- 트리거
- Storage bucket 정책
- Realtime publication 대상

### 9.2 공통처럼 보이는 함수의 마피아 결합

이름이 `start_game`, `get_current_game`처럼 일반적이어도 실제 구현은 마피아 규칙일 수 있다. 라이어 방에서 기존 `start_game`을 그대로 호출하면 마피아 역할이 배정되고 밤 단계가 시작된다.

게임 타입별 dispatcher 또는 라이어 전용 API 분리가 필요하다.

### 9.3 비밀 정보 노출

라이어 게임은 제시어와 라이어 ID가 핵심 비밀 정보다.

- 공개 테이블 SELECT
- Realtime Postgres Changes
- Broadcast payload
- 브라우저 상태
- Storage 로그
- 결과 생성 전 로그

위 경로로 비밀이 조기 노출되지 않도록 해야 한다. 비밀은 `private` 스키마에 저장하고 사용자별 RPC에서 필요한 정보만 반환하는 방식이 적합하다.

### 9.4 RLS와 Data API 권한

새 테이블을 `public`에 추가하면 RLS를 활성화해야 한다. RLS와 별개로 Data API 접근 권한도 확인해야 한다.

특히 다음 항목은 라이브 DB 정책을 검증해야 한다.

- `rooms` 직접 UPDATE
- `room_players` 직접 UPDATE
- `game_messages` SELECT와 INSERT
- `game_result_players`
- `game_result_player_logs`
- `game-logs` Storage bucket

### 9.5 클라이언트 필터에 의존한 채팅 보안

현재 마피아 게임 채팅은 프론트에서 `channel_type`을 필터링한다. DB 정책이 약하면 진영 채팅이 노출될 수 있다.

라이어 게임의 일반 채팅에는 문제가 적지만, 이 패턴을 비밀 제시어 전달에 재사용하면 안 된다.

### 9.6 상태 전환 경쟁 조건

현재 게임 화면은 Realtime, polling, 단계 만료 RPC를 함께 사용한다. 여러 참가자가 동시에 `process_due_game_phases`를 호출할 수 있다.

라이어 전용 `advance_liar_phase`는 다음 조건을 갖춰야 한다.

- 현재 단계 행 잠금
- 이미 진행된 단계에 대한 idempotent 처리
- 중복 시스템 메시지 방지
- 중복 결과 저장 방지
- 동점 투표 처리의 결정성

### 9.7 방 설정 모델 혼합

현재 방 생성 UI와 `create_room` RPC는 마피아 설정을 요구한다. 라이어 게임에 같은 필드를 억지로 재사용하면 의미가 불명확해진다.

공통 방 설정과 게임별 설정을 분리하고, 대기방 UI도 게임 타입별 컴포넌트로 나누는 것이 좋다.

### 9.8 기존 `liar` 또는 과거 게임 타입 데이터

운영 DB에 과거 준비 중 게임 타입이나 테스트 전적이 있다면 `rooms.game_type`, 최근 전적, 집계 테이블을 확인해야 한다. 게임 타입 문자열을 변경할 때는 표시명 변경만으로 끝내지 말고 기존 행 마이그레이션 여부도 판단해야 한다.

### 9.9 노출 스키마의 `security definer`

현재 보정 SQL은 `public` 스키마에 `security definer` 함수를 정의한다. 신규 라이어 구현에서는 Supabase 보안 권고에 맞춰 권한 상승 구현을 비공개 스키마에 두고, 외부에 노출하는 진입점은 최소 권한으로 설계하는 방식을 검토해야 한다.

## 10. 권장 구현 순서

1. 라이브 Supabase 스키마와 현재 배포 RPC를 덤프한다.
2. 라이어 규칙을 확정한다: 라이어 수, 동점, 정답 기회, 발언 순서, 시간 제한.
3. 공통 방 설정과 마피아 전용 설정의 경계를 정한다.
4. 비밀 저장용 `private` 테이블과 라이어 전용 공개 상태 테이블을 설계한다.
5. 라이어 전용 RPC를 만든다.
6. `LiarGamePlayView.vue`와 게임 타입별 라우팅 분기를 만든다.
7. `game_messages`, 결과, 보상, 마이페이지 전적 연결을 추가한다.
8. RLS, Storage, Realtime publication과 중복 단계 전환을 검증한다.

## 11. 결론

현재 프로젝트는 방, 참가자, 인증, 초대, 접속 상태, 로비 채팅을 여러 미니게임에서 공유할 수 있는 기반을 이미 갖고 있다. `rooms.game_type`과 마이페이지의 게임 타입별 집계도 라이어 게임을 수용할 방향으로 만들어져 있다.

반면 실제 게임 플레이 엔진과 화면은 마피아 규칙에 밀접하게 결합되어 있다. 라이어 게임은 기존 마피아 엔진을 수정해 끼워 넣기보다, 공통 방 구조 위에 라이어 전용 상태, RPC, 플레이 화면을 추가하는 방식이 적합하다.
