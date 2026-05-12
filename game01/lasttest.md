# 프로젝트 코드 리뷰 및 게임 개발 전 점검

점검일: 2026-05-12

## 점검 결과 요약

- `npm run build`는 성공했다.
- 현재 프로젝트는 로비, 회원/프로필, 친구, 방 생성/입장, 방 초대, 채팅, 마이페이지의 기본 골격이 갖춰져 있다.
- 본격적인 게임 로직 개발 전에 먼저 막아야 할 위험은 `비공개방 입장 정책`, `깨진 한글 메시지`, `초대 수락/만료 처리`, `채팅 권한 검증`이다.
- 자동화 테스트 스크립트가 없어서 현재 검증은 빌드와 정적 코드 리뷰 중심이다.

## 우선순위 발견사항

### Critical. 비공개방이 직접 URL 접근으로 입장 가능하다

근거:
- `src/views/GameRoomView.vue:282-290`
- `src/views/GameRoomView.vue:437-447`
- `supabase-schema.sql:1057-1117`

`GameRoomView`는 방 정보를 불러온 뒤 로그인 사용자가 현재 플레이어가 아니면 자동으로 `joinRoom()`을 호출한다. DB 함수 `join_room`도 `entry_mode = 'private'` 또는 비밀번호를 검사하지 않는다.

현재 홈 화면에서는 비공개방 입장 버튼을 숨기거나 별도 버튼으로 보여주지만, `/rooms/:roomId` URL을 직접 열면 비공개방도 입장될 수 있다.

권장 조치:
- `join_room`에 공개방만 직접 입장 가능하도록 서버 검증을 추가한다.
- 초대 수락 입장은 별도 RPC 또는 초대 검증 컨텍스트를 통해 허용한다.
- 비밀번호 입장 정책을 확정한다면 `join_room_with_password(room_id, password)` 같은 서버 함수를 분리한다.

### High. 만료/거절/이미 처리된 초대도 수락 플로우에서 방으로 이동할 수 있다

근거:
- `src/views/HomeView.vue:710-718`
- `supabase-schema.sql:873-888`
- `src/views/GameRoomView.vue:282-290`

`respond_room_invite`는 초대가 `pending`이 아니거나 만료된 경우에도 초대 row를 반환한다. 그런데 `acceptRoomInvite()`는 반환된 초대 상태를 확인하지 않고 `/rooms/:roomId?invited=1`로 이동한다.

이 문제는 위의 직접 입장 문제와 결합되면 만료된 초대에서 방 입장까지 이어질 수 있다.

권장 조치:
- `respondRoomInvite` 결과의 `status === 'accepted'`를 확인한 뒤 이동한다.
- 만료/거절/이미 처리된 초대는 토스트만 표시하고 이동하지 않는다.
- 서버 함수도 수락 실패 상태를 명확히 예외 또는 상태 코드로 구분하는 편이 안전하다.

### High. 여러 사용자 노출 문구가 한글 깨짐 상태다

근거:
- `src/api/authApi.js`
- `src/api/friendApi.js`
- `src/api/roomInviteApi.js:79-120`
- `src/api/chatApi.js:125-146`
- `src/api/myPageApi.js`
- `src/stores/profile.js:29-50`
- `src/api/supabaseClient.js`

빌드는 통과하지만 API 오류 메시지, 기본 프로필 문구, 마이페이지 통계 라벨, 채팅 오류 문구가 깨져 있다. 사용자는 실패 상황에서 의미 없는 문구를 보게 된다.

권장 조치:
- 깨진 문자열을 전부 UTF-8 한글 문구로 복구한다.
- PowerShell에서 파일을 복원/생성할 때 `-Encoding utf8`을 고정한다.
- 문자열 복구 후 주요 화면에서 토스트와 기본 라벨을 직접 확인한다.

### High. 방 채팅/로비 채팅은 권한 검증 없이 Realtime Broadcast에 의존한다

