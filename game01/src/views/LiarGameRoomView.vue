<script setup>
import { computed, onBeforeUnmount, onMounted, reactive, ref } from 'vue'
import { useRouter } from 'vue-router'
import { useAuthStore } from '@/stores/auth'
import { useToastStore } from '@/stores/toast'
import {
  ROOM_PRESENCE_TIMEOUTS,
  getRoom,
  heartbeatRoomPresence,
  joinRoom,
  leaveRoom,
  setPlayerReady,
  subscribeToRoom,
} from '@/api/roomApi'
import {
  normalizeBroadcastMessage,
  sendRoomChatMessage,
  subscribeToRoomChat,
} from '@/api/chatApi'
import { setCurrentUserPresence } from '@/api/presenceApi'
import {
  DEFAULT_LIAR_ROOM_SETTINGS,
  configureLiarRoom,
  getLiarCategories,
  getLiarRoomSettings,
  startLiarMatch,
} from '@/api/liarGameApi'

const props = defineProps({
  roomId: {
    type: String,
    required: true,
  },
})

const router = useRouter()
const authStore = useAuthStore()
const toastStore = useToastStore()
const savedUser = computed(() => authStore.user)

const room = ref(null)
const settings = ref({ ...DEFAULT_LIAR_ROOM_SETTINGS })
const categories = ref([])
const isLoading = ref(true)
const isWorking = ref(false)
const isSettingsOpen = ref(false)
const chatDraft = ref('')
const chatMessages = ref([
  {
    id: 'liar-room-welcome',
    nickname: 'System',
    content: '라이어 게임 대기방입니다. 참가자 전원이 준비되면 매치를 시작할 수 있습니다.',
    createdAt: '방금 전',
    isSystem: true,
  },
])
const settingsDraft = reactive({ ...DEFAULT_LIAR_ROOM_SETTINGS })

let unsubscribeRoom = null
let unsubscribeRoomChat = null
let roomChatChannel = null
let heartbeatTimer = null
let syncTimer = null

const players = computed(() => room.value?.players || [])
const currentPlayer = computed(() =>
  players.value.find((player) => player.userId === savedUser.value?.id),
)
const isHost = computed(() => currentPlayer.value?.isHost === true)
const canStartMatch = computed(
  () =>
    room.value?.status === 'waiting' &&
    players.value.length >= 3 &&
    players.value.every((player) => player.isReady),
)
const selectedCategoryLabel = computed(() => {
  if (!settings.value.categoryId) return '랜덤'
  return categories.value.find((category) => category.id === settings.value.categoryId)?.label || '랜덤'
})
const isCustomDraft = computed(() => settingsDraft.settingMode === 'custom')

function copySettingsToDraft(nextSettings) {
  Object.assign(settingsDraft, DEFAULT_LIAR_ROOM_SETTINGS, nextSettings)
}

function scheduleSync() {
  if (syncTimer) clearTimeout(syncTimer)
  syncTimer = setTimeout(loadRoom, 120)
}

async function loadRoom() {
  try {
    let nextRoom = await getRoom(props.roomId)

    if (savedUser.value && !nextRoom.players.some((player) => player.userId === savedUser.value.id)) {
      nextRoom = await joinRoom(props.roomId)
    }

    room.value = nextRoom

    if (nextRoom.status === 'playing') {
      router.replace(`/rooms/${props.roomId}/game`)
      return
    }

    const [nextSettings, nextCategories] = await Promise.all([
      getLiarRoomSettings(props.roomId),
      getLiarCategories(),
    ])
    settings.value = nextSettings
    categories.value = nextCategories
    copySettingsToDraft(nextSettings)

    await setCurrentUserPresence({
      userId: savedUser.value?.id,
      nickname: savedUser.value?.nickname,
      status: 'room',
      roomId: props.roomId,
      canReceiveWhisper: true,
    })
  } catch (error) {
    toastStore.error(error.message)
  } finally {
    isLoading.value = false
  }
}

async function sendHeartbeat() {
  try {
    await heartbeatRoomPresence(props.roomId)
  } catch (error) {
    console.warn('[LiarRoom] heartbeat failed', error)
  }
}

async function toggleReady() {
  if (!currentPlayer.value || isWorking.value) return
  isWorking.value = true

  try {
    room.value = await setPlayerReady(props.roomId, savedUser.value.id, !currentPlayer.value.isReady)
  } catch (error) {
    toastStore.error(error.message)
  } finally {
    isWorking.value = false
  }
}

async function beginMatch() {
  if (!canStartMatch.value || !isHost.value || isWorking.value) return
  isWorking.value = true

  try {
    await startLiarMatch(props.roomId)
    await router.push(`/rooms/${props.roomId}/game`)
  } catch (error) {
    toastStore.error(error.message)
  } finally {
    isWorking.value = false
  }
}

function openSettings() {
  copySettingsToDraft(settings.value)
  isSettingsOpen.value = true
}

