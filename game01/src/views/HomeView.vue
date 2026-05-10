<script setup>
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue';
import { useRouter } from 'vue-router';
import { logoutUser } from '@/api/authApi';
import { supabase } from '@/api/supabaseClient';
import { useAuthStore } from '@/stores/auth';
import { useRoomStore } from '@/stores/room';
import { useToastStore } from '@/stores/toast';
import {
  normalizeBroadcastMessage,
  sendPublicChatMessage,
  subscribeToPublicChat,
} from '@/api/chatApi';
import { createRoom as createRoomRequest } from '@/api/roomApi';
import {
  getFriendships,
  removeFriend,
  respondFriendRequest,
  sendFriendRequest,
  subscribeToFriendships,
} from '@/api/friendApi';
import {
  getIncomingRoomInvites,
  respondRoomInvite,
  subscribeToRoomInvites,
} from '@/api/roomInviteApi';

const router = useRouter();
const authStore = useAuthStore();
const roomStore = useRoomStore();
const toastStore = useToastStore();

const savedUser = computed(() => authStore.user);
const rooms = computed(() => roomStore.rooms);
const isLoadingRooms = ref(false);
const isCreatingRoom = ref(false);
const isCreateFormOpen = ref(false);
const newRoomTitle = ref('');
const newRoomDescription = ref('');
const newRoomMaxPlayers = ref(8);
const newRoomNightTimeSeconds = ref(30);
const newRoomVoteTimeSeconds = ref(15);
const newRoomRoleRevealMode = ref('private');
const newRoomEntryMode = ref('public');
const ROOMS_PER_PAGE = 5;
const currentRoomPage = ref(1);
const selectedRoomId = ref(null);
const presenceUsers = ref([]);
const friendships = ref([]);
const roomInvites = ref([]);
const friendNickname = ref('');
const isLoadingFriends = ref(false);
const isSendingFriendRequest = ref(false);
const isNotificationOpen = ref(false);
const publicChatDraft = ref('');
const publicChatNotice = ref('');
const publicChatMessages = ref([
  {
    id: 'welcome',
    nickname: 'System',
    content: '공용 채팅방이 준비되었습니다. 다음 단계에서 Supabase Realtime을 연결합니다.',
    createdAt: '방금 전',
    isSystem: true,
  },
]);
const publicChatChannel = ref(null);
let unsubscribeRooms = null;
let unsubscribePublicChat = null;
let unsubscribeFriendships = null;
let unsubscribeRoomInvites = null;
let friendshipRefreshTimer = null;
let roomInviteRefreshTimer = null;
let roomInvitePollTimer = null;
let lobbyPresenceChannel = null;

const character = computed(() => ({
  nickname: savedUser.value?.nickname || 'GuestPlayer',
  title: savedUser.value?.character?.name || 'Rookie Mafia',
  coin: savedUser.value?.character?.coin || savedUser.value?.coin || 0,
  level: savedUser.value?.level || savedUser.value?.character?.level || 12,
  expPercent: savedUser.value?.expPercent || savedUser.value?.experiencePercent || 68,
  rank: savedUser.value?.rank?.tier || savedUser.value?.rankTier || 'Bronze II',
  representativeTitle: savedUser.value?.representativeTitle || '침묵의 추리자',
  quote: savedUser.value?.quote || '오늘 밤, 누가 거짓말을 하고 있을까?',
  winRate: savedUser.value?.winRate || '0%',
  winStreak: savedUser.value?.winStreak || 3,
}));

const onlineUsers = computed(() => presenceUsers.value);
const onlineUserIds = computed(() => new Set(presenceUsers.value.map((user) => user.id)));
const acceptedFriends = computed(() => {
  return friendships.value
    .filter((friendship) => friendship.status === 'accepted')
    .map((friendship) => ({
      ...friendship,
      isOnline: onlineUserIds.value.has(friendship.friend.id),
      statusText: onlineUserIds.value.has(friendship.friend.id) ? '온라인' : '오프라인',
    }));
});
const incomingFriendRequests = computed(() => {
  return friendships.value.filter(
    (friendship) => friendship.status === 'pending' && friendship.direction === 'incoming',
  );
});
const outgoingFriendRequests = computed(() => {
  return friendships.value.filter(
    (friendship) => friendship.status === 'pending' && friendship.direction === 'outgoing',
  );
});
const incomingRoomInvites = computed(() => roomInvites.value);
const notificationCount = computed(() => incomingRoomInvites.value.length + incomingFriendRequests.value.length);

const waitingRoomCount = computed(() => {
  return rooms.value.filter((room) => room.status === 'waiting').length;
});

const playingRoomCount = computed(() => {
  return rooms.value.filter((room) => room.status !== 'waiting').length;
});

const roomPageCount = computed(() => {
  return Math.max(1, Math.ceil(rooms.value.length / ROOMS_PER_PAGE));
});

const paginatedRooms = computed(() => {
  const startIndex = (currentRoomPage.value - 1) * ROOMS_PER_PAGE;
  return rooms.value.slice(startIndex, startIndex + ROOMS_PER_PAGE);
});

const quickJoinPath = computed(() => {
  const joinableRoom = rooms.value.find((room) => {
    const currentPlayers = room.players?.length || room.currentPlayers || 0;
    return room.status === 'waiting' && currentPlayers < room.maxPlayers;
  });

  return joinableRoom ? `/rooms/${joinableRoom.id}` : '/home';
});

onMounted(async () => {
  isLoadingRooms.value = true;
  await roomStore.fetchRooms();
  isLoadingRooms.value = false;
  clampRoomPage();
  clampSelectedRoom();

  setupLobbyPresence();
  await loadFriendships();
  setupFriendshipRealtime();
  await loadRoomInvites();
  setupRoomInviteRealtime();
  roomInvitePollTimer = setInterval(loadRoomInvites, 10000);
  unsubscribeRooms = roomStore.subscribeToRooms();
  const publicChatSubscription = subscribeToPublicChat(handlePublicChatRealtimeEvent);
  publicChatChannel.value = publicChatSubscription.channel;
  unsubscribePublicChat = publicChatSubscription.unsubscribe;
});

onBeforeUnmount(() => {
  unsubscribeRooms?.();
  unsubscribeRooms = null;
  unsubscribePublicChat?.();
  unsubscribePublicChat = null;
  publicChatChannel.value = null;
  unsubscribeFriendships?.();
  unsubscribeFriendships = null;
  unsubscribeRoomInvites?.();
  unsubscribeRoomInvites = null;
  if (friendshipRefreshTimer) {
    clearTimeout(friendshipRefreshTimer);
  }
  if (roomInviteRefreshTimer) {
    clearTimeout(roomInviteRefreshTimer);
  }
  if (roomInvitePollTimer) {
    clearInterval(roomInvitePollTimer);
  }
  lobbyPresenceChannel?.untrack?.();
  if (lobbyPresenceChannel) {
    supabase.removeChannel(lobbyPresenceChannel);
  }
});

