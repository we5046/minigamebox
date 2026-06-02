import { createSupabaseError, supabase } from './supabaseClient'

function unwrapRpcRow(data) {
  return Array.isArray(data) ? data[0] || null : data
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

export function returnCatchmindLobby(roomId) {
  return callCatchmindRpc('return_catchmind_lobby', { p_room_id: roomId }, '대기방으로 돌아가지 못했습니다.')
}

export function subscribeToCatchmind(gameId, callback) {
  if (!gameId) return () => {}

  const channel = supabase
    .channel(`catchmind-state-${gameId}`)
    .on('postgres_changes', { event: '*', schema: 'public', table: 'catchmind_matches', filter: `game_id=eq.${gameId}` }, callback)
    .on('postgres_changes', { event: '*', schema: 'public', table: 'catchmind_players', filter: `game_id=eq.${gameId}` }, callback)
    .on('postgres_changes', { event: '*', schema: 'public', table: 'catchmind_rounds', filter: `game_id=eq.${gameId}` }, callback)
    .on('postgres_changes', { event: '*', schema: 'public', table: 'catchmind_correct_answers', filter: `game_id=eq.${gameId}` }, callback)
    .subscribe()

  return () => supabase.removeChannel(channel)
}

export function subscribeToCatchmindCanvas(roomId, callback) {
  const channel = supabase
    .channel(`catchmind-canvas-${roomId}`, { config: { broadcast: { self: false } } })
    .on('broadcast', { event: 'canvas' }, ({ payload }) => callback(payload))
    .subscribe()

  return {
    channel,
    unsubscribe: () => supabase.removeChannel(channel),
  }
}

export function broadcastCatchmindCanvas(channel, payload) {
  if (!channel) return Promise.resolve()
  return channel.send({ type: 'broadcast', event: 'canvas', payload })
}
