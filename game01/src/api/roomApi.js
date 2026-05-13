import { createSupabaseError, supabase } from './supabaseClient'

const roomListChannels = new Map()
const roomDetailChannels = new Map()
const ROOM_LIST_CHANNEL_KEY = 'rooms-list'

export const DEFAULT_ROOM_DETAIL_SETTINGS = {
  nightTimeSeconds: 30,
  discussionTimeSeconds: 60,
  voteTimeSeconds: 15,
  minStartPlayers: 4,
  tieVoteRule: 'no_execution',
  spectatorAllowed: false,
  firstNightAbilityAllowed: true,
}

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
    nightTimeSeconds:
      room.night_time_seconds ?? DEFAULT_ROOM_DETAIL_SETTINGS.nightTimeSeconds,
    voteTimeSeconds:
      room.vote_time_seconds ?? DEFAULT_ROOM_DETAIL_SETTINGS.voteTimeSeconds,
    discussionTimeSeconds:
      room.discussion_time_seconds ?? DEFAULT_ROOM_DETAIL_SETTINGS.discussionTimeSeconds,
    minStartPlayers:
      room.min_start_players ?? DEFAULT_ROOM_DETAIL_SETTINGS.minStartPlayers,
    tieVoteRule: room.tie_vote_rule || DEFAULT_ROOM_DETAIL_SETTINGS.tieVoteRule,
    spectatorAllowed:
      room.spectator_allowed ?? DEFAULT_ROOM_DETAIL_SETTINGS.spectatorAllowed,
    firstNightAbilityAllowed:
      room.first_night_ability_allowed ??
      DEFAULT_ROOM_DETAIL_SETTINGS.firstNightAbilityAllowed,
    roleRevealMode: room.role_reveal_mode || 'private',
    entryMode: room.entry_mode || 'public',
    entryPassword: room.entry_password || '',
    roleConfig: room.role_config || null,
    currentPlayers: players.length,
    phase: room.phase,
    createdAt: room.created_at,
    players,
  }
}