watch(savedUser, async (nextUser, previousUser) => {
  if (nextUser?.id === previousUser?.id) {
    return;
  }

  unsubscribeFriendships?.();
  unsubscribeFriendships = null;
  unsubscribeRoomInvites?.();
  unsubscribeRoomInvites = null;
  friendships.value = [];
  roomInvites.value = [];
  isNotificationOpen.value = false;
  if (roomInvitePollTimer) {
    clearInterval(roomInvitePollTimer);
    roomInvitePollTimer = null;
  }

  if (nextUser) {
    await loadFriendships();
    setupFriendshipRealtime();
    await loadRoomInvites();
    setupRoomInviteRealtime();
    if (!roomInvitePollTimer) {
      roomInvitePollTimer = setInterval(loadRoomInvites, 10000);
    }
  }
});

function handlePublicChatRealtimeEvent(payload) {
  if (payload?.type === 'subscription-status' && payload.status !== 'SUBSCRIBED') {
    return;
  }

  if (payload?.type === 'subscription-status') {
    publicChatNotice.value = '';
    return;
  }

  if (!payload?.payload) {
    return;
  }

  publicChatMessages.value = [
    ...publicChatMessages.value,
    normalizeBroadcastMessage(payload.payload),
  ].slice(-80);
  publicChatNotice.value = '';
}

async function createRoom() {
  if (!savedUser.value) {
    toastStore.error('로그인 후 방을 만들 수 있습니다.');
    router.push('/login');
    return;
  }

  if (!newRoomTitle.value.trim()) {
    toastStore.error('방 제목을 입력하세요.');
    return;
  }

  if (!newRoomDescription.value.trim()) {
    toastStore.error('방 소개 내용을 입력하세요.');
    return;
  }

  if (newRoomMaxPlayers.value < 2 || newRoomMaxPlayers.value > 12) {
    toastStore.error('참가 인원은 2명 이상 12명 이하로 설정하세요.');
    return;
  }

  isCreatingRoom.value = true;

  try {
    const createdRoom = await createRoomRequest({
      hostUser: savedUser.value,
      title: newRoomTitle.value,
      description: newRoomDescription.value,
      maxPlayers: Number(newRoomMaxPlayers.value),
      nightTimeSeconds: Number(newRoomNightTimeSeconds.value),
      voteTimeSeconds: Number(newRoomVoteTimeSeconds.value),
      roleRevealMode: newRoomRoleRevealMode.value,
      entryMode: newRoomEntryMode.value,
    });
    newRoomTitle.value = '';
    newRoomDescription.value = '';
    newRoomMaxPlayers.value = 8;
    newRoomNightTimeSeconds.value = 30;
    newRoomVoteTimeSeconds.value = 15;
    newRoomRoleRevealMode.value = 'private';
    newRoomEntryMode.value = 'public';
    isCreateFormOpen.value = false;
    await roomStore.fetchRooms();
    currentRoomPage.value = 1;
    router.push(`/rooms/${createdRoom.id}`);
  } catch (error) {
    toastStore.error(error.message);
  } finally {
    isCreatingRoom.value = false;
  }
}

function clampRoomPage() {
  if (currentRoomPage.value > roomPageCount.value) {
    currentRoomPage.value = roomPageCount.value;
  }
}

function clampSelectedRoom() {
  if (selectedRoomId.value && !rooms.value.some((room) => room.id === selectedRoomId.value)) {
    selectedRoomId.value = null;
  }
}

function goToPreviousRoomPage() {
  currentRoomPage.value = Math.max(1, currentRoomPage.value - 1);
  selectedRoomId.value = null;
}

function goToNextRoomPage() {
  currentRoomPage.value = Math.min(roomPageCount.value, currentRoomPage.value + 1);
  selectedRoomId.value = null;
}

function setupLobbyPresence() {
  const presenceKey = savedUser.value?.id || `guest-${Math.random().toString(36).slice(2)}`;

  lobbyPresenceChannel = supabase.channel('lobby-presence', {
    config: {
      presence: {
        key: presenceKey,
      },
    },
  });

  lobbyPresenceChannel
    .on('presence', { event: 'sync' }, () => {
      const state = lobbyPresenceChannel.presenceState();
      presenceUsers.value = Object.entries(state).map(([id, presences]) => {
        const latestPresence = presences[presences.length - 1];

        return {
          id,
          nickname: latestPresence.nickname || 'GuestPlayer',
          status: latestPresence.status || '로비',
        };
      });
    })
    .subscribe(async (status) => {
      if (status !== 'SUBSCRIBED') {
        return;
      }

      await lobbyPresenceChannel.track({
        nickname: character.value.nickname,
        status: '로비',
        onlineAt: new Date().toISOString(),
      });
    });
}

async function loadFriendships() {
  if (!savedUser.value) {
    friendships.value = [];
    return;
  }

  isLoadingFriends.value = true;

  try {
    friendships.value = await getFriendships(savedUser.value.id);
  } catch (error) {
    toastStore.error(error.message);
  } finally {
    isLoadingFriends.value = false;
  }
}

function setupFriendshipRealtime() {
  if (!savedUser.value || unsubscribeFriendships) {
    return;
  }

  unsubscribeFriendships = subscribeToFriendships(savedUser.value.id, (payload) => {
    if (payload?.type === 'subscription-status') {
      return;
    }

    scheduleFriendshipsRefresh();
  });
}

function scheduleFriendshipsRefresh() {
  if (friendshipRefreshTimer) {
    clearTimeout(friendshipRefreshTimer);
  }

  friendshipRefreshTimer = setTimeout(() => {
    friendshipRefreshTimer = null;
    loadFriendships();
  }, 120);
}

async function loadRoomInvites() {
  if (!savedUser.value) {
    roomInvites.value = [];
    return;
  }

  try {
    roomInvites.value = await getIncomingRoomInvites(savedUser.value.id);
  } catch (error) {
    toastStore.error(error.message);
  }
}

function setupRoomInviteRealtime() {
  if (!savedUser.value || unsubscribeRoomInvites) {
    return;
  }

  unsubscribeRoomInvites = subscribeToRoomInvites(savedUser.value.id, (payload) => {
    if (payload?.type === 'subscription-status') {
      return;
    }

    scheduleRoomInvitesRefresh();
  });
}

function scheduleRoomInvitesRefresh() {
  if (roomInviteRefreshTimer) {
    clearTimeout(roomInviteRefreshTimer);
  }

  roomInviteRefreshTimer = setTimeout(() => {
    roomInviteRefreshTimer = null;
    loadRoomInvites();
  }, 120);
}

async function acceptRoomInvite(invite) {
  try {
    const updatedInvite = await respondRoomInvite(invite.id, true);
    await loadRoomInvites();
    isNotificationOpen.value = false;
    router.push({ path: `/rooms/${updatedInvite.roomId}`, query: { invited: '1' } });
  } catch (error) {
    toastStore.error(error.message);
  }
}

async function rejectRoomInvite(inviteId) {
  try {
    await respondRoomInvite(inviteId, false);
    await loadRoomInvites();
  } catch (error) {
    toastStore.error(error.message);
  }
}

function toggleNotifications() {
  isNotificationOpen.value = !isNotificationOpen.value;
}

