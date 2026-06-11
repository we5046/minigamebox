import { createSupabaseError, supabase } from './supabaseClient'

async function callAdminRpc(name, params = {}, userMessage) {
  const { data, error } = await supabase.rpc(name, params)

  if (error) {
    throw createSupabaseError(`adminApi: ${name} failed`, error, userMessage)
  }

  return data
}

export function getMyAccessContext() {
  return callAdminRpc('get_my_access_context', {}, '계정 권한을 확인하지 못했습니다.')
}

export function getAdminUsers() {
  return callAdminRpc('admin_list_users', {}, '사용자 목록을 불러오지 못했습니다.')
}

export function getAdminRooms() {
  return callAdminRpc('admin_list_rooms', {}, '방 목록을 불러오지 못했습니다.')
}

export function setAdminUserRole(userId, role, reason) {
  return callAdminRpc(
    'admin_set_user_role',
    { p_target_user_id: userId, p_role: role, p_reason: reason },
    '사용자 권한을 변경하지 못했습니다.',
  )
}

export function applyAdminSanction(userId, sanctionType, reason, durationHours = null) {
  return callAdminRpc(
    'admin_apply_sanction',
    {
      p_target_user_id: userId,
      p_sanction_type: sanctionType,
      p_reason: reason,
      p_duration_hours: durationHours,
    },
    '사용자 제재를 적용하지 못했습니다.',
  )
}

export function revokeAdminSanctions(userId, sanctionType, reason) {
  return callAdminRpc(
    'admin_revoke_sanctions',
    { p_target_user_id: userId, p_sanction_type: sanctionType, p_reason: reason },
    '사용자 제재를 해제하지 못했습니다.',
  )
}

export function deleteRoomAsAdmin(roomId, reason) {
  return callAdminRpc(
    'admin_delete_room',
    { p_room_id: roomId, p_reason: reason },
    '방을 삭제하지 못했습니다.',
  )
}
