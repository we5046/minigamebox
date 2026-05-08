<script setup>
import { computed, onBeforeUnmount, onMounted, ref } from 'vue'
import { useRouter } from 'vue-router'
import { logoutUser } from '@/api/authApi'
import { getCurrentUser } from '@/api/session'
import {
  createRoom as createRoomRequest,
  getRooms,
  subscribeToRooms,
} from '@/api/roomApi'

const router = useRouter()
const savedUser = getCurrentUser()
const rooms = ref([])
const roomMessage = ref('')
const isLoadingRooms = ref(false)
const isCreatingRoom = ref(false)
const isCreateFormOpen = ref(false)
const newRoomTitle = ref('')
const newRoomDescription = ref('')
const newRoomMaxPlayers = ref(8)
const lastSyncedAt = ref(null)
let unsubscribeRooms = null
let fallbackPollingId = null

const character = computed(() => ({
  loginId: savedUser?.loginId || 'guest',
  nickname: savedUser?.nickname || 'GuestPlayer',
  title: savedUser?.character?.name || 'Rookie Mafia',
  coin: savedUser?.character?.coin || 0,
  winRate: '0%',
}))

const quickJoinPath = computed(() => {
  return rooms.value.length > 0 ? `/rooms/${rooms.value[0].id}` : '/home'
})

onMounted(() => {
  fetchRooms()
  unsubscribeRooms = subscribeToRooms(() => {
    syncRooms()
  })
  fallbackPollingId = window.setInterval(() => {
    syncRooms()
  }, 2000)
})

onBeforeUnmount(() => {
  unsubscribeRooms?.()
  window.clearInterval(fallbackPollingId)
})

async function fetchRooms() {
  roomMessage.value = ''
  isLoadingRooms.value = true

  try {
    rooms.value = await getRooms()
    lastSyncedAt.value = new Date()
  } catch (error) {
    roomMessage.value = error.message
  } finally {
    isLoadingRooms.value = false
  }
}

async function syncRooms() {
  if (isCreatingRoom.value) {
    return
  }

  try {
    rooms.value = await getRooms()
    lastSyncedAt.value = new Date()
    roomMessage.value = ''
  } catch (error) {
    roomMessage.value = error.message
  }
}

async function createRoom() {
  roomMessage.value = ''

  if (!savedUser) {
    roomMessage.value = '로그인 후 방을 만들 수 있습니다.'
    router.push('/login')
    return
  }

  if (!newRoomTitle.value.trim()) {
    roomMessage.value = '방 제목을 입력하세요.'
    return
  }

  if (!newRoomDescription.value.trim()) {
    roomMessage.value = '방 소개 내용을 입력하세요.'
    return
  }

  if (newRoomMaxPlayers.value < 2 || newRoomMaxPlayers.value > 12) {
    roomMessage.value = '참가 인원은 2명 이상 12명 이하로 설정하세요.'
    return
  }

  isCreatingRoom.value = true

  try {
    const createdRoom = await createRoomRequest({
      hostUser: savedUser,
      title: newRoomTitle.value,
      description: newRoomDescription.value,
      maxPlayers: Number(newRoomMaxPlayers.value),
    })
    newRoomTitle.value = ''
    newRoomDescription.value = ''
    newRoomMaxPlayers.value = 8
    isCreateFormOpen.value = false
    rooms.value = [createdRoom, ...rooms.value]
    router.push(`/rooms/${createdRoom.id}`)
  } catch (error) {
    roomMessage.value = error.message
  } finally {
    isCreatingRoom.value = false
  }
}

async function logout() {
  await logoutUser()
  router.push('/login')
}
</script>

<template>
  <section class="home-layout">
    <div class="page-card hero">
      <p class="eyebrow">Main Home</p>
      <h1>마피아 게임 로비</h1>
      <p>생성된 방을 확인하고, 내 캐릭터 상태를 간단히 볼 수 있는 홈입니다.</p>

      <div class="actions">
        <RouterLink class="primary" :to="quickJoinPath">빠른 입장</RouterLink>
        <RouterLink to="/shop">상점으로 가기</RouterLink>
        <button type="button" @click="logout">로그아웃</button>
      </div>
    </div>

    <aside class="page-card character-card">
      <p class="eyebrow">My Character</p>
      <div class="avatar" aria-hidden="true">M</div>
      <h2>{{ character.nickname }}</h2>
      <p>{{ character.title }}</p>
      <p class="login-id">Login ID: {{ character.loginId }}</p>

      <dl>
        <div>
          <dt>Coin</dt>
          <dd>{{ character.coin }}</dd>
        </div>
        <div>
          <dt>Win Rate</dt>
          <dd>{{ character.winRate }}</dd>
        </div>
      </dl>
    </aside>

    <div class="page-card room-list">
      <div class="section-heading">
        <div>
          <p class="eyebrow">Rooms</p>
          <h2>생성된 방</h2>
          <span v-if="lastSyncedAt" class="sync-label">자동 갱신 중</span>
        </div>
        <button type="button" @click="isCreateFormOpen = !isCreateFormOpen">
          {{ isCreateFormOpen ? '닫기' : '방 만들기' }}
        </button>
      </div>

      <p v-if="roomMessage" class="message">{{ roomMessage }}</p>
      <form v-if="isCreateFormOpen" class="create-room-form" @submit.prevent="createRoom">
        <label>
          방 제목
          <input v-model="newRoomTitle" type="text" placeholder="예: 초보 환영 마피아 방" />
        </label>

        <label>
          방 소개
          <textarea
            v-model="newRoomDescription"
            rows="4"
            placeholder="방 규칙, 플레이 분위기, 모집 인원 등을 적어주세요."
          />
        </label>

        <label>
          참가 인원 제한
          <input v-model.number="newRoomMaxPlayers" type="number" min="2" max="12" />
        </label>

        <button type="submit" :disabled="isCreatingRoom">
          {{ isCreatingRoom ? '생성 중...' : '작성한 내용으로 방 생성' }}
        </button>
      </form>
      <p v-else-if="isLoadingRooms" class="muted">방 목록을 불러오는 중입니다.</p>
      <p v-else-if="rooms.length === 0" class="muted">아직 생성된 방이 없습니다.</p>

      <RouterLink
        v-for="room in rooms"
        :key="room.id"
        class="room-item"
        :to="`/rooms/${room.id}`"
      >
        <strong>
          {{ room.title }}
          <small>{{ room.description }}</small>
        </strong>
        <span>{{ room.status === 'waiting' ? '대기 중' : room.status }}</span>
        <span>{{ room.players?.length || room.currentPlayers }} / {{ room.maxPlayers }}</span>
        <span>{{ room.phase }}</span>
      </RouterLink>
    </div>
  </section>
