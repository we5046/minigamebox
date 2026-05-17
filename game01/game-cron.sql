create or replace function public.process_due_game_phases()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_room_id uuid;
  v_game public.games;
  v_room public.rooms;
  v_next_phase text;
  v_duration_seconds integer;
  v_kill_target uuid;
  v_save_target uuid;
  v_top_count integer := 0;
  v_top_ties integer := 0;
  v_target_nickname text;
  v_execution_target uuid;
  v_final_defense_target_user_id uuid;
  v_vote_tally text;
  v_execute_count integer := 0;
  v_pardon_count integer := 0;
  v_winner text;
  v_mafia_count integer := 0;
  v_citizen_count integer := 0;
  v_processed_count integer := 0;
begin
  for v_room_id in
    select g.room_id
    from public.games g
    where g.status not in ('finished', 'ended')
      and g.phase_ends_at <= now()
    order by g.phase_ends_at asc
  loop
    v_winner := null;
    v_next_phase := null;
    v_duration_seconds := null;
    v_final_defense_target_user_id := null;
    v_vote_tally := null;
    v_execute_count := 0;
    v_pardon_count := 0;

    select *
    into v_game
    from public.games
    where room_id = v_room_id
      and status not in ('finished', 'ended')
    order by created_at desc
    limit 1
    for update;

    if not found or v_game.phase_ends_at > now() then
      continue;
    end if;

    select *
    into v_room
    from public.rooms
    where id = v_room_id
    for update;

    if v_game.phase = 'role_reveal' then
      v_next_phase := 'night';
      v_duration_seconds := 40;
    elsif v_game.phase = 'night' then
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
        values (v_room_id, v_game.id, v_game.round_no, null, 'System', '밤이 지났지만 아무도 죽지 않았습니다.', 'system', 'night_result', true)
        on conflict (game_id, round_no, event_key)
        where event_key is not null
        do nothing;
      elsif v_kill_target = v_save_target then
        insert into public.game_messages (room_id, game_id, round_no, user_id, nickname, content, message_type, event_key, is_system)
        values (v_room_id, v_game.id, v_game.round_no, null, 'System', '의사의 보호로 밤의 습격이 실패했습니다.', 'system', 'night_result', true)
        on conflict (game_id, round_no, event_key)
        where event_key is not null
        do nothing;
      else
        update public.room_players
        set is_alive = false
        where room_id = v_room_id
          and user_id = v_kill_target;

        select nickname
        into v_target_nickname
        from public.profiles
        where id = v_kill_target;

        insert into public.game_messages (room_id, game_id, round_no, user_id, nickname, content, message_type, event_key, is_system)
        values (
          v_room_id,
          v_game.id,
          v_game.round_no,
          null,
          'System',
          coalesce(v_target_nickname, '플레이어') || '님이 밤에 사망했습니다.',
          'system',
          'night_result',
          true
        )
        on conflict (game_id, round_no, event_key)
        where event_key is not null
        do nothing;
      end if;

      select count(*)
      into v_mafia_count
      from public.room_players
      where room_id = v_room_id
        and is_alive is true
        and role = 'mafia';

      select count(*)
      into v_citizen_count
      from public.room_players
      where room_id = v_room_id
        and is_alive is true
        and coalesce(role, '') <> 'mafia';

      if v_mafia_count = 0 then
        v_winner := 'citizen';
      elsif v_mafia_count >= v_citizen_count then
        v_winner := 'mafia';
      end if;

      if v_winner is not null then
        update public.games
        set status = 'ended',
            phase = 'ended',
            phase_started_at = now(),
            phase_ends_at = now(),
            updated_at = now()
        where id = v_game.id;

        update public.room_players
        set role = null,
            is_alive = true,
            is_ready = is_host
        where room_id = v_room_id;

        update public.rooms
        set status = 'waiting',
            phase = 'before_start',
            updated_at = now()
        where id = v_room_id;

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
          v_room_id,
          v_game.id,
          v_game.round_no,
          null,
          'System',
          case
            when v_winner = 'citizen' then '시민 진영이 승리했습니다. 마을은 다시 평화를 찾았습니다.'
            else '마피아 진영이 승리했습니다. 어둠이 마을을 삼켰습니다.'
          end,
          'system',
          'game_end',
          true
        )
        on conflict (game_id, round_no, event_key)
        where event_key is not null
        do nothing;

        v_processed_count := v_processed_count + 1;
        continue;
      end if;

      v_next_phase := 'discussion';
      v_duration_seconds := 120;
    elsif v_game.phase in ('day', 'discussion') then
      v_next_phase := 'vote';
      v_duration_seconds := 40;
    elsif v_game.phase = 'vote' then
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

      with vote_counts as (
        select target_user_id, count(*) as vote_count
        from public.game_votes
        where game_id = v_game.id
          and round_no = v_game.round_no
        group by target_user_id
      )
      select string_agg(p.nickname || ' ' || vc.vote_count || '표', ', ' order by vc.vote_count desc, p.nickname)
      into v_vote_tally
      from vote_counts vc
      join public.profiles p on p.id = vc.target_user_id;

      insert into public.game_messages (room_id, game_id, round_no, user_id, nickname, content, message_type, event_key, is_system)
      values (
        v_room_id,
        v_game.id,
        v_game.round_no,
        null,
        'System',
        '투표 결과: ' || coalesce(v_vote_tally, '득표자가 없습니다.'),
        'system',
        'vote_tally',
        true
      )
      on conflict (game_id, round_no, event_key)
      where event_key is not null
      do nothing;

      if v_execution_target is null or v_top_ties > 1 then
        insert into public.game_messages (room_id, game_id, round_no, user_id, nickname, content, message_type, event_key, is_system)
        values (v_room_id, v_game.id, v_game.round_no, null, 'System', '투표가 동점으로 마무리되어 처형하지 않았습니다.', 'system', 'vote_result', true)
        on conflict (game_id, round_no, event_key)
        where event_key is not null
        do nothing;
      elsif v_room.final_defense_enabled is true then
        v_next_phase := 'final_defense';
        v_duration_seconds := 30;
        v_final_defense_target_user_id := v_execution_target;
        select nickname
        into v_target_nickname
        from public.profiles
        where id = v_execution_target;
      else
        update public.room_players
        set is_alive = false
        where room_id = v_room_id
          and user_id = v_execution_target;

        select nickname
        into v_target_nickname
        from public.profiles
        where id = v_execution_target;

        insert into public.game_messages (room_id, game_id, round_no, user_id, nickname, content, message_type, event_key, is_system)
        values (
          v_room_id,
          v_game.id,
          v_game.round_no,
          null,
          'System',
          coalesce(v_target_nickname, '플레이어') || '님이 투표로 처형되었습니다.',
          'system',
          'vote_result',
          true
        )
        on conflict (game_id, round_no, event_key)
        where event_key is not null
        do nothing;
      end if;

      select count(*)
      into v_mafia_count
      from public.room_players
      where room_id = v_room_id
        and is_alive is true
        and role = 'mafia';

      select count(*)
      into v_citizen_count
      from public.room_players
      where room_id = v_room_id
        and is_alive is true
        and coalesce(role, '') <> 'mafia';

      if v_mafia_count = 0 then
        v_winner := 'citizen';
      elsif v_mafia_count >= v_citizen_count then
        v_winner := 'mafia';
      end if;

      if v_winner is not null then
        update public.games
        set status = 'ended',
            phase = 'ended',
            phase_started_at = now(),
            phase_ends_at = now(),
            updated_at = now()
        where id = v_game.id;

        update public.room_players
        set role = null,
            is_alive = true,
            is_ready = is_host
        where room_id = v_room_id;

        update public.rooms
        set status = 'waiting',
            phase = 'before_start',
            updated_at = now()
        where id = v_room_id;

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
          v_room_id,
          v_game.id,
          v_game.round_no,
          null,
          'System',
          case
            when v_winner = 'citizen' then '시민 진영이 승리했습니다. 마을은 다시 평화를 찾았습니다.'
            else '마피아 진영이 승리했습니다. 어둠이 마을을 삼켰습니다.'
          end,
          'system',
          'game_end',
          true
        )
        on conflict (game_id, round_no, event_key)
        where event_key is not null
        do nothing;

        v_processed_count := v_processed_count + 1;
        continue;
      end if;

      if v_next_phase is null then
        v_next_phase := 'result';
        v_duration_seconds := 8;
      end if;
    elsif v_game.phase = 'final_defense' then
      v_final_defense_target_user_id := v_game.final_defense_target_user_id;

      select nickname
      into v_target_nickname
      from public.profiles
      where id = v_final_defense_target_user_id;

      select
        count(*) filter (where approve_execution is true),
        count(*) filter (where approve_execution is false)
      into v_execute_count, v_pardon_count
      from public.game_final_defense_votes
      where game_id = v_game.id
        and round_no = v_game.round_no;

      if v_final_defense_target_user_id is not null and v_execute_count > v_pardon_count then
        update public.room_players
        set is_alive = false
        where room_id = v_room_id
          and user_id = v_final_defense_target_user_id;

        insert into public.game_messages (room_id, game_id, round_no, user_id, nickname, content, message_type, event_key, is_system)
        values (
          v_room_id,
          v_game.id,
          v_game.round_no,
          null,
          'System',
          '최후의 변론 결과: 처형 ' || v_execute_count || '표, 보류 ' || v_pardon_count || '표. ' || coalesce(v_target_nickname, '플레이어') || '님이 처형되었습니다.',
          'system',
          'final_defense_result',
          true
        )
        on conflict (game_id, round_no, event_key)
        where event_key is not null
        do nothing;
      else
        insert into public.game_messages (room_id, game_id, round_no, user_id, nickname, content, message_type, event_key, is_system)
        values (
          v_room_id,
          v_game.id,
          v_game.round_no,
          null,
          'System',
          '최후의 변론 결과: 처형 ' || v_execute_count || '표, 보류 ' || v_pardon_count || '표. 처형이 취소되었습니다.',
          'system',
          'final_defense_result',
          true
        )
        on conflict (game_id, round_no, event_key)
        where event_key is not null
        do nothing;
      end if;

      select count(*)
      into v_mafia_count
      from public.room_players
      where room_id = v_room_id
        and is_alive is true
        and role = 'mafia';

      select count(*)
      into v_citizen_count
      from public.room_players
      where room_id = v_room_id
        and is_alive is true
        and coalesce(role, '') <> 'mafia';

      if v_mafia_count = 0 then
        v_winner := 'citizen';
      elsif v_mafia_count >= v_citizen_count then
        v_winner := 'mafia';
      end if;

      if v_winner is not null then
        update public.games
        set status = 'ended',
            phase = 'ended',
            phase_started_at = now(),
            phase_ends_at = now(),
            final_defense_target_user_id = null,
            updated_at = now()
        where id = v_game.id;

        update public.room_players
        set role = null,
            is_alive = true,
            is_ready = is_host
        where room_id = v_room_id;

        update public.rooms
        set status = 'waiting',
            phase = 'before_start',
            updated_at = now()
        where id = v_room_id;

        insert into public.game_messages (room_id, game_id, round_no, user_id, nickname, content, message_type, event_key, is_system)
        values (
          v_room_id,
          v_game.id,
          v_game.round_no,
          null,
          'System',
          case
            when v_winner = 'citizen' then '시민 진영이 승리했습니다. 마을은 다시 평화를 찾았습니다.'
            else '마피아 진영이 승리했습니다. 어둠이 마을을 삼켰습니다.'
          end,
          'system',
          'game_end',
          true
        )
        on conflict (game_id, round_no, event_key)
        where event_key is not null
        do nothing;

        v_processed_count := v_processed_count + 1;
        continue;
      end if;

      v_next_phase := 'result';
      v_duration_seconds := 8;
    elsif v_game.phase = 'result' then
      v_next_phase := 'night';
      v_duration_seconds := 40;
      update public.games
      set round_no = round_no + 1
      where id = v_game.id;
    else
      continue;
    end if;

    update public.games
    set status = 'playing',
        phase = v_next_phase,
        phase_started_at = now(),
        phase_ends_at = now() + make_interval(secs => greatest(v_duration_seconds, 1)),
        final_defense_target_user_id = case when v_next_phase = 'final_defense' then v_final_defense_target_user_id else null end,
        updated_at = now()
    where id = v_game.id
    returning * into v_game;

    update public.rooms
    set status = 'playing',
        phase = v_next_phase,
        updated_at = now()
    where id = v_room_id;

    if v_next_phase <> 'result' then
      insert into public.game_messages (room_id, game_id, round_no, user_id, nickname, content, message_type, event_key, is_system)
      values (
        v_room_id,
        v_game.id,
        v_game.round_no,
        null,
        'System',
        case v_next_phase
          when 'night' then '밤이 시작되었습니다. 각자 행동을 선택하세요.'
          when 'discussion' then '토론이 시작되었습니다. 채팅으로 의견을 나누세요.'
          when 'vote' then '투표가 시작되었습니다. 처형할 대상을 선택하세요.'
          when 'final_defense' then coalesce(v_target_nickname, '플레이어') || '님의 최후의 변론이 시작되었습니다. 처형 여부를 결정하세요.'
          else '다음 단계로 진행합니다.'
        end,
        'system',
        case v_next_phase
          when 'night' then 'night_start'
          when 'discussion' then 'day_start'
          when 'vote' then 'vote_start'
          when 'final_defense' then 'final_defense_start'
          else 'phase_start'
        end,
        true
      )
      on conflict (game_id, round_no, event_key)
      where event_key is not null
      do nothing;
    end if;

    v_processed_count := v_processed_count + 1;
  end loop;

  return v_processed_count;
end;
$$;

drop function if exists public.skip_current_phase(uuid);

create or replace function public.skip_current_phase(p_room_id uuid)
returns public.games
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_room public.rooms;
  v_game public.games;
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
    raise exception '방장만 현재 단계를 스킵할 수 있습니다.';
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
    raise exception '진행 중인 게임이 없습니다.';
  end if;

  if v_room.status <> 'playing' then
    raise exception '진행 중인 게임만 스킵할 수 있습니다.';
  end if;

  update public.games
  set phase_ends_at = now() - interval '1 millisecond',
      updated_at = now()
  where id = v_game.id;

  perform public.process_due_game_phases();

  select *
  into v_game
  from public.games
  where id = v_game.id;

  return v_game;
end;
$$;

grant execute on function public.skip_current_phase(uuid) to authenticated;

create extension if not exists pg_cron;

select cron.schedule(
  'game-phase-auto-advance',
  '5 seconds',
  $$
  select public.process_due_game_phases();
  $$
);
