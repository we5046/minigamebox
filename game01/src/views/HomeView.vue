<script setup>
import { computed, onBeforeUnmount, onMounted, ref } from 'vue'
import { useRouter } from 'vue-router'
import { logoutUser } from '@/api/authApi'
import { getCurrentUser } from '@/api/session'
import { supabase } from '@/api/supabaseClient'
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
const ROOMS_PER_PAGE = 5
const currentRoomPage = ref(1)
const selectedRoomId = ref(null)
const presenceUsers = ref([])
const publicChatDraft = ref('')
const publicChatNotice = ref('')
const publicChatPreviewMessages = ref([
  {
    id: 'welcome',
    nickname: 'System',
    content: '공용 채팅방이 준비되었습니다. 다음 단계에서 Supabase Realtime을 연결합니다.',
    createdAt: '방금 전',
    isSystem: true,
  },
])
let unsubscribeRooms = null
let fallbackPollingId = null
let lobbyPresenceChannel = null

const character = computed(() => ({
  loginId: savedUser?.loginId || 'guest',
  nickname: savedUser?.nickname || 'GuestPlayer',
  title: savedUser?.character?.name || 'Rookie Mafia',
  coin: savedUser?.character?.coin || 0,
  winRate: '0%',
}))

const roomDerivedUsers = computed(() => {
  const userMap = new Map()

  if (savedUser) {
    userMap.set(savedUser.id, {
      id: savedUser.id,
      nickname: savedUser.nickname,
      status: '로비',
    })
  }

  rooms.value.forEach((room) => {
    room.players?.forEach((player) => {
      if (!userMap.has(player.userId)) {
        userMap.set(player.userId, {
          id: player.userId,
          nickname: player.nickname,
          status: room.title,
        })
      }
    })
  })

  if (userMap.size === 0) {
    userMap.set('guest', {
      id: 'guest',
      nickname: 'GuestPlayer',
      status: '로비',
    })
  }

  return Array.from(userMap.values())
})

const onlineUsers = computed(() => {
  return presenceUsers.value.length > 0 ? presenceUsers.value : roomDerivedUsers.value
})

const waitingRoomCount = computed(() => {
  return rooms.value.filter((room) => room.status === 'waiting').length
})

const roomPageCount = computed(() => {
  return Math.max(1, Math.ceil(rooms.value.length / ROOMS_PER_PAGE))
})

const paginatedRooms = computed(() => {
  const startIndex = (currentRoomPage.value - 1) * ROOMS_PER_PAGE
  return rooms.value.slice(startIndex, startIndex + ROOMS_PER_PAGE)
})

const quickJoinPath = computed(() => {
  return rooms.value.length > 0 ? `/rooms/${rooms.value[0].id}` : '/home'
})

onMounted(() => {
  fetchRooms()
  setupLobbyPresence()
  unsubscribeRooms = subscribeToRooms(() => {
    syncRooms()
  })
  fallbackPollingId = window.setInterval(() => {
    syncRooms()
  }, 2000)
})

onBeforeUnmount(() => {
  unsubscribeRooms?.()
  lobbyPresenceChannel?.untrack?.()
  if (lobbyPresenceChannel) {
    supabase.removeChannel(lobbyPresenceChannel)
  }
  window.clearInterval(fallbackPollingId)
})

async function fetchRooms() {
  roomMessage.value = ''
  isLoadingRooms.value = true

  try {
    rooms.value = await getRooms()
    clampRoomPage()
    clampSelectedRoom()
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
    clampRoomPage()
    clampSelectedRoom()
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
    currentRoomPage.value = 1
    router.push(`/rooms/${createdRoom.id}`)
  } catch (error) {
    roomMessage.value = error.message
  } finally {
    isCreatingRoom.value = false
  }
}

function clampRoomPage() {
  if (currentRoomPage.value > roomPageCount.value) {
    currentRoomPage.value = roomPageCount.value
  }
}