</template>

<style scoped>
.home-layout {
  display: grid;
  gap: 1rem;
  grid-template-columns: minmax(0, 1.5fr) minmax(260px, 0.8fr);
}

.hero {
  display: grid;
  gap: 1rem;
}

.eyebrow {
  color: var(--color-accent);
  font-weight: 700;
  letter-spacing: 0.08em;
  text-transform: uppercase;
}

h1 {
  color: var(--color-heading);
  font-size: clamp(2.5rem, 8vw, 5.5rem);
  font-weight: 900;
  letter-spacing: -0.08em;
  line-height: 0.9;
}

.actions {
  display: flex;
  flex-wrap: wrap;
  gap: 0.75rem;
}

.actions a,
.actions button,
.section-heading button {
  background: transparent;
  border: 1px solid var(--color-border);
  border-radius: 1rem;
  color: var(--color-text);
  cursor: pointer;
  font: inherit;
  padding: 0.8rem 1rem;
}

.actions .primary {
  background: var(--color-accent);
  border-color: var(--color-accent);
  color: #14110f;
  font-weight: 800;
}

.section-heading button:disabled {
  cursor: wait;
  opacity: 0.7;
}

.create-room-form {
  background: rgba(255, 255, 255, 0.06);
  border: 1px solid var(--color-border);
  border-radius: 1rem;
  display: grid;
  gap: 0.9rem;
  padding: 1rem;
}

.create-room-form label {
  display: grid;
  gap: 0.4rem;
  font-weight: 800;
}

.create-room-form input,
.create-room-form textarea {
  background: rgba(255, 255, 255, 0.08);
  border: 1px solid var(--color-border);
  border-radius: 0.8rem;
  color: var(--color-text);
  font: inherit;
  padding: 0.8rem 1rem;
  resize: vertical;
}

.create-room-form button {
  background: var(--color-accent);
  border: 0;
  border-radius: 0.8rem;
  color: #14110f;
  cursor: pointer;
  font-weight: 900;
  padding: 0.8rem 1rem;
}

.character-card {
  align-content: start;
  display: grid;
  gap: 0.75rem;
}

.avatar {
  align-items: center;
  background: linear-gradient(135deg, #ffbe55, #8f2115);
  border-radius: 1.4rem;
  color: #14110f;
  display: flex;
  font-size: 2.5rem;
  font-weight: 900;
  height: 5.5rem;
  justify-content: center;
  width: 5.5rem;
}

h2 {
  color: var(--color-heading);
  font-size: 1.7rem;
  font-weight: 900;
}

.login-id,
.muted {
  color: rgba(255, 245, 224, 0.58);
  font-size: 0.9rem;
}

.message {
  color: #ff8f70;
  font-weight: 700;
}

.sync-label {
  color: rgba(255, 245, 224, 0.58);
  font-size: 0.85rem;
}

dl {
  display: grid;
  gap: 0.6rem;
  grid-template-columns: repeat(2, 1fr);
  margin-top: 0.5rem;
}

dt {
  color: var(--color-text);
  font-size: 0.8rem;
}

dd {
  color: var(--color-heading);
  font-size: 1.15rem;
  font-weight: 800;
}

.room-list {
  display: grid;
  gap: 0.8rem;
  grid-column: 1 / -1;
}

.section-heading {
  align-items: center;
  display: flex;
  justify-content: space-between;
  gap: 1rem;
}

.room-item {
  align-items: center;
  background: rgba(255, 255, 255, 0.08);
  border: 1px solid var(--color-border);
  border-radius: 1rem;
  color: var(--color-text);
  display: grid;
  gap: 0.8rem;
  grid-template-columns: 1fr repeat(3, auto);
  padding: 1rem;
}

.room-item strong {
  color: var(--color-heading);
  display: grid;
  gap: 0.2rem;
  font-weight: 900;
}

.room-item small {
  color: rgba(255, 245, 224, 0.58);
  font-size: 0.85rem;
  font-weight: 500;
  max-width: 36rem;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

@media (max-width: 820px) {
  .home-layout,
  .room-item {
    grid-template-columns: 1fr;
  }

  .section-heading {
    align-items: flex-start;
    flex-direction: column;
  }
}
</style>
