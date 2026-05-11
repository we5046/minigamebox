create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  login_id text not null unique,
  nickname text not null unique,
  character_name text not null default 'Rookie Mafia',
  level integer not null default 1,
  coin integer not null default 0,
  avatar text not null default 'default-mafia',
  representative_title text,
  profile_quote text,
  experience_percent integer not null default 0,
  created_at timestamptz not null default now()
);

alter table public.profiles
  add column if not exists representative_title text,
  add column if not exists profile_quote text,
  add column if not exists experience_percent integer not null default 0;

create table if not exists public.rooms (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  description text not null default '',
  code text not null unique,
  host_user_id uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'waiting',
  max_players integer not null default 8,
  phase text not null default 'before_start',
  night_time_seconds integer not null default 30,
  vote_time_seconds integer not null default 15,
  role_reveal_mode text not null default 'private',
  entry_mode text not null default 'public',
  updated_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

alter table public.rooms
  add column if not exists description text not null default '',
  add column if not exists updated_at timestamptz not null default now(),
  add column if not exists night_time_seconds integer not null default 30,
  add column if not exists vote_time_seconds integer not null default 15,
  add column if not exists role_reveal_mode text not null default 'private',
  add column if not exists entry_mode text not null default 'public';

create table if not exists public.room_players (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  is_host boolean not null default false,
  is_ready boolean not null default false,
  joined_at timestamptz not null default now(),
  unique (room_id, user_id)
);

alter table public.rooms replica identity full;
alter table public.room_players replica identity full;

create table if not exists public.player_ranks (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  tier text not null default 'Bronze II',
  rp integer not null default 0,
  top_percent integer not null default 100,
  emblem text not null default 'B',
  updated_at timestamptz not null default now()
);

create table if not exists public.player_stats (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  total_games integer not null default 0,
  overall_win_rate numeric not null default 0,
  citizen_win_rate numeric not null default 0,
  mafia_win_rate numeric not null default 0,
  survival_rate numeric not null default 0,
  average_survival_turn numeric not null default 0,
  updated_at timestamptz not null default now()
);

create table if not exists public.player_role_stats (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  role_name text not null,
  icon text not null default '?',
  games_played integer not null default 0,
  win_rate integer not null default 0,
  is_most_played boolean not null default false,
  unique (user_id, role_name)
);

create table if not exists public.player_recent_matches (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  role_name text not null,
  role_icon text not null default '?',
  won boolean not null default false,
  summary text not null default '',
  detail text not null default '',
  played_at timestamptz not null default now()
);

create table if not exists public.player_achievements (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  name text not null,
  icon text not null default '?',
  rarity text not null default 'Common',
  unlocked boolean not null default false,
  unlocked_at text not null default 'locked',
  description text not null default '',
  unique (user_id, name)
);

create table if not exists public.player_cosmetics (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  label text not null,
  value text not null,
  sort_order integer not null default 0
);

create table if not exists public.friendships (
  id uuid primary key default gen_random_uuid(),
  requester_user_id uuid not null constraint friendships_requester_user_id_fkey references public.profiles(id) on delete cascade,
  addressee_user_id uuid not null constraint friendships_addressee_user_id_fkey references public.profiles(id) on delete cascade,
  status text not null default 'pending',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint friendships_no_self check (requester_user_id <> addressee_user_id),
  constraint friendships_status_check check (status in ('pending', 'accepted', 'rejected', 'removed')),
  unique (requester_user_id, addressee_user_id)
);

alter table public.friendships
  drop constraint if exists friendships_status_check;

alter table public.friendships
  add constraint friendships_status_check check (status in ('pending', 'accepted', 'rejected', 'removed'));

create unique index if not exists friendships_unique_pair_idx
  on public.friendships (
    least(requester_user_id, addressee_user_id),
    greatest(requester_user_id, addressee_user_id)
  );

alter table public.friendships replica identity full;

create table if not exists public.room_invites (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete cascade,
  from_user_id uuid not null constraint room_invites_from_user_id_fkey references public.profiles(id) on delete cascade,
  to_user_id uuid not null constraint room_invites_to_user_id_fkey references public.profiles(id) on delete cascade,
  status text not null default 'pending',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '10 seconds'),
  constraint room_invites_no_self check (from_user_id <> to_user_id),
  constraint room_invites_status_check check (status in ('pending', 'accepted', 'rejected', 'expired'))
);

