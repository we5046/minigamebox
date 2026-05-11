# 프로젝트 파일 구조 분석

## 개요

이 프로젝트는 `Vite + Vue 3` 기반의 Mafia Night 웹 게임 클라이언트입니다. 상태 관리는 `Pinia`, 라우팅은 `vue-router`, 백엔드 데이터와 실시간 기능은 `Supabase`를 사용합니다.

주요 기능은 로그인/회원가입, 로비, 방 생성 및 입장, 방 초대, 친구 요청, 실시간 채팅, 마이페이지 데이터 표시입니다.

## 최상위 구조

```text
game01/
├─ .vscode/                  # VS Code 설정
├─ dist/                     # Vite 빌드 결과물
├─ node_modules/             # npm 의존성
├─ public/                   # 정적 파일
│  └─ favicon.ico
├─ src/                      # 실제 애플리케이션 소스
│  ├─ api/                   # Supabase API 래퍼
│  ├─ assets/                # 전역 CSS
│  ├─ components/            # 재사용 Vue 컴포넌트
│  ├─ router/                # 라우터 설정
│  ├─ stores/                # Pinia 상태 저장소
│  ├─ views/                 # 페이지 단위 Vue 컴포넌트
│  ├─ App.vue                # 최상위 앱 레이아웃
│  └─ main.js                # 앱 부트스트랩
├─ .env                      # 로컬 Supabase 환경 변수
├─ .env.example              # 환경 변수 예시
├─ .gitignore
├─ db.json                   # 초기/목업 게임 데이터
├─ index.html                # Vite HTML 엔트리
├─ jsconfig.json             # @ 경로 별칭 설정
├─ package.json              # 스크립트 및 의존성
├─ package-lock.json
├─ README.md                 # 기본 Vite README
├─ supabase-schema.sql       # Supabase DB 스키마, RLS, RPC, Realtime 설정
├─ userDB.json               # 이전 로컬 사용자/방 데이터로 보이는 JSON
└─ vite.config.js            # Vite 설정
```

`dist/`와 `node_modules/`는 생성물/의존성 디렉터리라 구조 분석의 핵심 대상은 아닙니다.

## 실행 및 빌드

`package.json` 기준 스크립트는 다음과 같습니다.

```sh
npm run dev      # Vite 개발 서버
npm run build    # 프로덕션 빌드
npm run preview  # 빌드 결과 미리보기
```

주요 의존성:

- `vue`: Vue 3 애플리케이션 프레임워크
- `vue-router`: 페이지 라우팅
- `pinia`: 전역 상태 관리
- `@supabase/supabase-js`: Supabase Auth, DB, Realtime 연동
- `vite`, `@vitejs/plugin-vue`: 개발 서버와 빌드 도구

## 애플리케이션 진입 흐름

```text
index.html
└─ src/main.js
   ├─ App.vue
   ├─ Pinia 생성
   ├─ authStore.initialize()
   └─ router 등록 후 #app에 mount
```

`src/main.js`는 앱을 바로 마운트하지 않고, 먼저 인증 스토어를 초기화합니다. 이 덕분에 새로고침 후에도 현재 Supabase 세션을 확인한 뒤 라우터 가드를 적용할 수 있습니다.

## 라우팅 구조

라우터는 `src/router/index.js`에 정의되어 있습니다.

| Path | Name | View | 접근 조건 |
| --- | --- | --- | --- |
| `/` | - | `/login`으로 redirect | - |
| `/home` | `home` | `HomeView.vue` | 로그인 필요 |
| `/login` | `login` | `LoginView.vue` | 게스트 전용 |
| `/signup` | `signup` | `SignupView.vue` | 게스트 전용 |
| `/forgot-password` | `forgot-password` | `ForgotPasswordView.vue` | 게스트 전용 |
| `/rooms/:roomId` | `game-room` | `GameRoomView.vue` | 로그인 필요 |
| `/shop` | `shop` | `ShopView.vue` | 로그인 필요 |
| `/mypage` | `mypage` | `MyPageView.vue` | 로그인 필요 |

`beforeEach` 가드에서 `authStore.user`를 기준으로 인증 필요 페이지와 게스트 전용 페이지를 분기합니다.

## src 디렉터리 상세

### `src/api/`