function clampSelectedRoom() {
  if (selectedRoomId.value && !rooms.value.some((room) => room.id === selectedRoomId.value)) {
    selectedRoomId.value = null
  }
}

function goToPreviousRoomPage() {
  currentRoomPage.value = Math.max(1, currentRoomPage.value - 1)
  selectedRoomId.value = null
}

function goToNextRoomPage() {
  currentRoomPage.value = Math.min(roomPageCount.value, currentRoomPage.value + 1)
  selectedRoomId.value = null
}

function setupLobbyPresence() {
  const presenceKey = savedUser?.id || `guest-${Math.random().toString(36).slice(2)}`

  lobbyPresenceChannel = supabase.channel('lobby-presence', {
    config: {
      presence: {
        key: presenceKey,
      },
    },
  })

  lobbyPresenceChannel
    .on('presence', { event: 'sync' }, () => {
      const state = lobbyPresenceChannel.presenceState()
      presenceUsers.value = Object.entries(state).map(([id, presences]) => {
        const latestPresence = presences[presences.length - 1]

        return {
          id,
          nickname: latestPresence.nickname || 'GuestPlayer',
          status: latestPresence.status || '로비',
        }
      })
    })
    .subscribe(async (status) => {
      if (status !== 'SUBSCRIBED') {
        return
      }

      await lobbyPresenceChannel.track({
        nickname: character.value.nickname,
        status: '로비',
        onlineAt: new Date().toISOString(),
      })
    })
}

function toggleRoomDetails(roomId) {
  selectedRoomId.value = selectedRoomId.value === roomId ? null : roomId
}

function enterRoom(roomId) {
  router.push(`/rooms/${roomId}`)
}

function submitPublicChatPreview() {
  const content = publicChatDraft.value.trim()

  if (!content) {
    return
  }

  publicChatPreviewMessages.value.push({
    id: `preview-${Date.now()}`,
    nickname: character.value.nickname,
    content,
    createdAt: '방금 전',
    isSystem: false,
  })
  publicChatDraft.value = ''
  publicChatNotice.value = '지금은 UI 미리보기입니다. 다음 단계에서 Supabase Realtime으로 저장/동기화됩니다.'
}

async function logout() {
  await logoutUser()
  router.push('/login')
}
</script>

