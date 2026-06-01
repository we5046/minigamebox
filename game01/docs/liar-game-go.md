# 라이어 게임 구현 진행 문서

## 0. 목적

이 문서는 `docs/liar-game-spec.md`를 실제 프로젝트에 적용하는 순서와 현재 진행 상태를 기록한다.

작성 기준일: 2026-06-02

## 1. 현재 상태

| 영역 | 상태 | 결과물 |
| --- | --- | --- |
| 프로젝트 구조 분석 | 완료 | `docs/liar-game-analysis.md` |
| 최신 기획 기준 정리 | 완료 | `docs/liar-game-spec.md` |
| 라이어 DB와 RPC 초안 | 완료 | `liar-game.sql` |
| 로비 라이어 방 생성 | 완료 | `src/views/HomeView.vue`, `src/api/roomApi.js` |
| 라이어 전용 API | 완료 | `src/api/liarGameApi.js` |
| 게임 타입별 라우팅 | 완료 | `src/views/GameRoomRouteView.vue`, `src/views/GamePlayRouteView.vue` |
| 라이어 대기방 | 완료 | `src/views/LiarGameRoomView.vue` |
| 라이어 플레이 화면 | 완료 | `src/views/LiarGamePlayView.vue` |
| 프론트 프로덕션 빌드 | 완료 | `npm run build` 통과 |
| 라이브 Supabase SQL 적용 | 미실행 | Supabase SQL Editor 또는 배포 파이프라인에서 적용 필요 |
| 다중 브라우저 시나리오 테스트 | 미실행 | SQL 적용 후 진행 |

## 2. 구현 기준

현재 구현은 다음 규칙을 따른다.

- 3명 이상부터 시작
- 목표 점수 기반 다중 라운드
- 매 라운드 라이어와 제시어 무작위 재선정
- 클래식: 목표 5점, 시민 +1점, 라이어 +2점
- 커스텀: 테마, 목표 점수, 시민 점수, 라이어 점수 선택
- 자기 투표 불가
- 투표 후 변경 불가
- 1차 동률이면 공동 최다 득표 후보만 대상으로 재투표
- 재투표도 동률이면 라운드 무효, 점수 지급 없음
- 실제 라이어가 지목되면 한 번의 제시어 추측
- MVP 단계 진행은 방장이 수동으로 처리

## 3. SQL 적용 순서

현재 저장소는 전체 기준 스키마를 포함하지 않는다. 신규 프로젝트가 아니라 기존 Supabase 프로젝트에 적용하는 기준이다.

1. 기존 기준 스키마와 `room-admin.sql`이 적용되어 있는지 확인한다.
2. `password-room-fix.sql`을 적용한다.
3. 필요하면 `stalker-role-fix.sql`과 `mypage-game-records-fix.sql`을 적용한다.
4. `liar-game.sql`을 적용한다.
5. PostgREST 스키마 reload가 끝난 뒤 프론트를 새로고침한다.

Supabase Dashboard의 SQL Editor에서는 파일 하나씩 새 쿼리로 열어 전체 내용을 실행한다. 각 파일은 트랜잭션으로 감싸져 있으므로 오류가 발생하면 먼저 선행 스키마를 보완하고 해당 파일 전체를 다시 실행한다.

`liar-game.sql`은 최초 배포용 스크립트다. 현재 버전은 테이블 생성, 함수 교체, 정책 재생성, 시드 upsert를 포함하므로 같은 버전을 다시 실행할 수 있다. 라이브 배포 이후 테이블 컬럼이나 제약 조건을 바꿀 때는 기존 파일을 덮어쓰는 대신 `liar-game-v2-fix.sql`처럼 별도 증분 패치 파일을 추가한다.

`liar-game.sql`은 다음 작업을 수행한다.

- 공개 테마와 비공개 제시어 시드 생성
- 라이어 방 설정, 매치, 참가자, 점수, 라운드, 투표 테이블 생성
- 비공개 라운드 비밀과 추측 테이블 생성
- 공개 테이블 RLS와 최소 권한 `GRANT`
- Realtime publication 등록
- 라이어 전용 RPC 생성
- 토론 단계 외 라이어 게임 채팅 저장 차단 트리거 생성

