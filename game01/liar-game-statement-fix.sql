-- Add the required turn-based statement phase before liar-game discussion.
-- Apply after liar-game.sql. This patch is safe to rerun.

begin;

alter table public.liar_rounds
  drop constraint if exists liar_rounds_phase_check;

alter table public.liar_rounds
  add constraint liar_rounds_phase_check
  check (
    phase in (
      'word_reveal',
      'statement',
      'discussion',
      'voting',
      'revote',
      'liar_guess',
      'round_result',
      'match_result'
    )
  );

alter table public.liar_rounds
  add column if not exists current_statement_user_id uuid,
  add column if not exists current_statement_turn_order integer,
  add column if not exists statement_time_limit_seconds integer not null default 20,
  add column if not exists statement_turn_started_at timestamptz,
  add column if not exists statement_completed_count integer not null default 0;

create table if not exists public.liar_statements (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references public.games(id) on delete cascade,
  round_id uuid not null references public.liar_rounds(id) on delete cascade,
  user_id uuid not null,
  turn_order integer not null check (turn_order > 0),
  statement_text text,
  is_submitted boolean not null default false,
  is_timeout boolean not null default false,
  submitted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (round_id, user_id),
  unique (round_id, turn_order),
  check (statement_text is null or char_length(statement_text) <= 100),
  foreign key (game_id, user_id)
    references public.liar_match_players(game_id, user_id)
    on delete cascade
);

create index if not exists liar_statements_round_order_idx
  on public.liar_statements(round_id, turn_order);

create or replace function private.get_liar_statements_payload(p_round_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', statement.id,
        'userId', statement.user_id,
        'nickname', coalesce(profile.nickname, '알 수 없음'),
        'turnOrder', statement.turn_order,
        'statementText', statement.statement_text,
        'isSubmitted', statement.is_submitted,
        'isTimeout', statement.is_timeout,
        'submittedAt', statement.submitted_at
      )
      order by statement.turn_order
    ),
    '[]'::jsonb
  )
  from public.liar_statements statement
  left join public.profiles profile on profile.id = statement.user_id
  where statement.round_id = p_round_id;
$$;

