import { createSupabaseError, supabase } from './supabaseClient'

const roomListChannels = new Map()
const roomDetailChannels = new Map()
const gameChannels = new Map()
const ROOM_LIST_CHANNEL_KEY = 'rooms-list'
const ROOM_PLAYER_STALE_MS = 45_000

export const DEFAULT_ROOM_DETAIL_SETTINGS = {
  nightTimeSeconds: 30,
  discussionTimeSeconds: 60,
  voteTimeSeconds: 15,
  minStartPlayers: 4,
  tieVoteRule: 'no_execution',
  spectatorAllowed: false,
  firstNightAbilityAllowed: true,
  finalDefenseEnabled: false,
}

function toPlayer(row) {
  const lastSeenAt = row.last_seen_at || row.joined_at
  const lastSeenTime = lastSeenAt ? new Date(lastSeenAt).getTime() : 0
  const isStale = lastSeenTime > 0 && Date.now() - lastSeenTime > ROOM_PLAYER_STALE_MS
  const connectionStatus = isStale ? 'disconnected' : row.connection_status || 'active'

  return {
    userId: row.user_id,
    nickname: row.profiles?.nickname || '알 수 없음',
    avatar: row.profiles?.avatar || 'default-mafia',
    level: row.profiles?.level || 1,
    title: row.profiles?.representative_title || 'Rookie Mafia',
    isHost: row.is_host,
    isReady: row.is_ready,
    isAlive: row.is_alive !== false,
    connectionStatus,
    isConnected: connectionStatus === 'active',
    lastSeenAt,
    disconnectedAt: row.disconnected_at || null,
    joinedAt: row.joined_at,
  }
}