Supabase와 직접 통신하는 계층입니다. 화면 컴포넌트가 Supabase 쿼리를 직접 작성하지 않도록, 데이터 조회/변경/정규화/구독 로직을 이곳에 모아둔 구조입니다.

| 파일 | 역할 |
| --- | --- |
| `supabaseClient.js` | `.env`의 `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`로 Supabase 클라이언트 생성 |
| `authApi.js` | 로그인, 회원가입, 로그아웃, 프로필 조회, 현재 사용자 객체 변환 |
| `session.js` | `localStorage` 기반 현재 사용자 저장/삭제 유틸 |
| `roomApi.js` | 방 목록/상세 조회, 방 생성, 입장, 수정, 준비 상태, 나가기, 삭제, Realtime 구독 |
| `chatApi.js` | 공개/방/게임/사망자 채팅 채널 구독과 broadcast 메시지 전송 |
| `friendApi.js` | 친구 목록 조회, 친구 요청/응답/삭제, 친구 변경 Realtime 구독 |
| `roomInviteApi.js` | 방 초대 목록, 초대 전송/응답, 초대 Realtime 구독 |
| `myPageApi.js` | 프로필, 랭크, 통계, 역할 기록, 최근 경기, 업적, 코스메틱 데이터 조회 |

### `src/stores/`

Pinia 스토어 계층입니다.

| 파일 | 역할 |
| --- | --- |
| `auth.js` | Supabase 세션 초기화, 인증 상태 구독, 현재 사용자 프로필 보관 |
| `room.js` | 방 목록 상태 보관, 방/참여자 변경 Realtime 구독 |
| `toast.js` | 토스트 메시지 큐 관리 |
| `counter.js` | Vue 템플릿 기본 예제에 가까운 카운터 스토어 |

현재 실사용 핵심 스토어는 `auth`, `room`, `toast`입니다. `counter.js`는 기능과 직접 연결되지 않은 템플릿 잔여 코드로 보입니다.

### `src/views/`

라우트에 매핑되는 페이지 단위 컴포넌트입니다.

| 파일 | 역할 |
| --- | --- |
| `HomeView.vue` | 로비 화면. 방 목록, 방 생성, 온라인 유저 presence, 친구 요청, 방 초대 알림, 공개 채팅 처리 |
| `GameRoomView.vue` | 방 상세 화면. 참가자, 준비 상태, 방 설정 수정, 친구 초대, 방 채팅, 게임 시작/퇴장 처리 |
| `LoginView.vue` | 로그인 화면 |
| `SignupView.vue` | 회원가입 화면 |
| `ForgotPasswordView.vue` | 비밀번호 재설정 화면. 현재 API에서는 실제 재설정 미지원 에러를 던짐 |
| `MyPageView.vue` | 프로필, 랭크, 통계, 업적, 코스메틱 표시 |
| `ShopView.vue` | 상점 화면 |
| `AboutView.vue` | 현재 라우터에는 연결되지 않은 기본/잔여 View |

### `src/components/`

| 파일 | 역할 |
| --- | --- |
| `ToastNotification.vue` | `toast` 스토어의 메시지를 화면에 표시 |

### `src/assets/`

| 파일 | 역할 |
| --- | --- |
| `base.css` | 기본 색상, 레이아웃 변수, 리셋 스타일로 추정 |
| `main.css` | 앱 전역 스타일 엔트리. `main.js`에서 import |

## 데이터베이스 구조

`supabase-schema.sql`에는 Supabase에서 사용할 테이블, RLS 정책, RPC 함수, Realtime publication 설정이 포함되어 있습니다.

주요 테이블:

- `profiles`: 사용자 프로필, 로그인 ID, 닉네임, 캐릭터 정보
- `rooms`: 게임 방 정보
- `room_players`: 방 참가자 정보
- `player_ranks`: 랭크 정보
- `player_stats`: 전체 통계
- `player_role_stats`: 역할별 통계
- `player_recent_matches`: 최근 경기
- `player_achievements`: 업적
- `player_cosmetics`: 코스메틱
- `friendships`: 친구 요청/친구 관계
- `room_invites`: 방 초대

주요 RPC 함수:

- `send_friend_request`
- `respond_friend_request`
- `remove_friend`
- `send_room_invite`
- `respond_room_invite`
- `create_room`
- `join_room`
- `leave_room`

