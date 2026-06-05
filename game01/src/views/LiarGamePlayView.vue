<script setup>
import { computed, nextTick, onBeforeUnmount, onMounted, ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { useAuthStore } from '@/stores/auth'
import { useToastStore } from '@/stores/toast'
import {
  ROOM_PRESENCE_TIMEOUTS,
  getRoom,
  heartbeatRoomPresence,
  prepareRoomDepartureSignal,
  signalRoomDeparture,
  subscribeToRoom,
} from '@/api/roomApi'
import {
  getGameMessages,
  sendGameMessage,
  subscribeToGameMessages,
} from '@/api/chatApi'
import { setCurrentUserPresence } from '@/api/presenceApi'
import {
  advanceLiarPhase,
  getMyLiarState,
  leaveLiarMatch,
  reconcileLiarMatch,
  resolveLiarVote,
  returnLiarRoomToLobby,
  submitLiarGuess,
  submitLiarStatement,
  submitLiarVote,
  subscribeToLiarMatch,
  timeoutLiarStatement,
} from '@/api/liarGameApi'

const route = useRoute()
const router = useRouter()
const authStore = useAuthStore()
const toastStore = useToastStore()
const roomId = computed(() => String(route.params.roomId || ''))
const savedUser = computed(() => authStore.user)

const room = ref(null)
const match = ref(null)
const myState = ref(null)
const messages = ref([])
const chatDraft = ref('')
const guessDraft = ref('')
const statementDraft = ref('')
const isLoading = ref(true)
const isWorking = ref(false)
const nowTick = ref(Date.now())
const chatListRef = ref(null)

let unsubscribeRoom = null
let unsubscribeMatch = null
let unsubscribeMessages = null
let pollTimer = null
let heartbeatTimer = null
let syncTimer = null
let countdownTimer = null
let subscribedGameId = null
let statementTimeoutPromise = null
let resumeSyncPromise = null
let reconcilePromise = null
let intentionalDeparture = false

const phase = computed(() => match.value?.round?.phase || '')
const scoreboard = computed(() => match.value?.scoreboard || [])
const statements = computed(() => match.value?.statements || [])
const voteStatus = computed(() => match.value?.voteStatus || { votes: [], candidateUserIds: [] })
const currentVotes = computed(() => voteStatus.value.votes || [])
const currentPlayer = computed(() =>
  room.value?.players?.find((player) => player.userId === savedUser.value?.id),
)
const isHost = computed(() => currentPlayer.value?.isHost === true)
const connectedPlayerCount = computed(
  () => room.value?.players?.filter((player) => player.isConnected).length || 0,
)
const myVote = computed(() =>
  currentVotes.value.find((vote) => vote.voterId === savedUser.value?.id),
)
const candidateIds = computed(() => new Set(voteStatus.value.candidateUserIds || []))
const voteCandidates = computed(() =>
  scoreboard.value.filter(
    (player) =>
      player.userId !== savedUser.value?.id &&
      (phase.value !== 'revote' || candidateIds.value.has(player.userId)),
  ),
)
const canChat = computed(() => phase.value === 'discussion')
const isVoting = computed(() => ['voting', 'revote'].includes(phase.value))
const isCurrentLiar = computed(() => myState.value?.role === 'liar')
const isMyStatementTurn = computed(
  () =>
    phase.value === 'statement' &&
    match.value?.round?.currentStatementUserId === savedUser.value?.id,
)
const statementRemainingSeconds = computed(() => {
  const endsAt = match.value?.round?.phaseEndsAt
  if (phase.value !== 'statement' || !endsAt) return 0
  return Math.max(0, Math.ceil((new Date(endsAt).getTime() - nowTick.value) / 1000))
})
const roundResult = computed(() => match.value?.roundResult || null)
const winnerNames = computed(() => {
  const winnerIds = new Set(match.value?.winnerUserIds || [])
  return scoreboard.value.filter((player) => winnerIds.has(player.userId)).map((player) => player.nickname)
})
const phaseLabel = computed(() => {
  const labels = {
    word_reveal: '역할 및 제시어 확인',
    statement: '순서별 한마디 설명',
    discussion: '설명과 토론',
    voting: '라이어 투표',
    revote: '동률 재투표',
    liar_guess: '라이어 최종 추측',
    round_result: '라운드 결과',
    match_result: '최종 결과',
  }
  return labels[phase.value] || '라이어 게임'
})
const hostAdvanceLabel = computed(() => {
  if (phase.value === 'word_reveal') return '한마디 설명 시작'
  if (phase.value === 'discussion') return '투표 시작'
  if (phase.value === 'voting' || phase.value === 'revote') return '투표 결과 확정'
  if (phase.value === 'round_result') {
    return match.value?.matchStatus === 'finished' ? '최종 결과 보기' : '다음 라운드'
  }
  return ''
})
const groupedVotes = computed(() => {
  const groups = new Map()

  currentVotes.value.forEach((vote) => {
    const current = groups.get(vote.targetId) || {
      targetId: vote.targetId,
      targetName: vote.targetName,
      voterNames: [],
    }
    current.voterNames.push(vote.voterName)
    groups.set(vote.targetId, current)
  })

  return [...groups.values()].sort((a, b) => b.voterNames.length - a.voterNames.length)
})
const waitingVoterNames = computed(() => {
  const voters = new Set(currentVotes.value.map((vote) => vote.voterId))
  return scoreboard.value.filter((player) => !voters.has(player.userId)).map((player) => player.nickname)
})

function getRoundReasonLabel(reason) {
  const labels = {
    wrong_player_voted: '일반 유저가 지목되어 라이어가 살아남았습니다.',
    liar_guessed_word: '라이어가 제시어를 맞혔습니다.',
    liar_failed_guess: '라이어가 제시어 추측에 실패했습니다.',
    revote_tied: '재투표에서도 동률이 발생하여 라운드가 무효 처리되었습니다.',
    player_left: '참가자가 게임에서 나가 라이어게임이 종료되었습니다.',
  }
  return labels[reason] || '라운드 결과가 확정되었습니다.'
}

function scheduleSync() {
  if (syncTimer) clearTimeout(syncTimer)
  syncTimer = setTimeout(syncState, 100)
}

function scrollChatToBottom() {
  const el = chatListRef.value
  if (!el) return
  el.scrollTop = el.scrollHeight
}

async function ensureSubscriptions(gameId) {
  if (!gameId || subscribedGameId === gameId) return

  unsubscribeMatch?.()
  unsubscribeMessages?.()
  unsubscribeMatch = null
  unsubscribeMessages = null
  subscribedGameId = gameId
  unsubscribeMatch = subscribeToLiarMatch(gameId, scheduleSync)
  unsubscribeMessages = subscribeToGameMessages(roomId.value, gameId, (payload) => {
    if (payload?.new) {
      messages.value = [...messages.value, {
        id: payload.new.id,
        roomId: payload.new.room_id,
        gameId: payload.new.game_id,
        roundNo: payload.new.round_no,
        userId: payload.new.user_id,
        nickname: payload.new.nickname || 'System',
        content: payload.new.content || '',
        createdAt: new Date(payload.new.created_at).toLocaleTimeString('ko-KR', {
          hour: '2-digit',
          minute: '2-digit',
        }),
        isSystem: payload.new.is_system === true,
        messageType: payload.new.message_type || 'chat',
        channelType: payload.new.channel_type || 'public',
        eventKey: payload.new.event_key || null,
      }].slice(-160)
      nextTick(scrollChatToBottom)
    }
  })
  messages.value = await getGameMessages(roomId.value, gameId, { limit: 160 })
  nextTick(scrollChatToBottom)
}

function resetMatchSubscriptions() {
  unsubscribeMatch?.()
  unsubscribeMessages?.()
  unsubscribeMatch = null
  unsubscribeMessages = null
  subscribedGameId = null
}

function resetRoomSubscription() {
  unsubscribeRoom?.()
  unsubscribeRoom = subscribeToRoom(roomId.value, scheduleSync)
}

async function syncState() {
  try {
    await sendHeartbeat()
    const nextRoom = await getRoom(roomId.value)
    room.value = nextRoom

    if (nextRoom.status === 'waiting') {
      await router.replace(`/rooms/${roomId.value}`)
      return
    }

    if (!reconcilePromise) {
      reconcilePromise = reconcileLiarMatch(roomId.value).finally(() => {
        reconcilePromise = null
      })
    }

    const nextMatch = await reconcilePromise
    match.value = nextMatch

    if (nextMatch?.gameId) {
      await ensureSubscriptions(nextMatch.gameId)
      myState.value = await getMyLiarState(roomId.value)
    }

    await setCurrentUserPresence({
      userId: savedUser.value?.id,
      nickname: savedUser.value?.nickname,
      status: 'playing',
      roomId: roomId.value,
      canReceiveWhisper: false,
    })
  } catch (error) {
    toastStore.error(error.message)
  } finally {
    isLoading.value = false
  }
}

async function sendHeartbeat() {
  try {
    await heartbeatRoomPresence(roomId.value)
  } catch (error) {
    console.warn('[LiarGame] heartbeat failed', error)
  }
}

async function handlePageResume() {
  if (document.visibilityState && document.visibilityState !== 'visible') return
  if (resumeSyncPromise) return resumeSyncPromise

  resumeSyncPromise = (async () => {
    nowTick.value = Date.now()
    resetRoomSubscription()
    resetMatchSubscriptions()
    await prepareRoomDepartureSignal()
    await sendHeartbeat()
    await syncState()
  })()

  try {
    await resumeSyncPromise
  } finally {
    resumeSyncPromise = null
  }
}

async function sendChat() {
  const content = chatDraft.value.trim()
  if (!canChat.value || !content || !match.value?.gameId || !savedUser.value) return

  try {
    await sendGameMessage({
      roomId: roomId.value,
      gameId: match.value.gameId,
      userId: savedUser.value.id,
      nickname: savedUser.value.nickname,
      content,
    })
    chatDraft.value = ''
  } catch (error) {
    toastStore.error(error.message)
  }
}

async function voteFor(targetUserId) {
  if (!isVoting.value || myVote.value || isWorking.value) return
  isWorking.value = true

  try {
    match.value = await submitLiarVote(roomId.value, targetUserId)
    await syncState()
  } catch (error) {
    toastStore.error(error.message)
  } finally {
    isWorking.value = false
  }
}

async function submitGuess() {
  if (!guessDraft.value.trim() || !isCurrentLiar.value || isWorking.value) return
  isWorking.value = true

  try {
    match.value = await submitLiarGuess(roomId.value, guessDraft.value)
    guessDraft.value = ''
    await syncState()
  } catch (error) {
    toastStore.error(error.message)
  } finally {
    isWorking.value = false
  }
}

async function submitStatement() {
  if (!isMyStatementTurn.value || !statementDraft.value.trim() || isWorking.value) return
  isWorking.value = true

  try {
    match.value = await submitLiarStatement(roomId.value, statementDraft.value)
    statementDraft.value = ''
    await syncState()
  } catch (error) {
    const message = error?.message || ''
    if (
      message.includes('participant required') ||
      message.includes('Room not found') ||
      message.includes('방 정보를 불러오지 못했습니다')
    ) {
      await router.replace('/home')
      return
    }
    toastStore.error(error.message)
  } finally {
    isWorking.value = false
  }
}

async function processStatementTimeout() {
  if (
    phase.value !== 'statement' ||
    statementRemainingSeconds.value > 0 ||
    statementTimeoutPromise
  ) {
    return
  }

  statementTimeoutPromise = timeoutLiarStatement(roomId.value)

  try {
    match.value = await statementTimeoutPromise
    await syncState()
  } catch (error) {
    console.warn('[LiarGame] statement timeout failed', error)
  } finally {
    statementTimeoutPromise = null
  }
}

async function advancePhase() {
  if (!isHost.value || isWorking.value) return
  isWorking.value = true

  try {
    if (phase.value === 'voting' || phase.value === 'revote') {
      match.value = await resolveLiarVote(roomId.value)
    } else {
      match.value = await advanceLiarPhase(roomId.value)
    }
    await syncState()
  } catch (error) {
    toastStore.error(error.message)
  } finally {
    isWorking.value = false
  }
}

async function returnToLobby() {
  if (isWorking.value) return
  isWorking.value = true

  try {
    intentionalDeparture = true
    await returnLiarRoomToLobby(roomId.value)
    await router.push(`/rooms/${roomId.value}`)
  } catch (error) {
    intentionalDeparture = false
    toastStore.error(error.message)
  } finally {
    isWorking.value = false
  }
}

async function leaveGame() {
  if (isWorking.value) return
  isWorking.value = true

  try {
    intentionalDeparture = true
    await leaveLiarMatch(roomId.value)
    await router.push('/home')
  } catch (error) {
    intentionalDeparture = false
    toastStore.error(error.message)
  } finally {
    isWorking.value = false
  }
}

function handlePageDeparture() {
  if (intentionalDeparture) return
  signalRoomDeparture(roomId.value)
}

onMounted(async () => {
  await prepareRoomDepartureSignal()
  resetRoomSubscription()
  pollTimer = setInterval(syncState, 2500)
  heartbeatTimer = setInterval(sendHeartbeat, ROOM_PRESENCE_TIMEOUTS.heartbeatIntervalMs)
  countdownTimer = setInterval(() => {
    nowTick.value = Date.now()
    processStatementTimeout()
  }, 500)
  await syncState()
  await sendHeartbeat()
  document.addEventListener('visibilitychange', handlePageResume)
  window.addEventListener('focus', handlePageResume)
  window.addEventListener('online', handlePageResume)
  window.addEventListener('pageshow', handlePageResume)
  window.addEventListener('pagehide', handlePageDeparture)
  window.addEventListener('beforeunload', handlePageDeparture)
})

onBeforeUnmount(() => {
  unsubscribeRoom?.()
  resetMatchSubscriptions()
  if (pollTimer) clearInterval(pollTimer)
  if (heartbeatTimer) clearInterval(heartbeatTimer)
  if (countdownTimer) clearInterval(countdownTimer)
  if (syncTimer) clearTimeout(syncTimer)
  document.removeEventListener('visibilitychange', handlePageResume)
  window.removeEventListener('focus', handlePageResume)
  window.removeEventListener('online', handlePageResume)
  window.removeEventListener('pageshow', handlePageResume)
  window.removeEventListener('pagehide', handlePageDeparture)
  window.removeEventListener('beforeunload', handlePageDeparture)
})
</script>

<template>
  <section class="liar-game page-card">
    <div class="game-veil" aria-hidden="true"></div>
    <p v-if="isLoading" class="empty-state">라이어 게임 상태를 불러오는 중입니다.</p>

    <template v-else-if="match">
      <header class="match-header">
        <div>
          <p class="eyebrow">LIAR GAME · ROUND {{ match.currentRoundNo }}</p>
          <h1>{{ phaseLabel }}</h1>
        </div>
        <div class="match-actions">
          <span class="score-goal">참가 {{ connectedPlayerCount }}명 · 목표 {{ match.targetScore }}점</span>
          <button type="button" class="leave-game-button" :disabled="isWorking" @click="leaveGame">
            게임 나가기
          </button>
        </div>
      </header>

      <div class="game-layout">
        <aside class="side-column">
          <section class="panel role-card">
            <span class="section-kicker">내 역할</span>
            <strong :class="myState?.role">{{ myState?.role === 'liar' ? '라이어' : '일반 유저' }}</strong>
            <p>테마: {{ myState?.categoryLabel || match.round?.categoryLabel }}</p>
            <p v-if="myState?.word">제시어: <b>{{ myState.word }}</b></p>
            <p v-else>다른 참가자의 설명을 보고 제시어를 추리하세요.</p>
          </section>

          <section class="panel">
            <span class="section-kicker">점수판</span>
            <ol class="score-list">
              <li v-for="player in scoreboard" :key="player.userId">
                <span>{{ player.nickname }}</span>
                <strong>{{ player.score }} / {{ match.targetScore }}</strong>
              </li>
            </ol>
          </section>
        </aside>

        <main class="main-column">
          <section v-if="phase === 'word_reveal'" class="panel hero-panel">
            <h2>역할과 제시어를 확인하세요</h2>
            <p>모든 참가자가 확인하면 방장이 순서별 한마디 설명을 시작합니다.</p>
          </section>

          <section v-else-if="phase === 'statement'" class="panel hero-panel statement-panel">
            <div class="statement-turn-heading">
              <div>
                <span class="section-kicker">현재 설명 차례</span>
                <h2>{{ match.round?.currentStatementNickname }}님</h2>
              </div>
              <strong>{{ statementRemainingSeconds }}초</strong>
            </div>
            <p v-if="isMyStatementTurn">
              제시어를 직접 말하지 않고 특징을 한마디로 설명하세요.
            </p>
            <p v-else>
              다른 참가자는 설명이 끝날 때까지 기다려주세요.
            </p>
            <form class="statement-form" @submit.prevent="submitStatement">
              <input
                v-model="statementDraft"
                type="text"
                maxlength="100"
                :disabled="!isMyStatementTurn || isWorking"
                :placeholder="isMyStatementTurn ? '100자 이하로 한마디 설명을 입력하세요' : '현재 발언자만 입력할 수 있습니다'"
              />
              <button type="submit" :disabled="!isMyStatementTurn || isWorking || !statementDraft.trim()">
                설명 제출
              </button>
            </form>
          </section>

          <section v-else-if="phase === 'discussion'" class="panel hero-panel">
            <h2>설명과 토론</h2>
            <p>제시어를 직접 말하지 않으면서 자신이 알고 있다는 것을 보여주세요.</p>
          </section>

          <section v-else-if="isVoting" class="panel hero-panel">
            <h2>{{ phase === 'revote' ? '동률 발생! 후보자 중 다시 투표하세요.' : '라이어를 지목하세요.' }}</h2>
            <div class="candidate-grid">
              <button
                v-for="candidate in voteCandidates"
                :key="candidate.userId"
                type="button"
                :disabled="!!myVote || isWorking"
                :class="{ selected: myVote?.targetId === candidate.userId }"
                @click="voteFor(candidate.userId)"
              >
                {{ candidate.nickname }}
              </button>
            </div>
            <p>{{ myVote ? '투표를 제출했습니다. 다른 참가자의 선택을 기다립니다.' : '투표 후에는 변경할 수 없습니다.' }}</p>
          </section>

          <section v-else-if="phase === 'liar_guess'" class="panel hero-panel">
            <template v-if="isCurrentLiar">
              <h2>라이어로 지목되었습니다</h2>
              <p>제시어를 한 번만 추측할 수 있습니다.</p>
              <form class="guess-form" @submit.prevent="submitGuess">
                <input v-model="guessDraft" type="text" maxlength="80" placeholder="제시어를 입력하세요" />
                <button type="submit" :disabled="isWorking || !guessDraft.trim()">추측 제출</button>
              </form>
            </template>
            <template v-else>
              <h2>라이어가 제시어를 추측하고 있습니다</h2>
              <p>최종 답안을 기다려 주세요.</p>
            </template>
          </section>

          <section v-else-if="phase === 'round_result' && roundResult" class="panel hero-panel result-panel">
            <h2>{{ roundResult.winnerSide === 'invalid' ? '라운드 무효' : `${roundResult.winnerSide === 'liar' ? '라이어' : '일반 유저'} 승리` }}</h2>
            <p>{{ getRoundReasonLabel(roundResult.endReason) }}</p>
            <dl>
              <div><dt>라이어</dt><dd>{{ roundResult.liarNickname }}</dd></div>
              <div><dt>제시어</dt><dd>{{ roundResult.categoryLabel }} · {{ roundResult.word }}</dd></div>
              <div v-if="roundResult.guessText"><dt>추측</dt><dd>{{ roundResult.guessText }}</dd></div>
            </dl>
          </section>

          <section v-else-if="phase === 'match_result'" class="panel hero-panel result-panel">
            <h2>매치 종료</h2>
            <p>{{ winnerNames.join(', ') }}님이 목표 점수에 도달했습니다.</p>
            <button type="button" class="primary" :disabled="isWorking" @click="returnToLobby">대기방으로 돌아가기</button>
          </section>

          <section class="panel chat-panel">
            <div class="panel-heading">
              <div>
                <span class="eyebrow">LIVE DISCUSSION</span>
                <h2>게임 채팅</h2>
              </div>
              <span class="chat-status-badge" :class="{ locked: !canChat }">
                {{ canChat ? '채팅 가능' : '채팅 잠김' }}
              </span>
            </div>
            <ul ref="chatListRef" class="chat-list">
              <li v-for="message in messages" :key="message.id" :class="{ system: message.isSystem }">
                <template v-if="message.isSystem">
                  <span>{{ message.content }}</span>
                </template>
                <template v-else>
                  <div class="chat-meta">
                    <strong>{{ message.nickname }}</strong>
                    <small>R{{ message.roundNo || '-' }} · {{ message.createdAt }}</small>
                  </div>
                  <p>{{ message.content }}</p>
                </template>
              </li>
            </ul>
            <form @submit.prevent="sendChat">
              <input v-model="chatDraft" type="text" maxlength="240" :disabled="!canChat" placeholder="토론 메시지를 입력하세요" />
              <button type="submit" :disabled="!canChat || !chatDraft.trim()">전송</button>
            </form>
          </section>
        </main>

        <aside class="side-column">
          <section class="panel statement-list-panel">
            <span class="section-kicker">한마디 설명 목록</span>
            <p v-if="!statements.length">설명 단계가 시작되면 순서가 공개됩니다.</p>
            <ol v-else class="statement-list">
              <li
                v-for="statement in statements"
                :key="statement.id"
                :class="{
                  active: phase === 'statement' && match.round?.currentStatementUserId === statement.userId,
                  timeout: statement.isTimeout,
                }"
              >
                <div>
                  <b>{{ statement.turnOrder }}</b>
                  <strong>{{ statement.nickname }}</strong>
                </div>
                <p>{{ statement.statementText || '차례 대기 중' }}</p>
              </li>
            </ol>
          </section>

          <section class="panel">
            <span class="section-kicker">투표 현황</span>
            <p v-if="!isVoting && !currentVotes.length">투표 단계가 시작되면 공개됩니다.</p>
            <ul v-else class="vote-list">
              <li v-for="group in groupedVotes" :key="group.targetId">
                <strong>{{ group.targetName }} {{ group.voterNames.length }}표</strong>
                <span>{{ group.voterNames.join(', ') }}</span>
              </li>
              <li v-if="waitingVoterNames.length">
                <strong>대기 중</strong>
                <span>{{ waitingVoterNames.join(', ') }}</span>
              </li>
            </ul>
          </section>

          <section v-if="isHost && hostAdvanceLabel" class="panel host-panel">
            <span class="section-kicker">방장 진행</span>
            <button type="button" class="primary" :disabled="isWorking" @click="advancePhase">
              {{ hostAdvanceLabel }}
            </button>
          </section>
        </aside>
      </div>
    </template>
  </section>
