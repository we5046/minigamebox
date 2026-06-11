-- Administrative access foundation for Minigamebox.
-- Apply after the base profiles, rooms, and room_players tables exist.

begin;

create schema if not exists private;

create table if not exists public.user_roles (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  role text not null default 'user' check (role in ('user', 'admin')),
  updated_at timestamptz not null default now()
);

create table if not exists public.user_sanctions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  sanction_type text not null check (sanction_type in ('account', 'chat')),
  reason text not null,
  starts_at timestamptz not null default now(),
  ends_at timestamptz,
  revoked_at timestamptz,
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  check (ends_at is null or ends_at > starts_at)
);

create index if not exists user_sanctions_active_user_idx
  on public.user_sanctions (user_id, sanction_type, ends_at)
  where revoked_at is null;

create table if not exists public.admin_audit_logs (
  id bigint generated always as identity primary key,
  admin_user_id uuid not null references public.profiles(id),
  action text not null,
  target_user_id uuid references public.profiles(id),
  target_room_id uuid references public.rooms(id) on delete set null,
  reason text,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

alter table public.user_roles enable row level security;
alter table public.user_sanctions enable row level security;
alter table public.admin_audit_logs enable row level security;

revoke all on table public.user_roles, public.user_sanctions, public.admin_audit_logs
  from public, anon, authenticated;

create or replace function private.is_admin(p_user_id uuid default auth.uid())
returns boolean
language sql
security definer
stable
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.user_roles
    where user_id = p_user_id
      and role = 'admin'
  );
$$;

create or replace function private.has_active_sanction(
  p_user_id uuid,
  p_sanction_type text
)
returns boolean
language sql
security definer
stable
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.user_sanctions
    where user_id = p_user_id
      and sanction_type = p_sanction_type
      and revoked_at is null
      and starts_at <= now()
      and (ends_at is null or ends_at > now())
  );
$$;

create or replace function public.get_my_access_context()
returns jsonb
language sql
security definer
stable
set search_path = public, private, pg_temp
as $$
  select jsonb_build_object(
    'role', coalesce((select role from public.user_roles where user_id = auth.uid()), 'user'),
    'accountSuspended', private.has_active_sanction(auth.uid(), 'account'),
    'chatSuspended', private.has_active_sanction(auth.uid(), 'chat')
  );
$$;

create or replace function public.assert_can_chat()
returns void
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;
  if private.has_active_sanction(auth.uid(), 'account') then
    raise exception 'Account suspended';
  end if;
  if private.has_active_sanction(auth.uid(), 'chat') then
    raise exception 'Chat suspended';
  end if;
end;
$$;

create or replace function public.admin_list_users()
returns table (
  user_id uuid,
  login_id text,
  nickname text,
  role text,
  account_suspended boolean,
  chat_suspended boolean
)
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
begin
  if not private.is_admin() then
    raise exception 'Admin permission required';
  end if;

  return query
  select
    profile.id,
    profile.login_id,
    profile.nickname,
    coalesce(user_role.role, 'user'),
    private.has_active_sanction(profile.id, 'account'),
    private.has_active_sanction(profile.id, 'chat')
  from public.profiles profile
  left join public.user_roles user_role on user_role.user_id = profile.id
  order by profile.nickname;
end;
$$;

create or replace function public.admin_list_rooms()
returns table (
  room_id uuid,
  title text,
  status text,
  game_type text,
  host_user_id uuid,
  host_nickname text,
  player_count bigint
)
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
begin
  if not private.is_admin() then
    raise exception 'Admin permission required';
  end if;

  return query
  select
    room.id,
    room.title,
    room.status,
    room.game_type,
    room.host_user_id,
    profile.nickname,
    count(player.user_id)
  from public.rooms room
  left join public.profiles profile on profile.id = room.host_user_id
  left join public.room_players player on player.room_id = room.id
  group by room.id, profile.nickname
  order by room.created_at desc;
end;
$$;

create or replace function public.admin_set_user_role(
  p_target_user_id uuid,
  p_role text,
  p_reason text
)
returns void
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
begin
  if not private.is_admin() then
    raise exception 'Admin permission required';
  end if;
  if p_role not in ('user', 'admin') then
    raise exception 'Invalid role';
  end if;
  if nullif(trim(p_reason), '') is null then
    raise exception 'Reason is required';
  end if;
  if p_target_user_id = auth.uid() and p_role <> 'admin' then
    raise exception 'Cannot remove your own admin role';
  end if;

  insert into public.user_roles (user_id, role)
  values (p_target_user_id, p_role)
  on conflict (user_id) do update
    set role = excluded.role, updated_at = now();

  insert into public.admin_audit_logs (
    admin_user_id, action, target_user_id, reason, details
  ) values (
    auth.uid(), 'set_user_role', p_target_user_id, trim(p_reason),
    jsonb_build_object('role', p_role)
  );
