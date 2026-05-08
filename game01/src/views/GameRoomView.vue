<script setup>
import { computed, onBeforeUnmount, onMounted, ref } from 'vue'
import { useRouter } from 'vue-router'
import { getCurrentUser } from '@/api/session'
import { deleteRoom, getRoom, updateRoom } from '@/api/roomApi'

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
const lastSyncedAt = ref(null)
let pollingId = null

const players = computed(() => room.value?.players || [])
const currentPlayer = computed(() => {
  return players.value.find((player) => player.userId === savedUser?.id)
})

onMounted(() => {
  fetchRoom()
  pollingId = window.setInterval(() => {
    syncRoom()
  }, 2000)
})

onBeforeUnmount(() => {
  window.clearInterval(pollingId)
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

async function patchRoom(payload) {
  room.value = await updateRoom(props.roomId, payload)
  lastSyncedAt.value = new Date()
}

async function joinRoom() {
  if (!room.value || !savedUser) {
    router.push('/login')
    return
  }

  if (players.value.length >= room.value.maxPlayers) {
    message.value = '방 인원이 가득 찼습니다.'
    return
  }

  const joinedAt = new Date().toISOString()
  const nextPlayers = [
    ...players.value,
    {
      userId: savedUser.id,
      nickname: savedUser.nickname,
      isHost: players.value.length === 0,
      isReady: false,
      joinedAt,
    },
  ]

  await patchRoom({
    players: nextPlayers,
    currentPlayers: nextPlayers.length,
  })
}

async function toggleReady() {
  if (!currentPlayer.value || isUpdating.value) {
    return
  }

  message.value = ''
  isUpdating.value = true

  try {
    const nextPlayers = players.value.map((player) =>
      player.userId === savedUser.id ? { ...player, isReady: !player.isReady } : player,
    )

    await patchRoom({
      players: nextPlayers,
      currentPlayers: nextPlayers.length,
    })
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
    let nextPlayers = players.value.filter((player) => player.userId !== savedUser.id)

    if (nextPlayers.length === 0) {
      await deleteRoom(props.roomId)
      router.push('/home')
      return
    }

    if (currentPlayer.value.isHost) {
      nextPlayers = nextPlayers.map((player, index) => ({
        ...player,
        isHost: index === 0,
      }))
    }

    await patchRoom({
      hostUserId: nextPlayers.find((player) => player.isHost)?.userId,
      hostNickname: nextPlayers.find((player) => player.isHost)?.nickname,
      players: nextPlayers,
      currentPlayers: nextPlayers.length,
    })

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
        </div>

        <div v-if="currentPlayer" class="room-actions">
          <button type="button" :disabled="isUpdating" @click="toggleReady">
            {{ currentPlayer.isReady ? '준비 취소' : '준비' }}
          </button>
          <button type="button" :disabled="isUpdating" @click="leaveRoom">방 나가기</button>
        </div>
      </div>

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
          <span v-if="lastSyncedAt">자동 갱신 중</span>
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
