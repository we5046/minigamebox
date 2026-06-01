-- Apply after the base game schema, room-admin.sql, and password-room-fix.sql.
-- Adds the target-score liar game without changing the mafia engine.

begin;

create schema if not exists private;
revoke all on schema private from public;

-- This file extends the existing mafia schema. Fail early with a useful
-- message when it is accidentally applied to a blank Supabase project.
do $$
declare
  v_table_name text;
begin
  foreach v_table_name in array array[
    'public.rooms',
    'public.room_players',
    'public.games',
    'public.game_messages',
    'public.game_result_players',
    'public.profiles'
  ]
  loop
    if to_regclass(v_table_name) is null then
      raise exception 'liar-game.sql prerequisite table is missing: %', v_table_name;
    end if;
  end loop;
end;
$$;

do $$
declare
  v_column record;
begin
  for v_column in
    select *
    from (
      values
        ('public', 'rooms', 'game_type'),
        ('public', 'rooms', 'host_user_id'),
        ('public', 'rooms', 'status'),
        ('public', 'rooms', 'phase'),
        ('public', 'rooms', 'min_start_players'),
        ('public', 'rooms', 'tie_vote_rule'),
        ('public', 'rooms', 'spectator_allowed'),
        ('public', 'rooms', 'updated_at'),
        ('public', 'room_players', 'connection_status'),
        ('public', 'room_players', 'is_ready'),
        ('public', 'room_players', 'joined_at'),
        ('public', 'room_players', 'is_host'),
        ('public', 'room_players', 'role'),
        ('public', 'room_players', 'is_alive'),
        ('public', 'games', 'phase'),
        ('public', 'games', 'round_no'),
        ('public', 'games', 'phase_started_at'),
        ('public', 'games', 'phase_ends_at'),
        ('public', 'games', 'ended_at'),
        ('public', 'game_messages', 'channel_type'),
        ('public', 'game_messages', 'event_key'),
        ('public', 'game_messages', 'is_system'),
        ('public', 'game_result_players', 'role_name'),
        ('public', 'game_result_players', 'is_alive'),
        ('public', 'game_result_players', 'is_winner'),
        ('public', 'profiles', 'nickname')
    ) as required(schema_name, table_name, column_name)
  loop
    if not exists (
      select 1
      from information_schema.columns column_info
      where column_info.table_schema = v_column.schema_name
        and column_info.table_name = v_column.table_name
        and column_info.column_name = v_column.column_name
    ) then
      raise exception 'liar-game.sql prerequisite column is missing: %.%.%',
        v_column.schema_name,
        v_column.table_name,
        v_column.column_name;
    end if;
  end loop;
end;
$$;

