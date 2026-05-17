drop function if exists public.get_my_game_role(uuid);

create or replace function public.get_my_game_role(p_room_id uuid)
returns table (
  user_id uuid,
  role text,
  is_alive boolean
)
language sql
security definer
set search_path = public
stable
as $$
  select rp.user_id, rp.role, rp.is_alive
  from public.room_players rp
  join public.rooms r on r.id = rp.room_id
  where rp.room_id = p_room_id
    and rp.user_id = auth.uid()
    and r.status in ('starting', 'playing');
$$;

grant execute on function public.get_my_game_role(uuid) to authenticated;

drop function if exists public.get_my_role_info(uuid);

create or replace function public.get_my_role_info(p_room_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
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

grant execute on function public.get_my_role_info(uuid) to authenticated;

drop function if exists public.get_vote_status(uuid);

create or replace function public.get_vote_status(p_room_id uuid)
returns table (
  user_id uuid,
  has_voted boolean,
  target_user_id uuid
)
language sql
security definer
set search_path = public
stable
as $$
  with active_game as (
    select g.id, g.round_no
    from public.games g
    where g.room_id = p_room_id
      and g.status not in ('finished', 'ended')
    order by g.created_at desc
    limit 1
  ),
  requester as (
    select 1
    from public.room_players self_player
    where self_player.room_id = p_room_id
      and self_player.user_id = auth.uid()
    limit 1
  )
  select
    auth.uid() as user_id,
    gv.id is not null as has_voted,
    gv.target_user_id
  from requester req
  join active_game ag on true
  left join public.game_votes gv
    on gv.game_id = ag.id
   and gv.round_no = ag.round_no
   and gv.voter_user_id = auth.uid();
$$;

grant execute on function public.get_vote_status(uuid) to authenticated;

drop function if exists public.get_current_game(uuid);

create or replace function public.get_current_game(p_room_id uuid)
returns public.games
language sql
security definer
set search_path = public
stable
as $$
  select g.*
  from public.games g
  where g.room_id = p_room_id
    and g.status <> 'finished'
    and exists (
      select 1
      from public.room_players rp
      where rp.room_id = p_room_id
        and rp.user_id = auth.uid()
    )
  order by g.created_at desc
  limit 1;
$$;

grant execute on function public.get_current_game(uuid) to authenticated;

drop function if exists public.get_game_result(uuid);

create or replace function public.get_game_result(p_game_id uuid)
returns public.game_results
language sql
security definer
set search_path = public
stable
as $$
  select gr.*
  from public.game_results gr
  where gr.game_id = p_game_id
    and exists (
      select 1
      from public.room_players rp
      where rp.room_id = gr.room_id
        and rp.user_id = auth.uid()
    )
  limit 1;
$$;

grant execute on function public.get_game_result(uuid) to authenticated;

drop function if exists public.return_room_to_lobby(uuid);

create or replace function public.return_room_to_lobby(p_room_id uuid)
returns public.rooms
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_room public.rooms;
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;

  select *
  into v_room
  from public.rooms
  where id = p_room_id
    and host_user_id = v_user_id
  for update;

  if not found then
    raise exception 'Only the room host can return the room to the lobby.';
  end if;

  if v_room.status <> 'game_over' then
    return v_room;
  end if;

  update public.room_players
  set role = null,
      is_alive = true,
      is_ready = is_host
  where room_id = p_room_id;

  update public.rooms
  set status = 'waiting',
      phase = 'before_start',
      updated_at = now()
  where id = p_room_id
  returning * into v_room;

  return v_room;
end;
$$;

grant execute on function public.return_room_to_lobby(uuid) to authenticated;
