docs/liar-game-spec.md 문서를 수정해줘.

이번 수정의 핵심은 라이어 게임의 진행 흐름에 “순서별 한마디 설명 단계”를 추가하는 것이다.

중요:

- 기존 코드는 수정하지 않는다.
- docs/liar-game-spec.md 문서만 수정한다.
- 기존 목표 점수 기반 다중 라운드 매치 구조는 유지한다.
- 기존 classic/custom 설정 구조, 테마 선택, 투표/재투표, 투표 공개 규칙은 유지한다.
- 이번 작업은 구현이 아니라 기획/설계 문서 보완이다.

---

# 1. 핵심 변경 사항

현재 게임은 모두가 자유롭게 채팅 가능한 구조를 전제로 하고 있지만,
라이어 게임의 재미를 위해 토론 전에 “순서별 한마디 설명 단계”를 추가한다.

새로운 라운드 흐름은 다음과 같다.

1. word_reveal
   - 각 유저가 자신의 역할/제시어를 확인한다.

2. statement
   - 시스템이 참가자 순서를 정한다.
   - 각 참가자는 자신의 차례에 주제와 관련된 한마디 설명을 작성한다.
   - 각 참가자에게는 짧은 제한 시간이 주어진다.
   - 제한 시간 안에 작성하지 않으면 “답변 없음”으로 자동 기록한다.
   - 모든 참가자의 한마디 설명이 끝날 때까지 자유 토론 채팅은 제한한다.

3. discussion
   - 모든 참가자의 한마디 설명이 끝난 뒤 자유 토론이 열린다.
   - 이때부터 모든 참가자가 채팅으로 토론할 수 있다.

4. voting
   - 라이어라고 생각하는 사람에게 투표한다.

5. revote
   - 투표 동률 발생 시 재투표한다.

6. liar_guess
   - 실제 라이어가 지목된 경우 라이어가 최종 제시어를 추측한다.

7. round_result
   - 라운드 결과와 점수 변화를 보여준다.

8. match_result
   - 목표 점수 도달 시 최종 우승자를 보여준다.

---

# 2. round phase 수정

기존 round phase 목록에 statement를 추가한다.

최종 round phase는 다음과 같이 정리한다.

- word_reveal
- statement
- discussion
- voting
- revote
- liar_guess
- round_result
- match_result

각 phase 의미:

- word_reveal: 각 유저가 자신의 역할/제시어 확인
- statement: 참가자들이 정해진 순서대로 한마디 설명 작성
- discussion: 모든 한마디 설명 공개 후 자유 토론
- voting: 1차 투표
- revote: 동률 발생 시 재투표
- liar_guess: 라이어 최종 제시어 추측
- round_result: 라운드 결과 및 점수 변화 표시
- match_result: 최종 우승자 표시

---

# 3. statement phase 규칙

statement phase는 토론 전에 반드시 진행되는 단계다.

규칙:

- 라운드 시작 시 시스템이 참가자 발언 순서를 정한다.
- 순서는 라운드마다 새로 정할 수 있다.
- MVP에서는 참가자 입장 순서 또는 랜덤 순서 중 하나를 사용할 수 있다.
- 추천은 랜덤 순서다.
- 현재 발언자의 차례가 되면 해당 유저만 한마디 설명을 작성할 수 있다.
- 다른 유저들은 해당 시간 동안 일반 채팅을 작성할 수 없다.
- 각 유저는 자신의 차례에 한 번만 한마디 설명을 제출할 수 있다.
- 한마디 설명은 너무 길지 않도록 길이 제한을 둔다.
- 추천 제한: 100자 이하
- 각 유저에게 짧은 제한 시간을 부여한다.
- 추천 제한 시간: 15초 또는 20초
- 제한 시간 내에 제출하지 않으면 시스템이 자동으로 “답변 없음”을 기록한다.
- 모든 참가자가 한마디 설명을 완료하거나 “답변 없음” 처리되면 discussion phase로 넘어간다.

---

# 4. 한마디 설명 작성 규칙

한마디 설명은 일반 채팅과 분리해서 관리한다.

한마디 설명의 목적:

