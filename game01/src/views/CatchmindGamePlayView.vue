<script setup>
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { useAuthStore } from '@/stores/auth'
import { useToastStore } from '@/stores/toast'
import { getGameMessages, subscribeToGameMessages } from '@/api/chatApi'
import { getRoom, heartbeatRoomPresence, ROOM_PRESENCE_TIMEOUTS } from '@/api/roomApi'
import {
  advanceCatchmindPhase,
  broadcastCatchmindCanvas,
  leaveCatchmindMatch,
  reconcileCatchmindMatch,
  returnCatchmindLobby,
  submitCatchmindAnswer,
  subscribeToCatchmind,
  subscribeToCatchmindCanvas,
} from '@/api/catchmindApi'

const route = useRoute()
const router = useRouter()
const authStore = useAuthStore()
const toastStore = useToastStore()
const roomId = computed(() => String(route.params.roomId || ''))
const savedUser = computed(() => authStore.user)

const room = ref(null)
const match = ref(null)
const messages = ref([])
const answerDraft = ref('')
const canvasRef = ref(null)
const isLoading = ref(true)
const isWorking = ref(false)
const nowTick = ref(Date.now())
const brushColor = ref('#231107')
const brushSize = ref(5)
const isErasing = ref(false)

let unsubscribeState = null
let unsubscribeMessages = null
let unsubscribeCanvas = null
let canvasChannel = null
let pollTimer = null
let heartbeatTimer = null
let countdownTimer = null
let subscribedGameId = ''
let activeRoundId = ''
let isDrawing = false
let lastPoint = null
let timeoutPromise = null

const phase = computed(() => match.value?.round?.phase || 'WAITING')
const players = computed(() => match.value?.players || [])
const correctAnswers = computed(() => match.value?.correctAnswers || [])
const isDrawer = computed(() => match.value?.round?.drawerUserId === savedUser.value?.id)
const canAnswer = computed(
  () =>
    phase.value === 'ANSWERING' &&
    !isDrawer.value &&
    !correctAnswers.value.some((answer) => answer.userId === savedUser.value?.id),
)
const remainingSeconds = computed(() => {
  const endsAt = match.value?.round?.phaseEndsAt
  if (phase.value !== 'ANSWERING' || !endsAt) return 0
  return Math.max(0, Math.ceil((new Date(endsAt).getTime() - nowTick.value) / 1000))
})
const resultRemainingSeconds = computed(() => {
  const endsAt = match.value?.round?.phaseEndsAt
  if (phase.value !== 'ROUND_RESULT' || !endsAt) return 0
  return Math.max(0, Math.ceil((new Date(endsAt).getTime() - nowTick.value) / 1000))
})
const displayedSeconds = computed(() =>
  phase.value === 'ROUND_RESULT' ? resultRemainingSeconds.value : remainingSeconds.value,
)
const winnerNames = computed(() => {
  const winnerIds = new Set(match.value?.winnerUserIds || [])
  return players.value.filter((player) => winnerIds.has(player.userId)).map((player) => player.nickname)
})

function getCanvasContext() {
  return canvasRef.value?.getContext('2d') || null
}

function clearCanvas({ broadcast = false } = {}) {
  const canvas = canvasRef.value
  const context = getCanvasContext()
  if (!canvas || !context) return
  context.clearRect(0, 0, canvas.width, canvas.height)
  if (broadcast && isDrawer.value) broadcastCatchmindCanvas(canvasChannel, { type: 'clear' })
}

function drawSegment(segment, { broadcast = false } = {}) {
  const context = getCanvasContext()
  if (!context) return
  context.save()
  context.lineCap = 'round'
  context.lineJoin = 'round'
  context.lineWidth = segment.size
  context.strokeStyle = segment.color
  context.globalCompositeOperation = segment.erase ? 'destination-out' : 'source-over'
  context.beginPath()
  context.moveTo(segment.from.x, segment.from.y)
  context.lineTo(segment.to.x, segment.to.y)
  context.stroke()
  context.restore()
  if (broadcast && isDrawer.value) broadcastCatchmindCanvas(canvasChannel, { type: 'segment', segment })
}

