import { supabase } from './supabaseClient'

const inviteSelect = `
  *,
  room:rooms (
    id,
    title,
    status,
    max_players,
    description,
    host_nickname,
    entry_mode,
    room_players (
      user_id
    )
  ),
  inviter:profiles!room_invites_from_user_id_fkey (
    id,
    nickname,
    avatar,
    level
  ),
  receiver:profiles!room_invites_to_user_id_fkey (
    id,
    nickname,
    avatar,
    level
  )
`

const inviteChannels = new Map()

export function normalizeRoomInvite(row) {
  const roomPlayers = row.room?.room_players || []

  return {
    id: row.id,
    roomId: row.room_id,
    fromUserId: row.from_user_id,
    toUserId: row.to_user_id,
    status: row.status,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    expiresAt: row.expires_at,
    room: {
      id: row.room?.id || row.room_id,
      title: row.room?.title || 'Unknown Room',
      status: row.room?.status || 'waiting',
      maxPlayers: row.room?.max_players || 8,
      description: row.room?.description || '',
      hostNickname: row.room?.host_nickname || 'Unknown',
      entryMode: row.room?.entry_mode || 'public',
      currentPlayers: roomPlayers.length,
    },
    inviter: {
      id: row.inviter?.id || row.from_user_id,
      nickname: row.inviter?.nickname || 'Unknown',
      avatar: row.inviter?.avatar || 'default-mafia',
      level: row.inviter?.level || 1,
    },
    receiver: {
      id: row.receiver?.id || row.to_user_id,
      nickname: row.receiver?.nickname || 'Unknown',
      avatar: row.receiver?.avatar || 'default-mafia',
      level: row.receiver?.level || 1,
    },
  }
}

export async function getIncomingRoomInvites(userId) {
  const { data, error } = await supabase
    .from('room_invites')
    .select(inviteSelect)
    .eq('to_user_id', userId)
    .eq('status', 'pending')
    .gt('expires_at', new Date().toISOString())
    .order('updated_at', { ascending: false })

  if (error) {
    throw new Error('방 초대 목록을 불러오지 못했습니다.')
  }

  return data.map(normalizeRoomInvite)
}

export async function getRoomInvites(roomId, fromUserId) {
  const { data, error } = await supabase
    .from('room_invites')
    .select(inviteSelect)
    .eq('room_id', roomId)
    .eq('from_user_id', fromUserId)
    .eq('status', 'pending')
    .gt('expires_at', new Date().toISOString())

  if (error) {
    throw new Error('보낸 초대 목록을 불러오지 못했습니다.')
  }

  return data.map(normalizeRoomInvite)
}

export async function sendRoomInvite(roomId, targetUserId) {
  const { error } = await supabase.rpc('send_room_invite', {
    p_room_id: roomId,
    p_target_user_id: targetUserId,
  })

  if (error) {
    throw new Error('방 초대를 보내지 못했습니다.')
  }
}

export async function respondRoomInvite(inviteId, accept) {
  const { data, error } = await supabase.rpc('respond_room_invite', {
    p_invite_id: inviteId,
    p_accept: accept,
  })

  if (error) {
    throw new Error('방 초대를 처리하지 못했습니다.')
  }

  return normalizeRoomInvite(data)
}

export function subscribeToRoomInvites(userId, callback) {
  unsubscribeFromRoomInvites(userId)

  const channel = supabase
    .channel(`room-invites-${userId}`)
    .on('postgres_changes', { event: '*', schema: 'public', table: 'room_invites' }, (payload) => {
      const fromUserId = payload.new?.from_user_id || payload.old?.from_user_id
      const toUserId = payload.new?.to_user_id || payload.old?.to_user_id

      if (fromUserId === userId || toUserId === userId) {
        callback(payload)
      }
    })
    .subscribe((status) => {
      callback({ type: 'subscription-status', status })
    })

  inviteChannels.set(userId, channel)

  return () => unsubscribeFromRoomInvites(userId)
}

function unsubscribeFromRoomInvites(userId) {
  const channel = inviteChannels.get(userId)

  if (!channel) {
    return
  }

  inviteChannels.delete(userId)
  supabase.removeChannel(channel)
}