### 3.1 적용 후 확인 쿼리

```sql
select
  to_regclass('public.liar_categories') as liar_categories,
  to_regclass('public.liar_room_settings') as liar_room_settings,
  to_regclass('public.liar_match_states') as liar_match_states,
  to_regclass('public.liar_rounds') as liar_rounds,
  to_regclass('private.liar_words') as liar_words;

select routine_name
from information_schema.routines
where routine_schema = 'public'
  and routine_name like '%liar%'
order by routine_name;

select schemaname, tablename
from pg_publication_tables
where pubname = 'supabase_realtime'
  and tablename in (
    'liar_match_states',
    'liar_scores',
    'liar_rounds',
    'liar_votes'
  )
order by tablename;

select category_key, label, is_active
from public.liar_categories
order by category_key;
```

## 4. 수동 검증 시나리오

### 4.1 방 생성

1. 라이어 게임 카드를 선택한다.
2. 클래식 방을 생성한다.
3. 테마 선택이 가능하고 점수 규칙은 고정인지 확인한다.
4. 커스텀 방을 생성한다.
5. 목표 점수와 진영별 점수가 저장되는지 확인한다.
6. 공개방과 비공개방 입장을 각각 확인한다.

### 4.2 매치 시작

1. 2명 이하에서 시작이 거부되는지 확인한다.
2. 3명 이상에서도 미준비 참가자가 있으면 거부되는지 확인한다.
3. 전원 준비 후 시작하면 모든 참가자가 플레이 화면으로 이동하는지 확인한다.
4. 일반 유저는 같은 제시어를 보고 라이어는 제시어를 보지 못하는지 확인한다.

### 4.3 토론과 투표

1. `discussion` 단계에서만 게임 채팅을 저장할 수 있는지 확인한다.
2. `voting` 단계에서 누가 누구에게 투표했는지 즉시 공개되는지 확인한다.
3. 같은 투표 단계에서 두 번 제출하면 거부되는지 확인한다.
4. 자기 자신에게 투표하면 거부되는지 확인한다.
5. 동률이면 `revote`로 이동하고 공동 최다 득표 후보만 선택 가능한지 확인한다.
6. 재투표도 동률이면 `invalid` 결과와 점수 미지급을 확인한다.

### 4.4 추측과 종료

1. 실제 라이어가 지목되면 `liar_guess`로 이동하는지 확인한다.
2. 일반 유저의 추측 제출은 거부되는지 확인한다.
3. 정답이면 라이어 점수, 오답이면 시민 점수가 반영되는지 확인한다.
4. 목표 점수 미도달 시 다음 라운드에서 라이어와 제시어를 다시 선정하는지 확인한다.
5. 목표 점수 도달 시 최종 우승자와 공동 우승을 올바르게 표시하는지 확인한다.
6. 대기방 복귀 후 준비 상태가 초기화되는지 확인한다.

### 4.5 보안

브라우저 개발자 도구와 Data API를 사용해 다음을 확인한다.

1. `public.liar_rounds` Realtime payload에 실제 라이어 ID와 제시어가 없는지 확인한다.
2. 라이어가 `private.liar_words`를 직접 조회할 수 없는지 확인한다.
3. 일반 유저가 `private.liar_round_secrets`를 직접 조회할 수 없는지 확인한다.
4. `public.liar_votes`는 조회만 가능하고 직접 INSERT는 거부되는지 확인한다.
5. 토론 단계 외 `game_messages` 직접 INSERT가 거부되는지 확인한다.

## 5. 후속 작업

라이브 DB 적용과 다중 브라우저 테스트가 끝난 뒤 다음 순서로 확장한다.

1. 자동 타이머와 Cron 기반 단계 진행
2. 연결 해제 참가자 처리 정책
3. 대기방 친구 초대 기능을 라이어 전용 대기방에 연결
4. 라운드별 기록과 마이페이지 전적 표시 개선
5. 경험치와 코인 보상 정책
6. 운영자 제시어 관리 화면