async function saveSettings() {
  if (!isHost.value || isWorking.value) return
  isWorking.value = true

  try {
    settings.value = await configureLiarRoom(props.roomId, settingsDraft)
    copySettingsToDraft(settings.value)
    isSettingsOpen.value = false
    toastStore.success('라이어 게임 설정을 저장했습니다.')
  } catch (error) {
    toastStore.error(error.message)
  } finally {
    isWorking.value = false
  }
}

async function sendChat() {
  const content = chatDraft.value.trim()
  if (!content || !roomChatChannel || !savedUser.value) return

  try {
    await sendRoomChatMessage(roomChatChannel, {
      userId: savedUser.value.id,
      nickname: savedUser.value.nickname,
      content,
    })
    chatDraft.value = ''
  } catch (error) {
    toastStore.error(error.message)
  }
}

async function exitRoom() {
  if (isWorking.value) return
  isWorking.value = true

  try {
    await leaveRoom(props.roomId)
    await router.push('/home')
  } catch (error) {
    toastStore.error(error.message)
  } finally {
    isWorking.value = false
  }
}

onMounted(async () => {
  const subscription = subscribeToRoomChat(props.roomId, (payload) => {
    if (!payload?.payload) return
    chatMessages.value = [...chatMessages.value, normalizeBroadcastMessage(payload.payload)].slice(-80)
  })
  roomChatChannel = subscription.channel
  unsubscribeRoomChat = subscription.unsubscribe
  unsubscribeRoom = subscribeToRoom(props.roomId, scheduleSync)
  heartbeatTimer = setInterval(sendHeartbeat, ROOM_PRESENCE_TIMEOUTS.heartbeatIntervalMs)
  await loadRoom()
  await sendHeartbeat()
})

onBeforeUnmount(() => {
  unsubscribeRoom?.()
  unsubscribeRoomChat?.()
  if (heartbeatTimer) clearInterval(heartbeatTimer)
  if (syncTimer) clearTimeout(syncTimer)
})
</script>

<template>
  <section class="liar-room page-card">
    <p class="eyebrow">Liar Game Room</p>

    <p v-if="isLoading" class="empty-state">방 정보를 불러오는 중입니다.</p>

    <template v-else-if="room">
      <header class="room-header">
        <div>
          <h1>{{ room.title }}</h1>
          <p>제시어를 모르는 라이어를 찾아내세요. 목표 점수까지 여러 라운드를 진행합니다.</p>
        </div>
        <div class="header-actions">
          <button v-if="isHost" type="button" :disabled="isWorking" @click="openSettings">방 설정</button>
          <button type="button" :disabled="isWorking" @click="exitRoom">나가기</button>
        </div>
      </header>

      <div class="summary-grid">
        <article>
          <span>모드</span>
          <strong>{{ settings.settingMode === 'classic' ? '클래식' : '커스텀' }}</strong>
        </article>
        <article>
          <span>테마</span>
          <strong>{{ selectedCategoryLabel }}</strong>
        </article>
        <article>
          <span>목표 점수</span>
          <strong>{{ settings.targetScore }}점</strong>
        </article>
        <article>
          <span>점수</span>
          <strong>시민 +{{ settings.citizenWinScore }} / 라이어 +{{ settings.liarWinScore }}</strong>
        </article>
      </div>

      <div class="room-layout">
        <section class="panel">
          <div class="panel-heading">
            <h2>참가자</h2>
            <span>{{ players.length }} / {{ room.maxPlayers }}</span>
          </div>
          <ul class="player-list">
            <li v-for="player in players" :key="player.userId">
              <div>
                <strong>{{ player.isHost ? '👑 ' : '' }}{{ player.nickname }}</strong>
                <small>{{ player.isConnected ? '접속 중' : '연결 끊김' }}</small>
              </div>
              <b :class="{ ready: player.isReady }">{{ player.isReady ? 'READY' : 'WAIT' }}</b>
            </li>
          </ul>

          <div class="match-actions">
            <button
              v-if="isHost"
              type="button"
              class="primary"
              :disabled="!canStartMatch || isWorking"
              @click="beginMatch"
            >
              매치 시작
            </button>
            <button v-else type="button" class="primary" :disabled="isWorking" @click="toggleReady">
              {{ currentPlayer?.isReady ? '준비 취소' : '준비 완료' }}
            </button>
            <p>3명 이상, 전원 준비 완료 시 시작할 수 있습니다.</p>
          </div>
        </section>

        <section class="panel chat-panel">
          <div class="panel-heading">
            <h2>대기방 채팅</h2>
          </div>
          <ul class="chat-list">
            <li v-for="message in chatMessages" :key="message.id" :class="{ system: message.isSystem }">
              <strong>{{ message.nickname }}</strong>
              <span>{{ message.content }}</span>
            </li>
          </ul>
          <form @submit.prevent="sendChat">
            <input v-model="chatDraft" type="text" maxlength="240" placeholder="메시지를 입력하세요" />
            <button type="submit">전송</button>
          </form>
        </section>
      </div>

      <form v-if="isSettingsOpen" class="settings-modal" @submit.prevent="saveSettings">
        <header>
          <h2>라이어 게임 설정</h2>
          <button type="button" @click="isSettingsOpen = false">닫기</button>
        </header>

        <label>
          게임 모드
          <select v-model="settingsDraft.settingMode">
            <option value="classic">클래식</option>
            <option value="custom">커스텀</option>
          </select>
        </label>

        <label>
          테마
          <select v-model="settingsDraft.categoryId">
            <option :value="null">랜덤</option>
            <option v-for="category in categories" :key="category.id" :value="category.id">
              {{ category.label }}
            </option>
          </select>
        </label>

        <template v-if="isCustomDraft">
          <label>
            목표 점수
            <select v-model.number="settingsDraft.targetScore">
              <option v-for="score in [3, 5, 7, 10]" :key="score" :value="score">{{ score }}점</option>
            </select>
          </label>
          <label>
            시민 승리 점수
            <select v-model.number="settingsDraft.citizenWinScore">
              <option v-for="score in [1, 2]" :key="score" :value="score">+{{ score }}점</option>
            </select>
          </label>
          <label>
            라이어 승리 점수
            <select v-model.number="settingsDraft.liarWinScore">
              <option v-for="score in [2, 3, 5]" :key="score" :value="score">+{{ score }}점</option>
            </select>
          </label>
        </template>
        <p v-else>클래식은 목표 5점, 시민 +1점, 라이어 +2점, 동률 시 재투표로 진행합니다.</p>

        <button type="submit" class="primary" :disabled="isWorking">설정 저장</button>
      </form>
    </template>
  </section>
