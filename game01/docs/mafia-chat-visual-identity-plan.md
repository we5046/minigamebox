# 마피아 채팅 시각 식별 개선 계획

## 1. 목적

마피아 게임 채팅에서 다음 정보를 한눈에 구분할 수 있도록 시각 체계를 개선한다.

1. 첫날 사망자가 남긴 유언
2. 내가 개인 메모를 지정한 참가자의 메시지
3. 마피아·경찰처럼 현재 플레이어가 확실히 알고 있는 팀원의 메시지

이번 문서는 구현 방향만 정의한다. 실제 소스코드와 DB는 변경하지 않는다.

---

## 2. 현재 구조 분석

### 첫날 사망자 유언

- `remote_admin.sql`의 `public.submit_first_day_will()`이 유언을 `game_messages`에 공개 채팅으로 저장한다.
- 일반 채팅과 데이터 형태가 거의 같지만 `event_key`가 `first_day_will:{userId}` 형식이므로 정확히 식별할 수 있다.
- `src/api/chatApi.js`의 `normalizeGameMessage()`가 `eventKey`를 프론트에 전달하고 있다.
- 현재 `src/views/GamePlayView.vue`에서는 유언도 일반 공개 채팅과 같은 `chat-bubble channel-public`로 렌더링된다.

따라서 유언 식별을 위한 DB 변경은 필요하지 않다.

### 개인 역할 메모

- 메모는 `playerRoleMemos`에 `{ userId: role }` 형태로 저장된다.
- 역할 값은 `mafia`, `police`, `doctor`, `stalker`이다.
- 메모는 사용자·방·게임별 `localStorage`에 저장되므로 완전히 개인적인 정보다.
- 현재 메모 색상은 참가자 목록의 `.survivor-chip.memo-*`에만 적용된다.

채팅 메시지의 `userId`와 `playerRoleMemos[userId]`를 연결하면 같은 색상을 채팅에도 적용할 수 있다.

### 확인된 팀원 정보

- `get_visible_team_members` RPC와 `visibleTeamMembers`가 현재 플레이어에게 공개 가능한 팀원만 반환한다.
- `playersWithStatus`에서 각 플레이어에 `visibleTeamRole`을 계산한다.
- 참가자 목록에는 이미 `.team-mafia`, `.team-police` 스타일이 존재한다.

채팅 메시지 작성자의 `userId`를 `playersWithStatus`와 연결하면 공개 채팅에서도 확인된 팀원 색상을 적용할 수 있다.

---

## 3. 디자인 원칙

### 의미는 색상 하나에만 의존하지 않는다

색상만으로 유언, 개인 추측, 확정 팀 정보를 구분하면 혼란이 생긴다. 각 의미에는 색상 외 표식을 함께 제공한다.

| 의미 | 배경색 | 추가 표식 |
| --- | --- | --- |
| 첫날 유언 | 어두운 자주색·회색 계열 | `첫날 유언` 라벨, 굵은 테두리, 인용문 형태 |
| 개인 메모 | 메모 역할 색상 | `내 메모: 마피아` 같은 작은 라벨 |
| 확인된 팀원 | 실제 팀 색상 | `확인된 마피아 팀` 또는 `확인된 경찰 팀` 라벨 |
| 전용 채널 | 기존 채널 색상 | 기존 `마피아`, `경찰`, `사후` 채널 칩 |

### 확정 정보와 개인 추측을 다르게 표현한다

- 확인된 팀원: 선명한 실선 테두리와 `확인된 팀` 라벨
- 개인 메모: 조금 흐린 배경과 점선 또는 얇은 테두리, `내 메모` 라벨

같은 빨강이나 파랑을 사용하더라도 표식 강도를 달리해 확정 정보와 추측을 혼동하지 않게 한다.

---

## 4. 첫날 유언 디자인

유언은 일반 채팅 버블의 색만 바꾸지 않고 별도 카드로 표현한다.

### 권장 형태

- 일반 메시지보다 넓은 카드 폭을 사용한다.
- 카드 상단에 `첫날 사망자 유언` 라벨을 표시한다.
- 작성자명과 시간을 별도 헤더 행에 둔다.
- 본문 좌측에 굵은 자주색 세로선을 넣어 인용문처럼 보이게 한다.
- 배경은 어두운 자주색과 회색을 섞고, 일반 채팅보다 높은 대비의 테두리를 사용한다.
- 유언 본문은 일반 채팅보다 약간 큰 글씨와 높은 행간을 사용한다.
- 유언에는 `내 메시지`, 메모, 팀원 배경색을 적용하지 않는다.

예상 구조:

