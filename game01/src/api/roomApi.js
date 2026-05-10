import { supabase } from './supabaseClient'

function toPlayer(row) {
  return {
    userId: row.user_id,
    nickname: row.profiles?.nickname || 'Unknown',
    avatar: row.profiles?.avatar || 'default-mafia',
    level: row.profiles?.level || 1,
    title: row.profiles?.representative_title || '초보 마피아',
    isHost: row.is_host,
    isReady: row.is_ready,
    joinedAt: row.joined_at,
  }
}

export function normalizeRoom(room) {
  const players = (room.room_players || [])
    .map(toPlayer)
    .sort((a, b) => new Date(a.joinedAt) - new Date(b.joinedAt))
  const hostPlayer = players.find((player) => player.userId === room.host_user_id)

  return {
    id: room.id,
    title: room.title,
    description: room.description || '',
    code: room.code,
    hostUserId: room.host_user_id,
    hostNickname: hostPlayer?.nickname || room.host_nickname || 'Unknown',
    status: room.status,
    maxPlayers: room.max_players,
    currentPlayers: players.length,
    phase: room.phase,
    createdAt: room.created_at,
    players,
  }
}

const roomSelect = `
  *,
  room_players (
    user_id,
    is_host,
    is_ready,
    joined_at,
    profiles (
      nickname,
      avatar,
      level,
      representative_title
    )
  )
`

export async function getRooms() {
  const { data, error } = await supabase
    .from('rooms')
    .select(roomSelect)
    .order('created_at', { ascending: false })

  if (error) {
    throw new Error('방 목록을 불러오지 못했습니다.')
  }

  return data.map(normalizeRoom)
}

export async function getRoom(roomId) {
  const { data, error } = await supabase.from('rooms').select(roomSelect).eq('id', roomId).single()

  if (error) {
    throw new Error('방 정보를 불러오지 못했습니다.')
  }

  return normalizeRoom(data)
}

export async function createRoom({ hostUser, title, description, maxPlayers }) {
  const { data: room, error } = await supabase.rpc('create_room', {
    p_title: title.trim(),
    p_description: description.trim(),
    p_max_players: maxPlayers,
  })

  if (error) {
    throw new Error('방 생성에 실패했습니다.')
  }

  return getRoom(room.id)
}

export async function joinRoom(roomId, user) {
  const room = await getRoom(roomId)

  if (room.players.some((player) => player.userId === user.id)) {
    return room
  }

  if (room.players.length >= room.maxPlayers) {
    throw new Error('방 인원이 가득 찼습니다.')
  }

  const { error } = await supabase.from('room_players').insert({
    room_id: roomId,
    user_id: user.id,
    is_host: room.players.length === 0,
    is_ready: false,
  })

  if (error) {
    throw new Error('방 참가에 실패했습니다.')
  }

  return getRoom(roomId)
}

export async function updateRoom(roomId, payload) {
  if (payload.players) {
    const results = await Promise.all(
      payload.players.map((player) =>
        supabase
          .from('room_players')
          .update({
            is_ready: player.isReady,
            is_host: player.isHost,
          })
          .eq('room_id', roomId)
          .eq('user_id', player.userId),
      ),
    )

    const failedResult = results.find((result) => result.error)

    if (failedResult) {
      throw new Error('참가자 정보를 갱신하지 못했습니다.')
    }
  }

  const roomPayload = {}

  if (payload.title) roomPayload.title = payload.title.trim()
  if (typeof payload.description === 'string') roomPayload.description = payload.description.trim()
  if (payload.hostUserId) roomPayload.host_user_id = payload.hostUserId
  if (payload.status) roomPayload.status = payload.status
  if (payload.phase) roomPayload.phase = payload.phase

  if (Object.keys(roomPayload).length > 0) {
    const { error } = await supabase.from('rooms').update(roomPayload).eq('id', roomId)

    if (error) {
      throw new Error('방 정보를 갱신하지 못했습니다.')
    }
  }

  return getRoom(roomId)
}

export async function setPlayerReady(roomId, userId, isReady) {
  const { error } = await supabase
    .from('room_players')
    .update({ is_ready: isReady })
    .eq('room_id', roomId)
    .eq('user_id', userId)

  if (error) {
    throw new Error('준비 상태를 갱신하지 못했습니다.')
  }

  return getRoom(roomId)
}

export async function leaveRoom(roomId, userId) {
  const { error } = await supabase.rpc('leave_room', {
    p_room_id: roomId,
  })

  if (error) {
    throw new Error('방 나가기에 실패했습니다.')
  }

  return null
}

export async function deleteRoom(roomId) {
  const { error } = await supabase.from('rooms').delete().eq('id', roomId)

  if (error) {
    throw new Error('방 삭제에 실패했습니다.')
  }
}

export function subscribeToRooms(callback) {
  const channelName = `rooms-changes-${Date.now()}-${Math.random().toString(36).slice(2)}`
  const channel = supabase
    .channel(channelName)
    .on('postgres_changes', { event: '*', schema: 'public', table: 'rooms' }, callback)
    .on('postgres_changes', { event: '*', schema: 'public', table: 'room_players' }, callback)
    .subscribe((status) => {
      callback({ type: 'subscription-status', status })
    })

  return () => {
    supabase.removeChannel(channel)
  }
}

export function subscribeToRoom(roomId, callback) {
  const channel = supabase
    .channel(`room-${roomId}`)
    .on(
      'postgres_changes',
      { event: '*', schema: 'public', table: 'rooms', filter: `id=eq.${roomId}` },
      callback,
    )
    .on(
      'postgres_changes',
      { event: '*', schema: 'public', table: 'room_players', filter: `room_id=eq.${roomId}` },
      callback,
    )
    .subscribe((status) => {
      callback({ type: 'subscription-status', status })
    })

  return () => {
    supabase.removeChannel(channel)
  }
}
