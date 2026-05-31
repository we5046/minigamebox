<script setup>
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import {
  getGameMessages,
  normalizeGameMessage,
  sendGameMessage,
  subscribeToGameMessages,
  uploadGameLogMarkdown,
} from '@/api/chatApi'
import {
  endGame,
  getCurrentGame,
  getGameResult,
  getMyGameRole,
  getMyRoleInfo,
  getVisibleTeamMembers,
  getRoom,
  getVoteStatus,
  heartbeatRoomPresence,
  processDueGamePhases,
  returnRoomToLobby,
  ROOM_PRESENCE_TIMEOUTS,
  skipCurrentPhase,
  submitFinalDefenseVote,
  submitNightAction,
  submitVote,
  subscribeToGame,
  subscribeToRoom,
} from '@/api/roomApi'
import { useAuthStore } from '@/stores/auth'
import { useToastStore } from '@/stores/toast'

const route = useRoute()
const router = useRouter()
const authStore = useAuthStore()
const toastStore = useToastStore()

const roomId = computed(() => route.params.roomId)
const room = ref(null)
const game = ref(null)
const gameResult = ref(null)
const myRole = ref(null)
const roleInfo = ref(null)
const visibleTeamMembers = ref([])
const voteStatus = ref([])
const messages = ref([])
const chatDraft = ref('')
const deadChatDraft = ref('')
const activeMainChatChannel = ref('public')
const selectedNightTarget = ref('')
const selectedVoteTarget = ref('')
const selectedMemoPlayerId = ref('')
const playerRoleMemos = ref({})
const isLoading = ref(false)
const isSending = ref(false)
const isSubmittingAction = ref(false)
const isSubmittingVote = ref(false)
const isSubmittingFinalDefenseVote = ref(false)
const isEnding = ref(false)
const isReturningToLobby = ref(false)
const isEndConfirmOpen = ref(false)
const nowTick = ref(Date.now())
const fallbackReturnToLobbyAt = ref(null)
const chatMessagesRef = ref(null)
const chatInputRef = ref(null)
const lastExpiredSyncAt = ref(0)

let unsubscribeRoom = null
let unsubscribeGame = null
let unsubscribeMessages = null
let countdownTimer = null
let gameStatePollTimer = null
let roomHeartbeatTimer = null
let roomHeartbeatPromise = null
let roomHeartbeatFailureCount = 0
let nextRoomHeartbeatAt = 0
let gameSyncPromise = null
let messagesSyncPromise = null
const uploadedLogGameIds = new Set()
const EXPIRED_PHASE_SYNC_RETRY_MS = 1_000
const GAME_STATE_POLL_INTERVAL_MS = 2_000

const roleLabels = {
  citizen: '시민',
  mafia: '마피아',
  police: '경찰',
  doctor: '의사',
}

const playerMemoOptions = [
  { key: '', label: '기본', description: '미분류', tone: 'default' },
  { key: 'mafia', label: '마피아', description: '의심', tone: 'mafia' },
  { key: 'police', label: '경찰', description: '신뢰', tone: 'police' },
  { key: 'doctor', label: '의사', description: '보호', tone: 'doctor' },
]

const phaseLabels = {
  role_reveal: '역할 확인',
  night: '밤',
  day: '낮',
  discussion: '토론',
  vote: '투표',
  final_defense: '최후의 변론',
  result: '결과',
  ended: '게임 종료',
  finished: '게임 종료',
}

const nextPhaseLabels = {
  role_reveal: '밤',
  night: '토론',
  day: '투표',
  discussion: '투표',
  vote: '최후의 변론',
  final_defense: '결과',
  result: '밤',
  ended: '종료',
  finished: '종료',
}

const actionGuides = {
  role_reveal: '자신의 역할을 확인하고 밤을 기다리세요.',
  night: '밤에는 역할에 맞는 행동을 선택하세요.',
  day: '채팅으로 정보를 공유하세요.',
  discussion: '토론하고 의심되는 플레이어를 좁혀보세요.',
  vote: '처형할 대상을 선택하세요.',
  final_defense: '최후의 변론 대상의 처형 여부를 결정하세요.',
  result: '이번 라운드 결과를 확인하세요.',
  ended: '게임이 종료되었습니다.',
  finished: '게임이 종료되었습니다.',
}

const chatPhaseBanners = {
  role_reveal: '자신의 역할을 확인하고 밤을 기다리세요.',
  night: '밤에는 전체 채팅이 제한됩니다. 역할에 맞는 행동을 선택하세요.',
  day: '낮 토론 중입니다. 채팅으로 의심되는 플레이어를 논의하세요.',
  discussion: '낮 토론 중입니다. 채팅으로 의심되는 플레이어를 논의하세요.',
  vote: '투표 시간입니다. 처형할 대상을 선택하세요.',
  final_defense: '최후의 변론 중입니다. 처형 여부를 결정하세요.',
  result: '이번 라운드 결과를 확인하세요.',
  ended: '게임이 종료되었습니다.',
  finished: '게임이 종료되었습니다.',
}

const chatPlaceholders = {
  role_reveal: '역할 확인 중에는 채팅할 수 없습니다',
  night: '현재 단계에서는 채팅할 수 없습니다',
  day: '토론 내용을 입력하세요',
  discussion: '토론 내용을 입력하세요',
  vote: '투표 전 마지막 의견을 남겨보세요',
  final_defense: '최후의 변론 의견을 남겨보세요',
  result: '결과 확인 중입니다',
  ended: '종료된 게임입니다',
  finished: '종료된 게임입니다',
}

const nightActionLabels = {
  mafia_kill: '습격 대상 선택',
  police_check: '조사 대상 선택',
  doctor_save: '보호 대상 선택',
}

const chatChannelLabels = {
  public: '전체',
  mafia: '마피아',
  police: '경찰',
  dead: '사후',
}

const savedUser = computed(() => authStore.user)
const isHost = computed(() => room.value?.hostUserId === savedUser.value?.id)
const phaseKey = computed(() => game.value?.phase || room.value?.phase || 'night')
const roleKey = computed(() => myRole.value?.role || 'citizen')
const roleLabel = computed(() => roleLabels[roleKey.value] || '알 수 없음')
const phaseLabel = computed(() => phaseLabels[phaseKey.value] || phaseKey.value || '대기 중')
const nextPhase = computed(() => {
  if (phaseKey.value === 'vote' && !room.value?.finalDefenseEnabled) {
    return '결과'
  }

  return nextPhaseLabels[phaseKey.value] || '다음'
})
const isAlive = computed(() => myRole.value?.is_alive !== false)
const survivalText = computed(() => (isAlive.value ? '생존' : '사망'))
const isGameEnded = computed(
  () => ['ended', 'finished'].includes(game.value?.status) || phaseKey.value === 'ended',
)
const remainingSeconds = computed(() => {
  if (!game.value?.phase_ends_at || isGameEnded.value) return 0

  return Math.max(
    0,
    Math.ceil((new Date(game.value.phase_ends_at).getTime() - nowTick.value) / 1000),
  )
})

const myVoteStatus = computed(() => voteStatus.value.find((item) => (item.user_id || item.userId) === savedUser.value?.id) || null)
const myVoteTargetId = computed(() => myVoteStatus.value?.target_user_id || myVoteStatus.value?.targetUserId || '')
const finalDefenseTargetId = computed(() => game.value?.final_defense_target_user_id || game.value?.finalDefenseTargetUserId || '')
const isFinalDefenseTarget = computed(
  () => phaseKey.value === 'final_defense' && savedUser.value?.id === finalDefenseTargetId.value,
)
const visibleTeamNicknames = computed(() =>
  new Set(
    ['mafia', 'police'].includes(roleKey.value)
      ? (roleInfo.value?.items || [])
          .filter((item) => item.type === `${roleKey.value}_team`)
          .map((item) => item.label)
      : [],
  ),
)
const playersWithStatus = computed(() =>
  (room.value?.players || []).map((player) => {
    const visibleTeamMember = visibleTeamMembers.value.find(
      (member) => (member.user_id || member.userId) === player.userId,
    )
    const fallbackTeamRole =
      ['mafia', 'police'].includes(roleKey.value) && visibleTeamNicknames.value.has(player.nickname)
        ? roleKey.value
        : player.userId === savedUser.value?.id && ['mafia', 'police'].includes(roleKey.value)
          ? roleKey.value
          : ''

    return {
      ...player,
      isMe: player.userId === savedUser.value?.id,
      isMyVoteTarget: myVoteTargetId.value === player.userId,
      isFinalDefenseTarget: finalDefenseTargetId.value === player.userId,
      memoRole: playerRoleMemos.value[player.userId] || '',
      visibleTeamRole: visibleTeamMember?.team_role || visibleTeamMember?.teamRole || fallbackTeamRole,
    }
  }),
)
const alivePlayers = computed(() => playersWithStatus.value.filter((player) => player.isAlive !== false))
const targetPlayers = computed(() => alivePlayers.value)
const nightRoleChatChannel = computed(() => {
  if (roleKey.value === 'mafia') return 'mafia'
  if (roleKey.value === 'police') return 'police'
  return ''
})
const availableMainChatChannels = computed(() => {
  const channels = [{ key: 'public', label: '전체' }]

  if (roleKey.value === 'mafia') {
    channels.push({ key: 'mafia', label: '마피아' })
  }

  if (roleKey.value === 'police') {
    channels.push({ key: 'police', label: '경찰' })
  }

  return channels
})
const activeMainChatChannelInfo = computed(
  () =>
    availableMainChatChannels.value.find((channel) => channel.key === activeMainChatChannel.value) ||
    availableMainChatChannels.value[0],
)
const chatChannelType = computed(() => activeMainChatChannelInfo.value?.key || 'public')
const chatChannelLabel = computed(() => chatChannelLabels[chatChannelType.value] || '전체')
const canChatInCurrentPhase = computed(() => {
  if (['mafia', 'police'].includes(chatChannelType.value)) {
    return phaseKey.value === 'night' && chatChannelType.value === nightRoleChatChannel.value
  }

  if (phaseKey.value === 'night') {
    return false
  }

  if (phaseKey.value === 'final_defense') {
    return isFinalDefenseTarget.value
  }

  return ['day', 'discussion', 'vote'].includes(phaseKey.value)
})
const canChat = computed(
  () =>
    canChatInCurrentPhase.value &&
    isAlive.value &&
    room.value?.status === 'playing' &&
    Boolean(game.value?.id) &&
    Boolean(savedUser.value?.id),
)
const canSendDeadChat = computed(
  () =>
    !isAlive.value &&
    room.value?.status === 'playing' &&
    Boolean(game.value?.id) &&
    Boolean(savedUser.value?.id),
)
const nightActionType = computed(() => {
  if (roleKey.value === 'mafia') return 'mafia_kill'
  if (roleKey.value === 'police') return 'police_check'
  if (roleKey.value === 'doctor') return 'doctor_save'
  return ''
})
const canNightAction = computed(
  () =>
    phaseKey.value === 'night' &&
    isAlive.value &&
    Boolean(nightActionType.value) &&
    room.value?.status === 'playing' &&
    remainingSeconds.value > 0,
)
const canVote = computed(
  () =>
    phaseKey.value === 'vote' &&
    isAlive.value &&
    room.value?.status === 'playing' &&
    remainingSeconds.value > 0,
)
const canFinalDefenseVote = computed(
  () =>
    phaseKey.value === 'final_defense' &&
    isAlive.value &&
    savedUser.value?.id !== finalDefenseTargetId.value &&
    room.value?.status === 'playing' &&
    remainingSeconds.value > 0,
)
const isSkipCommand = computed(() => ['/스킵', '/skip'].includes(chatDraft.value.trim().toLowerCase()))
const canSkipPhaseCommand = computed(
  () =>
    isHost.value &&
    isAlive.value &&
    room.value?.status === 'playing' &&
    Boolean(game.value?.id) &&
    !isGameEnded.value,
)
const canUseChatInput = computed(() => canChat.value || canSkipPhaseCommand.value)
const canSubmitChatInput = computed(() => canChat.value || (canSkipPhaseCommand.value && isSkipCommand.value))
const actionGuide = computed(() => actionGuides[phaseKey.value] || '다음 단계를 기다리세요.')
const chatPanelTitle = computed(() => (isAlive.value ? '메인 채팅' : '메인 채팅 관전'))
const chatPhaseBanner = computed(() => {
  if (!isAlive.value) {
    return '사망한 플레이어는 전체 로그와 밤 채팅을 관전할 수 있습니다.'
  }

  return chatPhaseBanners[phaseKey.value] || '현재 게임 진행 상황을 확인하세요.'
})
const chatPlaceholder = computed(
  () =>
    canChat.value
      ? phaseKey.value === 'night'
        ? `${chatChannelLabel.value} 팀 채팅을 입력하세요`
        : chatPlaceholders[phaseKey.value] || '메시지를 입력하세요'
      : !isAlive.value
        ? '사망자는 메인 채팅에 참여할 수 없습니다. 사후 채팅을 이용하세요'
      : phaseKey.value === 'final_defense'
        ? canSkipPhaseCommand.value
          ? '변론 대상만 채팅할 수 있습니다. 방장은 /스킵으로 넘길 수 있습니다'
          : '변론 대상만 채팅할 수 있습니다'
      : phaseKey.value === 'night'
        ? canSkipPhaseCommand.value
          ? '밤에는 마피아/경찰만 팀 채팅이 가능합니다. 방장은 /스킵으로 넘길 수 있습니다'
          : '밤에는 마피아/경찰만 팀 채팅이 가능합니다'
      : canSkipPhaseCommand.value
        ? '방장은 /스킵으로 현재 단계를 넘길 수 있습니다'
        : chatPlaceholders[phaseKey.value] || '현재 단계에서는 채팅할 수 없습니다',
)
const roleSpecificInfo = computed(() => {
  const items = Array.isArray(roleInfo.value?.items) ? roleInfo.value.items : []

  if (items.length > 0) {
    return items
  }

  return [
    {
      type: 'empty',
      label: '정보 없음',
      description: '아직 공개하거나 표시할 정보가 없습니다.',
    },
  ]
})

