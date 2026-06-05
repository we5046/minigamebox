import { createSupabaseError, supabase } from './supabaseClient'
import { createRealtimeSubscription } from './realtimeSubscription'

export const DEFAULT_LIAR_ROOM_SETTINGS = {
  settingMode: 'classic',
  categoryId: null,
  targetScore: 5,
  citizenWinScore: 1,
  liarWinScore: 2,
  liarCount: 1,
  tieRule: 'revote',
  selfVoteAllowed: false,
  liarWordMode: 'none',
}

function unwrapRpcRow(data) {
  return Array.isArray(data) ? data[0] || null : data
}

function normalizeLiarRoomSettings(row = {}) {
  return {
    roomId: row.room_id || row.roomId || null,
    settingMode: row.setting_mode || row.settingMode || DEFAULT_LIAR_ROOM_SETTINGS.settingMode,
    categoryId: row.category_id || row.categoryId || null,
    targetScore: Number(row.target_score ?? row.targetScore ?? DEFAULT_LIAR_ROOM_SETTINGS.targetScore),
    citizenWinScore: Number(
      row.citizen_win_score ?? row.citizenWinScore ?? DEFAULT_LIAR_ROOM_SETTINGS.citizenWinScore,
    ),
    liarWinScore: Number(
      row.liar_win_score ?? row.liarWinScore ?? DEFAULT_LIAR_ROOM_SETTINGS.liarWinScore,
    ),
    liarCount: Number(row.liar_count ?? row.liarCount ?? DEFAULT_LIAR_ROOM_SETTINGS.liarCount),
    tieRule: row.tie_rule || row.tieRule || DEFAULT_LIAR_ROOM_SETTINGS.tieRule,
    selfVoteAllowed:
      row.self_vote_allowed ?? row.selfVoteAllowed ?? DEFAULT_LIAR_ROOM_SETTINGS.selfVoteAllowed,
    liarWordMode: row.liar_word_mode || row.liarWordMode || DEFAULT_LIAR_ROOM_SETTINGS.liarWordMode,
  }
}

function getLiarErrorMessage(error, fallback) {
  const message = error?.message || ''

  if (error?.code === 'PGRST202' || message.includes('Could not find the function')) {
    return '라이어 게임 DB 함수가 아직 배포되지 않았습니다. Supabase에 liar-game.sql을 적용하세요.'
  }

  if (message.includes('Not authenticated')) return '로그인이 필요합니다.'
  if (message.includes('Liar room host only')) return '방장만 변경할 수 있습니다.'
  if (message.includes('Liar room not found')) return '라이어 게임 방을 찾을 수 없습니다.'
  if (message.includes('Not enough liar match players')) return '라이어 게임은 3명 이상부터 시작할 수 있습니다.'
  if (message.includes('Liar match player not ready')) return '아직 준비하지 않은 참가자가 있습니다.'
  if (message.includes('Liar match already started')) return '이미 시작된 라이어 게임입니다.'
  if (message.includes('Liar vote already submitted')) return '이번 투표는 이미 제출했습니다.'
  if (message.includes('Liar self vote is not allowed')) return '자기 자신에게는 투표할 수 없습니다.'
  if (message.includes('Liar revote candidate required')) return '재투표 후보에게만 투표할 수 있습니다.'
  if (message.includes('Liar voting phase required')) return '현재는 투표할 수 없습니다.'
  if (message.includes('Liar guess already submitted')) return '최종 추측은 한 번만 제출할 수 있습니다.'
  if (message.includes('Current liar only')) return '현재 라이어만 제시어를 추측할 수 있습니다.'
  if (message.includes('All liar match players must vote')) return '모든 참가자의 투표가 필요합니다.'
  if (message.includes('Liar statement text required')) return '한마디 설명을 입력하세요.'
  if (message.includes('Liar statement too long')) return '한마디 설명은 100자 이하로 입력하세요.'
  if (message.includes('Liar statement phase required')) return '현재는 한마디 설명 단계가 아닙니다.'
  if (message.includes('Current liar statement player only')) return '현재 발언자만 한마디 설명을 제출할 수 있습니다.'
  if (message.includes('Liar statement already submitted')) return '이미 한마디 설명을 제출했습니다.'

  return message || fallback
}

async function callLiarRpc(name, params, fallback) {
  const { data, error } = await supabase.rpc(name, params)

  if (error) {
    throw createSupabaseError(
      `liarGameApi: ${name} rpc failed`,
      error,
      getLiarErrorMessage(error, fallback),
    )
  }

  return unwrapRpcRow(data)
}

export async function getLiarCategories() {
  const { data, error } = await supabase
    .from('liar_categories')
    .select('id, category_key, label')
    .eq('is_active', true)
    .order('label', { ascending: true })

  if (error) {
    throw createSupabaseError(
      'getLiarCategories: liar_categories select failed',
      error,
      getLiarErrorMessage(error, '라이어 게임 테마를 불러오지 못했습니다.'),
    )
  }

  return (data || []).map((category) => ({
    id: category.id,
    key: category.category_key,
    label: category.label,
  }))
}

