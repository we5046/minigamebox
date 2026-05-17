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
  discussion_time_seconds integer not null default 60,
  min_start_players integer not null default 4,
  tie_vote_rule text not null default 'no_execution',
  dead_chat_enabled boolean not null default false,
  spectator_allowed boolean not null default false,
  host_auto_transfer boolean not null default true,
  afk_auto_handle boolean not null default false,
  first_night_ability_allowed boolean not null default true,
  final_defense_enabled boolean not null default false,
  role_reveal_mode text not null default 'private',
  entry_mode text not null default 'public',
  entry_password text not null default '',
  role_config jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

alter table public.rooms
  add column if not exists description text not null default '',
  add column if not exists updated_at timestamptz not null default now(),
  add column if not exists night_time_seconds integer not null default 30,
  add column if not exists vote_time_seconds integer not null default 15,
  add column if not exists discussion_time_seconds integer not null default 60,
  add column if not exists min_start_players integer not null default 4,
  add column if not exists tie_vote_rule text not null default 'no_execution',
  add column if not exists dead_chat_enabled boolean not null default false,
  add column if not exists spectator_allowed boolean not null default false,
  add column if not exists host_auto_transfer boolean not null default true,
  add column if not exists afk_auto_handle boolean not null default false,
  add column if not exists first_night_ability_allowed boolean not null default true,
  add column if not exists final_defense_enabled boolean not null default false,
  add column if not exists role_reveal_mode text not null default 'private',
  add column if not exists entry_mode text not null default 'public',
  add column if not exists entry_password text not null default '',
  add column if not exists role_config jsonb not null default '{}'::jsonb;

update public.rooms
set
  discussion_time_seconds = coalesce(discussion_time_seconds, 60),
  min_start_players = coalesce(min_start_players, 4),
  tie_vote_rule = coalesce(tie_vote_rule, 'no_execution'),
  dead_chat_enabled = coalesce(dead_chat_enabled, false),
  spectator_allowed = coalesce(spectator_allowed, false),
  host_auto_transfer = coalesce(host_auto_transfer, true),
  afk_auto_handle = coalesce(afk_auto_handle, false),
  first_night_ability_allowed = coalesce(first_night_ability_allowed, true),
  final_defense_enabled = coalesce(final_defense_enabled, false)
where
  discussion_time_seconds is null
  or min_start_players is null
  or tie_vote_rule is null
  or dead_chat_enabled is null
  or spectator_allowed is null
  or host_auto_transfer is null
  or afk_auto_handle is null
  or first_night_ability_allowed is null
  or final_defense_enabled is null;

create table if not exists public.room_players (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  is_host boolean not null default false,
  is_ready boolean not null default false,
  role text,
  is_alive boolean not null default true,
  joined_at timestamptz not null default now(),
  unique (room_id, user_id)
);

alter table public.room_players
  add column if not exists role text,
  add column if not exists is_alive boolean not null default true;

update public.room_players
set is_ready = true
where is_host is true
  and is_ready is not true;

alter table public.rooms replica identity full;
alter table public.room_players replica identity full;

create table if not exists public.games (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete cascade,
  status text not null default 'playing',
  phase text not null default 'role_reveal',
  round_no integer not null default 1,
  phase_started_at timestamptz not null default now(),
  phase_ends_at timestamptz not null default (now() + interval '5 seconds'),
  final_defense_target_user_id uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.games
  add column if not exists final_defense_target_user_id uuid references public.profiles(id) on delete set null;

drop index if exists games_one_active_per_room_idx;

create unique index if not exists games_one_active_per_room_idx
  on public.games (room_id)
  where status not in ('finished', 'ended');

alter table public.games replica identity full;

grant select on public.games to authenticated;

create table if not exists public.game_messages (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete cascade,
  game_id uuid references public.games(id) on delete cascade,
  round_no integer,
  user_id uuid references public.profiles(id) on delete set null,
  nickname text not null default 'System',
  content text not null,
  message_type text not null default 'chat',
  channel_type text not null default 'public',
  event_key text,
  is_system boolean not null default false,
  created_at timestamptz not null default now()
);

alter table public.game_messages
  add column if not exists round_no integer,
  add column if not exists message_type text not null default 'chat',
  add column if not exists channel_type text not null default 'public',
  add column if not exists event_key text;

update public.game_messages
set message_type = case when is_system is true then 'system' else 'chat' end
where message_type is null
   or message_type = '';

update public.game_messages
set channel_type = 'public'
where channel_type is null
   or channel_type = '';

alter table public.game_messages replica identity full;

create index if not exists game_messages_room_created_at_idx
  on public.game_messages (room_id, created_at);

create index if not exists game_messages_game_channel_created_at_idx
  on public.game_messages (game_id, channel_type, created_at);

create unique index if not exists game_messages_unique_system_event_idx
  on public.game_messages (game_id, round_no, event_key)
  where event_key is not null;

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

insert into storage.buckets (id, name, public, file_size_limit)
values ('game-logs', 'game-logs', false, 1048576)
on conflict (id) do update
set public = excluded.public,
    file_size_limit = excluded.file_size_limit;

drop policy if exists "room participants can upload ended game logs" on storage.objects;
drop policy if exists "room participants can read game logs" on storage.objects;

create policy "room participants can upload ended game logs"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'game-logs'
    and exists (
      select 1
      from public.games
      join public.room_players on room_players.room_id = games.room_id
      where games.room_id::text = (storage.foldername(name))[1]
        and games.id::text = replace(storage.filename(name), '.md', '')
        and games.status in ('finished', 'ended')
        and room_players.user_id = auth.uid()
    )
  );

create policy "room participants can read game logs"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'game-logs'
    and exists (
      select 1
      from public.room_players
      where room_players.room_id::text = (storage.foldername(name))[1]
        and room_players.user_id = auth.uid()
    )
  );

create table if not exists public.game_actions (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete cascade,
  game_id uuid not null references public.games(id) on delete cascade,
  round_no integer not null,
  actor_user_id uuid not null references public.profiles(id) on delete cascade,
  action_type text not null,
  target_user_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint game_actions_type_check check (action_type in ('mafia_kill', 'police_check', 'doctor_save')),
  unique (game_id, round_no, actor_user_id, action_type)
);

create index if not exists game_actions_game_round_idx
  on public.game_actions (game_id, round_no);

create table if not exists public.game_votes (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete cascade,
  game_id uuid not null references public.games(id) on delete cascade,
  round_no integer not null,
  voter_user_id uuid not null references public.profiles(id) on delete cascade,
  target_user_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (game_id, round_no, voter_user_id)
);

create index if not exists game_votes_game_round_idx
  on public.game_votes (game_id, round_no);

create table if not exists public.game_final_defense_votes (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete cascade,
  game_id uuid not null references public.games(id) on delete cascade,
  round_no integer not null,
  voter_user_id uuid not null references public.profiles(id) on delete cascade,
  approve_execution boolean not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (game_id, round_no, voter_user_id)
);

create index if not exists game_final_defense_votes_game_round_idx
  on public.game_final_defense_votes (game_id, round_no);

create table if not exists public.player_ranks (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  tier text not null default 'Unranked',
  rp integer not null default 0,
  top_percent integer not null default 100,
  emblem text not null default '-',
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

create unique index if not exists player_cosmetics_unique_label_idx
  on public.player_cosmetics (user_id, label);

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

