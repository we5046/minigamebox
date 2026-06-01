<script setup>
import { computed, onBeforeUnmount, onMounted, ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { useAuthStore } from '@/stores/auth'
import { useToastStore } from '@/stores/toast'
import {
  ROOM_PRESENCE_TIMEOUTS,
  getRoom,
  heartbeatRoomPresence,
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
  getCurrentLiarMatch,
  getMyLiarState,
  resolveLiarVote,
  returnLiarRoomToLobby,
  submitLiarGuess,
  submitLiarVote,
  subscribeToLiarMatch,
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
const isLoading = ref(true)
const isWorking = ref(false)

let unsubscribeRoom = null
let unsubscribeMatch = null
let unsubscribeMessages = null
let pollTimer = null
let heartbeatTimer = null
let syncTimer = null
let subscribedGameId = null

const phase = computed(() => match.value?.round?.phase || '')
const scoreboard = computed(() => match.value?.scoreboard || [])
const voteStatus = computed(() => match.value?.voteStatus || { votes: [], candidateUserIds: [] })
const currentVotes = computed(() => voteStatus.value.votes || [])
const currentPlayer = computed(() =>
  room.value?.players?.find((player) => player.userId === savedUser.value?.id),
)
const isHost = computed(() => currentPlayer.value?.isHost === true)
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
const roundResult = computed(() => match.value?.roundResult || null)
const winnerNames = computed(() => {
  const winnerIds = new Set(match.value?.winnerUserIds || [])
  return scoreboard.value.filter((player) => winnerIds.has(player.userId)).map((player) => player.nickname)
})
const phaseLabel = computed(() => {
  const labels = {
    word_reveal: '역할 및 제시어 확인',
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
  if (phase.value === 'word_reveal') return '토론 시작'
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
  }
  return labels[reason] || '라운드 결과가 확정되었습니다.'
}

function scheduleSync() {
  if (syncTimer) clearTimeout(syncTimer)
  syncTimer = setTimeout(syncState, 100)
}

async function ensureSubscriptions(gameId) {
  if (!gameId || subscribedGameId === gameId) return

  unsubscribeMatch?.()
  unsubscribeMessages?.()
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
    }
  })
  messages.value = await getGameMessages(roomId.value, gameId, { limit: 160 })
}

async function syncState() {
  try {
    const nextRoom = await getRoom(roomId.value)
    room.value = nextRoom

    if (nextRoom.status === 'waiting') {
      await router.replace(`/rooms/${roomId.value}`)
      return
    }

    const nextMatch = await getCurrentLiarMatch(roomId.value)
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
    await returnLiarRoomToLobby(roomId.value)
    await router.push(`/rooms/${roomId.value}`)
  } catch (error) {
    toastStore.error(error.message)
  } finally {
    isWorking.value = false
  }
}

onMounted(async () => {
  unsubscribeRoom = subscribeToRoom(roomId.value, scheduleSync)
  pollTimer = setInterval(syncState, 2500)
  heartbeatTimer = setInterval(sendHeartbeat, ROOM_PRESENCE_TIMEOUTS.heartbeatIntervalMs)
  await syncState()
  await sendHeartbeat()
})

onBeforeUnmount(() => {
  unsubscribeRoom?.()
  unsubscribeMatch?.()
  unsubscribeMessages?.()
  if (pollTimer) clearInterval(pollTimer)
  if (heartbeatTimer) clearInterval(heartbeatTimer)
  if (syncTimer) clearTimeout(syncTimer)
})
</script>