const selectedParticipantId = computed(() =>
  canNightAction.value
    ? selectedNightTarget.value
    : canVote.value
      ? selectedVoteTarget.value || myVoteTargetId.value
      : phaseKey.value === 'final_defense'
        ? finalDefenseTargetId.value
      : '',
)
const selectedMemoPlayer = computed(() =>
  playersWithStatus.value.find((player) => player.userId === selectedMemoPlayerId.value) || null,
)

const isGameOverScreen = computed(
  () => game.value?.status === 'ended' || room.value?.status === 'game_over',
)
const hasGameResult = computed(() => Boolean(gameResult.value?.summary))

const resultSummary = computed(() => gameResult.value?.summary || null)
const resultPlayers = computed(() => (Array.isArray(resultSummary.value?.players) ? resultSummary.value.players : []))
const resultWinners = computed(() => (Array.isArray(resultSummary.value?.winners) ? resultSummary.value.winners : []))
const resultWinner = computed(() => game.value?.winner || gameResult.value?.winner || resultSummary.value?.winner || '')
const resultEndReason = computed(() => game.value?.end_reason || gameResult.value?.end_reason || '')
const resultWinnerLabel = computed(() =>
  resultWinner.value === 'mafia' ? '마피아 팀 승리' : '시민 팀 승리',
)
const resultWinnerAccent = computed(() => (resultWinner.value === 'mafia' ? 'mafia' : 'citizen'))
const resultMvp = computed(() => resultSummary.value?.mvp || gameResult.value?.mvp || null)
const resultSurvivorCount = computed(() => resultPlayers.value.filter((player) => player.is_alive).length)
const myResultPlayer = computed(
  () => resultPlayers.value.find((player) => player.user_id === savedUser.value?.id) || null,
)
const myContributionStats = computed(() => {
  const logs = Array.isArray(myResultPlayer.value?.logs) ? myResultPlayer.value.logs : []

  return {
    nightActions: logs.filter((log) => log.includes(' 밤: ')).length,
    votes: logs.filter((log) => log.includes(' 투표: ')).length,
    checks: logs.filter((log) => log.includes('조사했습니다')).length,
    saves: logs.filter((log) => log.includes('보호했습니다')).length,
    attacks: logs.filter((log) => log.includes('제거 대상으로 선택했습니다')).length,
  }
})
const myContributionSummary = computed(() => {
  const player = myResultPlayer.value

  if (!player) {
    return {
      title: '기여 기록을 찾지 못했습니다.',
      description: '이번 게임 결과에 내 플레이 기록이 아직 반영되지 않았습니다.',
      items: [],
    }
  }

  const roleLabel = roleLabels[player.role] || player.role || '알 수 없음'
  const outcome = player.is_winner ? '승리 팀에 기여했습니다.' : '패배했지만 게임에 참여했습니다.'
  const survival = player.is_alive ? '끝까지 생존했습니다.' : '게임 도중 사망했습니다.'
  const items = [
    `${roleLabel} 역할로 ${outcome}`,
    survival,
  ]

  if (myContributionStats.value.nightActions > 0) {
    items.push(`밤 행동 ${myContributionStats.value.nightActions}회 수행`)
  }

  if (myContributionStats.value.votes > 0) {
    items.push(`처형 투표 ${myContributionStats.value.votes}회 참여`)
  }

  if (myContributionStats.value.checks > 0) {
    items.push(`경찰 조사 ${myContributionStats.value.checks}회 수행`)
  }

  if (myContributionStats.value.saves > 0) {
    items.push(`의사 보호 ${myContributionStats.value.saves}회 수행`)
  }

  if (myContributionStats.value.attacks > 0) {
    items.push(`마피아 습격 선택 ${myContributionStats.value.attacks}회 참여`)
  }

  if (items.length === 2) {
    items.push('기록된 능력/투표 행동은 없습니다.')
  }

  return {
    title: `${roleLabel}로 ${player.is_winner ? '승리' : '패배'}`,
    description: `${player.nickname}님의 이번 게임 기여 요약입니다.`,
    items,
  }
})
const returnToLobbySeconds = computed(() => {
  const returnAt = game.value?.return_to_lobby_at || fallbackReturnToLobbyAt.value

  if (!isGameOverScreen.value || !returnAt) {
    return 0
  }

  const returnAtTime = new Date(returnAt).getTime()

  if (Number.isNaN(returnAtTime)) {
    return 0
  }

  return Math.max(
    0,
    Math.ceil((returnAtTime - nowTick.value) / 1000),
  )
})

function isNearChatBottom() {
  const el = chatMessagesRef.value
  if (!el) return true
  return el.scrollHeight - el.scrollTop - el.clientHeight < 96
}

function scrollChatToBottom() {
  const el = chatMessagesRef.value
  if (!el) return
  el.scrollTop = el.scrollHeight
}

function focusChatInput() {
  const el = chatInputRef.value
  if (!el || typeof el.focus !== 'function') return
  el.focus()
}

function canSeeGameMessage(message) {
  if (!message) return false
  if (message.isSystem || message.messageType === 'system') return true

  const messageChannel = message.channelType || 'public'
  if (messageChannel === 'public') return true
  if (!isAlive.value) return ['dead', 'mafia', 'police'].includes(messageChannel)

  return messageChannel === roleKey.value
}

const mainVisibleMessages = computed(() =>
  messages.value.filter((message) => {
    if (message.isSystem || message.messageType === 'system') {
      return true
    }

    const messageChannel = message.channelType || 'public'
    return messageChannel !== 'dead'
  }),
)
const deadChatMessages = computed(() =>
  isAlive.value ? [] : messages.value.filter((message) => message.channelType === 'dead'),
)

function getPlayerMemoStorageKey() {
  const userId = savedUser.value?.id
  const gameId = game.value?.id

  return userId && roomId.value && gameId
    ? `mafia-night-player-memos:${userId}:${roomId.value}:${gameId}`
    : ''
}

function loadPlayerRoleMemos() {
  const storageKey = getPlayerMemoStorageKey()

  if (!storageKey) {
    playerRoleMemos.value = {}
    return
  }

  try {
    playerRoleMemos.value = JSON.parse(localStorage.getItem(storageKey) || '{}')
  } catch {
    playerRoleMemos.value = {}
  }
}

function savePlayerRoleMemos() {
  const storageKey = getPlayerMemoStorageKey()
  if (!storageKey) return

  try {
    localStorage.setItem(storageKey, JSON.stringify(playerRoleMemos.value))
  } catch (error) {
    console.warn('[Game] Failed to save private player memos.', error)
  }
}

function setPlayerRoleMemo(role) {
  if (!selectedMemoPlayerId.value) return

  const nextMemos = { ...playerRoleMemos.value }

  if (role) {
    nextMemos[selectedMemoPlayerId.value] = role
  } else {
    delete nextMemos[selectedMemoPlayerId.value]
  }

  playerRoleMemos.value = nextMemos
  savePlayerRoleMemos()
}

function clearPlayerRoleMemos() {
  playerRoleMemos.value = {}
  savePlayerRoleMemos()
}

function selectParticipant(userId) {
  selectedMemoPlayerId.value = userId

  if (canNightAction.value) {
    selectedNightTarget.value = userId
    return
  }

  if (canVote.value) {
    selectedVoteTarget.value = userId
  }
}

function mergeGameRealtimePayload(nextGame) {
  if (!nextGame?.id) return

  const previousPhase = game.value?.phase

  game.value = {
    ...(game.value || {}),
    ...nextGame,
  }

  if (nextGame.phase && nextGame.phase !== previousPhase) {
    if (nextGame.phase !== 'night') {
      selectedNightTarget.value = ''
    }

    if (nextGame.phase !== 'vote') {
      selectedVoteTarget.value = ''
    }

    lastExpiredSyncAt.value = 0
  }
}

function mergeRoomRealtimePayload(nextRoom) {
  if (!nextRoom?.id) return

  room.value = {
    ...(room.value || {}),
    id: nextRoom.id,
    status: nextRoom.status ?? room.value?.status,
    phase: nextRoom.phase ?? room.value?.phase,
    updatedAt: nextRoom.updated_at ?? room.value?.updatedAt,
  }
}

function getResultTeamLabel(role) {
  return role === 'mafia' ? '마피아 팀' : '시민 팀'
}

async function loadGameResult(gameId) {
  if (!gameId) {
    gameResult.value = null
    return
  }

  try {
    gameResult.value = await getGameResult(gameId)
  } catch (error) {
    gameResult.value = null
    toastStore.error(error.message)
  }
}

