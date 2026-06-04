import { createSupabaseError, supabase } from './supabaseClient'
import { createRealtimeSubscription } from './realtimeSubscription'

export const DEFAULT_CATCHMIND_ROOM_SETTINGS = {
  settingMode: 'classic',
  totalRounds: 6,
  drawerRule: 'random',
}

function unwrapRpcRow(data) {
  return Array.isArray(data) ? data[0] || null : data
}

function normalizeCatchmindRoomSettings(row = {}) {
  return {
    roomId: row.room_id || row.roomId || null,
    settingMode:
      row.setting_mode ||
      row.settingMode ||
      DEFAULT_CATCHMIND_ROOM_SETTINGS.settingMode,
    totalRounds: Number(
      row.total_rounds ??
        row.totalRounds ??
        DEFAULT_CATCHMIND_ROOM_SETTINGS.totalRounds,
    ),
    drawerRule:
      row.drawer_rule ||
      row.drawerRule ||
      DEFAULT_CATCHMIND_ROOM_SETTINGS.drawerRule,
  }
}

export function normalizeAnswer(value = '') {
  return String(value).trim().toLowerCase()
}

export function isCorrectAnswer(answer, expectedAnswer) {
  return normalizeAnswer(answer) === normalizeAnswer(expectedAnswer)
}

async function callCatchmindRpc(name, params, fallback) {
  const { data, error } = await supabase.rpc(name, params)

  if (error) {
    throw createSupabaseError(`catchmindApi: ${name} rpc failed`, error, error.message || fallback)
  }

  return unwrapRpcRow(data)
}

export function startCatchmindMatch(roomId) {
  return callCatchmindRpc('start_catchmind_match', { p_room_id: roomId }, '캐치마인드를 시작하지 못했습니다.')
}

export async function getCatchmindRoomSettings(roomId) {
  return normalizeCatchmindRoomSettings(
    await callCatchmindRpc(
      'get_catchmind_room_settings',
      { p_room_id: roomId },
      '캐치마인드 방 설정을 불러오지 못했습니다.',
    ),
  )
}

export async function configureCatchmindRoom(roomId, settings = {}) {
  return normalizeCatchmindRoomSettings(
    await callCatchmindRpc(
      'configure_catchmind_room',
      {
        p_room_id: roomId,
        p_setting_mode:
          settings.settingMode || DEFAULT_CATCHMIND_ROOM_SETTINGS.settingMode,
        p_total_rounds: Number(
          settings.totalRounds || DEFAULT_CATCHMIND_ROOM_SETTINGS.totalRounds,
        ),
        p_drawer_rule:
          settings.drawerRule || DEFAULT_CATCHMIND_ROOM_SETTINGS.drawerRule,
      },
      '캐치마인드 방 설정을 저장하지 못했습니다.',
    ),
  )
}

export function getCurrentCatchmind(roomId) {
  return callCatchmindRpc('get_current_catchmind', { p_room_id: roomId }, '캐치마인드 상태를 불러오지 못했습니다.')
}

export function submitCatchmindAnswer(roomId, answer) {
  return callCatchmindRpc(
    'submit_catchmind_answer',
    { p_room_id: roomId, p_answer: answer },
    '정답을 제출하지 못했습니다.',
  )
}

export function advanceCatchmindPhase(roomId) {
  return callCatchmindRpc('advance_catchmind_phase', { p_room_id: roomId }, '다음 단계로 이동하지 못했습니다.')
}

export function reconcileCatchmindMatch(roomId) {
  return callCatchmindRpc('reconcile_catchmind_match', { p_room_id: roomId }, '캐치마인드 참가자 상태를 동기화하지 못했습니다.')
}

export function getCatchmindCanvasSnapshot(roomId, roundId) {
  if (!roundId) return Promise.resolve(null)
  return callCatchmindRpc(
    'get_catchmind_canvas_snapshot',
    { p_room_id: roomId, p_round_id: roundId },
    '캐치마인드 캔버스를 불러오지 못했습니다.',
  )
}

export function saveCatchmindCanvasSnapshot(roomId, roundId, imageData) {
  if (!roundId || !imageData) return Promise.resolve(null)
  return callCatchmindRpc(
    'save_catchmind_canvas_snapshot',
    { p_room_id: roomId, p_round_id: roundId, p_image_data: imageData },
    '캐치마인드 캔버스를 저장하지 못했습니다.',
  )
}

export function joinCatchmindMatch(roomId, entryPassword = '') {
  return callCatchmindRpc(
    'join_catchmind_match',
    { p_room_id: roomId, p_entry_password: entryPassword },
    '진행 중인 캐치마인드 게임에 입장하지 못했습니다.',
  )
}

export function leaveCatchmindMatch(roomId) {
  return callCatchmindRpc('leave_catchmind_match', { p_room_id: roomId }, '캐치마인드 게임에서 퇴장하지 못했습니다.')
}

export function returnCatchmindLobby(roomId) {
  return callCatchmindRpc('return_catchmind_lobby', { p_room_id: roomId }, '대기방으로 돌아가지 못했습니다.')
}

export function subscribeToCatchmind(gameId, callback) {
  if (!gameId) return () => {}

  const subscription = createRealtimeSubscription({
    createChannel: (handleStatus) =>
      supabase
        .channel(`catchmind-state-${gameId}`)
        .on('postgres_changes', { event: '*', schema: 'public', table: 'catchmind_matches', filter: `game_id=eq.${gameId}` }, callback)
        .on('postgres_changes', { event: '*', schema: 'public', table: 'catchmind_players', filter: `game_id=eq.${gameId}` }, callback)
        .on('postgres_changes', { event: '*', schema: 'public', table: 'catchmind_rounds', filter: `game_id=eq.${gameId}` }, callback)
        .on('postgres_changes', { event: '*', schema: 'public', table: 'catchmind_correct_answers', filter: `game_id=eq.${gameId}` }, callback)
        .subscribe((status) => {
          callback({ type: 'subscription-status', status })
          handleStatus(status)
        }),
  })

  return () => subscription.unsubscribe()
}

export function subscribeToCatchmindCanvas(roomId, callback, onSubscribed) {
  const subscription = createRealtimeSubscription({
    createChannel: (handleStatus) =>
      supabase
        .channel(`catchmind-canvas-${roomId}`, { config: { broadcast: { self: false } } })
        .on('broadcast', { event: 'canvas' }, ({ payload }) => callback(payload))
        .subscribe((status) => {
          if (status === 'SUBSCRIBED') onSubscribed?.(subscription)
          handleStatus(status)
        }),
  })

  return {
    channel: subscription,
    unsubscribe: () => subscription.unsubscribe(),
  }
}

export function broadcastCatchmindCanvas(channel, payload) {
  if (!channel) return Promise.resolve()
  return channel.send({ type: 'broadcast', event: 'canvas', payload })
}
