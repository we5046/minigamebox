<script setup>
import { computed, onMounted, ref } from 'vue'
import {
  applyAdminSanction,
  deleteRoomAsAdmin,
  getAdminRooms,
  getAdminUsers,
  revokeAdminSanctions,
  setAdminUserRole,
} from '@/api/adminApi'
import { useToastStore } from '@/stores/toast'

const toastStore = useToastStore()
const users = ref([])
const rooms = ref([])
const isLoading = ref(false)
const search = ref('')

const filteredUsers = computed(() => {
  const keyword = search.value.trim().toLowerCase()
  if (!keyword) return users.value
  return users.value.filter((user) =>
    `${user.login_id} ${user.nickname}`.toLowerCase().includes(keyword),
  )
})

function askReason(message) {
  return window.prompt(message)?.trim() || ''
}

async function loadData() {
  isLoading.value = true
  try {
    const [nextUsers, nextRooms] = await Promise.all([getAdminUsers(), getAdminRooms()])
    users.value = nextUsers || []
    rooms.value = nextRooms || []
  } catch (error) {
    toastStore.error(error.message)
  } finally {
    isLoading.value = false
  }
}

async function changeRole(user) {
  const nextRole = user.role === 'admin' ? 'user' : 'admin'
  const reason = askReason(`${user.nickname} 계정을 ${nextRole} 권한으로 변경하는 사유를 입력하세요.`)
  if (!reason) return
  try {
    await setAdminUserRole(user.user_id, nextRole, reason)
    toastStore.success('사용자 권한을 변경했습니다.')
    await loadData()
  } catch (error) {
    toastStore.error(error.message)
  }
}

async function applySanction(user, type) {
  const label = type === 'account' ? '이용' : '채팅'
  const reason = askReason(`${user.nickname} 계정의 ${label} 제재 사유를 입력하세요.`)
  if (!reason) return
  const durationValue = window.prompt('제재 시간을 입력하세요. 비워두면 영구 제재입니다.', '24')
  if (durationValue === null) return
  const durationHours = durationValue.trim() ? Number(durationValue) : null
  if (durationHours !== null && (!Number.isInteger(durationHours) || durationHours < 1)) {
    toastStore.error('제재 시간은 1 이상의 정수여야 합니다.')
    return
  }
  try {
    await applyAdminSanction(user.user_id, type, reason, durationHours)
    toastStore.success('사용자 제재를 적용했습니다.')
    await loadData()
  } catch (error) {
    toastStore.error(error.message)
  }
}

async function revokeSanction(user, type) {
  const reason = askReason(`${user.nickname} 계정의 제재 해제 사유를 입력하세요.`)
  if (!reason) return
  try {
    await revokeAdminSanctions(user.user_id, type, reason)
    toastStore.success('사용자 제재를 해제했습니다.')
    await loadData()
  } catch (error) {
    toastStore.error(error.message)
  }
}

async function deleteRoom(room) {
  const reason = askReason(`"${room.title}" 방을 삭제하는 사유를 입력하세요.`)
  if (!reason || !window.confirm('방과 연결된 데이터가 삭제될 수 있습니다. 계속할까요?')) return
  try {
    await deleteRoomAsAdmin(room.room_id, reason)
    toastStore.success('방을 삭제했습니다.')
    await loadData()
  } catch (error) {
    toastStore.error(error.message)
  }
}

onMounted(loadData)
</script>

<template>
  <section class="admin-page">
    <header class="admin-header">
      <div>
        <p class="eyebrow">Operations</p>
        <h1>관리자 운영실</h1>
        <p>권한 변경과 제재 작업은 감사 로그에 기록됩니다.</p>
      </div>
      <button type="button" :disabled="isLoading" @click="loadData">새로고침</button>
    </header>

    <section class="page-card">
      <div class="section-heading">
        <div><h2>사용자 관리</h2><p>계정 권한과 현재 적용 중인 제재를 관리합니다.</p></div>
        <input v-model="search" type="search" placeholder="ID 또는 닉네임 검색">
      </div>
      <div class="table-wrap">
        <table>
          <thead><tr><th>사용자</th><th>권한</th><th>상태</th><th>작업</th></tr></thead>
          <tbody>
            <tr v-for="user in filteredUsers" :key="user.user_id">
              <td><strong>{{ user.nickname }}</strong><small>{{ user.login_id }}</small></td>
              <td><span class="badge">{{ user.role }}</span></td>
              <td>
                <span v-if="user.account_suspended" class="badge danger">계정 정지</span>
                <span v-if="user.chat_suspended" class="badge warning">채팅 정지</span>
                <span v-if="!user.account_suspended && !user.chat_suspended" class="badge ok">정상</span>
              </td>
              <td class="actions">
                <button type="button" @click="changeRole(user)">권한 변경</button>
                <button v-if="!user.account_suspended" type="button" @click="applySanction(user, 'account')">계정 정지</button>
                <button v-else type="button" @click="revokeSanction(user, 'account')">계정 해제</button>
                <button v-if="!user.chat_suspended" type="button" @click="applySanction(user, 'chat')">채팅 정지</button>
                <button v-else type="button" @click="revokeSanction(user, 'chat')">채팅 해제</button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>

    <section class="page-card">
      <div class="section-heading">
        <div><h2>방 관리</h2><p>운영상 필요한 경우 생성된 방을 삭제합니다.</p></div>
      </div>
      <div class="room-list">
        <article v-for="room in rooms" :key="room.room_id">
          <div><strong>{{ room.title }}</strong><p>{{ room.game_type }} · {{ room.status }} · {{ room.player_count }}명 · 방장 {{ room.host_nickname || '알 수 없음' }}</p></div>
          <button type="button" class="danger-button" @click="deleteRoom(room)">방 삭제</button>
        </article>
        <p v-if="!rooms.length">생성된 방이 없습니다.</p>
      </div>
    </section>
  </section>
</template>

<style scoped>
.admin-page { display: grid; gap: 1.5rem; }
.admin-header, .section-heading, .room-list article { align-items: center; display: flex; justify-content: space-between; gap: 1rem; }
.admin-header h1, .section-heading h2 { margin: 0; }
.admin-header p, .section-heading p, .room-list p { margin: .35rem 0 0; opacity: .75; }
.eyebrow { color: var(--color-accent); font-weight: 800; text-transform: uppercase; }
button, input { background: rgba(255,255,255,.08); border: 1px solid var(--color-border); border-radius: .7rem; color: var(--color-text); padding: .65rem .8rem; }
button { cursor: pointer; }
.table-wrap { margin-top: 1.25rem; overflow-x: auto; }
table { border-collapse: collapse; min-width: 900px; width: 100%; }
th, td { border-bottom: 1px solid var(--color-border); padding: .8rem; text-align: left; }
td small { display: block; opacity: .65; }
.actions { display: flex; flex-wrap: wrap; gap: .4rem; }
.badge { background: rgba(255,255,255,.1); border-radius: 999px; display: inline-block; margin: .1rem; padding: .25rem .55rem; }
.badge.danger, .danger-button { border-color: #ef4444; color: #fca5a5; }
.badge.warning { color: #fbbf24; }
.badge.ok { color: #86efac; }
.room-list { display: grid; gap: .75rem; margin-top: 1.25rem; }
.room-list article { border: 1px solid var(--color-border); border-radius: 1rem; padding: 1rem; }
@media (max-width: 720px) { .admin-header, .section-heading, .room-list article { align-items: stretch; flex-direction: column; } }
</style>
