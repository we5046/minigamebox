-- Apply after the base game schema and room-admin.sql.
-- Adds the stalker role to assignment, night actions, and role-side data.

begin;

-- Keep the normalized role metadata in sync.
insert into public.role_types (
  role_name,
  display_name,
  team_name,
  sort_order
) values (
  'stalker',
  '스토커',
  'citizen',
  5
)
on conflict (role_name) do update
set
  display_name = excluded.display_name,
  team_name = excluded.team_name,
  sort_order = excluded.sort_order;

insert into public.room_role_configs (
  room_id,
  role_name,
  player_count
)
select
  r.id,
  'stalker',
  greatest(coalesce((r.role_config ->> 'stalker')::integer, 0), 0)
from public.rooms r
on conflict (room_id, role_name) do update
set
  player_count = excluded.player_count,
  updated_at = now();

insert into public.player_role_stats (
  user_id,
  role_name,
  icon
)
select
  p.id,
  '스토커',
  'S'
from public.profiles p
on conflict (user_id, role_name) do nothing;

alter table public.game_actions
  drop constraint if exists game_actions_type_check;

alter table public.game_actions
  add constraint game_actions_type_check
  check (action_type in ('mafia_kill', 'police_check', 'doctor_save', 'track'));

create or replace function public.start_game(p_room_id uuid)
returns public.games
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_room public.rooms;
  v_game public.games;
  v_player_count integer;
  v_not_ready_count integer;
  v_citizen_count integer;
  v_mafia_count integer;
  v_police_count integer;
  v_doctor_count integer;
  v_stalker_count integer;
  v_role_total integer;
begin
  if v_user_id is null then
    raise exception '로그인이 필요합니다.';
  end if;

  select *
  into v_room
  from public.rooms
  where id = p_room_id
  for update;

  if not found then
    raise exception '방을 찾을 수 없습니다.';
  end if;

  if v_room.host_user_id <> v_user_id then
    raise exception '방장만 게임을 시작할 수 있습니다.';
  end if;

  if v_room.status <> 'waiting' then
    raise exception '이미 게임이 시작된 방입니다.';
  end if;

  select count(*)
  into v_player_count
  from public.room_players
  where room_id = p_room_id;

  if v_player_count < v_room.min_start_players then
    raise exception '게임 시작 인원이 부족합니다.';
  end if;

  select count(*)
  into v_not_ready_count
  from public.room_players
  where room_id = p_room_id
    and is_ready is not true;

  if v_not_ready_count > 0 then
    raise exception '아직 준비하지 않은 참가자가 있습니다.';
  end if;

  if exists (
    select 1
    from public.games
    where room_id = p_room_id
      and status not in ('finished', 'ended')
  ) then
    raise exception '이미 진행 중인 게임이 있습니다.';
  end if;

  v_citizen_count := greatest(coalesce((v_room.role_config ->> 'citizen')::integer, 0), 0);
  v_mafia_count := greatest(coalesce((v_room.role_config ->> 'mafia')::integer, 0), 0);
  v_police_count := greatest(coalesce((v_room.role_config ->> 'police')::integer, 0), 0);
  v_doctor_count := greatest(coalesce((v_room.role_config ->> 'doctor')::integer, 0), 0);
  v_stalker_count := greatest(coalesce((v_room.role_config ->> 'stalker')::integer, 0), 0);
  v_role_total := v_citizen_count + v_mafia_count + v_police_count + v_doctor_count + v_stalker_count;

  if v_role_total = 0 then
    v_mafia_count := 1;
    v_police_count := 1;
    v_doctor_count := case when v_player_count >= 5 then 1 else 0 end;
    v_stalker_count := 0;
    v_citizen_count := greatest(
      v_player_count - v_mafia_count - v_police_count - v_doctor_count - v_stalker_count,
      0
    );
    v_role_total := v_citizen_count + v_mafia_count + v_police_count + v_doctor_count + v_stalker_count;
  end if;

  if v_role_total <> v_player_count then
    raise exception '역할 인원수(%)와 현재 참가자 수(%)가 일치하지 않습니다.', v_role_total, v_player_count;
  end if;

  update public.rooms
  set
    status = 'starting',
    updated_at = now()
  where id = p_room_id;

  with ordered_players as (
    select
      rp.id,
      row_number() over (order by random()) as rn
    from public.room_players rp
    where rp.room_id = p_room_id
  ),
  role_deck as (
    select
      row_number() over (order by random()) as rn,
      role_name
    from (
      select 'citizen' as role_name from generate_series(1, v_citizen_count)
      union all
      select 'mafia' as role_name from generate_series(1, v_mafia_count)
      union all
      select 'police' as role_name from generate_series(1, v_police_count)
      union all
      select 'doctor' as role_name from generate_series(1, v_doctor_count)
      union all
      select 'stalker' as role_name from generate_series(1, v_stalker_count)
    ) roles
  )
  update public.room_players rp
  set
    role = role_deck.role_name,
    is_alive = true,
    is_ready = true
  from ordered_players
  join role_deck on role_deck.rn = ordered_players.rn
  where rp.id = ordered_players.id;

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
    'night',
    1,
    now(),
    now() + make_interval(secs => greatest(v_room.night_time_seconds, 1))
  )
  returning * into v_game;

  update public.rooms
  set
    status = 'playing',
    phase = 'night',
    updated_at = now()
  where id = p_room_id;

  insert into public.game_messages (
    room_id,
    game_id,
    round_no,
    user_id,
    nickname,
    content,
    message_type,
    event_key,
    is_system
  ) values (
    p_room_id,
    v_game.id,
    v_game.round_no,
    null,
    'System',
    '밤이 시작되었습니다. 각자 행동을 선택하세요.',
    'system',
    'night_start',
    true
  )
  on conflict (game_id, round_no, event_key)
  where event_key is not null
  do nothing;

  return v_game;