function getCanvasPoint(event) {
  const canvas = canvasRef.value
  const rect = canvas.getBoundingClientRect()
  return {
    x: ((event.clientX - rect.left) / rect.width) * canvas.width,
    y: ((event.clientY - rect.top) / rect.height) * canvas.height,
  }
}

function startDrawing(event) {
  if (!isDrawer.value || phase.value !== 'ANSWERING') return
  event.preventDefault()
  isDrawing = true
  lastPoint = getCanvasPoint(event)
  canvasRef.value?.setPointerCapture?.(event.pointerId)
}

function continueDrawing(event) {
  if (!isDrawing || !lastPoint) return
  event.preventDefault()
  const nextPoint = getCanvasPoint(event)
  drawSegment({
    from: lastPoint,
    to: nextPoint,
    color: brushColor.value,
    size: Number(brushSize.value),
    erase: isErasing.value,
  }, { broadcast: true })
  lastPoint = nextPoint
}

function stopDrawing() {
  isDrawing = false
  lastPoint = null
}

function handleCanvasEvent(payload) {
  if (payload?.type === 'clear') clearCanvas()
  if (payload?.type === 'segment' && payload.segment) drawSegment(payload.segment)
  if (payload?.type === 'snapshot-request' && isDrawer.value) {
    const dataUrl = canvasRef.value?.toDataURL?.('image/png')
    if (dataUrl) broadcastCatchmindCanvas(canvasChannel, { type: 'snapshot', dataUrl })
  }
  if (payload?.type === 'snapshot' && payload.dataUrl && !isDrawer.value) {
    const image = new Image()
    image.onload = () => {
      const context = getCanvasContext()
      if (!context || !canvasRef.value) return
      context.clearRect(0, 0, canvasRef.value.width, canvasRef.value.height)
      context.drawImage(image, 0, 0, canvasRef.value.width, canvasRef.value.height)
    }
    image.src = payload.dataUrl
  }
}

async function ensureSubscriptions(gameId) {
  if (!gameId || subscribedGameId === gameId) return
  unsubscribeState?.()
  unsubscribeMessages?.()
  unsubscribeCanvas?.()
  subscribedGameId = gameId
  unsubscribeState = subscribeToCatchmind(gameId, scheduleSync)
  unsubscribeMessages = subscribeToGameMessages(roomId.value, gameId, scheduleSync)
  const canvasSub = subscribeToCatchmindCanvas(
    roomId.value,
    handleCanvasEvent,
    (channel) => broadcastCatchmindCanvas(channel, { type: 'snapshot-request' }),
  )
  canvasChannel = canvasSub.channel
  unsubscribeCanvas = canvasSub.unsubscribe
}

let syncTimer = null
function scheduleSync() {
  if (syncTimer) clearTimeout(syncTimer)
  syncTimer = setTimeout(syncState, 100)
}

async function syncState() {
  try {
    room.value = await getRoom(roomId.value)
    if (room.value.status === 'waiting') {
      await router.replace(`/rooms/${roomId.value}`)
      return
    }
    match.value = await reconcileCatchmindMatch(roomId.value)
    await ensureSubscriptions(match.value?.gameId)
    messages.value = await getGameMessages(roomId.value, match.value?.gameId, { limit: 120 })
    if (activeRoundId !== match.value?.round?.id) {
      activeRoundId = match.value?.round?.id || ''
      await nextTick()
      clearCanvas()
    }
  } catch (error) {
    toastStore.error(error.message)
  } finally {
    isLoading.value = false
  }
}

async function submitAnswer() {
  if (!answerDraft.value.trim() || !canAnswer.value || isWorking.value) return
  isWorking.value = true
  try {
    match.value = await submitCatchmindAnswer(roomId.value, answerDraft.value)
    answerDraft.value = ''
    await syncState()
  } catch (error) {
    toastStore.error(error.message)
  } finally {
    isWorking.value = false
  }
}

