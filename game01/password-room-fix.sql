-- Apply after the base game schema and room-admin.sql.
-- Keeps private-room passwords hashed and schema-qualifies pgcrypto calls.

begin;

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

do $$
begin
  if to_regprocedure('extensions.gen_salt(text)') is null
    or to_regprocedure('extensions.crypt(text,text)') is null
  then
    raise exception 'pgcrypto must be enabled in the extensions schema';
  end if;
end;
$$;

-- Remove older room password triggers that called gen_salt without the
-- extensions schema. The fixed trigger is recreated below.
do $$
declare
  v_trigger record;
begin
  for v_trigger in
    select t.tgname
    from pg_trigger t
    join pg_proc p on p.oid = t.tgfoid
    where t.tgrelid = 'public.rooms'::regclass
      and not t.tgisinternal
      and t.tgname <> 'hash_room_entry_password'
      and pg_get_functiondef(p.oid) ilike '%gen_salt%'
  loop
    execute format(
      'drop trigger %I on public.rooms',
      v_trigger.tgname
    );
  end loop;
end;
$$;

create or replace function public.hash_room_entry_password()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.entry_mode = 'private' then
    if nullif(trim(coalesce(new.entry_password, '')), '') is null then
      raise exception 'Room password is required for private rooms';
    end if;

    if new.entry_password !~ '^\$2[aby]\$[0-9]{2}\$' then
      new.entry_password := extensions.crypt(
        trim(new.entry_password),
        extensions.gen_salt('bf')
      );
    end if;
  else
    new.entry_password := '';
  end if;

  return new;
end;
$$;

revoke all on function public.hash_room_entry_password() from public;

drop trigger if exists hash_room_entry_password
  on public.rooms;

create trigger hash_room_entry_password
  before insert or update of entry_mode, entry_password on public.rooms
  for each row
  execute function public.hash_room_entry_password();

create or replace function public.create_room(
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
set search_path = ''
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
        case
          when p_entry_mode = 'private' then
            extensions.crypt(trim(p_entry_password), extensions.gen_salt('bf'))
          else ''
        end,
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

create or replace function public.join_room(
  p_room_id uuid,
  p_entry_password text default '',
  p_bypass_password boolean default false
)
returns public.rooms
language plpgsql
security definer
set search_path = ''
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

    if v_room.entry_password ~ '^\$2[aby]\$[0-9]{2}\$' then
      if extensions.crypt(trim(p_entry_password), v_room.entry_password) <> v_room.entry_password then
        raise exception 'Invalid room password';
      end if;
    elsif trim(p_entry_password) <> coalesce(v_room.entry_password, '') then
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

-- Hash legacy plaintext values without exposing them to the browser.
update public.rooms
set
  entry_password = extensions.crypt(
    trim(entry_password),
    extensions.gen_salt('bf')
  )
where entry_mode = 'private'
  and nullif(trim(entry_password), '') is not null
  and entry_password !~ '^\$2[aby]\$[0-9]{2}\$';

update public.rooms
set entry_password = ''
where entry_mode <> 'private'
  and entry_password <> '';

do $$
begin
  if not exists (
    select 1
    from pg_trigger
    where tgrelid = 'public.rooms'::regclass
      and tgname = 'hash_room_entry_password'
      and not tgisinternal
  ) then
    raise exception 'room password hash trigger was not installed';
  end if;

  if position(
    'extensions.gen_salt' in pg_get_functiondef(
      'public.create_room(text,text,text,integer,integer,integer,integer,integer,text,boolean,boolean,text,text,text,jsonb)'::regprocedure
    )
  ) = 0 then
    raise exception 'create_room does not schema-qualify gen_salt';
  end if;

  if position(
    'extensions.crypt' in pg_get_functiondef(
      'public.join_room(uuid,text,boolean)'::regprocedure
    )
  ) = 0 then
    raise exception 'join_room does not schema-qualify crypt';
  end if;
end;
$$;

commit;

notify pgrst, 'reload schema';