<template>
  <section class="lobby-layout">
    <header class="page-card lobby-hero">
      <div>
        <p class="eyebrow">Main Lobby</p>
        <h1>마피아 게임 로비</h1>
        <p>방을 찾고, 플레이어와 대화하고, 새 게임을 여는 중심 화면입니다.</p>
      </div>

    </header>

    <div class="lobby-content">
      <main class="main-panel">
        <section class="page-card room-board" aria-labelledby="room-board-title">
          <div class="section-heading">
            <div>
              <p class="eyebrow">Rooms</p>
              <h2 id="room-board-title">게임 방 목록</h2>
              <div class="room-summary">
                <span>전체 {{ rooms.length }}</span>
                <span>대기 {{ waitingRoomCount }}</span>
              </div>
            </div>
            <div class="room-tools">
              <div class="room-actions">
                <RouterLink class="primary" :to="quickJoinPath">빠른 입장</RouterLink>
                <button type="button" @click="isCreateFormOpen = true">방 만들기</button>
              </div>
            </div>
          </div>

          <div class="room-table-header" aria-hidden="true">
            <span>입장</span>
            <span>방 번호</span>
            <span>방 제목</span>
            <span>방장</span>
            <span>인원</span>
            <span>상태</span>
          </div>

          <div class="room-table">
            <p v-if="roomMessage" class="message">{{ roomMessage }}</p>
            <p v-else-if="isLoadingRooms" class="muted">방 목록을 불러오는 중입니다.</p>
            <p v-else-if="rooms.length === 0" class="muted">아직 생성된 방이 없습니다.</p>

            <article
              v-for="room in paginatedRooms"
              :key="room.id"
              class="room-entry"
              :class="{ expanded: selectedRoomId === room.id }"
            >
              <div
                class="room-row"
                role="button"
                tabindex="0"
                @click="toggleRoomDetails(room.id)"
                @keydown.enter.prevent="toggleRoomDetails(room.id)"
                @keydown.space.prevent="toggleRoomDetails(room.id)"
              >
                <button class="join-pill" type="button" @click.stop="enterRoom(room.id)">
                  입장
                </button>
                <span>#{{ room.id }}</span>
                <strong>
                  {{ room.title }}
                  <small>{{ room.description }}</small>
                </strong>
                <span>{{ room.hostNickname }}</span>
                <span>{{ room.players?.length || room.currentPlayers }} / {{ room.maxPlayers }}</span>
                <span>{{ room.status === 'waiting' ? '대기 중' : room.status }}</span>
              </div>

              <div v-if="selectedRoomId === room.id" class="room-details">
                <div class="room-details-heading">
                  <strong>참여 인원</strong>
                  <span>{{ room.players?.length || 0 }} / {{ room.maxPlayers }}</span>
                </div>

                <ul v-if="room.players?.length">
                  <li v-for="player in room.players" :key="player.userId">
                    <span>{{ player.nickname }}</span>
                    <small>{{ player.isHost ? '방장' : player.isReady ? '준비 완료' : '대기 중' }}</small>
                  </li>
                </ul>
                <p v-else class="muted">아직 입장한 플레이어가 없습니다.</p>
              </div>
            </article>
          </div>

          <div v-if="rooms.length > ROOMS_PER_PAGE" class="room-pagination" aria-label="Room pages">
            <button
              type="button"
              :disabled="currentRoomPage === 1"
              @click="goToPreviousRoomPage"
            >
              이전
            </button>
            <span>{{ currentRoomPage }} / {{ roomPageCount }}</span>
            <button
              type="button"
              :disabled="currentRoomPage === roomPageCount"
              @click="goToNextRoomPage"
            >
              다음
            </button>
          </div>
        </section>

        <section v-if="isCreateFormOpen" class="page-card create-room-panel">
          <div class="section-heading">
            <div>
              <p class="eyebrow">Create</p>
              <h2>새 게임방</h2>
            </div>
            <button type="button" @click="isCreateFormOpen = false">닫기</button>
          </div>

          <form class="create-room-form" @submit.prevent="createRoom">
            <label>
              방 제목
              <input v-model="newRoomTitle" type="text" placeholder="예: 초보 환영 마피아 방" />
            </label>

            <label>
              방 소개
              <textarea
                v-model="newRoomDescription"
                rows="3"
                placeholder="방 규칙, 플레이 분위기, 모집 인원 등을 적어주세요."
              />
            </label>

            <label>
              참가 인원
              <input v-model.number="newRoomMaxPlayers" type="number" min="2" max="12" />
            </label>

            <button type="submit" :disabled="isCreatingRoom">
              {{ isCreatingRoom ? '생성 중...' : '방 생성' }}
            </button>
          </form>
        </section>

        <section class="page-card chat-card" aria-labelledby="public-chat-title">
          <div class="section-heading">
            <div>
              <p class="eyebrow">Public Chat</p>
              <h2 id="public-chat-title">공용 채팅방</h2>
            </div>
            <span class="chat-status">UI 준비</span>
          </div>

          <div class="chat-log" aria-live="polite">
            <article
              v-for="chat in publicChatPreviewMessages"
              :key="chat.id"
              class="chat-line"
              :class="{ system: chat.isSystem }"
            >
              <strong>{{ chat.nickname }}</strong>
              <p>{{ chat.content }}</p>
              <time>{{ chat.createdAt }}</time>
            </article>
          </div>

          <p v-if="publicChatNotice" class="chat-notice">{{ publicChatNotice }}</p>

          <form class="chat-form" @submit.prevent="submitPublicChatPreview">
            <input
              v-model="publicChatDraft"
              type="text"
              maxlength="200"
              placeholder="공용 채팅 메시지"
            />
            <button type="submit">전송</button>
            <button type="button" @click="logout">로그아웃</button>
          </form>
        </section>
      </main>

      <aside class="side-panel">
        <section id="my-page" class="page-card profile-card">
          <p class="eyebrow">My Character</p>
          <div class="profile-main">
            <div class="avatar" aria-hidden="true">M</div>
            <div>
              <h2>{{ character.nickname }}</h2>
              <p>{{ character.title }}</p>
            </div>
          </div>
          <dl>
            <div>
              <dt>Login ID</dt>
              <dd>{{ character.loginId }}</dd>
            </div>
            <div>
              <dt>Coin</dt>
              <dd>{{ character.coin }}</dd>
            </div>
            <div>
              <dt>Win Rate</dt>
              <dd>{{ character.winRate }}</dd>
            </div>
          </dl>
        </section>

        <section class="page-card visitor-card" aria-labelledby="visitor-title">
          <div class="section-heading compact">
            <div>
              <p class="eyebrow">Online</p>
              <h2 id="visitor-title">접속 유저</h2>
            </div>
            <span class="user-count">{{ onlineUsers.length }}</span>
          </div>

          <ul>
            <li v-for="user in onlineUsers" :key="user.id">
              <strong>{{ user.nickname }}</strong>
              <span>{{ user.status }}</span>
            </li>
          </ul>
        </section>
      </aside>
    </div>
  </section>
