-- Replace the retired rainbowTail placeholder with a playable Catchmind mode.
-- Apply after the base room/game schema. Safe to rerun.

begin;

create schema if not exists private;

update public.rooms
set game_type = 'catchmind'
where game_type in ('rainbowTail', 'rainbow_tail', 'rainbow-tail');

create table if not exists private.catchmind_words (
  id uuid primary key default gen_random_uuid(),
  word text not null unique,
  normalized_word text not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.catchmind_matches (
  game_id uuid primary key references public.games(id) on delete cascade,
  room_id uuid not null references public.rooms(id) on delete cascade,
  status text not null default 'playing'
    check (status in ('playing', 'finished')),
  current_round_no integer not null default 0,
  total_rounds integer not null default 6 check (total_rounds between 1 and 30),
  target_score integer not null default 5 check (target_score between 1 and 30),
  winner_user_ids uuid[] not null default '{}'::uuid[],
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.catchmind_players (
  game_id uuid not null references public.games(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  display_order integer not null,
  score integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (game_id, user_id),
  unique (game_id, display_order)
);

create table if not exists public.catchmind_rounds (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references public.games(id) on delete cascade,
  round_no integer not null check (round_no > 0),
  drawer_user_id uuid not null references public.profiles(id),
  phase text not null default 'ANSWERING'
    check (phase in ('WAITING', 'DRAWING', 'ANSWERING', 'ROUND_RESULT', 'GAME_RESULT')),
  phase_started_at timestamptz not null default now(),
  phase_ends_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (game_id, round_no)
);

create table if not exists private.catchmind_round_secrets (
  round_id uuid primary key references public.catchmind_rounds(id) on delete cascade,
  word_id uuid not null references private.catchmind_words(id),
  created_at timestamptz not null default now()
);

create table if not exists public.catchmind_correct_answers (
  round_id uuid not null references public.catchmind_rounds(id) on delete cascade,
  game_id uuid not null references public.games(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  answer_text text not null,
  awarded_score integer not null default 1,
  answered_at timestamptz not null default now(),
  primary key (round_id, user_id)
);

create index if not exists catchmind_rounds_game_idx
  on public.catchmind_rounds(game_id, round_no desc);

insert into private.catchmind_words (word, normalized_word)
values
  ('사과', '사과'),
  ('비행기', '비행기'),
  ('고양이', '고양이'),
  ('우산', '우산'),
  ('피자', '피자'),
  ('자전거', '자전거'),
  ('선물', '선물'),
  ('로봇', '로봇'),
  ('축구공', '축구공'),
  ('수박', '수박'),
  ('눈사람', '눈사람'),
  ('기타', '기타')
on conflict (word) do update
set normalized_word = excluded.normalized_word;

create or replace function private.normalize_catchmind_answer(p_value text)
returns text
language sql
immutable
set search_path = ''
as $$
  select lower(trim(coalesce(p_value, '')));
$$;

create or replace function private.is_catchmind_player(p_game_id uuid, p_user_id uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.catchmind_players player
    where player.game_id = p_game_id
      and player.user_id = p_user_id
  );
$$;

create or replace function private.get_catchmind_game_id(p_room_id uuid)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select match.game_id
  from public.catchmind_matches match
  where match.room_id = p_room_id
  order by match.created_at desc
  limit 1;
$$;

create or replace function private.insert_catchmind_message(
  p_room_id uuid,
  p_game_id uuid,
  p_round_no integer,
  p_user_id uuid,
  p_nickname text,
  p_content text,
  p_is_system boolean default false,
  p_event_key text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.game_messages (
    room_id, game_id, round_no, user_id, nickname, content,
    message_type, channel_type, event_key, is_system
  ) values (
    p_room_id, p_game_id, p_round_no, p_user_id, p_nickname, p_content,
    case when p_is_system then 'system' else 'chat' end,
    'public', p_event_key, p_is_system
  )
  on conflict (game_id, round_no, event_key)
  where event_key is not null
  do nothing;
end;
$$;

create or replace function private.get_catchmind_payload(p_room_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_match public.catchmind_matches;
  v_round public.catchmind_rounds;
  v_word text;
begin
  select *
  into v_match
  from public.catchmind_matches match
  where match.room_id = p_room_id
  order by match.created_at desc
  limit 1;

  if not found or not private.is_catchmind_player(v_match.game_id, v_user_id) then
    raise exception 'Catchmind participant required';
  end if;

  select *
  into v_round
  from public.catchmind_rounds round
  where round.game_id = v_match.game_id
  order by round.round_no desc
  limit 1;

  select word.word
  into v_word
  from private.catchmind_round_secrets secret
  join private.catchmind_words word on word.id = secret.word_id
  where secret.round_id = v_round.id;

  return jsonb_build_object(
    'gameId', v_match.game_id,
    'roomId', v_match.room_id,
    'status', v_match.status,
    'currentRoundNo', v_match.current_round_no,
    'totalRounds', v_match.total_rounds,
    'targetScore', v_match.target_score,
    'winnerUserIds', to_jsonb(v_match.winner_user_ids),
    'round', case when v_round.id is null then null else jsonb_build_object(
      'id', v_round.id,
      'roundNo', v_round.round_no,
      'drawerUserId', v_round.drawer_user_id,
      'drawerNickname', coalesce(drawer.nickname, '알 수 없음'),
      'phase', v_round.phase,
      'phaseStartedAt', v_round.phase_started_at,
      'phaseEndsAt', v_round.phase_ends_at,
      'answerWord', case
        when v_round.drawer_user_id = v_user_id
          or v_round.phase in ('ROUND_RESULT', 'GAME_RESULT')
        then v_word
        else null
      end
    ) end,
    'players', coalesce((
      select jsonb_agg(jsonb_build_object(
        'userId', player.user_id,
        'nickname', coalesce(profile.nickname, '알 수 없음'),
        'displayOrder', player.display_order,
        'score', player.score,
        'isDrawer', player.user_id = v_round.drawer_user_id
      ) order by player.display_order)
      from public.catchmind_players player
      left join public.profiles profile on profile.id = player.user_id
      where player.game_id = v_match.game_id
    ), '[]'::jsonb),
    'correctAnswers', coalesce((
      select jsonb_agg(jsonb_build_object(
        'userId', answer.user_id,
        'nickname', coalesce(profile.nickname, '알 수 없음'),
        'awardedScore', answer.awarded_score,
        'answeredAt', answer.answered_at
      ) order by answer.answered_at)
      from public.catchmind_correct_answers answer
      left join public.profiles profile on profile.id = answer.user_id
      where answer.round_id = v_round.id
    ), '[]'::jsonb)
  )
  from public.profiles drawer
  where drawer.id = v_round.drawer_user_id;
end;
$$;

create or replace function private.start_catchmind_round(p_game_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_match public.catchmind_matches;
  v_round public.catchmind_rounds;
  v_word private.catchmind_words;
  v_drawer_id uuid;
  v_room_id uuid;
  v_player_count integer;
begin
  select * into v_match
  from public.catchmind_matches
  where game_id = p_game_id
  for update;

  select count(*) into v_player_count
  from public.catchmind_players
  where game_id = p_game_id;

  select player.user_id into v_drawer_id
  from public.catchmind_players player
  where player.game_id = p_game_id
    and player.display_order = ((v_match.current_round_no % v_player_count) + 1);

  select * into v_word
  from private.catchmind_words
  where is_active
  order by random()
  limit 1;

  insert into public.catchmind_rounds (
    game_id, round_no, drawer_user_id, phase, phase_started_at, phase_ends_at
  ) values (
    p_game_id, v_match.current_round_no + 1, v_drawer_id,
    'ANSWERING', now(), now() + interval '60 seconds'
  )
  returning * into v_round;

  insert into private.catchmind_round_secrets (round_id, word_id)
  values (v_round.id, v_word.id);

  update public.catchmind_matches
  set current_round_no = v_round.round_no, updated_at = now()
  where game_id = p_game_id;

  select room_id into v_room_id from public.games where id = p_game_id;

  perform private.insert_catchmind_message(
    v_room_id, p_game_id, v_round.round_no, null, 'System',
    format('%s라운드가 시작되었습니다. 출제자의 그림을 보고 정답을 맞혀보세요.', v_round.round_no),
    true, format('catchmind_round_start:%s', v_round.round_no)
  );
end;
$$;

create or replace function private.start_catchmind_match(p_room_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_room public.rooms;
  v_game public.games;
  v_player_count integer;
begin
  if v_user_id is null then raise exception 'Not authenticated'; end if;
  select * into v_room from public.rooms where id = p_room_id for update;

  if not found or v_room.game_type <> 'catchmind' then
    raise exception 'Catchmind room not found';
  end if;
  if v_room.host_user_id <> v_user_id then raise exception 'Host only'; end if;
  if v_room.status <> 'waiting' then raise exception 'Catchmind already started'; end if;
  if exists (
    select 1
    from public.games
    where room_id = p_room_id
      and status not in ('finished', 'ended')
  ) then raise exception 'Active game already exists'; end if;

  select count(*) into v_player_count
  from public.room_players
  where room_id = p_room_id and coalesce(connection_status, 'active') = 'active';

  if v_player_count < 2 then raise exception 'Not enough Catchmind players'; end if;
  if exists (
    select 1 from public.room_players
    where room_id = p_room_id
      and coalesce(connection_status, 'active') = 'active'
      and is_ready is not true
  ) then raise exception 'Catchmind player not ready'; end if;

  insert into public.games (room_id, status, phase, round_no, phase_started_at, phase_ends_at)
  values (p_room_id, 'playing', 'discussion', 0, now(), now() + interval '100 years')
  returning * into v_game;

  insert into public.catchmind_matches (game_id, room_id, total_rounds)
  values (v_game.id, p_room_id, greatest(v_player_count * 2, 4));

  insert into public.catchmind_players (game_id, user_id, display_order)
  select v_game.id, player.user_id, row_number() over (order by player.joined_at, player.user_id)
  from public.room_players player
  where player.room_id = p_room_id and coalesce(player.connection_status, 'active') = 'active';

  update public.rooms set status = 'playing', phase = 'discussion', updated_at = now()
  where id = p_room_id;

  perform private.start_catchmind_round(v_game.id);
  return private.get_catchmind_payload(p_room_id);
end;
$$;

create or replace function private.submit_catchmind_answer(p_room_id uuid, p_answer text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_game_id uuid := private.get_catchmind_game_id(p_room_id);
  v_round public.catchmind_rounds;
  v_word private.catchmind_words;
  v_nickname text;
  v_answer text := trim(coalesce(p_answer, ''));
  v_is_correct boolean := false;
  v_score integer;
begin
  if v_answer = '' then return private.get_catchmind_payload(p_room_id); end if;
  if not private.is_catchmind_player(v_game_id, v_user_id) then
    raise exception 'Catchmind participant required';
  end if;

  select * into v_round from public.catchmind_rounds
  where game_id = v_game_id order by round_no desc limit 1 for update;
  select word.* into v_word from private.catchmind_words word
  join private.catchmind_round_secrets secret on secret.word_id = word.id
  where secret.round_id = v_round.id;
  select coalesce(nickname, '알 수 없음') into v_nickname from public.profiles where id = v_user_id;

  v_is_correct := v_round.phase = 'ANSWERING'
    and v_round.drawer_user_id <> v_user_id
    and private.normalize_catchmind_answer(v_answer) = v_word.normalized_word;

  perform private.insert_catchmind_message(
    p_room_id, v_game_id, v_round.round_no, v_user_id, v_nickname,
    case when v_is_correct then '(정답을 맞혔습니다)' else v_answer end
  );

  if v_is_correct then
    insert into public.catchmind_correct_answers (round_id, game_id, user_id, answer_text)
    values (v_round.id, v_game_id, v_user_id, '정답')
    on conflict do nothing;

    if found then
      update public.catchmind_players set score = score + 1, updated_at = now()
      where game_id = v_game_id and user_id = v_user_id
      returning score into v_score;

      perform private.insert_catchmind_message(
        p_room_id, v_game_id, v_round.round_no, null, 'System',
        format('%s님이 정답을 맞혔습니다!', v_nickname), true,
        format('catchmind_correct:%s:%s', v_round.round_no, v_user_id)
      );

      if v_score >= (select target_score from public.catchmind_matches where game_id = v_game_id) then
        update public.catchmind_matches set status = 'finished', updated_at = now() where game_id = v_game_id;
      end if;
    end if;
  end if;

  return private.get_catchmind_payload(p_room_id);
end;
$$;

create or replace function private.advance_catchmind_phase(p_room_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_game_id uuid := private.get_catchmind_game_id(p_room_id);
  v_match public.catchmind_matches;
  v_round public.catchmind_rounds;
  v_host_user_id uuid;
  v_word text;
  v_winners uuid[];
begin
  if not private.is_catchmind_player(v_game_id, v_user_id) then raise exception 'Catchmind participant required'; end if;
  select host_user_id into v_host_user_id from public.rooms where id = p_room_id;
  select * into v_match from public.catchmind_matches where game_id = v_game_id for update;
  select * into v_round from public.catchmind_rounds where game_id = v_game_id order by round_no desc limit 1 for update;

  if v_round.phase = 'ANSWERING' then
    if v_round.phase_ends_at > now() and v_host_user_id <> v_user_id then
      raise exception 'Catchmind round is still active';
    end if;
    update public.catchmind_rounds set phase = 'ROUND_RESULT', phase_started_at = now(), phase_ends_at = null, updated_at = now()
    where id = v_round.id;
    select word.word into v_word from private.catchmind_round_secrets secret
    join private.catchmind_words word on word.id = secret.word_id where secret.round_id = v_round.id;
    perform private.insert_catchmind_message(
      p_room_id, v_game_id, v_round.round_no, null, 'System',
      format('라운드가 종료되었습니다. 정답은 "%s"입니다.', v_word), true,
      format('catchmind_round_result:%s', v_round.round_no)
    );
  elsif v_round.phase = 'ROUND_RESULT' then
    if v_host_user_id <> v_user_id then raise exception 'Host only'; end if;
    if v_match.status = 'finished' or v_match.current_round_no >= v_match.total_rounds then
      select coalesce(array_agg(user_id), '{}'::uuid[]) into v_winners
      from public.catchmind_players
      where game_id = v_game_id
        and score = (select max(score) from public.catchmind_players where game_id = v_game_id);
      update public.catchmind_matches set status = 'finished', winner_user_ids = v_winners, updated_at = now() where game_id = v_game_id;
      update public.catchmind_rounds set phase = 'GAME_RESULT', updated_at = now() where id = v_round.id;
      update public.rooms set status = 'game_over', phase = 'result', updated_at = now() where id = p_room_id;
    else
      perform private.start_catchmind_round(v_game_id);
    end if;
  end if;
  return private.get_catchmind_payload(p_room_id);
end;
$$;

create or replace function private.return_catchmind_lobby(p_room_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_game_id uuid := private.get_catchmind_game_id(p_room_id);
begin
  if not private.is_catchmind_player(v_game_id) then raise exception 'Catchmind participant required'; end if;
  update public.games set status = 'finished', ended_at = coalesce(ended_at, now()) where id = v_game_id;
  update public.rooms set status = 'waiting', phase = 'before_start', updated_at = now() where id = p_room_id;
  update public.room_players set is_ready = is_host where room_id = p_room_id;
end; $$;

create or replace function public.start_catchmind_match(p_room_id uuid) returns jsonb language sql security invoker set search_path = '' as $$ select private.start_catchmind_match(p_room_id); $$;
create or replace function public.get_current_catchmind(p_room_id uuid) returns jsonb language sql stable security invoker set search_path = '' as $$ select private.get_catchmind_payload(p_room_id); $$;
create or replace function public.submit_catchmind_answer(p_room_id uuid, p_answer text) returns jsonb language sql security invoker set search_path = '' as $$ select private.submit_catchmind_answer(p_room_id, p_answer); $$;
create or replace function public.advance_catchmind_phase(p_room_id uuid) returns jsonb language sql security invoker set search_path = '' as $$ select private.advance_catchmind_phase(p_room_id); $$;
create or replace function public.return_catchmind_lobby(p_room_id uuid) returns void language sql security invoker set search_path = '' as $$ select private.return_catchmind_lobby(p_room_id); $$;

revoke all on function public.start_catchmind_match(uuid) from public, anon;
revoke all on function public.get_current_catchmind(uuid) from public, anon;
revoke all on function public.submit_catchmind_answer(uuid, text) from public, anon;
revoke all on function public.advance_catchmind_phase(uuid) from public, anon;
revoke all on function public.return_catchmind_lobby(uuid) from public, anon;

alter table public.catchmind_matches enable row level security;
alter table public.catchmind_players enable row level security;
alter table public.catchmind_rounds enable row level security;
alter table public.catchmind_correct_answers enable row level security;

drop policy if exists catchmind_matches_select on public.catchmind_matches;
drop policy if exists catchmind_players_select on public.catchmind_players;
drop policy if exists catchmind_rounds_select on public.catchmind_rounds;
drop policy if exists catchmind_answers_select on public.catchmind_correct_answers;
create policy catchmind_matches_select on public.catchmind_matches for select to authenticated using (private.is_catchmind_player(game_id));
create policy catchmind_players_select on public.catchmind_players for select to authenticated using (private.is_catchmind_player(game_id));
create policy catchmind_rounds_select on public.catchmind_rounds for select to authenticated using (private.is_catchmind_player(game_id));
create policy catchmind_answers_select on public.catchmind_correct_answers for select to authenticated using (private.is_catchmind_player(game_id));

revoke all on table private.catchmind_words, private.catchmind_round_secrets from public, anon, authenticated;
revoke all on table public.catchmind_matches, public.catchmind_players, public.catchmind_rounds, public.catchmind_correct_answers from anon, authenticated;
grant select on table public.catchmind_matches, public.catchmind_players, public.catchmind_rounds, public.catchmind_correct_answers to authenticated;
revoke all on all functions in schema private from public;
grant usage on schema private to authenticated;
grant execute on function private.start_catchmind_match(uuid), private.get_catchmind_payload(uuid), private.submit_catchmind_answer(uuid, text), private.advance_catchmind_phase(uuid), private.return_catchmind_lobby(uuid) to authenticated;
grant execute on function public.start_catchmind_match(uuid), public.get_current_catchmind(uuid), public.submit_catchmind_answer(uuid, text), public.advance_catchmind_phase(uuid), public.return_catchmind_lobby(uuid) to authenticated;

do $realtime$
declare v_table text;
begin
  foreach v_table in array array['catchmind_matches', 'catchmind_players', 'catchmind_rounds', 'catchmind_correct_answers']
  loop
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = v_table) then
      execute format('alter publication supabase_realtime add table public.%I', v_table);
    end if;
  end loop;
end; $realtime$;

commit;
notify pgrst, 'reload schema';
