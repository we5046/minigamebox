-- Apply this file after the base rooms and room_players tables exist.
-- It keeps one create_room signature that matches src/api/roomApi.js.

begin;

alter table public.rooms
  add column if not exists game_type text not null default 'mafia';

alter table public.profiles
  add column if not exists level integer not null default 1,
  add column if not exists experience integer not null default 0,
  add column if not exists experience_percent integer not null default 0,
  add column if not exists coin integer not null default 0;

alter table public.room_players
  add column if not exists connection_status text not null default 'active',
  add column if not exists last_seen_at timestamptz not null default now(),
  add column if not exists disconnected_at timestamptz;

-- Realtime UPDATE payloads need the previous values so the client can ignore
-- last_seen_at-only heartbeats without skipping visible player-state changes.
alter table public.room_players replica identity full;

-- Remove historical overloads. Default arguments made PostgREST unable to
-- choose between the legacy 17-argument function and the current function.
drop function if exists public.create_room(text, text, integer);
drop function if exists public.create_room(text, text, integer, integer, integer, text, text);
drop function if exists public.create_room(text, text, integer, integer, integer, text, text, jsonb);
drop function if exists public.create_room(text, text, integer, integer, integer, text, text, text, jsonb);
drop function if exists public.create_room(text, text, integer, integer, integer, integer, integer, text, boolean, boolean, boolean, boolean, boolean, text, text, text, jsonb);
drop function if exists public.create_room(text, text, integer, integer, integer, integer, integer, text, boolean, boolean, text, text, text, jsonb);
drop function if exists public.create_room(text, text, text, integer, integer, integer, integer, integer, text, boolean, boolean, text, text, text, jsonb);

create function public.create_room(
  p_title text,
  p_description text,
  p_game_type text,
  p_max_players integer,
  p_night_time_seconds integer,
  p_vote_time_seconds integer,
  p_discussion_time_seconds integer,
  p_min_start_players integer,
  p_tie_vote_rule text,
  p_spectator_allowed boolean,
  p_first_night_ability_allowed boolean,
  p_role_reveal_mode text,
  p_entry_mode text,
  p_entry_password text,
  p_role_config jsonb
)
returns public.rooms
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_room public.rooms;
  v_code text;
  v_attempts integer := 0;
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;

  if nullif(trim(p_title), '') is null then
    raise exception 'Room title is required';
  end if;

  if nullif(trim(p_game_type), '') is null then
    raise exception 'Game type is required';
  end if;

  if p_max_players is null or p_max_players < 2 or p_max_players > 12 then
    raise exception 'Room max players must be between 2 and 12';
  end if;

  if p_night_time_seconds is null or p_night_time_seconds < 10 or p_night_time_seconds > 120 then
    raise exception 'Night time must be between 10 and 120 seconds';
  end if;

  if p_vote_time_seconds is null or p_vote_time_seconds < 10 or p_vote_time_seconds > 90 then
    raise exception 'Vote time must be between 10 and 90 seconds';
  end if;

  if p_discussion_time_seconds is null or p_discussion_time_seconds < 30 or p_discussion_time_seconds > 180 then
    raise exception 'Discussion time must be between 30 and 180 seconds';
  end if;

  if p_min_start_players is null or p_min_start_players < 2 or p_min_start_players > p_max_players then
    raise exception 'Minimum start players must be between 2 and the room max players';
  end if;

  if p_role_reveal_mode not in ('private', 'public') then
    raise exception 'Invalid role reveal mode';
  end if;

  if p_entry_mode not in ('public', 'private') then
    raise exception 'Invalid entry mode';
  end if;

  if p_entry_mode = 'private' and nullif(trim(p_entry_password), '') is null then
    raise exception 'Room password is required for private rooms';
  end if;

  loop
    v_attempts := v_attempts + 1;
    v_code := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));

    begin
      insert into public.rooms (
        title,
        description,
        game_type,
        code,
        host_user_id,
        status,
        max_players,
        phase,
        night_time_seconds,
        vote_time_seconds,
        discussion_time_seconds,
        min_start_players,
        tie_vote_rule,
        spectator_allowed,
        first_night_ability_allowed,
        role_reveal_mode,
        entry_mode,
        entry_password,
        role_config
      ) values (
        trim(p_title),
        coalesce(trim(p_description), ''),
        trim(p_game_type),
        v_code,
        v_user_id,
        'waiting',
        p_max_players,
        'before_start',
        p_night_time_seconds,
        p_vote_time_seconds,
        p_discussion_time_seconds,
        p_min_start_players,
        coalesce(nullif(trim(p_tie_vote_rule), ''), 'no_execution'),
        coalesce(p_spectator_allowed, false),
        coalesce(p_first_night_ability_allowed, true),
        p_role_reveal_mode,
        p_entry_mode,
        case when p_entry_mode = 'private' then trim(p_entry_password) else '' end,
        coalesce(p_role_config, '{}'::jsonb)
      )
      returning * into v_room;

      exit;
    exception
      when unique_violation then
        if v_attempts >= 5 then
          raise;
        end if;
    end;
  end loop;

  insert into public.room_players (
    room_id,
    user_id,
    is_host,
    is_ready,
    connection_status,
    last_seen_at,
    disconnected_at
  ) values (
    v_room.id,
    v_user_id,
    true,
    true,
    'active',
    now(),
    null
  );

  return v_room;