alter table public.room_invites
  drop constraint if exists room_invites_status_check;

alter table public.room_invites
  alter column expires_at set default (now() + interval '10 seconds');

alter table public.room_invites
  add constraint room_invites_status_check check (status in ('pending', 'accepted', 'rejected', 'expired'));

update public.room_invites
set expires_at = least(expires_at, updated_at + interval '10 seconds')
where status = 'pending';

create unique index if not exists room_invites_pending_unique_idx
  on public.room_invites (room_id, to_user_id)
  where status = 'pending';

alter table public.room_invites replica identity full;

alter table public.profiles enable row level security;
alter table public.rooms enable row level security;
alter table public.room_players enable row level security;
alter table public.player_ranks enable row level security;
alter table public.player_stats enable row level security;
alter table public.player_role_stats enable row level security;
alter table public.player_recent_matches enable row level security;
alter table public.player_achievements enable row level security;
alter table public.player_cosmetics enable row level security;
alter table public.friendships enable row level security;
alter table public.room_invites enable row level security;

drop policy if exists "profiles are readable by authenticated users" on public.profiles;
drop policy if exists "users can insert their own profile" on public.profiles;
drop policy if exists "users can update their own profile" on public.profiles;
drop policy if exists "rooms are readable by authenticated users" on public.rooms;
drop policy if exists "authenticated users can create rooms" on public.rooms;
drop policy if exists "room hosts can update rooms" on public.rooms;
drop policy if exists "room hosts can delete rooms" on public.rooms;
drop policy if exists "room players are readable by authenticated users" on public.room_players;
drop policy if exists "authenticated users can join as themselves" on public.room_players;
drop policy if exists "users can update their own room player row" on public.room_players;
drop policy if exists "room hosts can update players in their room" on public.room_players;
drop policy if exists "users can leave their own room" on public.room_players;
drop policy if exists "player ranks are readable by authenticated users" on public.player_ranks;
drop policy if exists "player stats are readable by authenticated users" on public.player_stats;
drop policy if exists "player role stats are readable by authenticated users" on public.player_role_stats;
drop policy if exists "player recent matches are readable by authenticated users" on public.player_recent_matches;
drop policy if exists "player achievements are readable by authenticated users" on public.player_achievements;
drop policy if exists "player cosmetics are readable by authenticated users" on public.player_cosmetics;
drop policy if exists "friendships are readable by participants" on public.friendships;
drop policy if exists "friendships can be deleted by participants" on public.friendships;
drop policy if exists "room invites are readable by participants" on public.room_invites;

create policy "profiles are readable by authenticated users"
  on public.profiles for select
  to authenticated
  using (true);

create policy "users can insert their own profile"
  on public.profiles for insert
  to authenticated
  with check (auth.uid() = id);

create policy "users can update their own profile"
  on public.profiles for update
  to authenticated
  using (auth.uid() = id)
  with check (auth.uid() = id);

create policy "rooms are readable by authenticated users"
  on public.rooms for select
  to authenticated
  using (true);

create policy "authenticated users can create rooms"
  on public.rooms for insert
  to authenticated
  with check (auth.uid() = host_user_id);

create policy "room hosts can update rooms"
  on public.rooms for update
  to authenticated
  using (auth.uid() = host_user_id)
  with check (auth.uid() = host_user_id);

create policy "room hosts can delete rooms"
  on public.rooms for delete
  to authenticated
  using (auth.uid() = host_user_id);

create policy "room players are readable by authenticated users"
  on public.room_players for select
  to authenticated
  using (true);

create policy "users can update their own room player row"
  on public.room_players for update
  to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create policy "room hosts can update players in their room"
  on public.room_players for update
  to authenticated
  using (
    exists (
      select 1
      from public.rooms
      where rooms.id = room_players.room_id
        and rooms.host_user_id = auth.uid()
    )
  )
  with check (
    exists (
      select 1
      from public.rooms
      where rooms.id = room_players.room_id
        and rooms.host_user_id = auth.uid()
    )
  );

