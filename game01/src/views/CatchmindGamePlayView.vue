<script setup>
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { useAuthStore } from '@/stores/auth'
import { useToastStore } from '@/stores/toast'
import { getGameMessages, subscribeToGameMessages } from '@/api/chatApi'
import {
  getRoom,
  heartbeatRoomPresence,
  prepareRoomDepartureSignal,
  ROOM_PRESENCE_TIMEOUTS,
  signalRoomDeparture,
} from '@/api/roomApi'
import {
  advanceCatchmindPhase,
  broadcastCatchmindCanvas,
  getCatchmindCanvasSnapshot,
  leaveCatchmindMatch,
  reconcileCatchmindMatch,
  returnCatchmindLobby,
  saveCatchmindCanvasSnapshot,
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
const chatMessagesRef = ref(null)
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
let resumeSyncPromise = null
let snapshotSaveTimer = null
let snapshotSavePromise = null
let intentionalDeparture = false

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
const sortedPlayers = computed(() => [...players.value].sort((a, b) => b.score - a.score))
const phaseLabel = computed(() => {
  if (phase.value === 'ROUND_RESULT') return '라운드 결과'
  if (phase.value === 'GAME_RESULT') return '게임 결과'
  return '그림 퀴즈 진행 중'
})
const actionGuide = computed(() => {
  if (phase.value === 'ROUND_RESULT') return '정답과 점수 변화를 확인하세요. 잠시 후 다음 라운드가 시작됩니다.'
  if (isDrawer.value) return '제시어를 그림으로 표현하세요. 글자나 숫자를 직접 적지 않는 것이 좋습니다.'
  if (canAnswer.value) return '그림을 보고 정답을 채팅으로 입력하세요. 정답 단어는 완전 일치 방식으로 판정됩니다.'
  return '이번 라운드의 정답 처리가 완료되었습니다. 다음 라운드를 기다려주세요.'
})
const answerPlaceholder = computed(() => {
  if (isDrawer.value) return '출제자는 그림으로 힌트를 전달하세요'
  if (!canAnswer.value) return '다음 라운드를 기다려주세요'
  return '정답을 입력하세요'
})
const drawerRuleLabel = computed(() =>
  match.value?.drawerRule === 'correct_answerer' ? '직전 정답자' : '랜덤 참가자',
)

function getCanvasContext() {
  return canvasRef.value?.getContext('2d') || null
}

function clearCanvas({ broadcast = false } = {}) {
  const canvas = canvasRef.value
  const context = getCanvasContext()
  if (!canvas || !context) return
  context.clearRect(0, 0, canvas.width, canvas.height)
  if (broadcast && isDrawer.value) {
    broadcastCatchmindCanvas(canvasChannel, { type: 'clear' })
    scheduleCanvasSnapshotSave()
  }
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
  if (broadcast && isDrawer.value) {
    broadcastCatchmindCanvas(canvasChannel, { type: 'segment', segment })
    scheduleCanvasSnapshotSave()
  }
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
  scheduleCanvasSnapshotSave({ immediate: true })
}

function drawSnapshot(imageData) {
  if (!imageData) return
  const image = new Image()
  image.onload = () => {
    const context = getCanvasContext()
    if (!context || !canvasRef.value) return
    context.clearRect(0, 0, canvasRef.value.width, canvasRef.value.height)
    context.drawImage(image, 0, 0, canvasRef.value.width, canvasRef.value.height)
  }
  image.src = imageData
}

function handleCanvasEvent(payload) {
  if (payload?.type === 'clear') clearCanvas()
  if (payload?.type === 'segment' && payload.segment) drawSegment(payload.segment)
  if (payload?.type === 'snapshot-request' && isDrawer.value) {
    const dataUrl = canvasRef.value?.toDataURL?.('image/png')
    if (dataUrl) broadcastCatchmindCanvas(canvasChannel, { type: 'snapshot', dataUrl })
  }
  if (payload?.type === 'snapshot' && payload.dataUrl && !isDrawer.value) drawSnapshot(payload.dataUrl)
}

async function saveCanvasSnapshot() {
  const roundId = match.value?.round?.id
  const imageData = canvasRef.value?.toDataURL?.('image/png')
  if (!isDrawer.value || !roundId || !imageData) return

  snapshotSavePromise = saveCatchmindCanvasSnapshot(roomId.value, roundId, imageData)
    .catch((error) => {
      console.warn('[Catchmind] canvas snapshot save failed', error)
    })
    .finally(() => {
      snapshotSavePromise = null
    })

  await snapshotSavePromise
}

function scheduleCanvasSnapshotSave({ immediate = false } = {}) {
  if (!isDrawer.value) return
  if (snapshotSaveTimer) clearTimeout(snapshotSaveTimer)

  if (immediate) {
    saveCanvasSnapshot()
    return
  }

  snapshotSaveTimer = setTimeout(() => {
    snapshotSaveTimer = null
    saveCanvasSnapshot()
  }, 900)
}

async function loadCanvasSnapshot() {
  if (isDrawer.value) return
  const roundId = match.value?.round?.id
  if (!roundId) return

  try {
    const snapshot = await getCatchmindCanvasSnapshot(roomId.value, roundId)
    drawSnapshot(snapshot?.imageData || snapshot?.image_data)
  } catch (error) {
    console.warn('[Catchmind] canvas snapshot load failed', error)
  }
}

function resetSubscriptions() {
  unsubscribeState?.()
  unsubscribeMessages?.()
  unsubscribeCanvas?.()
  unsubscribeState = null
  unsubscribeMessages = null
  unsubscribeCanvas = null
  canvasChannel = null
  subscribedGameId = ''
}

async function ensureSubscriptions(gameId, { force = false } = {}) {
  if (!gameId || (!force && subscribedGameId === gameId)) return
  resetSubscriptions()
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

async function sendHeartbeat() {
  try {
    await heartbeatRoomPresence(roomId.value)
  } catch (error) {
    console.warn('[Catchmind] heartbeat failed', error)
  }
}

let syncTimer = null
function scheduleSync() {
  if (syncTimer) clearTimeout(syncTimer)
  syncTimer = setTimeout(syncState, 100)
}

function scrollChatToBottom() {
  const el = chatMessagesRef.value
  if (!el) return
  el.scrollTop = el.scrollHeight
}

async function syncState() {
  try {
    await sendHeartbeat()
    room.value = await getRoom(roomId.value)
    if (room.value.status === 'waiting') {
      await router.replace(`/rooms/${roomId.value}`)
      return
    }
    match.value = await reconcileCatchmindMatch(roomId.value)
    await ensureSubscriptions(match.value?.gameId)
    messages.value = await getGameMessages(roomId.value, match.value?.gameId, { limit: 120 })
    nextTick(scrollChatToBottom)
    if (activeRoundId !== match.value?.round?.id) {
      activeRoundId = match.value?.round?.id || ''
      await nextTick()
      clearCanvas()
      await loadCanvasSnapshot()
    }
  } catch (error) {
    toastStore.error(error.message)
  } finally {
    isLoading.value = false
  }
}

async function handlePageResume() {
  if (document.visibilityState && document.visibilityState !== 'visible') return
  if (resumeSyncPromise) return resumeSyncPromise

  resumeSyncPromise = (async () => {
    nowTick.value = Date.now()
    resetSubscriptions()
    await prepareRoomDepartureSignal()
    await sendHeartbeat()
    await syncState()
    await loadCanvasSnapshot()
  })()

  try {
    await resumeSyncPromise
  } finally {
    resumeSyncPromise = null
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
    await syncState()
  } finally {
    timeoutPromise = null
  }
}

async function returnToLobby() {
  if (isWorking.value) return
  isWorking.value = true
  try {
    intentionalDeparture = true
    await returnCatchmindLobby(roomId.value)
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
    await leaveCatchmindMatch(roomId.value)
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

watch(() => match.value?.round?.id, () => nextTick(() => clearCanvas()))

onMounted(async () => {
  await prepareRoomDepartureSignal()
  await syncState()
  pollTimer = setInterval(syncState, 2500)
  heartbeatTimer = setInterval(sendHeartbeat, ROOM_PRESENCE_TIMEOUTS.heartbeatIntervalMs)
  countdownTimer = setInterval(() => {
    nowTick.value = Date.now()
    processTimeout()
  }, 500)
  document.addEventListener('visibilitychange', handlePageResume)
  window.addEventListener('focus', handlePageResume)
  window.addEventListener('online', handlePageResume)
  window.addEventListener('pageshow', handlePageResume)
  window.addEventListener('pagehide', handlePageDeparture)
  window.addEventListener('beforeunload', handlePageDeparture)
})

onBeforeUnmount(() => {
  resetSubscriptions()
  if (pollTimer) clearInterval(pollTimer)
  if (heartbeatTimer) clearInterval(heartbeatTimer)
  if (countdownTimer) clearInterval(countdownTimer)
  if (syncTimer) clearTimeout(syncTimer)
  if (snapshotSaveTimer) clearTimeout(snapshotSaveTimer)
  document.removeEventListener('visibilitychange', handlePageResume)
  window.removeEventListener('focus', handlePageResume)
  window.removeEventListener('online', handlePageResume)
  window.removeEventListener('pageshow', handlePageResume)
  window.removeEventListener('pagehide', handlePageDeparture)
  window.removeEventListener('beforeunload', handlePageDeparture)
})
</script>

<template>
  <section class="catchmind page-card">
    <div class="game-veil" aria-hidden="true"></div>

    <p v-if="isLoading" class="game-loading">캐치마인드 상태를 불러오는 중입니다.</p>

    <template v-else-if="match">
      <header class="game-status-bar">
        <div class="status-title">
          <p>CATCHMIND GAME · ROUND {{ match.currentRoundNo }} / {{ match.totalRounds }}</p>
          <strong>{{ phase === 'GAME_RESULT' ? '게임 결과' : phaseLabel }}</strong>
        </div>
        <div class="status-actions">
          <span v-if="phase !== 'GAME_RESULT'">남은 시간 <b>{{ displayedSeconds }}초</b></span>
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

      <main v-if="phase !== 'GAME_RESULT'" class="game-layout">
        <section class="board-area">
          <section class="info-card word-card">
            <div>
              <span class="section-kicker">{{ isDrawer ? 'DRAWING WORD' : 'SECRET WORD' }}</span>
              <p>{{ isDrawer ? '제시어를 그림으로 표현하세요.' : '출제자의 그림을 보고 정답을 맞혀보세요.' }}</p>
            </div>
            <strong>{{ match.round?.answerWord || '정답은 비공개입니다' }}</strong>
          </section>

          <section class="drawing-card">
            <header class="drawing-card-header">
              <div>
                <span class="section-kicker">LIVE CANVAS</span>
                <h2>{{ match.round?.drawerNickname }}님의 그림판</h2>
              </div>
              <span class="drawer-badge">{{ isDrawer ? '내가 출제자' : '그림 공유 중' }}</span>
            </header>

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

            <div v-if="isDrawer" class="toolbar">
              <label>
                <span>선 색상</span>
                <input v-model="brushColor" type="color" title="선 색상" />
              </label>
              <label>
                <span>선 굵기</span>
                <select v-model.number="brushSize" title="선 굵기">
                  <option :value="3">얇게</option>
                  <option :value="5">보통</option>
                  <option :value="9">굵게</option>
                  <option :value="16">매우 굵게</option>
                </select>
              </label>
              <button type="button" :class="{ active: isErasing }" @click="isErasing = !isErasing">
                {{ isErasing ? '지우개 사용 중' : '지우개' }}
              </button>
              <button type="button" @click="clearCanvas({ broadcast: true })">전체 지우기</button>
            </div>
          </section>

          <section class="chat-panel">
            <header class="chat-header">
              <div>
                <span class="eyebrow">LIVE ANSWER CHAT</span>
                <h2>정답 채팅</h2>
              </div>
              <span class="chat-status-badge" :class="{ locked: !canAnswer }">
                {{ canAnswer ? '입력 가능' : '입력 잠김' }}
              </span>
            </header>
            <div class="chat-phase-banner">{{ actionGuide }}</div>
            <div ref="chatMessagesRef" class="chat-messages">
              <div
                v-for="message in messages"
                :key="message.id"
                :class="
                  message.isSystem
                    ? 'system-message-row'
                    : ['chat-message-row', message.userId === savedUser?.id ? 'mine' : 'other']
                "
              >
                <template v-if="message.isSystem">
                  <span>{{ message.content }}</span>
                </template>
                <div v-else class="chat-bubble">
                  <div class="chat-meta">
                    <strong>{{ message.nickname }}</strong>
                    <time>{{ message.createdAt }}</time>
                  </div>
                  <p>{{ message.content }}</p>
                </div>
              </div>
              <div v-if="messages.length === 0" class="empty-chat">
                아직 정답 채팅이 없습니다. 그림을 보고 정답을 입력해보세요.
              </div>
            </div>
            <form class="chat-input-area" @submit.prevent="submitAnswer">
              <input v-model="answerDraft" :disabled="!canAnswer" :placeholder="answerPlaceholder" />
              <button type="submit" :disabled="!canAnswer || !answerDraft.trim()">전송</button>
            </form>
          </section>
        </section>

        <aside class="game-info-panel">
          <section class="info-card">
            <span class="section-kicker">CURRENT DRAWER</span>
            <div class="drawer-profile">
              <strong>{{ match.round?.drawerNickname }}</strong>
              <span>현재 출제자</span>
            </div>
          </section>

          <section class="info-card">
            <span class="section-kicker">현재 진행</span>
            <dl class="phase-list">
              <div><dt>현재 단계</dt><dd>{{ phaseLabel }}</dd></div>
              <div><dt>라운드</dt><dd>{{ match.currentRoundNo }} / {{ match.totalRounds }}</dd></div>
              <div><dt>다음 출제자</dt><dd>{{ drawerRuleLabel }}</dd></div>
              <div class="timer-row"><dt>남은 시간</dt><dd>{{ displayedSeconds }}초</dd></div>
            </dl>
          </section>

          <section class="info-card score-card">
            <span class="section-kicker">점수판</span>
            <ol class="player-list">
              <li v-for="player in sortedPlayers" :key="player.userId" :class="{ drawer: player.isDrawer }">
                <div>
                  <strong>{{ player.nickname }}</strong>
                  <span v-if="player.isDrawer">출제자</span>
                </div>
                <b>{{ player.score }}점</b>
              </li>
            </ol>
          </section>

          <section class="info-card guide-card">
            <span class="section-kicker">현재 행동 안내</span>
            <p>{{ actionGuide }}</p>
          </section>
        </aside>
      </main>

      <section v-else class="game-result-screen">
        <header class="result-hero">
          <span class="section-kicker">GAME OVER</span>
          <h2>캐치마인드 최종 결과</h2>
          <p>{{ winnerNames.join(', ') }}님이 우승했습니다.</p>
        </header>
        <section class="info-card result-ranking">
          <span class="section-kicker">FINAL RANKING</span>
          <ol class="player-list">
            <li v-for="(player, index) in sortedPlayers" :key="player.userId" :class="{ winner: index === 0 }">
              <div><strong>{{ index + 1 }}위 · {{ player.nickname }}</strong></div>
              <b>{{ player.score }}점</b>
            </li>
          </ol>
          <button type="button" :disabled="isWorking" @click="returnToLobby">대기방으로 돌아가기</button>
        </section>
      </section>
    </template>
    <p class="refresh-guide">※ 뭔가 이상하다면 새로고침(F5)을 한번 눌러주세요.</p>
  </section>
</template>

<style scoped>
.refresh-guide {
  color: rgba(255, 245, 224, 0.62);
  font-size: 0.82rem;
  margin: 0;
  position: relative;
  text-align: center;
  z-index: 1;
}

.catchmind {
  background:
    radial-gradient(circle at 50% -12%, rgba(255, 190, 85, 0.15), transparent 34%),
    radial-gradient(circle at 13% 18%, rgba(127, 29, 29, 0.18), transparent 31%),
    linear-gradient(180deg, rgba(35, 20, 14, 0.97), rgba(8, 6, 6, 0.99));
  border: 1px solid rgba(255, 190, 85, 0.18);
  color: #fff1d6;
  display: grid;
  gap: clamp(0.9rem, 1.8vw, 1.25rem);
  min-height: min(900px, calc(100vh - 3rem));
  overflow: hidden;
  position: relative;
}
.game-veil {
  background: linear-gradient(90deg, transparent, rgba(255, 190, 85, 0.07), transparent);
  inset: 0;
  pointer-events: none;
  position: absolute;
}
.game-loading, .game-status-bar, .game-layout, .game-result-screen { position: relative; z-index: 1; }
.game-loading { color: rgba(255, 245, 224, 0.72); font-weight: 900; }
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
.status-title p, .section-kicker, .eyebrow {
  color: rgba(255, 190, 85, 0.72);
  font-size: 0.72rem;
  font-weight: 900;
  letter-spacing: 0.08em;
  margin: 0;
  text-transform: uppercase;
}
.status-title strong { display: block; font-size: clamp(1.35rem, 2.4vw, 2rem); margin-top: 0.1rem; }
.status-actions { align-items: center; display: flex; gap: 0.75rem; }
.status-actions span { color: rgba(255, 245, 224, 0.66); font-size: 0.86rem; font-weight: 800; }
.status-actions b, .word-card > strong, .timer-row dd { color: #ffbe55; }
button, input, select { font: inherit; }
button {
  background: linear-gradient(180deg, #ffbe55, #b86b1b);
  border: 0;
  border-radius: 8px;
  color: #231107;
  cursor: pointer;
  font-weight: 900;
  padding: 0.68rem 0.95rem;
}
button:disabled, input:disabled { cursor: not-allowed; opacity: 0.5; }
.game-layout { align-items: start; display: grid; gap: 1rem; grid-template-columns: minmax(0, 7fr) minmax(18rem, 3fr); }
.board-area, .game-info-panel { display: grid; gap: 0.9rem; min-width: 0; }
.info-card, .drawing-card, .chat-panel {
  background: linear-gradient(180deg, rgba(255, 255, 255, 0.055), rgba(255, 255, 255, 0.022)), rgba(14, 10, 8, 0.76);
  border: 1px solid rgba(255, 190, 85, 0.16);
  border-radius: 16px;
  box-shadow: 0 24px 60px rgba(0, 0, 0, 0.32), inset 0 0 34px rgba(255, 138, 0, 0.04);
}
.info-card { display: grid; gap: 0.75rem; padding: 1rem; }
.word-card { align-items: center; display: flex; justify-content: space-between; }
.word-card p, .guide-card p { color: rgba(255, 245, 224, 0.66); line-height: 1.55; margin: 0.32rem 0 0; }
.word-card > strong { background: rgba(255, 190, 85, 0.1); border: 1px solid rgba(255, 190, 85, 0.2); border-radius: 10px; padding: 0.65rem 0.85rem; }
.drawing-card { overflow: hidden; }
.drawing-card-header, .chat-header {
  align-items: center;
  border-bottom: 1px solid rgba(255, 190, 85, 0.11);
  display: flex;
  justify-content: space-between;
  padding: 1rem 1.15rem;
}
.drawing-card-header h2, .chat-header h2 { color: #fff1d6; font-size: 1.25rem; margin: 0.22rem 0 0; }
.drawer-badge, .chat-status-badge {
  background: rgba(74, 222, 128, 0.12);
  border: 1px solid rgba(74, 222, 128, 0.28);
  border-radius: 999px;
  color: #86efac;
  font-size: 0.76rem;
  font-weight: 900;
  padding: 0.38rem 0.65rem;
}
.chat-status-badge.locked { background: rgba(148, 116, 84, 0.12); border-color: rgba(255,255,255,0.08); color: rgba(255,245,224,0.52); }
.canvas-wrap { background: #fffef8; border: 5px solid rgba(255, 190, 85, 0.52); margin: 1rem; overflow: hidden; }
canvas { display: block; height: auto; touch-action: none; width: 100%; }
.toolbar { align-items: end; border-top: 1px solid rgba(255,190,85,0.11); display: flex; flex-wrap: wrap; gap: 0.65rem; padding: 0.9rem 1rem 1rem; }
.toolbar label { display: grid; gap: 0.28rem; }
.toolbar label span { color: rgba(255,245,224,0.58); font-size: 0.72rem; font-weight: 900; }
.toolbar input, .toolbar select { background: rgba(0,0,0,0.34); border: 1px solid rgba(255,190,85,0.2); border-radius: 8px; color: #fff1d6; min-height: 40px; padding: 0.42rem; }
.toolbar button { background: rgba(255,255,255,0.07); border: 1px solid rgba(255,190,85,0.16); color: rgba(255,245,224,0.82); }
.toolbar button.active { background: rgba(255,190,85,0.16); border-color: rgba(255,190,85,0.5); color: #ffd28a; }
.drawer-profile { background: rgba(255,190,85,0.1); border: 1px solid rgba(255,190,85,0.2); border-radius: 12px; display: grid; gap: 0.2rem; padding: 0.85rem; }
.drawer-profile strong { color: #ffd28a; font-size: 1.18rem; }
.drawer-profile span { color: rgba(255,245,224,0.58); font-size: 0.78rem; font-weight: 800; }
.phase-list { display: grid; gap: 0.55rem; margin: 0; }
.phase-list div { align-items: center; display: flex; gap: 0.6rem; justify-content: space-between; }
.phase-list dt { color: rgba(255,245,224,0.55); font-size: 0.8rem; font-weight: 800; }
.phase-list dd { color: #fff1d6; font-size: 0.88rem; font-weight: 900; margin: 0; text-align: right; }
.player-list { display: grid; gap: 0.5rem; list-style: none; margin: 0; padding: 0; }
.player-list li { align-items: center; background: rgba(255,255,255,0.045); border: 1px solid transparent; border-radius: 10px; display: flex; justify-content: space-between; padding: 0.65rem; }
.player-list li.drawer { background: rgba(255,190,85,0.1); border-color: rgba(255,190,85,0.36); }
.player-list li.winner { background: rgba(255,190,85,0.13); border-color: rgba(255,190,85,0.42); }
.player-list div { display: grid; gap: 0.18rem; }
.player-list span { color: #ffd28a; font-size: 0.68rem; font-weight: 900; }
.player-list b { color: #ffbe55; font-size: 0.84rem; }
.chat-panel { display: flex; flex-direction: column; min-height: 27rem; overflow: hidden; }
.chat-phase-banner { background: linear-gradient(90deg, rgba(255,190,85,0.08), rgba(127,29,29,0.1)); border-bottom: 1px solid rgba(255,190,85,0.12); color: rgba(255,226,179,0.84); font-size: 0.86rem; font-weight: 850; line-height: 1.45; padding: 0.72rem 1.15rem; }
.chat-messages { display: flex; flex: 1; flex-direction: column; gap: 0.75rem; max-height: 24rem; min-height: 14rem; overflow-y: auto; padding: 1rem 1.15rem; }
.system-message-row { align-items: center; color: rgba(255,210,138,0.82); display: flex; font-size: 0.8rem; font-weight: 900; gap: 0.7rem; justify-content: center; text-align: center; width: 100%; }
.system-message-row::before, .system-message-row::after { background: rgba(255,190,85,0.16); content: ''; flex: 1; height: 1px; }
.system-message-row span { background: rgba(255,190,85,0.08); border: 1px solid rgba(255,190,85,0.14); border-radius: 999px; padding: 0.35rem 0.7rem; }
.chat-message-row { display: flex; width: 100%; }
.chat-message-row.mine { justify-content: flex-end; }
.chat-bubble { background: rgba(0,0,0,0.24); border: 1px solid rgba(255,255,255,0.065); border-radius: 12px; max-width: min(74%, 48rem); min-width: 7.5rem; padding: 0.72rem 0.85rem; }
.chat-message-row.mine .chat-bubble { background: linear-gradient(180deg, rgba(255,190,85,0.15), rgba(96,42,18,0.22)); border-color: rgba(255,190,85,0.22); }
.chat-meta { align-items: center; display: flex; gap: 0.65rem; justify-content: space-between; }
.chat-meta strong { color: #ffd28a; font-size: 0.82rem; }
.chat-meta time { color: rgba(255,245,224,0.42); font-size: 0.7rem; }
.chat-bubble p { color: rgba(255,245,224,0.86); line-height: 1.5; margin: 0.25rem 0 0; overflow-wrap: anywhere; }
.empty-chat { color: rgba(255,245,224,0.48); font-weight: 800; margin: auto; text-align: center; }
.chat-input-area { border-top: 1px solid rgba(255,190,85,0.11); display: grid; gap: 0.7rem; grid-template-columns: minmax(0,1fr) auto; padding: 0.9rem 1.15rem 1rem; }
.chat-input-area input { background: rgba(0,0,0,0.34); border: 1px solid rgba(255,190,85,0.14); border-radius: 10px; color: #fff1d6; font-weight: 800; min-height: 48px; min-width: 0; outline: none; padding: 0.8rem 0.9rem; }
.chat-input-area input:focus { border-color: rgba(255,190,85,0.42); box-shadow: 0 0 0 3px rgba(255,190,85,0.08); }
.result-overlay { align-items: center; background: rgba(0,0,0,0.68); display: flex; inset: 0; justify-content: center; padding: 1.25rem; position: fixed; z-index: 20; }
.result-overlay-card { background: linear-gradient(145deg, #25150e, #090605); border: 1px solid rgba(255,190,85,0.58); border-radius: 18px; box-shadow: 0 22px 70px rgba(0,0,0,0.46); max-width: 30rem; padding: 2rem; text-align: center; width: 100%; }
.result-overlay-card span { color: rgba(255,190,85,0.72); font-size: 0.72rem; font-weight: 900; letter-spacing: 0.12em; }
.result-overlay-card h2 { color: #ffbe55; font-size: 1.65rem; margin: 0.7rem 0; }
.result-overlay-card p { margin: 0 0 0.75rem; }
.result-overlay-card p strong { color: #ffbe55; font-size: 1.3rem; }
.result-overlay-card small { color: rgba(255,245,224,0.62); }
.result-pop-enter-active, .result-pop-leave-active { transition: opacity 0.2s ease; }
.result-pop-enter-active .result-overlay-card, .result-pop-leave-active .result-overlay-card { transition: transform 0.2s ease; }
.result-pop-enter-from, .result-pop-leave-to { opacity: 0; }
.result-pop-enter-from .result-overlay-card, .result-pop-leave-to .result-overlay-card { transform: scale(0.94); }
.game-result-screen { display: grid; gap: 1rem; margin: auto; max-width: 44rem; width: 100%; }
.result-hero { background: rgba(10,7,6,0.54); border: 1px solid rgba(255,190,85,0.22); border-radius: 16px; padding: 1.35rem; text-align: center; }
.result-hero h2 { color: #ffbe55; font-size: 1.8rem; margin: 0.45rem 0; }
.result-hero p { color: rgba(255,245,224,0.72); margin: 0; }
.result-ranking button { justify-self: end; margin-top: 0.35rem; }
.catchmind {
  --catchmind-accent: #10b981;
  --catchmind-accent-strong: #6ee7b7;
  --catchmind-accent-deep: #047857;
  --catchmind-accent-rgb: 110, 231, 183;
  --catchmind-glow-rgb: 16, 185, 129;
  --catchmind-text: #ecfdf5;
  --catchmind-text-rgb: 209, 250, 229;
  background:
    radial-gradient(circle at 50% -12%, rgba(var(--catchmind-accent-rgb), 0.18), transparent 34%),
    radial-gradient(circle at 13% 18%, rgba(6, 78, 59, 0.22), transparent 31%),
    linear-gradient(180deg, rgba(10, 34, 29, 0.98), rgba(4, 15, 13, 0.99));
  border-color: rgba(var(--catchmind-accent-rgb), 0.22);
  color: var(--catchmind-text);
}
.catchmind .game-veil { background: linear-gradient(90deg, transparent, rgba(var(--catchmind-accent-rgb), 0.08), transparent); }
.catchmind .game-loading,
.catchmind .status-actions span,
.catchmind .word-card p,
.catchmind .guide-card p,
.catchmind .toolbar label span,
.catchmind .drawer-profile span,
.catchmind .phase-list dt,
.catchmind .chat-meta time,
.catchmind .chat-bubble p,
.catchmind .empty-chat,
.catchmind .result-overlay-card small,
.catchmind .result-hero p { color: rgba(var(--catchmind-text-rgb), 0.72); }
.catchmind .game-status-bar,
.catchmind .info-card,
.catchmind .drawing-card,
.catchmind .chat-panel,
.catchmind .result-hero { border-color: rgba(var(--catchmind-accent-rgb), 0.18); }
.catchmind .game-status-bar { background: rgba(4,15,13,0.58); }
.catchmind .info-card,
.catchmind .drawing-card,
.catchmind .chat-panel {
  background: linear-gradient(180deg, rgba(255,255,255,0.045), rgba(255,255,255,0.018)), rgba(4,15,13,0.82);
  box-shadow: 0 24px 60px rgba(0,0,0,0.32), inset 0 0 34px rgba(var(--catchmind-glow-rgb),0.05);
}
.catchmind .result-hero { background: rgba(4,15,13,0.62); }
.catchmind .status-title p,
.catchmind .section-kicker,
.catchmind .eyebrow,
.catchmind .result-overlay-card span { color: rgba(var(--catchmind-accent-rgb), 0.84); }
.catchmind .status-actions b,
.catchmind .word-card > strong,
.catchmind .timer-row dd,
.catchmind .player-list b,
.catchmind .result-overlay-card h2,
.catchmind .result-overlay-card p strong,
.catchmind .result-hero h2 { color: var(--catchmind-accent); }
.catchmind button,
.catchmind .chat-input-area button,
.catchmind .result-ranking button {
  background: linear-gradient(180deg, var(--catchmind-accent-strong), var(--catchmind-accent-deep));
  color: #03251e;
}
.catchmind .word-card > strong,
.catchmind .drawer-profile,
.catchmind .player-list li.drawer,
.catchmind .player-list li.winner,
.catchmind .toolbar button.active {
  background: rgba(var(--catchmind-accent-rgb), 0.12);
  border-color: rgba(var(--catchmind-accent-rgb), 0.34);
}
.catchmind .drawing-card-header,
.catchmind .chat-header,
.catchmind .toolbar,
.catchmind .chat-input-area { border-color: rgba(var(--catchmind-accent-rgb), 0.15); }
.catchmind .drawing-card-header h2,
.catchmind .chat-header h2,
.catchmind .phase-list dd,
.catchmind .toolbar input,
.catchmind .toolbar select,
.catchmind .chat-input-area input { color: var(--catchmind-text); }
.catchmind .canvas-wrap { border-color: rgba(var(--catchmind-accent-rgb), 0.58); }
.catchmind .toolbar input,
.catchmind .toolbar select,
.catchmind .toolbar button,
.catchmind .chat-input-area input { border-color: rgba(var(--catchmind-accent-rgb), 0.2); }
.catchmind .toolbar button { background: rgba(255,255,255,0.07); color: rgba(var(--catchmind-text-rgb), 0.86); }
.catchmind .toolbar button.active,
.catchmind .drawer-profile strong,
.catchmind .player-list span,
.catchmind .chat-meta strong { color: var(--catchmind-accent-strong); }
.catchmind .chat-phase-banner {
  background: linear-gradient(90deg, rgba(var(--catchmind-accent-rgb), 0.1), rgba(6,78,59,0.14));
  border-color: rgba(var(--catchmind-accent-rgb), 0.15);
  color: rgba(var(--catchmind-text-rgb), 0.88);
}
.catchmind .system-message-row { color: rgba(var(--catchmind-accent-rgb), 0.94); }
.catchmind .system-message-row::before,
.catchmind .system-message-row::after { background: rgba(var(--catchmind-accent-rgb), 0.18); }
.catchmind .system-message-row span {
  background: rgba(var(--catchmind-accent-rgb), 0.1);
  border-color: rgba(var(--catchmind-accent-rgb), 0.18);
}
.catchmind .chat-message-row.mine .chat-bubble {
  background: linear-gradient(180deg, rgba(var(--catchmind-accent-rgb), 0.16), rgba(6,78,59,0.24));
  border-color: rgba(var(--catchmind-accent-rgb), 0.24);
}
.catchmind .chat-input-area input:focus {
  border-color: rgba(var(--catchmind-accent-rgb), 0.48);
  box-shadow: 0 0 0 3px rgba(var(--catchmind-accent-rgb), 0.1);
}
.catchmind .result-overlay-card {
  background: linear-gradient(145deg, #102f28, #04100e);
  border-color: rgba(var(--catchmind-accent-rgb), 0.62);
}
@media (max-width: 980px) { .game-layout { grid-template-columns: 1fr; } .game-info-panel { grid-template-columns: repeat(2, minmax(0,1fr)); } .score-card, .guide-card { grid-column: span 2; } }
@media (max-width: 560px) { .game-status-bar, .status-actions, .word-card { align-items: stretch; flex-direction: column; } .game-info-panel { grid-template-columns: 1fr; } .score-card, .guide-card { grid-column: auto; } .chat-input-area { grid-template-columns: 1fr; } .canvas-wrap { border-width: 3px; margin: 0.65rem; } }
</style>