async function maybeReturnToLobby() {
  if (
    !isGameOverScreen.value ||
    !hasGameResult.value ||
    returnToLobbySeconds.value > 0 ||
    isReturningToLobby.value
  ) {
    return
  }

  await returnToLobby(true)
}

async function returnToLobbyNow() {
  await returnToLobby(false, true)
}

async function returnToLobby(auto = false, force = false) {
  if (isReturningToLobby.value) {
    return
  }

  if (auto && !isGameOverScreen.value) {
    return
  }

  if (auto && returnToLobbySeconds.value > 0) {
    return
  }

  isReturningToLobby.value = true

  try {
    await sendRoomHeartbeat({ force: true })

    if (isHost.value && room.value?.status === 'game_over') {
      await returnRoomToLobby(roomId.value)
    }

    if (force || auto || room.value?.status === 'game_over' || room.value?.status === 'waiting') {
      await router.push(`/rooms/${roomId.value}`)
    }
  } catch (error) {
    toastStore.error(error.message)
  } finally {
    isReturningToLobby.value = false
  }
}

function pushMessage(message) {
  if (!message?.id || messages.value.some((item) => item.id === message.id)) return
  if (!canSeeGameMessage(message)) return

  isNearChatBottom()
  messages.value.push(message)
  nextTick(scrollChatToBottom)
}

async function loadRoleSideData() {
  const [roleInfoResult, voteStatusResult, visibleTeamMembersResult] = await Promise.allSettled([
    getMyRoleInfo(roomId.value),
    getVoteStatus(roomId.value),
    getVisibleTeamMembers(roomId.value),
  ])

  roleInfo.value = roleInfoResult.status === 'fulfilled' ? roleInfoResult.value : null
  voteStatus.value = voteStatusResult.status === 'fulfilled' ? voteStatusResult.value : []
  visibleTeamMembers.value =
    visibleTeamMembersResult.status === 'fulfilled' ? visibleTeamMembersResult.value : []

  if (visibleTeamMembersResult.status === 'rejected') {
    console.warn('[Game] Failed to load visible team members.', visibleTeamMembersResult.reason)
  }
}

function isMissingRoomError(error) {
  const raw = error.cause || error.supabaseError || {}
  return raw.code === 'PGRST116' || raw.details?.includes('0 rows')
}

function getRoomHeartbeatBackoffMs() {
  return Math.min(
    60_000,
    ROOM_PRESENCE_TIMEOUTS.heartbeatIntervalMs * 2 ** Math.min(roomHeartbeatFailureCount, 3),
  )
}

async function sendRoomHeartbeat({ force = false } = {}) {
  if (!roomId.value) {
    return false
  }

  if (!force && Date.now() < nextRoomHeartbeatAt) {
    return false
  }

  if (roomHeartbeatPromise) {
    return roomHeartbeatPromise
  }

  roomHeartbeatPromise = (async () => {
    try {
      await heartbeatRoomPresence(roomId.value)
      roomHeartbeatFailureCount = 0
      nextRoomHeartbeatAt = 0
      return true
    } catch (error) {
      const rawMessage = error.cause?.message || error.supabaseError?.message || ''

      if (
        rawMessage.includes('Room participant required') ||
        error.message?.includes('Room participant required') ||
        error.message?.includes('방 참가자')
      ) {
        await router.push('/home')
        return false
      }

      roomHeartbeatFailureCount += 1
      nextRoomHeartbeatAt = Date.now() + getRoomHeartbeatBackoffMs()
      console.warn('[Game] Heartbeat failed.', error)
      return false
    } finally {
      roomHeartbeatPromise = null
    }
  })()

  return roomHeartbeatPromise
}

function startRoomHeartbeat() {
  if (roomHeartbeatTimer) {
    return
  }

  roomHeartbeatTimer = setInterval(() => {
    sendRoomHeartbeat()
  }, ROOM_PRESENCE_TIMEOUTS.heartbeatIntervalMs)
}

function stopRoomHeartbeat() {
  if (!roomHeartbeatTimer) {
    return
  }

  clearInterval(roomHeartbeatTimer)
  roomHeartbeatTimer = null
}

async function loadGame({ silent = false } = {}) {
  if (gameSyncPromise) {
    return gameSyncPromise
  }

  if (!silent) {
    isLoading.value = true
  }

  gameSyncPromise = (async () => {
    try {
      const heartbeatOk = await sendRoomHeartbeat({ force: !silent })

      if (!heartbeatOk && route.name !== 'game-play') {
        return
      }

      const [nextRoom, nextGame, nextRole] = await Promise.all([
        getRoom(roomId.value),
        getCurrentGame(roomId.value),
        getMyGameRole(roomId.value),
      ])

      room.value = nextRoom
      game.value = nextGame
      myRole.value = nextRole

      await loadRoleSideData()

      if (nextGame?.status === 'ended' || nextRoom.status === 'game_over') {
        if (!nextGame?.return_to_lobby_at && !fallbackReturnToLobbyAt.value) {
          fallbackReturnToLobbyAt.value = new Date(Date.now() + 60000).toISOString()
        }

        if (nextGame?.id) {
          await loadGameResult(nextGame.id)
        }
      } else {
        gameResult.value = null
        fallbackReturnToLobbyAt.value = null
      }

      if (nextGame?.status !== 'ended' && (nextRoom.status === 'waiting' || nextRoom.phase === 'before_start')) {
        router.push(`/rooms/${roomId.value}`)
      }
    } catch (error) {
      if (isMissingRoomError(error)) {
        await router.push('/home')
        return
      }

      toastStore.error(error.message)
    } finally {
      gameSyncPromise = null
      if (!silent) {
        isLoading.value = false
      }
    }
  })()

  return gameSyncPromise
}

async function loadMessages() {
  if (messagesSyncPromise) {
    return messagesSyncPromise
  }

  messagesSyncPromise = (async () => {
    try {
      const nextMessages = await getGameMessages(roomId.value, game.value?.id)
      messages.value = nextMessages.filter(canSeeGameMessage)
      nextTick(scrollChatToBottom)
    } catch (error) {
      toastStore.error(error.message)
    } finally {
      messagesSyncPromise = null
    }
  })()

  return messagesSyncPromise
}


async function maybeSyncExpiredGameState() {
  if (!game.value?.id || isGameEnded.value || remainingSeconds.value > 0 || isLoading.value) {
    return
  }

  const now = Date.now()
  if (now - lastExpiredSyncAt.value < EXPIRED_PHASE_SYNC_RETRY_MS) {
    return
  }

  lastExpiredSyncAt.value = now

  try {
    await processDueGamePhases()
    await loadGame({ silent: true })
    await loadMessages()
  } catch (error) {
    console.warn('[Game] Failed to sync expired phase.', error)
    await loadGame({ silent: true })
  }
}

async function saveGameLogFile(endingRoom, endingGame) {
  if (!endingRoom?.id || !endingGame?.id || uploadedLogGameIds.has(endingGame.id)) {
    return
  }

  uploadedLogGameIds.add(endingGame.id)

  try {
    const logMessages = await getGameMessages(endingRoom.id, endingGame.id, { limit: 1000 })
    await uploadGameLogMarkdown({
      room: endingRoom,
      game: endingGame,
      messages: logMessages,
    })
  } catch (error) {
    uploadedLogGameIds.delete(endingGame.id)
    toastStore.error(error.message)
  }
}

async function handleSendMessage() {
  if (isSending.value || !chatDraft.value.trim()) return

  if (isSkipCommand.value) {
    await handleSkipPhaseCommand()
    return
  }

  if (!canChat.value) return

  isSending.value = true

  try {
    const sentMessage = await sendGameMessage({
      roomId: roomId.value,
      gameId: game.value?.id,
      userId: savedUser.value?.id,
      nickname: savedUser.value?.nickname || '알 수 없음',
      content: chatDraft.value,
      channelType: chatChannelType.value,
    })

    chatDraft.value = ''
    pushMessage(sentMessage)
    nextTick(focusChatInput)
  } catch (error) {
    toastStore.error(error.message)
  } finally {
    isSending.value = false
    if (canChat.value) {
      nextTick(focusChatInput)
    }
  }
}

async function handleSendDeadMessage() {
  if (isSending.value || !deadChatDraft.value.trim() || !canSendDeadChat.value) return

  isSending.value = true

  try {
    const sentMessage = await sendGameMessage({
      roomId: roomId.value,
      gameId: game.value?.id,
      userId: savedUser.value?.id,
      nickname: savedUser.value?.nickname || '알 수 없음',
      content: deadChatDraft.value,
      channelType: 'dead',
    })

    deadChatDraft.value = ''
    pushMessage(sentMessage)
  } catch (error) {
    toastStore.error(error.message)
  } finally {
    isSending.value = false
  }
}

async function handleSkipPhaseCommand() {
  if (!canSkipPhaseCommand.value) {
    toastStore.error('방장만 /스킵 명령을 사용할 수 있습니다.')
    return
  }

  isSending.value = true

  try {
    await skipCurrentPhase(roomId.value)
    chatDraft.value = ''
    toastStore.success('현재 단계를 스킵했습니다.')
    await loadGame({ silent: true })
    await loadMessages()
  } catch (error) {
    toastStore.error(error.message)
  } finally {
    isSending.value = false
    nextTick(focusChatInput)
  }
}

async function handleNightAction() {
  if (!canNightAction.value || !selectedNightTarget.value || isSubmittingAction.value) return

  isSubmittingAction.value = true

  try {
    await submitNightAction(roomId.value, nightActionType.value, selectedNightTarget.value)
    await loadRoleSideData()
    toastStore.success('밤 행동을 제출했습니다.')
  } catch (error) {
    toastStore.error(error.message)
  } finally {
    isSubmittingAction.value = false
  }
}

async function handleVote() {
  if (!canVote.value || !selectedVoteTarget.value || isSubmittingVote.value) return

  isSubmittingVote.value = true

  try {
    await submitVote(roomId.value, selectedVoteTarget.value)
    await loadRoleSideData()
    toastStore.success('투표를 제출했습니다.')
  } catch (error) {
    toastStore.error(error.message)
  } finally {
    isSubmittingVote.value = false
  }
}

async function handleFinalDefenseVote(approveExecution) {
  if (!canFinalDefenseVote.value || isSubmittingFinalDefenseVote.value) return

  isSubmittingFinalDefenseVote.value = true

  try {
    await submitFinalDefenseVote(roomId.value, approveExecution)
    toastStore.success(approveExecution ? '처형 찬성표를 제출했습니다.' : '처형 보류표를 제출했습니다.')
  } catch (error) {
    toastStore.error(error.message)
  } finally {
    isSubmittingFinalDefenseVote.value = false
  }
}

async function handleEndGame() {
  if (!isHost.value || isEnding.value) return

  isEnding.value = true

  try {
    const endingRoom = room.value
    const endingGame = game.value

    await endGame(roomId.value)
    await saveGameLogFile(endingRoom, endingGame)

    isEndConfirmOpen.value = false
    router.push(`/rooms/${roomId.value}`)
  } catch (error) {
    toastStore.error(error.message)
  } finally {
    isEnding.value = false
  }
}

watch(roleKey, () => {
  messages.value = messages.value.filter(canSeeGameMessage)
})

watch(isAlive, (alive, wasAlive) => {
  messages.value = messages.value.filter(canSeeGameMessage)

  if (!alive && wasAlive !== false) {
    toastStore.info('사망했습니다. 이제 사후 채팅에 참여할 수 있습니다.')
    loadMessages()
  }
})