async function processTimeout() {
  const isExpiredAnswering = phase.value === 'ANSWERING' && remainingSeconds.value <= 0
  const isExpiredResult = phase.value === 'ROUND_RESULT' && resultRemainingSeconds.value <= 0
  if ((!isExpiredAnswering && !isExpiredResult) || timeoutPromise) return
  timeoutPromise = advanceCatchmindPhase(roomId.value)
  try {
    match.value = await timeoutPromise
    await syncState()
  } catch (error) {
    console.warn('[Catchmind] timeout advance failed', error)
  } finally {
    timeoutPromise = null
  }
}

async function returnToLobby() {
  if (isWorking.value) return
  isWorking.value = true
  try {
    await returnCatchmindLobby(roomId.value)
    await router.push(`/rooms/${roomId.value}`)
  } catch (error) {
    toastStore.error(error.message)
  } finally {
    isWorking.value = false
  }
}

async function leaveGame() {
  if (isWorking.value) return
  isWorking.value = true
  try {
    await leaveCatchmindMatch(roomId.value)
    await router.push('/home')
  } catch (error) {
    toastStore.error(error.message)
  } finally {
    isWorking.value = false
  }
}

watch(() => match.value?.round?.id, () => nextTick(() => clearCanvas()))

onMounted(async () => {
  await syncState()
  pollTimer = setInterval(syncState, 2500)
  heartbeatTimer = setInterval(() => heartbeatRoomPresence(roomId.value).catch(() => {}), ROOM_PRESENCE_TIMEOUTS.heartbeatIntervalMs)
  countdownTimer = setInterval(() => {
    nowTick.value = Date.now()
    processTimeout()
  }, 500)
})

onBeforeUnmount(() => {
  unsubscribeState?.()
  unsubscribeMessages?.()
  unsubscribeCanvas?.()
  if (pollTimer) clearInterval(pollTimer)
  if (heartbeatTimer) clearInterval(heartbeatTimer)
  if (countdownTimer) clearInterval(countdownTimer)
  if (syncTimer) clearTimeout(syncTimer)
})
</script>