function openLobbySettings() {
  toastStore.info('濡쒕퉬 ?ㅼ젙 湲곕뒫??以鍮??묒엯?덈떎.');
}

async function submitFriendRequest() {
  const nickname = friendNickname.value.trim();

  if (!nickname || isSendingFriendRequest.value) {
    return;
  }

  isSendingFriendRequest.value = true;

  try {
    await sendFriendRequest(nickname);
    friendNickname.value = '';
    await loadFriendships();
    toastStore.success('친구 요청을 보냈습니다.');
  } catch (error) {
    toastStore.error(error.message);
  } finally {
    isSendingFriendRequest.value = false;
  }
}

async function acceptFriendRequest(friendshipId) {
  try {
    await respondFriendRequest(friendshipId, true);
    await loadFriendships();
  } catch (error) {
    toastStore.error(error.message);
  }
}

async function rejectFriendRequest(friendshipId) {
  try {
    await respondFriendRequest(friendshipId, false);
    await loadFriendships();
  } catch (error) {
    toastStore.error(error.message);
  }
}

async function deleteFriend(friendship) {
  const confirmed = window.confirm(`${friendship.friend.nickname}님을 친구 목록에서 삭제할까요?`);

  if (!confirmed) {
    return;
  }

  try {
    await removeFriend(friendship.id);
    await loadFriendships();
  } catch (error) {
    toastStore.error(error.message);
  }
}

function toggleRoomDetails(roomId) {
  selectedRoomId.value = selectedRoomId.value === roomId ? null : roomId;
}

function enterRoom(roomId) {
  router.push(`/rooms/${roomId}`);
}

function getRoomStatusLabel(room) {
  return room.status === 'waiting' ? '대기중' : '게임중';
}

function getRoomStatusClass(room) {
  return room.status === 'waiting' ? 'waiting' : 'playing';
}

function getModeClass(description) {
  if (description === '랭크전') return 'mode-ranked';
  if (description === '친선전') return 'mode-friendly';
  return 'mode-classic';
}

function getPlayerSlots(room) {
  const currentPlayers = room.players?.length || room.currentPlayers || 0;
  const maxPlayers = room.maxPlayers || 8;

  return Array.from({ length: maxPlayers }, (_, index) => index < currentPlayers);
}

async function submitPublicChat() {
  const content = publicChatDraft.value.trim();

  if (!content) {
    return;
  }

  if (!savedUser.value) {
    publicChatNotice.value = '로그인 후 채팅을 보낼 수 있습니다.';
    router.push('/login');
    return;
  }

  try {
    await sendPublicChatMessage(publicChatChannel.value, {
      userId: savedUser.value.id,
      nickname: character.value.nickname,
      content,
    });
    publicChatDraft.value = '';
    publicChatNotice.value = '';
  } catch (error) {
    publicChatNotice.value = error.message;
  }
}

