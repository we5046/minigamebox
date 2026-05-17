drop function if exists public.start_game(uuid);

create or replace function public.start_game(p_room_id uuid)
returns public.games
language plpgsql
security definer
set search_path = public
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
  v_role_total := v_citizen_count + v_mafia_count + v_police_count + v_doctor_count;

  if v_role_total = 0 then
    v_mafia_count := 1;
    v_police_count := 1;
    v_doctor_count := case when v_player_count >= 5 then 1 else 0 end;
    v_citizen_count := greatest(v_player_count - v_mafia_count - v_police_count - v_doctor_count, 0);
    v_role_total := v_citizen_count + v_mafia_count + v_police_count + v_doctor_count;
  end if;

  if v_role_total <> v_player_count then
    raise exception '역할 인원수(%)와 현재 참가자 수(%)가 일치하지 않습니다.', v_role_total, v_player_count;
  end if;

  update public.rooms
  set status = 'starting',
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
    ) roles
  )
  update public.room_players rp
  set role = role_deck.role_name,
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
  set status = 'playing',
      phase = 'night',
      updated_at = now()
  where id = p_room_id;

  insert into public.game_messages (room_id, game_id, round_no, user_id, nickname, content, message_type, event_key, is_system)
  values (
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

grant execute on function public.start_game(uuid) to authenticated;

drop function if exists public.end_game(uuid);

create or replace function public.end_game(p_room_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_room public.rooms;
  v_game_id uuid;
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
    raise exception '방장만 게임을 종료할 수 있습니다.';
  end if;

  if v_room.status = 'waiting' then
    update public.room_players
    set role = null,
        is_alive = true,
        is_ready = is_host
    where room_id = p_room_id;

    update public.rooms
    set phase = 'before_start',
        updated_at = now()
    where id = p_room_id;

    return;
  end if;

  select id
  into v_game_id
  from public.games
  where room_id = p_room_id
    and status not in ('finished', 'ended')
  order by created_at desc
  limit 1
  for update;

  if v_game_id is null then
    update public.room_players
    set role = null,
        is_alive = true,
        is_ready = is_host
    where room_id = p_room_id;

    update public.rooms
    set status = 'waiting',
        phase = 'before_start',
        updated_at = now()
    where id = p_room_id;

    return;
  end if;

  update public.games
  set status = 'ended',
      phase = 'ended',
      phase_started_at = now(),
      phase_ends_at = now(),
      updated_at = now()
  where id = v_game_id;

  update public.room_players
  set role = null,
      is_alive = true,
      is_ready = is_host
  where room_id = p_room_id;

  update public.rooms
  set status = 'waiting',
      phase = 'before_start',
      updated_at = now()
  where id = p_room_id;
end;
$$;

grant execute on function public.end_game(uuid) to authenticated;


drop function if exists public.submit_night_action(uuid, text, uuid);

create or replace function public.submit_night_action(
  p_room_id uuid,
  p_action_type text,
  p_target_user_id uuid
)
returns public.game_actions
language plpgsql
security definer
set search_path = public
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
    or p_action_type not in ('mafia_kill', 'police_check', 'doctor_save') then
    raise exception '현재 수행할 수 없는 행동입니다.';
  end if;

  if not exists (
    select 1
    from public.room_players
    where room_id = p_room_id
      and user_id = p_target_user_id
      and is_alive is true
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

grant execute on function public.submit_night_action(uuid, text, uuid) to authenticated;

drop function if exists public.resolve_night(uuid);

create or replace function public.resolve_night(p_room_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_game public.games;
  v_kill_target uuid;
  v_save_target uuid;
  v_top_count integer := 0;
  v_top_ties integer := 0;
  v_target_nickname text;
begin
  if v_user_id is null then
    raise exception '로그인이 필요합니다.';
  end if;

  if not exists (
    select 1
    from public.room_players
    where room_id = p_room_id
      and user_id = v_user_id
  ) then
    raise exception '방 참가자만 밤 결과를 처리할 수 있습니다.';
  end if;

  select *
  into v_game
  from public.games
  where room_id = p_room_id
    and status not in ('finished', 'ended')
  order by created_at desc
  limit 1
  for update;

  if not found or v_game.phase <> 'night' or v_game.phase_ends_at > now() then
    return;
  end if;

  with kill_counts as (
    select target_user_id, count(*) as vote_count
    from public.game_actions
    where game_id = v_game.id
      and round_no = v_game.round_no
      and action_type = 'mafia_kill'
    group by target_user_id
  ),
  top_count as (
    select max(vote_count) as vote_count
    from kill_counts
  )
  select kc.target_user_id, tc.vote_count, count(*) over ()
  into v_kill_target, v_top_count, v_top_ties
  from kill_counts kc
  join top_count tc on tc.vote_count = kc.vote_count
  limit 1;

  select target_user_id
  into v_save_target
  from public.game_actions
  where game_id = v_game.id
    and round_no = v_game.round_no
    and action_type = 'doctor_save'
  order by updated_at desc
  limit 1;

  if v_kill_target is null or v_top_ties > 1 then
    insert into public.game_messages (room_id, game_id, round_no, user_id, nickname, content, message_type, event_key, is_system)
    values (p_room_id, v_game.id, v_game.round_no, null, 'System', '밤에 처형 대상이 정해지지 않았습니다.', 'system', 'night_result', true)
    on conflict (game_id, round_no, event_key)
    where event_key is not null
    do nothing;
  elsif v_kill_target = v_save_target then
    insert into public.game_messages (room_id, game_id, round_no, user_id, nickname, content, message_type, event_key, is_system)
    values (p_room_id, v_game.id, v_game.round_no, null, 'System', '의사의 보호로 밤의 공격이 실패했습니다.', 'system', 'night_result', true)
    on conflict (game_id, round_no, event_key)
    where event_key is not null
    do nothing;
  else
    update public.room_players
    set is_alive = false
    where room_id = p_room_id
      and user_id = v_kill_target;

    select nickname
    into v_target_nickname
    from public.profiles
    where id = v_kill_target;

    insert into public.game_messages (room_id, game_id, round_no, user_id, nickname, content, message_type, event_key, is_system)
    values (
      p_room_id,
      v_game.id,
      v_game.round_no,
      null,
      'System',
      coalesce(v_target_nickname, '?') || '님이 밤에 사망했습니다.',
      'system',
      'night_result',
      true
    )
    on conflict (game_id, round_no, event_key)
    where event_key is not null
    do nothing;
  end if;

  perform public.check_game_ended(p_room_id);
end;
$$;

drop function if exists public.submit_vote(uuid, uuid);

create or replace function public.submit_vote(
  p_room_id uuid,
  p_target_user_id uuid
)
returns public.game_votes
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_game public.games;
  v_vote public.game_votes;
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

  if v_game.phase <> 'vote' then
    raise exception '투표할 수 있는 단계가 아닙니다.';
  end if;

  if v_game.phase_ends_at <= now() then
    raise exception '투표 시간이 종료되었습니다.';
  end if;

  if not exists (
    select 1
    from public.room_players
    where room_id = p_room_id
      and user_id = v_user_id
      and is_alive is true
  ) then
    raise exception '현재 살아있는 참가자만 투표할 수 있습니다.';
  end if;

  if not exists (
    select 1
    from public.room_players
    where room_id = p_room_id
      and user_id = p_target_user_id
      and is_alive is true
  ) then
    raise exception '투표 대상이 없습니다.';
  end if;

  insert into public.game_votes (
    room_id,
    game_id,
    round_no,
    voter_user_id,
    target_user_id
  ) values (
    p_room_id,
    v_game.id,
    v_game.round_no,
    v_user_id,
    p_target_user_id
  )
  on conflict (game_id, round_no, voter_user_id)
  do update set
    target_user_id = excluded.target_user_id,
    updated_at = now()
  returning * into v_vote;

  return v_vote;
end;
$$;

grant execute on function public.submit_vote(uuid, uuid) to authenticated;

drop function if exists public.submit_final_defense_vote(uuid, boolean);

create or replace function public.submit_final_defense_vote(
  p_room_id uuid,
  p_approve_execution boolean
)
returns public.game_final_defense_votes
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_game public.games;
  v_vote public.game_final_defense_votes;
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

  if v_game.phase <> 'final_defense' then
    raise exception '최후의 변론 투표 단계가 아닙니다.';
  end if;

  if v_game.phase_ends_at <= now() then
    raise exception '최후의 변론 시간이 종료되었습니다.';
  end if;

  if not exists (
    select 1
    from public.room_players
    where room_id = p_room_id
      and user_id = v_user_id
      and is_alive is true
      and user_id <> v_game.final_defense_target_user_id
  ) then
    raise exception '생존한 참가자만 최후의 변론 투표를 할 수 있습니다.';
  end if;

  insert into public.game_final_defense_votes (
    room_id,
    game_id,
    round_no,
    voter_user_id,
    approve_execution
  ) values (
    p_room_id,
    v_game.id,
    v_game.round_no,
    v_user_id,
    coalesce(p_approve_execution, false)
  )
  on conflict (game_id, round_no, voter_user_id)
  do update set
    approve_execution = excluded.approve_execution,
    updated_at = now()
  returning * into v_vote;

  return v_vote;
end;
$$;

grant execute on function public.submit_final_defense_vote(uuid, boolean) to authenticated;

drop function if exists public.resolve_vote(uuid);

create or replace function public.resolve_vote(p_room_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_game public.games;
  v_execution_target uuid;
  v_top_count integer := 0;
  v_top_ties integer := 0;
  v_target_nickname text;
begin
  if v_user_id is null then
    raise exception '로그인이 필요합니다.';
  end if;

  if not exists (
    select 1
    from public.room_players
    where room_id = p_room_id
      and user_id = v_user_id
  ) then
    raise exception '방 참가자만 투표 결과를 처리할 수 있습니다.';
  end if;

  select *
  into v_game
  from public.games
  where room_id = p_room_id
    and status not in ('finished', 'ended')
  order by created_at desc
  limit 1
  for update;

  if not found or v_game.phase <> 'vote' or v_game.phase_ends_at > now() then
    return;
  end if;

  with vote_counts as (
    select target_user_id, count(*) as vote_count
    from public.game_votes
    where game_id = v_game.id
      and round_no = v_game.round_no
    group by target_user_id
  ),
  top_count as (
    select max(vote_count) as vote_count
    from vote_counts
  )
  select vc.target_user_id, tc.vote_count, count(*) over ()
  into v_execution_target, v_top_count, v_top_ties
  from vote_counts vc
  join top_count tc on tc.vote_count = vc.vote_count
  limit 1;

  if v_execution_target is null or v_top_ties > 1 then
    insert into public.game_messages (room_id, game_id, round_no, user_id, nickname, content, message_type, event_key, is_system)
    values (p_room_id, v_game.id, v_game.round_no, null, 'System', '투표가 동점으로 마무리되어 처형하지 않았습니다.', 'system', 'vote_result', true)
    on conflict (game_id, round_no, event_key)
    where event_key is not null
    do nothing;
  else
    update public.room_players
    set is_alive = false
    where room_id = p_room_id
      and user_id = v_execution_target;

    select nickname
    into v_target_nickname
    from public.profiles
    where id = v_execution_target;

    insert into public.game_messages (room_id, game_id, round_no, user_id, nickname, content, message_type, event_key, is_system)
    values (
      p_room_id,
      v_game.id,
      v_game.round_no,
      null,
      'System',
      coalesce(v_target_nickname, '?') || '님이 투표로 처형되었습니다.',
      'system',
      'vote_result',
      true
    )
    on conflict (game_id, round_no, event_key)
    where event_key is not null
    do nothing;
  end if;

  perform public.check_game_ended(p_room_id);
end;
$$;

drop function if exists public.finish_game(uuid, text, text);

create or replace function public.finish_game(
  p_game_id uuid,
  p_winner text,
  p_reason text
)
returns public.games
language plpgsql
security definer
set search_path = public
as $$
declare
  v_game public.games;
  v_room public.rooms;
  v_summary jsonb;
begin
  select *
  into v_game
  from public.games
  where id = p_game_id
  for update;

  if not found then
    raise exception '게임을 찾을 수 없습니다.';
  end if;

  select *
  into v_room
  from public.rooms
  where id = v_game.room_id
  for update;

  if not found then
    raise exception '방을 찾을 수 없습니다.';
  end if;

  with player_base as (
    select
      rp.user_id,
      p.nickname,
      rp.role,
      case when coalesce(rp.role, '') = 'mafia' then 'mafia' else 'citizen' end as team,
      rp.is_alive
    from public.room_players rp
    join public.profiles p on p.id = rp.user_id
    where rp.room_id = v_room.id
  ),
  log_rows as (
    select
      ga.actor_user_id as user_id,
      ga.round_no,
      ga.created_at,
      1 as sort_order,
      case ga.action_type
        when 'mafia_kill' then format('Round %s 밤: %s를 제거 대상으로 선택했습니다.', ga.round_no, target.nickname)
        when 'police_check' then format(
          'Round %s 밤: %s를 조사했습니다. 결과: %s',
          ga.round_no,
          target.nickname,
          case when coalesce(target.role, '') = 'mafia' then '마피아입니다' else '마피아가 아닙니다' end
        )
        when 'doctor_save' then format('Round %s 밤: %s를 보호했습니다.', ga.round_no, target.nickname)
      end as log_text
    from public.game_actions ga
    join public.profiles target on target.id = ga.target_user_id
    where ga.game_id = p_game_id

    union all

    select
      gv.voter_user_id as user_id,
      gv.round_no,
      gv.created_at,
      2 as sort_order,
      format('Round %s 투표: %s에게 투표했습니다.', gv.round_no, target.nickname) as log_text
    from public.game_votes gv
    join public.profiles target on target.id = gv.target_user_id
    where gv.game_id = p_game_id
  ),
  player_logs as (
    select
      user_id,
      jsonb_agg(log_text order by round_no, sort_order, created_at) as logs
    from log_rows
    group by user_id
  ),
  player_payload as (
    select
      pb.user_id,
      pb.nickname,
      pb.role,
      pb.team,
      pb.is_alive,
      case
        when p_winner = 'mafia' then pb.role = 'mafia'
        else pb.team <> 'mafia'
      end as is_winner,
      coalesce(pl.logs, '[]'::jsonb) as logs
    from player_base pb
    left join player_logs pl on pl.user_id = pb.user_id
  )
  select jsonb_build_object(
    'winner', p_winner,
    'winners', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'user_id', user_id,
          'nickname', nickname,
          'role', role,
          'is_alive', is_alive
        )
        order by nickname
      )
      from player_payload
      where is_winner
    ), '[]'::jsonb),
    'players', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'user_id', user_id,
          'nickname', nickname,
          'role', role,
          'team', team,
          'is_alive', is_alive,
          'is_winner', is_winner,
          'logs', logs
        )
        order by nickname
      )
      from player_payload
    ), '[]'::jsonb)
  )
  into v_summary;

  update public.games
  set status = 'ended',
      phase = 'ended',
      winner = p_winner,
      end_reason = p_reason,
      ended_at = now(),
      return_to_lobby_at = now() + interval '15 seconds',
      phase_started_at = now(),
      phase_ends_at = now(),
      updated_at = now()
  where id = p_game_id
  returning * into v_game;

  update public.rooms
  set status = 'game_over',
      phase = 'ended',
      updated_at = now()
  where id = v_room.id;

  insert into public.game_results (
    game_id,
    room_id,
    winner,
    end_reason,
    summary
  ) values (
    p_game_id,
    v_room.id,
    p_winner,
    p_reason,
    coalesce(v_summary, jsonb_build_object('winner', p_winner, 'winners', '[]'::jsonb, 'players', '[]'::jsonb))
  )
  on conflict (game_id) do update
  set
    room_id = excluded.room_id,
    winner = excluded.winner,
    end_reason = excluded.end_reason,
    summary = excluded.summary;

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
    v_room.id,
    p_game_id,
    v_game.round_no,
    null,
    'System',
    case
      when p_winner = 'mafia' then '마피아 진영이 승리했습니다. 결과 화면을 확인하세요.'
      else '시민 진영이 승리했습니다. 결과 화면을 확인하세요.'
    end,
    'system',
    'game_end',
    true
  )
  on conflict (game_id, round_no, event_key)
  where event_key is not null
  do nothing;

  return v_game;