export async function getLiarRoomSettings(roomId) {
  const { data, error } = await supabase
    .from('liar_room_settings')
    .select(
      'room_id, setting_mode, category_id, target_score, citizen_win_score, liar_win_score, liar_count, tie_rule, self_vote_allowed, liar_word_mode',
    )
    .eq('room_id', roomId)
    .maybeSingle()

  if (error) {
    throw createSupabaseError(
      'getLiarRoomSettings: liar_room_settings select failed',
      error,
      getLiarErrorMessage(error, '라이어 게임 설정을 불러오지 못했습니다.'),
    )
  }

  return normalizeLiarRoomSettings(data || { roomId })
}

export async function configureLiarRoom(roomId, settings = {}) {
  const payload = {
    ...DEFAULT_LIAR_ROOM_SETTINGS,
    ...settings,
  }
  const data = await callLiarRpc(
    'configure_liar_room',
    {
      p_room_id: roomId,
      p_setting_mode: payload.settingMode,
      p_category_id: payload.categoryId || null,
      p_target_score: Number(payload.targetScore),
      p_citizen_win_score: Number(payload.citizenWinScore),
      p_liar_win_score: Number(payload.liarWinScore),
    },
    '라이어 게임 설정을 저장하지 못했습니다.',
  )

  return normalizeLiarRoomSettings(data)
}

export function startLiarMatch(roomId) {
  return callLiarRpc('start_liar_match', { p_room_id: roomId }, '라이어 게임을 시작하지 못했습니다.')
}

export function getCurrentLiarMatch(roomId) {
  return callLiarRpc(
    'get_current_liar_match',
    { p_room_id: roomId },
    '라이어 게임 상태를 불러오지 못했습니다.',
  )
}

export function getMyLiarState(roomId) {
  return callLiarRpc(
    'get_my_liar_state',
    { p_room_id: roomId },
    '내 라이어 게임 정보를 불러오지 못했습니다.',
  )
}

export function submitLiarVote(roomId, targetUserId) {
  return callLiarRpc(
    'submit_liar_vote',
    {
      p_room_id: roomId,
      p_target_user_id: targetUserId,
    },
    '투표를 제출하지 못했습니다.',
  )
}

export function resolveLiarVote(roomId) {
  return callLiarRpc(
    'resolve_liar_vote',
    { p_room_id: roomId },
    '투표 결과를 확정하지 못했습니다.',
  )
}

export function submitLiarGuess(roomId, guess) {
  return callLiarRpc(
    'submit_liar_guess',
    {
      p_room_id: roomId,
      p_guess: guess,
    },
    '최종 추측을 제출하지 못했습니다.',
  )
}

export function submitLiarStatement(roomId, statementText) {
  return callLiarRpc(
    'submit_liar_statement',
    {
      p_room_id: roomId,
      p_statement_text: statementText,
    },
    '한마디 설명을 제출하지 못했습니다.',
  )
}

export function timeoutLiarStatement(roomId) {
  return callLiarRpc(
    'timeout_liar_statement',
    { p_room_id: roomId },
    '한마디 설명 시간 초과를 처리하지 못했습니다.',
  )
}

export function advanceLiarPhase(roomId) {
  return callLiarRpc(
    'advance_liar_phase',
    { p_room_id: roomId },
    '다음 단계로 이동하지 못했습니다.',
  )
}

export function returnLiarRoomToLobby(roomId) {
  return callLiarRpc(
    'return_liar_room_to_lobby',
    { p_room_id: roomId },
    '대기방으로 돌아가지 못했습니다.',
  )
}

export function reconcileLiarMatch(roomId) {
  return callLiarRpc(
    'reconcile_liar_match',
    { p_room_id: roomId },
    '라이어게임 참가자 상태를 확인하지 못했습니다.',
  )
}

export function leaveLiarMatch(roomId) {
  return callLiarRpc(
    'leave_liar_match',
    { p_room_id: roomId },
    '라이어게임에서 나가지 못했습니다.',
  )
}

export function subscribeToLiarMatch(gameId, callback) {
  if (!gameId) {
    return () => {}
  }

  const subscription = createRealtimeSubscription({
    createChannel: (handleStatus) =>
      supabase
        .channel(`liar-match-${gameId}`)
        .on(
          'postgres_changes',
          { event: '*', schema: 'public', table: 'liar_match_states', filter: `game_id=eq.${gameId}` },
          callback,
        )
        .on(
          'postgres_changes',
          { event: '*', schema: 'public', table: 'liar_scores', filter: `game_id=eq.${gameId}` },
          callback,
        )
        .on(
          'postgres_changes',
          { event: '*', schema: 'public', table: 'liar_rounds', filter: `game_id=eq.${gameId}` },
          callback,
        )
        .on(
          'postgres_changes',
          { event: '*', schema: 'public', table: 'liar_votes', filter: `game_id=eq.${gameId}` },
          callback,
        )
        .on(
          'postgres_changes',
          { event: '*', schema: 'public', table: 'liar_statements', filter: `game_id=eq.${gameId}` },
          callback,
        )
        .subscribe((status) => {
          callback({ type: 'subscription-status', status })
          handleStatus(status)
        }),
  })

  return () => {
    subscription.unsubscribe()
  }
}
