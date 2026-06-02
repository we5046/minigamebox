-- Apply after the base game schema, room-admin.sql, and stalker-role-fix.sql.
-- Normalizes per-game profile records and rebuilds My Page read models from
-- game_result_players so repeated result processing stays idempotent.

begin;

create schema if not exists private;
revoke all on schema private from public;

alter table public.player_recent_matches
  add column if not exists game_id uuid,
  add column if not exists game_type text not null default 'mafia';

alter table public.player_recent_matches
  drop constraint if exists player_recent_matches_game_id_fkey;

create unique index if not exists player_recent_matches_game_user_idx
  on public.player_recent_matches (game_id, user_id)
  where game_id is not null;

create table if not exists public.player_game_match_records (
  -- Keep completed history after its temporary room and game rows are deleted.
  game_id uuid not null,
  user_id uuid not null references public.profiles(id) on delete cascade,
  game_type text not null,
  role_key text not null,
  role_name text not null,
  role_icon text not null default '?',
  won boolean not null default false,
  survived boolean not null default false,
  played_rounds integer not null default 0,
  summary text not null default '',
  detail text not null default '',
  played_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (game_id, user_id)
);

alter table public.player_game_match_records
  drop constraint if exists player_game_match_records_game_id_fkey;

create index if not exists player_game_match_records_user_played_at_idx
  on public.player_game_match_records (user_id, played_at desc);

create table if not exists public.player_game_stats (
  user_id uuid not null references public.profiles(id) on delete cascade,
  game_type text not null,
  total_games integer not null default 0,
  win_rate numeric not null default 0,
  citizen_win_rate numeric not null default 0,
  mafia_win_rate numeric not null default 0,
  survival_rate numeric not null default 0,
  average_played_rounds numeric not null default 0,
  updated_at timestamptz not null default now(),
  primary key (user_id, game_type)
);

create table if not exists public.player_game_role_stats (
  user_id uuid not null references public.profiles(id) on delete cascade,
  game_type text not null,
  role_key text not null,
  role_name text not null,
  icon text not null default '?',
  games_played integer not null default 0,
  win_rate numeric not null default 0,
  is_most_played boolean not null default false,
  updated_at timestamptz not null default now(),
  primary key (user_id, game_type, role_key)
);

alter table public.player_game_match_records enable row level security;
alter table public.player_game_stats enable row level security;
alter table public.player_game_role_stats enable row level security;
alter table public.player_stats enable row level security;
alter table public.player_role_stats enable row level security;
alter table public.player_recent_matches enable row level security;

revoke all on table public.player_game_match_records from public;
revoke all on table public.player_game_stats from public;
revoke all on table public.player_game_role_stats from public;

grant select on table public.player_game_match_records to authenticated;
grant select on table public.player_game_stats to authenticated;
grant select on table public.player_game_role_stats to authenticated;
grant select on table public.player_stats to authenticated;
grant select on table public.player_role_stats to authenticated;
grant select on table public.player_recent_matches to authenticated;

drop policy if exists "players can read own game match records"
  on public.player_game_match_records;
drop policy if exists "players can read own game stats"
  on public.player_game_stats;
drop policy if exists "players can read own game role stats"
  on public.player_game_role_stats;

create policy "players can read own game match records"
  on public.player_game_match_records for select
  to authenticated
  using (user_id = auth.uid());

create policy "players can read own game stats"
  on public.player_game_stats for select
  to authenticated
  using (user_id = auth.uid());

create policy "players can read own game role stats"
  on public.player_game_role_stats for select
  to authenticated
  using (user_id = auth.uid());

-- My Page tables contain personal history. Keep their existing Data API
-- access, but narrow row visibility to the signed-in profile.
drop policy if exists "player stats are readable by authenticated users"
  on public.player_stats;
drop policy if exists "player role stats are readable by authenticated users"
  on public.player_role_stats;
drop policy if exists "player recent matches are readable by authenticated users"
  on public.player_recent_matches;
drop policy if exists "players can read own player stats"
  on public.player_stats;
drop policy if exists "players can read own player role stats"
  on public.player_role_stats;
drop policy if exists "players can read own recent matches"
  on public.player_recent_matches;

create policy "players can read own player stats"
  on public.player_stats for select
  to authenticated
  using (user_id = auth.uid());

create policy "players can read own player role stats"
  on public.player_role_stats for select
  to authenticated
  using (user_id = auth.uid());

create policy "players can read own recent matches"
  on public.player_recent_matches for select
  to authenticated
  using (user_id = auth.uid());

