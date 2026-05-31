-- Apply this file after the base rooms and room_players tables exist.
-- It keeps one create_room signature that matches src/api/roomApi.js.

begin;

alter table public.room_players
  add column if not exists connection_status text not null default 'active',
  add column if not exists last_seen_at timestamptz not null default now(),
  add column if not exists disconnected_at timestamptz;

-- Remove historical overloads. Default arguments made PostgREST unable to
-- choose between the legacy 17-argument function and the current function.
drop function if exists public.create_room(text, text, integer);
drop function if exists public.create_room(text, text, integer, integer, integer, text, text);
drop function if exists public.create_room(text, text, integer, integer, integer, text, text, jsonb);
drop function if exists public.create_room(text, text, integer, integer, integer, text, text, text, jsonb);
drop function if exists public.create_room(text, text, integer, integer, integer, integer, integer, text, boolean, boolean, boolean, boolean, boolean, text, text, text, jsonb);
drop function if exists public.create_room(text, text, integer, integer, integer, integer, integer, text, boolean, boolean, text, text, text, jsonb);

create function public.create_room(
  p_title text,
  p_description text,
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

revoke all on function public.create_room(text, text, integer, integer, integer, integer, integer, text, boolean, boolean, text, text, text, jsonb) from public;
grant execute on function public.create_room(text, text, integer, integer, integer, integer, integer, text, boolean, boolean, text, text, text, jsonb) to authenticated;

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
            and room_players.role = 'mafia'
          )
          or (
            coalesce(game_messages.channel_type, 'public') = 'police'
            and room_players.role = 'police'
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
    and coalesce(channel_type, 'public') in ('public', 'mafia', 'police')
    and exists (
      select 1
      from public.room_players
      where room_players.room_id = game_messages.room_id
        and room_players.user_id = auth.uid()
        and room_players.is_alive is true
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
        )
    )
  );

do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'games'
  ) then
    alter publication supabase_realtime add table public.games;
  end if;
end;
$$;

commit;

notify pgrst, 'reload schema';