end;
$$;

revoke all on function public.create_room(text, text, text, integer, integer, integer, integer, integer, text, boolean, boolean, text, text, text, jsonb) from public;
grant execute on function public.create_room(text, text, text, integer, integer, integer, integer, integer, text, boolean, boolean, text, text, text, jsonb) to authenticated;

-- DROP is required here because PostgreSQL cannot change an existing
-- function's return type with CREATE OR REPLACE FUNCTION.
drop function if exists public.join_room(uuid, text, boolean);

create function public.join_room(
  p_room_id uuid,
  p_entry_password text default '',
  p_bypass_password boolean default false
)
returns public.rooms
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_room public.rooms;
  v_player_count integer := 0;
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;

  select *
    into v_room
  from public.rooms
  where id = p_room_id
  for update;

  if not found then
    raise exception 'Room not found';
  end if;

  if exists (
    select 1
    from public.room_players
    where room_id = p_room_id
      and user_id = v_user_id
  ) then
    update public.room_players
    set
      connection_status = 'active',
      last_seen_at = now(),
      disconnected_at = null
    where room_id = p_room_id
      and user_id = v_user_id;

    return v_room;
  end if;

  if v_room.status <> 'waiting' then
    raise exception 'Room is not waiting';
  end if;

  if v_room.entry_mode = 'private' and not coalesce(p_bypass_password, false) then
    if nullif(trim(coalesce(p_entry_password, '')), '') is null then
      raise exception 'Room password is required';
    end if;

    if trim(coalesce(p_entry_password, '')) <> coalesce(v_room.entry_password, '') then
      raise exception 'Invalid room password';
    end if;
  end if;

  select count(*)
    into v_player_count
  from public.room_players
  where room_id = p_room_id
    and connection_status = 'active';

  if v_player_count >= v_room.max_players then
    raise exception 'Room is full';
  end if;

  insert into public.room_players (
    room_id,
    user_id,
    is_host,
    is_ready,
    connection_status,
    last_seen_at,
    disconnected_at
  ) values (
    p_room_id,
    v_user_id,
    false,
    false,
    'active',
    now(),
    null
  );

  return v_room;
end;
$$;

revoke all on function public.join_room(uuid, text, boolean) from public;
grant execute on function public.join_room(uuid, text, boolean) to authenticated;