create policy "users can leave their own room"
  on public.room_players for delete
  to authenticated
  using (auth.uid() = user_id);

create policy "player ranks are readable by authenticated users"
  on public.player_ranks for select
  to authenticated
  using (true);

create policy "player stats are readable by authenticated users"
  on public.player_stats for select
  to authenticated
  using (true);

create policy "player role stats are readable by authenticated users"
  on public.player_role_stats for select
  to authenticated
  using (true);

create policy "player recent matches are readable by authenticated users"
  on public.player_recent_matches for select
  to authenticated
  using (true);

create policy "player achievements are readable by authenticated users"
  on public.player_achievements for select
  to authenticated
  using (true);

create policy "player cosmetics are readable by authenticated users"
  on public.player_cosmetics for select
  to authenticated
  using (true);

create policy "friendships are readable by participants"
  on public.friendships for select
  to authenticated
  using (auth.uid() = requester_user_id or auth.uid() = addressee_user_id);

create policy "friendships can be deleted by participants"
  on public.friendships for delete
  to authenticated
  using (auth.uid() = requester_user_id or auth.uid() = addressee_user_id);

create policy "room invites are readable by participants"
  on public.room_invites for select
  to authenticated
  using (auth.uid() = from_user_id or auth.uid() = to_user_id);

create or replace function public.send_friend_request(p_target_nickname text)
returns public.friendships
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_target_id uuid;
  v_friendship public.friendships;
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;

  select id
    into v_target_id
  from public.profiles
  where lower(nickname) = lower(trim(p_target_nickname))
  limit 1;

  if v_target_id is null then
    raise exception 'Player not found';
  end if;

  if v_target_id = v_user_id then
    raise exception 'Cannot add yourself';
  end if;

  select *
    into v_friendship
  from public.friendships
  where (requester_user_id = v_user_id and addressee_user_id = v_target_id)
     or (requester_user_id = v_target_id and addressee_user_id = v_user_id)
  limit 1;

  if found then
    if v_friendship.status in ('rejected', 'removed') then
      update public.friendships
      set requester_user_id = v_user_id,
          addressee_user_id = v_target_id,
          status = 'pending',
          updated_at = now()
      where id = v_friendship.id
      returning * into v_friendship;
    end if;

    return v_friendship;
  end if;

  begin
    insert into public.friendships (
      requester_user_id,
      addressee_user_id,
      status
    ) values (
      v_user_id,
      v_target_id,
      'pending'
    ) returning * into v_friendship;
  exception
    when unique_violation then
      select *
        into v_friendship
      from public.friendships
      where (requester_user_id = v_user_id and addressee_user_id = v_target_id)
         or (requester_user_id = v_target_id and addressee_user_id = v_user_id)
      limit 1;
  end;

  return v_friendship;
end;
$$;

grant execute on function public.send_friend_request(text) to authenticated;

create or replace function public.respond_friend_request(
  p_friendship_id uuid,
  p_accept boolean
)
returns public.friendships
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_friendship public.friendships;
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;

  select *
    into v_friendship
  from public.friendships
  where id = p_friendship_id
  for update;

  if not found then
    raise exception 'Friend request not found';
  end if;

  if v_friendship.addressee_user_id <> v_user_id then
    raise exception 'Only the receiver can respond';
  end if;

  if v_friendship.status <> 'pending' then
    return v_friendship;
  end if;

  update public.friendships
  set status = case when p_accept then 'accepted' else 'rejected' end,
      updated_at = now()
  where id = p_friendship_id
  returning * into v_friendship;

  return v_friendship;
end;
$$;

grant execute on function public.respond_friend_request(uuid, boolean) to authenticated;

create or replace function public.remove_friend(p_friendship_id uuid)
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

  update public.friendships
  set status = 'removed',
      updated_at = now()
  where id = p_friendship_id
    and (requester_user_id = v_user_id or addressee_user_id = v_user_id);
end;
$$;

grant execute on function public.remove_friend(uuid) to authenticated;

