<script setup>
import { computed, onBeforeUnmount, onMounted, ref } from 'vue'
import { useRouter } from 'vue-router'
import { getCurrentUser } from '@/api/session'
import {
  getRoom,
  joinRoom as joinRoomRequest,
  leaveRoom as leaveRoomRequest,
  setPlayerReady,
  subscribeToRoom,
  updateRoom,
} from '@/api/roomApi'

const props = defineProps({
  roomId: {
    type: String,
    required: true,
  },
})

const router = useRouter()
const savedUser = getCurrentUser()
const room = ref(null)
const message = ref('')
const isLoading = ref(false)
const isUpdating = ref(false)
const isEditingRoom = ref(false)
const editRoomTitle = ref('')
const editRoomDescription = ref('')
const lastSyncedAt = ref(null)
let unsubscribeRoom = null
let fallbackPollingId = null

const players = computed(() => room.value?.players || [])
const currentPlayer = computed(() => {
  return players.value.find((player) => player.userId === savedUser?.id)
})
const isHost = computed(() => currentPlayer.value?.isHost === true)
const canStartGame = computed(() => {
  return players.value.length > 0 && players.value.every((player) => player.isReady)
})

onMounted(() => {
  fetchRoom()
  unsubscribeRoom = subscribeToRoom(props.roomId, () => {
    syncRoom()
  })
  fallbackPollingId = window.setInterval(() => {
    syncRoom()
  }, 2000)
})

onBeforeUnmount(() => {
  unsubscribeRoom?.()
  window.clearInterval(fallbackPollingId)
})

async function fetchRoom() {
  message.value = ''
  isLoading.value = true

  try {
    room.value = await getRoom(props.roomId)
    lastSyncedAt.value = new Date()

    if (savedUser && !currentPlayer.value) {
      await joinRoom()
    }
  } catch (error) {
    message.value = error.message
  } finally {
    isLoading.value = false
  }
}

async function syncRoom() {
  if (isUpdating.value) {
    return
  }

  try {
    room.value = await getRoom(props.roomId)
    lastSyncedAt.value = new Date()
    message.value = ''
  } catch (error) {
    if (error.message.includes('Not Found')) {
      router.push('/home')
      return
    }

    message.value = error.message
  }
}

async function joinRoom() {
  if (!room.value || !savedUser) {
    router.push('/login')
    return
  }

  room.value = await joinRoomRequest(props.roomId, savedUser)
  lastSyncedAt.value = new Date()
}

async function toggleReady() {
  if (!currentPlayer.value || isUpdating.value) {
    return
  }

  message.value = ''
  isUpdating.value = true

  try {
    room.value = await setPlayerReady(props.roomId, savedUser.id, !currentPlayer.value.isReady)
    lastSyncedAt.value = new Date()
  } catch (error) {
    message.value = error.message
  } finally {
    isUpdating.value = false
  }
}

function openEditRoomForm() {
  editRoomTitle.value = room.value?.title || ''
  editRoomDescription.value = room.value?.description || ''
  isEditingRoom.value = true
}

function closeEditRoomForm() {
  isEditingRoom.value = false
  editRoomTitle.value = ''
  editRoomDescription.value = ''
}

async function saveRoomInfo() {
  message.value = ''

  if (!isHost.value || isUpdating.value) {
    return
  }

  if (!editRoomTitle.value.trim()) {
    message.value = '방 제목을 입력하세요.'
    return
  }

  if (!editRoomDescription.value.trim()) {
    message.value = '방 소개 내용을 입력하세요.'
    return
  }

  isUpdating.value = true

  try {
    room.value = await updateRoom(props.roomId, {
      title: editRoomTitle.value,
      description: editRoomDescription.value,
    })
    lastSyncedAt.value = new Date()
    closeEditRoomForm()
  } catch (error) {
    message.value = error.message
  } finally {
    isUpdating.value = false
  }
}

async function startGame() {
  message.value = ''

  if (!isHost.value || !canStartGame.value || isUpdating.value) {
    return
  }

  isUpdating.value = true

  try {
    room.value = await updateRoom(props.roomId, {
      status: 'playing',
      phase: '게임 진행 중',
    })
    lastSyncedAt.value = new Date()
  } catch (error) {
    message.value = error.message
  } finally {
    isUpdating.value = false
  }
}

async function leaveRoom() {
  if (!currentPlayer.value || isUpdating.value) {
    router.push('/home')
    return
  }

  message.value = ''
  isUpdating.value = true

  try {
    await leaveRoomRequest(props.roomId, savedUser.id)
    router.push('/home')
  } catch (error) {
    message.value = error.message
  } finally {
    isUpdating.value = false
  }
}
</script>

