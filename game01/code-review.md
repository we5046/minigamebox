# 프로젝트 코드 리뷰

## 요약

현재 프론트엔드 빌드는 정상적으로 통과하지만, Supabase SQL/RPC 배포 재현성, 권한 정책, 비밀번호 노출, 게임 단계 설정값 반영에서 운영 리스크가 큽니다.

검증 결과:

- `npm run build` 성공
- 로컬 환경에 `psql`이 없어 PostgreSQL SQL 파싱/실행 검증은 수행하지 못함

## 주요 발견 사항

### 1. 필수 RPC 함수가 SQL 파일에 없음

상태: 해결됨

심각도: 높음

프론트엔드는 아래 RPC를 호출합니다.

- `create_room`
- `join_room`
- `leave_room`

관련 위치:

- `src/api/roomApi.js`의 `createRoom`
- `src/api/roomApi.js`의 `joinRoom`
- `src/api/roomApi.js`의 `leaveRoom`

이 항목은 `room-admin.sql`에 `create_room`, `join_room`, `leave_room`을 추가해 해결했습니다. 이제 이 저장소의 SQL 파일만으로도 방 생성, 입장, 퇴장 RPC를 재현할 수 있습니다.

추가로 기존 DB에 남아 있던 레거시 `create_room` 오버로드를 제거하도록 구성했습니다. 프론트엔드와 동일한 14개 인자 함수만 다시 생성하므로 PostgREST의 `PGRST203` 함수 선택 오류를 방지합니다.

`heartbeat_room_presence`, `cleanup_stale_room_players`도 같은 파일에서 재생성합니다. 게임 화면의 만료 단계 재동기화 간격은 3초에서 1초로 줄였습니다.

적용 내용:

- `create_room`: 방 생성, 고유 방 코드 생성, 생성자를 호스트 참가자로 등록
- `join_room`: 대기방 여부, 정원, 비공개방 비밀번호 검증 후 참가자 등록
- `leave_room`: 대기방 퇴장, 빈 방 삭제, 방장 위임, 게임 중 퇴장 시 연결 끊김 처리

남은 보완:

- SQL 파일 적용 순서는 README 또는 별도 배포 문서에 명시하는 것이 좋습니다.

### 2. 비공개 방 비밀번호가 클라이언트로 노출됨

심각도: 높음

`roomSelect`에서 `entry_password`를 조회하고, `normalizeRoom`에서 `entryPassword`로 반환합니다. 이 구조에서는 방 목록/상세 정보를 가져온 클라이언트가 저장된 방 비밀번호를 볼 수 있습니다.

관련 위치:

- `src/api/roomApi.js`의 `roomSelect`
- `src/api/roomApi.js`의 `normalizeRoom`
- `GameRoomView.vue`의 방 수정 폼에서 기존 비밀번호를 재사용하는 흐름

권장 조치:

- `rooms.entry_password`를 클라이언트 조회 대상에서 제거합니다.
- 가능하면 평문 저장 대신 해시 저장 방식으로 변경합니다.
- 비밀번호 변경/검증은 RPC 내부에서만 처리합니다.
- 방장에게도 기존 비밀번호 원문을 보여주지 않고 새 비밀번호 입력 방식으로 처리합니다.

### 3. 정규화된 게임 결과/로그 테이블 권한이 과도함

심각도: 높음

새로 추가된 정규화 테이블에 대해 `authenticated` 전체 `select` 권한이 부여되어 있습니다.

- `game_result_players`
- `game_result_player_logs`

이 테이블에는 게임별 역할, 생존 여부, 승패, 행동 로그가 저장됩니다. RLS 정책 없이 전체 인증 사용자에게 조회 권한을 주면 다른 방의 결과나 로그를 직접 조회할 수 있습니다.

관련 위치:

- `schema-base.sql`
- `game-flow.sql`

권장 조치:

- 두 테이블에 RLS를 활성화합니다.
- 같은 방 참가자만 조회할 수 있도록 정책을 추가합니다.
- 이미 `game_messages`에 적용한 “방 참가자만 조회” 정책 패턴을 재사용할 수 있습니다.

예시 방향:

```sql
alter table public.game_result_players enable row level security;
alter table public.game_result_player_logs enable row level security;

create policy "room participants can read game result players"
  on public.game_result_players for select
  to authenticated
  using (
    exists (
      select 1
      from public.games g
      join public.room_players rp on rp.room_id = g.room_id
      where g.id = game_result_players.game_id
        and rp.user_id = auth.uid()
    )
  );
```

### 4. SQL 파일 간 동일 RPC 중복 정의로 최종 동작이 달라질 수 있음

심각도: 중간

`game-flow.sql`과 `game-read-models.sql`이 일부 함수를 중복 정의합니다.

대표 예:

- `get_current_game`
- `get_game_result`
- `return_room_to_lobby`

`game-flow.sql`의 `get_current_game`은 종료된 게임을 `room.status = 'game_over'`일 때만 반환하도록 되어 있습니다. 반면 `game-read-models.sql`은 `g.status <> 'finished'` 조건을 사용해서 `ended` 상태의 게임도 계속 반환할 수 있습니다.

