<script setup>
import {
  computed,
  nextTick,
  onBeforeUnmount,
  onMounted,
  ref,
  watch,
} from 'vue';
import { useRouter } from 'vue-router';
import { logoutUser } from '@/api/authApi';
import { useAuthStore } from '@/stores/auth';
import { useProfileStore } from '@/stores/profile';
import { useRoomStore } from '@/stores/room';
import { useToastStore } from '@/stores/toast';
import GameSettingsModal from '@/components/GameSettingsModal.vue';
import {
  normalizeBroadcastMessage,
  sendPublicChatMessage,
  sendWhisperChatMessage,
  subscribeToPublicChat,
} from '@/api/chatApi';
import {
  clearCurrentUserPresence,
  setCurrentUserPresence,
  subscribeToPresenceUsers,
} from '@/api/presenceApi';
import {
  DEFAULT_ROOM_DETAIL_SETTINGS,
  createRoom as createRoomRequest,
  joinRoom as joinRoomRequest,
} from '@/api/roomApi';
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
const profileStore = useProfileStore();
const roomStore = useRoomStore();
const toastStore = useToastStore();

const savedUser = computed(() => authStore.user);
const rooms = computed(() => roomStore.rooms);
const isLoadingRooms = ref(false);
const isCreatingRoom = ref(false);
const isCreateFormOpen = ref(false);
const newRoomTitle = ref('');
const newRoomDescription = ref('클래식');
const newRoomMaxPlayers = ref(8);
const newRoomNightTimeSeconds = ref(
  DEFAULT_ROOM_DETAIL_SETTINGS.nightTimeSeconds,
);
const newRoomVoteTimeSeconds = ref(
  DEFAULT_ROOM_DETAIL_SETTINGS.voteTimeSeconds,
);
const newRoomDiscussionTimeSeconds = ref(
  DEFAULT_ROOM_DETAIL_SETTINGS.discussionTimeSeconds,
);
const newRoomMinStartPlayers = ref(
  DEFAULT_ROOM_DETAIL_SETTINGS.minStartPlayers,
);
const newRoomTieVoteRule = ref(DEFAULT_ROOM_DETAIL_SETTINGS.tieVoteRule);
const newRoomSpectatorAllowed = ref(
  DEFAULT_ROOM_DETAIL_SETTINGS.spectatorAllowed,
);
const newRoomFirstNightAbilityAllowed = ref(
  DEFAULT_ROOM_DETAIL_SETTINGS.firstNightAbilityAllowed,
);
const newRoomFinalDefenseEnabled = ref(
  DEFAULT_ROOM_DETAIL_SETTINGS.finalDefenseEnabled,
);
const newRoomRoleRevealMode = ref('private');
const newRoomEntryMode = ref('public');
const newRoomEntryPassword = ref('');
const newRoomRoleConfig = ref(getDefaultRoleConfig(8));
const isRecommendedRolesEnabled = ref(false);
const isNewRoomAdvancedOpen = ref(false);
const isJoinRoomModalOpen = ref(false);
const selectedJoinRoom = ref(null);
const joinRoomPassword = ref('');
const isJoinRoomPasswordVisible = ref(false);
const isJoiningRoom = ref(false);
const ROOMS_PER_PAGE = 5;
const currentRoomPage = ref(1);
const selectedRoomId = ref(null);
const roomFilter = ref('all');
const presenceUsers = ref([]);
const friendships = ref([]);
const roomInvites = ref([]);
const friendNickname = ref('');
const isLoadingFriends = ref(false);
const isSendingFriendRequest = ref(false);
const isNotificationOpen = ref(false);
const isLobbySettingsOpen = ref(false);
const publicChatDraft = ref('');
const publicChatNotice = ref('');
const publicChatInput = ref(null);
const whisperTarget = ref(null);
const lastWhisperReplyTarget = ref(null);
const selectedLobbyUserId = ref(null);
const selectedFriendshipId = ref(null);
const sendingFriendRequestUserIds = ref(new Set());
const publicChatMessages = ref([
  {
    id: 'welcome',
    nickname: 'System',
    content: '공용 채팅방이 준비되었습니다.',
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
let unsubscribePresenceUsers = null;

const lobbySettingsSections = [
  {
    title: '로비',
    items: ['방 목록 갱신', '온라인 유저 표시', '초대 알림 표시'],
  },
  {
    title: '채팅',
    items: ['공개 채팅 표시', '시스템 메시지 강조', '채팅 시간 표시'],
  },
];

const character = computed(() => profileStore.profile);

const onlineUsers = computed(() => presenceUsers.value);
const presenceByUserId = computed(() => {
  return new Map(presenceUsers.value.map((user) => [user.id, user]));
});
const presenceStatusByUserId = computed(() => {
  return new Map(
    presenceUsers.value.map((user) => [user.id, user.status || 'offline']),
  );
});
const isUserOnline = (userId) =>
  presenceStatusByUserId.value.get(userId) !== 'offline';
function getPresenceStatusLabel(status) {
  if (status === 'lobby') return '로비';
  if (status === 'room') return '게임방';
  if (status === 'playing') return '게임중';
  return '오프라인';
}
const friendshipByUserId = computed(() => {
  return friendships.value.reduce((map, friendship) => {
    if (friendship.friend?.id) {
      map.set(friendship.friend.id, friendship);
    }

    return map;
  }, new Map());
});
const acceptedFriends = computed(() => {
  return friendships.value
    .filter((friendship) => friendship.status === 'accepted')
    .map((friendship) => ({
      ...friendship,
      status:
        presenceStatusByUserId.value.get(friendship.friend.id) || 'offline',
      isOnline:
        presenceStatusByUserId.value.get(friendship.friend.id) !== 'offline',
      statusText: getPresenceStatusLabel(
        presenceStatusByUserId.value.get(friendship.friend.id) || 'offline',
      ),
      canReceiveWhisper:
        presenceByUserId.value.get(friendship.friend.id)?.canReceiveWhisper ===
        true,
    }));
});
const incomingFriendRequests = computed(() => {
  return friendships.value.filter(
    (friendship) =>
      friendship.status === 'pending' && friendship.direction === 'incoming',
  );
});
const outgoingFriendRequests = computed(() => {
  return friendships.value.filter(
    (friendship) =>
      friendship.status === 'pending' && friendship.direction === 'outgoing',
  );
});
const incomingRoomInvites = computed(() => roomInvites.value);
const notificationCount = computed(
  () => incomingRoomInvites.value.length + incomingFriendRequests.value.length,
);

const waitingRoomCount = computed(() => {
  return rooms.value.filter((room) => room.status === 'waiting').length;
});

const playingRoomCount = computed(() => {
  return rooms.value.filter((room) => room.status !== 'waiting').length;
});

const roomFilterOptions = computed(() => [
  { value: 'all', label: '전체', count: rooms.value.length },
  { value: 'waiting', label: '대기', count: waitingRoomCount.value },
  { value: 'playing', label: '게임중', count: playingRoomCount.value },
]);

const roomMessage = computed(() => '');

const filteredRooms = computed(() => {
  if (roomFilter.value === 'waiting') {
    return rooms.value.filter((room) => room.status === 'waiting');
  }

  if (roomFilter.value === 'playing') {
    return rooms.value.filter((room) => room.status !== 'waiting');
  }

  return rooms.value;
});

const roomPageCount = computed(() => {
  return Math.max(1, Math.ceil(filteredRooms.value.length / ROOMS_PER_PAGE));
});

const paginatedRooms = computed(() => {
  const startIndex = (currentRoomPage.value - 1) * ROOMS_PER_PAGE;
  return filteredRooms.value.slice(startIndex, startIndex + ROOMS_PER_PAGE);
});

const quickJoinPath = computed(() => {
  const joinableRoom = rooms.value.find((room) => {
    const currentPlayers = room.players?.length || room.currentPlayers || 0;
    return room.status === 'waiting' && currentPlayers < room.maxPlayers;
  });

  return joinableRoom ? `/rooms/${joinableRoom.id}` : '/home';
});

const roleOptions = [
  { key: 'citizen', label: '시민' },
  { key: 'mafia', label: '마피아' },
  { key: 'police', label: '경찰' },
  { key: 'doctor', label: '의사' },
];
const fixedPlayerCounts = [4, 6, 8, 12];
const nightTimeOptions = [20, 30, 45, 60];
const discussionTimeOptions = [30, 45, 60, 90, 120];
const voteTimeOptions = [15, 30, 45, 60];
const tieVoteOptions = [
  { value: 'no_execution', label: '처형 없음' },
  { value: 'revote', label: '재투표' },
];
const newRoomMinStartPlayerOptions = computed(() =>
  Array.from(
    { length: Math.max(1, Number(newRoomMaxPlayers.value) - 1) },
    (_, index) => index + 2,
  ),
);

const isFriendlyRoomMode = computed(
  () => newRoomDescription.value === '친선전',
);
const roleConfigTotal = computed(() => {
  return Object.values(newRoomRoleConfig.value).reduce(
    (total, count) => total + Number(count || 0),
    0,
  );
});
const isRoleConfigValid = computed(
  () => roleConfigTotal.value === Number(newRoomMaxPlayers.value),
);
const roleConfigStatusText = computed(() => {
  if (newRoomDescription.value === '클래식') {
    return '기본 밸런스 고정';
  }

  return '커스텀 사용자 설정';
});

function getDefaultRoleConfig(maxPlayers) {
  const defaults = {
    4: { citizen: 2, mafia: 1, police: 1, doctor: 0 },
    6: { citizen: 3, mafia: 1, police: 1, doctor: 1 },
    8: { citizen: 4, mafia: 2, police: 1, doctor: 1 },
    12: { citizen: 7, mafia: 3, police: 1, doctor: 1 },
  };

  return { ...(defaults[Number(maxPlayers)] || defaults[8]) };
}

function getRecommendedRoleConfig(maxPlayers) {
  const playerCount = Number(maxPlayers);

  if (fixedPlayerCounts.includes(playerCount)) {
    return getDefaultRoleConfig(playerCount);
  }

  const mafia = Math.max(1, Math.floor(playerCount / 4));
  const police = 1;
  const doctor = playerCount >= 6 ? 1 : 0;
  const citizen = Math.max(0, playerCount - mafia - police - doctor);

  return { citizen, mafia, police, doctor };
}

onMounted(async () => {
  unsubscribePresenceUsers = subscribeToPresenceUsers((users) => {
    presenceUsers.value = users;
  });

  isLoadingRooms.value = true;
  await roomStore.fetchRooms();
  isLoadingRooms.value = false;
  clampRoomPage();
  clampSelectedRoom();

  await loadFriendships();
  setupFriendshipRealtime();
  await loadRoomInvites();
  setupRoomInviteRealtime();
  roomInvitePollTimer = setInterval(loadRoomInvites, 10000);
  unsubscribeRooms = roomStore.subscribeToRooms();
  const publicChatSubscription = subscribeToPublicChat(
    handlePublicChatRealtimeEvent,
  );
  publicChatChannel.value = publicChatSubscription.channel;
  unsubscribePublicChat = publicChatSubscription.unsubscribe;

  if (savedUser.value) {
    await profileStore.reloadProfile(savedUser.value.id);
    await setCurrentUserPresence({
      userId: savedUser.value.id,
      nickname: character.value.nickname,
      status: 'lobby',
      canReceiveWhisper: true,
    });
  }
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
  unsubscribePresenceUsers?.();
  unsubscribePresenceUsers = null;
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
    await profileStore.reloadProfile(nextUser.id);
    await loadFriendships();
    setupFriendshipRealtime();
    await loadRoomInvites();
    setupRoomInviteRealtime();
    if (!roomInvitePollTimer) {
      roomInvitePollTimer = setInterval(loadRoomInvites, 10000);
    }
    await setCurrentUserPresence({
      userId: nextUser.id,
      nickname: character.value.nickname,
      status: 'lobby',
      canReceiveWhisper: true,
    });
  } else {
    profileStore.resetProfile();
    await clearCurrentUserPresence();
  }
});

watch([rooms, roomFilter], () => {
  clampRoomPage();
  clampSelectedRoom();
});

watch([newRoomMaxPlayers, newRoomDescription], () => {
  if (isFriendlyRoomMode.value) {
    if (isRecommendedRolesEnabled.value) {
      newRoomRoleConfig.value = getRecommendedRoleConfig(
        newRoomMaxPlayers.value,
      );
    }

    return;
  }

  newRoomRoleConfig.value = getDefaultRoleConfig(newRoomMaxPlayers.value);
});

watch([newRoomMaxPlayers, newRoomMinStartPlayers], () => {
  if (newRoomMinStartPlayers.value < 2) {
    newRoomMinStartPlayers.value = 2;
  }

  if (newRoomMinStartPlayers.value > newRoomMaxPlayers.value) {
    newRoomMinStartPlayers.value = newRoomMaxPlayers.value;
  }
});

function handlePublicChatRealtimeEvent(payload) {
  if (
    payload?.type === 'subscription-status' &&
    payload.status !== 'SUBSCRIBED'
  ) {
    return;
  }

  if (payload?.type === 'subscription-status') {
    publicChatNotice.value = '';
    return;
  }

  if (!payload?.payload) {
    return;
  }

  const message = normalizeBroadcastMessage(payload.payload);

  if (
    message.isWhisper &&
    message.userId !== savedUser.value?.id &&
    message.targetUserId !== savedUser.value?.id
  ) {
    return;
  }

  if (
    message.isWhisper &&
    message.targetUserId === savedUser.value?.id &&
    message.userId !== savedUser.value?.id
  ) {
    lastWhisperReplyTarget.value = {
      id: message.userId,
      nickname: message.nickname,
    };
  }

  publicChatMessages.value = [...publicChatMessages.value, message].slice(-80);
  publicChatNotice.value = '';
}

async function createRoom() {
  if (!savedUser.value) {
    toastStore.error('로그인해야 방을 만들 수 있습니다.');
    router.push('/login');
    return;
  }

  if (!newRoomTitle.value.trim()) {
    toastStore.error('방 제목을 입력하세요.');
    return;
  }

  if (!newRoomDescription.value.trim()) {
    toastStore.error('게임 모드를 선택하세요.');
    return;
  }

  if (newRoomMaxPlayers.value < 2 || newRoomMaxPlayers.value > 12) {
    toastStore.error('참가 인원은 2명 이상 12명 이하로 설정하세요.');
    return;
  }

  if (!isRoleConfigValid.value) {
    toastStore.error('역할 인원수 합계가 참가 인원과 같아야 합니다.');
    return;
  }

  if (newRoomMinStartPlayers.value < 2) {
    toastStore.error('최소 시작 인원은 2명 이상이어야 합니다.');
    return;
  }

  if (newRoomMinStartPlayers.value > newRoomMaxPlayers.value) {
    toastStore.error('최소 시작 인원은 참가 인원보다 많을 수 없습니다.');
    return;
  }

  if (
    newRoomEntryMode.value === 'private' &&
    !newRoomEntryPassword.value.trim()
  ) {
    toastStore.error('비공개방은 비밀번호를 입력해야 합니다.');
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
      discussionTimeSeconds: Number(newRoomDiscussionTimeSeconds.value),
      minStartPlayers: Number(newRoomMinStartPlayers.value),
      tieVoteRule: newRoomTieVoteRule.value,
      spectatorAllowed: newRoomSpectatorAllowed.value,
      firstNightAbilityAllowed: newRoomFirstNightAbilityAllowed.value,
      finalDefenseEnabled: newRoomFinalDefenseEnabled.value,
      roleRevealMode: newRoomRoleRevealMode.value,
      entryMode: newRoomEntryMode.value,
      entryPassword: newRoomEntryPassword.value.trim(),
      roleConfig: newRoomRoleConfig.value,
    });
    newRoomTitle.value = '';
    newRoomDescription.value = '클래식';
    newRoomMaxPlayers.value = 8;
    newRoomNightTimeSeconds.value =
      DEFAULT_ROOM_DETAIL_SETTINGS.nightTimeSeconds;
    newRoomVoteTimeSeconds.value = DEFAULT_ROOM_DETAIL_SETTINGS.voteTimeSeconds;
    newRoomDiscussionTimeSeconds.value =
      DEFAULT_ROOM_DETAIL_SETTINGS.discussionTimeSeconds;
    newRoomMinStartPlayers.value = DEFAULT_ROOM_DETAIL_SETTINGS.minStartPlayers;
    newRoomTieVoteRule.value = DEFAULT_ROOM_DETAIL_SETTINGS.tieVoteRule;
    newRoomSpectatorAllowed.value =
      DEFAULT_ROOM_DETAIL_SETTINGS.spectatorAllowed;
    newRoomFirstNightAbilityAllowed.value =
      DEFAULT_ROOM_DETAIL_SETTINGS.firstNightAbilityAllowed;
    newRoomFinalDefenseEnabled.value =
      DEFAULT_ROOM_DETAIL_SETTINGS.finalDefenseEnabled;
    newRoomRoleRevealMode.value = 'private';
    newRoomEntryMode.value = 'public';
    newRoomEntryPassword.value = '';
    newRoomRoleConfig.value = getDefaultRoleConfig(8);
    isRecommendedRolesEnabled.value = false;
    isNewRoomAdvancedOpen.value = false;
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

function selectNewRoomEntryMode(mode) {
  newRoomEntryMode.value = mode;

  if (mode === 'public') {
    newRoomEntryPassword.value = '';
  }
}

function toggleNewRoomAdvancedSettings() {
  isNewRoomAdvancedOpen.value = !isNewRoomAdvancedOpen.value;
}

function openCreateRoomForm() {
  isCreateFormOpen.value = true;
  isNewRoomAdvancedOpen.value = false;
}

function closeCreateRoomForm() {
  isCreateFormOpen.value = false;
  isNewRoomAdvancedOpen.value = false;
}

function clampRoomPage() {
  if (currentRoomPage.value > roomPageCount.value) {
    currentRoomPage.value = roomPageCount.value;
  }
}

function clampSelectedRoom() {
  if (
    selectedRoomId.value &&
    !filteredRooms.value.some((room) => room.id === selectedRoomId.value)
  ) {
    selectedRoomId.value = null;
  }
}

function goToPreviousRoomPage() {
  currentRoomPage.value = Math.max(1, currentRoomPage.value - 1);
  selectedRoomId.value = null;
}

function goToNextRoomPage() {
  currentRoomPage.value = Math.min(
    roomPageCount.value,
    currentRoomPage.value + 1,
  );
  selectedRoomId.value = null;
}

function setRoomFilter(nextFilter) {
  roomFilter.value = nextFilter;
  currentRoomPage.value = 1;
  selectedRoomId.value = null;
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

  unsubscribeFriendships = subscribeToFriendships(
    savedUser.value.id,
    (payload) => {
      if (payload?.type === 'subscription-status') {
        return;
      }

      scheduleFriendshipsRefresh();
    },
  );
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

  unsubscribeRoomInvites = subscribeToRoomInvites(
    savedUser.value.id,
    (payload) => {
      if (payload?.type === 'subscription-status') {
        return;
      }

      scheduleRoomInvitesRefresh();
    },
  );
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
    router.push({
      path: `/rooms/${updatedInvite.roomId}`,
      query: { invited: '1' },
    });
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
  isLobbySettingsOpen.value = true;
}

function handleLobbySettingSelect({ section, item }) {
  toastStore.info(`${section} - ${item} 설정은 준비 중입니다.`);
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

function getFriendshipWithUser(userId) {
  return friendshipByUserId.value.get(userId) || null;
}

function isSelfUser(userId) {
  return userId === savedUser.value?.id;
}

function canSendFriendRequestToUser(user) {
  return Boolean(
    user?.id &&
    !isSelfUser(user.id) &&
    !getFriendshipWithUser(user.id) &&
    !sendingFriendRequestUserIds.value.has(user.id),
  );
}

function getFriendRequestStatusText(user) {
  const friendship = getFriendshipWithUser(user.id);

  if (isSelfUser(user.id)) {
    return '본인';
  }

  if (friendship?.status === 'accepted') {
    return '친구';
  }

  if (friendship?.status === 'pending') {
    return friendship.direction === 'incoming' ? '요청 받음' : '요청 중';
  }

  if (sendingFriendRequestUserIds.value.has(user.id)) {
    return '전송 중';
  }

  return '친구 추가';
}

function toggleLobbyUserActions(user) {
  selectedLobbyUserId.value =
    selectedLobbyUserId.value === user.id ? null : user.id;
  selectedFriendshipId.value = null;
}

function toggleFriendActions(friendship) {
  selectedFriendshipId.value =
    selectedFriendshipId.value === friendship.id ? null : friendship.id;
  selectedLobbyUserId.value = null;
}

async function sendFriendRequestToUser(user) {
  if (!canSendFriendRequestToUser(user)) {
    return;
  }

  sendingFriendRequestUserIds.value = new Set([
    ...sendingFriendRequestUserIds.value,
    user.id,
  ]);

  try {
    await sendFriendRequest(user.nickname);
    await loadFriendships();
    toastStore.success(`${user.nickname}에게 친구 요청을 보냈습니다.`);
  } catch (error) {
    toastStore.error(error.message);
  } finally {
    const nextIds = new Set(sendingFriendRequestUserIds.value);
    nextIds.delete(user.id);
    sendingFriendRequestUserIds.value = nextIds;
  }
}

async function startWhisper(target) {
  if (!target?.id || isSelfUser(target.id)) {
    return;
  }

  whisperTarget.value = {
    id: target.id,
    nickname: target.nickname,
  };
  selectedLobbyUserId.value = null;
  selectedFriendshipId.value = null;
  await nextTick();
  publicChatInput.value?.focus?.();
}

function clearWhisperTarget() {
  whisperTarget.value = null;
}

function setNewRoomMaxPlayers(count) {
  newRoomMaxPlayers.value = Math.min(12, Math.max(4, Number(count)));
}

function selectNewRoomMode(mode) {
  newRoomDescription.value = mode;

  if (mode === '친선전') {
    isRecommendedRolesEnabled.value = true;
    newRoomRoleConfig.value = getRecommendedRoleConfig(newRoomMaxPlayers.value);
    return;
  }

  if (!fixedPlayerCounts.includes(Number(newRoomMaxPlayers.value))) {
    newRoomMaxPlayers.value = 8;
  }

  isRecommendedRolesEnabled.value = false;
}

function adjustNewRoomMaxPlayers(amount) {
  setNewRoomMaxPlayers(newRoomMaxPlayers.value + amount);
}

function applyRecommendedNewRoomRoles() {
  newRoomRoleConfig.value = getRecommendedRoleConfig(newRoomMaxPlayers.value);
}

function toggleRecommendedNewRoomRoles() {
  isRecommendedRolesEnabled.value = !isRecommendedRolesEnabled.value;

  if (isRecommendedRolesEnabled.value) {
    applyRecommendedNewRoomRoles();
  }
}

function resetNewRoomRoles() {
  if (isRecommendedRolesEnabled.value) {
    applyRecommendedNewRoomRoles();
    return;
  }

  newRoomRoleConfig.value = {
    citizen: 0,
    mafia: 0,
    police: 0,
    doctor: 0,
  };
}

function adjustNewRoomRole(roleKey, amount) {
  if (!isFriendlyRoomMode.value) {
    return;
  }

  isRecommendedRolesEnabled.value = false;
  const currentCount = Number(newRoomRoleConfig.value[roleKey] || 0);
  const nextCount = Math.max(0, currentCount + amount);

  if (amount > 0 && roleConfigTotal.value >= Number(newRoomMaxPlayers.value)) {
    return;
  }

  newRoomRoleConfig.value = {
    ...newRoomRoleConfig.value,
    [roleKey]: nextCount,
  };
}

function normalizeMemberNickname(nickname) {
  return String(nickname || '')
    .trim()
    .toLowerCase();
}

function getWhisperMembers() {
  const members = new Map();

  onlineUsers.value.forEach((user) => {
    if (user?.id && user?.nickname) {
      members.set(user.id, user);
    }
  });

  acceptedFriends.value.forEach((friendship) => {
    const friend = friendship.friend;

    if (friend?.id && friend?.nickname) {
      members.set(friend.id, friend);
    }
  });

  if (lastWhisperReplyTarget.value?.id) {
    members.set(lastWhisperReplyTarget.value.id, lastWhisperReplyTarget.value);
  }

  return [...members.values()];
}

function findWhisperMemberByNickname(nickname) {
  const normalizedNickname = normalizeMemberNickname(nickname);

  if (!normalizedNickname) {
    return null;
  }

  return (
    getWhisperMembers().find(
      (member) =>
        normalizeMemberNickname(member.nickname) === normalizedNickname,
    ) || null
  );
}

function parseChatCommand(content) {
  const whisperMatch = content.match(/^\/(?:귓속말|w)\s+(\S+)\s+([\s\S]+)$/);

  if (whisperMatch) {
    const whisperContent = whisperMatch[2].trim();

    if (!whisperContent) {
      return {
        type: 'error',
        message: '사용법: /귓속말 대상닉네임 메시지 또는 /w 대상닉네임 메시지',
      };
    }

    return {
      type: 'whisper',
      nickname: whisperMatch[1],
      content: whisperContent,
    };
  }

  if (
    content === '/귓속말' ||
    content.startsWith('/귓속말 ') ||
    content === '/w' ||
    content.startsWith('/w ')
  ) {
    return {
      type: 'error',
      message: '사용법: /귓속말 대상닉네임 메시지 또는 /w 대상닉네임 메시지',
    };
  }

  const replyMatch = content.match(/^\/(?:r|답장)\s+([\s\S]+)$/);

  if (replyMatch) {
    const replyContent = replyMatch[1].trim();

    if (!replyContent) {
      return {
        type: 'error',
        message: '사용법: /r 메시지 또는 /답장 메시지',
      };
    }

    return {
      type: 'reply',
      content: replyContent,
    };
  }

  if (content === '/r' || content === '/답장') {
    return {
      type: 'error',
      message: '사용법: /r 메시지 또는 /답장 메시지',
    };
  }

  return null;
}

async function sendWhisperToTarget(target, content) {
  if (!target?.id || isSelfUser(target.id)) {
    throw new Error('귓속말 대상을 선택할 수 없습니다.');
  }

  const targetPresence = presenceByUserId.value.get(target.id);
  if (!targetPresence?.canReceiveWhisper) {
    const message = '[상대방이 채팅을 볼 수 없는 상태입니다.]';
    publicChatNotice.value = message;
    throw new Error(message);
  }

  await sendWhisperChatMessage(publicChatChannel.value, {
    userId: savedUser.value.id,
    nickname: character.value.nickname,
    targetUserId: target.id,
    targetNickname: target.nickname,
    content,
  });
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
  const confirmed = window.confirm(
    `${friendship.friend.nickname}을(를) 친구 목록에서 삭제할까요?`,
  );

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

function openJoinRoomModal(room) {
  if (!room || !canEnterRoom(room)) {
    return;
  }

  selectedJoinRoom.value = room;
  joinRoomPassword.value = '';
  isJoinRoomPasswordVisible.value = false;
  isJoinRoomModalOpen.value = true;
}

function closeJoinRoomModal() {
  isJoinRoomModalOpen.value = false;
  selectedJoinRoom.value = null;
  joinRoomPassword.value = '';
  isJoinRoomPasswordVisible.value = false;
}

async function submitJoinRoom() {
  if (!selectedJoinRoom.value || isJoiningRoom.value) {
    return;
  }

  if (!joinRoomPassword.value.trim()) {
    toastStore.error('비공개방은 비밀번호를 입력해야 합니다.');
    return;
  }

  isJoiningRoom.value = true;

  try {
    const roomId = selectedJoinRoom.value.id;
    await joinRoomRequest(roomId, joinRoomPassword.value.trim());
    closeJoinRoomModal();
    await roomStore.fetchRooms();
    router.push(`/rooms/${roomId}`);
  } catch (error) {
    toastStore.error(error.message);
  } finally {
    isJoiningRoom.value = false;
  }
}

function toggleJoinRoomPasswordVisibility() {
  isJoinRoomPasswordVisible.value = !isJoinRoomPasswordVisible.value;
}

async function enterRoom(room) {
  if (!room || isJoiningRoom.value || !canEnterRoom(room)) {
    return;
  }

  if (room?.entryMode === 'private') {
    openJoinRoomModal(room);
    return;
  }

  isJoiningRoom.value = true;

  try {
    await joinRoomRequest(room.id);
    await roomStore.fetchRooms();
    router.push(`/rooms/${room.id}`);
  } catch (error) {
    toastStore.error(error.message);
  } finally {
    isJoiningRoom.value = false;
  }
}

function getRoomStatusLabel(room) {
  return room.status === 'waiting' ? '대기중' : '게임중';
}

function getRoomStatusClass(room) {
  return room.status === 'waiting' ? 'waiting' : 'playing';
}

function getModeClass(description) {
  if (description === '친선전') return 'mode-friendly';
  return 'mode-classic';
}

function getModeDisplayLabel(description) {
  if (description === '친선전') return '커스텀';
  return '클래식';
}

function getPlayerSlots(room) {
  const currentPlayers = room.players?.length || room.currentPlayers || 0;
  const maxPlayers = room.maxPlayers || 8;

  return Array.from(
    { length: maxPlayers },
    (_, index) => index < currentPlayers,
  );
}

function getRoomAccessLabel(room) {
  return room.entryMode === 'private' ? '비공개' : '공개';
}

function getRoomAccessClass(room) {
  return room.entryMode === 'private' ? 'private' : 'public';
}

function getEntryModeLabel(mode) {
  return mode === 'private' ? '비공개방' : '공개방';
}

function canEnterRoom(room) {
  const currentPlayers = room.players?.length || room.currentPlayers || 0;

  return room.status === 'waiting' && currentPlayers < room.maxPlayers;
}

function getRoomAvailabilityLabel(room) {
  const currentPlayers = room.players?.length || room.currentPlayers || 0;

  if (room.status !== 'waiting') {
    return '게임 진행 중';
  }

  if (currentPlayers >= room.maxPlayers) {
    return '정원 초과';
  }

  return '입장 가능';
}

function getRoomAvailabilityClass(room) {
  if (room.status !== 'waiting') {
    return 'playing';
  }

  const currentPlayers = room.players?.length || room.currentPlayers || 0;

  if (currentPlayers >= room.maxPlayers) {
    return 'full';
  }

  if (room.entryMode === 'private') {
    return 'locked';
  }

  return 'available';
}

function getRoomRolePreview(room) {
  const roleConfig = room.roleConfig || getDefaultRoleConfig(room.maxPlayers);

  return [
    { key: 'mafia', label: '마피아', count: roleConfig.mafia || 0 },
    { key: 'police', label: '경찰', count: roleConfig.police || 0 },
    { key: 'doctor', label: '의사', count: roleConfig.doctor || 0 },
    { key: 'citizen', label: '시민', count: roleConfig.citizen || 0 },
  ];
}

async function submitPublicChat() {
  const content = publicChatDraft.value.trim();

  if (!content) {
    return;
  }

  if (!savedUser.value) {
    publicChatNotice.value = '로그인해야 채팅을 보낼 수 있습니다.';
    router.push('/login');
    return;
  }

  try {
    const command = parseChatCommand(content);

    if (command?.type === 'error') {
      publicChatNotice.value = command.message;
      return;
    }

    if (command?.type === 'whisper') {
      const target = findWhisperMemberByNickname(command.nickname);

      if (!target) {
        publicChatNotice.value = `${command.nickname}을(를) 로비 유저 또는 친구 목록에서 찾을 수 없습니다.`;
        return;
      }

      await sendWhisperToTarget(target, command.content);
    } else if (command?.type === 'reply') {
      if (!lastWhisperReplyTarget.value) {
        publicChatNotice.value = '답장할 귓속말 대상이 없습니다.';
        return;
      }

      await sendWhisperToTarget(lastWhisperReplyTarget.value, command.content);
    } else if (whisperTarget.value) {
      await sendWhisperToTarget(whisperTarget.value, content);
    } else {
      await sendPublicChatMessage(publicChatChannel.value, {
        userId: savedUser.value.id,
        nickname: character.value.nickname,
        content,
      });
    }
    publicChatDraft.value = '';
    publicChatNotice.value = '';
  } catch (error) {
    publicChatNotice.value = error.message;
  }
}

async function logout() {
  if (savedUser.value?.id) {
    await clearCurrentUserPresence();
  }
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
          <span aria-hidden="true">⚙️</span>
        </button>

        <div v-if="isNotificationOpen" class="notification-popover">
          <div class="notification-head">
            <strong>알림</strong>
            <span>{{ notificationCount }}</span>
          </div>

          <div class="notification-section">
            <p>방 초대 목록</p>
            <article
              v-for="invite in incomingRoomInvites"
              :key="invite.id"
              class="notification-row"
            >
              <div>
                <strong
                  >{{ invite.inviter.nickname }}님이 [{{ invite.room.title }}]
                  방으로 초대했습니다.</strong
                >
                <span>
                  방장 {{ invite.room.hostNickname }} ·
                  {{ getModeDisplayLabel(invite.room.description) }} ·
                  {{ invite.room.currentPlayers }} /
                  {{ invite.room.maxPlayers }}
                </span>
                <div class="invite-room-badges">
                  <b
                    v-if="invite.room.entryMode === 'private'"
                    class="invite-room-badge private"
                  >
                    비공개방
                  </b>
                </div>
              </div>
              <div class="notification-actions">
                <button type="button" @click="acceptRoomInvite(invite)">
                  입장
                </button>
                <button type="button" @click="rejectRoomInvite(invite.id)">
                  거절
                </button>
              </div>
            </article>
            <small v-if="incomingRoomInvites.length === 0"
              >받은 방 초대가 없습니다.</small
            >
          </div>

          <div class="notification-section">
            <p>친구 요청 목록</p>
            <article
              v-for="request in incomingFriendRequests"
              :key="request.id"
              class="notification-row"
            >
              <div>
                <strong>{{ request.friend.nickname }}</strong>
                <span>친구 요청</span>
              </div>
              <div class="notification-actions">
                <button type="button" @click="acceptFriendRequest(request.id)">
                  수락
                </button>
                <button type="button" @click="rejectFriendRequest(request.id)">
                  거절
                </button>
              </div>
            </article>
            <small v-if="incomingFriendRequests.length === 0"
              >받은 친구 요청이 없습니다.</small
            >
          </div>
        </div>
      </div>
    </header>

    <div class="lobby-content">
      <main class="main-panel">
        <section
          v-if="isCreateFormOpen"
          class="page-card create-room-panel room-form-modal"
          role="dialog"
          aria-modal="true"
          aria-labelledby="create-room-title"
        >
          <div class="section-heading">
            <div>
              <p class="eyebrow">Create</p>
              <h2 id="create-room-title">새 게임방</h2>
            </div>
            <button type="button" @click="closeCreateRoomForm">닫기</button>
          </div>

          <form
            class="create-room-form game-styled-form"
            @submit.prevent="createRoom"
          >
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
              <div v-if="!isFriendlyRoomMode" class="option-group">
                <button
                  v-for="count in fixedPlayerCounts"
                  :key="count"
                  type="button"
                  class="option-btn"
                  :class="{ active: newRoomMaxPlayers === count }"
                  @click="newRoomMaxPlayers = count"
                >
                  {{ count }}명
                </button>
              </div>
              <div v-else class="friendly-player-control">
                <strong class="friendly-count-display">
                  {{ newRoomMaxPlayers }}명
                </strong>

                <div class="friendly-slider-row">
                  <button
                    type="button"
                    class="stepper-btn"
                    :disabled="newRoomMaxPlayers <= 4"
                    @click="adjustNewRoomMaxPlayers(-1)"
                  >
                    -
                  </button>

                  <input
                    v-model.number="newRoomMaxPlayers"
                    class="player-range"
                    type="range"
                    min="4"
                    max="12"
                    step="1"
                  />

                  <button
                    type="button"
                    class="stepper-btn"
                    :disabled="newRoomMaxPlayers >= 12"
                    @click="adjustNewRoomMaxPlayers(1)"
                  >
                    +
                  </button>
                </div>

                <div class="range-labels">
                  <span>4명</span>
                  <span>12명</span>
                </div>
              </div>
            </div>

            <div class="form-group">
              <label>게임 모드</label>
              <div class="option-group">
                <button
                  type="button"
                  class="option-btn"
                  :class="{ active: newRoomDescription === '클래식' }"
                  @click="selectNewRoomMode('클래식')"
                >
                  🎭 클래식
                </button>
                <button
                  type="button"
                  class="option-btn"
                  :class="{ active: newRoomDescription === '친선전' }"
                  @click="selectNewRoomMode('친선전')"
                >
                  🛠 커스텀
                </button>
              </div>
            </div>

            <div class="room-custom-grid">
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
                    @click="selectNewRoomEntryMode('public')"
                  >
                    공개방
                  </button>
                  <button
                    type="button"
                    class="option-btn"
                    :class="{ active: newRoomEntryMode === 'private' }"
                    @click="selectNewRoomEntryMode('private')"
                  >
                    비공개방
                  </button>
                </div>
              </div>

              <div v-if="newRoomEntryMode === 'private'" class="form-group">
                <label for="new-room-entry-password">비밀번호</label>
                <input
                  id="new-room-entry-password"
                  v-model="newRoomEntryPassword"
                  type="password"
                  class="text-input"
                  placeholder="비공개방 비밀번호를 입력하세요"
                  autocomplete="new-password"
                />
              </div>
            </div>

            <section class="advanced-settings-panel">
              <button
                type="button"
                class="advanced-settings-toggle"
                :class="{ active: isNewRoomAdvancedOpen }"
                @click="toggleNewRoomAdvancedSettings"
              >
                <span>세부 설정</span>
                <strong>{{ isNewRoomAdvancedOpen ? '접기' : '펼치기' }}</strong>
              </button>

              <div v-if="isNewRoomAdvancedOpen" class="advanced-settings-grid">
                <div class="form-group">
                  <label>밤 시간</label>
                  <select v-model.number="newRoomNightTimeSeconds">
                    <option
                      v-for="seconds in nightTimeOptions"
                      :key="`night-${seconds}`"
                      :value="seconds"
                    >
                      {{ seconds }}초
                    </option>
                  </select>
                </div>

                <div class="form-group">
                  <label>토론 시간</label>
                  <select v-model.number="newRoomDiscussionTimeSeconds">
                    <option
                      v-for="seconds in discussionTimeOptions"
                      :key="`discussion-${seconds}`"
                      :value="seconds"
                    >
                      {{ seconds }}초
                    </option>
                  </select>
                </div>

                <div class="form-group">
                  <label>최소 시작 인원</label>
                  <select v-model.number="newRoomMinStartPlayers">
                    <option
                      v-for="count in newRoomMinStartPlayerOptions"
                      :key="`start-${count}`"
                      :value="count"
                    >
                      {{ count }}명
                    </option>
                  </select>
                </div>

                <div class="form-group">
                  <label>투표 시간</label>
                  <select v-model.number="newRoomVoteTimeSeconds">
                    <option
                      v-for="seconds in voteTimeOptions"
                      :key="`vote-${seconds}`"
                      :value="seconds"
                    >
                      {{ seconds }}초
                    </option>
                  </select>
                </div>

                <div class="form-group">
                  <label>동점 투표</label>
                  <select v-model="newRoomTieVoteRule">
                    <option
                      v-for="option in tieVoteOptions"
                      :key="option.value"
                      :value="option.value"
                    >
                      {{ option.label }}
                    </option>
                  </select>
                </div>

                <div class="form-group">
                  <label>관전 허용</label>
                  <div class="option-group">
                    <button
                      type="button"
                      class="option-btn"
                      :class="{ active: newRoomSpectatorAllowed }"
                      @click="newRoomSpectatorAllowed = true"
                    >
                      활성화
                    </button>
                    <button
                      type="button"
                      class="option-btn"
                      :class="{ active: !newRoomSpectatorAllowed }"
                      @click="newRoomSpectatorAllowed = false"
                    >
                      비활성화
                    </button>
                  </div>
                </div>

                <div class="form-group">
                  <label>첫날 밤 능력 사용</label>
                  <div class="option-group">
                    <button
                      type="button"
                      class="option-btn"
                      :class="{ active: newRoomFirstNightAbilityAllowed }"
                      @click="newRoomFirstNightAbilityAllowed = true"
                    >
                      활성화
                    </button>
                    <button
                      type="button"
                      class="option-btn"
                      :class="{ active: !newRoomFirstNightAbilityAllowed }"
                      @click="newRoomFirstNightAbilityAllowed = false"
                    >
                      비활성화
                    </button>
                  </div>
                </div>

                <div class="form-group">
                  <label>최후의 변론</label>
                  <div class="option-group">
                    <button
                      type="button"
                      class="option-btn"
                      :class="{ active: newRoomFinalDefenseEnabled }"
                      @click="newRoomFinalDefenseEnabled = true"
                    >
                      활성화
                    </button>
                    <button
                      type="button"
                      class="option-btn"
                      :class="{ active: !newRoomFinalDefenseEnabled }"
                      @click="newRoomFinalDefenseEnabled = false"
                    >
                      비활성화
                    </button>
                  </div>
                </div>
              </div>
            </section>

            <section
              class="role-config-section"
              :class="{
                invalid: !isRoleConfigValid,
                locked: !isFriendlyRoomMode,
              }"
            >
              <div class="role-config-header">
                <div>
                  <p class="eyebrow">Roles</p>
                  <h3>역할 구성</h3>
                </div>
                <div>
                  <span class="role-lock-status">{{
                    roleConfigStatusText
                  }}</span>
                  <strong
                    :class="{
                      valid: isRoleConfigValid,
                      invalid: !isRoleConfigValid,
                    }"
                  >
                    역할 합계 {{ roleConfigTotal }} / {{ newRoomMaxPlayers }}
                  </strong>
                </div>
              </div>

              <p v-if="isFriendlyRoomMode" class="role-config-intro">
                커스텀은 역할 구성을 자유롭게 변경할 수 있습니다.
              </p>

              <div class="role-config-list">
                <article
                  v-for="role in roleOptions"
                  :key="role.key"
                  class="role-config-row"
                >
                  <span>{{ role.label }}</span>
                  <div class="role-stepper">
                    <button
                      type="button"
                      :disabled="
                        !isFriendlyRoomMode || newRoomRoleConfig[role.key] <= 0
                      "
                      @click="adjustNewRoomRole(role.key, -1)"
                    >
                      -
                    </button>
                    <strong>{{ newRoomRoleConfig[role.key] }}</strong>
                    <button
                      type="button"
                      :disabled="
                        !isFriendlyRoomMode ||
                        roleConfigTotal >= newRoomMaxPlayers
                      "
                      @click="adjustNewRoomRole(role.key, 1)"
                    >
                      +
                    </button>
                  </div>
                </article>
              </div>

              <div v-if="isFriendlyRoomMode" class="role-config-actions">
                <button
                  type="button"
                  :class="{ active: isRecommendedRolesEnabled }"
                  @click="toggleRecommendedNewRoomRoles"
                >
                  추천 구성 적용
                </button>
                <button type="button" @click="resetNewRoomRoles">초기화</button>
              </div>

              <p v-if="!isFriendlyRoomMode" class="role-config-help">
                {{ roleConfigStatusText }}으로 역할 인원수는 수정할 수 없습니다.
              </p>
              <p v-else-if="!isRoleConfigValid" class="role-config-warning">
                역할 인원수 합계가 참가 인원과 같아야 방을 생성할 수 있습니다.
              </p>
            </section>

            <button
              type="submit"
              class="submit-btn"
              :disabled="isCreatingRoom || !isRoleConfigValid"
            >
              {{ isCreatingRoom ? '생성 중...' : '방 생성' }}
            </button>
          </form>
        </section>

        <section
          v-if="isJoinRoomModalOpen && selectedJoinRoom"
          class="page-card create-room-panel room-form-modal"
          role="dialog"
          aria-modal="true"
          aria-labelledby="join-room-title"
          @click.self="closeJoinRoomModal"
        >
          <div class="section-heading">
            <div>
              <p class="eyebrow">Join</p>
              <h2 id="join-room-title">비공개방 입장</h2>
            </div>
            <button
              type="button"
              :disabled="isJoiningRoom"
              @click="closeJoinRoomModal"
            >
              닫기
            </button>
          </div>

          <form
            class="create-room-form game-styled-form"
            @submit.prevent="submitJoinRoom"
          >
            <div class="form-group">
              <label>방 제목</label>
              <input :value="selectedJoinRoom.title" type="text" readonly />
            </div>

            <div class="form-group">
              <label for="join-room-password">비밀번호</label>
              <div class="password-input-shell">
                <input
                  id="join-room-password"
                  v-model="joinRoomPassword"
                  :type="isJoinRoomPasswordVisible ? 'text' : 'password'"
                  class="text-input"
                  placeholder="비공개방 비밀번호를 입력하세요"
                  autocomplete="current-password"
                />
                <button
                  type="button"
                  class="password-toggle-icon"
                  :aria-label="
                    isJoinRoomPasswordVisible
                      ? '비밀번호 숨기기'
                      : '비밀번호 보기'
                  "
                  :title="
                    isJoinRoomPasswordVisible
                      ? '비밀번호 숨기기'
                      : '비밀번호 보기'
                  "
                  @click="toggleJoinRoomPasswordVisibility"
                >
                  <svg
                    v-if="isJoinRoomPasswordVisible"
                    viewBox="0 0 24 24"
                    aria-hidden="true"
                  >
                    <path
                      d="M2.5 12s3.5-6.5 9.5-6.5 9.5 6.5 9.5 6.5-3.5 6.5-9.5 6.5S2.5 12 2.5 12Z"
                      fill="none"
                      stroke="currentColor"
                      stroke-width="1.8"
                      stroke-linecap="round"
                      stroke-linejoin="round"
                    />
                    <circle
                      cx="12"
                      cy="12"
                      r="2.9"
                      fill="none"
                      stroke="currentColor"
                      stroke-width="1.8"
                    />
                  </svg>
                  <svg v-else viewBox="0 0 24 24" aria-hidden="true">
                    <path
                      d="M3.5 4.5 20.5 19.5"
                      fill="none"
                      stroke="currentColor"
                      stroke-width="1.8"
                      stroke-linecap="round"
                    />
                    <circle
                      cx="12"
                      cy="12"
                      r="2.9"
                      fill="none"
                      stroke="currentColor"
                      stroke-width="1.8"
                    />
                    <path
                      d="M2.5 12s3.5-6.5 9.5-6.5c1.7 0 3.3.38 4.7 1.04M21.5 12s-3.5 6.5-9.5 6.5c-1.7 0-3.3-.38-4.7-1.04"
                      fill="none"
                      stroke="currentColor"
                      stroke-width="1.8"
                      stroke-linecap="round"
                      stroke-linejoin="round"
                    />
                  </svg>
                </button>
              </div>
            </div>

            <p class="role-config-help">
              비공개방은 비밀번호를 입력해야 입장할 수 있습니다.
            </p>

            <div class="room-preview-actions compact">
              <button type="submit" :disabled="isJoiningRoom">
                {{ isJoiningRoom ? '입장 중...' : '입장' }}
              </button>
              <button
                type="button"
                :disabled="isJoiningRoom"
                @click="closeJoinRoomModal"
              >
                취소
              </button>
            </div>
          </form>
        </section>

        <section
          class="page-card room-board"
          aria-labelledby="room-board-title"
        >
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
            <div class="room-filter-summary" aria-label="Room filters">
              <button
                v-for="option in roomFilterOptions"
                :key="option.value"
                type="button"
                :class="{ active: roomFilter === option.value }"
                @click="setRoomFilter(option.value)"
              >
                {{ option.label }} {{ option.count }}
              </button>
            </div>
            <div class="room-tools">
              <div class="room-actions">
                <RouterLink class="primary" :to="quickJoinPath"
                  >빠른 입장</RouterLink
                >
                <button type="button" @click="openCreateRoomForm">
                  방 만들기
                </button>
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
            <p v-else-if="isLoadingRooms" class="muted">
              방 목록을 불러오는 중입니다.
            </p>
            <p v-else-if="filteredRooms.length === 0" class="muted">
              아직 생성된 방이 없습니다.
            </p>

            <article
              v-for="room in paginatedRooms"
              :key="room.id"
              class="room-entry"
              :class="{ expanded: selectedRoomId === room.id }"
            >
              <div class="room-row" @click="toggleRoomDetails(room.id)">
                <button
                  class="join-pill"
                  type="button"
                  :disabled="isJoiningRoom || !canEnterRoom(room)"
                  @click.stop="enterRoom(room)"
                >
                  <svg
                    v-if="room.entryMode === 'private'"
                    class="lock-icon"
                    viewBox="0 0 24 24"
                    aria-hidden="true"
                    focusable="false"
                  >
                    <path
                      d="M17 10h1a2 2 0 0 1 2 2v7a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2v-7a2 2 0 0 1 2-2h1V8a5 5 0 0 1 10 0v2Zm-8 0h6V8a3 3 0 0 0-6 0v2Zm4 5.73A2 2 0 1 0 11 15.73V18h2v-2.27Z"
                      fill="currentColor"
                    />
                  </svg>
                  입장
                </button>
                <button
                  class="room-detail-trigger"
                  type="button"
                  :aria-expanded="selectedRoomId === room.id"
                  @click.stop="toggleRoomDetails(room.id)"
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
                    <b
                      class="status-badge"
                      :class="getModeClass(room.description)"
                    >
                      {{ getModeDisplayLabel(room.description) }}
                    </b>
                  </span>
                </button>
              </div>

              <div
                v-if="selectedRoomId === room.id"
                class="room-details"
                @click.stop
              >
                <div class="room-preview-header">
                  <div>
                    <p class="eyebrow">Room Preview</p>
                    <h3>{{ room.title }}</h3>
                    <span>방장 {{ room.hostNickname }}</span>
                  </div>
                </div>

                <div
                  class="room-preview-summary"
                  aria-label="Room preview summary"
                >
                  <b class="status-badge" :class="getRoomStatusClass(room)">
                    {{ getRoomStatusLabel(room) }}
                  </b>
                  <b class="status-badge" :class="getRoomAccessClass(room)">
                    {{ getRoomAccessLabel(room) }}
                  </b>
                  <b class="status-badge summary-count">
                    {{ room.players?.length || room.currentPlayers || 0 }} /
                    {{ room.maxPlayers }}
                  </b>
                  <b
                    class="status-badge"
                    :class="getModeClass(room.description)"
                  >
                    {{ getModeDisplayLabel(room.description) }}
                  </b>
                  <b
                    class="status-badge"
                    :class="getRoomAvailabilityClass(room)"
                  >
                    {{ getRoomAvailabilityLabel(room) }}
                  </b>
                  <b
                    v-if="room.entryMode === 'private'"
                    class="status-badge private-warning"
                  >
                    비밀번호 필요
                  </b>
                </div>

                <section class="room-preview-section settings">
                  <h4>게임 설정</h4>
                  <dl>
                    <div>
                      <dt>참가 인원</dt>
                      <dd>{{ room.maxPlayers }}명</dd>
                    </div>
                    <div>
                      <dt>게임 모드</dt>
                      <dd>{{ getModeDisplayLabel(room.description) }}</dd>
                    </div>
                    <div>
                      <dt>역할 공개</dt>
                      <dd>
                        {{
                          room.roleRevealMode === 'public' ? '공개' : '비공개'
                        }}
                      </dd>
                    </div>
                    <div>
                      <dt>입장 방식</dt>
                      <dd>{{ getEntryModeLabel(room.entryMode) }}</dd>
                    </div>
                  </dl>
                </section>

                <section class="room-preview-section roles compact">
                  <h4>역할 구성</h4>
                  <div class="preview-role-list">
                    <span
                      v-for="role in getRoomRolePreview(room)"
                      :key="role.key"
                    >
                      {{ role.label }} x{{ role.count }}
                    </span>
                  </div>
                </section>

                <div class="room-details-heading">
                  <strong>참가 인원</strong>
                  <span
                    >{{ room.players?.length || 0 }} /
                    {{ room.maxPlayers }}</span
                  >
                </div>

                <ul v-if="room.players?.length">
                  <li v-for="player in room.players" :key="player.userId">
                    <span class="preview-player-main">
                      <i aria-hidden="true"></i>
                      <strong>{{ player.nickname }}</strong>
                      <em>Lv.{{ player.level || 1 }}</em>
                    </span>
                    <span class="preview-player-state">
                      <b v-if="player.isHost">방장</b>
                      <small>{{
                        player.isHost
                          ? '준비 면제'
                          : player.isReady
                            ? '준비 완료'
                            : '대기 중'
                      }}</small>
                    </span>
                  </li>
                </ul>
                <p v-else class="muted">아직 입장한 플레이어가 없습니다.</p>
                <div class="room-preview-actions">
                  <span :class="getRoomAvailabilityClass(room)">
                    {{ getRoomAvailabilityLabel(room) }}
                  </span>
                  <button
                    v-if="room.entryMode !== 'private'"
                    type="button"
                    :disabled="isJoiningRoom || !canEnterRoom(room)"
                    @click="enterRoom(room)"
                  >
                    입장하기
                  </button>
                  <button
                    v-else
                    type="button"
                    :disabled="isJoiningRoom || !canEnterRoom(room)"
                    @click="enterRoom(room)"
                  >
                    <svg
                      class="lock-icon"
                      viewBox="0 0 24 24"
                      aria-hidden="true"
                      focusable="false"
                    >
                      <path
                        d="M17 10h1a2 2 0 0 1 2 2v7a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2v-7a2 2 0 0 1 2-2h1V8a5 5 0 0 1 10 0v2Zm-8 0h6V8a3 3 0 0 0-6 0v2Zm4 5.73A2 2 0 1 0 11 15.73V18h2v-2.27Z"
                        fill="currentColor"
                      />
                    </svg>
                    비밀번호 입력 후 입장
                  </button>
                  <button type="button" disabled>관전하기</button>
                  <button type="button" @click="selectedRoomId = null">
                    닫기
                  </button>
                </div>
              </div>
            </article>
          </div>

          <div
            v-if="filteredRooms.length > ROOMS_PER_PAGE"
            class="room-pagination"
            aria-label="Room pages"
          >
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

          <div class="room-board-footer">
            <div class="room-actions">
              <RouterLink class="primary" :to="quickJoinPath"
                >빠른 입장</RouterLink
              >
              <button type="button" @click="openCreateRoomForm">
                방 만들기
              </button>
            </div>
          </div>
        </section>

        <section
          class="page-card chat-card"
          aria-labelledby="public-chat-title"
        >
          <div class="section-heading">
            <div>
              <p class="eyebrow">Public Chat</p>
              <h2 id="public-chat-title">공용 채팅방</h2>
            </div>
          </div>

          <div class="chat-log" aria-live="polite">
            <article
              v-for="chat in publicChatMessages"
              :key="chat.id"
              class="chat-line"
              :class="{ system: chat.isSystem, whisper: chat.isWhisper }"
            >
              <strong>
                <template v-if="chat.isWhisper">
                  <span class="whisper-label">귓속말</span>
                  {{ chat.nickname }} → {{ chat.targetNickname }}
                </template>
                <template v-else>{{ chat.nickname }}</template>
              </strong>
              <p>{{ chat.content }}</p>
              <time>{{ chat.createdAt }}</time>
            </article>
          </div>

          <p v-if="publicChatNotice" class="chat-notice">
            {{ publicChatNotice }}
          </p>

          <form class="chat-form" @submit.prevent="submitPublicChat">
            <div v-if="whisperTarget" class="whisper-target">
              <span>{{ whisperTarget.nickname }}에게 귓속말</span>
              <button type="button" @click="clearWhisperTarget">해제</button>
            </div>
            <input
              ref="publicChatInput"
              v-model="publicChatDraft"
              type="text"
              maxlength="200"
              :placeholder="
                whisperTarget ? '귓속말 메시지' : '공용 채팅 메시지'
              "
            />
            <button type="submit">
              {{ whisperTarget ? '귓속말' : '전송' }}
            </button>
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
              <i
                :style="{ width: `${Math.min(100, character.expPercent)}%` }"
              ></i>
            </div>
          </div>

          <div class="profile-tags">
            <span>{{ character.characterName }}</span>
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
              <h2 id="visitor-title">접속 유저</h2>
            </div>
            <span class="user-count">{{ onlineUsers.length }}</span>
          </div>

          <ul>
            <li
              v-for="user in onlineUsers"
              :key="user.id"
              :class="{ selected: selectedLobbyUserId === user.id }"
            >
              <button
                class="user-row-button"
                type="button"
                :aria-expanded="selectedLobbyUserId === user.id"
                @click="toggleLobbyUserActions(user)"
              >
                <strong>
                  <i aria-hidden="true"></i>
                  {{ user.nickname }}
                </strong>
                <span>{{ getPresenceStatusLabel(user.status) }}</span>
              </button>
              <div
                v-if="selectedLobbyUserId === user.id"
                class="member-action-panel"
              >
                <button
                  type="button"
                  :disabled="isSelfUser(user.id)"
                  @click="startWhisper(user)"
                >
                  귓속말
                </button>
                <button
                  type="button"
                  :disabled="!canSendFriendRequestToUser(user)"
                  @click="sendFriendRequestToUser(user)"
                >
                  {{ getFriendRequestStatusText(user) }}
                </button>
              </div>
            </li>
          </ul>

          <button v-if="false" class="invite-button" type="button">
            친구 초대
          </button>
          <div
            v-if="false && incomingRoomInvites.length"
            class="room-invite-panel"
          >
            <div class="friend-heading">
              <div>
                <p class="eyebrow">Invites</p>
                <h3>방 초대</h3>
              </div>
              <span>{{ incomingRoomInvites.length }}</span>
            </div>

            <article
              v-for="invite in incomingRoomInvites"
              :key="invite.id"
              class="room-invite-row"
            >
              <div>
                <strong>{{ invite.room.title }}</strong>
                <span>{{ invite.inviter.nickname }}님의 초대</span>
              </div>
              <div class="friend-actions">
                <button type="button" @click="acceptRoomInvite(invite)">
                  입장
                </button>
                <button type="button" @click="rejectRoomInvite(invite.id)">
                  거절
                </button>
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

            <form
              class="friend-request-form"
              @submit.prevent="submitFriendRequest"
            >
              <input
                v-model="friendNickname"
                type="text"
                placeholder="닉네임으로 친구 추가"
                :disabled="isSendingFriendRequest"
              />
              <button
                type="submit"
                :disabled="!friendNickname.trim() || isSendingFriendRequest"
              >
                요청
              </button>
            </form>

            <div
              v-if="false && incomingFriendRequests.length"
              class="friend-request-list"
            >
              <p>받은 요청</p>
              <article
                v-for="request in incomingFriendRequests"
                :key="request.id"
                class="friend-row request"
              >
                <strong>{{ request.friend.nickname }}</strong>
                <div class="friend-actions">
                  <button
                    type="button"
                    @click="acceptFriendRequest(request.id)"
                  >
                    수락
                  </button>
                  <button
                    type="button"
                    @click="rejectFriendRequest(request.id)"
                  >
                    거절
                  </button>
                </div>
              </article>
            </div>

            <ul class="friend-list">
              <li v-if="isLoadingFriends" class="friend-empty">
                친구 목록을 불러오는 중...
              </li>
              <li v-else-if="acceptedFriends.length === 0" class="friend-empty">
                아직 등록된 친구가 없습니다.
              </li>
              <li
                v-for="friendship in acceptedFriends"
                v-else
                :key="friendship.id"
                class="friend-row"
                :class="{ selected: selectedFriendshipId === friendship.id }"
              >
                <button
                  class="friend-row-main"
                  type="button"
                  :aria-expanded="selectedFriendshipId === friendship.id"
                  @click="toggleFriendActions(friendship)"
                >
                  <strong>
                    <i
                      :class="{ offline: friendship.status === 'offline' }"
                      aria-hidden="true"
                    ></i>
                    {{ friendship.friend.nickname }}
                  </strong>
                  <span>{{ friendship.statusText }}</span>
                </button>
                <div
                  v-if="selectedFriendshipId === friendship.id"
                  class="member-action-panel"
                >
                  <button
                    type="button"
                    @click="startWhisper(friendship.friend)"
                  >
                    귓속말
                  </button>
                  <button
                    type="button"
                    aria-label="친구 삭제"
                    @click="deleteFriend(friendship)"
                  >
                    삭제
                  </button>
                </div>
              </li>
            </ul>

            <div v-if="outgoingFriendRequests.length" class="outgoing-requests">
              <span>대기중 {{ outgoingFriendRequests.length }}</span>
            </div>
          </div>
        </section>
      </aside>
    </div>

    <GameSettingsModal
      v-model="isLobbySettingsOpen"
      title="로비 설정"
      :extra-sections="lobbySettingsSections"
      @select="handleLobbySettingSelect"
    />
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
    linear-gradient(180deg, rgba(80, 46, 30, 0.44), rgba(20, 14, 11, 0.78)),
    rgba(20, 17, 15, 0.86);
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
  background: linear-gradient(
    90deg,
    transparent,
    rgba(255, 132, 38, 0.12),
    transparent
  );
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
  background: linear-gradient(
    180deg,
    rgba(255, 190, 85, 0.12),
    rgba(48, 20, 16, 0.72)
  );
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
  background: linear-gradient(
    180deg,
    rgba(255, 190, 85, 0.2),
    rgba(84, 27, 22, 0.78)
  );
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
  background: linear-gradient(
    180deg,
    rgba(73, 34, 22, 0.96),
    rgba(13, 9, 7, 0.98)
  );
  border: 1px solid rgba(255, 190, 85, 0.24);
  border-radius: 0.95rem;
  box-shadow:
    0 22px 55px rgba(0, 0, 0, 0.42),
    0 0 24px rgba(255, 106, 42, 0.12);
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

.invite-room-badges {
  display: flex;
  gap: 0.35rem;
  margin-top: 0.2rem;
}

.invite-room-badge {
  background: rgba(255, 190, 85, 0.08);
  border: 1px solid rgba(255, 190, 85, 0.18);
  border-radius: 999px;
  color: var(--color-accent);
  display: inline-flex;
  font-size: 0.72rem;
  font-weight: 900;
  padding: 0.2rem 0.5rem;
}

.invite-room-badge.private {
  background: rgba(252, 165, 165, 0.12);
  border-color: rgba(252, 165, 165, 0.24);
  color: #fca5a5;
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

.room-board > .section-heading > .room-tools {
  display: none;
}

.room-board-footer {
  display: flex;
  justify-content: flex-end;
  min-width: 0;
}

.room-actions a,
.room-actions button,
.section-heading button,
.chat-form button,
.room-pagination button,
.invite-button {
  background: linear-gradient(
    180deg,
    rgba(255, 190, 85, 0.11),
    rgba(80, 31, 21, 0.22)
  );
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

.advanced-settings-panel {
  background:
    linear-gradient(180deg, rgba(255, 190, 85, 0.05), rgba(12, 7, 4, 0.5)),
    rgba(10, 6, 4, 0.76);
  border: 1px solid rgba(255, 190, 85, 0.12);
  border-radius: 0.7rem;
  display: grid;
  gap: 0.8rem;
  padding: 0.85rem;
}

.advanced-settings-toggle {
  align-items: center;
  background: linear-gradient(180deg, #3b1f12, #24110a);
  border: 1px solid rgba(255, 166, 77, 0.24);
  border-radius: 0.65rem;
  color: #f8e7c0;
  cursor: pointer;
  display: flex;
  font: inherit;
  font-weight: 800;
  justify-content: space-between;
  min-height: 44px;
  padding: 0.75rem 0.8rem;
  transition:
    background 0.16s ease,
    border-color 0.16s ease,
    box-shadow 0.16s ease,
    color 0.16s ease,
    transform 0.16s ease;
  width: 100%;
}

.advanced-settings-toggle strong {
  color: #ffcc7a;
}

.advanced-settings-toggle:hover {
  background: linear-gradient(180deg, #5a2b16, #32170d);
  border-color: rgba(255, 166, 77, 0.35);
  box-shadow:
    0 0 12px rgba(255, 128, 47, 0.14),
    inset 0 0 10px rgba(255, 255, 255, 0.02);
}

.advanced-settings-toggle.active {
  background: linear-gradient(180deg, #6f3518, #3d1b0e);
  border-color: rgba(255, 166, 77, 0.42);
  box-shadow:
    0 0 14px rgba(255, 128, 47, 0.16),
    inset 0 0 12px rgba(255, 204, 122, 0.04);
}

.advanced-settings-grid {
  display: grid;
  gap: 0.85rem;
  grid-template-columns: repeat(2, minmax(0, 1fr));
}

.advanced-settings-grid .form-group {
  margin: 0;
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

.room-filter-summary,
.room-tools,
.chat-status,
.user-count {
  align-items: center;
  display: flex;
  flex-wrap: wrap;
  gap: 0.5rem;
}

.room-filter-summary {
  justify-content: flex-end;
  margin-left: auto;
}

.room-tools {
  justify-content: flex-end;
}

.room-summary {
  display: none;
}

.room-filter-summary button,
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

.room-filter-summary button {
  cursor: pointer;
  font: inherit;
  transition:
    background 0.16s ease,
    border-color 0.16s ease,
    box-shadow 0.16s ease,
    color 0.16s ease,
    transform 0.16s ease;
}

.room-filter-summary button:hover,
.room-filter-summary button.active {
  background: linear-gradient(180deg, #ffbe55, #c87127);
  border-color: rgba(255, 210, 130, 0.42);
  box-shadow: 0 0 16px rgba(255, 143, 54, 0.18);
  color: #17100b;
}

.room-filter-summary button:active {
  transform: translateY(1px);
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

.create-room-panel.room-form-modal {
  isolation: isolate;
  left: 50%;
  max-height: min(86vh, 760px);
  max-width: 760px;
  overflow-y: auto;
  position: fixed;
  top: 50%;
  transform: translate(-50%, -50%);
  width: min(calc(100vw - 2rem), 760px);
  z-index: 70;
  background:
    linear-gradient(180deg, rgba(61, 34, 20, 0.98), rgba(18, 10, 7, 0.99)),
    rgba(18, 10, 7, 0.98);
  border: 1px solid rgba(255, 190, 85, 0.18);
  box-shadow:
    0 32px 90px rgba(0, 0, 0, 0.62),
    0 0 22px rgba(255, 143, 54, 0.08);
  scrollbar-color: rgba(255, 190, 85, 0.45) rgba(20, 14, 11, 0.84);
  scrollbar-width: thin;
}

.create-room-panel.room-form-modal::before {
  background: rgba(0, 0, 0, 0.72);
  content: '';
  inset: 0;
  position: fixed;
  z-index: -1;
}

.create-room-panel.room-form-modal .create-room-form {
  grid-template-columns: 1fr;
  gap: 0.9rem;
}

.create-room-panel.room-form-modal::-webkit-scrollbar {
  width: 0.62rem;
}

.create-room-panel.room-form-modal::-webkit-scrollbar-track {
  background: rgba(20, 14, 11, 0.72);
  border-radius: 999px;
}

.create-room-panel.room-form-modal::-webkit-scrollbar-thumb {
  background: linear-gradient(
    180deg,
    rgba(255, 190, 85, 0.66),
    rgba(201, 113, 29, 0.66)
  );
  border: 2px solid rgba(20, 14, 11, 0.84);
  border-radius: 999px;
}

.password-input-shell {
  position: relative;
}

.password-input-shell .text-input {
  padding-right: 3rem;
}

.password-toggle-icon {
  align-items: center;
  background: transparent;
  border: none;
  color: rgba(255, 190, 85, 0.78);
  cursor: pointer;
  display: inline-flex;
  height: 2.2rem;
  justify-content: center;
  padding: 0;
  position: absolute;
  right: 0.65rem;
  top: 50%;
  transform: translateY(-50%);
  width: 2.2rem;
}

.password-toggle-icon:hover {
  color: #ffd88a;
}

.password-toggle-icon svg {
  display: block;
  height: 1.15rem;
  width: 1.15rem;
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
  grid-template-columns:
    5rem minmax(8rem, 0.9fr) minmax(5.25rem, 6.5rem) minmax(8.75rem, 10.5rem)
    7rem
    4.25rem;
  min-width: 0;
  padding: 0.65rem 0.8rem;
}

.room-table-header span:first-child {
  order: 1;
  text-align: right;
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
  background: linear-gradient(
    180deg,
    rgba(255, 255, 255, 0.075),
    rgba(0, 0, 0, 0.05)
  );
  border: 1px solid var(--color-border);
  border-radius: 0.75rem;
  color: var(--color-text);
  cursor: pointer;
  display: grid;
  gap: 0.8rem;
  grid-template-columns: minmax(0, 1fr) 4.25rem;
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
  background: linear-gradient(
    180deg,
    rgba(255, 190, 85, 0.13),
    rgba(90, 28, 18, 0.18)
  );
  border-color: rgba(255, 190, 85, 0.38);
  box-shadow: 0 0 22px rgba(255, 132, 38, 0.12);
}

.room-row:focus-within {
  outline: 2px solid rgba(255, 190, 85, 0.28);
  outline-offset: 2px;
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
  grid-template-columns:
    5rem minmax(8rem, 0.9fr) minmax(5.25rem, 6.5rem) minmax(8.75rem, 10.5rem)
    7rem;
  min-width: 0;
  order: 0;
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
  align-items: center;
  background: linear-gradient(180deg, #ffbe55, #b85a1f);
  border: 1px solid rgba(255, 230, 160, 0.4);
  border-radius: 999px;
  color: #14110f;
  cursor: pointer;
  display: inline-flex;
  font: inherit;
  font-size: 0.82rem;
  font-weight: 900;
  gap: 0.28rem;
  justify-self: end;
  order: 1;
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

.join-pill:disabled {
  cursor: not-allowed;
  filter: grayscale(0.35);
  opacity: 0.5;
}

.lock-icon {
  flex: 0 0 auto;
  height: 0.95em;
  width: 0.95em;
}

.slot-meter {
  align-items: center;
  display: flex;
  gap: 0.18rem;
  min-width: 0;
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
  flex: 0 0 auto;
  margin-left: 0.25rem;
  min-width: 2.75rem;
  text-align: right;
  white-space: nowrap;
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

.status-badge.public,
.status-badge.available {
  background: rgba(34, 197, 94, 0.13);
  border-color: rgba(34, 197, 94, 0.38);
  color: #86efac;
}

.status-badge.private,
.status-badge.locked {
  background: rgba(255, 190, 85, 0.12);
  border-color: rgba(255, 190, 85, 0.34);
  color: #ffd28a;
}

.status-badge.full {
  background: rgba(239, 68, 68, 0.16);
  border-color: rgba(239, 68, 68, 0.38);
  color: #fca5a5;
}

.room-details {
  background:
    linear-gradient(180deg, rgba(255, 190, 85, 0.075), rgba(20, 12, 8, 0.42)),
    rgba(20, 17, 15, 0.62);
  border: 1px solid rgba(255, 190, 85, 0.22);
  border-radius: 0.85rem;
  display: grid;
  gap: 0.85rem;
  padding: 0.8rem;
  transition:
    border-color 0.18s ease,
    box-shadow 0.18s ease;
}

.room-entry.expanded .room-details {
  box-shadow: 0 0 18px rgba(255, 143, 54, 0.1);
}

.room-preview-header {
  align-items: flex-start;
  border-bottom: 1px solid rgba(255, 190, 85, 0.12);
  display: flex;
  gap: 0.75rem;
  justify-content: space-between;
  padding-bottom: 0.55rem;
}

.room-preview-header h3 {
  color: var(--color-heading);
  font-size: 1rem;
  font-weight: 900;
  margin: 0.12rem 0 0.2rem;
}

.room-preview-header span,
.room-preview-section dt {
  color: rgba(255, 245, 224, 0.56);
  font-size: 0.78rem;
}

.room-preview-summary {
  align-items: center;
  background: rgba(0, 0, 0, 0.16);
  border: 1px solid rgba(255, 190, 85, 0.12);
  border-radius: 0.65rem;
  display: flex;
  flex-wrap: wrap;
  gap: 0.35rem 0.4rem;
  justify-content: flex-start;
  padding: 0.45rem 0.55rem;
}

.room-preview-summary .status-badge {
  font-size: 0.75rem;
  padding: 0.32rem 0.55rem;
}

.room-preview-summary .summary-count {
  color: #ffdf9e;
}

.room-preview-summary .private-warning {
  background: rgba(248, 113, 113, 0.12);
  border-color: rgba(248, 113, 113, 0.28);
  color: #fecaca;
}

.room-preview-grid {
  display: grid;
  gap: 0.2rem;
  grid-template-columns: minmax(0, 1fr);
}

.room-preview-section {
  background: rgba(0, 0, 0, 0.18);
  border: 1px solid rgba(255, 190, 85, 0.12);
  border-radius: 0.7rem;
  display: grid;
  gap: 0.45rem;
  min-width: 0;
  padding: 0.55rem 0.6rem;
}

.room-preview-section.settings {
  margin-top: 0.05rem;
}

.room-preview-section h4 {
  color: #ffd28a;
  font-size: 0.79rem;
  font-weight: 900;
  margin: 0;
}

.room-preview-section dl {
  display: grid;
  gap: 0.28rem;
  margin: 0;
}

.room-preview-section dl div {
  display: grid;
  gap: 0.6rem;
  grid-template-columns: minmax(4.8rem, 5.7rem) minmax(0, 1fr);
  align-items: center;
}

.room-preview-section dt {
  line-height: 1.2;
}

.room-preview-section dd {
  color: #ffdf9e;
  font-size: 0.82rem;
  font-weight: 900;
  margin: 0;
  text-align: right;
}

.room-preview-section.roles.compact {
  padding-top: 0.45rem;
}

.room-preview-section.roles.compact h4 {
  margin-bottom: 0.1rem;
}

.preview-role-list {
  display: flex;
  flex-wrap: wrap;
  gap: 0.3rem;
}

.preview-role-list span {
  background: rgba(255, 190, 85, 0.07);
  border: 1px solid rgba(255, 190, 85, 0.12);
  border-radius: 999px;
  color: rgba(255, 245, 224, 0.82);
  font-size: 0.76rem;
  font-weight: 900;
  padding: 0.28rem 0.5rem;
  text-align: center;
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

.preview-player-main,
.preview-player-state {
  align-items: center;
  display: flex;
  gap: 0.42rem;
  min-width: 0;
}

.preview-player-main i {
  background: #22c55e;
  border-radius: 999px;
  box-shadow: 0 0 10px rgba(34, 197, 94, 0.36);
  flex: 0 0 auto;
  height: 0.5rem;
  width: 0.5rem;
}

.preview-player-main strong {
  color: var(--color-heading);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.preview-player-main em,
.preview-player-state b {
  background: rgba(255, 190, 85, 0.1);
  border: 1px solid rgba(255, 190, 85, 0.18);
  border-radius: 999px;
  color: #ffd28a;
  flex: 0 0 auto;
  font-size: 0.72rem;
  font-style: normal;
  font-weight: 900;
  padding: 0.2rem 0.4rem;
}

.room-preview-actions {
  align-items: center;
  border-top: 1px solid rgba(255, 190, 85, 0.12);
  display: flex;
  flex-wrap: wrap;
  gap: 0.5rem;
  justify-content: flex-end;
  padding-top: 0.7rem;
}

.room-preview-actions > span {
  border: 1px solid rgba(255, 190, 85, 0.16);
  border-radius: 999px;
  color: rgba(255, 245, 224, 0.74);
  font-size: 0.78rem;
  font-weight: 900;
  margin-right: auto;
  padding: 0.32rem 0.55rem;
}

.room-preview-actions > span:not(.available):not(.full):not(.playing) {
  display: none;
}

.room-preview-actions > span.available {
  border-color: rgba(34, 197, 94, 0.38);
  color: #86efac;
}

.room-preview-actions > span.full,
.room-preview-actions > span.playing {
  border-color: rgba(239, 68, 68, 0.38);
  color: #fca5a5;
}

.room-preview-actions button {
  align-items: center;
  background: linear-gradient(
    180deg,
    rgba(255, 190, 85, 0.13),
    rgba(80, 31, 21, 0.24)
  );
  border: 1px solid rgba(255, 190, 85, 0.24);
  border-radius: 0.55rem;
  color: var(--color-text);
  cursor: pointer;
  display: inline-flex;
  font: inherit;
  font-size: 0.8rem;
  font-weight: 900;
  gap: 0.32rem;
  justify-content: center;
  padding: 0.55rem 0.75rem;
  transition:
    border-color 0.16s ease,
    box-shadow 0.16s ease,
    transform 0.16s ease;
}

.room-preview-actions button:hover:not(:disabled) {
  border-color: rgba(255, 210, 130, 0.55);
  box-shadow: 0 0 14px rgba(255, 143, 54, 0.16);
  transform: translateY(-1px);
}

.room-preview-actions button:disabled {
  cursor: not-allowed;
  opacity: 0.48;
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
  grid-template-columns:
    minmax(10rem, 1fr) minmax(14rem, 1.35fr) minmax(7rem, 0.45fr)
    auto;
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
  background: rgba(14, 9, 6, 0.82);
  border: 1px solid rgba(255, 190, 85, 0.18);
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
  background: rgba(18, 11, 7, 0.92);
  border-color: rgba(255, 190, 85, 0.42);
  box-shadow: 0 0 0 3px rgba(255, 190, 85, 0.08);
  outline: 0;
}

.create-room-form button {
  align-self: end;
  border-radius: 0.75rem;
  cursor: pointer;
  padding: 0.8rem 1rem;
}

.create-room-form .password-input-shell .password-toggle-icon {
  align-self: center;
  background: transparent;
  border: none;
  border-radius: 0;
  color: rgba(255, 190, 85, 0.78);
  padding: 0;
  position: absolute;
  right: 0.65rem;
  top: 50%;
  transform: translateY(-50%);
  width: 2.2rem;
  min-height: 2.2rem;
}

.create-room-form .password-input-shell .password-toggle-icon:hover {
  background: transparent;
  border: none;
  box-shadow: none;
  color: #ffd88a;
  transform: translateY(-50%);
}

.create-room-form .password-input-shell .password-toggle-icon:active {
  transform: translateY(-50%);
}

.create-room-panel.room-form-modal .section-heading button {
  background: linear-gradient(
    180deg,
    rgba(52, 29, 18, 0.96),
    rgba(28, 16, 10, 0.98)
  );
  border: 1px solid rgba(255, 190, 85, 0.18);
  color: #ffe1ab;
}

.create-room-panel.room-form-modal .section-heading button:hover {
  border-color: rgba(255, 190, 85, 0.34);
  box-shadow: 0 0 14px rgba(255, 138, 0, 0.08);
}

.friendly-player-control {
  background:
    linear-gradient(180deg, rgba(255, 190, 85, 0.06), rgba(12, 7, 4, 0.34)),
    rgba(9, 5, 3, 0.58);
  border: 1px solid rgba(255, 190, 85, 0.14);
  border-radius: 0.75rem;
  display: grid;
  gap: 0.75rem;
  padding: 0.9rem 1rem;
}

.friendly-count-display {
  color: #ffd28a;
  font-size: 1.15rem;
  font-weight: 900;
  text-align: center;
  text-shadow: 0 0 10px rgba(255, 170, 60, 0.24);
}

.friendly-slider-row {
  display: grid;
  grid-template-columns: 2.35rem minmax(0, 1fr) 2.35rem;
  align-items: center;
  gap: 0.85rem;
}

.stepper-btn {
  width: 2.35rem;
  height: 2.35rem;
  padding: 0;
  box-sizing: border-box;

  display: flex;
  align-items: center;
  justify-content: center;

  border-radius: 0.6rem;
  border: 1px solid rgba(255, 190, 85, 0.35);
  background: linear-gradient(
    180deg,
    rgba(255, 177, 71, 0.95),
    rgba(195, 95, 22, 0.95)
  );

  color: #1b0d05;
  font-size: 1.15rem;
  font-weight: 900;
  line-height: 1;

  cursor: pointer;
}

.player-range {
  width: 100%;
  accent-color: #f0a329;
}

.range-labels {
  display: grid;
  grid-template-columns: 2.35rem minmax(0, 1fr) 2.35rem;
  color: rgba(255, 244, 220, 0.52);
  font-size: 0.78rem;
  font-weight: 700;
}

.range-labels span:first-child {
  grid-column: 2;
  justify-self: start;
}

.range-labels span:last-child {
  grid-column: 2;
  justify-self: end;
}

.role-config-section {
  background:
    linear-gradient(180deg, rgba(255, 190, 85, 0.065), rgba(12, 7, 4, 0.42)),
    rgba(14, 9, 7, 0.7);
  border: 1px solid rgba(255, 190, 85, 0.16);
  border-radius: 0.75rem;
  display: grid;
  gap: 0.65rem;
  padding: 0.75rem;
}

.role-config-section.invalid {
  border-color: rgba(248, 113, 113, 0.5);
  box-shadow: 0 0 18px rgba(248, 113, 113, 0.1);
}

.role-config-section.locked {
  background:
    linear-gradient(180deg, rgba(255, 190, 85, 0.045), rgba(12, 7, 4, 0.48)),
    rgba(14, 9, 7, 0.74);
}

.role-config-header {
  align-items: center;
  border-bottom: 1px solid rgba(255, 190, 85, 0.1);
  display: flex;
  gap: 0.75rem;
  justify-content: space-between;
  padding-bottom: 0.62rem;
}

.role-config-header h3 {
  color: var(--color-heading);
  font-size: 1rem;
  font-weight: 900;
  margin: 0.12rem 0 0;
}

.role-config-header > div:last-child {
  align-items: center;
  display: flex;
  flex-wrap: wrap;
  gap: 0.45rem;
  justify-content: flex-end;
}

.role-config-header strong {
  color: #ffd28a;
  font-size: 0.86rem;
}

.role-config-header strong.valid {
  color: #ffd28a;
  text-shadow: 0 0 10px rgba(255, 190, 85, 0.22);
}

.role-config-header strong.invalid {
  color: #fca5a5;
}

.role-lock-status {
  background: rgba(255, 190, 85, 0.1);
  border: 1px solid rgba(255, 190, 85, 0.22);
  border-radius: 999px;
  color: rgba(255, 245, 224, 0.76);
  font-size: 0.74rem;
  font-weight: 900;
  padding: 0.25rem 0.5rem;
}

.role-config-list {
  display: grid;
  gap: 0.45rem;
  grid-template-columns: repeat(2, minmax(0, 1fr));
}

.role-config-row {
  align-items: center;
  background: rgba(255, 255, 255, 0.045);
  border: 1px solid rgba(255, 190, 85, 0.1);
  border-radius: 0.6rem;
  display: flex;
  gap: 0.55rem;
  justify-content: space-between;
  min-width: 0;
  padding: 0.5rem 0.55rem;
}

.role-config-row > span {
  color: var(--color-heading);
  font-size: 0.9rem;
  font-weight: 900;
}

.role-stepper {
  align-items: center;
  display: grid;
  gap: 0.25rem;
  grid-template-columns: 1.8rem 1.85rem 1.8rem;
}

.role-stepper button {
  align-self: center;
  background: rgba(0, 0, 0, 0.34);
  border: 1px solid rgba(255, 190, 85, 0.2);
  border-radius: 0.45rem;
  color: #ffd28a;
  font-size: 1rem;
  min-height: 1.8rem;
  padding: 0;
}

.role-stepper button:disabled {
  cursor: not-allowed;
  opacity: 0.38;
}

.role-stepper strong {
  color: #fff1d6;
  text-align: center;
}

.role-config-intro {
  color: rgba(255, 224, 168, 0.72);
  font-size: 0.82rem;
  font-weight: 800;
  margin: 0;
}

.role-config-actions {
  display: flex;
  flex-wrap: wrap;
  gap: 0.5rem;
  justify-content: flex-end;
}

.role-config-actions button {
  align-self: center;
  background: rgba(0, 0, 0, 0.28);
  border: 1px solid rgba(255, 190, 85, 0.22);
  color: #ffd28a;
  font-size: 0.82rem;
  font-weight: 900;
  min-height: 2.25rem;
  padding: 0.52rem 0.75rem;
}

.role-config-actions button:hover {
  background: rgba(255, 138, 0, 0.11);
  border-color: rgba(255, 190, 85, 0.42);
}

.role-config-actions button.active {
  background: linear-gradient(
    180deg,
    rgba(255, 138, 0, 0.28),
    rgba(229, 46, 113, 0.16)
  );
  border-color: rgba(255, 190, 85, 0.66);
  box-shadow:
    0 0 16px rgba(255, 138, 0, 0.14),
    inset 0 0 12px rgba(255, 255, 255, 0.04);
  color: #ffdf9e;
}

.role-config-help,
.role-config-warning {
  font-size: 0.82rem;
  font-weight: 800;
  margin: 0;
  padding: 0 0.1rem;
}

.role-config-help {
  color: rgba(255, 245, 224, 0.6);
}

.role-config-warning {
  color: #fca5a5;
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

.chat-line.whisper {
  background:
    linear-gradient(180deg, rgba(46, 28, 62, 0.82), rgba(24, 17, 36, 0.9)),
    rgba(24, 17, 36, 0.92);
  border-color: rgba(167, 139, 250, 0.3);
  border-left: 4px solid rgba(196, 181, 253, 0.78);
  box-shadow:
    0 0 16px rgba(139, 92, 246, 0.12),
    inset 0 0 18px rgba(109, 40, 217, 0.1);
}

.chat-line.whisper strong {
  color: #ddd6fe;
}

.whisper-label {
  background: rgba(124, 58, 237, 0.22);
  border: 1px solid rgba(196, 181, 253, 0.34);
  border-radius: 0.42rem;
  color: #c4b5fd;
  display: inline-flex;
  font-size: 0.68rem;
  font-weight: 900;
  line-height: 1;
  margin-right: 0.45rem;
  padding: 0.18rem 0.34rem;
  vertical-align: middle;
}

.chat-line.whisper p {
  color: rgba(250, 245, 255, 0.9);
}

.chat-line.whisper time {
  color: rgba(196, 181, 253, 0.58);
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

.whisper-target {
  align-items: center;
  background:
    linear-gradient(180deg, rgba(46, 28, 62, 0.92), rgba(24, 17, 36, 0.94)),
    rgba(24, 17, 36, 0.94);
  border: 1px solid rgba(167, 139, 250, 0.34);
  border-radius: 0.7rem;
  box-shadow:
    0 0 14px rgba(139, 92, 246, 0.1),
    inset 4px 0 0 rgba(196, 181, 253, 0.64);
  color: #ddd6fe;
  display: flex;
  font-size: 0.82rem;
  font-weight: 900;
  gap: 0.65rem;
  grid-column: 1 / -1;
  justify-content: space-between;
  min-width: 0;
  padding: 0.45rem 0.55rem 0.45rem 0.75rem;
}

.whisper-target span {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.whisper-target button {
  background: rgba(38, 25, 55, 0.74);
  border-color: rgba(196, 181, 253, 0.32);
  color: #ede9fe;
  min-height: 0;
  padding: 0.35rem 0.55rem;
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
  flex-wrap: wrap;
  gap: 0.75rem;
  justify-content: space-between;
  min-width: 0;
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

.profile-main > div:last-child {
  min-width: 0;
}

.profile-main h2,
.profile-main p {
  overflow-wrap: anywhere;
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
  min-width: 0;
}

.profile-tags span {
  align-items: center;
  background: rgba(255, 190, 85, 0.1);
  border: 1px solid rgba(255, 190, 85, 0.24);
  border-radius: 0.9rem;
  color: #ffd28a;
  display: inline-flex;
  flex: 1 1 7.25rem;
  font-size: 0.78rem;
  font-weight: 900;
  justify-content: center;
  line-height: 1.25;
  max-width: 100%;
  min-width: 0;
  overflow-wrap: anywhere;
  padding: 0.42rem 0.6rem;
  text-align: center;
}

.profile-quote {
  border-left: 3px solid rgba(255, 190, 85, 0.48);
  color: rgba(255, 245, 224, 0.72);
  font-size: 0.86rem;
  line-height: 1.55;
  margin: 0;
  overflow-wrap: anywhere;
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
  align-items: stretch;
  background: rgba(255, 255, 255, 0.07);
  border: 1px solid var(--color-border);
  border-radius: 0.75rem;
  display: flex;
  flex-direction: column;
  gap: 0.75rem;
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

.visitor-card li.selected {
  background: rgba(255, 190, 85, 0.12);
  border-color: rgba(255, 190, 85, 0.34);
}

.visitor-card li:hover,
.visitor-card li:hover * {
  text-decoration: none;
}

.user-row-button {
  align-items: center;
  background: transparent;
  border: 0;
  color: inherit;
  cursor: pointer;
  display: flex;
  font: inherit;
  gap: 0.75rem;
  justify-content: space-between;
  min-width: 0;
  padding: 0;
  text-align: left;
  width: 100%;
}

.member-action-panel {
  display: grid;
  gap: 0.4rem;
  grid-template-columns: repeat(2, minmax(0, 1fr));
}

.member-action-panel button {
  background: linear-gradient(
    180deg,
    rgba(255, 190, 85, 0.14),
    rgba(80, 31, 21, 0.24)
  );
  border: 1px solid rgba(255, 190, 85, 0.24);
  border-radius: 0.55rem;
  color: var(--color-text);
  cursor: pointer;
  font: inherit;
  font-size: 0.78rem;
  font-weight: 900;
  min-width: 0;
  padding: 0.55rem 0.45rem;
}

.member-action-panel button:disabled {
  cursor: not-allowed;
  opacity: 0.5;
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
  background: linear-gradient(
    180deg,
    rgba(255, 190, 85, 0.14),
    rgba(80, 31, 21, 0.24)
  );
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

.friend-row.selected {
  background: rgba(255, 190, 85, 0.1);
  border-color: rgba(255, 190, 85, 0.28);
}

.friend-row-main {
  align-items: center;
  background: transparent !important;
  border: 0 !important;
  color: inherit;
  cursor: pointer;
  display: grid;
  gap: 0.45rem;
  grid-template-columns: minmax(0, 1fr) auto;
  min-width: 0;
  padding: 0 !important;
  text-align: left;
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
    grid-template-columns: repeat(auto-fit, minmax(min(100%, 20rem), 1fr));
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

  .role-config-list {
    grid-template-columns: 1fr;
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
    justify-self: end;
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

  .room-preview-header,
  .room-preview-actions {
    align-items: flex-start;
    flex-direction: column;
  }

  .room-preview-grid,
  .preview-role-list {
    grid-template-columns: 1fr;
  }

  .room-preview-actions > span,
  .room-preview-actions button {
    width: 100%;
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

  .advanced-settings-grid {
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

  .room-filter-summary {
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

.room-board-footer .room-actions {
  justify-content: flex-end;
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
  background: linear-gradient(
    180deg,
    rgba(255, 190, 85, 0.2),
    rgba(255, 132, 38, 0.2)
  ) !important;
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
