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

alter table public.profiles
  add column if not exists representative_title text,
  add column if not exists profile_quote text,
  add column if not exists experience_percent integer not null default 0;

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
  unlocked_at text not null default '잠김',
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

alter table public.profiles enable row level security;
alter table public.rooms enable row level security;
alter table public.room_players enable row level security;
alter table public.player_ranks enable row level security;
alter table public.player_stats enable row level security;
alter table public.player_role_stats enable row level security;
alter table public.player_recent_matches enable row level security;
alter table public.player_achievements enable row level security;
alter table public.player_cosmetics enable row level security;

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

 c r e a t e   o r   r e p l a c e   f u n c t i o n   p u b l i c . c r e a t e _ r o o m ( 
     p _ t i t l e   t e x t , 
     p _ d e s c r i p t i o n   t e x t , 
     p _ m a x _ p l a y e r s   i n t e g e r 
 ) 
 r e t u r n s   p u b l i c . r o o m s 
 l a n g u a g e   p l p g s q l 
 s e c u r i t y   d e f i n e r 
 s e t   s e a r c h _ p a t h   =   p u b l i c 
 a s   \ $ \ $ 
 d e c l a r e 
     v _ u s e r _ i d   u u i d   : =   a u t h . u i d ( ) ; 
     v _ r o o m   p u b l i c . r o o m s ; 
     v _ c o d e   t e x t ; 
 b e g i n 
     i f   v _ u s e r _ i d   i s   n u l l   t h e n 
         r a i s e   e x c e p t i o n   ' N o t   a u t h e n t i c a t e d ' ; 
     e n d   i f ; 
 
     v _ c o d e   : =   ' R O O M - '   | |   s u b s t r i n g ( c a s t ( e x t r a c t ( e p o c h   f r o m   n o w ( ) )   *   1 0 0 0   a s   t e x t )   f r o m   8 ) ; 
 
     i n s e r t   i n t o   p u b l i c . r o o m s   ( 
         t i t l e , 
         d e s c r i p t i o n , 
         c o d e , 
         h o s t _ u s e r _ i d , 
         m a x _ p l a y e r s , 
         s t a t u s , 
         p h a s e 
     )   v a l u e s   ( 
         p _ t i t l e , 
         p _ d e s c r i p t i o n , 
         v _ c o d e , 
         v _ u s e r _ i d , 
         p _ m a x _ p l a y e r s , 
         ' w a i t i n g ' , 
         ' ��  �' 
     )   r e t u r n i n g   *   i n t o   v _ r o o m ; 
 
     i n s e r t   i n t o   p u b l i c . r o o m _ p l a y e r s   ( 
         r o o m _ i d , 
         u s e r _ i d , 
         i s _ h o s t , 
         i s _ r e a d y 
     )   v a l u e s   ( 
         v _ r o o m . i d , 
         v _ u s e r _ i d , 
         t r u e , 
         f a l s e 
     ) ; 
 
     r e t u r n   v _ r o o m ; 
 e n d ; 
 \ $ \ $ ; 
 
 g r a n t   e x e c u t e   o n   f u n c t i o n   p u b l i c . c r e a t e _ r o o m ( t e x t ,   t e x t ,   i n t e g e r )   t o   a u t h e n t i c a t e d ; 
  
 