create or replace function private.get_game_display_name(p_game_type text)
returns text
language sql
stable
set search_path = ''
as $$
  select case p_game_type
    when 'mafia' then '마피아 게임'
    when 'catchmind' then '캐치마인드'
    when 'rainbowTail' then '캐치마인드'
    when 'rainbow_tail' then '캐치마인드'
    when 'rainbow-tail' then '캐치마인드'
    when 'liar' then '라이어 게임'
    else coalesce(nullif(trim(p_game_type), ''), '알 수 없는 게임')
  end;
$$;

create or replace function private.get_role_display_name(p_role_key text)
returns text
language sql
stable
set search_path = ''
as $$
  select coalesce(
    (
      select rt.display_name
      from public.role_types rt
      where rt.role_name = p_role_key
      limit 1
    ),
    case p_role_key
      when 'citizen' then '시민'
      when 'mafia' then '마피아'
      when 'police' then '경찰'
      when 'doctor' then '의사'
      when 'stalker' then '스토커'
      else coalesce(nullif(trim(p_role_key), ''), '플레이어')
    end
  );
$$;

create or replace function private.get_role_icon(p_role_key text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_role_key
    when 'citizen' then 'C'
    when 'mafia' then 'M'
    when 'police' then 'P'
    when 'doctor' then 'D'
    when 'stalker' then 'S'
    else '?'
  end;
$$;

create or replace function private.refresh_player_mypage_stats(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.player_stats (
    user_id,
    total_games,
    overall_win_rate,
    citizen_win_rate,
    mafia_win_rate,
    survival_rate,
    average_survival_turn,
    updated_at
  )
  select
    p_user_id,
    count(*)::integer,
    coalesce(
      round(100.0 * count(*) filter (where r.won) / nullif(count(*), 0)),
      0
    ),
    coalesce(
      round(
        100.0 *
        count(*) filter (
          where r.game_type = 'mafia'
            and r.role_key <> 'mafia'
            and r.won
        ) /
        nullif(
          count(*) filter (
            where r.game_type = 'mafia'
              and r.role_key <> 'mafia'
          ),
          0
        )
      ),
      0
    ),
    coalesce(
      round(
        100.0 *
        count(*) filter (
          where r.game_type = 'mafia'
            and r.role_key = 'mafia'
            and r.won
        ) /
        nullif(
          count(*) filter (
            where r.game_type = 'mafia'
              and r.role_key = 'mafia'
          ),
          0
        )
      ),
      0
    ),
    coalesce(
      round(100.0 * count(*) filter (where r.survived) / nullif(count(*), 0)),
      0
    ),
    coalesce(round(avg(r.played_rounds), 1), 0),
    now()
  from public.player_game_match_records r
  where r.user_id = p_user_id
  on conflict (user_id) do update
  set
    total_games = excluded.total_games,
    overall_win_rate = excluded.overall_win_rate,
    citizen_win_rate = excluded.citizen_win_rate,
    mafia_win_rate = excluded.mafia_win_rate,
    survival_rate = excluded.survival_rate,
    average_survival_turn = excluded.average_survival_turn,
    updated_at = excluded.updated_at;

  delete from public.player_game_stats
  where user_id = p_user_id;

  insert into public.player_game_stats (
    user_id,
    game_type,
    total_games,
    win_rate,
    citizen_win_rate,
    mafia_win_rate,
    survival_rate,
    average_played_rounds,
    updated_at
  )
  select
    r.user_id,
    r.game_type,
    count(*)::integer,
    coalesce(
      round(100.0 * count(*) filter (where r.won) / nullif(count(*), 0)),
      0
    ),
    coalesce(
      round(
        100.0 *
        count(*) filter (where r.role_key <> 'mafia' and r.won) /
        nullif(count(*) filter (where r.role_key <> 'mafia'), 0)
      ),
      0
    ),
    coalesce(
      round(
        100.0 *
        count(*) filter (where r.role_key = 'mafia' and r.won) /
        nullif(count(*) filter (where r.role_key = 'mafia'), 0)
      ),
      0
    ),
    coalesce(
      round(100.0 * count(*) filter (where r.survived) / nullif(count(*), 0)),
      0
    ),
    coalesce(round(avg(r.played_rounds), 1), 0),
    now()
  from public.player_game_match_records r
  where r.user_id = p_user_id
  group by r.user_id, r.game_type;

  delete from public.player_game_role_stats
  where user_id = p_user_id;

  insert into public.player_game_role_stats (
    user_id,
    game_type,
    role_key,
    role_name,
    icon,
    games_played,
    win_rate,
    is_most_played,
    updated_at
  )
  with role_totals as (
    select
      r.user_id,
      r.game_type,
      r.role_key,
      max(r.role_name) as role_name,
      max(r.role_icon) as icon,
      count(*)::integer as games_played,
      coalesce(
        round(100.0 * count(*) filter (where r.won) / nullif(count(*), 0)),
        0
      ) as win_rate
    from public.player_game_match_records r
    where r.user_id = p_user_id
    group by r.user_id, r.game_type, r.role_key
  )
  select
    rt.user_id,
    rt.game_type,
    rt.role_key,
    rt.role_name,
    rt.icon,
    rt.games_played,
    rt.win_rate,
    rt.games_played = max(rt.games_played) over (
      partition by rt.user_id, rt.game_type
    ),
    now()
  from role_totals rt;

  update public.player_role_stats
  set
    games_played = 0,
    win_rate = 0,
    is_most_played = false
  where user_id = p_user_id;

  insert into public.player_role_stats (
    user_id,
    role_name,
    icon,
    games_played,
    win_rate,
    is_most_played
  )
  select
    grs.user_id,
    grs.role_name,
    grs.icon,
    grs.games_played,
    round(grs.win_rate)::integer,
    grs.is_most_played
  from public.player_game_role_stats grs
  where grs.user_id = p_user_id
    and grs.game_type = 'mafia'
  on conflict (user_id, role_name) do update
  set
    icon = excluded.icon,
    games_played = excluded.games_played,
    win_rate = excluded.win_rate,
    is_most_played = excluded.is_most_played;

  delete from public.player_recent_matches
  where user_id = p_user_id;

  insert into public.player_recent_matches (
    user_id,
    game_id,
    game_type,
    role_name,
    role_icon,
    won,
    summary,
    detail,
    played_at
  )
  select
    r.user_id,
    r.game_id,
    r.game_type,
    r.role_name,
    r.role_icon,
    r.won,
    r.summary,
    r.detail,
    r.played_at
  from public.player_game_match_records r
  where r.user_id = p_user_id
  order by r.played_at desc
  limit 20;
end;
$$;

revoke all on function private.get_game_display_name(text) from public;
revoke all on function private.get_role_display_name(text) from public;
revoke all on function private.get_role_icon(text) from public;
revoke all on function private.refresh_player_mypage_stats(uuid) from public;

create or replace function private.refresh_player_mypage_stats_after_match_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    perform private.refresh_player_mypage_stats(old.user_id);
    return null;
  end if;

  perform private.refresh_player_mypage_stats(new.user_id);

  if tg_op = 'UPDATE' and new.user_id is distinct from old.user_id then
    perform private.refresh_player_mypage_stats(old.user_id);
  end if;

  return null;
end;
$$;

revoke all on function private.refresh_player_mypage_stats_after_match_change() from public;

drop trigger if exists refresh_player_mypage_stats_after_match_change
  on public.player_game_match_records;

create trigger refresh_player_mypage_stats_after_match_change
  after insert or update or delete on public.player_game_match_records
  for each row
  execute function private.refresh_player_mypage_stats_after_match_change();

create or replace function private.sync_game_result_player_to_mypage()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_game_type text;
  v_game_display_name text;
  v_role_display_name text;
  v_round_no integer;
  v_played_at timestamptz;
begin
  select
    coalesce(nullif(trim(r.game_type), ''), 'mafia'),
    greatest(coalesce(g.round_no, 0), 0),
    coalesce(g.ended_at, now())
  into
    v_game_type,
    v_round_no,
    v_played_at
  from public.games g
  join public.rooms r on r.id = g.room_id
  where g.id = new.game_id;

  if v_game_type is null then
    raise exception 'Game room required for My Page synchronization';
  end if;

  v_game_display_name := private.get_game_display_name(v_game_type);
  v_role_display_name := private.get_role_display_name(
    coalesce(nullif(trim(new.role_name), ''), 'player')
  );

  insert into public.player_game_match_records (
    game_id,
    user_id,
    game_type,
    role_key,
    role_name,
    role_icon,
    won,
    survived,
    played_rounds,
    summary,
    detail,
    played_at,
    updated_at
  ) values (
    new.game_id,
    new.user_id,
    v_game_type,
    coalesce(nullif(trim(new.role_name), ''), 'player'),
    v_role_display_name,
    private.get_role_icon(coalesce(nullif(trim(new.role_name), ''), 'player')),
    coalesce(new.is_winner, false),
    coalesce(new.is_alive, false),
    v_round_no,
    format(
      '%s · %s 역할로 %s',
      v_game_display_name,
      v_role_display_name,
      case when coalesce(new.is_winner, false) then '승리' else '패배' end
    ),
    format(
      '%s라운드 종료 · %s',
      v_round_no,
      case when coalesce(new.is_alive, false) then '생존' else '탈락' end
    ),
    v_played_at,
    now()
  )
  on conflict (game_id, user_id) do update
  set
    game_type = excluded.game_type,
    role_key = excluded.role_key,
    role_name = excluded.role_name,
    role_icon = excluded.role_icon,
    won = excluded.won,
    survived = excluded.survived,
    played_rounds = excluded.played_rounds,
    summary = excluded.summary,
    detail = excluded.detail,
    played_at = excluded.played_at,
    updated_at = excluded.updated_at;

  return new;
end;
$$;

revoke all on function private.sync_game_result_player_to_mypage() from public;

drop trigger if exists sync_game_result_player_to_mypage
  on public.game_result_players;

create trigger sync_game_result_player_to_mypage
  after insert or update of role_name, is_alive, is_winner
  on public.game_result_players
  for each row
  execute function private.sync_game_result_player_to_mypage();

-- Backfill ended games and replace old seeded demo rows with computed values.
insert into public.player_game_match_records (
  game_id,
  user_id,
  game_type,
  role_key,
  role_name,
  role_icon,
  won,
  survived,
  played_rounds,
  summary,
  detail,
  played_at,
  updated_at
)
select
  grp.game_id,
  grp.user_id,
  coalesce(nullif(trim(r.game_type), ''), 'mafia'),
  coalesce(nullif(trim(grp.role_name), ''), 'player'),
  private.get_role_display_name(coalesce(nullif(trim(grp.role_name), ''), 'player')),
  private.get_role_icon(coalesce(nullif(trim(grp.role_name), ''), 'player')),
  coalesce(grp.is_winner, false),
  coalesce(grp.is_alive, false),
  greatest(coalesce(g.round_no, 0), 0),
  format(
    '%s · %s 역할로 %s',
    private.get_game_display_name(coalesce(nullif(trim(r.game_type), ''), 'mafia')),
    private.get_role_display_name(coalesce(nullif(trim(grp.role_name), ''), 'player')),
    case when coalesce(grp.is_winner, false) then '승리' else '패배' end
  ),
  format(
    '%s라운드 종료 · %s',
    greatest(coalesce(g.round_no, 0), 0),
    case when coalesce(grp.is_alive, false) then '생존' else '탈락' end
  ),
  coalesce(g.ended_at, now()),
  now()
from public.game_result_players grp
join public.games g on g.id = grp.game_id
join public.rooms r on r.id = g.room_id
on conflict (game_id, user_id) do update
set
  game_type = excluded.game_type,
  role_key = excluded.role_key,
  role_name = excluded.role_name,
  role_icon = excluded.role_icon,
  won = excluded.won,
  survived = excluded.survived,
  played_rounds = excluded.played_rounds,
  summary = excluded.summary,
  detail = excluded.detail,
  played_at = excluded.played_at,
  updated_at = excluded.updated_at;

do $$
declare
  v_profile record;
begin
  for v_profile in
    select id
    from public.profiles
  loop
    perform private.refresh_player_mypage_stats(v_profile.id);
  end loop;
end;
$$;

do $$
declare
  v_table_name text;
begin
  foreach v_table_name in array array[
    'player_stats',
    'player_role_stats',
    'player_recent_matches',
    'player_game_stats',
    'player_game_role_stats'
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

do $$
begin
  if not exists (
    select 1
    from pg_trigger
    where tgrelid = 'public.game_result_players'::regclass
      and tgname = 'sync_game_result_player_to_mypage'
      and not tgisinternal
  ) then
    raise exception 'My Page result synchronization trigger was not installed';
  end if;

  if to_regclass('public.player_game_stats') is null
    or to_regclass('public.player_game_role_stats') is null
  then
    raise exception 'My Page per-game tables were not installed';
  end if;

  if exists (
    select 1
    from public.game_result_players grp
    left join public.player_game_match_records record
      on record.game_id = grp.game_id
     and record.user_id = grp.user_id
    where record.game_id is null
  ) then
    raise exception 'My Page result backfill is incomplete';
  end if;
end;
$$;

commit;

notify pgrst, 'reload schema';

-- SQL Editor verification after finishing one test game:
-- select game_type, total_games, win_rate, survival_rate, average_played_rounds
-- from public.player_game_stats
-- order by updated_at desc;
--
-- select game_type, role_name, games_played, win_rate, is_most_played
-- from public.player_game_role_stats
-- order by updated_at desc, games_played desc;
--
-- select game_type, role_name, won, summary, played_at
-- from public.player_recent_matches
-- order by played_at desc
-- limit 20;