<template>
  <section class="catchmind page-card">
    <p v-if="isLoading">캐치마인드 상태를 불러오는 중입니다.</p>
    <template v-else-if="match">
      <header class="status-bar">
        <div>
          <span>CATCHMIND · ROUND {{ match.currentRoundNo }} / {{ match.totalRounds }}</span>
          <h1>{{ phase === 'GAME_RESULT' ? '게임 결과' : `${match.round?.drawerNickname}님의 그림 차례` }}</h1>
        </div>
        <div class="status-actions">
          <strong>{{ displayedSeconds }}초</strong>
          <button type="button" :disabled="isWorking" @click="leaveGame">게임 나가기</button>
        </div>
      </header>

      <Transition name="result-pop">
        <section v-if="phase === 'ROUND_RESULT'" class="result-overlay">
          <div class="result-overlay-card">
            <span>ROUND {{ match.currentRoundNo }} RESULT</span>
            <h2 v-if="correctAnswers.length > 0">
              {{ correctAnswers.map((answer) => answer.nickname).join(', ') }}님 정답!
            </h2>
            <h2 v-else>시간 종료</h2>
            <p>정답은 <strong>{{ match.round?.answerWord }}</strong></p>
            <small>{{ resultRemainingSeconds }}초 후 다음 라운드로 이동합니다.</small>
          </div>
        </section>
      </Transition>

      <main v-if="phase !== 'GAME_RESULT'" class="layout">
        <aside class="panel">
          <h2>점수판</h2>
          <ol class="player-list">
            <li v-for="player in players" :key="player.userId" :class="{ drawer: player.isDrawer }">
              <span>{{ player.nickname }} <b v-if="player.isDrawer">출제자</b></span>
              <strong>{{ player.score }}점</strong>
            </li>
          </ol>
        </aside>

        <section class="board-column">
          <div class="panel word-card">
            <span>{{ isDrawer ? '내가 그릴 단어' : '출제자의 그림을 보고 맞혀보세요' }}</span>
            <strong>{{ match.round?.answerWord || '정답은 비공개입니다' }}</strong>
          </div>
          <div v-if="phase === 'ROUND_RESULT'" class="panel round-result">
            <h2>라운드 결과</h2>
            <strong>정답: {{ match.round?.answerWord }}</strong>
            <p v-if="correctAnswers.length === 0">이번 라운드에는 정답자가 없습니다.</p>
            <ul v-else>
              <li v-for="answer in correctAnswers" :key="answer.userId">
                {{ answer.nickname }} <b>+{{ answer.awardedScore }}점</b>
              </li>
            </ul>
          </div>
          <div class="canvas-wrap">
            <canvas
              ref="canvasRef"
              width="900"
              height="560"
              @pointerdown="startDrawing"
              @pointermove="continueDrawing"
              @pointerup="stopDrawing"
              @pointercancel="stopDrawing"
              @pointerleave="stopDrawing"
            ></canvas>
          </div>
          <div v-if="isDrawer" class="panel toolbar">
            <input v-model="brushColor" type="color" title="선 색상" />
            <select v-model.number="brushSize" title="선 굵기">
              <option :value="3">얇게</option>
              <option :value="5">보통</option>
              <option :value="9">굵게</option>
              <option :value="16">매우 굵게</option>
            </select>
            <button type="button" :class="{ active: isErasing }" @click="isErasing = !isErasing">지우개</button>
            <button type="button" @click="clearCanvas({ broadcast: true })">전체 지우기</button>
          </div>
        </section>

        <aside class="panel chat-panel">
          <h2>정답 채팅</h2>
          <ul>
            <li v-for="message in messages" :key="message.id" :class="{ system: message.isSystem }">
              <strong>{{ message.nickname }}</strong>
              <span>{{ message.content }}</span>
            </li>
          </ul>
          <form @submit.prevent="submitAnswer">
            <input v-model="answerDraft" :disabled="!canAnswer" :placeholder="isDrawer ? '출제자는 정답을 입력할 수 없습니다' : '정답을 입력하세요'" />
            <button type="submit" :disabled="!canAnswer || !answerDraft.trim()">전송</button>
          </form>
        </aside>
      </main>

      <section v-else class="panel result">
        <h2>최종 순위</h2>
        <p>{{ winnerNames.join(', ') }}님이 우승했습니다.</p>
        <ol class="player-list">
          <li v-for="player in [...players].sort((a, b) => b.score - a.score)" :key="player.userId">
            <span>{{ player.nickname }}</span><strong>{{ player.score }}점</strong>
          </li>
        </ol>
        <button type="button" @click="returnToLobby">대기방으로 돌아가기</button>
      </section>
    </template>
  </section>
</template>