export function normalizeRoom(room) {
  const allPlayers = (room.room_players || [])
    .map(toPlayer)
    .sort((a, b) => new Date(a.joinedAt) - new Date(b.joinedAt))
  const players =
    room.status === 'waiting'
      ? allPlayers.filter((player) => player.isConnected)
      : allPlayers
  const hostPlayer = players.find((player) => player.userId === room.host_user_id)

  return {
    id: room.id,
    title: room.title,
    description: room.description || '',
    code: room.code,
    hostUserId: room.host_user_id,
    hostNickname: hostPlayer?.nickname || room.host_nickname || '알 수 없음',
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
    finalDefenseEnabled:
      room.final_defense_enabled ?? DEFAULT_ROOM_DETAIL_SETTINGS.finalDefenseEnabled,
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
  final_defense_enabled,
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
    is_alive,
    connection_status,
    last_seen_at,
    disconnected_at,
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
  await cleanupStaleRoomPlayers().catch(() => {})

  const { data, error } = await supabase
    .from('rooms')
    .select(roomSelect)
    .order('created_at', { ascending: false })

  if (error) {
    throw createSupabaseError('getRooms: rooms select failed', error, '방 목록을 불러오지 못했습니다.')
  }

  return data.map(normalizeRoom)
}

export async function getRoom(roomId) {
  await cleanupStaleRoomPlayers().catch(() => {})

  const { data, error } = await supabase.from('rooms').select(roomSelect).eq('id', roomId).single()

  if (error) {
    throw createSupabaseError('getRoom: room select failed', error, '방 정보를 불러오지 못했습니다.')
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
  finalDefenseEnabled = DEFAULT_ROOM_DETAIL_SETTINGS.finalDefenseEnabled,
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
    throw createSupabaseError('createRoom: create_room rpc failed', error, '방 생성에 실패했습니다.')
  }

  if (!room?.id) {
    console.error('[Supabase] createRoom: create_room rpc returned invalid payload', { room })
    throw new Error('방 생성에 실패했습니다.')
  }

  if (finalDefenseEnabled !== DEFAULT_ROOM_DETAIL_SETTINGS.finalDefenseEnabled) {
    const { error: updateError } = await supabase
      .from('rooms')
      .update({ final_defense_enabled: finalDefenseEnabled })
      .eq('id', room.id)

    if (updateError) {
      throw createSupabaseError('createRoom: rooms final defense update failed', updateError, '최후의 변론 설정을 저장하지 못했습니다.')
    }
  }

  return getRoom(room.id)
}

export async function joinRoom(roomId, entryPassword = '') {
  const { error } = await supabase.rpc('join_room', {
    p_room_id: roomId,
    p_entry_password: entryPassword,
    p_bypass_password: false,
  })

  if (error) {
    throw createSupabaseError('joinRoom: join_room rpc failed', error, getJoinRoomErrorMessage(error))
  }

  return getRoom(roomId)
}

function getJoinRoomErrorMessage(error) {
  const message = error?.message || ''

  if (error?.code === 'PGRST202' || message.includes('Could not find the function public.join_room')) {
    return '방 입장 DB 함수가 배포되지 않았습니다. Supabase에 join_room SQL을 적용해야 합니다.'
  }

  if (message.includes('Not authenticated')) {
    return '로그인이 필요합니다.'
  }

  if (message.includes('Room not found')) {
    return '방을 찾을 수 없습니다.'
  }

  if (message.includes('Room is not waiting')) {
    return '이미 게임이 시작된 방입니다.'
  }

  if (message.includes('Room password is required')) {
    return '비공개 방은 비밀번호를 입력해야 합니다.'
  }

  if (message.includes('Invalid room password')) {
    return '방 비밀번호가 일치하지 않습니다.'
  }

  if (message.includes('Room is full')) {
    return '방 정원이 가득 찼습니다.'
  }

  return '방 입장에 실패했습니다.'
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
      throw createSupabaseError('updateRoom: room_players update failed', failedResult.error, '플레이어 정보를 업데이트하지 못했습니다.')
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
  if (Object.prototype.hasOwnProperty.call(payload, 'finalDefenseEnabled')) {
    roomPayload.final_defense_enabled = payload.finalDefenseEnabled
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
      throw createSupabaseError('updateRoom: rooms update failed', error, '방 정보를 업데이트하지 못했습니다.')
    }

    if (!data?.id) {
      console.error('[Supabase] updateRoom: rooms update returned invalid payload', { data })
      throw new Error('방 정보를 업데이트하지 못했습니다.')
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
    throw createSupabaseError('setPlayerReady: room_players update failed', error, '준비 상태를 업데이트하지 못했습니다.')
  }

  return getRoom(roomId)
}

function getStartGameErrorMessage(error) {
  const message = error?.message || ''

  if (message.includes('Not authenticated')) {
    return '로그인이 필요합니다.'
  }

  if (message.includes('Room not found')) {
    return '방을 찾을 수 없습니다.'
  }

  if (message.includes('already started')) {
    return '이미 게임이 시작되었습니다.'
  }

  if (message.includes('not ready')) {
    return '아직 준비하지 않은 참가자가 있습니다.'
  }

  if (message.includes('Not enough')) {
    return '게임 시작 인원이 부족합니다.'
  }

  if (message.includes('역할 인원수')) {
    return message
  }

  return '게임 시작에 실패했습니다.'
}

export async function startGame(roomId) {
  const { data, error } = await supabase.rpc('start_game', {
    p_room_id: roomId,
  })

  if (error) {
    throw createSupabaseError('startGame: start_game rpc failed', error, getStartGameErrorMessage(error))
  }

  return data
}

export async function endGame(roomId) {
  const { error } = await supabase.rpc('end_game', {
    p_room_id: roomId,
  })

  if (error) {
    throw createSupabaseError('endGame: end_game rpc failed', error, getEndGameErrorMessage(error))
  }
}

export async function skipCurrentPhase(roomId) {
  const { data, error } = await supabase.rpc('skip_current_phase', {
    p_room_id: roomId,
  })

  if (error) {
    throw createSupabaseError('skipCurrentPhase: skip_current_phase rpc failed', error, getSkipPhaseErrorMessage(error))
  }

  return Array.isArray(data) ? data[0] || null : data
}

function getSkipPhaseErrorMessage(error) {
  const message = error?.message || ''

  if (error?.code === 'PGRST202' || message.includes('Could not find the function')) {
    return 'skip_current_phase RPC가 아직 배포되지 않았습니다.'
  }

  if (message.includes('로그인이 필요') || message.includes('Not authenticated')) {
    return '로그인이 필요합니다.'
  }

  if (message.includes('방장만')) {
    return '방장만 현재 단계를 스킵할 수 있습니다.'
  }

  if (message.includes('방을 찾을 수') || message.includes('Room not found')) {
    return '방을 찾을 수 없습니다.'
  }

  if (message.includes('진행 중인 게임')) {
    return message
  }

  return message || '현재 단계를 스킵하지 못했습니다.'
}

function getEndGameErrorMessage(error) {
  const message = error?.message || ''

  if (error?.code === 'PGRST202' || message.includes('Could not find the function')) {
    return 'end_game RPC가 아직 배포되지 않았습니다.'
  }

  if (message.includes('Not authenticated')) {
    return '로그인이 필요합니다.'
  }

  if (message.includes('host only')) {
    return '방장만 게임을 종료할 수 있습니다.'
  }

  if (message.includes('Room not found')) {
    return '방을 찾을 수 없습니다.'
  }

  return message || '게임 종료에 실패했습니다.'
}


export async function submitNightAction(roomId, actionType, targetUserId) {
  const { data, error } = await supabase.rpc('submit_night_action', {
    p_room_id: roomId,
    p_action_type: actionType,
    p_target_user_id: targetUserId,
  })

  if (error) {
    throw createSupabaseError('submitNightAction: submit_night_action rpc failed', error, '밤 행동 제출에 실패했습니다.')
  }

  return data
}

export async function submitVote(roomId, targetUserId) {
  const { data, error } = await supabase.rpc('submit_vote', {
    p_room_id: roomId,
    p_target_user_id: targetUserId,
  })

  if (error) {
    throw createSupabaseError('submitVote: submit_vote rpc failed', error, '투표 제출에 실패했습니다.')
  }

  return data
}

export async function submitFinalDefenseVote(roomId, approveExecution) {
  const { data, error } = await supabase.rpc('submit_final_defense_vote', {
    p_room_id: roomId,
    p_approve_execution: approveExecution,
  })

  if (error) {
    throw createSupabaseError('submitFinalDefenseVote: submit_final_defense_vote rpc failed', error, '최후의 변론 투표 제출에 실패했습니다.')
  }

  return data
}

export async function getCurrentGame(roomId) {
  const { data, error } = await supabase.rpc('get_current_game', {
    p_room_id: roomId,
  })

  if (error) {
    throw createSupabaseError('getCurrentGame: get_current_game rpc failed', error, '게임 정보를 불러오지 못했습니다.')
  }

  return Array.isArray(data) ? data[0] || null : data
}

export async function getGameResult(gameId) {
  const { data, error } = await supabase.rpc('get_game_result', {
    p_game_id: gameId,
  })

  if (error) {
    throw createSupabaseError('getGameResult: get_game_result rpc failed', error, '게임 결과를 불러오지 못했습니다.')
  }

  return Array.isArray(data) ? data[0] || null : data
}

export async function returnRoomToLobby(roomId) {
  const { data, error } = await supabase.rpc('return_room_to_lobby', {
    p_room_id: roomId,
  })

  if (error) {
    throw createSupabaseError('returnRoomToLobby: return_room_to_lobby rpc failed', error, '대기방으로 돌아가지 못했습니다.')
  }

  return Array.isArray(data) ? data[0] || null : data
}

export async function getMyGameRole(roomId) {
  const { data, error } = await supabase.rpc('get_my_game_role', {
    p_room_id: roomId,
  })

  if (error) {
    throw createSupabaseError('getMyGameRole: get_my_game_role rpc failed', error, '내 역할 정보를 불러오지 못했습니다.')
  }

  return Array.isArray(data) ? data[0] || null : data
}

export async function getMyRoleInfo(roomId) {
  const { data, error } = await supabase.rpc('get_my_role_info', {
    p_room_id: roomId,
  })

  if (error) {
    throw createSupabaseError('getMyRoleInfo: get_my_role_info rpc failed', error, '역할 보조 정보를 불러오지 못했습니다.')
  }

  return data || null
}

export async function getVoteStatus(roomId) {
  const { data, error } = await supabase.rpc('get_vote_status', {
    p_room_id: roomId,
  })

  if (error) {
    throw createSupabaseError('getVoteStatus: get_vote_status rpc failed', error, '투표 상태를 불러오지 못했습니다.')
  }

  return data || []
}

export async function leaveRoom(roomId) {
  const { error } = await supabase.rpc('leave_room', {
    p_room_id: roomId,
  })

  if (error) {
    throw createSupabaseError('leaveRoom: leave_room rpc failed', error, '방을 나가지 못했습니다.')
  }

  return null
}

export async function heartbeatRoomPresence(roomId) {
  const { error } = await supabase.rpc('heartbeat_room_presence', {
    p_room_id: roomId,
  })

  if (error) {
    throw createSupabaseError('heartbeatRoomPresence: heartbeat_room_presence rpc failed', error, '방 접속 상태를 갱신하지 못했습니다.')
  }
}

export async function cleanupStaleRoomPlayers(staleAfterSeconds = 45) {
  const { data, error } = await supabase.rpc('cleanup_stale_room_players', {
    p_stale_after_seconds: staleAfterSeconds,
  })

  if (error) {
    throw createSupabaseError('cleanupStaleRoomPlayers: cleanup_stale_room_players rpc failed', error, '만료된 방 참가자 정리에 실패했습니다.')
  }

  return data || 0
}

export async function deleteRoom(roomId) {
  const { error } = await supabase.from('rooms').delete().eq('id', roomId)

  if (error) {
    throw createSupabaseError('deleteRoom: rooms delete failed', error, '방 삭제에 실패했습니다.')
  }
}

export function subscribeToRooms(callback) {
  const channelName = `rooms-changes-${Date.now()}-${Math.random().toString(36).slice(2)}`
  unsubscribeFromRooms(ROOM_LIST_CHANNEL_KEY)

  const channel = supabase
    .channel(channelName)
    .on('postgres_changes', { event: '*', schema: 'public', table: 'rooms' }, callback)
    .subscribe((status) => {
      callback({ type: 'subscription-status', status })
    })

  roomListChannels.set(ROOM_LIST_CHANNEL_KEY, channel)

  return () => unsubscribeFromRooms(ROOM_LIST_CHANNEL_KEY)
}

export function subscribeToRoom(roomId, callback) {
  unsubscribeFromRoom(roomId)

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

  roomDetailChannels.set(roomId, channel)

  return () => unsubscribeFromRoom(roomId)
}

export function subscribeToGame(roomId, callback) {
  unsubscribeFromGame(roomId)

  const channel = supabase
    .channel(`game-${roomId}`)
    .on(
      'postgres_changes',
      { event: '*', schema: 'public', table: 'games', filter: `room_id=eq.${roomId}` },
      callback,
    )
    .subscribe((status) => {
      callback({ type: 'subscription-status', status })
    })

  gameChannels.set(roomId, channel)

  return () => unsubscribeFromGame(roomId)
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

function unsubscribeFromGame(roomId) {
  const channel = gameChannels.get(roomId)

  if (!channel) {
    return
  }

  gameChannels.delete(roomId)
  supabase.removeChannel(channel)
}