적용 순서에 따라 최종 DB 함수가 달라지므로, 같은 코드라도 배포 순서에 따라 게임 종료 후 화면 동작이 달라질 수 있습니다.

권장 조치:

- 같은 RPC는 한 파일에서만 정의합니다.
- 읽기 모델 전용 파일이 필요하다면 `game-flow.sql`의 정의를 제거하거나 반대로 최신 정의를 `game-read-models.sql`에만 유지합니다.
- SQL 파일 적용 순서를 README에 명시합니다.

### 5. 방 설정의 시간 값이 게임 진행 중 일부 무시됨

심각도: 중간

`start_game`은 `v_room.night_time_seconds`를 사용합니다. 하지만 이후 자동 진행 함수 `process_due_game_phases`는 단계 시간을 하드코딩합니다.

예:

- 밤: `40`
- 토론: `120`
- 투표: `40`
- 최후의 변론: `30`
- 결과: `8`

사용자가 방 설정에서 `night_time_seconds`, `discussion_time_seconds`, `vote_time_seconds`를 변경해도 시작 이후 자동 진행에서는 일관되게 반영되지 않습니다.

관련 위치:

- `game-flow.sql`의 `start_game`
- `game-cron.sql`의 `process_due_game_phases`

권장 조치:

- `process_due_game_phases`에서 `v_room.night_time_seconds`, `v_room.discussion_time_seconds`, `v_room.vote_time_seconds`를 사용합니다.
- 결과/최후의 변론처럼 별도 컬럼이 없는 값만 상수로 남깁니다.

### 6. 정규화 테이블 참조 순서가 배포 순서에 민감함

심각도: 중간

`start_game`은 `room_role_configs`를 조회합니다. 이 테이블은 `schema-base.sql` 또는 `game-flow.sql` 중간 이후에 생성됩니다.

일반적으로 SQL 파일 전체를 한 번에 적용하면 문제가 작지만, 운영 중 `start_game` 부분만 먼저 적용하거나 파일을 분리 적용하면 `room_role_configs`가 없어 함수 생성/실행이 실패할 수 있습니다.

권장 조치:

- 정규화 DDL은 게임 함수보다 먼저 적용되는 마이그레이션 파일로 분리합니다.
- `role_types`, `room_role_configs`, `game_result_players`, `game_result_player_logs`는 `schema-base.sql`에만 두고, `game-flow.sql`에서는 중복 DDL을 제거하는 편이 좋습니다.

## 추가 관찰

### 1. `rooms.role_config`와 정규화 테이블이 병행됨

현재 구조는 프론트 호환을 위해 `rooms.role_config`를 유지하고 `room_role_configs`를 동기화합니다. 마이그레이션 단계로는 합리적이지만, 장기적으로는 원천 데이터가 둘로 보일 수 있습니다.

권장 조치:

- 단기: `role_config`는 호환용 읽기/쓰기 필드라는 주석을 남깁니다.
- 중기: 프론트 조회/수정을 `room_role_configs` 기반 RPC로 전환합니다.
- 장기: `rooms.role_config`를 제거하거나 읽기 전용 뷰로 대체합니다.

### 2. 승리 조건이 아직 역할 문자열에 직접 의존함

`finish_game` 일부는 `role_types.team_name`을 사용하지만, `check_game_ended`, `game-cron.sql`, `game-read-models.sql`에는 아직 `role = 'mafia'`, `coalesce(role, '') <> 'mafia'` 조건이 남아 있습니다.

권장 조치:

- 승리 조건 계산도 `role_types.team_name` 기준으로 통일합니다.
- 새 역할이 추가될 경우 팀 판정 로직을 한 곳에서만 관리할 수 있습니다.

### 3. 결과 로그 저장 방식이 JSON을 다시 파싱함

`finish_game`은 `v_summary` JSON을 만든 뒤 `jsonb_to_recordset`으로 다시 파싱해 `game_result_players`, `game_result_player_logs`에 넣습니다. 기능상 동작은 가능하지만, 같은 데이터를 두 번 가공합니다.

권장 조치:

- `player_payload`, `log_rows` CTE를 직접 insert에 재사용하는 구조가 더 안정적입니다.
- JSON `summary`는 최종 호환 출력용으로만 생성하는 편이 좋습니다.

## 우선순위 제안

1. 완료: `create_room`, `join_room`, `leave_room` SQL 정의 추가
2. `entry_password` 클라이언트 노출 제거 및 RPC 기반 검증으로 전환
3. `game_result_players`, `game_result_player_logs` RLS 정책 추가
4. 중복 RPC 정의 정리
5. `process_due_game_phases`에서 방 시간 설정값 사용
6. 역할 팀 판정을 `role_types` 기준으로 통일

## 결론

프론트 빌드는 통과하지만, 현재 가장 큰 위험은 UI 코드보다 DB 계층에 있습니다. 특히 RPC 누락, 비밀번호 노출, RLS 부재는 운영 전에 먼저 정리하는 것이 좋습니다. 정규화 작업 자체는 방향이 맞지만, 마이그레이션 파일 분리와 권한 정책까지 같이 마무리해야 안정적인 구조가 됩니다.