create or replace function public.leave_room(p_room_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_room_status text;
  v_was_host boolean := false;
  v_next_host_user_id uuid;
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;

  select status
    into v_room_status
  from public.rooms
  where id = p_room_id
  for update;

  if not found then
    return;
  end if;

  select is_host
    into v_was_host
  from public.room_players
  where room_id = p_room_id
    and user_id = v_user_id;

  if not found then
    return;
  end if;

  if v_room_status <> 'waiting' then
    update public.room_players
    set
      connection_status = 'disconnected',
      disconnected_at = now(),
      last_seen_at = now()
    where room_id = p_room_id
      and user_id = v_user_id;

    return;
  end if;

  delete from public.room_players
  where room_id = p_room_id
    and user_id = v_user_id;

  select user_id
    into v_next_host_user_id
  from public.room_players
  where room_id = p_room_id
    and connection_status = 'active'
  order by joined_at asc
  limit 1;

  if v_next_host_user_id is null then
    delete from public.rooms
    where id = p_room_id;

    return;
  end if;

  if v_was_host then
    update public.room_players
    set
      is_host = (user_id = v_next_host_user_id),
      is_ready = case when user_id = v_next_host_user_id then true else is_ready end
    where room_id = p_room_id;

    update public.rooms
    set
      host_user_id = v_next_host_user_id,
      updated_at = now()
    where id = p_room_id;
  end if;
end;
$$;

revoke all on function public.leave_room(uuid) from public;
grant execute on function public.leave_room(uuid) to authenticated;

drop function if exists public.heartbeat_room_presence(uuid);

create function public.heartbeat_room_presence(p_room_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;

  update public.room_players
  set
    connection_status = 'active',
    last_seen_at = now(),
    disconnected_at = null
  where room_id = p_room_id
    and user_id = v_user_id;

  if not found then
    raise exception 'Room participant required';
  end if;
end;
$$;

revoke all on function public.heartbeat_room_presence(uuid) from public;
grant execute on function public.heartbeat_room_presence(uuid) to authenticated;

drop function if exists public.cleanup_stale_room_players(integer, integer);

create function public.cleanup_stale_room_players(
  p_waiting_stale_after_seconds integer default 25,
  p_game_stale_after_seconds integer default 50
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_affected_count integer := 0;
  v_step_count integer := 0;
  v_room record;
  v_next_host_user_id uuid;
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;

  delete from public.room_players rp
  using public.rooms r
  where r.id = rp.room_id
    and r.status = 'waiting'
    and coalesce(rp.last_seen_at, rp.joined_at) <
      now() - make_interval(secs => greatest(coalesce(p_waiting_stale_after_seconds, 25), 1));

  get diagnostics v_step_count = row_count;
  v_affected_count := v_affected_count + v_step_count;

  update public.room_players rp
  set
    connection_status = 'disconnected',
    disconnected_at = coalesce(rp.disconnected_at, now())
  from public.rooms r
  where r.id = rp.room_id
    and r.status <> 'waiting'
    and rp.connection_status = 'active'
    and coalesce(rp.last_seen_at, rp.joined_at) <
      now() - make_interval(secs => greatest(coalesce(p_game_stale_after_seconds, 50), 1));

  get diagnostics v_step_count = row_count;
  v_affected_count := v_affected_count + v_step_count;

  delete from public.rooms r
  where r.status = 'waiting'
    and not exists (
      select 1
      from public.room_players rp
      where rp.room_id = r.id
    );

  get diagnostics v_step_count = row_count;
  v_affected_count := v_affected_count + v_step_count;

  for v_room in
    select r.id
    from public.rooms r
    where r.status = 'waiting'
      and not exists (
        select 1
        from public.room_players rp
        where rp.room_id = r.id
          and rp.user_id = r.host_user_id
      )
  loop
    select rp.user_id
      into v_next_host_user_id
    from public.room_players rp
    where rp.room_id = v_room.id
    order by rp.joined_at asc
    limit 1;

    if v_next_host_user_id is not null then
      update public.room_players
      set
        is_host = (user_id = v_next_host_user_id),
        is_ready = case when user_id = v_next_host_user_id then true else is_ready end
      where room_id = v_room.id;

      update public.rooms
      set
        host_user_id = v_next_host_user_id,
        updated_at = now()
      where id = v_room.id;
    end if;
  end loop;

  return v_affected_count;
end;
$$;

revoke all on function public.cleanup_stale_room_players(integer, integer) from public;
grant execute on function public.cleanup_stale_room_players(integer, integer) to authenticated;

drop function if exists public.get_visible_team_members(uuid);

create function public.get_visible_team_members(p_room_id uuid)
returns table (
  user_id uuid,
  team_role text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_team_role text;
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;

  select role
    into v_team_role
  from public.room_players
  where room_id = p_room_id
    and user_id = v_user_id;

  if v_team_role not in ('mafia', 'police') then
    return;
  end if;

  return query
  select rp.user_id, rp.role::text
  from public.room_players rp
  join public.rooms r on r.id = rp.room_id
  where rp.room_id = p_room_id
    and rp.role = v_team_role
    and r.status = 'playing';
end;
$$;

revoke all on function public.get_visible_team_members(uuid) from public;
grant execute on function public.get_visible_team_members(uuid) to authenticated;

create table if not exists public.game_rewards (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references public.games(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  exp_amount integer not null default 0,
  coin_amount integer not null default 0,
  reason jsonb not null default '[]'::jsonb,
  old_level integer not null,
  new_level integer not null,
  old_experience integer not null,
  new_experience integer not null,
  experience_percent integer not null,
  created_at timestamptz not null default now(),
  constraint unique_game_user_reward unique (game_id, user_id)
);

alter table public.game_rewards enable row level security;

revoke all on table public.game_rewards from public;
grant select on table public.game_rewards to authenticated;

drop policy if exists "players can read own game rewards" on public.game_rewards;

create policy "players can read own game rewards"
  on public.game_rewards for select
  to authenticated
  using (user_id = auth.uid());

drop function if exists public.award_game_rewards(uuid);

create function public.award_game_rewards(p_game_id uuid)
returns table (
  user_id uuid,
  nickname text,
  exp_gained integer,
  coin_gained integer,
  old_level integer,
  new_level integer,
  old_experience integer,
  new_experience integer,
  experience_percent integer,
  reasons jsonb
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_request_user_id uuid := auth.uid();
  v_game public.games;
  v_player record;
  v_profile public.profiles;
  v_reward_id uuid;
  v_exp_amount integer;
  v_coin_amount integer;
  v_reasons jsonb;
  v_old_level integer;
  v_new_level integer;
  v_old_experience integer;
  v_new_experience integer;
  v_required_exp integer;
  v_experience_percent integer;
begin
  if v_request_user_id is null and pg_trigger_depth() = 0 then
    raise exception 'Not authenticated';
  end if;

  select *
    into v_game
  from public.games
  where id = p_game_id
  for update;

  if not found then
    raise exception 'Game not found';
  end if;

  if v_game.status not in ('ended', 'finished') then
    raise exception 'Game is not finished';
  end if;

  if pg_trigger_depth() = 0 and not exists (
    select 1
    from public.game_result_players grp
    where grp.game_id = p_game_id
      and grp.user_id = v_request_user_id
  ) then
    raise exception 'Game participant required';
  end if;

  -- Keep eligibility rules here so minimum-round and disconnect handling can
  -- be tightened later without allowing the browser to decide rewards.
  for v_player in
    select grp.user_id, grp.is_winner, grp.is_alive
    from public.game_result_players grp
    where grp.game_id = p_game_id
  loop
    v_exp_amount := 20;
    v_coin_amount := 5;
    v_reasons := jsonb_build_array('참가 보상');

    if v_player.is_winner is true then
      v_exp_amount := v_exp_amount + 40;
      v_coin_amount := v_coin_amount + 15;
      v_reasons := v_reasons || jsonb_build_array('승리 보상');
    end if;

    if v_player.is_alive is true then
      v_exp_amount := v_exp_amount + 20;
      v_coin_amount := v_coin_amount + 5;
      v_reasons := v_reasons || jsonb_build_array('생존 보상');
    end if;

    v_exp_amount := least(v_exp_amount, 100);
    v_coin_amount := least(v_coin_amount, 30);

    select *
      into v_profile
    from public.profiles
    where id = v_player.user_id
    for update;

    if not found then
      continue;
    end if;

    v_old_level := greatest(coalesce(v_profile.level, 1), 1);
    v_new_level := v_old_level;
    v_old_experience := greatest(coalesce(v_profile.experience, 0), 0);
    v_new_experience := v_old_experience + v_exp_amount;

    loop
      v_required_exp := 100 + ((v_new_level - 1) * 50);
      exit when v_new_experience < v_required_exp;

      v_new_experience := v_new_experience - v_required_exp;
      v_new_level := v_new_level + 1;
    end loop;

    v_required_exp := 100 + ((v_new_level - 1) * 50);
    v_experience_percent := least(
      floor((v_new_experience::numeric / v_required_exp::numeric) * 100)::integer,
      100
    );
    v_reward_id := null;

    insert into public.game_rewards (
      game_id,
      user_id,
      exp_amount,
      coin_amount,
      reason,
      old_level,
      new_level,
      old_experience,
      new_experience,
      experience_percent
    ) values (
      p_game_id,
      v_player.user_id,
      v_exp_amount,
      v_coin_amount,
      v_reasons,
      v_old_level,
      v_new_level,
      v_old_experience,
      v_new_experience,
      v_experience_percent
    )
    on conflict (game_id, user_id) do nothing
    returning id into v_reward_id;

    if v_reward_id is not null then
      update public.profiles
      set
        level = v_new_level,
        experience = v_new_experience,
        experience_percent = v_experience_percent,
        coin = greatest(coalesce(coin, 0), 0) + v_coin_amount
      where id = v_player.user_id;
    end if;
  end loop;

  return query
  select
    gr.user_id,
    coalesce(p.nickname, 'GuestPlayer'),
    gr.exp_amount,
    gr.coin_amount,
    gr.old_level,
    gr.new_level,
    gr.old_experience,
    gr.new_experience,
    gr.experience_percent,
    gr.reason
  from public.game_rewards gr
  join public.profiles p on p.id = gr.user_id
  where gr.game_id = p_game_id
  order by gr.created_at asc;
end;
$$;

revoke all on function public.award_game_rewards(uuid) from public;
grant execute on function public.award_game_rewards(uuid) to authenticated;

create or replace function public.award_inserted_game_result_rewards()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if exists (
    select 1
    from public.games
    where id = new.game_id
      and status in ('ended', 'finished')
  ) then
    perform public.award_game_rewards(new.game_id);
  end if;

  return new;
end;
$$;

revoke all on function public.award_inserted_game_result_rewards() from public;

drop trigger if exists award_inserted_game_result_rewards
  on public.game_result_players;

create trigger award_inserted_game_result_rewards
  after insert on public.game_result_players
  for each row
  execute function public.award_inserted_game_result_rewards();

create or replace function public.award_ended_game_rewards()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status in ('ended', 'finished')
    and old.status is distinct from new.status
    and exists (
      select 1
      from public.game_result_players
      where game_id = new.id
    )
  then
    perform public.award_game_rewards(new.id);
  end if;

  return new;
end;
$$;

revoke all on function public.award_ended_game_rewards() from public;

drop trigger if exists award_ended_game_rewards
  on public.games;

create trigger award_ended_game_rewards
  after update of status on public.games
  for each row
  execute function public.award_ended_game_rewards();

grant select, insert on public.game_messages to authenticated;

alter table public.game_messages enable row level security;

drop policy if exists "room participants can read game messages" on public.game_messages;
drop policy if exists "eligible players can send game messages" on public.game_messages;

create policy "room participants can read game messages"
  on public.game_messages for select
  to authenticated
  using (
    exists (
      select 1
      from public.room_players
      where room_players.room_id = game_messages.room_id
        and room_players.user_id = auth.uid()
        and (
          game_messages.is_system is true
          or coalesce(game_messages.channel_type, 'public') = 'public'
          or (
            coalesce(game_messages.channel_type, 'public') = 'mafia'
            and (
              room_players.role = 'mafia'
              or room_players.is_alive is false
            )
          )
          or (
            coalesce(game_messages.channel_type, 'public') = 'police'
            and (
              room_players.role = 'police'
              or room_players.is_alive is false
            )
          )
          or (
            coalesce(game_messages.channel_type, 'public') = 'dead'
            and room_players.is_alive is false
          )
        )
    )
  );

create policy "eligible players can send game messages"
  on public.game_messages for insert
  to authenticated
  with check (
    user_id = auth.uid()
    and message_type = 'chat'
    and is_system is false
    and event_key is null
    and coalesce(channel_type, 'public') in ('public', 'mafia', 'police', 'dead')
    and exists (
      select 1
      from public.room_players
      where room_players.room_id = game_messages.room_id
        and room_players.user_id = auth.uid()
        and (
          (
            coalesce(game_messages.channel_type, 'public') = 'dead'
            and room_players.is_alive is false
          )
          or (
            room_players.is_alive is true
            and (
              coalesce(game_messages.channel_type, 'public') = 'public'
              or (
                coalesce(game_messages.channel_type, 'public') = 'mafia'
                and room_players.role = 'mafia'
              )
              or (
                coalesce(game_messages.channel_type, 'public') = 'police'
                and room_players.role = 'police'
              )
            )
          )
        )
    )
    and exists (
      select 1
      from public.games
      where games.id = game_messages.game_id
        and games.room_id = game_messages.room_id
        and games.status = 'playing'
        and (
          (
            coalesce(game_messages.channel_type, 'public') = 'public'
            and games.phase in ('day', 'discussion', 'vote', 'final_defense')
            and (
              games.phase <> 'final_defense'
              or games.final_defense_target_user_id = auth.uid()
            )
          )
          or (
            coalesce(game_messages.channel_type, 'public') in ('mafia', 'police')
            and games.phase = 'night'
          )
          or coalesce(game_messages.channel_type, 'public') = 'dead'
        )
    )
  );

do $$
declare
  v_table_name text;
begin
  foreach v_table_name in array array[
    'rooms',
    'room_players',
    'games',
    'game_messages',
    'game_rewards',
    'profiles',
    'player_stats',
    'player_role_stats',
    'player_recent_matches',
    'player_achievements',
    'player_cosmetics'
  ]
  loop
    if to_regclass(format('public.%I', v_table_name)) is not null
      and not exists (
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