watch(availableMainChatChannels, (channels) => {
  if (!channels.some((channel) => channel.key === activeMainChatChannel.value)) {
    activeMainChatChannel.value = channels[0]?.key || 'public'
  }
})

watch([phaseKey, nightRoleChatChannel, isAlive], ([phase, teamChannel, alive]) => {
  if (!alive) {
    return
  }

  activeMainChatChannel.value = phase === 'night' && teamChannel ? teamChannel : 'public'
})

watch(
  [() => savedUser.value?.id, roomId, () => game.value?.id],
  () => {
    selectedMemoPlayerId.value = ''
    loadPlayerRoleMemos()
  },
)

onMounted(async () => {
  await loadGame()
  startRoomHeartbeat()
  await loadMessages()
  nextTick(focusChatInput)

  countdownTimer = setInterval(() => {
    nowTick.value = Date.now()
    maybeSyncExpiredGameState()
    maybeReturnToLobby()
  }, 1000)

  gameStatePollTimer = setInterval(async () => {
    await loadGame({ silent: true })
    await loadMessages()
  }, GAME_STATE_POLL_INTERVAL_MS)

  unsubscribeRoom = subscribeToRoom(roomId.value, (payload) => {
    if (payload?.type === 'subscription-status') return
    if (payload?.table === 'rooms' && payload.new) {
      mergeRoomRealtimePayload(payload.new)
    }
    loadGame({ silent: true })
  })

  unsubscribeGame = subscribeToGame(roomId.value, (payload) => {
    if (payload?.type === 'subscription-status') return
    if (payload.new) {
      mergeGameRealtimePayload(payload.new)
    }
    loadGame({ silent: true })
  })

  unsubscribeMessages = subscribeToGameMessages(roomId.value, game.value?.id, (payload) => {
    if (payload?.type === 'subscription-status') return
    const message = normalizeGameMessage(payload.new)
    pushMessage(message)
    if (['night_start', 'day_start', 'vote_start', 'final_defense_start'].includes(message.eventKey)) {
      loadGame({ silent: true })
    }
  })
})

onBeforeUnmount(() => {
  unsubscribeRoom?.()
  unsubscribeGame?.()
  unsubscribeMessages?.()
  if (countdownTimer) clearInterval(countdownTimer)
  if (gameStatePollTimer) clearInterval(gameStatePollTimer)
  stopRoomHeartbeat()
})
</script>

<template>
  <section class="page-card game-play-view">
    <div class="game-veil" aria-hidden="true"></div>

    <div v-if="isLoading" class="game-loading">게임 정보를 불러오는 중...</div>

    <template v-else>
      <header class="game-status-bar">
        <div class="status-title">
          <p>MAFIA GAME · ROUND {{ game?.round_no || 1 }}</p>
          <strong>{{ phaseLabel }}</strong>
        </div>

        <div class="status-actions">
          <template v-if="isGameOverScreen">
            <div class="game-over-countdown">
              <strong>{{ returnToLobbySeconds }}초</strong>
              <span>후 대기방으로 이동</span>
            </div>
            <button type="button" :disabled="isReturningToLobby" @click="returnToLobbyNow">
              대기방으로 돌아가기
            </button>
          </template>
          <template v-else>
            <span>남은 시간 <b>{{ remainingSeconds }}초</b></span>
            <button type="button" @click="router.push(`/rooms/${roomId}`)">대기방 보기</button>
            <button
              v-if="isHost"
              class="end-game-button"
              type="button"
              :disabled="isEnding"
              @click="isEndConfirmOpen = true"
            >
              게임 종료
            </button>
          </template>
        </div>
      </header>

      <section v-if="isGameOverScreen" class="game-over-screen">
        <header class="game-over-hero" :class="resultWinnerAccent">
          <span class="eyebrow">GAME OVER</span>
          <h2>🏆 {{ resultWinnerLabel }}</h2>
          <p class="game-over-reason">{{ resultEndReason }}</p>
        </header>

        <div class="result-primary-grid" :class="{ 'without-mvp': !resultMvp }">
          <section v-if="resultMvp" class="result-panel mvp-panel">
            <span class="section-kicker">🏅 이번 판 MVP</span>
            <strong class="mvp-name">{{ resultMvp.nickname }}</strong>
            <div class="result-badge-row">
              <span>{{ getResultTeamLabel(resultMvp.role) }}</span>
              <span>{{ resultMvp.is_alive ? '생존' : '사망' }}</span>
            </div>
            <p>{{ resultMvp.reason || resultMvp.summary || '이번 게임에서 인상적인 활약을 보여주었습니다.' }}</p>
          </section>

          <section class="result-panel my-result-panel">
            <span class="section-kicker">내 결과</span>
            <template v-if="myResultPlayer">
              <strong class="my-result-title">{{ myContributionSummary.title }}</strong>
              <div class="result-badge-row">
                <span>{{ getResultTeamLabel(myResultPlayer.role) }}</span>
                <span>{{ myResultPlayer.is_alive ? '생존' : '사망' }}</span>
                <span :class="{ victory: myResultPlayer.is_winner, defeat: !myResultPlayer.is_winner }">
                  {{ myResultPlayer.is_winner ? '승리' : '패배' }}
                </span>
              </div>
              <p>{{ myContributionSummary.description }}</p>
            </template>
            <p v-else>이번 게임의 개인 결과를 불러오지 못했습니다.</p>
          </section>
        </div>

        <div class="game-over-grid">
          <section class="result-panel winner-panel" :class="resultWinnerAccent">
            <span class="section-kicker">승리 팀</span>
            <div class="winner-list">
              <article v-for="winner in resultWinners" :key="winner.user_id" class="winner-chip">
                <strong>{{ winner.nickname }}</strong>
                <span>{{ getResultTeamLabel(winner.role) }}</span>
              </article>
            </div>
          </section>

          <section class="result-panel">
            <span class="section-kicker">게임 요약</span>
            <div class="result-summary-grid">
              <article>
                <strong>승리 팀</strong>
                <p>{{ resultWinnerLabel }}</p>
              </article>
              <article>
                <strong>승리 사유</strong>
                <p>{{ resultEndReason }}</p>
              </article>
              <article>
                <strong>라운드</strong>
                <p>Round {{ game?.round_no || 1 }}</p>
              </article>
              <article>
                <strong>생존자</strong>
                <p>{{ resultSurvivorCount }} / {{ resultPlayers.length }}명</p>
              </article>
            </div>
          </section>

          <section class="result-panel my-contribution-panel">
            <span class="section-kicker">내 기여 상세</span>
            <div class="my-contribution-summary">
              <strong>{{ myContributionSummary.title }}</strong>
              <p>{{ myContributionSummary.description }}</p>
            </div>
            <ul class="my-contribution-list">
              <li v-for="item in myContributionSummary.items" :key="item">{{ item }}</li>
            </ul>
          </section>
        </div>

        <section class="result-panel player-result-panel">
          <span class="section-kicker">플레이어 결과</span>
          <div class="player-result-list">
            <article
              v-for="player in resultPlayers"
              :key="player.user_id"
              class="player-result-card"
              :class="{ winner: player.is_winner, mafia: player.team === 'mafia' }"
            >
              <header class="player-result-header">
                <div>
                  <strong>{{ player.nickname }}</strong>
                  <span>{{ getResultTeamLabel(player.role) }}</span>
                </div>
                <div class="player-result-status">
                  <span :class="{ alive: player.is_alive, dead: !player.is_alive }">
                    {{ player.is_alive ? '생존' : '사망' }}
                  </span>
                  <b :class="{ victory: player.is_winner, defeat: !player.is_winner }">
                    {{ player.is_winner ? '승리' : '패배' }}
                  </b>
                </div>
              </header>

              <ul v-if="player.logs?.length" class="player-log-list">
                <li v-for="log in player.logs.slice(0, 3)" :key="log">{{ log }}</li>
              </ul>
              <p v-else class="player-log-empty">기록된 행동 로그가 없습니다.</p>
            </article>
          </div>
        </section>
      </section>

      <main v-else class="game-layout">
        <div class="chat-area" :class="{ dead: !isAlive }">
        <section class="chat-panel main-chat-panel">
          <header class="chat-header">
            <div>
              <span class="eyebrow">LIVE DISCUSSION</span>
              <h2 class="chat-title">{{ chatPanelTitle }}</h2>
              <h1>실시간 채팅</h1>
            </div>
            <span class="chat-status-badge" :class="{ locked: !canChat && !canSkipPhaseCommand }">
              {{ canChat ? '채팅 가능' : canSkipPhaseCommand ? '스킵 가능' : '채팅 잠김' }}
            </span>
          </header>

          <div class="chat-phase-banner">
            {{ chatPhaseBanner }}
          </div>

          <nav v-if="isAlive && availableMainChatChannels.length > 1" class="chat-tabs" aria-label="전송 채널">
            <button
              v-for="channel in availableMainChatChannels"
              :key="channel.key"
              type="button"
              class="chat-tab"
              :class="[channel.key, { active: activeMainChatChannel === channel.key }]"
              @click="activeMainChatChannel = channel.key"
            >
              {{ channel.label }}
            </button>
          </nav>

          <div ref="chatMessagesRef" class="chat-messages">
            <div
              v-for="message in mainVisibleMessages"
              :key="message.id"
              :class="
                message.messageType === 'system'
                  ? 'system-message-row'
                  : [
                      'chat-message-row',
                      message.userId === savedUser?.id ? 'mine' : 'other',
                    ]
              "
            >
              <template v-if="message.messageType === 'system'">
                <span>{{ message.content }}</span>
              </template>

              <template v-else>
                <div class="chat-bubble" :class="`channel-${message.channelType || 'public'}`">
                  <div class="chat-meta">
                    <strong>{{ message.nickname }}</strong>
                    <span v-if="message.channelType !== 'public'" class="chat-channel-chip">
                      {{ chatChannelLabels[message.channelType] || message.channelType }}
                    </span>
                    <time>{{ message.createdAt }}</time>
                  </div>
                  <p>{{ message.content }}</p>
                </div>
              </template>
            </div>

            <div v-if="mainVisibleMessages.length === 0" class="empty-chat">
              아직 메시지가 없습니다. 토론이 시작되면 이곳에서 대화가 진행됩니다.
            </div>
          </div>

          <form class="chat-input-area" @submit.prevent="handleSendMessage">
            <input
              ref="chatInputRef"
              v-model="chatDraft"
              :disabled="!canUseChatInput || isSending"
              :placeholder="chatPlaceholder"
              maxlength="240"
            />
            <button type="submit" :disabled="!canSubmitChatInput || isSending || !chatDraft.trim()">
              전송
            </button>
          </form>
        </section>

        <section v-if="!isAlive" class="chat-panel dead-chat-panel">
          <header class="chat-header">
            <div>
              <span class="eyebrow">AFTERLIFE</span>
              <h2 class="chat-title">사후 채팅</h2>
            </div>
            <span class="chat-status-badge">채팅 가능</span>
          </header>

          <div class="chat-phase-banner dead">
            사망한 플레이어끼리만 대화할 수 있습니다.
          </div>

          <div class="chat-messages">
            <div
              v-for="message in deadChatMessages"
              :key="message.id"
              :class="[
                'chat-message-row',
                message.userId === savedUser?.id ? 'mine' : 'other',
              ]"
            >
              <div class="chat-bubble channel-dead">
                <div class="chat-meta">
                  <strong>{{ message.nickname }}</strong>
                  <span class="chat-channel-chip dead">사후</span>
                  <time>{{ message.createdAt }}</time>
                </div>
                <p>{{ message.content }}</p>
              </div>
            </div>

            <div v-if="deadChatMessages.length === 0" class="empty-chat">
              아직 사후 채팅 메시지가 없습니다.
            </div>
          </div>

          <form class="chat-input-area" @submit.prevent="handleSendDeadMessage">
            <input
              v-model="deadChatDraft"
              :disabled="!canSendDeadChat || isSending"
              placeholder="사망한 플레이어끼리 대화할 수 있습니다"
              maxlength="240"
            />
            <button type="submit" :disabled="!canSendDeadChat || isSending || !deadChatDraft.trim()">
              전송
            </button>
          </form>
        </section>
        </div>

        <section class="info-card survivors-card survivors-card-main" :class="{ voting: phaseKey === 'vote' }">
          <header class="survivors-card-header">
            <span class="section-kicker">참가자</span>
            <button
              v-if="canNightAction"
              class="compact-action-button"
              type="button"
              :disabled="!selectedNightTarget || isSubmittingAction"
              :title="nightActionLabels[nightActionType]"
              @click="handleNightAction"
            >
              행동 제출
            </button>
            <button
              v-if="canVote"
              class="compact-action-button"
              type="button"
              :disabled="!selectedVoteTarget || isSubmittingVote"
              title="처형할 대상에게 투표합니다"
              @click="handleVote"
            >
              투표 제출
            </button>
            <div v-if="canFinalDefenseVote" class="compact-action-group">
              <button
                class="compact-action-button danger"
                type="button"
                :disabled="isSubmittingFinalDefenseVote"
                @click="handleFinalDefenseVote(true)"
              >
                처형
              </button>
              <button
                class="compact-action-button ghost"
                type="button"
                :disabled="isSubmittingFinalDefenseVote"
                @click="handleFinalDefenseVote(false)"
              >
                보류
              </button>
            </div>
          </header>
          <div class="survivor-list">
            <button
              v-for="player in playersWithStatus"
              :key="player.userId"
              type="button"
              class="survivor-chip"
              :class="{
                dead: !player.isAlive,
                me: player.isMe,
                selected: player.userId === selectedParticipantId,
                'memo-editing': player.userId === selectedMemoPlayerId,
                'team-mafia': player.visibleTeamRole === 'mafia',
                'team-police': player.visibleTeamRole === 'police',
                [`memo-${player.memoRole}`]: player.memoRole,
              }"
              @click="selectParticipant(player.userId)"
            >
              <strong>{{ player.nickname }}</strong>
              <span v-if="player.visibleTeamRole === 'mafia'" class="team-identity-label mafia">마피아 팀</span>
              <span v-if="player.visibleTeamRole === 'police'" class="team-identity-label police">경찰 팀</span>
              <span v-if="player.memoRole" class="player-memo-label" :class="player.memoRole">
                메모 {{ roleLabels[player.memoRole] }}
              </span>
              <span v-if="player.isMe">나</span>
              <span v-if="player.isHost">방장</span>
              <span>{{ player.isAlive ? '생존' : '사망' }}</span>
              <span v-if="phaseKey === 'vote' && player.isMyVoteTarget">내 선택</span>
              <span v-if="phaseKey === 'final_defense' && player.isFinalDefenseTarget">변론 대상</span>
            </button>
          </div>
          <section class="player-memo-panel" :class="{ empty: !selectedMemoPlayer }">
            <div class="player-memo-heading">
              <div>
                <span class="section-kicker">개인 역할 메모</span>
                <strong>{{ selectedMemoPlayer?.nickname || '참가자를 선택하세요' }}</strong>
              </div>
              <button
                v-if="Object.keys(playerRoleMemos).length > 0"
                type="button"
                class="memo-reset-button"
                @click="clearPlayerRoleMemos"
              >
                전체 초기화
              </button>
            </div>
            <p v-if="!selectedMemoPlayer">참가자 카드를 누르면 나만 볼 수 있는 색상 메모를 남길 수 있습니다.</p>
            <div v-else class="player-memo-options">
              <button
                v-for="option in playerMemoOptions"
                :key="option.tone"
                type="button"
                class="player-memo-option"
                :class="[option.tone, { active: (selectedMemoPlayer.memoRole || '') === option.key }]"
                @click="setPlayerRoleMemo(option.key)"
              >
                <span class="memo-color-swatch"></span>
                <strong>{{ option.label }}</strong>
                <small>{{ option.description }}</small>
              </button>
            </div>
          </section>
        </section>
        <aside class="game-info-panel">
          <section class="info-card my-info-card">
            <span class="section-kicker">내 정보</span>
            <div class="role-badge" :class="roleKey">
              <span>역할</span>
              <strong>{{ roleLabel }}</strong>
            </div>
            <div class="alive-state" :class="{ out: !isAlive }">{{ survivalText }}</div>
          </section>

          <section class="info-card">
            <span class="section-kicker">현재 진행</span>
            <dl class="phase-list">
              <div>
                <dt>현재 단계</dt>
                <dd>{{ phaseLabel }}</dd>
              </div>
              <div>
                <dt>라운드</dt>
                <dd>Round {{ game?.round_no || 1 }}</dd>
              </div>
              <div>
                <dt>다음 단계</dt>
                <dd>{{ nextPhase }}</dd>
              </div>
              <div class="timer-row">
                <dt>남은 시간</dt>
                <dd>{{ remainingSeconds }}초</dd>
              </div>
            </dl>
          </section>

          <section class="info-card role-info-card">
            <span class="section-kicker">역할 보조 정보</span>
            <div class="role-info-list">
              <article v-for="item in roleSpecificInfo" :key="`${item.type}-${item.roundNo || item.label}`">
                <strong>{{ item.label }}</strong>
                <p>{{ item.description }}</p>
              </article>
            </div>
          </section>

          <section class="info-card survivors-card" :class="{ voting: phaseKey === 'vote' }">
            <span class="section-kicker">참가자 상태</span>
            <div class="survivor-list">
              <article
                v-for="player in playersWithStatus"
                :key="player.userId"
                class="survivor-chip"
                :class="{
                  dead: !player.isAlive,
                  me: player.isMe,
                  'team-mafia': player.visibleTeamRole === 'mafia',
                  'team-police': player.visibleTeamRole === 'police',
                  [`memo-${player.memoRole}`]: player.memoRole,
                }"
              >
                <strong>{{ player.nickname }}</strong>
                <span v-if="player.visibleTeamRole === 'mafia'" class="team-identity-label mafia">마피아 팀</span>
                <span v-if="player.visibleTeamRole === 'police'" class="team-identity-label police">경찰 팀</span>
                <span v-if="player.memoRole" class="player-memo-label" :class="player.memoRole">
                  메모 {{ roleLabels[player.memoRole] }}
                </span>
                <span v-if="player.isMe">나</span>
                <span v-if="player.isHost">방장</span>
                <span>{{ player.isAlive ? '생존' : '사망' }}</span>
                <span v-if="phaseKey === 'vote' && player.isMyVoteTarget">내 선택</span>
                <span v-if="phaseKey === 'final_defense' && player.isFinalDefenseTarget">변론 대상</span>
              </article>
            </div>
          </section>

          <section class="info-card guide-card">
            <span class="section-kicker">현재 행동 안내</span>
            <p>{{ actionGuide }}</p>
          </section>
        </aside>
      </main>

      <div v-if="isEndConfirmOpen" class="confirm-backdrop" @click.self="isEndConfirmOpen = false">
        <section class="confirm-modal">
          <h2>게임을 종료할까요?</h2>
          <p>현재 진행 중인 게임을 종료하고 모든 플레이어를 대기방 상태로 되돌립니다.</p>
          <div>
            <button type="button" class="ghost-button" :disabled="isEnding" @click="isEndConfirmOpen = false">
              취소
            </button>
            <button type="button" class="danger-button" :disabled="isEnding" @click="handleEndGame">
              종료
            </button>
          </div>
        </section>
      </div>
    </template>
  </section>