async function logout() {
  await logoutUser();
  router.push('/login');
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
      <div class="lobby-toolbar">
        <button
          type="button"
          class="lobby-icon-button"
          :class="{ active: isNotificationOpen }"
          aria-label="Notifications"
          @click="toggleNotifications"
        >
          <span aria-hidden="true">🔔</span>
          <b v-if="notificationCount">{{ notificationCount }}</b>
        </button>
        <button
          type="button"
          class="lobby-icon-button"
          aria-label="Lobby settings"
          @click="openLobbySettings"
        >
          <span aria-hidden="true">⚙</span>
        </button>

        <div v-if="isNotificationOpen" class="notification-popover">
          <div class="notification-head">
            <strong>Notifications</strong>
            <span>{{ notificationCount }}</span>
          </div>

          <div class="notification-section">
            <p>Room Invites</p>
            <article v-for="invite in incomingRoomInvites" :key="invite.id" class="notification-row">
              <div>
                <strong>{{ invite.room.title }}</strong>
                <span>{{ invite.inviter.nickname }}</span>
              </div>
              <div class="notification-actions">
                <button type="button" @click="acceptRoomInvite(invite)">Enter</button>
                <button type="button" @click="rejectRoomInvite(invite.id)">Decline</button>
              </div>
            </article>
            <small v-if="incomingRoomInvites.length === 0">No room invites.</small>
          </div>

          <div class="notification-section">
            <p>Friend Requests</p>
            <article
              v-for="request in incomingFriendRequests"
              :key="request.id"
              class="notification-row"
            >
              <div>
                <strong>{{ request.friend.nickname }}</strong>
                <span>Friend request</span>
              </div>
              <div class="notification-actions">
                <button type="button" @click="acceptFriendRequest(request.id)">Accept</button>
                <button type="button" @click="rejectFriendRequest(request.id)">Decline</button>
              </div>
            </article>
            <small v-if="incomingFriendRequests.length === 0">No friend requests.</small>
          </div>
        </div>
      </div>
    </header>

    <div class="lobby-content">
      <main class="main-panel">
        <section v-if="isCreateFormOpen" class="page-card create-room-panel">
          <div class="section-heading">
            <div>
              <p class="eyebrow">Create</p>
              <h2>새 게임방</h2>
            </div>
            <button type="button" @click="isCreateFormOpen = false">닫기</button>
          </div>

          <form class="create-room-form game-styled-form" @submit.prevent="createRoom">
            <div class="form-group">
              <label>방 제목</label>
              <input
                v-model="newRoomTitle"
                type="text"
                placeholder="마피아의 밤에 오신 것을 환영합니다"
              />
            </div>

            <div class="form-group">
              <label>참가 인원</label>
              <div class="option-group">
                <button
                  v-for="count in [4, 6, 8, 12]"
                  :key="count"
                  type="button"
                  class="option-btn"
                  :class="{ active: newRoomMaxPlayers === count }"
                  @click="newRoomMaxPlayers = count"
                >
                  {{ count }}인
                </button>
              </div>
            </div>

            <div class="form-group">
              <label>게임 모드</label>
              <div class="option-group">
                <button
                  type="button"
                  class="option-btn"
                  :class="{ active: newRoomDescription === '클래식' }"
                  @click="newRoomDescription = '클래식'"
                >
                  🎭 클래식
                </button>
                <button
                  type="button"
                  class="option-btn"
                  :class="{ active: newRoomDescription === '랭크전' }"
                  @click="newRoomDescription = '랭크전'"
                >
                  ⚔️ 랭크전
                </button>
                <button
                  type="button"
                  class="option-btn"
                  :class="{ active: newRoomDescription === '친선전' }"
                  @click="newRoomDescription = '친선전'"
                >
                  🤝 친선전
                </button>
              </div>
            </div>

            <div class="room-custom-grid">
              <div class="form-group">
                <label>밤 시간</label>
                <select v-model.number="newRoomNightTimeSeconds">
                  <option :value="20">20초</option>
                  <option :value="30">30초</option>
                  <option :value="45">45초</option>
                  <option :value="60">60초</option>
                </select>
              </div>

              <div class="form-group">
                <label>투표 시간</label>
                <select v-model.number="newRoomVoteTimeSeconds">
                  <option :value="15">15초</option>
                  <option :value="30">30초</option>
                  <option :value="45">45초</option>
                  <option :value="60">60초</option>
                </select>
              </div>

              <div class="form-group">
                <label>역할 공개</label>
                <div class="option-group">
                  <button
                    type="button"
                    class="option-btn"
                    :class="{ active: newRoomRoleRevealMode === 'private' }"
                    @click="newRoomRoleRevealMode = 'private'"
                  >
                    비공개
                  </button>
                  <button
                    type="button"
                    class="option-btn"
                    :class="{ active: newRoomRoleRevealMode === 'public' }"
                    @click="newRoomRoleRevealMode = 'public'"
                  >
                    공개
                  </button>
                </div>
              </div>

              <div class="form-group">
                <label>입장 방식</label>
                <div class="option-group">
                  <button
                    type="button"
                    class="option-btn"
                    :class="{ active: newRoomEntryMode === 'public' }"
                    @click="newRoomEntryMode = 'public'"
                  >
                    공개방
                  </button>
                  <button
                    type="button"
                    class="option-btn"
                    :class="{ active: newRoomEntryMode === 'private' }"
                    @click="newRoomEntryMode = 'private'"
                  >
                    초대방
                  </button>
                </div>
              </div>
            </div>

            <button type="submit" class="submit-btn" :disabled="isCreatingRoom">
              {{ isCreatingRoom ? '생성 중...' : '방 생성' }}
            </button>
          </form>
        </section>

        <section class="page-card room-board" aria-labelledby="room-board-title">
          <div class="section-heading">
            <div>
              <p class="eyebrow">Rooms</p>
              <h2 id="room-board-title">게임 방 목록</h2>
              <div class="room-summary">
                <span>전체 {{ rooms.length }}</span>
                <span>대기 {{ waitingRoomCount }}</span>
                <span>게임중 {{ playingRoomCount }}</span>
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
              <div class="room-row">
                <button class="join-pill" type="button" @click="enterRoom(room.id)">입장</button>
                <button
                  class="room-detail-trigger"
                  type="button"
                  :aria-expanded="selectedRoomId === room.id"
                  @click="toggleRoomDetails(room.id)"
                >
                  <span>#{{ String(room.id).slice(0, 8) }}</span>
                  <strong>
                    {{ room.title }}
                  </strong>
                  <span>{{ room.hostNickname }}</span>
                  <span
                    class="slot-meter"
                    :aria-label="`${room.players?.length || room.currentPlayers} / ${room.maxPlayers}`"
                  >
                    <i
                      v-for="(filled, index) in getPlayerSlots(room)"
                      :key="`${room.id}-${index}`"
                      :class="{ filled }"
                    ></i>
                    <small
                      >{{ room.players?.length || room.currentPlayers }} /
                      {{ room.maxPlayers }}</small
                    >
                  </span>
                  <span class="status-stack">
                    <b class="status-badge" :class="getRoomStatusClass(room)">
                      {{ getRoomStatusLabel(room) }}
                    </b>
                    <b class="status-badge" :class="getModeClass(room.description)">{{
                      room.description || '클래식'
                    }}</b>
                  </span>
                </button>
              </div>

              <div v-if="selectedRoomId === room.id" class="room-details">
                <div class="room-details-heading">
                  <strong>참여 인원</strong>
                  <span>{{ room.players?.length || 0 }} / {{ room.maxPlayers }}</span>
                </div>

                <ul v-if="room.players?.length">
                  <li v-for="player in room.players" :key="player.userId">
                    <span>{{ player.nickname }}</span>
                    <small>{{
                      player.isHost ? '방장' : player.isReady ? '준비 완료' : '대기 중'
                    }}</small>
                  </li>
                </ul>
                <p v-else class="muted">아직 입장한 플레이어가 없습니다.</p>
              </div>
            </article>
          </div>

          <div v-if="rooms.length > ROOMS_PER_PAGE" class="room-pagination" aria-label="Room pages">
            <button type="button" :disabled="currentRoomPage === 1" @click="goToPreviousRoomPage">
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
              v-for="chat in publicChatMessages"
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

          <form class="chat-form" @submit.prevent="submitPublicChat">
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
          <div class="profile-header">
            <p class="eyebrow">My Character</p>
            <span class="online-pill">Online</span>
          </div>
          <div class="profile-main">
            <div class="avatar" aria-hidden="true">M</div>
            <div>
              <h2>{{ character.nickname }}</h2>
              <p>{{ character.title }}</p>
            </div>
          </div>

          <div class="profile-level">
            <div>
              <strong>Lv.{{ character.level }}</strong>
              <span>{{ character.expPercent }}%</span>
            </div>
            <div class="exp-track">
              <i :style="{ width: `${Math.min(100, character.expPercent)}%` }"></i>
            </div>
          </div>

          <div class="profile-tags">
            <span>{{ character.rank }}</span>
            <span>{{ character.representativeTitle }}</span>
          </div>

          <p class="profile-quote">"{{ character.quote }}"</p>

          <dl class="profile-stats">
            <div>
              <dt>Win Rate</dt>
              <dd>{{ character.winRate }}</dd>
            </div>
            <div>
              <dt>Streak</dt>
              <dd>{{ character.winStreak }} Win</dd>
            </div>
            <div>
              <dt>Coin</dt>
              <dd>{{ character.coin }}</dd>
            </div>
          </dl>
        </section>

        <section class="page-card visitor-card" aria-labelledby="visitor-title">
          <div class="section-heading compact">
            <div>
              <p class="eyebrow">Online</p>
              <h2 id="visitor-title">로비 접속 유저</h2>
            </div>
            <span class="user-count">{{ onlineUsers.length }}</span>
          </div>

          <ul>
            <li v-for="user in onlineUsers" :key="user.id">
              <strong>
                <i aria-hidden="true"></i>
                {{ user.nickname }}
              </strong>
              <span>{{ user.status }}</span>
            </li>
          </ul>

          <button v-if="false" class="invite-button" type="button">친구 초대</button>
          <div v-if="false && incomingRoomInvites.length" class="room-invite-panel">
            <div class="friend-heading">
              <div>
                <p class="eyebrow">Invites</p>
                <h3>방 초대</h3>
              </div>
              <span>{{ incomingRoomInvites.length }}</span>
            </div>

            <article v-for="invite in incomingRoomInvites" :key="invite.id" class="room-invite-row">
              <div>
                <strong>{{ invite.room.title }}</strong>
                <span>{{ invite.inviter.nickname }}님의 초대</span>
              </div>
              <div class="friend-actions">
                <button type="button" @click="acceptRoomInvite(invite)">입장</button>
                <button type="button" @click="rejectRoomInvite(invite.id)">거절</button>
              </div>
            </article>
          </div>

          <div class="friend-panel" aria-labelledby="friend-title">
            <div class="friend-heading">
              <div>
                <p class="eyebrow">Friends</p>
                <h3 id="friend-title">친구 목록</h3>
              </div>
              <span>{{ acceptedFriends.length }}</span>
            </div>

            <form class="friend-request-form" @submit.prevent="submitFriendRequest">
              <input
                v-model="friendNickname"
                type="text"
                placeholder="닉네임으로 친구 추가"
                :disabled="isSendingFriendRequest"
              />
              <button type="submit" :disabled="!friendNickname.trim() || isSendingFriendRequest">
                요청
              </button>
            </form>

            <div v-if="false && incomingFriendRequests.length" class="friend-request-list">
              <p>받은 요청</p>
              <article v-for="request in incomingFriendRequests" :key="request.id" class="friend-row request">
                <strong>{{ request.friend.nickname }}</strong>
                <div class="friend-actions">
                  <button type="button" @click="acceptFriendRequest(request.id)">수락</button>
                  <button type="button" @click="rejectFriendRequest(request.id)">거절</button>
                </div>
              </article>
            </div>

            <ul class="friend-list">
              <li v-if="isLoadingFriends" class="friend-empty">친구 목록을 불러오는 중...</li>
              <li v-else-if="acceptedFriends.length === 0" class="friend-empty">
                아직 등록된 친구가 없습니다.
              </li>
              <li v-for="friendship in acceptedFriends" v-else :key="friendship.id" class="friend-row">
                <strong>
                  <i :class="{ offline: !friendship.isOnline }" aria-hidden="true"></i>
                  {{ friendship.friend.nickname }}
                </strong>
                <span>{{ friendship.statusText }}</span>
                <button type="button" aria-label="친구 삭제" @click="deleteFriend(friendship)">삭제</button>
              </li>
            </ul>

            <div v-if="outgoingFriendRequests.length" class="outgoing-requests">
              <span>대기중 {{ outgoingFriendRequests.length }}</span>
            </div>
          </div>
        </section>
      </aside>
    </div>
  </section>
</template>

<style scoped>
.lobby-layout {
  --side-panel-width: clamp(17.5rem, 26vw, 20rem);
  --lobby-gap: clamp(0.75rem, 1.4vw, 1rem);
  --pc-panel-shadow: 0 18px 46px rgba(0, 0, 0, 0.34);
  display: grid;
  gap: var(--lobby-gap);
  min-width: 0;
  position: relative;
}

.lobby-layout :deep(.page-card),
.lobby-layout .page-card {
  background:
    linear-gradient(180deg, rgba(80, 46, 30, 0.44), rgba(20, 14, 11, 0.78)), rgba(20, 17, 15, 0.86);
  border: 1px solid rgba(255, 190, 85, 0.16);
  border-radius: clamp(0.85rem, 1.5vw, 1.35rem);
  box-shadow: var(--pc-panel-shadow);
  padding: clamp(1rem, 2.2vw, 1.75rem);
}

.lobby-hero {
  align-items: flex-start;
  display: flex;
  gap: 1rem;
  justify-content: space-between;
  min-width: 0;
  overflow: visible;
  position: relative;
}

.lobby-hero::after {
  background: linear-gradient(90deg, transparent, rgba(255, 132, 38, 0.12), transparent);
  content: '';
  inset: 0;
  pointer-events: none;
  position: absolute;
}

.lobby-hero > div:first-child {
  min-width: 0;
}

.lobby-toolbar {
  align-items: center;
  display: flex;
  gap: 0.55rem;
  margin-left: auto;
  position: relative;
  z-index: 2;
}

.lobby-icon-button {
  align-items: center;
  background: linear-gradient(180deg, rgba(255, 190, 85, 0.12), rgba(48, 20, 16, 0.72));
  border: 1px solid rgba(255, 190, 85, 0.28);
  border-radius: 0.7rem;
  color: #ffd49a;
  cursor: pointer;
  display: inline-flex;
  font: inherit;
  height: 2.55rem;
  justify-content: center;
  position: relative;
  transition:
    transform 0.16s ease,
    border-color 0.16s ease,
    box-shadow 0.16s ease,
    background 0.16s ease;
  width: 2.55rem;
}

.lobby-icon-button:hover,
.lobby-icon-button.active {
  background: linear-gradient(180deg, rgba(255, 190, 85, 0.2), rgba(84, 27, 22, 0.78));
  border-color: rgba(255, 202, 118, 0.58);
  box-shadow: 0 0 18px rgba(255, 129, 48, 0.2);
  transform: translateY(-1px);
}

.lobby-icon-button b {
  align-items: center;
  background: #e24531;
  border: 1px solid rgba(255, 218, 180, 0.48);
  border-radius: 999px;
  color: #fff6ea;
  display: inline-flex;
  font-size: 0.68rem;
  font-weight: 900;
  justify-content: center;
  min-width: 1.15rem;
  padding: 0.08rem 0.28rem;
  position: absolute;
  right: -0.36rem;
  top: -0.36rem;
}

.notification-popover {
  background:
    linear-gradient(180deg, rgba(73, 34, 22, 0.96), rgba(13, 9, 7, 0.98));
  border: 1px solid rgba(255, 190, 85, 0.24);
  border-radius: 0.95rem;
  box-shadow: 0 22px 55px rgba(0, 0, 0, 0.42), 0 0 24px rgba(255, 106, 42, 0.12);
  display: grid;
  gap: 0.85rem;
  max-height: min(31rem, 72vh);
  overflow: auto;
  padding: 1rem;
  position: absolute;
  right: 0;
  top: calc(100% + 0.75rem);
  width: min(24rem, calc(100vw - 2rem));
  z-index: 20;
}

.notification-head,
.notification-row,
.notification-actions {
  align-items: center;
  display: flex;
}

.notification-head {
  border-bottom: 1px solid rgba(255, 190, 85, 0.16);
  justify-content: space-between;
  padding-bottom: 0.65rem;
}

.notification-head strong {
  color: var(--color-heading);
}

.notification-head span {
  color: var(--color-accent);
  font-weight: 900;
}

.notification-section {
  display: grid;
  gap: 0.55rem;
}

.notification-section p {
  color: rgba(255, 214, 172, 0.76);
  font-size: 0.78rem;
  font-weight: 900;
  letter-spacing: 0.08em;
  text-transform: uppercase;
}

.notification-section small {
  color: var(--color-muted);
}

.notification-row {
  background: rgba(14, 9, 7, 0.54);
  border: 1px solid rgba(255, 190, 85, 0.12);
  border-radius: 0.7rem;
  gap: 0.75rem;
  justify-content: space-between;
  padding: 0.75rem;
  transition:
    border-color 0.16s ease,
    box-shadow 0.16s ease;
}

.notification-row:hover {
  border-color: rgba(255, 190, 85, 0.32);
  box-shadow: 0 0 18px rgba(255, 120, 52, 0.13);
}

.notification-row div:first-child {
  display: grid;
  gap: 0.16rem;
  min-width: 0;
}

.notification-row strong,
.notification-row span {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.notification-row span {
  color: var(--color-muted);
  font-size: 0.82rem;
}

.notification-actions {
  flex: 0 0 auto;
  gap: 0.38rem;
}

.notification-actions button {
  background: rgba(255, 190, 85, 0.08);
  border: 1px solid rgba(255, 190, 85, 0.24);
  border-radius: 0.52rem;
  color: var(--color-text);
  cursor: pointer;
  font: inherit;
  font-size: 0.78rem;
  font-weight: 800;
  padding: 0.44rem 0.6rem;
}

.notification-actions button:first-child {
  background: linear-gradient(180deg, #ffbe55, #bd6b24);
  color: #17100b;
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
  font-size: clamp(2.2rem, 5.2vw, 4.8rem);
  letter-spacing: -0.05em;
  line-height: 0.95;
  margin-top: 0.5rem;
  overflow-wrap: anywhere;
  text-shadow: 0 0 26px rgba(255, 120, 52, 0.2);
}

h2 {
  font-size: clamp(1.15rem, 2vw, 1.45rem);
  overflow-wrap: anywhere;
}

.room-actions {
  display: flex;
  flex-wrap: wrap;
  gap: 0.65rem;
  justify-content: flex-end;
}

.room-actions a,
.room-actions button,
.section-heading button,
.chat-form button,
.room-pagination button,
.invite-button {
  background: linear-gradient(180deg, rgba(255, 190, 85, 0.11), rgba(80, 31, 21, 0.22));
  border: 1px solid rgba(255, 190, 85, 0.28);
  border-radius: 0.65rem;
  color: var(--color-text);
  cursor: pointer;
  font: inherit;
  min-height: 2.75rem;
  padding: 0.75rem 1rem;
  transition:
    transform 0.16s ease,
    border-color 0.16s ease,
    box-shadow 0.16s ease,
    background 0.16s ease;
  white-space: nowrap;
}

.room-pagination button:disabled {
  cursor: not-allowed;
  opacity: 0.45;
}

.room-actions .primary,
.chat-form button[type='submit'],
.create-room-form button {
  background: linear-gradient(180deg, #ffbe55, #c87127);
  border-color: rgba(255, 210, 130, 0.42);
  color: #17100b;
  font-weight: 900;
}

.room-actions a:hover,
.room-actions button:hover,
.chat-form button:hover,
.room-pagination button:not(:disabled):hover,
.invite-button:hover {
  border-color: rgba(255, 210, 130, 0.6);
  box-shadow: 0 0 18px rgba(255, 143, 54, 0.18);
  transform: translateY(-1px);
}

.room-custom-grid {
  display: grid;
  gap: 0.85rem;
  grid-template-columns: repeat(2, minmax(0, 1fr));
}

.game-styled-form select {
  background: rgba(20, 12, 8, 0.78);
  border: 1px solid rgba(255, 190, 85, 0.2);
  border-radius: 0.65rem;
  color: var(--color-text);
  font: inherit;
  min-height: 2.75rem;
  padding: 0.65rem 0.8rem;
  width: 100%;
}

.room-actions a:active,
.room-actions button:active,
.chat-form button:active,
.room-pagination button:not(:disabled):active,
.invite-button:active,
.join-pill:active {
  transform: translateY(1px);
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

.room-board,
.create-room-panel,
.chat-card,
.profile-card,
.visitor-card {
  display: grid;
  gap: 0.9rem;
  min-width: 0;
}

.room-table-header {
  background: rgba(0, 0, 0, 0.18);
  border: 1px solid rgba(255, 190, 85, 0.12);
  border-radius: 0.65rem;
  color: rgba(255, 245, 224, 0.66);
  display: grid;
  font-size: 0.86rem;
  font-weight: 800;
  gap: 0.8rem;
  grid-template-columns: 4.25rem 5rem minmax(10rem, 1fr) minmax(5.5rem, 7rem) minmax(
      7.5rem,
      9rem
    ) 7rem;
  min-width: 0;
  padding: 0.65rem 0.8rem;
}

.room-table {
  --room-row-gap: 0.55rem;
  --room-row-height: 4.95rem;
  align-content: start;
  display: grid;
  gap: var(--room-row-gap);
  min-height: calc((var(--room-row-height) * 5) + (var(--room-row-gap) * 4));
  min-width: 0;
}

.room-entry {
  display: grid;
  gap: 0.55rem;
  min-width: 0;
}

.room-row {
  align-items: center;
  background: linear-gradient(180deg, rgba(255, 255, 255, 0.075), rgba(0, 0, 0, 0.05));
  border: 1px solid var(--color-border);
  border-radius: 0.75rem;
  color: var(--color-text);
  display: grid;
  gap: 0.8rem;
  grid-template-columns: 4.25rem minmax(0, 1fr);
  min-height: var(--room-row-height);
  min-width: 0;
  padding: 0.78rem 0.8rem;
  transition:
    background 0.18s ease,
    border-color 0.18s ease,
    box-shadow 0.18s ease;
}

.room-row:hover,
.room-row:focus-within {
  background: linear-gradient(180deg, rgba(255, 190, 85, 0.13), rgba(90, 28, 18, 0.18));
  border-color: rgba(255, 190, 85, 0.38);
  box-shadow: 0 0 22px rgba(255, 132, 38, 0.12);
}

.room-entry.expanded .room-row {
  border-color: rgba(255, 190, 85, 0.48);
}

.room-detail-trigger {
  align-items: center;
  background: transparent;
  border: 0;
  color: var(--color-text);
  cursor: pointer;
  display: grid;
  font: inherit;
  gap: 0.8rem;
  grid-template-columns: 5rem minmax(10rem, 1fr) minmax(5.5rem, 7rem) minmax(7.5rem, 9rem) 7rem;
  min-width: 0;
  padding: 0;
  text-align: left;
}

.room-detail-trigger > span {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.room-detail-trigger:focus-visible {
  border-radius: 0.55rem;
  outline: 2px solid var(--color-accent);
  outline-offset: 3px;
}

.join-pill {
  background: linear-gradient(180deg, #ffbe55, #b85a1f);
  border: 1px solid rgba(255, 230, 160, 0.4);
  border-radius: 999px;
  color: #14110f;
  cursor: pointer;
  font: inherit;
  font-size: 0.82rem;
  font-weight: 900;
  justify-self: start;
  padding: 0.35rem 0.68rem;
  transition:
    transform 0.16s ease,
    box-shadow 0.16s ease,
    filter 0.16s ease;
}

.join-pill:hover {
  box-shadow: 0 0 18px rgba(255, 190, 85, 0.3);
  filter: brightness(1.06);
  transform: translateY(-1px);
}

.slot-meter {
  align-items: center;
  display: flex;
  gap: 0.18rem;
}

.slot-meter i {
  background: rgba(255, 245, 224, 0.2);
  border-radius: 999px;
  display: block;
  height: 0.48rem;
  width: 0.48rem;
}

.slot-meter i.filled {
  background: #ffbe55;
  box-shadow: 0 0 8px rgba(255, 190, 85, 0.3);
}

.slot-meter small {
  color: rgba(255, 245, 224, 0.7);
  margin-left: 0.25rem;
}

.status-stack {
  align-items: center;
  display: flex;
  flex-wrap: wrap;
  gap: 0.28rem;
}

.status-badge {
  border: 1px solid rgba(255, 245, 224, 0.16);
  border-radius: 999px;
  font-size: 0.74rem;
  line-height: 1;
  padding: 0.3rem 0.45rem;
}

.status-badge.waiting {
  background: rgba(34, 197, 94, 0.13);
  border-color: rgba(34, 197, 94, 0.38);
  color: #86efac;
}

.status-badge.playing {
  background: rgba(239, 68, 68, 0.16);
  border-color: rgba(239, 68, 68, 0.38);
  color: #fca5a5;
}

.status-badge.rank {
  background: rgba(255, 190, 85, 0.12);
  border-color: rgba(255, 190, 85, 0.3);
  color: #ffd28a;
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
.room-details li span,
.room-detail-trigger strong {
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

.room-detail-trigger strong {
  display: grid;
  min-width: 0;
}

.room-detail-trigger small {
  color: rgba(255, 245, 224, 0.56);
  font-size: 0.82rem;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
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

.message {
  color: #ff8f70;
  font-weight: 800;
}

.muted,
.chat-notice {
  color: rgba(255, 245, 224, 0.58);
  font-size: 0.9rem;
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

.create-room-form input:focus,
.create-room-form textarea:focus,
.chat-form input:focus {
  border-color: rgba(255, 190, 85, 0.5);
  box-shadow: 0 0 0 3px rgba(255, 190, 85, 0.1);
  outline: 0;
}

.create-room-form button {
  align-self: end;
  border-radius: 0.75rem;
  cursor: pointer;
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
  min-width: 0;
  overflow-y: auto;
  padding: 0.85rem;
}

.chat-line {
  align-items: baseline;
  background: rgba(20, 17, 15, 0.46);
  border: 1px solid transparent;
  border-radius: 0.75rem 0.75rem 0.75rem 0.28rem;
  display: grid;
  gap: 0.7rem;
  grid-template-columns: minmax(4rem, auto) minmax(0, 1fr) auto;
  min-width: 0;
  padding: 0.65rem 0.75rem;
  transition:
    background 0.16s ease,
    border-color 0.16s ease;
}

.chat-line:hover {
  background: rgba(48, 29, 20, 0.72);
  border-color: rgba(255, 190, 85, 0.18);
}

.chat-line.system {
  background: rgba(127, 29, 29, 0.18);
  border-color: rgba(255, 190, 85, 0.25);
}

.chat-line.system strong {
  color: #ffbe55;
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

.profile-card,
.visitor-card {
  transition:
    border-color 0.18s ease,
    box-shadow 0.18s ease,
    transform 0.18s ease;
}

.profile-card:hover,
.visitor-card:hover {
  border-color: rgba(255, 190, 85, 0.32);
  box-shadow:
    0 20px 52px rgba(0, 0, 0, 0.38),
    0 0 22px rgba(255, 132, 38, 0.08);
}

.profile-header {
  align-items: center;
  display: flex;
  gap: 0.75rem;
  justify-content: space-between;
}

.online-pill {
  background: rgba(34, 197, 94, 0.12);
  border: 1px solid rgba(34, 197, 94, 0.28);
  border-radius: 999px;
  color: #86efac;
  font-size: 0.78rem;
  font-weight: 900;
  padding: 0.28rem 0.58rem;
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

.profile-level {
  display: grid;
  gap: 0.4rem;
}

.profile-level > div:first-child {
  align-items: center;
  display: flex;
  justify-content: space-between;
}

.profile-level strong,
.profile-level span {
  color: var(--color-heading);
  font-weight: 900;
}

.exp-track {
  background: rgba(255, 245, 224, 0.12);
  border-radius: 999px;
  height: 0.55rem;
  overflow: hidden;
}

.exp-track i {
  background: linear-gradient(90deg, #ffbe55, #8f2115);
  display: block;
  height: 100%;
}

.profile-tags {
  display: flex;
  flex-wrap: wrap;
  gap: 0.4rem;
}

.profile-tags span {
  background: rgba(255, 190, 85, 0.1);
  border: 1px solid rgba(255, 190, 85, 0.24);
  border-radius: 999px;
  color: #ffd28a;
  font-size: 0.78rem;
  font-weight: 900;
  padding: 0.3rem 0.55rem;
}

.profile-quote {
  border-left: 3px solid rgba(255, 190, 85, 0.48);
  color: rgba(255, 245, 224, 0.72);
  font-size: 0.86rem;
  margin: 0;
  padding-left: 0.65rem;
}

.profile-stats {
  display: grid;
  gap: 0.55rem;
  grid-template-columns: repeat(3, minmax(0, 1fr));
  margin: 0;
}

.profile-stats div {
  background: rgba(255, 255, 255, 0.06);
  border: 1px solid var(--color-border);
  border-radius: 0.75rem;
  display: grid;
  gap: 0.15rem;
  padding: 0.55rem;
}

dt {
  color: rgba(255, 245, 224, 0.58);
  font-size: 0.72rem;
}

dd {
  color: var(--color-heading);
  font-weight: 900;
  margin: 0;
}

.visitor-card ul {
  display: grid;
  gap: 0.55rem;
  list-style: none;
  margin: 0;
  max-height: 17rem;
  min-width: 0;
  overflow-y: auto;
  padding: 0;
}

.visitor-card li {
  align-items: center;
  background: rgba(255, 255, 255, 0.07);
  border: 1px solid var(--color-border);
  border-radius: 0.75rem;
  display: flex;
  gap: 0.75rem;
  justify-content: space-between;
  min-width: 0;
  padding: 0.7rem 0.75rem;
  transition:
    background 0.16s ease,
    border-color 0.16s ease,
    transform 0.16s ease;
}

.visitor-card li:hover {
  background: rgba(255, 190, 85, 0.1);
  border-color: rgba(255, 190, 85, 0.28);
  box-shadow: 0 0 14px rgba(255, 143, 54, 0.12);
}

.visitor-card li:hover,
.visitor-card li:hover * {
  text-decoration: none;
}

.visitor-card strong {
  align-items: center;
  color: var(--color-heading);
  display: flex;
  font-weight: 900;
  gap: 0.45rem;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.visitor-card strong i {
  background: #22c55e;
  border-radius: 999px;
  box-shadow: 0 0 10px rgba(34, 197, 94, 0.38);
  flex: 0 0 auto;
  height: 0.55rem;
  width: 0.55rem;
}

.visitor-card span {
  color: rgba(255, 245, 224, 0.58);
  font-size: 0.82rem;
  white-space: nowrap;
}

.invite-button {
  align-items: center;
  display: flex;
  font-weight: 900;
  justify-content: center;
  width: 100%;
}

.visitor-card > .invite-button {
  display: none;
}

.friend-panel {
  border-top: 1px solid rgba(255, 190, 85, 0.16);
  display: grid;
  gap: 0.75rem;
  margin-top: 0.2rem;
  padding-top: 0.95rem;
}

.room-invite-panel {
  background: rgba(255, 190, 85, 0.08);
  border: 1px solid rgba(255, 190, 85, 0.2);
  border-radius: 0.8rem;
  display: grid;
  gap: 0.65rem;
  padding: 0.75rem;
}

.friend-heading {
  align-items: flex-start;
  display: flex;
  justify-content: space-between;
  gap: 0.75rem;
}

.friend-heading h3 {
  color: var(--color-heading);
  font-size: 1rem;
  font-weight: 900;
  margin: 0.15rem 0 0;
}

.friend-heading > span,
.outgoing-requests span {
  background: rgba(255, 190, 85, 0.12);
  border: 1px solid rgba(255, 190, 85, 0.24);
  border-radius: 999px;
  color: #ffd28a;
  font-size: 0.78rem;
  font-weight: 900;
  padding: 0.28rem 0.52rem;
}

.friend-request-form {
  display: grid;
  gap: 0.45rem;
  grid-template-columns: minmax(0, 1fr) auto;
}

.friend-request-form input {
  background: rgba(255, 255, 255, 0.07);
  border: 1px solid var(--color-border);
  border-radius: 0.65rem;
  color: var(--color-text);
  font: inherit;
  min-width: 0;
  padding: 0.65rem 0.75rem;
}

.friend-request-form input:focus {
  border-color: rgba(255, 190, 85, 0.5);
  box-shadow: 0 0 0 3px rgba(255, 190, 85, 0.1);
  outline: none;
}

.friend-request-form button,
.friend-actions button,
.friend-row > button {
  background: linear-gradient(180deg, rgba(255, 190, 85, 0.14), rgba(80, 31, 21, 0.24));
  border: 1px solid rgba(255, 190, 85, 0.24);
  border-radius: 0.55rem;
  color: var(--color-text);
  cursor: pointer;
  font: inherit;
  font-size: 0.78rem;
  font-weight: 900;
  padding: 0.55rem 0.65rem;
}

.friend-request-form button:disabled {
  cursor: not-allowed;
  opacity: 0.5;
}

.friend-request-list,
.friend-list {
  display: grid;
  gap: 0.45rem;
  list-style: none;
  margin: 0;
  padding: 0;
}

.friend-request-list p {
  color: rgba(255, 245, 224, 0.58);
  font-size: 0.78rem;
  font-weight: 900;
  margin: 0;
}

.friend-row {
  align-items: center;
  background: rgba(255, 255, 255, 0.06);
  border: 1px solid var(--color-border);
  border-radius: 0.7rem;
  display: grid;
  gap: 0.45rem;
  grid-template-columns: minmax(0, 1fr) auto auto;
  min-width: 0;
  padding: 0.62rem 0.65rem;
}

.room-invite-row {
  align-items: center;
  background: rgba(20, 17, 15, 0.42);
  border: 1px solid rgba(255, 190, 85, 0.16);
  border-radius: 0.7rem;
  display: grid;
  gap: 0.65rem;
  grid-template-columns: minmax(0, 1fr) auto;
  padding: 0.65rem;
}

.room-invite-row div:first-child {
  display: grid;
  gap: 0.18rem;
  min-width: 0;
}

.room-invite-row strong {
  color: var(--color-heading);
  font-weight: 900;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.room-invite-row span {
  color: rgba(255, 245, 224, 0.58);
  font-size: 0.78rem;
}

.friend-row.request {
  grid-template-columns: minmax(0, 1fr) auto;
}

.friend-row strong {
  align-items: center;
  color: var(--color-heading);
  display: flex;
  gap: 0.42rem;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.friend-row strong i {
  background: #22c55e;
  border-radius: 999px;
  box-shadow: 0 0 10px rgba(34, 197, 94, 0.38);
  flex: 0 0 auto;
  height: 0.55rem;
  width: 0.55rem;
}

.friend-row strong i.offline {
  background: #71717a;
  box-shadow: none;
}

.friend-row span,
.friend-empty {
  color: rgba(255, 245, 224, 0.58);
  font-size: 0.78rem;
}

.friend-actions {
  display: flex;
  gap: 0.35rem;
}

.lobby-layout *::-webkit-scrollbar {
  height: 0.55rem;
  width: 0.55rem;
}

.lobby-layout *::-webkit-scrollbar-track {
  background: rgba(20, 14, 11, 0.36);
}

.lobby-layout *::-webkit-scrollbar-thumb {
  background: rgba(255, 190, 85, 0.42);
  border-radius: 999px;
}

@media (max-width: 1180px) {
  .lobby-content {
    grid-template-columns: 1fr;
  }

  .side-panel {
    position: static;
    grid-template-columns: 1fr 1fr;
  }
}

@media (max-width: 980px) {
  .lobby-hero {
    align-items: start;
    grid-template-columns: 1fr;
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

  .room-row,
  .room-detail-trigger {
    align-items: stretch;
    gap: 0.55rem;
    grid-template-columns: 1fr;
    min-height: auto;
  }

  .join-pill {
    justify-self: start;
  }

  .room-detail-trigger > span:not(.slot-meter):not(.status-stack) {
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

  .create-room-form,
  .chat-line,
  .chat-form,
  .side-panel {
    grid-template-columns: 1fr;
  }

  .room-actions,
  .section-heading {
    align-items: flex-start;
    flex-direction: column;
  }

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

  .visitor-card li {
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
.game-styled-form {
  display: grid;
  gap: 1.25rem;
  grid-template-columns: 1fr;
}

.form-group {
  display: grid;
  gap: 0.5rem;
}

.form-group label {
  color: rgba(255, 245, 224, 0.7);
  font-size: 0.85rem;
  font-weight: 800;
  text-transform: uppercase;
  letter-spacing: 0.05em;
}

.option-group {
  display: flex;
  flex-wrap: wrap;
  gap: 0.5rem;
}

.option-btn {
  background: rgba(255, 255, 255, 0.05) !important;
  border: 1px solid var(--color-border) !important;
  border-radius: 0.75rem !important;
  color: var(--color-text) !important;
  cursor: pointer;
  flex: 1;
  font-weight: 800;
  padding: 0.75rem 0.5rem !important;
  text-align: center;
  transition: all 0.2s ease !important;
  white-space: nowrap;
}

.option-btn:hover {
  background: rgba(255, 255, 255, 0.1) !important;
  border-color: rgba(255, 190, 85, 0.3) !important;
}

.option-btn.active {
  background: linear-gradient(180deg, rgba(255, 190, 85, 0.2), rgba(255, 132, 38, 0.2)) !important;
  border-color: #ffbe55 !important;
  box-shadow: 0 0 12px rgba(255, 190, 85, 0.2) !important;
  color: #ffbe55 !important;
}

.submit-btn {
  background: linear-gradient(180deg, #ffbe55, #c87127) !important;
  border: 0 !important;
  border-radius: 0.75rem !important;
  color: #17100b !important;
  cursor: pointer;
  font-size: 1rem;
  font-weight: 900;
  margin-top: 0.5rem;
  padding: 1rem !important;
  text-align: center;
  transition:
    transform 0.16s ease,
    box-shadow 0.16s ease !important;
}

.submit-btn:hover:not(:disabled) {
  box-shadow: 0 0 18px rgba(255, 143, 54, 0.3) !important;
  transform: translateY(-2px);
}

.submit-btn:disabled {
  cursor: wait;
  opacity: 0.7;
}
</style>