```html
<article class="chat-bubble first-day-will-message">
  <div class="will-label">첫날 사망자 유언</div>
  <div class="chat-meta">작성자 · 시간</div>
  <blockquote>유언 내용</blockquote>
</article>
```

### 식별 방식

```js
function isFirstDayWillMessage(message) {
  return message.eventKey?.startsWith('first_day_will:') === true
}
```

현재 `event_key`가 이미 고유한 의미를 가지므로 MVP에서는 별도 컬럼을 추가하지 않는다.

---

## 5. 메모 색상을 채팅에 적용하는 방법

### 메시지 작성자 상태 조회

`playersWithStatus`를 메시지 렌더링 때마다 반복 탐색하지 않도록 `userId` 기반 맵을 만든다.

```js
const playerVisualStateByUserId = computed(() =>
  Object.fromEntries(
    playersWithStatus.value.map((player) => [
      player.userId,
      {
        memoRole: player.memoRole,
        visibleTeamRole: player.visibleTeamRole,
      },
    ]),
  ),
)
```

### 적용 방식

일반 공개 채팅에서 작성자에게 개인 메모가 있으면 다음 클래스를 추가한다.

```text
memo-mafia
memo-police
memo-doctor
memo-stalker
```

참가자 목록의 기존 메모 팔레트와 동일한 계열을 사용한다.

| 메모 | 채팅 배경 방향 |
| --- | --- |
| 마피아 | 반투명 적색 |
| 경찰 | 반투명 청색 |
| 의사 | 반투명 녹색 |
| 스토커 | 반투명 보라색 |

메모는 개인 추측이므로 채팅 안에 `내 메모: 경찰` 같은 작은 라벨을 표시한다. 다른 사용자에게는 이 라벨과 색상이 보이지 않는다.

### 저장 구조

현재 `localStorage` 구조를 그대로 사용한다. 메모 색상을 서버 메시지 데이터에 저장하거나 Realtime payload에 포함하지 않는다.

---

## 6. 확인된 팀원의 채팅색 적용 방법

### 적용 대상

- 내가 마피아일 때 확인 가능한 마피아 팀원
- 내가 경찰일 때 확인 가능한 경찰 팀원
- 향후 같은 방식으로 공개가 허용된 팀 역할

`visibleTeamMembers` 또는 `playersWithStatus.visibleTeamRole`만 신뢰한다. 메시지 작성자의 실제 역할을 클라이언트가 임의로 조회하거나 메시지 데이터에 포함해서는 안 된다.

### 표현 방식

- 확인된 마피아 팀원의 공개 채팅: 적색 배경과 실선 테두리
- 확인된 경찰 팀원의 공개 채팅: 청색 배경과 실선 테두리
- `확인된 마피아 팀`, `확인된 경찰 팀` 라벨 추가

자기 자신의 팀 색상도 동일하게 적용할 수 있다. 다만 메시지 정렬은 기존처럼 본인 메시지를 오른쪽에 유지한다.

### 보안 원칙

- 팀원 색상 판정은 현재 사용자에게 허용된 `get_visible_team_members` 결과만 사용한다.
- 역할 정보나 계산된 색상 클래스를 `game_messages`에 저장하지 않는다.
- 사망자가 모든 진영 채팅을 읽을 수 있더라도 공개 채팅 작성자의 숨겨진 역할을 새로 노출하지 않는다.

---

## 7. 시각 규칙 우선순위

한 메시지에 여러 조건이 겹칠 수 있으므로 다음 순서로 배경 스타일을 결정한다.

1. **첫날 유언**
2. **전용 채널 색상**: 마피아, 경찰, 사후 채팅
3. **개인 메모 색상**
4. **확인된 팀원 색상**
5. **내 메시지 색상**
6. **일반 메시지 색상**

### 우선순위 이유

- 유언은 게임 이벤트이므로 다른 모든 개인화보다 먼저 보여야 한다.
- 전용 채널은 메시지가 어디에서 작성되었는지 나타내므로 작성자 색상보다 중요하다.
- 개인 메모는 사용자가 직접 지정한 판단이므로 공개 채팅 배경에서 우선 적용한다.
- 메모와 확인된 팀 정보가 충돌하면 메모 배경을 사용하되, `확인된 팀` 라벨은 유지한다. 이를 통해 사용자가 잘못 지정한 메모도 알아차릴 수 있다.

---

## 8. 권장 프론트 구현 구조

`GamePlayView.vue`에 메시지별 시각 정보를 반환하는 함수를 둔다.

```js
function getMessageVisualContext(message) {
  const player = playerVisualStateByUserId.value[message.userId]

  return {
    isFirstDayWill: isFirstDayWillMessage(message),
    memoRole: player?.memoRole || '',
    visibleTeamRole: player?.visibleTeamRole || '',
  }
}
```