create table if not exists public.liar_categories (
  id uuid primary key default gen_random_uuid(),
  category_key text not null unique,
  label text not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.liar_room_settings (
  room_id uuid primary key references public.rooms(id) on delete cascade,
  setting_mode text not null default 'classic'
    check (setting_mode in ('classic', 'custom')),
  category_id uuid references public.liar_categories(id),
  target_score integer not null default 5
    check (target_score between 3 and 20),
  citizen_win_score integer not null default 1
    check (citizen_win_score between 1 and 5),
  liar_win_score integer not null default 2
    check (liar_win_score between 1 and 10),
  liar_count integer not null default 1
    check (liar_count = 1),
  tie_rule text not null default 'revote'
    check (tie_rule = 'revote'),
  self_vote_allowed boolean not null default false
    check (self_vote_allowed is false),
  liar_word_mode text not null default 'none'
    check (liar_word_mode = 'none'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.liar_match_states (
  game_id uuid primary key references public.games(id) on delete cascade,
  room_id uuid not null references public.rooms(id) on delete cascade,
  setting_mode text not null check (setting_mode in ('classic', 'custom')),
  category_id uuid references public.liar_categories(id),
  target_score integer not null check (target_score between 3 and 20),
  citizen_win_score integer not null check (citizen_win_score between 1 and 5),
  liar_win_score integer not null check (liar_win_score between 1 and 10),
  current_round_no integer not null default 0 check (current_round_no >= 0),
  winner_user_ids uuid[] not null default '{}'::uuid[],
  status text not null default 'playing'
    check (status in ('playing', 'finished')),
  created_at timestamptz not null default now(),
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  updated_at timestamptz not null default now()
);

create table if not exists public.liar_match_players (
  game_id uuid not null references public.games(id) on delete cascade,
  user_id uuid not null,
  display_order integer not null,
  created_at timestamptz not null default now(),
  primary key (game_id, user_id),
  unique (game_id, display_order)
);

create table if not exists public.liar_scores (
  game_id uuid not null references public.games(id) on delete cascade,
  user_id uuid not null,
  score integer not null default 0 check (score >= 0),
  updated_at timestamptz not null default now(),
  primary key (game_id, user_id),
  foreign key (game_id, user_id)
    references public.liar_match_players(game_id, user_id)
    on delete cascade
);

create table if not exists public.liar_rounds (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references public.games(id) on delete cascade,
  round_no integer not null check (round_no > 0),
  category_id uuid not null references public.liar_categories(id),
  phase text not null default 'word_reveal'
    check (
      phase in (
        'word_reveal',
        'discussion',
        'voting',
        'revote',
        'liar_guess',
        'round_result',
        'match_result'
      )
    ),
  phase_started_at timestamptz not null default now(),
  phase_ends_at timestamptz,
  voted_user_id uuid,
  round_winner_side text
    check (round_winner_side in ('citizen', 'liar', 'invalid')),
  end_reason text,
  vote_attempt_no integer not null default 1
    check (vote_attempt_no in (1, 2)),
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (game_id, round_no)
);

create table if not exists public.liar_votes (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references public.games(id) on delete cascade,
  round_id uuid not null references public.liar_rounds(id) on delete cascade,
  voter_id uuid not null,
  target_id uuid not null,
  vote_attempt_no integer not null check (vote_attempt_no in (1, 2)),
  created_at timestamptz not null default now(),
  unique (round_id, voter_id, vote_attempt_no),
  check (voter_id <> target_id)
);

create table if not exists private.liar_words (
  id uuid primary key default gen_random_uuid(),
  category_id uuid not null references public.liar_categories(id) on delete cascade,
  word text not null,
  normalized_word text not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (category_id, word)
);

create table if not exists private.liar_round_secrets (
  round_id uuid primary key references public.liar_rounds(id) on delete cascade,
  liar_user_id uuid not null,
  word_id uuid not null references private.liar_words(id),
  created_at timestamptz not null default now()
);

create table if not exists private.liar_guesses (
  round_id uuid primary key references public.liar_rounds(id) on delete cascade,
  liar_user_id uuid not null,
  guess_text text not null,
  normalized_guess text not null,
  is_correct boolean not null,
  created_at timestamptz not null default now()
);

create index if not exists liar_match_states_room_id_idx
  on public.liar_match_states(room_id, created_at desc);

create index if not exists liar_rounds_game_id_idx
  on public.liar_rounds(game_id, round_no desc);

create index if not exists liar_votes_round_attempt_idx
  on public.liar_votes(round_id, vote_attempt_no, created_at);

insert into public.liar_categories (category_key, label)
values
  ('food', '음식'),
  ('animal', '동물'),
  ('place', '장소'),
  ('object', '물건'),
  ('job', '직업'),
  ('sport', '스포츠')
on conflict (category_key) do update
set
  label = excluded.label,
  updated_at = now();

insert into private.liar_words (category_id, word, normalized_word)
select c.id, seed.word, lower(regexp_replace(trim(seed.word), '\s+', ' ', 'g'))
from (
  values
    ('food', '김밥'),
    ('food', '피자'),
    ('food', '떡볶이'),
    ('food', '초밥'),
    ('food', '햄버거'),
    ('animal', '고양이'),
    ('animal', '강아지'),
    ('animal', '코끼리'),
    ('animal', '기린'),
    ('animal', '돌고래'),
    ('place', '학교'),
    ('place', '공항'),
    ('place', '도서관'),
    ('place', '놀이공원'),
    ('place', '편의점'),
    ('object', '우산'),
    ('object', '냉장고'),
    ('object', '이어폰'),
    ('object', '자전거'),
    ('object', '연필'),
    ('job', '의사'),
    ('job', '소방관'),
    ('job', '요리사'),
    ('job', '교사'),
    ('job', '개발자'),
    ('sport', '축구'),
    ('sport', '야구'),
    ('sport', '농구'),
    ('sport', '수영'),
    ('sport', '배드민턴')
) as seed(category_key, word)
join public.liar_categories c on c.category_key = seed.category_key
on conflict (category_id, word) do update
set
  normalized_word = excluded.normalized_word,
  updated_at = now();

create or replace function private.normalize_liar_word(p_value text)
returns text
language sql
immutable
set search_path = ''
as $$
  select lower(regexp_replace(trim(coalesce(p_value, '')), '\s+', ' ', 'g'));
$$;

create or replace function private.is_liar_match_player(
  p_game_id uuid,
  p_user_id uuid default auth.uid()
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.liar_match_players player
    where player.game_id = p_game_id
      and player.user_id = p_user_id
  );
$$;

create or replace function private.get_liar_game_id_for_room(p_room_id uuid)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select state.game_id
  from public.liar_match_states state
  where state.room_id = p_room_id
  order by state.created_at desc
  limit 1;
$$;

create or replace function private.get_liar_revote_candidate_ids(p_round_id uuid)
returns uuid[]
language sql
stable
security definer
set search_path = ''
as $$
  with vote_counts as (
    select vote.target_id, count(*)::integer as vote_count
    from public.liar_votes vote
    where vote.round_id = p_round_id
      and vote.vote_attempt_no = 1
    group by vote.target_id
  ),
  max_count as (
    select max(vote_count) as vote_count
    from vote_counts
  )
  select coalesce(array_agg(vote_counts.target_id order by vote_counts.target_id), '{}'::uuid[])
  from vote_counts
  cross join max_count
  where vote_counts.vote_count = max_count.vote_count;
$$;

create or replace function private.insert_liar_system_message(
  p_room_id uuid,
  p_game_id uuid,
  p_round_no integer,
  p_content text,
  p_event_key text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.game_messages (
    room_id,
    game_id,
    round_no,
    user_id,
    nickname,
    content,
    message_type,
    channel_type,
    event_key,
    is_system
  ) values (
    p_room_id,
    p_game_id,
    p_round_no,
    null,
    'System',
    p_content,
    'system',
    'public',
    p_event_key,
    true
  )
  on conflict (game_id, round_no, event_key)
  where event_key is not null
  do nothing;
end;
$$;

create or replace function private.get_liar_scoreboard_payload(p_game_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'userId', player.user_id,
        'nickname', coalesce(profile.nickname, '알 수 없음'),
        'displayOrder', player.display_order,
        'score', coalesce(score.score, 0)
      )
      order by player.display_order
    ),
    '[]'::jsonb
  )
  from public.liar_match_players player
  left join public.profiles profile on profile.id = player.user_id
  left join public.liar_scores score
    on score.game_id = player.game_id
   and score.user_id = player.user_id
  where player.game_id = p_game_id;
$$;

create or replace function private.get_liar_vote_status_payload(p_round_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_round public.liar_rounds;
  v_votes jsonb;
  v_candidate_ids uuid[];
begin
  select *
  into v_round
  from public.liar_rounds
  where id = p_round_id;

  if not found then
    return jsonb_build_object(
      'attemptNo', 1,
      'candidateUserIds', '[]'::jsonb,
      'votes', '[]'::jsonb
    );
  end if;

  if v_round.phase = 'revote' then
    v_candidate_ids := private.get_liar_revote_candidate_ids(p_round_id);
  else
    select coalesce(array_agg(player.user_id order by player.display_order), '{}'::uuid[])
    into v_candidate_ids
    from public.liar_match_players player
    where player.game_id = v_round.game_id;
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', vote.id,
        'voterId', vote.voter_id,
        'voterName', coalesce(voter.nickname, '알 수 없음'),
        'targetId', vote.target_id,
        'targetName', coalesce(target.nickname, '알 수 없음'),
        'voteAttemptNo', vote.vote_attempt_no,
        'createdAt', vote.created_at
      )
      order by vote.created_at
    ),
    '[]'::jsonb
  )
  into v_votes
  from public.liar_votes vote
  left join public.profiles voter on voter.id = vote.voter_id
  left join public.profiles target on target.id = vote.target_id
  where vote.round_id = p_round_id
    and vote.vote_attempt_no = v_round.vote_attempt_no;

  return jsonb_build_object(
    'attemptNo', v_round.vote_attempt_no,
    'candidateUserIds', to_jsonb(v_candidate_ids),
    'votes', v_votes
  );