</template>

<style scoped>
.game-play-view {
  background:
    radial-gradient(circle at 50% -12%, rgba(255, 190, 85, 0.15), transparent 34%),
    radial-gradient(circle at 13% 18%, rgba(127, 29, 29, 0.2), transparent 31%),
    linear-gradient(180deg, rgba(35, 20, 14, 0.97), rgba(8, 6, 6, 0.99));
  border: 1px solid rgba(255, 190, 85, 0.18);
  display: grid;
  gap: clamp(0.9rem, 1.8vw, 1.25rem);
  min-height: min(820px, calc(100vh - 3rem));
  overflow: hidden;
  position: relative;
}

.game-veil {
  background:
    linear-gradient(90deg, transparent, rgba(255, 190, 85, 0.075), transparent),
    radial-gradient(circle at 78% 18%, rgba(255, 138, 0, 0.08), transparent 28%);
  inset: 0;
  pointer-events: none;
  position: absolute;
}

.game-loading,
.game-status-bar,
.game-layout {
  position: relative;
  z-index: 1;
}

.game-loading {
  color: rgba(255, 245, 224, 0.72);
  font-weight: 900;
}

.game-status-bar {
  align-items: center;
  background: rgba(10, 7, 6, 0.46);
  border: 1px solid rgba(255, 190, 85, 0.14);
  border-radius: 14px;
  box-shadow: 0 18px 42px rgba(0, 0, 0, 0.22);
  display: flex;
  gap: 1rem;
  justify-content: space-between;
  padding: 0.85rem 1rem;
}

.status-title p,
.chat-header p,
.section-kicker {
  color: rgba(255, 190, 85, 0.72);
  font-size: 0.72rem;
  font-weight: 900;
  letter-spacing: 0.08em;
  margin: 0;
  text-transform: uppercase;
}

.status-title strong {
  color: #fff1d6;
  display: block;
  font-size: clamp(1.35rem, 2.4vw, 2rem);
  font-weight: 900;
  line-height: 1.1;
  margin-top: 0.1rem;
  text-shadow: 0 0 24px rgba(255, 138, 0, 0.2);
}

.status-actions {
  align-items: center;
  display: flex;
  gap: 0.75rem;
}

.status-actions span {
  color: rgba(255, 245, 224, 0.66);
  font-size: 0.86rem;
  font-weight: 800;
  white-space: nowrap;
}

.status-actions b {
  color: #ffbe55;
  margin-left: 0.3rem;
}

.status-actions button,
.chat-input-row button,
.action-card button,
.confirm-modal button {
  border: 0;
  border-radius: 8px;
  cursor: pointer;
  font: inherit;
  font-weight: 900;
  white-space: nowrap;
}