<template>
  <section class="page-card room">
    <p class="eyebrow">Game Room #{{ roomId }}</p>

    <template v-if="room">
      <div class="room-heading">
        <div>
          <h1>{{ room.title }}</h1>
          <p>방장 {{ room.hostNickname }}님이 만든 게임 방입니다.</p>
          <p class="room-description">{{ room.description }}</p>
        </div>

        <div v-if="currentPlayer" class="room-actions">
          <button
            v-if="isHost"
            type="button"
            :disabled="isUpdating || !canStartGame || room.status !== 'waiting'"
            @click="startGame"
          >
            게임 시작
          </button>
          <button v-if="isHost" type="button" :disabled="isUpdating" @click="openEditRoomForm">
            방 정보 수정
          </button>
          <button type="button" :disabled="isUpdating" @click="toggleReady">
            {{ currentPlayer.isReady ? '준비 취소' : '준비' }}
          </button>
          <button type="button" :disabled="isUpdating" @click="leaveRoom">방 나가기</button>
        </div>
      </div>

      <form v-if="isEditingRoom" class="edit-room-form" @submit.prevent="saveRoomInfo">
        <label>
          방 제목
          <input v-model="editRoomTitle" type="text" placeholder="방 제목" />
        </label>

        <label>
          방 소개
          <textarea v-model="editRoomDescription" rows="4" placeholder="방 소개 내용" />
        </label>

        <div class="edit-actions">
          <button type="submit" :disabled="isUpdating">
            {{ isUpdating ? '저장 중...' : '저장' }}
          </button>
          <button type="button" :disabled="isUpdating" @click="closeEditRoomForm">취소</button>
        </div>
      </form>

      <div class="room-grid">
        <article>
          <strong>현재 페이즈</strong>
          <span>{{ room.phase }}</span>
        </article>
        <article>
          <strong>참가자</strong>
          <span>{{ players.length }} / {{ room.maxPlayers }}</span>
        </article>
        <article>
          <strong>상태</strong>
          <span>{{ room.status === 'waiting' ? '대기 중' : room.status }}</span>
        </article>
      </div>

      <div class="players">
        <div class="players-heading">
          <h2>참가 플레이어</h2>
          <span v-if="lastSyncedAt">
            {{ canStartGame ? '모든 플레이어 준비 완료' : '자동 갱신 중' }}
          </span>
        </div>
        <ul>
          <li v-for="player in players" :key="player.userId">
            <div>
              <strong>{{ player.nickname }}</strong>
              <span>User ID: {{ player.userId }}</span>
            </div>
            <div class="badges">
              <span v-if="player.isHost">방장</span>
              <span :class="{ ready: player.isReady }">
                {{ player.isReady ? '준비 완료' : '대기 중' }}
              </span>
            </div>
          </li>
        </ul>
      </div>
    </template>

    <p v-else-if="isLoading">방 정보를 불러오는 중입니다.</p>
    <p v-if="message" class="message">{{ message }}</p>
  </section>
</template>

<style scoped>
.room {
  display: grid;
  gap: 1rem;
}

.eyebrow {
  color: var(--color-accent);
  font-weight: 800;
}

.room-heading {
  align-items: flex-start;
  display: flex;
  gap: 1rem;
  justify-content: space-between;
}

h1 {
  color: var(--color-heading);
  font-size: 3rem;
  font-weight: 900;
}

.room-actions {
  display: flex;
  flex-wrap: wrap;
  gap: 0.6rem;
}

.edit-room-form {
  background: rgba(255, 255, 255, 0.06);
  border: 1px solid var(--color-border);
  border-radius: 1rem;
  display: grid;
  gap: 0.9rem;
  padding: 1rem;
}

.edit-room-form label {
  display: grid;
  gap: 0.4rem;
  font-weight: 800;
}

.edit-room-form input,
.edit-room-form textarea {
  background: rgba(255, 255, 255, 0.08);
  border: 1px solid var(--color-border);
  border-radius: 0.8rem;
  color: var(--color-text);
  font: inherit;
  padding: 0.8rem 1rem;
  resize: vertical;
}

.edit-actions {
  display: flex;
  flex-wrap: wrap;
  gap: 0.6rem;
}

.room-description {
  color: rgba(255, 245, 224, 0.7);
  margin-top: 0.5rem;
  max-width: 42rem;
}

button {
  background: var(--color-accent);
  border: 0;
  border-radius: 0.8rem;
  color: #14110f;
  cursor: pointer;
  font-weight: 900;
  padding: 0.75rem 1rem;
}

button + button {
  background: transparent;
  border: 1px solid var(--color-border);
  color: var(--color-text);
}

button:disabled {
  cursor: wait;
  opacity: 0.7;
}

.room-grid {
  display: grid;
  gap: 1rem;
  grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
  margin-top: 1rem;
}

article,
.players {
  background: rgba(255, 255, 255, 0.08);
  border: 1px solid var(--color-border);
  border-radius: 1rem;
  display: grid;
  gap: 0.35rem;
  padding: 1rem;
}

.players-heading {
  align-items: center;
  display: flex;
  gap: 1rem;
  justify-content: space-between;
}

.players-heading span {
  color: rgba(255, 245, 224, 0.58);
  font-size: 0.85rem;
}

strong,
h2 {
  color: var(--color-heading);
}

ul {
  display: grid;
  gap: 0.75rem;
  list-style: none;
  padding: 0;
}

li {
  align-items: center;
  border-top: 1px solid var(--color-border);
  display: flex;
  gap: 1rem;
  justify-content: space-between;
  padding-top: 0.75rem;
}

li div:first-child {
  display: grid;
  gap: 0.2rem;
}

li span {
  color: rgba(255, 245, 224, 0.64);
  font-size: 0.9rem;
}

.badges {
  display: flex;
  flex-wrap: wrap;
  gap: 0.5rem;
  justify-content: flex-end;
}

.badges span {
  border: 1px solid var(--color-border);
  border-radius: 999px;
  padding: 0.35rem 0.65rem;
}

.badges .ready {
  border-color: var(--color-accent);
  color: var(--color-accent);
}

.message {
  color: #ff8f70;
  font-weight: 700;
}

@media (max-width: 760px) {
  .room-heading,
  li {
    align-items: flex-start;
    flex-direction: column;
  }

  .badges {
    justify-content: flex-start;
  }
}
</style>