create or replace function private.get_liar_statements(p_room_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_game_id uuid;
  v_round_id uuid;
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;

  v_game_id := private.get_liar_game_id_for_room(p_room_id);

  if v_game_id is null or not private.is_liar_match_player(v_game_id, v_user_id) then
    raise exception 'Liar match participant required';
  end if;

  select round.id
  into v_round_id
  from public.liar_rounds round
  where round.game_id = v_game_id
  order by round.round_no desc
  limit 1;

  return private.get_liar_statements_payload(v_round_id);
end;
$$;

create or replace function private.advance_liar_statement_turn(p_round_id uuid)
returns public.liar_rounds
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_round public.liar_rounds;
  v_room_id uuid;
  v_next_statement public.liar_statements;
  v_next_nickname text;
  v_completed_count integer;
begin
  select *
  into v_round
  from public.liar_rounds
  where id = p_round_id
  for update;

  if not found or v_round.phase <> 'statement' then
    raise exception 'Liar statement phase required';
  end if;

  select count(*)
  into v_completed_count
  from public.liar_statements
  where round_id = p_round_id
    and submitted_at is not null;

  select statement.*
  into v_next_statement
  from public.liar_statements statement
  where statement.round_id = p_round_id
    and statement.submitted_at is null
  order by statement.turn_order
  limit 1;

  select game.room_id
  into v_room_id
  from public.games game
  where game.id = v_round.game_id;

  if not found then
    raise exception 'Liar match not found';
  end if;

  if v_next_statement.id is null then
    update public.liar_rounds
    set
      phase = 'discussion',
      phase_started_at = now(),
      phase_ends_at = null,
      current_statement_user_id = null,
      current_statement_turn_order = null,
      statement_turn_started_at = null,
      statement_completed_count = v_completed_count,
      updated_at = now()
    where id = p_round_id
    returning * into v_round;

    perform private.insert_liar_system_message(
      v_room_id,
      v_round.game_id,
      v_round.round_no,
      '모든 참가자의 설명이 완료되었습니다. 자유 토론을 시작합니다.',
      format('liar_discussion_start:%s', v_round.round_no)
    );

    return v_round;
  end if;

  select coalesce(profile.nickname, '알 수 없음')
  into v_next_nickname
  from public.profiles profile
  where profile.id = v_next_statement.user_id;

  update public.liar_rounds
  set
    current_statement_user_id = v_next_statement.user_id,
    current_statement_turn_order = v_next_statement.turn_order,
    statement_turn_started_at = now(),
    phase_ends_at = now() + make_interval(secs => statement_time_limit_seconds),
    statement_completed_count = v_completed_count,
    updated_at = now()
  where id = p_round_id
  returning * into v_round;

  perform private.insert_liar_system_message(
    v_room_id,
    v_round.game_id,
    v_round.round_no,
    format('%s님의 설명 차례입니다.', coalesce(v_next_nickname, '알 수 없음')),
    format('liar_statement_turn:%s:%s', v_round.round_no, v_next_statement.turn_order)
  );

  return v_round;
end;
$$;

create or replace function private.start_liar_statement_phase(p_round_id uuid)
returns public.liar_rounds
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_round public.liar_rounds;
  v_room_id uuid;
begin
  select *
  into v_round
  from public.liar_rounds
  where id = p_round_id
  for update;

  if not found or v_round.phase <> 'word_reveal' then
    raise exception 'Liar word reveal phase required';
  end if;

  select game.room_id
  into v_room_id
  from public.games game
  where game.id = v_round.game_id;

  insert into public.liar_statements (
    game_id,
    round_id,
    user_id,
    turn_order
  )
  select
    player.game_id,
    p_round_id,
    player.user_id,
    row_number() over (order by random())::integer
  from public.liar_match_players player
  where player.game_id = v_round.game_id
  on conflict (round_id, user_id) do nothing;

  update public.liar_rounds
  set
    phase = 'statement',
    phase_started_at = now(),
    statement_completed_count = 0,
    updated_at = now()
  where id = p_round_id;

  perform private.insert_liar_system_message(
    v_room_id,
    v_round.game_id,
    v_round.round_no,
    '한마디 설명 단계가 시작되었습니다.',
    format('liar_statement_start:%s', v_round.round_no)
  );

  return private.advance_liar_statement_turn(p_round_id);
end;
$$;

create or replace function private.timeout_liar_statement(p_room_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_game_id uuid;
  v_round public.liar_rounds;
  v_statement public.liar_statements;
  v_nickname text;
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;

  v_game_id := private.get_liar_game_id_for_room(p_room_id);

  if v_game_id is null or not private.is_liar_match_player(v_game_id, v_user_id) then
    raise exception 'Liar match participant required';
  end if;

  select *
  into v_round
  from public.liar_rounds
  where game_id = v_game_id
  order by round_no desc
  limit 1
  for update;

  if not found or v_round.phase <> 'statement' then
    return private.build_current_liar_match(p_room_id);
  end if;

  if v_round.phase_ends_at is null or v_round.phase_ends_at > now() then
    return private.build_current_liar_match(p_room_id);
  end if;

  update public.liar_statements
  set
    statement_text = '답변 없음',
    is_submitted = false,
    is_timeout = true,
    submitted_at = now(),
    updated_at = now()
  where round_id = v_round.id
    and user_id = v_round.current_statement_user_id
    and submitted_at is null
  returning * into v_statement;

  if v_statement.id is null then
    return private.build_current_liar_match(p_room_id);
  end if;

  select coalesce(profile.nickname, '알 수 없음')
  into v_nickname
  from public.profiles profile
  where profile.id = v_statement.user_id;

  perform private.insert_liar_system_message(
    p_room_id,
    v_game_id,
    v_round.round_no,
    format('%s님이 시간 내에 답변하지 않아 "답변 없음"으로 처리되었습니다.', coalesce(v_nickname, '알 수 없음')),
    format('liar_statement_timeout:%s:%s', v_round.round_no, v_statement.turn_order)
  );

  perform private.advance_liar_statement_turn(v_round.id);

  return private.build_current_liar_match(p_room_id);
end;
$$;

create or replace function private.submit_liar_statement(
  p_room_id uuid,
  p_statement_text text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_game_id uuid;
  v_round public.liar_rounds;
  v_statement_text text := trim(coalesce(p_statement_text, ''));
  v_statement public.liar_statements;
  v_nickname text;
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;

  if v_statement_text = '' then
    raise exception 'Liar statement text required';
  end if;

  if char_length(v_statement_text) > 100 then
    raise exception 'Liar statement too long';
  end if;

  v_game_id := private.get_liar_game_id_for_room(p_room_id);

  if v_game_id is null or not private.is_liar_match_player(v_game_id, v_user_id) then
    raise exception 'Liar match participant required';
  end if;

  select *
  into v_round
  from public.liar_rounds
  where game_id = v_game_id
  order by round_no desc
  limit 1
  for update;

  if not found or v_round.phase <> 'statement' then
    raise exception 'Liar statement phase required';
  end if;

  if v_round.phase_ends_at <= now() then
    return private.timeout_liar_statement(p_room_id);
  end if;

  if v_round.current_statement_user_id <> v_user_id then
    raise exception 'Current liar statement player only';
  end if;

  update public.liar_statements
  set
    statement_text = v_statement_text,
    is_submitted = true,
    is_timeout = false,
    submitted_at = now(),
    updated_at = now()
  where round_id = v_round.id
    and user_id = v_user_id
    and submitted_at is null
  returning * into v_statement;

  if v_statement.id is null then
    raise exception 'Liar statement already submitted';
  end if;

  select coalesce(profile.nickname, '알 수 없음')
  into v_nickname
  from public.profiles profile
  where profile.id = v_user_id;

  perform private.insert_liar_system_message(
    p_room_id,
    v_game_id,
    v_round.round_no,
    format('%s님이 설명을 완료했습니다.', coalesce(v_nickname, '알 수 없음')),
    format('liar_statement_submitted:%s:%s', v_round.round_no, v_statement.turn_order)
  );

  perform private.advance_liar_statement_turn(v_round.id);

  return private.build_current_liar_match(p_room_id);
end;
$$;

create or replace function private.build_current_liar_match(p_room_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_state public.liar_match_states;
  v_game public.games;
  v_round public.liar_rounds;
  v_category_label text;
  v_statement_nickname text;
begin
  select state.*
  into v_state
  from public.liar_match_states state
  where state.room_id = p_room_id
  order by state.created_at desc
  limit 1;

  if not found then
    return null;
  end if;

  select *
  into v_game
  from public.games
  where id = v_state.game_id;

  if not found then
    return null;
  end if;

  if not private.is_liar_match_player(v_state.game_id, v_user_id) then
    raise exception 'Liar match participant required';
  end if;

  select *
  into v_round
  from public.liar_rounds
  where game_id = v_state.game_id
  order by round_no desc
  limit 1;

  select label
  into v_category_label
  from public.liar_categories
  where id = v_round.category_id;

  select coalesce(profile.nickname, '알 수 없음')
  into v_statement_nickname
  from public.profiles profile
  where profile.id = v_round.current_statement_user_id;

  return jsonb_build_object(
    'gameId', v_state.game_id,
    'roomId', v_state.room_id,
    'gameStatus', v_game.status,
    'matchStatus', v_state.status,
    'settingMode', v_state.setting_mode,
    'categoryId', v_state.category_id,
    'targetScore', v_state.target_score,
    'citizenWinScore', v_state.citizen_win_score,
    'liarWinScore', v_state.liar_win_score,
    'currentRoundNo', v_state.current_round_no,
    'winnerUserIds', to_jsonb(v_state.winner_user_ids),
    'scoreboard', private.get_liar_scoreboard_payload(v_state.game_id),
    'round', case
      when v_round.id is null then null
      else jsonb_build_object(
        'id', v_round.id,
        'roundNo', v_round.round_no,
        'categoryId', v_round.category_id,
        'categoryLabel', v_category_label,
        'phase', v_round.phase,
        'phaseStartedAt', v_round.phase_started_at,
        'phaseEndsAt', v_round.phase_ends_at,
        'votedUserId', v_round.voted_user_id,
        'winnerSide', v_round.round_winner_side,
        'endReason', v_round.end_reason,
        'voteAttemptNo', v_round.vote_attempt_no,
        'currentStatementUserId', v_round.current_statement_user_id,
        'currentStatementNickname', v_statement_nickname,
        'currentStatementTurnOrder', v_round.current_statement_turn_order,
        'statementTimeLimitSeconds', v_round.statement_time_limit_seconds,
        'statementTurnStartedAt', v_round.statement_turn_started_at,
        'statementCompletedCount', v_round.statement_completed_count
      )
    end,
    'statements', case
      when v_round.id is null then '[]'::jsonb
      else private.get_liar_statements_payload(v_round.id)
    end,
    'voteStatus', case
      when v_round.id is null then null
      else private.get_liar_vote_status_payload(v_round.id)
    end,
    'roundResult', case
      when v_round.id is null then null
      else private.get_liar_round_result_payload(v_round.id)
    end
  );
end;
$$;

create or replace function private.advance_liar_phase(p_room_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_room public.rooms;
  v_game_id uuid;
  v_state public.liar_match_states;
  v_round public.liar_rounds;
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;

  select *
  into v_room
  from public.rooms
  where id = p_room_id
  for update;

  if not found or v_room.game_type <> 'liar' then
    raise exception 'Liar room not found';
  end if;

  if v_room.host_user_id <> v_user_id then
    raise exception 'Liar room host only';
  end if;

  v_game_id := private.get_liar_game_id_for_room(p_room_id);

  select *
  into v_state
  from public.liar_match_states
  where game_id = v_game_id
  for update;

  select *
  into v_round
  from public.liar_rounds
  where game_id = v_game_id
  order by round_no desc
  limit 1
  for update;

  if v_round.phase = 'word_reveal' then
    perform private.start_liar_statement_phase(v_round.id);
  elsif v_round.phase = 'statement' then
    perform private.timeout_liar_statement(p_room_id);
  elsif v_round.phase = 'discussion' then
    update public.liar_rounds
    set
      phase = 'voting',
      vote_attempt_no = 1,
      phase_started_at = now(),
      updated_at = now()
    where id = v_round.id;

    perform private.insert_liar_system_message(
      p_room_id,
      v_game_id,
      v_round.round_no,
      '라이어라고 생각하는 참가자에게 투표하세요.',
      format('liar_voting_start:%s', v_round.round_no)
    );
  elsif v_round.phase in ('voting', 'revote') then
    perform private.resolve_liar_vote(v_round.id);
  elsif v_round.phase = 'round_result' then
    if v_state.status = 'finished' then
      update public.liar_rounds
      set
        phase = 'match_result',
        phase_started_at = now(),
        updated_at = now()
      where id = v_round.id;

      update public.rooms
      set
        status = 'game_over',
        phase = 'result',
        updated_at = now()
      where id = p_room_id;

      perform private.insert_liar_system_message(
        p_room_id,
        v_game_id,
        v_round.round_no,
        '목표 점수에 도달했습니다. 최종 결과를 확인하세요.',
        'liar_match_result'
      );
    else
      perform private.start_liar_round(v_game_id);
    end if;
  end if;

  return private.build_current_liar_match(p_room_id);
end;
$$;

create or replace function public.submit_liar_statement(
  p_room_id uuid,
  p_statement_text text
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.submit_liar_statement(p_room_id, p_statement_text);
$$;

create or replace function public.get_liar_statements(p_room_id uuid)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select private.get_liar_statements(p_room_id);
$$;

create or replace function public.timeout_liar_statement(p_room_id uuid)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.timeout_liar_statement(p_room_id);
$$;

alter table public.liar_statements enable row level security;

drop policy if exists liar_statements_participant_select
  on public.liar_statements;
create policy liar_statements_participant_select
  on public.liar_statements
  for select
  to authenticated
  using (private.is_liar_match_player(game_id));

revoke all on table public.liar_statements from anon, authenticated;
grant select on table public.liar_statements to authenticated;

revoke all on function private.get_liar_statements_payload(uuid) from public;
revoke all on function private.get_liar_statements(uuid) from public;
revoke all on function private.advance_liar_statement_turn(uuid) from public;
revoke all on function private.start_liar_statement_phase(uuid) from public;
revoke all on function private.submit_liar_statement(uuid, text) from public;
revoke all on function private.timeout_liar_statement(uuid) from public;
revoke all on function public.submit_liar_statement(uuid, text) from public;
revoke all on function public.get_liar_statements(uuid) from public;
revoke all on function public.timeout_liar_statement(uuid) from public;

grant execute on function private.submit_liar_statement(uuid, text) to authenticated;
grant execute on function private.timeout_liar_statement(uuid) to authenticated;
grant execute on function public.submit_liar_statement(uuid, text) to authenticated;
grant execute on function public.get_liar_statements(uuid) to authenticated;
grant execute on function public.timeout_liar_statement(uuid) to authenticated;

do $realtime$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'liar_statements'
  ) then
    alter publication supabase_realtime add table public.liar_statements;
  end if;
end;
$realtime$;

commit;

notify pgrst, 'reload schema';