Realtime 대상 테이블:

- `rooms`
- `room_players`
- `friendships`
- `room_invites`

## 데이터 흐름 요약

### 인증

```text
LoginView / SignupView
└─ authApi.js
   ├─ supabase.auth.signInWithPassword()
   ├─ supabase.auth.signUp()
   └─ profiles 테이블 조회/생성
      └─ authStore.user 갱신
```

`loginId`는 실제 이메일 대신 `loginId@mafia.local` 형태로 Supabase Auth 이메일에 매핑됩니다.

### 로비와 방 목록

```text
HomeView.vue
└─ roomStore
   └─ roomApi.getRooms()
      └─ rooms + room_players + profiles join 결과 정규화
```

방 목록은 `rooms`, `room_players` 변경 이벤트를 구독해 갱신됩니다.

### 방 상세

```text
GameRoomView.vue
├─ roomApi.getRoom()
├─ roomApi.joinRoom()
├─ roomApi.updateRoom()
├─ roomApi.setPlayerReady()
├─ roomInviteApi.*
└─ chatApi.subscribeToRoomChat()
```

방 상세에서는 참가자 상태, 호스트 권한, 방 설정, 초대, 방 채팅이 한 화면에서 관리됩니다.

### 친구와 초대

```text
HomeView.vue / GameRoomView.vue
├─ friendApi.js
│  └─ friendships 테이블 + RPC
└─ roomInviteApi.js
   └─ room_invites 테이블 + RPC
```

친구 요청과 방 초대는 테이블 변경 구독을 통해 알림 목록을 갱신합니다.

## 환경 변수

`.env.example` 기준 필요한 값:

```text
VITE_SUPABASE_URL=https://your-project-ref.supabase.co
VITE_SUPABASE_ANON_KEY=your-anon-key
```

`.env`는 로컬 실행용 민감 설정이므로 Git에 포함하지 않는 것이 좋습니다.

## 로컬 JSON 파일

| 파일 | 현재 역할 추정 |
| --- | --- |
| `db.json` | json-server 또는 초기 목업용으로 만든 게임 데이터. 현재 Vue 코드에서는 직접 import하지 않음 |
| `userDB.json` | 이전 로컬 로그인/방 데이터 저장소로 보임. 현재 핵심 인증은 Supabase로 이동한 상태 |

현재 앱 로직은 대부분 Supabase를 기준으로 작성되어 있으므로, 두 JSON 파일은 과거 개발 단계의 목업 데이터 또는 테스트 데이터일 가능성이 큽니다.

## 주의할 점

1. 여러 파일에서 한글 문자열이 깨져 보입니다.
   - 예: `App.vue`, `authApi.js`, `friendApi.js`, `myPageApi.js`, `roomInviteApi.js`, `chatApi.js`, `db.json`, `userDB.json`
   - 파일 인코딩 또는 저장 과정에서 문자가 손상된 것으로 보입니다.

2. `ForgotPasswordView.vue`는 화면은 존재하지만, `authApi.resetPassword()`가 실제 Supabase 비밀번호 재설정을 구현하지 않고 에러를 던집니다.

3. `AboutView.vue`, `counter.js`, `db.json`, `userDB.json`은 현재 라우팅/앱 흐름에서 핵심 사용처가 보이지 않습니다.

4. `App.vue`의 헤더는 로그인 상태와 무관하게 표시됩니다. 로그인/회원가입 화면에서도 헤더 및 로그아웃 버튼이 노출되는지 UI 확인이 필요합니다.

5. `supabaseClient.js`에는 환경 변수가 없을 때 에러를 던지는 대체 클라이언트가 있지만, 일부 메서드만 구현되어 있어 화면에 따라 다른 형태의 런타임 문제가 날 수 있습니다.

## 추천 정리 방향

1. 깨진 한글 문자열 복구 및 파일 인코딩 통일
2. 사용하지 않는 템플릿 파일(`AboutView.vue`, `counter.js`) 정리 여부 결정
3. `db.json`, `userDB.json`을 계속 목업 데이터로 사용할지, Supabase 전환 후 제거할지 결정
4. 비밀번호 재설정 기능을 Supabase Auth 정책에 맞춰 재설계
5. 인증 화면에서 공통 헤더 노출 여부 점검
6. README를 현재 프로젝트 기준으로 업데이트