</template>

<style scoped>
.lobby-layout {
  --side-panel-width: clamp(17.5rem, 26vw, 20rem);
  --lobby-gap: clamp(0.75rem, 1.4vw, 1rem);
  display: grid;
  gap: var(--lobby-gap);
  min-width: 0;
}

.lobby-layout :deep(.page-card),
.lobby-layout .page-card {
  border-radius: clamp(1rem, 2vw, 1.6rem);
  padding: clamp(1rem, 2.4vw, 2rem);
}

.lobby-hero {
  align-items: end;
  display: grid;
  gap: clamp(1rem, 2vw, 1.5rem);
  grid-template-columns: minmax(0, 1fr);
  min-width: 0;
}

.eyebrow {
  color: var(--color-accent);
  font-weight: 800;
  letter-spacing: 0.08em;
  text-transform: uppercase;
}

h1,
h2 {
  color: var(--color-heading);
  font-weight: 900;
}

h1 {
  font-size: clamp(2.2rem, 6vw, 5.4rem);
  letter-spacing: -0.06em;
  line-height: 0.92;
  margin-top: 0.5rem;
  overflow-wrap: anywhere;
}

h2 {
  font-size: clamp(1.15rem, 2vw, 1.45rem);
  overflow-wrap: anywhere;
}

.hero-actions,
.room-actions {
  display: flex;
  flex-wrap: wrap;
  gap: 0.65rem;
  justify-content: flex-end;
}

.hero-actions a,
.hero-actions button,
.room-actions a,
.room-actions button,
.section-heading button,
.chat-form button,
.room-pagination button {
  background: transparent;
  border: 1px solid var(--color-border);
  border-radius: 0.75rem;
  color: var(--color-text);
  cursor: pointer;
  font: inherit;
  min-height: 2.75rem;
  padding: 0.75rem 1rem;
  white-space: nowrap;
}

.room-pagination button:disabled {
  cursor: not-allowed;
  opacity: 0.45;
}

.hero-actions .primary,
.room-actions .primary {
  background: var(--color-accent);
  border-color: var(--color-accent);
  color: #14110f;
  font-weight: 900;
}

.lobby-content {
  align-items: start;
  display: grid;
  gap: var(--lobby-gap);
  grid-template-columns: minmax(0, 1fr) var(--side-panel-width);
  min-width: 0;
}

.main-panel,
.side-panel {
  display: grid;
  gap: var(--lobby-gap);
  min-width: 0;
}

.side-panel {
  position: sticky;
  top: 1rem;
}