end;
$$;

create or replace function private.get_liar_round_result_payload(p_round_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_round public.liar_rounds;
  v_payload jsonb;
begin
  select *
  into v_round
  from public.liar_rounds
  where id = p_round_id;

  if not found or v_round.phase not in ('round_result', 'match_result') then
    return null;
  end if;

  select jsonb_build_object(
    'roundNo', v_round.round_no,
    'winnerSide', v_round.round_winner_side,
    'endReason', v_round.end_reason,
    'votedUserId', v_round.voted_user_id,
    'liarUserId', secret.liar_user_id,
    'liarNickname', coalesce(liar_profile.nickname, '알 수 없음'),
    'categoryId', category.id,
    'categoryLabel', category.label,
    'word', word.word,
    'guessText', guess.guess_text,
    'guessCorrect', guess.is_correct,
    'votes', private.get_liar_vote_status_payload(v_round.id)
  )
  into v_payload
  from private.liar_round_secrets secret
  join private.liar_words word on word.id = secret.word_id
  join public.liar_categories category on category.id = word.category_id
  left join public.profiles liar_profile on liar_profile.id = secret.liar_user_id
  left join private.liar_guesses guess on guess.round_id = secret.round_id
  where secret.round_id = v_round.id;

  return v_payload;
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
        'voteAttemptNo', v_round.vote_attempt_no
      )
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

create or replace function private.start_liar_round(p_game_id uuid)
returns public.liar_rounds
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_game public.games;
  v_state public.liar_match_states;
  v_round public.liar_rounds;
  v_round_no integer;
  v_liar_user_id uuid;
  v_word private.liar_words;
begin
  select *
  into v_game
  from public.games
  where id = p_game_id
  for update;

  if not found then
    raise exception 'Liar match not found';
  end if;

  select *
  into v_state
  from public.liar_match_states
  where game_id = p_game_id
  for update;

  if not found or v_state.status <> 'playing' then
    raise exception 'Liar match is not playing';
  end if;

  select player.user_id
  into v_liar_user_id
  from public.liar_match_players player
  where player.game_id = p_game_id
  order by random()
  limit 1;

  if v_liar_user_id is null then
    raise exception 'Liar match players required';
  end if;

  select word.*
  into v_word
  from private.liar_words word
  join public.liar_categories category on category.id = word.category_id
  where word.is_active
    and category.is_active
    and (v_state.category_id is null or word.category_id = v_state.category_id)
  order by random()
  limit 1;

  if not found then
    raise exception 'Active liar word required';
  end if;

  v_round_no := v_state.current_round_no + 1;

  insert into public.liar_rounds (
    game_id,
    round_no,
    category_id,
    phase,
    vote_attempt_no
  ) values (
    p_game_id,
    v_round_no,
    v_word.category_id,
    'word_reveal',
    1
  )
  returning * into v_round;

  insert into private.liar_round_secrets (
    round_id,
    liar_user_id,
    word_id
  ) values (
    v_round.id,
    v_liar_user_id,
    v_word.id
  );

  update public.liar_match_states
  set
    current_round_no = v_round_no,
    updated_at = now()
  where game_id = p_game_id;

  update public.games
  set
    status = 'playing',
    phase = 'discussion',
    round_no = v_round_no,
    phase_started_at = now(),
    -- Liar phases advance through liar RPCs, not the mafia expiry worker.
    phase_ends_at = now() + interval '100 years'
  where id = p_game_id;

  update public.rooms
  set
    status = 'playing',
    phase = 'discussion',
    updated_at = now()
  where id = v_game.room_id;

  perform private.insert_liar_system_message(
    v_game.room_id,
    p_game_id,
    v_round_no,
    format('%s라운드가 시작되었습니다. 역할과 제시어를 확인하세요.', v_round_no),
    format('liar_round_start:%s', v_round_no)
  );

  return v_round;
end;
$$;

