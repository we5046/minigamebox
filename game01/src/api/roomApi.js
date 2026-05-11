import { supabase } from './supabaseClient'

const roomListChannels = new Map()
const roomDetailChannels = new Map()
const ROOM_LIST_CHANNEL_KEY = 'rooms-list'

function toPlayer(row) {
  return {
    userId: row.user_id,
    nickname: row.profiles?.nickname || 'Unknown',
    avatar: row.profiles?.avatar || 'default-mafia',
    level: row.profiles?.level || 1,
    title: row.profiles?.representative_title || 'Rookie Mafia',
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
    nightTimeSeconds: room.night_time_seconds || 30,
    voteTimeSeconds: room.vote_time_seconds || 15,
    roleRevealMode: room.role_reveal_mode || 'private',
    entryMode: room.entry_mode || 'public',
    roleConfig: room.role_config || null,
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
    throw new Error('Failed to load room list.')
  }

  return data.map(normalizeRoom)
}

export async function getRoom(roomId) {
  const { data, error } = await supabase.from('rooms').select(roomSelect).eq('id', roomId).single()

  if (error) {
    throw new Error('Failed to load room information.')
  }

  return normalizeRoom(data)
}

export async function createRoom({
  title,
  description,
  maxPlayers,
  nightTimeSeconds = 30,
  voteTimeSeconds = 15,
  roleRevealMode = 'private',
  entryMode = 'public',
  roleConfig = null,
}) {
  const { data: room, error } = await supabase.rpc('create_room', {
    p_title: title.trim(),
    p_description: description.trim(),
    p_max_players: maxPlayers,
    p_night_time_seconds: nightTimeSeconds,
    p_vote_time_seconds: voteTimeSeconds,
    p_role_reveal_mode: roleRevealMode,
    p_entry_mode: entryMode,
    p_role_config: roleConfig,
  })

  if (error) {
    throw new Error('Failed to create room.')
  }

  return getRoom(room.id)
}

export async function joinRoom(roomId) {
  const { error } = await supabase.rpc('join_room', {
    p_room_id: roomId,
  })

  if (error) {
    throw new Error('Failed to join room.')
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
      throw new Error('Failed to update player information.')
    }
  }

  const roomPayload = {}

  if (payload.title) roomPayload.title = payload.title.trim()
  if (typeof payload.description === 'string') roomPayload.description = payload.description.trim()
  if (payload.hostUserId) roomPayload.host_user_id = payload.hostUserId
  if (payload.status) roomPayload.status = payload.status
  if (payload.phase) roomPayload.phase = payload.phase
  if (payload.maxPlayers) roomPayload.max_players = payload.maxPlayers
  if (payload.nightTimeSeconds) roomPayload.night_time_seconds = payload.nightTimeSeconds
  if (payload.voteTimeSeconds) roomPayload.vote_time_seconds = payload.voteTimeSeconds
  if (payload.roleRevealMode) roomPayload.role_reveal_mode = payload.roleRevealMode
  if (payload.entryMode) roomPayload.entry_mode = payload.entryMode
  if (payload.roleConfig) roomPayload.role_config = payload.roleConfig

  if (Object.keys(roomPayload).length > 0) {
    const { error } = await supabase.from('rooms').update(roomPayload).eq('id', roomId)

    if (error) {
      throw new Error('Failed to update room information.')
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
    throw new Error('Failed to update ready status.')
  }

  return getRoom(roomId)
}

export async function leaveRoom(roomId) {
  const { error } = await supabase.rpc('leave_room', {
    p_room_id: roomId,
  })

  if (error) {
    throw new Error('Failed to leave room.')
  }

  return null
}

export async function deleteRoom(roomId) {
  const { error } = await supabase.from('rooms').delete().eq('id', roomId)

  if (error) {
    throw new Error('Failed to delete room.')
  }
}

export function subscribeToRooms(callback) {
  const channelName = `rooms-changes-${Date.now()}-${Math.random().toString(36).slice(2)}`
  unsubscribeFromRooms(ROOM_LIST_CHANNEL_KEY)

  const channel = supabase
    .channel(channelName)
    .on('postgres_changes', { event: '*', schema: 'public', table: 'rooms' }, callback)
    .on('postgres_changes', { event: '*', schema: 'public', table: 'room_players' }, callback)
    .subscribe((status) => {
      callback({ type: 'subscription-status', status })
    })

  roomListChannels.set(ROOM_LIST_CHANNEL_KEY, channel)

  return () => unsubscribeFromRooms(ROOM_LIST_CHANNEL_KEY)
}

export function subscribeToRoom(roomId, callback) {
  unsubscribeFromRoom(roomId)

  const handleRoomPlayerChange = (payload) => {
    const changedRoomId = payload.new?.room_id || payload.old?.room_id
    if (changedRoomId === roomId) {
      callback(payload)
    }
  }

  const channel = supabase
    .channel(`room-${roomId}`)
    .on(
      'postgres_changes',
      { event: '*', schema: 'public', table: 'rooms', filter: `id=eq.${roomId}` },
      callback,
    )
    .on(
      'postgres_changes',
      { event: '*', schema: 'public', table: 'room_players' },
      handleRoomPlayerChange,
    )
    .subscribe((status) => {
      callback({ type: 'subscription-status', status })
    })

  roomDetailChannels.set(roomId, channel)

  return () => unsubscribeFromRoom(roomId)
}

function unsubscribeFromRooms(channelName) {
  const channel = roomListChannels.get(channelName)

  if (!channel) {
    return
  }

  roomListChannels.delete(channelName)
  supabase.removeChannel(channel)
}

function unsubscribeFromRoom(roomId) {
  const channel = roomDetailChannels.get(roomId)

  if (!channel) {
    return
  }

  roomDetailChannels.delete(roomId)
  supabase.removeChannel(channel)
}