<style scoped>
.catchmind { background: linear-gradient(160deg, #10251f, #07110f); color: #f8fafc; display: grid; gap: 1rem; min-height: calc(100vh - 2rem); }
.status-bar, .panel { background: rgba(8, 25, 21, .82); border: 1px solid rgba(110, 231, 183, .22); border-radius: 14px; padding: 1rem; }
.status-bar { align-items: center; display: flex; justify-content: space-between; }
.status-bar span { color: #6ee7b7; font-size: .74rem; font-weight: 900; letter-spacing: .08em; }
.status-bar h1 { font-size: 1.5rem; margin: .2rem 0 0; }
.status-bar > strong { color: #fbbf24; font-size: 1.2rem; }
.status-actions { align-items: center; display: flex; gap: .65rem; }
.status-actions > strong { color: #fbbf24; font-size: 1.2rem; }
.layout { display: grid; gap: 1rem; grid-template-columns: minmax(11rem, .75fr) minmax(24rem, 2fr) minmax(15rem, 1fr); }
.board-column { display: grid; gap: .8rem; min-width: 0; }
h2 { color: #d1fae5; font-size: 1rem; margin: 0 0 .75rem; }
.word-card { display: flex; justify-content: space-between; gap: .7rem; }
.word-card span { color: rgba(209, 250, 229, .7); }
.word-card strong { color: #fbbf24; }
.round-result strong, .round-result b { color: #fbbf24; }
.round-result p { color: rgba(236,253,245,.76); margin-bottom: 0; }
.round-result ul { display: grid; gap: .35rem; list-style: none; margin: .65rem 0 0; padding: 0; }
.result-overlay { align-items: center; background: rgba(0, 0, 0, .68); display: flex; inset: 0; justify-content: center; padding: 1.25rem; position: fixed; z-index: 20; }
.result-overlay-card { background: linear-gradient(145deg, #12352c, #07110f); border: 1px solid rgba(251, 191, 36, .58); border-radius: 18px; box-shadow: 0 22px 70px rgba(0,0,0,.46); max-width: 30rem; padding: 2rem; text-align: center; width: 100%; }
.result-overlay-card span { color: #6ee7b7; font-size: .72rem; font-weight: 900; letter-spacing: .12em; }
.result-overlay-card h2 { color: #fbbf24; font-size: 1.65rem; margin: .7rem 0; }
.result-overlay-card p { color: #ecfdf5; margin: 0 0 .75rem; }
.result-overlay-card p strong { color: #fbbf24; font-size: 1.3rem; }
.result-overlay-card small { color: rgba(209,250,229,.7); }
.result-pop-enter-active, .result-pop-leave-active { transition: opacity .2s ease; }
.result-pop-enter-active .result-overlay-card, .result-pop-leave-active .result-overlay-card { transition: transform .2s ease; }
.result-pop-enter-from, .result-pop-leave-to { opacity: 0; }
.result-pop-enter-from .result-overlay-card, .result-pop-leave-to .result-overlay-card { transform: scale(.94); }
.canvas-wrap { background: #fffef8; border: 5px solid rgba(167, 243, 208, .7); border-radius: 14px; overflow: hidden; }
canvas { display: block; height: auto; touch-action: none; width: 100%; }
.toolbar { display: flex; flex-wrap: wrap; gap: .55rem; }
button, input, select { background: rgba(0, 0, 0, .28); border: 1px solid rgba(110, 231, 183, .26); border-radius: 8px; color: #ecfdf5; font: inherit; padding: .65rem .75rem; }
button { cursor: pointer; font-weight: 900; }
button.active, button:hover { border-color: #6ee7b7; }
button:disabled, input:disabled { cursor: not-allowed; opacity: .48; }
.player-list, .chat-panel ul { display: grid; gap: .45rem; list-style: none; margin: 0; padding: 0; }
.player-list li { align-items: center; background: rgba(255,255,255,.04); border-radius: 8px; display: flex; justify-content: space-between; padding: .58rem; }
.player-list li.drawer { border: 1px solid rgba(251, 191, 36, .55); }
.player-list b { color: #fbbf24; font-size: .68rem; }
.chat-panel { display: flex; flex-direction: column; min-height: 28rem; min-width: 0; }
.chat-panel ul { flex: 1; max-height: 34rem; overflow-y: auto; }
.chat-panel li { display: grid; gap: .16rem; padding: .4rem 0; }
.chat-panel li.system { color: #fbbf24; }
.chat-panel span { color: rgba(236,253,245,.76); overflow-wrap: anywhere; }
.chat-panel form { display: grid; gap: .45rem; grid-template-columns: minmax(0,1fr) auto; margin-top: .7rem; }
.chat-panel input { min-width: 0; }
.result { margin: auto; max-width: 32rem; width: 100%; }
@media (max-width: 1100px) { .layout { grid-template-columns: 1fr; } .chat-panel { min-height: 20rem; } }
@media (max-width: 560px) { .status-bar, .word-card { align-items: stretch; flex-direction: column; } .chat-panel form { grid-template-columns: 1fr; } }
</style>