exception
  when unique_violation then
    raise exception '이미 진행 중인 게임입니다.';
end;
$$;

revoke all on function public.start_game(uuid) from public;
grant execute on function public.start_game(uuid) to authenticated;

create or replace function public.submit_night_action(
  p_room_id uuid,
  p_action_type text,
  p_target_user_id uuid
)
returns public.game_actions
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_game public.games;
  v_actor public.room_players;
  v_action public.game_actions;
begin
  if v_user_id is null then
    raise exception '로그인이 필요합니다.';
  end if;

  select *
  into v_game
  from public.games
  where room_id = p_room_id
    and status not in ('finished', 'ended')
  order by created_at desc
  limit 1;

  if not found then
    raise exception '진행 중인 게임이 없습니다.';
  end if;

  if v_game.phase <> 'night' then
    raise exception '밤 행동을 제출할 수 있는 단계가 아닙니다.';
  end if;

  if v_game.phase_ends_at <= now() then
    raise exception '밤 시간이 종료되었습니다.';
  end if;

  select *
  into v_actor
  from public.room_players
  where room_id = p_room_id
    and user_id = v_user_id;

  if not found or v_actor.is_alive is not true then
    raise exception '현재 살아있는 참가자만 밤 행동을 제출할 수 있습니다.';
  end if;

  if (p_action_type = 'mafia_kill' and v_actor.role <> 'mafia')
    or (p_action_type = 'police_check' and v_actor.role <> 'police')
    or (p_action_type = 'doctor_save' and v_actor.role <> 'doctor')
    or (p_action_type = 'track' and v_actor.role <> 'stalker')
    or p_action_type not in ('mafia_kill', 'police_check', 'doctor_save', 'track') then
    raise exception '현재 수행할 수 없는 행동입니다.';
  end if;

  if not exists (
    select 1
    from public.room_players
    where room_id = p_room_id
      and user_id = p_target_user_id
      and (
        p_action_type = 'track'
        or is_alive is true
      )
  ) then
    raise exception '선택한 대상이 없습니다.';
  end if;

  insert into public.game_actions (
    room_id,
    game_id,
    round_no,
    actor_user_id,
    action_type,
    target_user_id
  ) values (
    p_room_id,
    v_game.id,
    v_game.round_no,
    v_user_id,
    p_action_type,
    p_target_user_id
  )
  on conflict (game_id, round_no, actor_user_id, action_type)
  do update set
    target_user_id = excluded.target_user_id,
    updated_at = now()
  returning * into v_action;

  return v_action;