.section-heading {
  align-items: center;
  display: flex;
  flex-wrap: wrap;
  gap: 1rem;
  justify-content: space-between;
  min-width: 0;
}

.section-heading.compact {
  align-items: flex-start;
}

.room-summary,
.room-tools,
.chat-status,
.user-count {
  align-items: center;
  display: flex;
  flex-wrap: wrap;
  gap: 0.5rem;
}

.room-tools {
  justify-content: flex-end;
}

.room-summary span,
.chat-status,
.user-count {
  background: rgba(255, 190, 85, 0.12);
  border: 1px solid rgba(255, 190, 85, 0.28);
  border-radius: 999px;
  color: var(--color-accent);
  font-size: 0.82rem;
  font-weight: 800;
  padding: 0.35rem 0.65rem;
  white-space: nowrap;
}

.room-board {
  display: grid;
  gap: 0.9rem;
  min-width: 0;
}

.room-table-header,
.room-row {
  display: grid;
  gap: 0.8rem;
  grid-template-columns: 4.25rem 5rem minmax(10rem, 1fr) minmax(5.5rem, 7rem) 4.75rem 5.75rem;
  min-width: 0;
}

.room-table-header {
  border-bottom: 1px solid var(--color-border);
  color: rgba(255, 245, 224, 0.66);
  font-size: 0.86rem;
  font-weight: 800;
  padding: 0 0.25rem 0.65rem;
}

.room-table {
  --room-row-gap: 0.55rem;
  --room-row-height: 4.75rem;
  align-content: start;
  display: grid;
  gap: var(--room-row-gap);
  min-height: calc((var(--room-row-height) * 5) + (var(--room-row-gap) * 4));
  min-width: 0;
}

.room-pagination {
  align-items: center;
  display: flex;
  flex-wrap: wrap;
  gap: 0.65rem;
  justify-content: flex-end;
}

.room-pagination span {
  color: var(--color-heading);
  font-weight: 900;
  min-width: 4rem;
  text-align: center;
}

.room-entry {
  display: grid;
  gap: 0.55rem;
  min-width: 0;
}

.room-row {
  align-items: center;
  background: rgba(255, 255, 255, 0.07);
  border: 1px solid var(--color-border);
  border-radius: 0.8rem;
  color: var(--color-text);
  cursor: pointer;
  display: grid;
  font: inherit;
  gap: 0.8rem;
  grid-template-columns: 4.25rem 5rem minmax(10rem, 1fr) minmax(5.5rem, 7rem) 4.75rem 5.75rem;
  min-height: var(--room-row-height);
  padding: 0.8rem;
  min-width: 0;
}