end;
$$;

create or replace function public.admin_apply_sanction(
  p_target_user_id uuid,
  p_sanction_type text,
  p_reason text,
  p_duration_hours integer default null
)
returns uuid
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_sanction_id uuid;
begin
  if not private.is_admin() then
    raise exception 'Admin permission required';
  end if;
  if p_sanction_type not in ('account', 'chat') then
    raise exception 'Invalid sanction type';
  end if;
  if nullif(trim(p_reason), '') is null then
    raise exception 'Reason is required';
  end if;
  if p_target_user_id = auth.uid() then
    raise exception 'Cannot sanction yourself';
  end if;
  if p_duration_hours is not null and p_duration_hours < 1 then
    raise exception 'Duration must be at least one hour';
  end if;

  insert into public.user_sanctions (
    user_id, sanction_type, reason, ends_at, created_by
  ) values (
    p_target_user_id,
    p_sanction_type,
    trim(p_reason),
    case when p_duration_hours is null then null else now() + make_interval(hours => p_duration_hours) end,
    auth.uid()
  )
  returning id into v_sanction_id;

  insert into public.admin_audit_logs (
    admin_user_id, action, target_user_id, reason, details
  ) values (
    auth.uid(), 'apply_sanction', p_target_user_id, trim(p_reason),
    jsonb_build_object('sanctionType', p_sanction_type, 'durationHours', p_duration_hours)
  );

  return v_sanction_id;
end;
$$;

create or replace function public.admin_revoke_sanctions(
  p_target_user_id uuid,
  p_sanction_type text,
  p_reason text
)
returns void
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
begin
  if not private.is_admin() then
    raise exception 'Admin permission required';
  end if;
  if p_sanction_type not in ('account', 'chat') then
    raise exception 'Invalid sanction type';
  end if;
  if nullif(trim(p_reason), '') is null then
    raise exception 'Reason is required';
  end if;

  update public.user_sanctions
  set revoked_at = now()
  where user_id = p_target_user_id
    and sanction_type = p_sanction_type
    and revoked_at is null
    and (ends_at is null or ends_at > now());

  insert into public.admin_audit_logs (
    admin_user_id, action, target_user_id, reason, details
  ) values (
    auth.uid(), 'revoke_sanctions', p_target_user_id, trim(p_reason),
    jsonb_build_object('sanctionType', p_sanction_type)
  );
end;
$$;

create or replace function public.admin_delete_room(
  p_room_id uuid,
  p_reason text
)
returns void
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
begin
  if not private.is_admin() then
    raise exception 'Admin permission required';
  end if;
  if nullif(trim(p_reason), '') is null then
    raise exception 'Reason is required';
  end if;
  if not exists (select 1 from public.rooms where id = p_room_id) then
    raise exception 'Room not found';
  end if;

  insert into public.admin_audit_logs (
    admin_user_id, action, target_room_id, reason
  ) values (
    auth.uid(), 'delete_room', p_room_id, trim(p_reason)
  );

  delete from public.rooms where id = p_room_id;
end;
$$;

revoke all on function private.is_admin(uuid), private.has_active_sanction(uuid, text)
  from public, anon, authenticated;
revoke all on function public.get_my_access_context(),
  public.assert_can_chat(),
  public.admin_list_users(),
  public.admin_list_rooms(),
  public.admin_set_user_role(uuid, text, text),
  public.admin_apply_sanction(uuid, text, text, integer),
  public.admin_revoke_sanctions(uuid, text, text),
  public.admin_delete_room(uuid, text)
  from public, anon;

grant execute on function public.get_my_access_context() to authenticated;
grant execute on function public.assert_can_chat() to authenticated;
grant execute on function public.admin_list_users(),
  public.admin_list_rooms(),
  public.admin_set_user_role(uuid, text, text),
  public.admin_apply_sanction(uuid, text, text, integer),
  public.admin_revoke_sanctions(uuid, text, text),
  public.admin_delete_room(uuid, text)
  to authenticated;

commit;

-- Bootstrap the first administrator manually in the Supabase SQL editor:
-- insert into public.user_roles (user_id, role)
-- select id, 'admin' from public.profiles where login_id = 'YOUR_LOGIN_ID'
-- on conflict (user_id) do update set role = excluded.role, updated_at = now();