create or replace function private.record_liar_match_results(p_game_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_winner_user_ids uuid[];
begin
  select winner_user_ids
  into v_winner_user_ids
  from public.liar_match_states
  where game_id = p_game_id;

  insert into public.game_result_players (
    game_id,
    user_id,
    role_name,
    is_alive,
    is_winner
  )
  select
    player.game_id,
    player.user_id,
    'player',
    true,
    player.user_id = any(v_winner_user_ids)
  from public.liar_match_players player
  where player.game_id = p_game_id
  on conflict (game_id, user_id) do update
  set
    role_name = excluded.role_name,
    is_alive = excluded.is_alive,
    is_winner = excluded.is_winner;
end;
$$;

create or replace function private.finish_liar_round(
  p_round_id uuid,
  p_winner_side text,
  p_end_reason text
)
returns public.liar_rounds
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_round public.liar_rounds;
  v_state public.liar_match_states;
  v_secret private.liar_round_secrets;
  v_max_score integer;
  v_winner_user_ids uuid[];
  v_room_id uuid;
begin
  if p_winner_side not in ('citizen', 'liar', 'invalid') then
    raise exception 'Invalid liar round winner side';
  end if;

  select *
  into v_round
  from public.liar_rounds
  where id = p_round_id
  for update;

  if not found then
    raise exception 'Liar round not found';
  end if;

  if v_round.round_winner_side is not null then
    return v_round;
  end if;

  select *
  into v_state
  from public.liar_match_states
  where game_id = v_round.game_id
  for update;

  select *
  into v_secret
  from private.liar_round_secrets
  where round_id = p_round_id;

  update public.liar_rounds
  set
    phase = 'round_result',
    round_winner_side = p_winner_side,
    end_reason = p_end_reason,
    ended_at = now(),
    updated_at = now()
  where id = p_round_id
  returning * into v_round;

  if p_winner_side = 'liar' then
    update public.liar_scores
    set
      score = score + v_state.liar_win_score,
      updated_at = now()
    where game_id = v_round.game_id
      and user_id = v_secret.liar_user_id;
  elsif p_winner_side = 'citizen' then
    update public.liar_scores
    set
      score = score + v_state.citizen_win_score,
      updated_at = now()
    where game_id = v_round.game_id
      and user_id <> v_secret.liar_user_id;
  end if;

  select max(score)
  into v_max_score
  from public.liar_scores
  where game_id = v_round.game_id;

  if coalesce(v_max_score, 0) >= v_state.target_score then
    select coalesce(array_agg(score.user_id order by score.user_id), '{}'::uuid[])
    into v_winner_user_ids
    from public.liar_scores score
    where score.game_id = v_round.game_id
      and score.score = v_max_score;

    update public.liar_match_states
    set
      winner_user_ids = v_winner_user_ids,
      status = 'finished',
      finished_at = now(),
      updated_at = now()
    where game_id = v_round.game_id;

    update public.games
    set
      status = 'ended',
      ended_at = now()
    where id = v_round.game_id;

    perform private.record_liar_match_results(v_round.game_id);
  end if;

  select room_id
  into v_room_id
  from public.games
  where id = v_round.game_id;

  perform private.insert_liar_system_message(
    v_room_id,
    v_round.game_id,
    v_round.round_no,
    case p_winner_side
      when 'citizen' then '일반 유저가 이번 라운드에서 승리했습니다.'
      when 'liar' then '라이어가 이번 라운드에서 승리했습니다.'
      else '재투표에서도 동률이 발생하여 이번 라운드는 무효입니다.'
    end,
    format('liar_round_result:%s', v_round.round_no)
  );

  return v_round;
end;
$$;

create or replace function private.resolve_liar_vote(p_round_id uuid)
returns public.liar_rounds
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_round public.liar_rounds;
  v_player_count integer;
  v_vote_count integer;
  v_max_vote_count integer;
  v_top_candidate_count integer;
  v_nominated_user_id uuid;
  v_liar_user_id uuid;
  v_room_id uuid;
begin
  select *
  into v_round
  from public.liar_rounds
  where id = p_round_id
  for update;

  if not found then
    raise exception 'Liar round not found';
  end if;

  if v_round.phase not in ('voting', 'revote') then
    return v_round;
  end if;

  select count(*)
  into v_player_count
  from public.liar_match_players
  where game_id = v_round.game_id;

  select count(*)
  into v_vote_count
  from public.liar_votes
  where round_id = p_round_id
    and vote_attempt_no = v_round.vote_attempt_no;

  if v_vote_count < v_player_count then
    raise exception 'All liar match players must vote';
  end if;

  with vote_counts as (
    select target_id, count(*)::integer as vote_count
    from public.liar_votes
    where round_id = p_round_id
      and vote_attempt_no = v_round.vote_attempt_no
    group by target_id
  )
  select max(vote_count)
  into v_max_vote_count
  from vote_counts;

  with vote_counts as (
    select target_id, count(*)::integer as vote_count
    from public.liar_votes
    where round_id = p_round_id
      and vote_attempt_no = v_round.vote_attempt_no
    group by target_id
  )
  select count(*), (array_agg(target_id order by target_id))[1]
  into v_top_candidate_count, v_nominated_user_id
  from vote_counts
  where vote_count = v_max_vote_count;

  select game.room_id
  into v_room_id
  from public.games game
  where game.id = v_round.game_id;

  if v_top_candidate_count > 1 and v_round.vote_attempt_no = 1 then
    update public.liar_rounds
    set
      phase = 'revote',
      vote_attempt_no = 2,
      phase_started_at = now(),
      updated_at = now()
    where id = p_round_id
    returning * into v_round;

    perform private.insert_liar_system_message(
      v_room_id,
      v_round.game_id,
      v_round.round_no,
      '동률이 발생했습니다. 최다 득표 후보 중 다시 투표하세요.',
      format('liar_revote_start:%s', v_round.round_no)
    );

    return v_round;
  end if;

  if v_top_candidate_count > 1 then
    return private.finish_liar_round(
      p_round_id,
      'invalid',
      'revote_tied'
    );
  end if;

  update public.liar_rounds
  set
    voted_user_id = v_nominated_user_id,
    updated_at = now()
  where id = p_round_id
  returning * into v_round;

  select liar_user_id
  into v_liar_user_id
  from private.liar_round_secrets
  where round_id = p_round_id;

  if v_nominated_user_id = v_liar_user_id then
    update public.liar_rounds
    set
      phase = 'liar_guess',
      phase_started_at = now(),
      updated_at = now()
    where id = p_round_id
    returning * into v_round;

    perform private.insert_liar_system_message(
      v_room_id,
      v_round.game_id,
      v_round.round_no,
      '라이어가 지목되었습니다. 최종 제시어 추측을 기다립니다.',
      format('liar_guess_start:%s', v_round.round_no)
    );

    return v_round;
  end if;

  return private.finish_liar_round(
    p_round_id,
    'liar',
    'wrong_player_voted'
  );
end;
$$;

create or replace function private.ensure_liar_room_settings()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.game_type = 'liar' then
    insert into public.liar_room_settings (room_id)
    values (new.id)
    on conflict (room_id) do nothing;
  end if;

  return new;
end;
$$;

create or replace function private.enforce_liar_game_message_phase()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_game_type text;
  v_phase text;
begin
  select room.game_type
  into v_game_type
  from public.rooms room
  where room.id = new.room_id;

  if v_game_type <> 'liar' or coalesce(new.is_system, false) then
    return new;
  end if;

  if new.user_id is null or new.user_id <> auth.uid() then
    raise exception 'Liar chat author mismatch';
  end if;

  if not private.is_liar_match_player(new.game_id, new.user_id) then
    raise exception 'Liar match participant required';
  end if;

  select round.phase
  into v_phase
  from public.liar_rounds round
  where round.game_id = new.game_id
  order by round.round_no desc
  limit 1;

  if v_phase <> 'discussion' then
    raise exception 'Liar discussion phase required';
  end if;

  return new;
end;
$$;

drop trigger if exists enforce_liar_game_message_phase
  on public.game_messages;

create trigger enforce_liar_game_message_phase
  before insert on public.game_messages
  for each row
  execute function private.enforce_liar_game_message_phase();

drop trigger if exists ensure_liar_room_settings
  on public.rooms;

create trigger ensure_liar_room_settings
  after insert or update of game_type on public.rooms
  for each row
  execute function private.ensure_liar_room_settings();

insert into public.liar_room_settings (room_id)
select room.id
from public.rooms room
where room.game_type = 'liar'
on conflict (room_id) do nothing;

create or replace function private.configure_liar_room(
  p_room_id uuid,
  p_setting_mode text default 'classic',
  p_category_id uuid default null,
  p_target_score integer default 5,
  p_citizen_win_score integer default 1,
  p_liar_win_score integer default 2
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_room public.rooms;
  v_settings public.liar_room_settings;
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

  if v_room.status <> 'waiting' then
    raise exception 'Waiting liar room required';
  end if;

  if p_setting_mode not in ('classic', 'custom') then
    raise exception 'Invalid liar setting mode';
  end if;

  if p_category_id is not null and not exists (
    select 1
    from public.liar_categories category
    where category.id = p_category_id
      and category.is_active
  ) then
    raise exception 'Active liar category required';
  end if;

  if p_setting_mode = 'classic' then
    p_target_score := 5;
    p_citizen_win_score := 1;
    p_liar_win_score := 2;
  end if;

  if p_target_score < 3 or p_target_score > 20 then
    raise exception 'Liar target score must be between 3 and 20';
  end if;

  if p_citizen_win_score < 1 or p_citizen_win_score > 5 then
    raise exception 'Citizen win score must be between 1 and 5';
  end if;

  if p_liar_win_score < 1 or p_liar_win_score > 10 then
    raise exception 'Liar win score must be between 1 and 10';
  end if;

  insert into public.liar_room_settings (
    room_id,
    setting_mode,
    category_id,
    target_score,
    citizen_win_score,
    liar_win_score,
    updated_at
  ) values (
    p_room_id,
    p_setting_mode,
    p_category_id,
    p_target_score,
    p_citizen_win_score,
    p_liar_win_score,
    now()
  )
  on conflict (room_id) do update
  set
    setting_mode = excluded.setting_mode,
    category_id = excluded.category_id,
    target_score = excluded.target_score,
    citizen_win_score = excluded.citizen_win_score,
    liar_win_score = excluded.liar_win_score,
    updated_at = now()
  returning * into v_settings;

  update public.rooms
  set
    min_start_players = greatest(min_start_players, 3),
    tie_vote_rule = 'revote',
    spectator_allowed = false,
    updated_at = now()
  where id = p_room_id;

  return to_jsonb(v_settings);
end;
$$;

create or replace function private.start_liar_match(p_room_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_room public.rooms;
  v_settings public.liar_room_settings;
  v_game public.games;
  v_player_count integer;
  v_not_ready_count integer;
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

  if v_room.status <> 'waiting' then
    raise exception 'Liar match already started';
  end if;

  select *
  into v_settings
  from public.liar_room_settings
  where room_id = p_room_id;

  if not found then
    insert into public.liar_room_settings (room_id)
    values (p_room_id)
    returning * into v_settings;
  end if;

  select count(*)
  into v_player_count
  from public.room_players player
  where player.room_id = p_room_id
    and coalesce(player.connection_status, 'active') = 'active';

  if v_player_count < 3 then
    raise exception 'Not enough liar match players';
  end if;

  select count(*)
  into v_not_ready_count
  from public.room_players player
  where player.room_id = p_room_id
    and coalesce(player.connection_status, 'active') = 'active'
    and player.is_ready is not true;

  if v_not_ready_count > 0 then
    raise exception 'Liar match player not ready';
  end if;

  if exists (
    select 1
    from public.games game
    where game.room_id = p_room_id
      and game.status not in ('finished', 'ended')
  ) then
    raise exception 'Liar match already started';
  end if;

  if not exists (
    select 1
    from private.liar_words word
    join public.liar_categories category on category.id = word.category_id
    where word.is_active
      and category.is_active
      and (v_settings.category_id is null or word.category_id = v_settings.category_id)
  ) then
    raise exception 'Active liar word required';
  end if;

  update public.rooms
  set
    status = 'starting',
    updated_at = now()
  where id = p_room_id;

  insert into public.games (
    room_id,
    status,
    phase,
    round_no,
    phase_started_at,
    phase_ends_at
  ) values (
    p_room_id,
    'playing',
    'discussion',
    0,
    now(),
    -- Keep the shared mafia timer dormant until the liar round RPCs advance it.
    now() + interval '100 years'
  )
  returning * into v_game;

  insert into public.liar_match_states (
    game_id,
    room_id,
    setting_mode,
    category_id,
    target_score,
    citizen_win_score,
    liar_win_score
  ) values (
    v_game.id,
    p_room_id,
    v_settings.setting_mode,
    v_settings.category_id,
    v_settings.target_score,
    v_settings.citizen_win_score,
    v_settings.liar_win_score
  );

  insert into public.liar_match_players (
    game_id,
    user_id,
    display_order
  )
  select
    v_game.id,
    player.user_id,
    row_number() over (order by player.joined_at, player.user_id)
  from public.room_players player
  where player.room_id = p_room_id
    and coalesce(player.connection_status, 'active') = 'active';

  insert into public.liar_scores (
    game_id,
    user_id,
    score
  )
  select
    player.game_id,
    player.user_id,
    0
  from public.liar_match_players player
  where player.game_id = v_game.id;

  perform private.start_liar_round(v_game.id);

  return private.build_current_liar_match(p_room_id);
exception
  when unique_violation then
    raise exception 'Liar match already started';
end;
$$;

create or replace function private.get_current_liar_match(p_room_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  return private.build_current_liar_match(p_room_id);
end;
$$;

create or replace function private.get_my_liar_state(p_room_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_game_id uuid;
  v_round public.liar_rounds;
  v_secret private.liar_round_secrets;
  v_word private.liar_words;
  v_category public.liar_categories;
  v_role text;
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
  limit 1;

  select *
  into v_secret
  from private.liar_round_secrets
  where round_id = v_round.id;

  select *
  into v_word
  from private.liar_words
  where id = v_secret.word_id;

  select *
  into v_category
  from public.liar_categories
  where id = v_word.category_id;

  v_role := case when v_secret.liar_user_id = v_user_id then 'liar' else 'citizen' end;

  return jsonb_build_object(
    'roundId', v_round.id,
    'roundNo', v_round.round_no,
    'role', v_role,
    'categoryId', v_category.id,
    'categoryLabel', v_category.label,
    'word', case when v_role = 'citizen' then v_word.word else null end
  );
end;
$$;

create or replace function private.submit_liar_vote(
  p_room_id uuid,
  p_target_user_id uuid
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
  v_room public.rooms;
  v_voter_name text;
  v_target_name text;
  v_vote_count integer;
  v_player_count integer;
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;

  v_game_id := private.get_liar_game_id_for_room(p_room_id);

  if v_game_id is null or not private.is_liar_match_player(v_game_id, v_user_id) then
    raise exception 'Liar match participant required';
  end if;

  if not private.is_liar_match_player(v_game_id, p_target_user_id) then
    raise exception 'Liar vote target must be a match player';
  end if;

  if v_user_id = p_target_user_id then
    raise exception 'Liar self vote is not allowed';
  end if;

  select *
  into v_round
  from public.liar_rounds
  where game_id = v_game_id
  order by round_no desc
  limit 1
  for update;

  if v_round.phase not in ('voting', 'revote') then
    raise exception 'Liar voting phase required';
  end if;

  if v_round.phase = 'revote'
    and not (p_target_user_id = any(private.get_liar_revote_candidate_ids(v_round.id)))
  then
    raise exception 'Liar revote candidate required';
  end if;

  insert into public.liar_votes (
    game_id,
    round_id,
    voter_id,
    target_id,
    vote_attempt_no
  ) values (
    v_game_id,
    v_round.id,
    v_user_id,
    p_target_user_id,
    v_round.vote_attempt_no
  );

  select coalesce(nickname, '알 수 없음')
  into v_voter_name
  from public.profiles
  where id = v_user_id;

  select coalesce(nickname, '알 수 없음')
  into v_target_name
  from public.profiles
  where id = p_target_user_id;

  select *
  into v_room
  from public.rooms
  where id = p_room_id;

  perform private.insert_liar_system_message(
    p_room_id,
    v_game_id,
    v_round.round_no,
    format(
      '%s%s님이 %s님에게 투표했습니다.',
      case when v_round.vote_attempt_no = 2 then '재투표: ' else '' end,
      coalesce(v_voter_name, '알 수 없음'),
      coalesce(v_target_name, '알 수 없음')
    ),
    format(
      'liar_vote_cast:%s:%s:%s',
      v_round.round_no,
      v_round.vote_attempt_no,
      v_user_id
    )
  );

  select count(*)
  into v_vote_count
  from public.liar_votes
  where round_id = v_round.id
    and vote_attempt_no = v_round.vote_attempt_no;

  select count(*)
  into v_player_count
  from public.liar_match_players
  where game_id = v_game_id;

  if v_vote_count >= v_player_count then
    perform private.resolve_liar_vote(v_round.id);
  end if;

  return private.build_current_liar_match(p_room_id);
exception
  when unique_violation then
    raise exception 'Liar vote already submitted';
end;
$$;

create or replace function private.resolve_liar_vote_for_room(p_room_id uuid)
returns jsonb
language plpgsql
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

  select id
  into v_round_id
  from public.liar_rounds
  where game_id = v_game_id
  order by round_no desc
  limit 1;

  perform private.resolve_liar_vote(v_round_id);

  return private.build_current_liar_match(p_room_id);
end;
$$;

create or replace function private.submit_liar_guess(
  p_room_id uuid,
  p_guess text
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
  v_secret private.liar_round_secrets;
  v_word private.liar_words;
  v_normalized_guess text;
  v_is_correct boolean;
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;

  if nullif(trim(coalesce(p_guess, '')), '') is null then
    raise exception 'Liar guess required';
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

  if v_round.phase <> 'liar_guess' then
    raise exception 'Liar guess phase required';
  end if;

  select *
  into v_secret
  from private.liar_round_secrets
  where round_id = v_round.id;

  if v_secret.liar_user_id <> v_user_id then
    raise exception 'Current liar only';
  end if;

  select *
  into v_word
  from private.liar_words
  where id = v_secret.word_id;

  v_normalized_guess := private.normalize_liar_word(p_guess);
  v_is_correct := v_normalized_guess = v_word.normalized_word;

  insert into private.liar_guesses (
    round_id,
    liar_user_id,
    guess_text,
    normalized_guess,
    is_correct
  ) values (
    v_round.id,
    v_user_id,
    trim(p_guess),
    v_normalized_guess,
    v_is_correct
  );

  if v_is_correct then
    perform private.finish_liar_round(
      v_round.id,
      'liar',
      'liar_guessed_word'
    );
  else
    perform private.finish_liar_round(
      v_round.id,
      'citizen',
      'liar_failed_guess'
    );
  end if;

  return private.build_current_liar_match(p_room_id);
exception
  when unique_violation then
    raise exception 'Liar guess already submitted';
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
    update public.liar_rounds
    set
      phase = 'discussion',
      phase_started_at = now(),
      updated_at = now()
    where id = v_round.id;

    perform private.insert_liar_system_message(
      p_room_id,
      v_game_id,
      v_round.round_no,
      '설명과 토론을 시작하세요.',
      format('liar_discussion_start:%s', v_round.round_no)
    );
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

create or replace function private.return_liar_room_to_lobby(p_room_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_game_id uuid;
  v_round public.liar_rounds;
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

  if v_round.phase <> 'match_result' then
    raise exception 'Liar match result phase required';
  end if;

  update public.games
  set
    status = 'finished',
    ended_at = coalesce(ended_at, now())
  where id = v_game_id;

  update public.rooms
  set
    status = 'waiting',
    phase = 'before_start',
    updated_at = now()
  where id = p_room_id;

  update public.room_players
  set
    is_ready = is_host,
    role = null,
    is_alive = true
  where room_id = p_room_id;

  return jsonb_build_object(
    'roomId', p_room_id,
    'gameId', v_game_id,
    'status', 'waiting'
  );
end;
$$;

create or replace function public.configure_liar_room(
  p_room_id uuid,
  p_setting_mode text default 'classic',
  p_category_id uuid default null,
  p_target_score integer default 5,
  p_citizen_win_score integer default 1,
  p_liar_win_score integer default 2
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.configure_liar_room(
    p_room_id,
    p_setting_mode,
    p_category_id,
    p_target_score,
    p_citizen_win_score,
    p_liar_win_score
  );
$$;

create or replace function public.start_liar_match(p_room_id uuid)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.start_liar_match(p_room_id);
$$;

create or replace function public.get_current_liar_match(p_room_id uuid)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select private.get_current_liar_match(p_room_id);
$$;

create or replace function public.get_my_liar_state(p_room_id uuid)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select private.get_my_liar_state(p_room_id);
$$;

create or replace function public.submit_liar_vote(
  p_room_id uuid,
  p_target_user_id uuid
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.submit_liar_vote(p_room_id, p_target_user_id);
$$;

create or replace function public.resolve_liar_vote(p_room_id uuid)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.resolve_liar_vote_for_room(p_room_id);
$$;

create or replace function public.submit_liar_guess(
  p_room_id uuid,
  p_guess text
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.submit_liar_guess(p_room_id, p_guess);
$$;

create or replace function public.advance_liar_phase(p_room_id uuid)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.advance_liar_phase(p_room_id);
$$;

create or replace function public.return_liar_room_to_lobby(p_room_id uuid)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.return_liar_room_to_lobby(p_room_id);
$$;

alter table public.liar_categories enable row level security;
alter table public.liar_room_settings enable row level security;
alter table public.liar_match_states enable row level security;
alter table public.liar_match_players enable row level security;
alter table public.liar_scores enable row level security;
alter table public.liar_rounds enable row level security;
alter table public.liar_votes enable row level security;
alter table private.liar_words enable row level security;
alter table private.liar_round_secrets enable row level security;
alter table private.liar_guesses enable row level security;

drop policy if exists liar_categories_authenticated_select
  on public.liar_categories;
create policy liar_categories_authenticated_select
  on public.liar_categories
  for select
  to authenticated
  using (is_active);

drop policy if exists liar_room_settings_participant_select
  on public.liar_room_settings;
create policy liar_room_settings_participant_select
  on public.liar_room_settings
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.room_players player
      where player.room_id = liar_room_settings.room_id
        and player.user_id = auth.uid()
    )
  );

drop policy if exists liar_match_states_participant_select
  on public.liar_match_states;
create policy liar_match_states_participant_select
  on public.liar_match_states
  for select
  to authenticated
  using (private.is_liar_match_player(game_id));

drop policy if exists liar_match_players_participant_select
  on public.liar_match_players;
create policy liar_match_players_participant_select
  on public.liar_match_players
  for select
  to authenticated
  using (private.is_liar_match_player(game_id));

drop policy if exists liar_scores_participant_select
  on public.liar_scores;
create policy liar_scores_participant_select
  on public.liar_scores
  for select
  to authenticated
  using (private.is_liar_match_player(game_id));

drop policy if exists liar_rounds_participant_select
  on public.liar_rounds;
create policy liar_rounds_participant_select
  on public.liar_rounds
  for select
  to authenticated
  using (private.is_liar_match_player(game_id));

drop policy if exists liar_votes_participant_select
  on public.liar_votes;
create policy liar_votes_participant_select
  on public.liar_votes
  for select
  to authenticated
  using (private.is_liar_match_player(game_id));

revoke all on table public.liar_categories from anon, authenticated;
revoke all on table public.liar_room_settings from anon, authenticated;
revoke all on table public.liar_match_states from anon, authenticated;
revoke all on table public.liar_match_players from anon, authenticated;
revoke all on table public.liar_scores from anon, authenticated;
revoke all on table public.liar_rounds from anon, authenticated;
revoke all on table public.liar_votes from anon, authenticated;

grant select on table public.liar_categories to authenticated;
grant select on table public.liar_room_settings to authenticated;
grant select on table public.liar_match_states to authenticated;
grant select on table public.liar_match_players to authenticated;
grant select on table public.liar_scores to authenticated;
grant select on table public.liar_rounds to authenticated;
grant select on table public.liar_votes to authenticated;

revoke all on table private.liar_words from public, anon, authenticated;
revoke all on table private.liar_round_secrets from public, anon, authenticated;
revoke all on table private.liar_guesses from public, anon, authenticated;

revoke all on all functions in schema private from public;

grant usage on schema private to authenticated;

revoke all on function private.is_liar_match_player(uuid, uuid) from public;
revoke all on function private.configure_liar_room(uuid, text, uuid, integer, integer, integer) from public;
revoke all on function private.start_liar_match(uuid) from public;
revoke all on function private.get_current_liar_match(uuid) from public;
revoke all on function private.get_my_liar_state(uuid) from public;
revoke all on function private.submit_liar_vote(uuid, uuid) from public;
revoke all on function private.resolve_liar_vote_for_room(uuid) from public;
revoke all on function private.submit_liar_guess(uuid, text) from public;
revoke all on function private.advance_liar_phase(uuid) from public;
revoke all on function private.return_liar_room_to_lobby(uuid) from public;

grant execute on function private.is_liar_match_player(uuid, uuid) to authenticated;
grant execute on function private.configure_liar_room(uuid, text, uuid, integer, integer, integer) to authenticated;
grant execute on function private.start_liar_match(uuid) to authenticated;
grant execute on function private.get_current_liar_match(uuid) to authenticated;
grant execute on function private.get_my_liar_state(uuid) to authenticated;
grant execute on function private.submit_liar_vote(uuid, uuid) to authenticated;
grant execute on function private.resolve_liar_vote_for_room(uuid) to authenticated;
grant execute on function private.submit_liar_guess(uuid, text) to authenticated;
grant execute on function private.advance_liar_phase(uuid) to authenticated;
grant execute on function private.return_liar_room_to_lobby(uuid) to authenticated;

revoke all on function public.configure_liar_room(uuid, text, uuid, integer, integer, integer) from public;
revoke all on function public.start_liar_match(uuid) from public;
revoke all on function public.get_current_liar_match(uuid) from public;
revoke all on function public.get_my_liar_state(uuid) from public;
revoke all on function public.submit_liar_vote(uuid, uuid) from public;
revoke all on function public.resolve_liar_vote(uuid) from public;
revoke all on function public.submit_liar_guess(uuid, text) from public;
revoke all on function public.advance_liar_phase(uuid) from public;
revoke all on function public.return_liar_room_to_lobby(uuid) from public;

grant execute on function public.configure_liar_room(uuid, text, uuid, integer, integer, integer) to authenticated;
grant execute on function public.start_liar_match(uuid) to authenticated;
grant execute on function public.get_current_liar_match(uuid) to authenticated;
grant execute on function public.get_my_liar_state(uuid) to authenticated;
grant execute on function public.submit_liar_vote(uuid, uuid) to authenticated;
grant execute on function public.resolve_liar_vote(uuid) to authenticated;
grant execute on function public.submit_liar_guess(uuid, text) to authenticated;
grant execute on function public.advance_liar_phase(uuid) to authenticated;
grant execute on function public.return_liar_room_to_lobby(uuid) to authenticated;

do $$
declare
  v_table_name text;
begin
  foreach v_table_name in array array[
    'liar_match_states',
    'liar_scores',
    'liar_rounds',
    'liar_votes'
  ]
  loop
    if not exists (
      select 1
      from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public'
        and tablename = v_table_name
    ) then
      execute format(
        'alter publication supabase_realtime add table public.%I',
        v_table_name
      );
    end if;
  end loop;
end;
$$;

commit;

notify pgrst, 'reload schema';