근거:
- `src/api/chatApi.js:37-48`
- `src/api/chatApi.js:113-148`
- `src/views/GameRoomView.vue:257-270`

채팅은 Supabase Broadcast 채널명을 알고 있으면 메시지를 보낼 수 있는 구조다. `isSystem`도 클라이언트 payload 값이라 일반 사용자가 시스템 메시지처럼 보낼 여지가 있다.

게임 단계에 들어가면 생존자 채팅, 사망자 채팅, 귓속말, 시스템 로그가 모두 권한 민감해진다.

권장 조치:
- 게임 채팅은 DB insert/RPC 기반으로 전환하고 RLS 또는 서버 함수에서 방 멤버십, 생존 여부, 역할/페이즈를 검사한다.
- 시스템 메시지는 클라이언트가 직접 `isSystem: true`를 보내지 못하게 한다.
- Broadcast는 UI 반영용 알림으로만 사용하거나 서버 검증 후 발행한다.

### Medium. 오프라인 유저 초대 불가 조건이 클라이언트 presence에만 의존한다

근거:
- `src/views/GameRoomView.vue:89-102`
- `src/views/GameRoomView.vue:334-343`
- `supabase-schema.sql:725-837`

UI에서는 presence 목록 기준으로 오프라인 친구 초대를 막지만, `send_room_invite` 서버 함수는 대상이 온라인인지 확인하지 않는다. 클라이언트를 우회하면 오프라인 친구에게도 초대 row를 만들 수 있다.

권장 조치:
- 요구사항상 반드시 막아야 한다면 presence를 DB 테이블로 동기화하거나, 초대 정책을 "UI에서는 오프라인 초대 비활성화, 서버는 친구/방 조건만 검증"으로 명확히 문서화한다.

### Medium. 홈의 비공개방 버튼이 동작 없는 버튼으로 남아 있다

근거:
- `src/views/HomeView.vue:1948-1958`

공개방은 `입장하기` 버튼에 `@click="enterRoom(room.id)"`가 있지만, 비공개방의 `비밀번호 입력 후 입장` 버튼은 클릭 핸들러가 없다. 현재는 사용자가 누를 수 있는 것처럼 보일 수 있다.

권장 조치:
- 비밀번호 입장 기능을 구현하기 전까지는 명확히 `disabled` 처리하고 문구를 "초대 필요" 등으로 바꾼다.
- 비밀번호 입장을 구현한다면 모달과 서버 검증 RPC를 함께 추가한다.

### Medium. `joinRoom()` 안에 도달 불가능한 코드가 남아 있다

근거:
- `src/views/GameRoomView.vue:437-458`

`joinRoom()`은 `return` 이후에 기존 입장 메시지 전송 코드가 남아 있다. 현재 동작에는 영향이 작지만 유지보수자가 실제 실행되는 코드로 오해할 수 있다.

권장 조치:
- 도달 불가능한 코드를 제거한다.
- 입장 알림은 이미 분리된 `announceRoomEntry()`만 사용하도록 정리한다.

### Medium. 테스트 체계가 없다

근거:
- `package.json`

현재 scripts는 `dev`, `build`, `preview`뿐이다. 게임 로직은 역할 배정, 밤/낮 페이즈, 투표, 승패 판정처럼 회귀 위험이 큰 코드가 될 가능성이 높다.

권장 조치:
- 게임 로직은 UI와 분리된 순수 함수 모듈로 만들고 단위 테스트를 먼저 붙인다.
- 최소 테스트 후보: 역할 배정 합계, 페이즈 전환, 투표 동률 처리, 마피아/시민 승리 조건, 재접속 상태 복구.

## 기능별 점검

### 인증/프로필

- Supabase Auth 기반 로그인/회원가입 구조는 갖춰져 있다.
- `profiles`, `player_stats`, `player_ranks`를 묶어 현재 유저 표시용 모델로 정규화한다.
- 한글 오류 메시지와 기본 마이페이지 문구가 깨져 있어 사용자 경험상 먼저 복구가 필요하다.
- 프로필 store가 auth store와 동기화하는 구조라, 향후 게임 내 닉네임/칭호 표시와 일관성을 유지하기 쉽다.