</template>

<style scoped>
.liar-room {
  display: grid;
  gap: 1.2rem;
  position: relative;
}

.eyebrow,
.room-header p,
.match-actions p,
.settings-modal p,
small {
  color: rgba(255, 245, 224, 0.64);
}

.eyebrow {
  font-size: 0.76rem;
  font-weight: 900;
  letter-spacing: 0.12em;
  margin: 0;
  text-transform: uppercase;
}

h1,
h2,
p {
  margin: 0;
}

.room-header,
.header-actions,
.panel-heading,
.match-actions,
.settings-modal header {
  align-items: center;
  display: flex;
  gap: 0.75rem;
  justify-content: space-between;
}

.room-header p {
  margin-top: 0.35rem;
}

.summary-grid,
.room-layout {
  display: grid;
  gap: 0.8rem;
}

.summary-grid {
  grid-template-columns: repeat(4, minmax(0, 1fr));
}

.summary-grid article,
.panel,
.settings-modal {
  background: rgba(255, 255, 255, 0.055);
  border: 1px solid rgba(196, 181, 253, 0.22);
  border-radius: 0.85rem;
  padding: 1rem;
}

.summary-grid article {
  display: grid;
  gap: 0.25rem;
}

.summary-grid span {
  color: rgba(255, 245, 224, 0.58);
  font-size: 0.78rem;
}

.room-layout {
  grid-template-columns: minmax(0, 1fr) minmax(0, 1fr);
}

.panel {
  display: grid;
  gap: 0.8rem;
}

.player-list,
.chat-list {
  display: grid;
  gap: 0.5rem;
  list-style: none;
  margin: 0;
  padding: 0;
}

.player-list li {
  align-items: center;
  background: rgba(255, 255, 255, 0.045);
  border-radius: 0.7rem;
  display: flex;
  justify-content: space-between;
  padding: 0.7rem;
}

.player-list li div {
  display: grid;
  gap: 0.2rem;
}

.player-list b {
  color: #fda4af;
  font-size: 0.76rem;
}

.player-list b.ready {
  color: #86efac;
}

.match-actions {
  align-items: stretch;
  flex-direction: column;
}

.chat-list {
  max-height: 21rem;
  min-height: 16rem;
  overflow-y: auto;
}

.chat-list li {
  display: grid;
  gap: 0.15rem;
}

.chat-list li.system {
  color: #c4b5fd;
}

.chat-list strong {
  font-size: 0.78rem;
}

.chat-panel form {
  display: grid;
  gap: 0.5rem;
  grid-template-columns: minmax(0, 1fr) auto;
}

button,
input,
select {
  background: rgba(13, 10, 22, 0.78);
  border: 1px solid rgba(196, 181, 253, 0.28);
  border-radius: 0.65rem;
  color: var(--color-text);
  font: inherit;
  padding: 0.68rem 0.78rem;
}

button {
  cursor: pointer;
  font-weight: 900;
}

button.primary {
  background: linear-gradient(135deg, #8b5cf6, #6d28d9);
  color: white;
}

button:disabled {
  cursor: not-allowed;
  opacity: 0.48;
}

.settings-modal {
  display: grid;
  gap: 0.8rem;
  inset: 5rem max(1rem, 14vw) auto;
  position: fixed;
  z-index: 20;
}

.settings-modal label {
  display: grid;
  gap: 0.35rem;
  font-weight: 800;
}

@media (max-width: 820px) {
  .summary-grid,
  .room-layout {
    grid-template-columns: 1fr;
  }

  .room-header {
    align-items: flex-start;
    flex-direction: column;
  }

  .settings-modal {
    inset: 1rem;
  }
}
</style>