.room-row > span {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.room-row:hover {
  border-color: var(--color-border-hover);
  background: rgba(255, 255, 255, 0.1);
}

.room-row:focus-visible {
  outline: 2px solid var(--color-accent);
  outline-offset: 3px;
}

.join-pill {
  background: var(--color-accent);
  border: 0;
  border-radius: 999px;
  color: #14110f;
  cursor: pointer;
  font: inherit;
  font-size: 0.82rem;
  font-weight: 900;
  justify-self: start;
  padding: 0.25rem 0.55rem;
}

.room-details {
  background: rgba(255, 190, 85, 0.08);
  border: 1px solid rgba(255, 190, 85, 0.2);
  border-radius: 0.85rem;
  display: grid;
  gap: 0.7rem;
  padding: 0.8rem;
}

.room-details-heading,
.room-details li {
  align-items: center;
  display: flex;
  gap: 0.75rem;
  justify-content: space-between;
}

.room-details-heading strong,
.room-details li span {
  color: var(--color-heading);
  font-weight: 900;
}

.room-details ul {
  display: grid;
  gap: 0.5rem;
  list-style: none;
  margin: 0;
  padding: 0;
}

.room-details li {
  background: rgba(20, 17, 15, 0.36);
  border: 1px solid var(--color-border);
  border-radius: 0.7rem;
  padding: 0.55rem 0.65rem;
}

.room-details small,
.room-details-heading span {
  color: rgba(255, 245, 224, 0.62);
}

.room-row strong {
  color: var(--color-heading);
  display: grid;
  font-weight: 900;
  min-width: 0;
}

.room-row small {
  color: rgba(255, 245, 224, 0.56);
  font-size: 0.82rem;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.message {
  color: #ff8f70;
  font-weight: 800;
}

.muted,
.sync-label,
.chat-notice {
  color: rgba(255, 245, 224, 0.58);
  font-size: 0.9rem;
}

.create-room-panel,
.chat-card,
.profile-card,
.visitor-card {
  display: grid;
  gap: 0.9rem;
  min-width: 0;
}

.create-room-form {
  display: grid;
  gap: 0.75rem;
  grid-template-columns: minmax(10rem, 1fr) minmax(14rem, 1.35fr) minmax(7rem, 0.45fr) auto;
  min-width: 0;
}

.create-room-form label {
  display: grid;
  gap: 0.35rem;
  font-weight: 800;
}

.create-room-form input,
.create-room-form textarea,
.chat-form input {
  background: rgba(255, 255, 255, 0.08);
  border: 1px solid var(--color-border);
  border-radius: 0.75rem;
  color: var(--color-text);
  font: inherit;
  min-width: 0;
  padding: 0.75rem 0.9rem;
  resize: vertical;
  width: 100%;
}

.create-room-form button {
  align-self: end;
  background: var(--color-accent);
  border: 0;
  border-radius: 0.75rem;
  color: #14110f;
  cursor: pointer;
  font-weight: 900;
  padding: 0.8rem 1rem;
}

.chat-log {
  background: rgba(255, 190, 85, 0.08);
  border: 1px solid rgba(255, 190, 85, 0.18);
  border-radius: 1rem;
  display: flex;
  flex-direction: column;
  gap: 0.55rem;
  height: clamp(13rem, 28vh, 19rem);
  overflow-y: auto;
  padding: 0.85rem;
  min-width: 0;
}

.chat-line {
  align-items: baseline;
  background: rgba(20, 17, 15, 0.46);
  border: 1px solid transparent;
  border-radius: 0.75rem;
  display: grid;
  gap: 0.7rem;
  grid-template-columns: minmax(4rem, auto) minmax(0, 1fr) auto;
  padding: 0.65rem 0.75rem;
  min-width: 0;
}

.chat-line.system {
  border-color: rgba(255, 190, 85, 0.25);
}

.chat-line strong {
  color: var(--color-heading);
  font-weight: 900;
}

.chat-line p {
  margin: 0;
  overflow-wrap: anywhere;
}

.chat-line time {
  color: rgba(255, 245, 224, 0.48);
  font-size: 0.78rem;
  white-space: nowrap;
}

.chat-form {
  display: grid;
  gap: 0.6rem;
  grid-template-columns: minmax(12rem, 1fr) auto auto;
  min-width: 0;
}

.chat-form button[type='submit'] {
  background: var(--color-accent);
  border-color: var(--color-accent);
  color: #14110f;
  font-weight: 900;
}

.profile-main {
  align-items: center;
  display: flex;
  gap: 0.9rem;
  min-width: 0;
}

.avatar {
  align-items: center;
  background: linear-gradient(135deg, #ffbe55, #8f2115);
  border-radius: 1rem;
  color: #14110f;
  display: flex;
  flex: 0 0 auto;
  font-size: 2rem;
  font-weight: 900;
  height: 4.5rem;
  justify-content: center;
  width: 4.5rem;
}

dl {
  display: grid;
  gap: 0.55rem;
  margin: 0;
}

dl div {
  border-top: 1px solid var(--color-border);
  display: flex;
  justify-content: space-between;
  gap: 1rem;
  padding-top: 0.55rem;
}

dt {
  color: rgba(255, 245, 224, 0.58);
}

dd {
  color: var(--color-heading);
  font-weight: 800;
  margin: 0;
}

.visitor-card ul {
  display: grid;
  gap: 0.55rem;
  list-style: none;
  margin: 0;
  max-height: 17rem;
  overflow-y: auto;
  padding: 0;
  min-width: 0;
}

.visitor-card li {
  align-items: center;
  background: rgba(255, 255, 255, 0.07);
  border: 1px solid var(--color-border);
  border-radius: 0.75rem;
  display: flex;
  justify-content: space-between;
  gap: 0.75rem;
  padding: 0.7rem 0.75rem;
  min-width: 0;
}

.visitor-card strong {
  color: var(--color-heading);
  font-weight: 900;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.visitor-card span {
  color: rgba(255, 245, 224, 0.58);
  font-size: 0.82rem;
  white-space: nowrap;
}

@media (max-width: 1180px) {
  .lobby-content {
    grid-template-columns: 1fr;
  }

  .side-panel {
    position: static;
    grid-template-columns: 1fr 1fr;
  }

  .room-table-header,
  .room-row {
    grid-template-columns: 4.25rem 5rem minmax(12rem, 1fr) minmax(6rem, 8rem) 5rem 6rem;
  }
}

@media (max-width: 980px) {
  .lobby-hero {
    align-items: start;
    grid-template-columns: 1fr;
  }

  .hero-actions {
    justify-content: flex-start;
  }

  .room-tools,
  .room-actions {
    justify-content: flex-start;
  }

  .create-room-form {
    grid-template-columns: minmax(0, 1fr) minmax(0, 1fr);
  }

  .create-room-form label:nth-child(2) {
    grid-column: 1 / -1;
  }

  .create-room-form button {
    align-self: stretch;
  }

  .chat-form {
    grid-template-columns: minmax(0, 1fr) auto auto;
  }

  .chat-form input {
    grid-column: 1 / -1;
  }
}

@media (max-width: 820px) {
  .room-table-header {
    display: none;
  }

  .room-row {
    align-items: stretch;
    gap: 0.55rem;
    grid-template-columns: minmax(0, 1fr) auto;
    min-height: var(--room-row-height);
  }

  .room-row .join-pill {
    grid-column: 2;
    grid-row: 1;
  }

  .room-row > span:nth-child(2) {
    color: rgba(255, 245, 224, 0.55);
    font-size: 0.82rem;
    grid-column: 1;
    grid-row: 1;
  }

  .room-row strong {
    grid-column: 1 / -1;
  }

  .room-row > span:nth-child(4),
  .room-row > span:nth-child(5),
  .room-row > span:nth-child(6) {
    background: rgba(255, 255, 255, 0.07);
    border-radius: 999px;
    justify-self: start;
    padding: 0.28rem 0.55rem;
  }

  .room-details-heading,
  .room-details li {
    align-items: flex-start;
    flex-direction: column;
  }
}

@media (max-width: 680px) {
  .lobby-layout {
    gap: 0.75rem;
  }

  .room-row,
  .create-room-form,
  .chat-line,
  .chat-form,
  .side-panel {
    grid-template-columns: 1fr;
  }

  .hero-actions,
  .room-actions,
  .section-heading {
    align-items: flex-start;
    flex-direction: column;
  }

  .hero-actions,
  .hero-actions a,
  .hero-actions button,
  .room-actions,
  .room-actions a,
  .room-actions button,
  .chat-form button,
  .room-pagination,
  .room-pagination button {
    width: 100%;
  }

  .room-summary {
    width: 100%;
  }

  .room-pagination span {
    width: 100%;
  }

  .chat-line {
    align-items: start;
  }

  .chat-line time {
    white-space: normal;
  }

  .visitor-card li,
  dl div {
    align-items: flex-start;
    flex-direction: column;
  }
}

@media (max-width: 420px) {
  .lobby-layout .page-card {
    padding: 0.9rem;
  }

  h1 {
    font-size: 2rem;
  }

  .avatar {
    height: 3.75rem;
    width: 3.75rem;
  }
}
</style>