### 로비/방 목록

- 방 목록, 필터, 페이지네이션, 방 상세 미리보기, 공개방 입장 흐름은 구현되어 있다.
- 비공개방은 UI상 직접 입장을 막는 것처럼 보이지만 서버 입장 함수가 막지 않는다.
- 방 목록은 authenticated 사용자에게 전체 공개다. 비공개방 제목/모드/인원까지 보이는 정책이 맞는지 확인이 필요하다.

### 방 생성/설정

- 참가 인원, 모드, 시간, 최소 시작 인원, 역할 구성, 공개/비공개 설정이 구현되어 있다.
- `create_room` 서버 함수에서 인원 범위와 비공개방 비밀번호 필수 조건을 검증한다.
- 방 수정은 클라이언트에서 `rooms` 직접 update를 사용한다. RLS상 host만 가능하지만, 게임 시작 이후 수정 가능 범위는 추가 정책이 필요하다.

### 친구/초대

- 친구 목록 기반 초대, 닉네임 검색, 이미 방에 있는 유저 차단, 오프라인 표시, 초대 쿨타임 UI가 구현되어 있다.
- 초대 알림은 방 제목, 방장, 모드, 인원, 비공개 배지를 표시하고 방 ID/비밀번호를 노출하지 않는다.
- 서버는 친구 관계, 방 멤버 여부, 방 정원, 대기 상태를 검증한다.
- 오프라인 차단은 클라이언트 조건이라 서버 정책과 요구사항을 맞춰야 한다.

### 채팅

- 로비 공개 채팅, 귓속말, 방 채팅 UI와 Broadcast 송수신은 구현되어 있다.
- 현재 채팅은 게임 규칙 권한을 검증하기 어렵다. 게임 개발 전 채팅 저장/권한 모델을 정해야 한다.
- 시스템 메시지는 클라이언트 입력과 분리할 필요가 있다.

### Realtime/Presence

- 로비/방 presence를 통해 온라인 여부와 현재 위치를 표시한다.
- presence는 브라우저 세션 기반이라 서버에서 영속 정책으로 쓰기에는 부족하다.
- 게임 진행 상태 복구, 이탈/재접속, 강제 퇴장 같은 기능은 별도 DB 상태가 필요하다.

## 게임 개발 착수 전 권장 처리 순서

1. 비공개방 입장 정책 확정 및 서버 함수 분리
2. 만료/처리된 초대 수락 시 이동 차단
3. 깨진 한글 문구 전체 복구
4. 채팅 권한 모델 결정
5. 게임 상태 테이블 설계
6. 게임 로직 순수 함수화 및 테스트 추가
7. 역할 배정, 페이즈, 투표, 승패 판정 구현

## 게임 상태 설계 시 필요한 테이블 후보

- `games`: room_id, phase, turn, started_at, ended_at, winner
- `game_players`: game_id, user_id, role, alive, seat_no, disconnected_at
- `game_actions`: game_id, actor_user_id, action_type, target_user_id, phase, turn
- `game_votes`: game_id, voter_user_id, target_user_id, phase, turn
- `game_events`: game_id, event_type, payload, visibility, created_at
- `game_chat_messages`: game_id, room_id, sender_user_id, channel_type, content, created_at

## 최종 판정

현재 코드는 로비/방/친구 초대까지의 프로토타입으로는 진행 가능하다. 다만 게임 본편은 권한 검증과 상태 일관성이 핵심이므로, 비공개방 입장과 초대 수락의 서버 정책을 먼저 정리해야 한다.

게임 개발에 바로 들어가기보다는 위 Critical/High 항목을 먼저 처리한 뒤, 게임 로직은 테스트 가능한 별도 모듈로 시작하는 것이 안전하다.