const roomSelect = `
  id,
  title,
  description,
  code,
  host_user_id,
  status,
  max_players,
  phase,
  night_time_seconds,
  vote_time_seconds,
  discussion_time_seconds,
  min_start_players,
  tie_vote_rule,
  spectator_allowed,
  first_night_ability_allowed,
  role_reveal_mode,
  entry_mode,
  entry_password,
  role_config,
  updated_at,
  created_at,
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
    throw createSupabaseError('getRooms: rooms select failed', error, 'Failed to load room list.')
  }

  return data.map(normalizeRoom)
}

export async function getRoom(roomId) {
  const { data, error } = await supabase.from('rooms').select(roomSelect).eq('id', roomId).single()

  if (error) {
    throw createSupabaseError('getRoom: room select failed', error, 'Failed to load room information.')
  }

  return normalizeRoom(data)
}

export async function createRoom({
  title,
  description,
  maxPlayers,
  nightTimeSeconds = DEFAULT_ROOM_DETAIL_SETTINGS.nightTimeSeconds,
  voteTimeSeconds = DEFAULT_ROOM_DETAIL_SETTINGS.voteTimeSeconds,
  discussionTimeSeconds = DEFAULT_ROOM_DETAIL_SETTINGS.discussionTimeSeconds,
  minStartPlayers = DEFAULT_ROOM_DETAIL_SETTINGS.minStartPlayers,
  tieVoteRule = DEFAULT_ROOM_DETAIL_SETTINGS.tieVoteRule,
  spectatorAllowed = DEFAULT_ROOM_DETAIL_SETTINGS.spectatorAllowed,
  firstNightAbilityAllowed = DEFAULT_ROOM_DETAIL_SETTINGS.firstNightAbilityAllowed,
  roleRevealMode = 'private',
  entryMode = 'public',
  entryPassword = '',
  roleConfig = null,
}) {
  const { data: room, error } = await supabase.rpc('create_room', {
    p_title: title.trim(),
    p_description: description.trim(),
    p_max_players: maxPlayers,
    p_night_time_seconds: nightTimeSeconds,
    p_vote_time_seconds: voteTimeSeconds,
    p_discussion_time_seconds: discussionTimeSeconds,
    p_min_start_players: minStartPlayers,
    p_tie_vote_rule: tieVoteRule,
    p_spectator_allowed: spectatorAllowed,
    p_first_night_ability_allowed: firstNightAbilityAllowed,
    p_role_reveal_mode: roleRevealMode,
    p_entry_mode: entryMode,
    p_entry_password: entryPassword,
    p_role_config: roleConfig,
  })

  if (error) {
    throw createSupabaseError('createRoom: create_room rpc failed', error, 'Failed to create room.')
  }

  if (!room?.id) {
    console.error('[Supabase] createRoom: create_room rpc returned invalid payload', { room })
    throw new Error('Failed to create room.')
  }

  return getRoom(room.id)
}

export async function joinRoom(roomId, entryPassword = '') {
  const { error } = await supabase.rpc('join_room', {
    p_room_id: roomId,
    p_entry_password: entryPassword,
  })

  if (error) {
    throw createSupabaseError('joinRoom: join_room rpc failed', error, 'Failed to join room.')
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
      throw createSupabaseError('updateRoom: room_players update failed', failedResult.error, 'Failed to update player information.')
    }
  }

  const roomPayload = {}

  if (payload.title) roomPayload.title = payload.title.trim()
  if (typeof payload.description === 'string') roomPayload.description = payload.description.trim()
  if (payload.hostUserId) roomPayload.host_user_id = payload.hostUserId
  if (payload.status) roomPayload.status = payload.status
  if (payload.phase) roomPayload.phase = payload.phase
  if (payload.maxPlayers) roomPayload.max_players = payload.maxPlayers
  if (Object.prototype.hasOwnProperty.call(payload, 'nightTimeSeconds')) {
    roomPayload.night_time_seconds = payload.nightTimeSeconds
  }
  if (Object.prototype.hasOwnProperty.call(payload, 'voteTimeSeconds')) {
    roomPayload.vote_time_seconds = payload.voteTimeSeconds
  }
  if (Object.prototype.hasOwnProperty.call(payload, 'discussionTimeSeconds')) {
    roomPayload.discussion_time_seconds = payload.discussionTimeSeconds
  }
  if (Object.prototype.hasOwnProperty.call(payload, 'minStartPlayers')) {
    roomPayload.min_start_players = payload.minStartPlayers
  }
  if (Object.prototype.hasOwnProperty.call(payload, 'tieVoteRule')) {
    roomPayload.tie_vote_rule = payload.tieVoteRule
  }
  if (Object.prototype.hasOwnProperty.call(payload, 'spectatorAllowed')) {
    roomPayload.spectator_allowed = payload.spectatorAllowed
  }
  if (Object.prototype.hasOwnProperty.call(payload, 'firstNightAbilityAllowed')) {
    roomPayload.first_night_ability_allowed = payload.firstNightAbilityAllowed
  }
  if (payload.roleRevealMode) roomPayload.role_reveal_mode = payload.roleRevealMode
  if (payload.entryMode) roomPayload.entry_mode = payload.entryMode
  if (Object.prototype.hasOwnProperty.call(payload, 'entryPassword')) {
    roomPayload.entry_password = payload.entryPassword || ''
  }
  if (payload.roleConfig) roomPayload.role_config = payload.roleConfig
  roomPayload.updated_at = new Date().toISOString()

  if (Object.keys(roomPayload).length > 0) {
    const { data, error } = await supabase
      .from('rooms')
      .update(roomPayload)
      .eq('id', roomId)
      .select(roomSelect)
      .single()

    if (error) {
      throw createSupabaseError('updateRoom: rooms update failed', error, 'Failed to update room information.')
    }

    if (!data?.id) {
      console.error('[Supabase] updateRoom: rooms update returned invalid payload', { data })
      throw new Error('Failed to update room information.')
    }

    return normalizeRoom(data)
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
    throw createSupabaseError('setPlayerReady: room_players update failed', error, 'Failed to update ready status.')
  }

  return getRoom(roomId)
}

export async function leaveRoom(roomId) {
  const { error } = await supabase.rpc('leave_room', {
    p_room_id: roomId,
  })

  if (error) {
    throw createSupabaseError('leaveRoom: leave_room rpc failed', error, 'Failed to leave room.')
  }

  return null
}

export async function deleteRoom(roomId) {
  const { error } = await supabase.from('rooms').delete().eq('id', roomId)

  if (error) {
    throw createSupabaseError('deleteRoom: rooms delete failed', error, 'Failed to delete room.')
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