create or replace function public.send_room_invite(
  p_room_id uuid,
  p_target_user_id uuid
)
returns public.room_invites
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_room public.rooms;
  v_invite public.room_invites;
  v_player_count integer := 0;
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;

  if v_user_id = p_target_user_id then
    raise exception 'Cannot invite yourself';
  end if;

  select *
    into v_room
  from public.rooms
  where id = p_room_id
  for update;

  if not found then
    raise exception 'Room not found';
  end if;

  if v_room.status <> 'waiting' then
    raise exception 'Room is not waiting';
  end if;

  if not exists (
    select 1
    from public.room_players
    where room_id = p_room_id
      and user_id = v_user_id
  ) then
    raise exception 'Only room players can invite';
  end if;

  if exists (
    select 1
    from public.room_players
    where room_id = p_room_id
      and user_id = p_target_user_id
  ) then
    raise exception 'Player is already in the room';
  end if;

  if not exists (
    select 1
    from public.friendships
    where status = 'accepted'
      and (
        (requester_user_id = v_user_id and addressee_user_id = p_target_user_id)
        or (requester_user_id = p_target_user_id and addressee_user_id = v_user_id)
      )
  ) then
    raise exception 'Only friends can be invited';
  end if;

  select count(*)
    into v_player_count
  from public.room_players
  where room_id = p_room_id;

  if v_player_count >= v_room.max_players then
    raise exception 'Room is full';
  end if;

  select *
    into v_invite
  from public.room_invites
  where room_id = p_room_id
    and to_user_id = p_target_user_id
    and status = 'pending'
  limit 1;

  if found then
    if v_invite.updated_at > now() - interval '10 seconds' then
      return v_invite;
    end if;

    update public.room_invites
    set from_user_id = v_user_id,
        updated_at = now(),
        expires_at = now() + interval '10 seconds'
    where id = v_invite.id
    returning * into v_invite;

    return v_invite;
  end if;

  insert into public.room_invites (
    room_id,
    from_user_id,
    to_user_id,
    status
  ) values (
    p_room_id,
    v_user_id,
    p_target_user_id,
    'pending'
  ) returning * into v_invite;

  return v_invite;
end;
$$;

grant execute on function public.send_room_invite(uuid, uuid) to authenticated;

create or replace function public.respond_room_invite(
  p_invite_id uuid,
  p_accept boolean
)
returns public.room_invites
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_invite public.room_invites;
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;

  select *
    into v_invite
  from public.room_invites
  where id = p_invite_id
  for update;

  if not found then
    raise exception 'Room invite not found';
  end if;

  if v_invite.to_user_id <> v_user_id then
    raise exception 'Only the receiver can respond';
  end if;

  if v_invite.status <> 'pending' then
    return v_invite;
  end if;

  if v_invite.expires_at < now() then
    update public.room_invites
    set status = 'expired',
        updated_at = now()
    where id = p_invite_id
    returning * into v_invite;

    return v_invite;
  end if;

  if p_accept then
    perform public.join_room(v_invite.room_id);
  end if;

  update public.room_invites
  set status = case when p_accept then 'accepted' else 'rejected' end,
      updated_at = now()
  where id = p_invite_id
  returning * into v_invite;

  return v_invite;
end;
$$;

grant execute on function public.respond_room_invite(uuid, boolean) to authenticated;

drop function if exists public.create_room(text, text, integer);

create or replace function public.create_room(
  p_title text,
  p_description text,
  p_max_players integer,
  p_night_time_seconds integer default 30,
  p_vote_time_seconds integer default 15,
  p_role_reveal_mode text default 'private',
  p_entry_mode text default 'public'
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

  if p_role_reveal_mode not in ('private', 'public') then
    raise exception 'Invalid role reveal mode';
  end if;

  if p_entry_mode not in ('public', 'private') then
    raise exception 'Invalid entry mode';
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
        max_players,
        status,
        phase,
        night_time_seconds,
        vote_time_seconds,
        role_reveal_mode,
        entry_mode
      ) values (
        trim(p_title),
        coalesce(trim(p_description), ''),
        v_code,
        v_user_id,
        p_max_players,
        'waiting',
        'before_start',
        p_night_time_seconds,
        p_vote_time_seconds,
        p_role_reveal_mode,
        p_entry_mode
      ) returning * into v_room;

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
    is_ready
  ) values (
    v_room.id,
    v_user_id,
    true,
    false
  );

  return v_room;