템플릿에서는 문자열 조합을 여러 군데 작성하지 않고 전용 함수로 클래스와 라벨을 반환한다.

권장 클래스:

```text
first-day-will-message
memo-mafia / memo-police / memo-doctor / memo-stalker
verified-team-mafia / verified-team-police
has-private-memo
has-verified-team
```

CSS 색상은 참가자 목록과 채팅에서 중복 정의하지 않도록 `GamePlayView.vue` 내부 CSS 변수로 통일한다.

```css
.game-play-view {
  --role-mafia-bg: rgba(127, 29, 29, 0.3);
  --role-mafia-border: rgba(248, 113, 113, 0.64);
  --role-police-bg: rgba(30, 64, 175, 0.28);
  --role-police-border: rgba(96, 165, 250, 0.64);
  --role-doctor-bg: rgba(20, 83, 45, 0.3);
  --role-doctor-border: rgba(74, 222, 128, 0.58);
  --role-stalker-bg: rgba(91, 33, 182, 0.28);
  --role-stalker-border: rgba(167, 139, 250, 0.6);
}
```

---

## 9. 변경 예상 파일

### 필수

- `src/views/GamePlayView.vue`
  - 메시지 시각 상태 계산
  - 유언 전용 마크업
  - 메모·팀원 라벨
  - 우선순위 CSS

### 선택

- `src/api/chatApi.js`
  - `normalizeGameMessage()`에 `isFirstDayWill` 파생 값을 추가할 수 있다.
  - 다만 화면 전용 의미이므로 MVP에서는 `GamePlayView.vue`에서 계산하는 편이 단순하다.

### DB

- MVP에서는 변경 없음
- 향후 유언 외 특수 메시지가 늘어나면 `event_key` 문자열 대신 `message_subtype` 컬럼 도입을 검토한다.

---

## 10. 구현 순서

1. `userId` 기반 플레이어 시각 상태 맵을 추가한다.
2. 유언 식별 함수와 메시지 시각 우선순위 함수를 추가한다.
3. 일반 공개 채팅 템플릿에 유언 전용 마크업을 추가한다.
4. 일반 메시지에 메모·확인된 팀원 클래스와 라벨을 추가한다.
5. 역할 색상을 CSS 변수로 정리하고 참가자 목록과 채팅에 함께 적용한다.
6. 모바일에서 유언 카드와 라벨이 채팅 폭을 넘지 않는지 확인한다.
7. 색각 이상 환경에서도 라벨과 테두리 형태로 의미가 구분되는지 확인한다.

---

## 11. 테스트 항목

### 유언

- 첫날 사망자 유언이 모든 참가자의 공개 채팅에서 유언 카드로 표시된다.
- 유언 작성자가 본인이어도 일반 `mine` 배경색이 유언 디자인을 덮지 않는다.
- 유언 작성자에게 메모가 있어도 유언 디자인이 유지된다.
- 일반 공개 채팅은 유언 디자인으로 잘못 표시되지 않는다.

### 개인 메모

- 참가자에게 메모를 지정하면 기존 메시지와 새 메시지 모두 즉시 같은 색으로 변경된다.
- 메모를 변경하거나 초기화하면 채팅색도 즉시 갱신된다.
- 새로고침 후 같은 게임에서는 저장된 메모 색상이 복구된다.
- 다른 사용자 화면에는 내 메모 색상과 라벨이 보이지 않는다.

### 확인된 팀원

- 마피아는 확인 가능한 마피아 팀원의 공개 채팅만 적색으로 본다.
- 경찰은 확인 가능한 경찰 팀원의 공개 채팅만 청색으로 본다.
- 시민과 다른 역할에게 숨겨진 팀 색상이 노출되지 않는다.
- 팀 전용 채널에서는 기존 채널 색상이 우선 적용된다.

### 충돌

- 확인된 팀원에게 다른 역할 메모를 지정하면 메모 배경과 확인된 팀 라벨이 함께 표시된다.
- 사망, 게임 종료, 재접속 이후에도 허용되지 않은 역할 정보가 새로 노출되지 않는다.

---

## 12. 최종 권장안

유언은 **게임 이벤트 카드**, 메모는 **개인 추측 색상**, 팀원 표시는 **확인된 정보 라벨**로 역할을 분리한다.

배경색만 여러 겹 적용하지 않고 하나의 우선 배경색과 여러 개의 의미 라벨을 조합하면, 현재 채팅 UI를 크게 흔들지 않으면서도 사용자가 차이를 즉시 이해할 수 있다.