- 일반 유저는 제시어를 직접 말하지 않으면서 특징을 설명한다.
- 라이어는 다른 사람의 설명을 보고 제시어를 추리하면서 자연스럽게 섞인다.
- 토론 전에 모든 유저가 최소 한 번씩 의심 단서를 남기도록 한다.

작성 예시:

- 제시어: 김치찌개
- 유저 A: “한국 사람들이 자주 먹는 음식이에요.”
- 유저 B: “밥이랑 같이 먹으면 좋아요.”
- 유저 C: “빨간색 느낌이 강해요.”
- 라이어: “집에서 자주 볼 수 있는 것 같아요.”

금지/주의:

- MVP에서는 제시어 직접 언급을 시스템이 자동으로 막지 않아도 된다.
- 단, 문서에는 “제시어를 직접 말하면 재미가 떨어지므로 직접 언급하지 않는 것이 권장된다”고 작성한다.
- 추후 확장으로 제시어 직접 언급 감지 기능을 추가할 수 있다.

---

# 5. 채팅 제한 규칙

statement phase에서는 일반 자유 채팅을 제한한다.

규칙:

- word_reveal phase에서는 자유 채팅을 제한하거나 시스템 안내만 허용할 수 있다.
- statement phase에서는 현재 발언자만 한마디 설명을 제출할 수 있다.
- statement phase 동안 일반 채팅 입력창은 비활성화한다.
- 다른 참가자들은 현재 발언자의 차례와 남은 시간을 볼 수 있다.
- 모든 참가자의 한마디 설명이 완료되기 전까지 discussion phase로 넘어가지 않는다.
- discussion phase부터 일반 자유 채팅이 가능하다.

화면 안내 예시:

- “현재 박성훈님의 설명 차례입니다.”
- “남은 시간: 15초”
- “다른 참가자는 설명이 끝날 때까지 기다려주세요.”
- “모든 설명이 끝나면 자유 토론이 시작됩니다.”

---

# 6. 답변 없음 처리

제한 시간 안에 한마디 설명을 제출하지 않으면 자동으로 “답변 없음”을 기록한다.

규칙:

- 제한 시간이 끝났는데 제출된 statement가 없으면 시스템이 해당 유저의 statement_text를 “답변 없음”으로 저장한다.
- 이 상태도 발언 완료로 처리한다.
- 이후 다음 유저 차례로 넘어간다.
- “답변 없음”도 한마디 설명 목록에 표시한다.
- 토론 단계에서 다른 유저들이 “답변 없음”을 의심 근거로 사용할 수 있다.

예시:

- 박성훈: “밥이랑 같이 먹는 경우가 많아요.”
- 김철수: “답변 없음”
- 이영희: “뜨겁게 먹는 경우가 많아요.”

---

# 7. 한마디 설명 공개/정리 화면

모든 유저의 한마디 설명은 별도 영역에 정리해서 보여준다.

표시 위치:

- 게임 진행 화면의 사이드 패널
- 또는 채팅창 위/옆의 “한마디 설명 목록” 영역

표시 예시:

한마디 설명 목록

1. 박성훈
   - “밥이랑 같이 먹는 경우가 많아요.”

2. 김철수
   - “답변 없음”

3. 이영희
   - “뜨겁게 먹는 경우가 많아요.”

4. 최민수
   - “빨간색이 떠올라요.”

규칙:

- statement phase 중에는 완료된 사람의 한마디 설명을 즉시 공개할지, 모든 사람이 끝난 뒤 한 번에 공개할지 선택할 수 있다.
- MVP 추천은 “제출 즉시 공개”다.
- 이유: 실시간 진행감이 생기고, 뒤 차례 유저가 앞선 설명을 보고 라이어처럼 자연스럽게 따라갈 수 있기 때문이다.
- 다만 이로 인해 뒤 순서 유저가 유리해질 수 있으므로, 추후 확장으로 “모든 설명 완료 후 일괄 공개 모드”를 추가할 수 있다.

---

# 8. 시스템 메시지 규칙

한마디 설명 단계에서도 시스템 메시지를 사용할 수 있다.

예시:

- [시스템] 한마디 설명 단계가 시작되었습니다.
- [시스템] 박성훈님의 설명 차례입니다.
- [시스템] 박성훈님이 설명을 완료했습니다.
- [시스템] 김철수님이 시간 내에 답변하지 않아 “답변 없음”으로 처리되었습니다.
- [시스템] 모든 참가자의 설명이 완료되었습니다. 자유 토론을 시작합니다.

시스템 메시지는 일반 채팅과 구분한다.

추천 구분값:

- chat_type = system
- system_event_type = liar_statement_phase_started
- system_event_type = liar_statement_turn_started
- system_event_type = liar_statement_submitted
- system_event_type = liar_statement_timeout
- system_event_type = liar_discussion_started

---

# 9. DB 설계 보완

statement phase를 지원하기 위해 DB 설계 초안에 한마디 설명 저장 구조를 추가한다.

새 테이블 또는 구조 예시:

## liar_statements

필드 예시:

- id
- game_id
- round_id
- user_id
- turn_order
- statement_text
- is_submitted
- is_timeout
- submitted_at
- created_at

설명:

- turn_order: 해당 라운드에서의 발언 순서
- statement_text: 유저가 작성한 한마디 설명. 시간 초과 시 “답변 없음”
- is_submitted: 유저가 직접 제출했는지 여부
- is_timeout: 시간 초과로 자동 처리되었는지 여부
- submitted_at: 실제 제출 또는 자동 처리 시각

제약 조건:

- round_id, user_id 기준으로 한 유저는 한 라운드에 하나의 statement만 가질 수 있다.
- turn_order는 같은 round_id 안에서 중복되면 안 된다.
- statement_text는 100자 이하를 권장한다.

---

# 10. liar_rounds 보완

liar_rounds 또는 라운드 상태 테이블에 statement 진행 상태를 관리할 필드를 둘 수 있다.

추가 고려 필드:

- current_statement_user_id
- current_statement_turn_order
- statement_time_limit_seconds
- statement_turn_started_at
- statement_completed_count

설명:

- current_statement_user_id: 현재 한마디 설명 차례인 유저
- current_statement_turn_order: 현재 몇 번째 순서인지
- statement_time_limit_seconds: 각 유저에게 주어지는 제한 시간
- statement_turn_started_at: 현재 차례가 시작된 시간
- statement_completed_count: 완료된 설명 수

MVP에서는 이 필드를 모두 테이블에 두지 않고 RPC에서 계산해도 된다.
단, 실시간 동기화와 새로고침 복구를 고려하면 DB에 저장하는 방식을 권장한다.

---

# 11. RPC 설계 보완

문서의 RPC 설계 초안에 아래 함수를 추가하거나 기존 함수에 반영한다.

필요 RPC 예시:

- start_liar_statement_phase
- submit_liar_statement
- timeout_liar_statement
- advance_liar_statement_turn
- get_liar_statements

## start_liar_statement_phase

역할:

- 라운드 참가자들의 발언 순서를 생성한다.
- liar_statements 초기 데이터를 생성한다.
- 첫 번째 발언자를 current_statement_user_id로 설정한다.
- phase를 statement로 변경한다.

처리:

- 라운드 참가자 목록 조회
- 발언 순서 결정
- 각 참가자별 liar_statements row 생성
- 첫 번째 발언자 지정
- statement_turn_started_at 저장

## submit_liar_statement

역할:

- 현재 발언자가 제한 시간 안에 한마디 설명을 제출한다.

검증:

- 현재 phase가 statement인지 확인
- 요청자가 current_statement_user_id인지 확인
- 이미 제출했는지 확인
- statement_text 길이 제한 확인
- 공백만 입력한 경우 “답변 없음” 또는 제출 불가 처리 중 하나 선택
- MVP 추천: 공백만 입력하면 제출 불가
- 제한 시간이 지났다면 timeout 처리로 넘김

처리:

- statement_text 저장
- is_submitted = true
- is_timeout = false
- submitted_at 저장
- 다음 발언자로 이동
- 모든 참가자 완료 시 phase를 discussion으로 변경

## timeout_liar_statement