end;
$$;

grant execute on function public.create_room(text, text, integer, integer, integer, text, text) to authenticated;

create or replace function public.join_room(p_room_id uuid)
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
    return v_room;
  end if;

  if v_room.status <> 'waiting' then
    raise exception 'Room is not waiting';
  end if;

  select count(*)
    into v_player_count
  from public.room_players
  where room_id = p_room_id;

  if v_player_count >= v_room.max_players then
    raise exception 'Room is full';
  end if;

  insert into public.room_players (
    room_id,
    user_id,
    is_host,
    is_ready
  ) values (
    p_room_id,
    v_user_id,
    false,
    false
  );

  return v_room;
end;
$$;

grant execute on function public.join_room(uuid) to authenticated;

create or replace function public.leave_room(p_room_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_was_host boolean := false;
  v_next_host_user_id uuid;
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;

  select is_host
    into v_was_host
  from public.room_players
  where room_id = p_room_id
    and user_id = v_user_id;

  if not found then
    return;
  end if;

  delete from public.room_players
  where room_id = p_room_id
    and user_id = v_user_id;

  select user_id
    into v_next_host_user_id
  from public.room_players
  where room_id = p_room_id
  order by joined_at asc
  limit 1;

  if v_next_host_user_id is null then
    delete from public.rooms
    where id = p_room_id;
    return;
  end if;

  if v_was_host then
    update public.room_players
    set is_host = (user_id = v_next_host_user_id)
    where room_id = p_room_id;

    update public.rooms
    set host_user_id = v_next_host_user_id
    where id = p_room_id;
  end if;
end;
$$;

grant execute on function public.leave_room(uuid) to authenticated;

create or replace function public.touch_room_after_player_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_room_id uuid;
begin
  v_room_id := coalesce(new.room_id, old.room_id);

  if v_room_id is not null then
    update public.rooms
    set updated_at = now()
    where id = v_room_id;
  end if;

  return null;
end;
$$;

drop trigger if exists room_players_touch_room on public.room_players;

create trigger room_players_touch_room
after insert or update or delete on public.room_players
for each row
execute function public.touch_room_after_player_change();

do $$
begin
  alter publication supabase_realtime add table public.rooms;
exception
  when duplicate_object then null;
end;
$$;

do $$
begin
  alter publication supabase_realtime add table public.room_players;
exception
  when duplicate_object then null;
end;
$$;

do $$
begin
  alter publication supabase_realtime add table public.friendships;
exception
  when duplicate_object then null;
end;
$$;

do $$
begin
  alter publication supabase_realtime add table public.room_invites;
exception
  when duplicate_object then null;
end;
$$;

update public.profiles
set
  character_name = 'Lobby Master',
  level = 12,
  coin = 1200,
  avatar = 'default-mafia',
  representative_title = '침묵을 읽는 방장',
  profile_quote = '오늘 밤, 진실은 침묵하는 사람의 눈빛에 숨어 있다.',
  experience_percent = 68
where login_id = 'host';

insert into public.player_ranks (user_id, tier, rp, top_percent, emblem)
select id, 'Bronze II', 420, 72, 'B'
from public.profiles
where login_id = 'host'
on conflict (user_id) do update
set
  tier = excluded.tier,
  rp = excluded.rp,
  top_percent = excluded.top_percent,
  emblem = excluded.emblem,
  updated_at = now();

insert into public.player_stats (
  user_id,
  total_games,
  overall_win_rate,
  citizen_win_rate,
  mafia_win_rate,
  survival_rate,
  average_survival_turn
)
select id, 24, 58, 61, 50, 67, 4.2
from public.profiles
where login_id = 'host'
on conflict (user_id) do update
set
  total_games = excluded.total_games,
  overall_win_rate = excluded.overall_win_rate,
  citizen_win_rate = excluded.citizen_win_rate,
  mafia_win_rate = excluded.mafia_win_rate,
  survival_rate = excluded.survival_rate,
  average_survival_turn = excluded.average_survival_turn,
  updated_at = now();