.status-actions button,
.chat-input-row button,
.action-card button,
.confirm-modal .danger-button {
  background: linear-gradient(180deg, #ffbe55, #b86b1b);
  color: #231107;
  padding: 0.68rem 0.95rem;
}

.status-actions .end-game-button,
.confirm-modal .danger-button {
  background: linear-gradient(180deg, #f87171, #991b1b);
  color: #fff7ed;
}

button:disabled {
  cursor: not-allowed;
  opacity: 0.55;
}

.game-layout {
  align-items: start;
  display: grid;
  gap: clamp(0.9rem, 1.7vw, 1.25rem);
  grid-template-columns: minmax(0, 7fr) minmax(18rem, 3fr);
}

.chat-area {
  grid-column: 1;
  grid-row: 1;
  display: grid;
  gap: 0.9rem;
  min-width: 0;
}

.chat-area.dead {
  grid-template-columns: repeat(2, minmax(0, 1fr));
}

.survivors-card-main {
  grid-column: 1;
  grid-row: 2;
}

.game-info-panel {
  display: grid;
  gap: 0.9rem;
  grid-column: 2;
  grid-row: 1 / span 2;
}

.chat-panel,
.info-card {
  background:
    linear-gradient(180deg, rgba(255, 255, 255, 0.055), rgba(255, 255, 255, 0.022)),
    rgba(14, 10, 8, 0.76);
  border: 1px solid rgba(255, 190, 85, 0.16);
  border-radius: 16px;
  box-shadow:
    0 24px 60px rgba(0, 0, 0, 0.38),
    inset 0 0 34px rgba(255, 138, 0, 0.04);
}

.chat-panel {
  display: flex;
  flex-direction: column;
  height: clamp(38rem, 72vh, 46rem);
  overflow: hidden;
}

.chat-header {
  align-items: center;
  border-bottom: 1px solid rgba(255, 190, 85, 0.11);
  display: flex;
  flex-shrink: 0;
  justify-content: space-between;
  padding: 1.15rem 1.25rem 0.95rem;
}

.chat-header h1 {
  color: #fff1d6;
  font-size: clamp(1.6rem, 3vw, 2.4rem);
  font-weight: 900;
  letter-spacing: 0;
  line-height: 1;
  margin: 0.2rem 0 0;
}

.chat-state {
  background: rgba(74, 222, 128, 0.12);
  border: 1px solid rgba(74, 222, 128, 0.28);
  border-radius: 999px;
  color: #86efac;
  font-size: 0.78rem;
  font-weight: 900;
  padding: 0.38rem 0.65rem;
}

.chat-state.locked {
  background: rgba(148, 116, 84, 0.12);
  border-color: rgba(255, 255, 255, 0.08);
  color: rgba(255, 245, 224, 0.52);
}

.chat-messages {
  display: flex;
  flex: 1;
  flex-direction: column;
  gap: 0.8rem;
  min-height: 0;
  overflow-y: auto;
  padding: 1rem 1.25rem;
  scrollbar-color: rgba(255, 190, 85, 0.36) rgba(0, 0, 0, 0.18);
}

.chat-message {
  background: rgba(0, 0, 0, 0.24);
  border: 1px solid rgba(255, 255, 255, 0.065);
  border-radius: 12px;
  max-width: min(76%, 48rem);
  padding: 0.78rem 0.9rem;
}

.chat-message.mine {
  align-self: flex-end;
  background:
    linear-gradient(180deg, rgba(255, 190, 85, 0.15), rgba(96, 42, 18, 0.22)),
    rgba(0, 0, 0, 0.25);
  border-color: rgba(255, 190, 85, 0.22);
}

.system-message {
  align-items: center;
  color: rgba(255, 210, 138, 0.82);
  display: flex;
  font-size: 0.82rem;
  font-weight: 900;
  gap: 0.75rem;
  justify-content: center;
  line-height: 1.4;
  margin: 0.2rem 0;
  text-align: center;
}

.system-message::before,
.system-message::after {
  background: rgba(255, 190, 85, 0.16);
  content: '';
  flex: 1;
  height: 1px;
  min-width: 2rem;
}

.system-message span {
  background: rgba(255, 190, 85, 0.08);
  border: 1px solid rgba(255, 190, 85, 0.14);
  border-radius: 999px;
  padding: 0.35rem 0.7rem;
}

.message-meta {
  align-items: center;
  display: flex;
  gap: 0.65rem;
  justify-content: space-between;
}

.message-meta strong {
  color: #ffd28a;
  font-size: 0.82rem;
  font-weight: 900;
}

.message-meta time {
  color: rgba(255, 245, 224, 0.42);
  font-size: 0.72rem;
  font-weight: 800;
}

.chat-message p {
  color: rgba(255, 245, 224, 0.86);
  font-size: 0.98rem;
  font-weight: 750;
  line-height: 1.55;
  margin: 0.28rem 0 0;
  overflow-wrap: anywhere;
}

.empty-chat {
  align-self: center;
  color: rgba(255, 245, 224, 0.48);
  font-weight: 800;
  margin: auto;
  text-align: center;
}

.chat-input-row {
  align-items: center;
  border-top: 1px solid rgba(255, 190, 85, 0.11);
  display: grid;
  flex-shrink: 0;
  gap: 0.7rem;
  grid-template-columns: minmax(0, 1fr) auto;
  padding: 0.95rem 1.25rem 1.1rem;
}

.chat-input-row input,
.action-card select {
  background: rgba(0, 0, 0, 0.34);
  border: 1px solid rgba(255, 190, 85, 0.14);
  border-radius: 10px;
  color: #fff1d6;
  font: inherit;
  font-weight: 800;
  min-height: 48px;
  min-width: 0;
  outline: none;
  padding: 0.82rem 0.9rem;
}

.chat-input-row button {
  min-height: 48px;
  min-width: 5.75rem;
}

.chat-input-row input:focus,
.action-card select:focus {
  border-color: rgba(255, 190, 85, 0.42);
  box-shadow: 0 0 0 3px rgba(255, 190, 85, 0.08);
}

.chat-input-row input:disabled {
  cursor: not-allowed;
  opacity: 0.48;
}

.game-info-panel {
  align-content: start;
  min-width: 0;
}

.info-card {
  display: grid;
  gap: 0.75rem;
  padding: 1rem;
}

.role-badge {
  background: rgba(255, 190, 85, 0.1);
  border: 1px solid rgba(255, 190, 85, 0.2);
  border-radius: 12px;
  display: grid;
  gap: 0.18rem;
  padding: 0.85rem;
}

.role-badge.mafia {
  background: rgba(127, 29, 29, 0.18);
  border-color: rgba(248, 113, 113, 0.32);
}

.role-badge.police {
  background: rgba(30, 64, 175, 0.15);
  border-color: rgba(96, 165, 250, 0.28);
}

.role-badge.doctor {
  background: rgba(22, 101, 52, 0.14);
  border-color: rgba(74, 222, 128, 0.24);
}

.role-badge span,
.phase-list dt,
.action-card label {
  color: rgba(255, 245, 224, 0.58);
  font-size: 0.78rem;
  font-weight: 900;
}

.role-badge strong {
  color: #fff1d6;
  font-size: 1.8rem;
  font-weight: 900;
  line-height: 1;
}

.alive-state {
  color: #86efac;
  font-weight: 900;
}

.alive-state.out {
  color: #fca5a5;
}

.phase-list {
  display: grid;
  gap: 0.5rem;
  margin: 0;
}

.phase-list > div {
  align-items: center;
  display: flex;
  gap: 0.7rem;
  justify-content: space-between;
}

.phase-list dd {
  color: #fff1d6;
  font-weight: 900;
  margin: 0;
  text-align: right;
}

.phase-list .timer-row dd {
  color: #ffbe55;
  font-size: 1.35rem;
}

.role-info-list {
  display: grid;
  gap: 0.5rem;
}

.role-info-list article {
  background: rgba(255, 255, 255, 0.045);
  border: 1px solid rgba(255, 190, 85, 0.1);
  border-radius: 10px;
  padding: 0.72rem;
}

.role-info-list strong {
  color: #ffd28a;
  display: block;
  font-size: 0.9rem;
  font-weight: 900;
}

.role-info-list p,
.guide-card p {
  color: rgba(255, 245, 224, 0.76);
  font-weight: 850;
  line-height: 1.55;
  margin: 0.2rem 0 0;
}

.survivor-list {
  display: grid;
  gap: 0.55rem;
  grid-template-columns: repeat(auto-fit, minmax(8rem, 1fr));
}

.survivors-card-header {
  align-items: center;
  display: flex;
  gap: 0.75rem;
  justify-content: space-between;
  min-height: 2rem;
}

.compact-action-button {
  background: linear-gradient(180deg, #ffbe55, #b86b1b);
  border: 0;
  border-radius: 7px;
  color: #231107;
  cursor: pointer;
  font: inherit;
  font-size: 0.74rem;
  font-weight: 900;
  min-height: 2rem;
  padding: 0.42rem 0.7rem;
  white-space: nowrap;
}

.compact-action-group {
  display: flex;
  gap: 0.45rem;
}

.compact-action-button.danger {
  background: linear-gradient(180deg, #f87171, #991b1b);
  color: #fff7ed;
}

.compact-action-button.ghost {
  background: rgba(255, 255, 255, 0.07);
  border: 1px solid rgba(255, 190, 85, 0.22);
  color: #ffd28a;
}

.compact-action-button:disabled {
  cursor: not-allowed;
  opacity: 0.5;
}

.survivor-chip {
  background: rgba(255, 255, 255, 0.055);
  border: 1px solid rgba(255, 190, 85, 0.13);
  border-radius: 10px;
  color: rgba(255, 245, 224, 0.82);
  cursor: pointer;
  display: flex;
  flex-wrap: wrap;
  gap: 0.35rem;
  text-align: left;
  width: 100%;
  min-height: 3.25rem;
  padding: 0.62rem;
}

.survivor-chip:hover:not(:disabled),
.survivor-chip:focus-visible:not(:disabled) {
  border-color: rgba(255, 190, 85, 0.4);
  box-shadow: 0 0 0 3px rgba(255, 190, 85, 0.08);
  transform: translateY(-1px);
}

.survivor-chip:disabled {
  cursor: default;
}

.survivor-chip strong {
  color: #fff1d6;
  flex-basis: 100%;
  font-size: 0.92rem;
  font-weight: 900;
}

.survivor-chip span {
  background: rgba(0, 0, 0, 0.22);
  border: 1px solid rgba(255, 255, 255, 0.075);
  border-radius: 999px;
  color: rgba(255, 245, 224, 0.7);
  font-size: 0.7rem;
  font-weight: 900;
  padding: 0.18rem 0.42rem;
}

.survivor-chip.me {
  border-color: rgba(255, 190, 85, 0.36);
}

.survivor-chip.team-mafia {
  background: rgba(127, 29, 29, 0.34);
  border-color: rgba(248, 113, 113, 0.72);
  box-shadow: inset 0 0 18px rgba(248, 113, 113, 0.08);
}

.survivor-chip.team-mafia strong {
  color: #fecaca;
}

.survivor-chip.team-police {
  background: rgba(30, 64, 175, 0.3);
  border-color: rgba(96, 165, 250, 0.68);
  box-shadow: inset 0 0 18px rgba(96, 165, 250, 0.08);
}

.survivor-chip.team-police strong {
  color: #bfdbfe;
}

.survivor-chip .team-identity-label {
  border-width: 1px;
  color: #fff;
}

.survivor-chip .team-identity-label.mafia {
  background: rgba(153, 27, 27, 0.72);
  border-color: rgba(252, 165, 165, 0.54);
  color: #fee2e2;
}

.survivor-chip .team-identity-label.police {
  background: rgba(30, 64, 175, 0.7);
  border-color: rgba(147, 197, 253, 0.5);
  color: #dbeafe;
}

.survivor-chip.dead {
  opacity: 0.55;
}

.survivor-chip.selected {
  border-color: rgba(255, 190, 85, 0.7);
  box-shadow:
    0 0 0 1px rgba(255, 190, 85, 0.15),
    0 0 0 3px rgba(255, 190, 85, 0.08);
}

.survivor-chip.memo-editing {
  outline: 1px dashed rgba(255, 210, 138, 0.72);
  outline-offset: 3px;
}

.survivor-chip.memo-mafia {
  background: rgba(127, 29, 29, 0.3);
  border-color: rgba(248, 113, 113, 0.64);
}

.survivor-chip.memo-police {
  background: rgba(30, 64, 175, 0.28);
  border-color: rgba(96, 165, 250, 0.64);
}

.survivor-chip.memo-doctor {
  background: rgba(20, 83, 45, 0.3);
  border-color: rgba(74, 222, 128, 0.58);
}

.survivor-chip .player-memo-label {
  border-width: 1px;
}

.survivor-chip .player-memo-label.mafia {
  background: rgba(153, 27, 27, 0.7);
  border-color: rgba(252, 165, 165, 0.48);
  color: #fee2e2;
}

.survivor-chip .player-memo-label.police {
  background: rgba(30, 64, 175, 0.68);
  border-color: rgba(147, 197, 253, 0.48);
  color: #dbeafe;
}

.survivor-chip .player-memo-label.doctor {
  background: rgba(21, 128, 61, 0.62);
  border-color: rgba(134, 239, 172, 0.44);
  color: #dcfce7;
}

.player-memo-panel {
  background: rgba(8, 7, 6, 0.42);
  border: 1px solid rgba(255, 190, 85, 0.16);
  border-radius: 8px;
  display: grid;
  gap: 0.7rem;
  margin-top: 0.75rem;
  padding: 0.75rem;
}

.player-memo-panel.empty {
  border-style: dashed;
}

.player-memo-panel p {
  color: rgba(255, 245, 224, 0.58);
  font-size: 0.76rem;
  font-weight: 800;
  line-height: 1.5;
  margin: 0;
}

.player-memo-heading {
  align-items: center;
  display: flex;
  gap: 0.75rem;
  justify-content: space-between;
}

.player-memo-heading strong {
  color: #fff1d6;
  display: block;
  font-size: 0.9rem;
  margin-top: 0.2rem;
}

.memo-reset-button {
  background: rgba(255, 255, 255, 0.045);
  border: 1px solid rgba(255, 190, 85, 0.18);
  border-radius: 6px;
  color: rgba(255, 245, 224, 0.7);
  cursor: pointer;
  font: inherit;
  font-size: 0.7rem;
  font-weight: 900;
  padding: 0.4rem 0.56rem;
}

.player-memo-options {
  display: grid;
  gap: 0.45rem;
  grid-template-columns: repeat(4, minmax(0, 1fr));
}

.player-memo-option {
  align-items: center;
  background: rgba(255, 255, 255, 0.045);
  border: 1px solid rgba(255, 255, 255, 0.09);
  border-radius: 7px;
  color: rgba(255, 245, 224, 0.76);
  cursor: pointer;
  display: grid;
  font: inherit;
  gap: 0.16rem;
  justify-items: start;
  min-width: 0;
  padding: 0.48rem;
}

.player-memo-option:hover,
.player-memo-option:focus-visible,
.player-memo-option.active {
  border-color: rgba(255, 190, 85, 0.56);
  box-shadow: 0 0 0 2px rgba(255, 190, 85, 0.08);
}

.player-memo-option strong {
  font-size: 0.76rem;
}

.player-memo-option small {
  color: rgba(255, 245, 224, 0.5);
  font-size: 0.64rem;
  font-weight: 800;
}

.memo-color-swatch {
  background: rgba(255, 255, 255, 0.16);
  border: 1px solid rgba(255, 255, 255, 0.2);
  border-radius: 50%;
  height: 0.7rem;
  width: 0.7rem;
}

.player-memo-option.mafia .memo-color-swatch {
  background: #ef4444;
}

.player-memo-option.police .memo-color-swatch {
  background: #3b82f6;
}

.player-memo-option.doctor .memo-color-swatch {
  background: #22c55e;
}

.game-info-panel .survivors-card {
  display: none;
}

.game-over-screen {
  display: grid;
  gap: 1rem;
  position: relative;
  z-index: 1;
}

.game-over-hero {
  background:
    linear-gradient(180deg, rgba(255, 190, 85, 0.1), rgba(255, 255, 255, 0.02)),
    rgba(14, 10, 8, 0.82);
  border: 1px solid rgba(255, 190, 85, 0.34);
  border-radius: 16px;
  box-shadow: inset 0 0 52px rgba(255, 190, 85, 0.06);
  padding: 3rem 1.5rem;
  text-align: center;
}

.game-over-hero.mafia {
  border-color: rgba(248, 113, 113, 0.45);
  box-shadow: inset 0 0 58px rgba(127, 29, 29, 0.2);
}

.game-over-hero.citizen {
  border-color: rgba(255, 190, 85, 0.42);
}

.game-over-hero h2 {
  color: #fff1d6;
  font-size: clamp(2.5rem, 5vw, 4.7rem);
  font-weight: 900;
  line-height: 1.08;
  margin: 0.55rem 0 0;
}

.game-over-reason {
  color: rgba(255, 245, 224, 0.78);
  font-size: 1.05rem;
  font-weight: 850;
  line-height: 1.5;
  margin: 0.8rem 0 0;
}

.game-over-countdown {
  align-items: end;
  background: rgba(0, 0, 0, 0.2);
  border: 1px solid rgba(255, 190, 85, 0.14);
  border-radius: 8px;
  color: rgba(255, 245, 224, 0.68);
  display: grid;
  gap: 0.08rem;
  padding: 0.48rem 0.68rem;
  text-align: right;
}

.game-over-countdown strong {
  color: #ffbe55;
  font-size: 1.05rem;
  line-height: 1;
}

.game-over-countdown span {
  font-size: 0.72rem;
  font-weight: 800;
}

.result-primary-grid {
  display: grid;
  gap: 1rem;
  grid-template-columns: repeat(2, minmax(0, 1fr));
}

.result-primary-grid.without-mvp {
  grid-template-columns: 1fr;
}

.game-over-grid {
  display: grid;
  gap: 1rem;
  grid-template-columns: repeat(3, minmax(0, 1fr));
}

.result-panel {
  background:
    linear-gradient(180deg, rgba(255, 255, 255, 0.045), rgba(255, 255, 255, 0.016)),
    rgba(14, 10, 8, 0.8);
  border: 1px solid rgba(255, 190, 85, 0.16);
  border-radius: 16px;
  display: grid;
  gap: 0.9rem;
  padding: 1rem;
}

.mvp-panel {
  background:
    linear-gradient(180deg, rgba(255, 190, 85, 0.15), rgba(255, 190, 85, 0.035)),
    rgba(14, 10, 8, 0.84);
  border-color: rgba(255, 190, 85, 0.48);
  box-shadow:
    0 0 0 1px rgba(255, 190, 85, 0.08),
    0 16px 42px rgba(255, 154, 31, 0.12);
}

.mvp-name,
.my-result-title {
  color: #fff1d6;
  font-size: 1.65rem;
  font-weight: 900;
}

.mvp-panel p,
.my-result-panel p {
  color: rgba(255, 245, 224, 0.76);
  font-weight: 800;
  line-height: 1.55;
  margin: 0;
}

.my-result-panel {
  background:
    linear-gradient(180deg, rgba(52, 211, 153, 0.1), rgba(255, 255, 255, 0.016)),
    rgba(14, 10, 8, 0.82);
  border-color: rgba(52, 211, 153, 0.28);
}

.result-badge-row {
  display: flex;
  flex-wrap: wrap;
  gap: 0.45rem;
}

.result-badge-row span,
.player-result-status span,
.player-result-status b {
  background: rgba(255, 255, 255, 0.06);
  border: 1px solid rgba(255, 255, 255, 0.1);
  border-radius: 999px;
  color: rgba(255, 245, 224, 0.78);
  font-size: 0.72rem;
  font-weight: 900;
  padding: 0.2rem 0.5rem;
}

.result-badge-row .victory,
.player-result-status .victory,
.player-result-status .alive {
  background: rgba(52, 211, 153, 0.1);
  border-color: rgba(52, 211, 153, 0.22);
  color: #bbf7d0;
}

.result-badge-row .defeat,
.player-result-status .defeat,
.player-result-status .dead {
  background: rgba(248, 113, 113, 0.1);
  border-color: rgba(248, 113, 113, 0.22);
  color: #fecaca;
}

.result-panel.winner-panel.mafia {
  border-color: rgba(248, 113, 113, 0.34);
}

.result-panel.winner-panel.citizen {
  border-color: rgba(96, 165, 250, 0.3);
}

.winner-list {
  display: grid;
  gap: 0.6rem;
  grid-template-columns: repeat(auto-fit, minmax(10rem, 1fr));
}

.winner-chip {
  background: rgba(255, 190, 85, 0.08);
  border: 1px solid rgba(255, 190, 85, 0.18);
  border-radius: 10px;
  display: grid;
  gap: 0.18rem;
  padding: 0.75rem;
}

.winner-chip strong {
  color: #fff1d6;
  font-size: 0.98rem;
  font-weight: 900;
}

.winner-chip span {
  color: rgba(255, 245, 224, 0.64);
  font-size: 0.8rem;
  font-weight: 800;
}

.result-summary-grid {
  display: grid;
  gap: 0.65rem;
  grid-template-columns: repeat(2, minmax(0, 1fr));
}

.result-summary-grid article {
  background: rgba(0, 0, 0, 0.22);
  border: 1px solid rgba(255, 255, 255, 0.06);
  border-radius: 10px;
  padding: 0.8rem;
}

.result-summary-grid strong {
  color: rgba(255, 190, 85, 0.82);
  display: block;
  font-size: 0.8rem;
  font-weight: 900;
  margin-bottom: 0.25rem;
}

.result-summary-grid p {
  color: rgba(255, 245, 224, 0.88);
  font-weight: 850;
  margin: 0;
}

.my-contribution-panel {
  border-color: rgba(52, 211, 153, 0.25);
}

.my-contribution-summary {
  background: rgba(16, 185, 129, 0.08);
  border: 1px solid rgba(52, 211, 153, 0.16);
  border-radius: 10px;
  display: grid;
  gap: 0.28rem;
  padding: 0.8rem;
}

.my-contribution-summary strong {
  color: #bbf7d0;
  font-size: 1rem;
  font-weight: 900;
}

.my-contribution-summary p {
  color: rgba(255, 245, 224, 0.72);
  font-size: 0.82rem;
  font-weight: 800;
  line-height: 1.45;
  margin: 0;
}

.my-contribution-list {
  color: rgba(255, 245, 224, 0.84);
  display: grid;
  gap: 0.42rem;
  margin: 0;
  padding-left: 1.1rem;
}

.my-contribution-list li::marker {
  color: #86efac;
}

.player-result-panel {
  max-height: 28rem;
  overflow: auto;
}

.player-result-list {
  display: grid;
  gap: 0.8rem;
  grid-template-columns: repeat(auto-fit, minmax(18rem, 1fr));
}

.player-result-card {
  background: rgba(0, 0, 0, 0.22);
  border: 1px solid rgba(255, 255, 255, 0.06);
  border-radius: 12px;
  display: grid;
  gap: 0.75rem;
  padding: 0.9rem;
}

.player-result-card.winner {
  border-color: rgba(52, 211, 153, 0.34);
  box-shadow: 0 0 0 1px rgba(255, 190, 85, 0.1);
}

.player-result-card.mafia {
  background: rgba(127, 29, 29, 0.14);
}

.player-result-card:not(.winner) {
  border-color: rgba(248, 113, 113, 0.2);
}

.player-result-header {
  align-items: start;
  display: flex;
  gap: 1rem;
  justify-content: space-between;
}

.player-result-header strong {
  color: #fff1d6;
  display: block;
  font-size: 1rem;
  font-weight: 900;
}

.player-result-header div:first-child span {
  color: rgba(255, 245, 224, 0.62);
  font-size: 0.78rem;
  font-weight: 800;
}

.player-result-status {
  display: grid;
  gap: 0.15rem;
  justify-items: end;
}

.player-log-list {
  color: rgba(255, 245, 224, 0.82);
  display: grid;
  gap: 0.35rem;
  margin: 0;
  padding-left: 1.1rem;
}

.player-log-empty {
  color: rgba(255, 245, 224, 0.55);
  margin: 0;
}

.survivors-card.voting .survivor-list {
  grid-template-columns: repeat(auto-fit, minmax(9.5rem, 1fr));
}

.chat-header .eyebrow {
  color: rgba(255, 190, 85, 0.72);
  display: block;
  font-size: 0.72rem;
  font-weight: 900;
  letter-spacing: 0.08em;
  text-transform: uppercase;
}

.chat-header h1 {
  display: none;
}

.chat-title {
  color: #fff1d6;
  font-size: clamp(1.55rem, 2.6vw, 2.25rem);
  font-weight: 900;
  letter-spacing: 0;
  line-height: 1;
  margin: 0.2rem 0 0;
}

.chat-status-badge {
  background: rgba(74, 222, 128, 0.12);
  border: 1px solid rgba(74, 222, 128, 0.28);
  border-radius: 999px;
  color: #86efac;
  flex-shrink: 0;
  font-size: 0.78rem;
  font-weight: 900;
  padding: 0.38rem 0.65rem;
}

.chat-status-badge.locked {
  background: rgba(148, 116, 84, 0.12);
  border-color: rgba(255, 255, 255, 0.08);
  color: rgba(255, 245, 224, 0.52);
}

.chat-phase-banner {
  background:
    linear-gradient(90deg, rgba(255, 190, 85, 0.08), rgba(127, 29, 29, 0.1)),
    rgba(0, 0, 0, 0.18);
  border-bottom: 1px solid rgba(255, 190, 85, 0.12);
  color: rgba(255, 226, 179, 0.84);
  flex-shrink: 0;
  font-size: 0.88rem;
  font-weight: 850;
  line-height: 1.45;
  padding: 0.72rem 1.25rem;
}

.chat-phase-banner.dead {
  background: rgba(88, 28, 135, 0.2);
  border-bottom-color: rgba(192, 132, 252, 0.22);
  color: #e9d5ff;
}

.chat-tabs {
  background: rgba(0, 0, 0, 0.2);
  border-bottom: 1px solid rgba(255, 190, 85, 0.1);
  display: flex;
  flex-shrink: 0;
  gap: 0.45rem;
  overflow-x: auto;
  padding: 0.62rem 1.25rem;
}

.chat-tab {
  background: rgba(255, 255, 255, 0.045);
  border: 1px solid rgba(255, 255, 255, 0.09);
  border-radius: 999px;
  color: rgba(255, 245, 224, 0.68);
  cursor: pointer;
  flex-shrink: 0;
  font: inherit;
  font-size: 0.74rem;
  font-weight: 900;
  padding: 0.34rem 0.62rem;
}

.chat-tab.active {
  background: rgba(255, 190, 85, 0.14);
  border-color: rgba(255, 190, 85, 0.38);
  color: #ffd28a;
}

.chat-tab.mafia.active {
  background: rgba(127, 29, 29, 0.32);
  border-color: rgba(248, 113, 113, 0.68);
  color: #fecaca;
}

.chat-tab.police.active {
  background: rgba(30, 64, 175, 0.3);
  border-color: rgba(96, 165, 250, 0.64);
  color: #dbeafe;
}

.chat-tab.dead.active {
  background: rgba(88, 28, 135, 0.28);
  border-color: rgba(192, 132, 252, 0.56);
  color: #e9d5ff;
}

.system-message-row {
  align-items: center;
  align-self: center;
  color: rgba(255, 210, 138, 0.82);
  display: flex;
  font-size: 0.8rem;
  font-weight: 900;
  gap: 0.7rem;
  justify-content: center;
  line-height: 1.4;
  margin: 0.25rem 0;
  max-width: 84%;
  text-align: center;
  width: 100%;
}

.system-message-row::before,
.system-message-row::after {
  background: rgba(255, 190, 85, 0.16);
  content: '';
  flex: 1;
  height: 1px;
  min-width: 2rem;
}

.system-message-row span {
  background: rgba(255, 190, 85, 0.08);
  border: 1px solid rgba(255, 190, 85, 0.14);
  border-radius: 999px;
  padding: 0.35rem 0.7rem;
}

.chat-message-row {
  display: flex;
  width: 100%;
}

.chat-message-row.other {
  justify-content: flex-start;
}

.chat-message-row.mine {
  justify-content: flex-end;
}

.chat-bubble {
  background: rgba(0, 0, 0, 0.24);
  border: 1px solid rgba(255, 255, 255, 0.065);
  border-radius: 12px;
  max-width: min(74%, 48rem);
  min-width: 7.5rem;
  padding: 0.78rem 0.9rem;
  white-space: pre-wrap;
  word-break: break-word;
}

.chat-message-row.mine .chat-bubble {
  background:
    linear-gradient(180deg, rgba(255, 190, 85, 0.15), rgba(96, 42, 18, 0.22)),
    rgba(0, 0, 0, 0.25);
  border-color: rgba(255, 190, 85, 0.22);
}

.chat-bubble.channel-mafia {
  background: rgba(127, 29, 29, 0.26);
  border-color: rgba(248, 113, 113, 0.56);
}

.chat-bubble.channel-police {
  background: rgba(30, 64, 175, 0.24);
  border-color: rgba(96, 165, 250, 0.52);
}

.chat-bubble.channel-dead {
  background: rgba(88, 28, 135, 0.22);
  border-color: rgba(192, 132, 252, 0.48);
}

.chat-meta {
  align-items: center;
  display: flex;
  gap: 0.65rem;
  justify-content: space-between;
}

.chat-meta strong {
  color: #ffd28a;
  font-size: 0.82rem;
  font-weight: 900;
}

.chat-channel-chip {
  border: 1px solid rgba(255, 190, 85, 0.22);
  border-radius: 999px;
  color: rgba(255, 210, 138, 0.86);
  font-size: 0.66rem;
  font-weight: 900;
  letter-spacing: 0.04em;
  padding: 0.12rem 0.42rem;
}

.chat-channel-chip.dead {
  background: rgba(88, 28, 135, 0.35);
  border-color: rgba(192, 132, 252, 0.52);
  color: #e9d5ff;
}

.chat-meta time {
  color: rgba(255, 245, 224, 0.42);
  font-size: 0.72rem;
  font-weight: 800;
}

.chat-bubble p {
  color: rgba(255, 245, 224, 0.86);
  font-size: 0.98rem;
  font-weight: 750;
  line-height: 1.55;
  margin: 0.28rem 0 0;
}

.chat-input-area {
  align-items: center;
  border-top: 1px solid rgba(255, 190, 85, 0.11);
  display: grid;
  flex-shrink: 0;
  gap: 0.7rem;
  grid-template-columns: minmax(0, 1fr) auto;
  padding: 0.95rem 1.25rem 1.1rem;
}

.chat-input-area input {
  background: rgba(0, 0, 0, 0.34);
  border: 1px solid rgba(255, 190, 85, 0.14);
  border-radius: 10px;
  color: #fff1d6;
  font: inherit;
  font-weight: 800;
  min-height: 48px;
  min-width: 0;
  outline: none;
  padding: 0.82rem 0.9rem;
}

.chat-input-area input:focus {
  border-color: rgba(255, 190, 85, 0.42);
  box-shadow: 0 0 0 3px rgba(255, 190, 85, 0.08);
}

.chat-input-area input:disabled {
  cursor: not-allowed;
  opacity: 0.48;
}

.chat-input-area button {
  background: linear-gradient(180deg, #ffbe55, #b86b1b);
  border: 0;
  border-radius: 8px;
  color: #231107;
  cursor: pointer;
  font: inherit;
  font-weight: 900;
  min-height: 48px;
  min-width: 5.75rem;
  padding: 0.68rem 0.95rem;
  white-space: nowrap;
}

.confirm-backdrop {
  align-items: center;
  background: rgba(0, 0, 0, 0.56);
  display: flex;
  inset: 0;
  justify-content: center;
  padding: 1rem;
  position: fixed;
  z-index: 40;
}

.confirm-modal {
  background: rgba(20, 12, 10, 0.98);
  border: 1px solid rgba(255, 190, 85, 0.22);
  border-radius: 16px;
  box-shadow: 0 24px 70px rgba(0, 0, 0, 0.45);
  color: #fff1d6;
  max-width: 26rem;
  padding: 1.2rem;
  width: 100%;
}

.confirm-modal h2 {
  font-size: 1.25rem;
  margin: 0;
}

.confirm-modal p {
  color: rgba(255, 245, 224, 0.7);
  font-weight: 750;
  line-height: 1.55;
  margin: 0.7rem 0 1rem;
}

.confirm-modal div {
  display: flex;
  gap: 0.6rem;
  justify-content: flex-end;
}

.confirm-modal .ghost-button {
  background: rgba(255, 255, 255, 0.08);
  color: rgba(255, 245, 224, 0.82);
  padding: 0.68rem 0.95rem;
}

@media (max-width: 980px) {
  .game-layout {
    grid-template-columns: 1fr;
  }

  .game-over-grid {
    grid-template-columns: 1fr;
  }

  .result-primary-grid {
    grid-template-columns: 1fr;
  }

  .chat-panel,
  .chat-area,
  .survivors-card-main,
  .game-info-panel {
    grid-column: auto;
    grid-row: auto;
  }

  .chat-area.dead {
    grid-template-columns: 1fr;
  }

  .game-info-panel {
    grid-template-columns: repeat(2, minmax(0, 1fr));
  }
}

@media (max-width: 640px) {
  .game-play-view {
    min-height: auto;
  }

  .game-status-bar,
  .status-actions {
    align-items: stretch;
    flex-direction: column;
  }

  .status-actions button {
    width: 100%;
  }

  .chat-panel {
    height: min(38rem, calc(100vh - 8rem));
  }

  .chat-message {
    max-width: 100%;
  }

  .system-message {
    gap: 0.45rem;
  }

  .chat-input-row,
  .chat-input-area {
    grid-template-columns: 1fr;
  }

  .game-info-panel {
    grid-template-columns: 1fr;
  }

  .player-memo-options {
    grid-template-columns: repeat(2, minmax(0, 1fr));
  }
}
</style>