역할:

- 현재 발언자가 제한 시간 내 제출하지 않았을 때 “답변 없음”으로 처리한다.

처리:

- statement_text = “답변 없음”
- is_submitted = false
- is_timeout = true
- submitted_at 또는 timeout_at 저장
- 다음 발언자로 이동
- 모든 참가자 완료 시 phase를 discussion으로 변경

## advance_liar_statement_turn

역할:

- 다음 발언자로 차례를 넘긴다.
- 마지막 참가자까지 완료되면 discussion phase로 전환한다.

## get_liar_statements

역할:

- 현재 라운드의 한마디 설명 목록을 순서대로 조회한다.

반환 예시:
[
{
"turn_order": 1,
"user_id": "user-1",
"nickname": "박성훈",
"statement_text": "밥이랑 같이 먹는 경우가 많아요.",
"is_submitted": true,
"is_timeout": false
},
{
"turn_order": 2,
"user_id": "user-2",
"nickname": "김철수",
"statement_text": "답변 없음",
"is_submitted": false,
"is_timeout": true
}
]

---

# 12. 화면 구성 보완

게임 진행 화면에 statement phase 관련 UI를 추가한다.

## statement phase 화면

필수 표시:

- 현재 phase: 한마디 설명
- 현재 발언자
- 남은 시간
- 내 차례 여부
- 한마디 입력창
- 제출 버튼
- 한마디 설명 목록 패널
- 채팅창 비활성화 상태 안내

내 차례일 때:

- 한마디 입력창 활성화
- 제출 버튼 활성화
- 남은 시간 표시

내 차례가 아닐 때:

- 입력창 비활성화
- “현재 ○○님의 설명 차례입니다.” 표시
- “다른 참가자는 설명이 끝날 때까지 기다려주세요.” 표시

시간 초과 시:

- 해당 유저의 설명에 “답변 없음” 표시
- 다음 유저 차례로 이동

## discussion phase 화면

discussion phase부터 일반 채팅을 활성화한다.

추가 표시:

- 한마디 설명 목록 패널은 계속 유지한다.
- 유저들은 토론 중에도 이전 한마디 설명들을 확인할 수 있다.
- “답변 없음”도 그대로 표시한다.

---

# 13. MVP 범위 수정

MVP에 포함:

- statement phase 추가
- 라운드마다 발언 순서 생성
- 현재 발언자만 한마디 설명 작성 가능
- 각 유저별 짧은 제한 시간
- 시간 초과 시 “답변 없음” 자동 기록
- 모든 유저의 한마디 설명 완료 후 discussion phase 진입
- statement phase 동안 일반 자유 채팅 제한
- discussion phase부터 자유 채팅 가능
- 한마디 설명 목록 패널 제공
- 한마디 설명은 제출 즉시 공개
- 한마디 설명은 라운드 결과 전까지 계속 확인 가능

MVP에서 제외하고 추후 확장:

- 모든 한마디 설명 완료 후 일괄 공개 모드
- 제시어 직접 언급 자동 감지
- 발언 순서 수동 설정
- 발언 시간 커스텀 설정
- 라이어에게 다른 유사 제시어 제공
- 음성/녹음 기반 설명
- 답변 없음 패널티 점수
- 한마디 설명 좋아요/의심 표시 기능

---

# 14. 기존 흐름 수정

문서 전체에서 discussion phase가 word_reveal 직후 바로 시작되는 것처럼 작성된 부분이 있다면 수정한다.

기존 흐름:
word_reveal → discussion → voting

수정 흐름:
word_reveal → statement → discussion → voting

설명:

- word_reveal 이후 바로 자유 토론으로 넘어가지 않는다.
- 반드시 모든 참가자의 한마디 설명 단계를 거친 뒤 discussion phase로 넘어간다.
- 이 구조는 모든 참가자가 최소 한 번씩 단서를 남기게 만들어 라이어 게임의 추리 재미를 강화한다.

---

결과물:

- docs/liar-game-spec.md 문서를 갱신한다.
- 기존 코드는 수정하지 않는다.
- 문서 수정 후 변경 요약을 알려준다.