</template>

<style scoped>
.liar-game {
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

.empty-state,
.match-header,
.game-layout {
  position: relative;
  z-index: 1;
}

.empty-state {
  color: rgba(255, 245, 224, 0.72);
  font-weight: 900;
}

.eyebrow,
.hero-panel p,
.vote-list span,
.panel > p,
small {
  color: rgba(255, 245, 224, 0.62);
}

.eyebrow,
.section-kicker {
  color: rgba(255, 190, 85, 0.72);
  font-size: 0.72rem;
  font-weight: 900;
  letter-spacing: 0.08em;
  margin: 0;
  text-transform: uppercase;
}

h1,
h2,
p {
  margin: 0;
}

h2 {
  font-size: 1rem;
}

.match-header {
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

.match-header h1 {
  color: #fff1d6;
  font-size: clamp(1.35rem, 2.4vw, 2rem);
  line-height: 1.1;
  margin-top: 0.1rem;
  text-shadow: 0 0 24px rgba(255, 138, 0, 0.2);
}

.score-goal {
  background: rgba(255, 190, 85, 0.12);
  border: 1px solid rgba(255, 190, 85, 0.28);
  border-radius: 999px;
  color: #ffd591;
  font-weight: 900;
  padding: 0.5rem 0.8rem;
}

.match-actions {
  align-items: center;
  display: flex;
  flex-wrap: wrap;
  gap: 0.65rem;
  justify-content: flex-end;
}

.leave-game-button {
  background: rgba(239, 68, 68, 0.1);
  border-color: rgba(248, 113, 113, 0.28);
  color: #fecaca;
  min-height: 2.35rem;
  padding: 0.48rem 0.75rem;
}

.leave-game-button:hover:not(:disabled) {
  background: rgba(239, 68, 68, 0.18);
  border-color: rgba(248, 113, 113, 0.48);
}

.game-layout {
  display: grid;
  gap: clamp(0.9rem, 1.7vw, 1.25rem);
  grid-template-columns: minmax(11rem, 0.78fr) minmax(22rem, 1.7fr) minmax(12rem, 0.88fr);
}

.side-column,
.main-column,
.panel {
  display: grid;
  gap: 0.75rem;
  min-width: 0;
}

.side-column {
  align-content: start;
}

.panel {
  background:
    linear-gradient(180deg, rgba(255, 255, 255, 0.055), rgba(255, 255, 255, 0.022)),
    rgba(14, 10, 8, 0.76);
  border: 1px solid rgba(255, 190, 85, 0.16);
  border-radius: 16px;
  box-shadow:
    0 24px 60px rgba(0, 0, 0, 0.3),
    inset 0 0 34px rgba(255, 138, 0, 0.04);
  padding: 1rem;
}

.role-card strong {
  color: #86efac;
  font-size: 1.45rem;
}

.role-card strong.liar {
  color: #fca5a5;
}

.score-list,
.vote-list,
.chat-list {
  display: grid;
  gap: 0.5rem;
  list-style: none;
  margin: 0;
  padding: 0;
}

.score-list li,
.vote-list li {
  align-items: center;
  background: rgba(0, 0, 0, 0.2);
  border: 1px solid rgba(255, 255, 255, 0.06);
  border-radius: 8px;
  display: flex;
  gap: 0.45rem;
  justify-content: space-between;
  padding: 0.62rem;
}

.score-list strong,
.vote-list strong {
  color: #fff1d6;
}

.vote-list li {
  align-items: flex-start;
  flex-direction: column;
}

.hero-panel {
  background:
    linear-gradient(90deg, rgba(255, 190, 85, 0.08), rgba(127, 29, 29, 0.1)),
    rgba(14, 10, 8, 0.8);
  min-height: 8.5rem;
}

.hero-panel h2 {
  color: #fff1d6;
  font-size: 1.25rem;
}

.candidate-grid {
  display: grid;
  gap: 0.55rem;
  grid-template-columns: repeat(auto-fit, minmax(8rem, 1fr));
}

button,
input {
  background: rgba(0, 0, 0, 0.34);
  border: 1px solid rgba(255, 190, 85, 0.16);
  border-radius: 8px;
  color: #fff1d6;
  font: inherit;
  padding: 0.7rem 0.78rem;
}

button {
  cursor: pointer;
  font-weight: 900;
}

button.primary,
.guess-form button,
.statement-form button {
  background: linear-gradient(180deg, #ffbe55, #b86b1b);
  border: 0;
  color: #231107;
}

button.selected {
  background: rgba(255, 190, 85, 0.14);
  border-color: rgba(255, 190, 85, 0.7);
  box-shadow: 0 0 0 3px rgba(255, 190, 85, 0.1);
  color: #ffd591;
}

button:disabled,
input:disabled {
  cursor: not-allowed;
  opacity: 0.52;
}

.guess-form,
.statement-form,
.chat-panel form {
  display: grid;
  gap: 0.5rem;
  grid-template-columns: minmax(0, 1fr) auto;
}

.result-panel dl {
  display: grid;
  gap: 0.5rem;
  margin: 0;
}

.result-panel dl div {
  display: flex;
  gap: 0.5rem;
}

.result-panel dd {
  color: #fff1d6;
  font-weight: 900;
  margin: 0;
}

.statement-turn-heading {
  align-items: center;
  display: flex;
  gap: 0.8rem;
  justify-content: space-between;
}

.statement-turn-heading strong {
  background: rgba(255, 190, 85, 0.12);
  border: 1px solid rgba(255, 190, 85, 0.3);
  border-radius: 999px;
  color: #ffd591;
  font-size: 1rem;
  padding: 0.42rem 0.68rem;
}

.statement-list {
  display: grid;
  gap: 0.5rem;
  list-style: none;
  margin: 0;
  padding: 0;
}

.statement-list li {
  background: rgba(0, 0, 0, 0.2);
  border: 1px solid rgba(255, 255, 255, 0.06);
  border-radius: 8px;
  display: grid;
  gap: 0.35rem;
  padding: 0.62rem;
}

.statement-list li.active {
  border-color: rgba(255, 190, 85, 0.56);
  box-shadow: 0 0 0 2px rgba(255, 190, 85, 0.08);
}

.statement-list li.timeout p {
  color: #fca5a5;
}

.statement-list div {
  align-items: center;
  display: flex;
  gap: 0.45rem;
}

.statement-list b {
  align-items: center;
  background: rgba(255, 190, 85, 0.12);
  border-radius: 50%;
  color: #ffd591;
  display: inline-flex;
  font-size: 0.7rem;
  height: 1.35rem;
  justify-content: center;
  width: 1.35rem;
}

.statement-list strong {
  color: #fff1d6;
  font-size: 0.88rem;
}

.statement-list p {
  color: rgba(255, 245, 224, 0.68);
  font-size: 0.82rem;
  line-height: 1.45;
}

.panel-heading {
  align-items: center;
  border-bottom: 1px solid rgba(255, 190, 85, 0.11);
  display: flex;
  gap: 0.75rem;
  justify-content: space-between;
  margin: -1rem -1rem 0;
  padding: 1rem;
}

.panel-heading h2 {
  color: #fff1d6;
  font-size: 1.45rem;
  margin-top: 0.2rem;
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

.chat-panel {
  container-type: inline-size;
  overflow: hidden;
}

.chat-list {
  align-content: start;
  max-height: 23rem;
  min-height: 16rem;
  overflow-y: auto;
  padding: 0.15rem;
  scrollbar-color: rgba(255, 190, 85, 0.36) rgba(0, 0, 0, 0.18);
}

.chat-list li {
  background: rgba(0, 0, 0, 0.24);
  border: 1px solid rgba(255, 255, 255, 0.065);
  border-radius: 12px;
  display: grid;
  gap: 0.28rem;
  min-height: 0;
  max-width: 82%;
  padding: 0.72rem 0.82rem;
  overflow-wrap: anywhere;
  word-break: break-word;
}

.chat-list li.system {
  background: rgba(255, 190, 85, 0.08);
  border-color: rgba(255, 190, 85, 0.14);
  border-radius: 14px;
  color: rgba(255, 210, 138, 0.82);
  justify-self: center;
  line-height: 1.45;
  max-width: min(92%, 34rem);
  padding: 0.48rem 0.72rem;
  text-align: center;
  width: fit-content;
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
}

.chat-list p {
  color: rgba(255, 245, 224, 0.86);
  line-height: 1.5;
}

.chat-panel form {
  border-top: 1px solid rgba(255, 190, 85, 0.11);
  margin: 0 -1rem -1rem;
  padding: 0.9rem 1rem 1rem;
}

.chat-panel form input {
  min-width: 0;
  width: 100%;
}

.chat-panel form button {
  background: linear-gradient(180deg, #ffbe55, #b86b1b);
  border: 0;
  color: #231107;
  font-weight: 900;
}

.liar-game {
  --liar-accent: #a78bfa;
  --liar-accent-strong: #c4b5fd;
  --liar-accent-deep: #7c3aed;
  --liar-accent-rgb: 196, 181, 253;
  --liar-glow-rgb: 167, 139, 250;
  --liar-text: #f5f3ff;
  --liar-text-rgb: 237, 233, 254;
  background:
    radial-gradient(circle at 50% -12%, rgba(var(--liar-accent-rgb), 0.18), transparent 34%),
    radial-gradient(circle at 13% 18%, rgba(76, 29, 149, 0.22), transparent 31%),
    linear-gradient(180deg, rgba(28, 20, 48, 0.98), rgba(10, 7, 19, 0.99));
  border-color: rgba(var(--liar-accent-rgb), 0.22);
}

.liar-game .game-veil {
  background:
    linear-gradient(90deg, transparent, rgba(var(--liar-accent-rgb), 0.08), transparent),
    radial-gradient(circle at 78% 18%, rgba(var(--liar-glow-rgb), 0.11), transparent 28%);
}

.liar-game .empty-state,
.liar-game .eyebrow,
.liar-game .hero-panel p,
.liar-game .vote-list span,
.liar-game .panel > p,
.liar-game small,
.liar-game .statement-list p,
.liar-game .chat-list p {
  color: rgba(var(--liar-text-rgb), 0.72);
}

.liar-game .eyebrow,
.liar-game .section-kicker {
  color: rgba(var(--liar-accent-rgb), 0.82);
}

.liar-game .match-header,
.liar-game .panel {
  border-color: rgba(var(--liar-accent-rgb), 0.18);
}

.liar-game .match-header {
  background: rgba(10, 7, 19, 0.58);
}

.liar-game .panel {
  background:
    linear-gradient(180deg, rgba(255, 255, 255, 0.045), rgba(255, 255, 255, 0.018)),
    rgba(12, 8, 24, 0.82);
  box-shadow:
    0 24px 60px rgba(0, 0, 0, 0.3),
    inset 0 0 34px rgba(var(--liar-glow-rgb), 0.05);
}

.liar-game .match-header h1,
.liar-game .score-list strong,
.liar-game .vote-list strong,
.liar-game .hero-panel h2,
.liar-game .result-panel dd,
.liar-game .statement-list strong,
.liar-game .panel-heading h2,
.liar-game button,
.liar-game input {
  color: var(--liar-text);
}

.liar-game .match-header h1 {
  text-shadow: 0 0 24px rgba(var(--liar-glow-rgb), 0.28);
}

.liar-game .score-goal,
.liar-game .statement-turn-heading strong,
.liar-game .statement-list b {
  background: rgba(var(--liar-accent-rgb), 0.13);
  border-color: rgba(var(--liar-accent-rgb), 0.34);
  color: var(--liar-accent-strong);
}

.liar-game .hero-panel {
  background:
    linear-gradient(90deg, rgba(var(--liar-accent-rgb), 0.1), rgba(76, 29, 149, 0.13)),
    rgba(12, 8, 24, 0.82);
}

.liar-game button,
.liar-game input {
  border-color: rgba(var(--liar-accent-rgb), 0.2);
}

.liar-game button.primary,
.liar-game .guess-form button,
.liar-game .statement-form button,
.liar-game .chat-panel form button {
  background: linear-gradient(180deg, var(--liar-accent-strong), var(--liar-accent-deep));
  color: #160b28;
}

.liar-game button.selected,
.liar-game .statement-list li.active {
  background: rgba(var(--liar-accent-rgb), 0.15);
  border-color: rgba(var(--liar-accent-rgb), 0.72);
  box-shadow: 0 0 0 3px rgba(var(--liar-accent-rgb), 0.11);
  color: var(--liar-accent-strong);
}

.liar-game .panel-heading,
.liar-game .chat-panel form {
  border-color: rgba(var(--liar-accent-rgb), 0.15);
}

.liar-game .chat-list {
  scrollbar-color: rgba(var(--liar-accent-rgb), 0.42) rgba(0, 0, 0, 0.18);
}

.liar-game .chat-list li.system {
  background: rgba(var(--liar-accent-rgb), 0.1);
  border-color: rgba(var(--liar-accent-rgb), 0.18);
  color: rgba(var(--liar-accent-rgb), 0.92);
}

.liar-game .chat-meta strong {
  color: var(--liar-accent-strong);
}

@container (max-width: 30rem) {
  .panel-heading {
    align-items: flex-start;
    flex-direction: column;
  }

  .chat-list li {
    max-width: 94%;
  }

  .chat-list li.system {
    max-width: 96%;
  }

  .chat-panel form {
    grid-template-columns: 1fr;
  }

  .chat-panel form button {
    width: 100%;
  }
}

@media (max-width: 1100px) {
  .game-layout {
    grid-template-columns: 1fr;
  }
}

@media (max-width: 640px) {
  .liar-game {
    min-height: auto;
  }

  .match-header {
    align-items: stretch;
    flex-direction: column;
  }

  .score-goal {
    justify-self: start;
    width: fit-content;
  }

  .match-actions {
    align-items: flex-start;
    justify-content: flex-start;
  }

  .guess-form,
  .statement-form,
  .chat-panel form {
    grid-template-columns: 1fr;
  }
}
</style>