<template>
  <section class="liar-game page-card">
    <p class="eyebrow">Liar Match</p>
    <p v-if="isLoading" class="empty-state">라이어 게임 상태를 불러오는 중입니다.</p>

    <template v-else-if="match">
      <header class="match-header">
        <div>
          <h1>ROUND {{ match.currentRoundNo }}</h1>
          <p>{{ phaseLabel }}</p>
        </div>
        <div class="score-goal">목표 {{ match.targetScore }}점</div>
      </header>

      <div class="game-layout">
        <aside class="side-column">
          <section class="panel role-card">
            <span>내 역할</span>
            <strong :class="myState?.role">{{ myState?.role === 'liar' ? '라이어' : '일반 유저' }}</strong>
            <p>테마: {{ myState?.categoryLabel || match.round?.categoryLabel }}</p>
            <p v-if="myState?.word">제시어: <b>{{ myState.word }}</b></p>
            <p v-else>다른 참가자의 설명을 보고 제시어를 추리하세요.</p>
          </section>

          <section class="panel">
            <h2>점수판</h2>
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
            <p>모든 참가자가 확인하면 방장이 토론을 시작합니다.</p>
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
              <h2>게임 채팅</h2>
              <span>{{ canChat ? '입력 가능' : '현재 단계에서는 읽기만 가능' }}</span>
            </div>
            <ul class="chat-list">
              <li v-for="message in messages" :key="message.id" :class="{ system: message.isSystem }">
                <small>R{{ message.roundNo || '-' }} · {{ message.createdAt }}</small>
                <strong>{{ message.nickname }}</strong>
                <span>{{ message.content }}</span>
              </li>
            </ul>
            <form @submit.prevent="sendChat">
              <input v-model="chatDraft" type="text" maxlength="240" :disabled="!canChat" placeholder="토론 메시지를 입력하세요" />
              <button type="submit" :disabled="!canChat || !chatDraft.trim()">전송</button>
            </form>
          </section>
        </main>

        <aside class="side-column">
          <section class="panel">
            <h2>투표 현황</h2>
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
            <h2>방장 진행</h2>
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
  display: grid;
  gap: 1rem;
}

.eyebrow,
.match-header p,
.hero-panel p,
.panel-heading span,
.vote-list span,
.panel > p,
small {
  color: rgba(255, 245, 224, 0.62);
}

.eyebrow {
  font-size: 0.76rem;
  font-weight: 900;
  letter-spacing: 0.14em;
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

.match-header,
.panel-heading {
  align-items: center;
  display: flex;
  gap: 0.75rem;
  justify-content: space-between;
}

.score-goal {
  background: rgba(139, 92, 246, 0.16);
  border: 1px solid rgba(196, 181, 253, 0.34);
  border-radius: 999px;
  color: #ddd6fe;
  font-weight: 900;
  padding: 0.5rem 0.8rem;
}

.game-layout {
  display: grid;
  gap: 0.85rem;
  grid-template-columns: minmax(12rem, 0.8fr) minmax(18rem, 1.6fr) minmax(12rem, 0.9fr);
}

.side-column,
.main-column,
.panel {
  display: grid;
  gap: 0.75rem;
}

.side-column {
  align-content: start;
}

.panel {
  background: rgba(255, 255, 255, 0.055);
  border: 1px solid rgba(196, 181, 253, 0.2);
  border-radius: 0.85rem;
  padding: 0.9rem;
}

.role-card strong {
  color: #86efac;
  font-size: 1.35rem;
}

.role-card strong.liar {
  color: #fda4af;
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
  background: rgba(255, 255, 255, 0.045);
  border-radius: 0.55rem;
  display: flex;
  gap: 0.45rem;
  justify-content: space-between;
  padding: 0.55rem;
}

.vote-list li {
  align-items: flex-start;
  flex-direction: column;
}

.hero-panel {
  min-height: 8rem;
}

.candidate-grid {
  display: grid;
  gap: 0.55rem;
  grid-template-columns: repeat(auto-fit, minmax(8rem, 1fr));
}

button,
input {
  background: rgba(15, 10, 25, 0.82);
  border: 1px solid rgba(196, 181, 253, 0.3);
  border-radius: 0.65rem;
  color: var(--color-text);
  font: inherit;
  padding: 0.7rem 0.78rem;
}

button {
  cursor: pointer;
  font-weight: 900;
}

button.primary,
.guess-form button {
  background: linear-gradient(135deg, #8b5cf6, #6d28d9);
  color: white;
}

button.selected {
  border-color: #c4b5fd;
  box-shadow: 0 0 0 2px rgba(167, 139, 250, 0.22);
}

button:disabled,
input:disabled {
  cursor: not-allowed;
  opacity: 0.52;
}

.guess-form,
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
  font-weight: 900;
  margin: 0;
}

.chat-list {
  max-height: 23rem;
  min-height: 16rem;
  overflow-y: auto;
}

.chat-list li {
  display: grid;
  gap: 0.12rem;
}

.chat-list li.system {
  color: #c4b5fd;
}

@media (max-width: 1100px) {
  .game-layout {
    grid-template-columns: 1fr;
  }
}
</style>