end;
$$;

revoke all on function public.submit_night_action(uuid, text, uuid) from public;
grant execute on function public.submit_night_action(uuid, text, uuid) to authenticated;

create or replace function public.get_my_role_info(p_room_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
stable
as $$
declare
  v_user_id uuid := auth.uid();
  v_player public.room_players;
  v_game public.games;
  v_result jsonb;
begin
  if v_user_id is null then
    raise exception '로그인이 필요합니다.';
  end if;

  select *
  into v_player
  from public.room_players
  where room_id = p_room_id
    and user_id = v_user_id;

  if not found then
    raise exception '방 참가자만 역할 정보를 볼 수 있습니다.';
  end if;

  select *
  into v_game
  from public.games
  where room_id = p_room_id
    and status not in ('finished', 'ended')
  order by created_at desc
  limit 1;

  if v_player.role = 'police' then
    select jsonb_build_object(
      'role', 'police',
      'items', coalesce(
        jsonb_agg(
          jsonb_build_object(
            'type', 'police_check',
            'roundNo', ga.round_no,
            'label', p.nickname,
            'description',
              p.nickname || case when target_player.role = 'mafia' then ': 마피아입니다.' else ': 마피아가 아닙니다.' end
          )
          order by ga.round_no desc, ga.updated_at desc
        ),
        '[]'::jsonb
      )
    )
    into v_result
    from public.game_actions ga
    join public.profiles p on p.id = ga.target_user_id
    join public.room_players target_player
      on target_player.room_id = ga.room_id
     and target_player.user_id = ga.target_user_id
    where ga.room_id = p_room_id
      and ga.game_id = v_game.id
      and ga.actor_user_id = v_user_id
      and ga.action_type = 'police_check'
      and (
        v_game.id is null
        or v_game.phase <> 'night'
        or ga.round_no < v_game.round_no
      );
  elsif v_player.role = 'doctor' then
    select jsonb_build_object(
      'role', 'doctor',
      'items', coalesce(
        jsonb_agg(
          jsonb_build_object(
            'type', 'doctor_save',
            'roundNo', ga.round_no,
            'label', p.nickname,
            'description', p.nickname || '님을 보호했습니다.'
          )
          order by ga.round_no desc, ga.updated_at desc
        ),
        '[]'::jsonb
      )
    )
    into v_result
    from public.game_actions ga
    join public.profiles p on p.id = ga.target_user_id
    where ga.room_id = p_room_id
      and ga.game_id = v_game.id
      and ga.actor_user_id = v_user_id
      and ga.action_type = 'doctor_save';
  elsif v_player.role = 'mafia' then
    select jsonb_build_object(
      'role', 'mafia',
      'items', coalesce(
        jsonb_agg(
          jsonb_build_object(
            'type', 'mafia_team',
            'label', p.nickname,
            'description', case when rp.user_id = v_user_id then '나' else '마피아 진영' end,
            'isMe', rp.user_id = v_user_id
          )
          order by p.nickname
        ),
        '[]'::jsonb
      )
    )
    into v_result
    from public.room_players rp
    join public.profiles p on p.id = rp.user_id
    where rp.room_id = p_room_id
      and rp.role = 'mafia';
  elsif v_player.role = 'stalker' then
    select jsonb_build_object(
      'role', 'stalker',
      'items', coalesce(
        jsonb_agg(
          jsonb_build_object(
            'type', 'track',
            'roundNo', tracker_action.round_no,
            'label', tracked_profile.nickname,
            'description',
              tracked_profile.nickname ||
              case
                when visited_profile.id is null then '님은 밤에 아무도 선택하지 않았습니다.'
                else '님은 밤에 ' || visited_profile.nickname || '님을 선택했습니다.'
              end
          )
          order by tracker_action.round_no desc, tracker_action.updated_at desc
        ),
        '[]'::jsonb
      )
    )
    into v_result
    from public.game_actions tracker_action
    join public.profiles tracked_profile
      on tracked_profile.id = tracker_action.target_user_id
    left join lateral (
      select tracked_action.target_user_id
      from public.game_actions tracked_action
      where tracked_action.game_id = tracker_action.game_id
        and tracked_action.round_no = tracker_action.round_no
        and tracked_action.actor_user_id = tracker_action.target_user_id
      order by tracked_action.updated_at desc
      limit 1
    ) visited_action on true
    left join public.profiles visited_profile
      on visited_profile.id = visited_action.target_user_id
    where tracker_action.room_id = p_room_id
      and tracker_action.game_id = v_game.id
      and tracker_action.actor_user_id = v_user_id
      and tracker_action.action_type = 'track'
      and (
        v_game.id is null
        or v_game.phase <> 'night'
        or tracker_action.round_no < v_game.round_no
      );
  else
    v_result := jsonb_build_object(
      'role', coalesce(v_player.role, 'citizen'),
      'items', jsonb_build_array(
        jsonb_build_object(
          'type', 'citizen_guide',
          'label', '시민 안내',
          'description', '토론과 투표로 마피아를 찾아야 합니다.'
        )
      )
    );
  end if;

  return coalesce(
    v_result,
    jsonb_build_object('role', v_player.role, 'items', '[]'::jsonb)
  );
end;
$$;

revoke all on function public.get_my_role_info(uuid) from public;
grant execute on function public.get_my_role_info(uuid) to authenticated;

-- finish_game may still use an older action-to-log CASE expression. Keep
-- newly added role actions from rolling back the entire game-end transaction.
create or replace function public.fill_missing_game_result_player_log_text()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_action_type text;
  v_target_nickname text;
begin
  if new.log_text is not null then
    return new;
  end if;

  select ga.action_type, p.nickname
  into v_action_type, v_target_nickname
  from public.game_actions ga
  left join public.profiles p on p.id = ga.target_user_id
  where ga.game_id = new.game_id
    and ga.actor_user_id = new.user_id
    and ga.round_no = new.round_no
  order by ga.updated_at desc
  limit 1;

  new.log_text := case
    when v_action_type = 'track' then
      format('Round %s 밤: %s님을 추적했습니다.', new.round_no, coalesce(v_target_nickname, '대상'))
    else
      format('Round %s 밤: 역할 행동을 수행했습니다.', new.round_no)
  end;

  return new;
end;
$$;

revoke all on function public.fill_missing_game_result_player_log_text() from public;

drop trigger if exists fill_missing_game_result_player_log_text
  on public.game_result_player_logs;

create trigger fill_missing_game_result_player_log_text
  before insert or update of log_text on public.game_result_player_logs
  for each row
  execute function public.fill_missing_game_result_player_log_text();

do $$
begin
  if not exists (
    select 1
    from public.role_types
    where role_name = 'stalker'
      and team_name = 'citizen'
  ) then
    raise exception 'stalker role metadata was not installed';
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.game_actions'::regclass
      and conname = 'game_actions_type_check'
      and pg_get_constraintdef(oid) like '%track%'
  ) then
    raise exception 'track action constraint was not installed';
  end if;

  if position(
    'v_stalker_count' in pg_get_functiondef('public.start_game(uuid)'::regprocedure)
  ) = 0 then
    raise exception 'start_game does not include stalker assignment';
  end if;

  if not exists (
    select 1
    from pg_trigger
    where tgrelid = 'public.game_result_player_logs'::regclass
      and tgname = 'fill_missing_game_result_player_log_text'
      and not tgisinternal
  ) then
    raise exception 'game result log fallback trigger was not installed';
  end if;
end;
$$;

commit;

notify pgrst, 'reload schema';
