create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  login_id text not null unique,
  nickname text not null unique,
  character_name text not null default 'Rookie Mafia',
  level integer not null default 1,
  coin integer not null default 0,
  avatar text not null default 'default-mafia',
  created_at timestamptz not null default now()
);

create table if not exists public.rooms (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  description text not null default '',
  code text not null unique,
  host_user_id uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'waiting',
  max_players integer not null default 8,
  phase text not null default '시작 전',
  created_at timestamptz not null default now()
);

alter table public.rooms
  add column if not exists description text not null default '';

create table if not exists public.room_players (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  is_host boolean not null default false,
  is_ready boolean not null default false,
  joined_at timestamptz not null default now(),
  unique (room_id, user_id)
);

alter table public.profiles enable row level security;
alter table public.rooms enable row level security;
alter table public.room_players enable row level security;

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

create policy "authenticated users can join as themselves"
  on public.room_players for insert
  to authenticated
  with check (auth.uid() = user_id);

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

alter publication supabase_realtime add table public.rooms;
alter publication supabase_realtime add table public.room_players;

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