end;
$$;

-- Internal helper used by server-side game flow only.

drop function if exists public.check_game_ended(uuid);

create or replace function public.check_game_ended(p_room_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_game public.games;
  v_mafia_count integer := 0;
  v_citizen_count integer := 0;
  v_winner text := null;
  v_reason text := null;
begin
  if v_user_id is null then
    raise exception '로그인이 필요합니다.';
  end if;

  if not exists (
    select 1
    from public.room_players
    where room_id = p_room_id
      and user_id = v_user_id
  ) then
    raise exception '방 참가자만 게임 상태를 확인할 수 있습니다.';
  end if;

  select *
  into v_game
  from public.games
  where room_id = p_room_id
    and status not in ('finished', 'ended')
  order by created_at desc
  limit 1
  for update;

  if not found then
    return null;
  end if;

  select count(*)
  into v_mafia_count
  from public.room_players
  where room_id = p_room_id
    and is_alive is true
    and role = 'mafia';

  select count(*)
  into v_citizen_count
  from public.room_players
  where room_id = p_room_id
    and is_alive is true
    and coalesce(role, '') <> 'mafia';

  if v_mafia_count = 0 then
    v_winner := 'citizen';
    v_reason := '마피아가 모두 제거되었습니다.';
  elsif v_mafia_count >= v_citizen_count then
    v_winner := 'mafia';
    v_reason := '마피아 수가 시민 수와 같아졌습니다.';
  end if;

  if v_winner is not null then
    perform public.finish_game(v_game.id, v_winner, v_reason);
  end if;

  return v_winner;
end;
$$;

-- Internal helper used by server-side game flow only.

