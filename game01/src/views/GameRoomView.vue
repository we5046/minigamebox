<script setup>
import {
  computed,
  onBeforeUnmount,
  onMounted,
  ref,
  nextTick,
  watch,
} from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { useAuthStore } from '@/stores/auth';
import { useRoomStore } from '@/stores/room';
import { useToastStore } from '@/stores/toast';
import {
  getRoom,
  heartbeatRoomPresence,
  joinRoom as joinRoomRequest,
  kickRoomPlayer,
  leaveRoom as leaveRoomRequest,
  DEFAULT_ROOM_DETAIL_SETTINGS,
  ROOM_PRESENCE_TIMEOUTS,
  setPlayerReady,
  startGame as startGameRequest,
  subscribeToRoom,
  updateRoom,
} from '@/api/roomApi';
import {
  subscribeToPublicChat,
  subscribeToRoomChat,
  sendRoomChatMessage,
  sendWhisperChatMessage,
  normalizeBroadcastMessage,
} from '@/api/chatApi';
import {
  setCurrentUserPresence,
  subscribeToPresenceUsers,
} from '@/api/presenceApi';
import { getFriendships } from '@/api/friendApi';
import { getRoomInvites, sendRoomInvite } from '@/api/roomInviteApi';
import {
  DEFAULT_LIAR_ROOM_SETTINGS,
  configureLiarRoom,
  getLiarCategories,
  getLiarRoomSettings,
  startLiarMatch,
} from '@/api/liarGameApi';

const props = defineProps({
  roomId: {
    type: String,
    required: true,
  },
});

const route = useRoute();
const router = useRouter();
const authStore = useAuthStore();
const roomStore = useRoomStore();
const toastStore = useToastStore();
const savedUser = computed(() => authStore.user);

const room = ref(null);
const isLoading = ref(false);
const isUpdating = ref(false);
const isEditingRoom = ref(false);
const hasLoadedRoomOnce = ref(false);
const editRoomTitle = ref('');
const editRoomDescription = ref('');
const editRoomMaxPlayers = ref(8);
const editRoomRoleConfig = ref(getDefaultRoleConfig(8));
const editNightTimeSeconds = ref(30);
const editVoteTimeSeconds = ref(15);
const editRoleRevealMode = ref('private');
const editEntryMode = ref('public');
const lastSyncedAt = ref(null);
const shouldSyncAfterUpdate = ref(false);
const friendships = ref([]);
const sentRoomInvites = ref([]);
const invitingUserIds = ref(new Set());
const isLoadingInviteFriends = ref(false);
const presenceUsers = ref([]);
const isInviteModalOpen = ref(false);
const inviteSearchQuery = ref('');
const isRoomBriefingOpen = ref(false);
const liarSettings = ref({ ...DEFAULT_LIAR_ROOM_SETTINGS });
const liarCategories = ref([]);
const editLiarCategoryId = ref(null);
const editLiarTargetScore = ref(DEFAULT_LIAR_ROOM_SETTINGS.targetScore);
const editLiarCitizenWinScore = ref(
  DEFAULT_LIAR_ROOM_SETTINGS.citizenWinScore,
);
const editLiarWinScore = ref(DEFAULT_LIAR_ROOM_SETTINGS.liarWinScore);

let unsubscribeRoom = null;
let roomChatSubscription = null;
let publicChatSubscription = null;
let syncTimer = null;
let roomHeartbeatTimer = null;
let roomHeartbeatPromise = null;
let roomHeartbeatFailureCount = 0;
let nextRoomHeartbeatAt = 0;
let roomTransitionPollTimer = null;
let roomSyncPromise = null;
let sentInviteRefreshTimer = null;
let inviteCountdownTimer = null;
let unsubscribePresenceUsers = null;
let isLeavingRoomExplicitly = false;
const chatChannel = ref(null);
const publicChatChannel = ref(null);
const hasAnnouncedEntry = ref(false);
const inviteCountdownTick = ref(Date.now());
const lastWhisperReplyTarget = ref(null);

const chatMessages = ref([
  {
    id: 'sys-welcome',
    nickname: 'System',
    content: '게임 방에 입장하셨습니다. 매너 채팅 부탁드립니다.',
    createdAt: new Date().toLocaleTimeString('ko-KR', {
      hour: '2-digit',
      minute: '2-digit',
    }),
    isSystem: true,
  },
]);
const chatDraft = ref('');
const chatLogRef = ref(null);

const players = computed(() => room.value?.players || []);
const currentPlayer = computed(() => {
  return players.value.find((player) => player.userId === savedUser.value?.id);
});
const isHost = computed(() => currentPlayer.value?.isHost === true);
const isLiarRoom = computed(() => room.value?.gameType === 'liar');
const isGameStarted = computed(
  () =>
    room.value?.status === 'playing' ||
    room.value?.status === 'finished' ||
    room.value?.status === 'game_over',
);
const canStartGame = computed(() => {
  if (!room.value || isGameStarted.value) {
    return false;
  }

  return (
    players.value.length >= Number(room.value.minStartPlayers || 0) &&
    players.value.length > 1 &&
    players.value.every((player) => player.isReady)
  );
});
const roomProgressText = computed(() => {
  if (isGameStarted.value) {
    return '게임 진행 중';
  }

  return canStartGame.value ? '시작 가능' : '대기 중';
});
const sentInviteMap = computed(() => {
  return new Map(
    sentRoomInvites.value.map((invite) => [invite.toUserId, invite]),
  );
});
const inviteFriends = computed(() => {
  const playerIds = new Set(players.value.map((player) => player.userId));
  const onlineUserIds = new Set(presenceUsers.value.map((user) => user.id));

  return friendships.value
    .filter((friendship) => friendship.status === 'accepted')
    .filter((friendship) => !playerIds.has(friendship.friend.id))
    .map((friendship) => ({
      ...friendship.friend,
      isOnline: onlineUserIds.has(friendship.friend.id),
      inviteRemainingSeconds: getInviteRemainingSeconds(
        sentInviteMap.value.get(friendship.friend.id),
      ),
      isInvited:
        getInviteRemainingSeconds(
          sentInviteMap.value.get(friendship.friend.id),
        ) > 0,
      isInviting: invitingUserIds.value.has(friendship.friend.id),
    }));
});

const filteredInviteFriends = computed(() => {
  const query = inviteSearchQuery.value.trim().toLowerCase();

  if (!query) {
    return inviteFriends.value;
  }

  return inviteFriends.value.filter((friend) => {
    return String(friend.nickname || '')
      .toLowerCase()
      .includes(query);
  });
});

const roleOptions = [
  { key: 'citizen', label: '시민', tone: 'citizen' },
  { key: 'mafia', label: '마피아', tone: 'mafia' },
  { key: 'police', label: '경찰', tone: 'police' },
  { key: 'doctor', label: '의사', tone: 'doctor' },
  { key: 'stalker', label: '스토커', tone: 'stalker' },
];
const fixedPlayerCounts = [4, 6, 8, 12];
const nightTimeOptions = [20, 30, 45, 60];
const discussionTimeOptions = [30, 45, 60, 90, 120];
const voteTimeOptions = [15, 30, 45, 60];
const tieVoteOptions = [
  { value: 'no_execution', label: '처형 없음' },
  { value: 'revote', label: '재투표' },
];
const liarPlayerCountOptions = [3, 4, 5, 6, 8, 10, 12];
const selectedLiarCategoryLabel = computed(() => {
  if (!liarSettings.value.categoryId) {
    return '랜덤';
  }

  return (
    liarCategories.value.find(
      (category) => category.id === liarSettings.value.categoryId,
    )?.label || '랜덤'
  );
});
const roomBriefing = computed(() => {
  if (!room.value) {
    return null;
  }

  if (isLiarRoom.value) {
    return {
      players: `${players.value.length} / ${room.value.maxPlayers}`,
      minStartPlayers: room.value.minStartPlayers,
      roleTotal: players.value.length,
      roles: [
        { key: 'liar', label: '라이어', tone: 'mafia', count: 1 },
        {
          key: 'citizen',
          label: '일반 유저',
          tone: 'citizen',
          count: Math.max(0, players.value.length - 1),
        },
      ],
      settings: [
        {
          label: '입장 방식',
          value: getEntryModeLabel(room.value.entryMode),
          tone: room.value.entryMode === 'private' ? 'private' : 'public',
        },
        {
          label: '테마',
          value: selectedLiarCategoryLabel.value,
          tone: 'public',
        },
        {
          label: '목표 점수',
          value: `${liarSettings.value.targetScore}점`,
          tone: 'allowed',
        },
        {
          label: '승리 점수',
          value: `일반 +${liarSettings.value.citizenWinScore} / 라이어 +${liarSettings.value.liarWinScore}`,
          tone: 'allowed',
        },
        {
          label: '동점 투표',
          value: '재투표',
          tone: 'allowed',
        },
        {
          label: '방 상태',
          value: room.value.status === 'waiting' ? '대기중' : '게임중',
          tone: room.value.status === 'waiting' ? 'public' : 'disabled',
        },
      ],
    };
  }

  return {
    players: `${players.value.length} / ${room.value.maxPlayers}`,
    minStartPlayers: room.value.minStartPlayers,
    roleTotal: getRoleConfigTotal(room.value.roleConfig, room.value.maxPlayers),
    roles: getRoleConfigItems(room.value.roleConfig, room.value.maxPlayers),
    settings: [
      {
        label: '입장 방식',
        value: getEntryModeLabel(room.value.entryMode),
        tone: room.value.entryMode === 'private' ? 'private' : 'public',
      },
      {
        label: '관전',
        value: getEnabledLabel(room.value.spectatorAllowed),
        tone: room.value.spectatorAllowed ? 'allowed' : 'disabled',
      },
      {
        label: '역할 공개',
        value: getRoleRevealLabel(room.value.roleRevealMode),
        tone: room.value.roleRevealMode === 'public' ? 'public' : 'private',
      },
      {
        label: '첫날 밤 능력',
        value: getEnabledLabel(room.value.firstNightAbilityAllowed),
        tone: room.value.firstNightAbilityAllowed ? 'allowed' : 'disabled',
      },
      {
        label: '최후의 변론',
        value: getEnabledLabel(room.value.finalDefenseEnabled),
        tone: room.value.finalDefenseEnabled ? 'allowed' : 'disabled',
      },
      {
        label: '동점 투표',
        value: getTieVoteRuleLabel(room.value.tieVoteRule),
        tone: room.value.tieVoteRule === 'revote' ? 'allowed' : 'disabled',
      },
      {
        label: '방 상태',
        value: room.value.status === 'waiting' ? '대기중' : '게임중',
        tone: room.value.status === 'waiting' ? 'public' : 'disabled',
      },
    ],
  };
});
const gameFlowTotalSeconds = computed(() => {
  if (!room.value) {
    return 0;
  }

  if (isLiarRoom.value) {
    return (
      Number(room.value.discussionTimeSeconds || 0) +
      Number(room.value.voteTimeSeconds || 0)
    );
  }

  return (
    Number(room.value.nightTimeSeconds || 0) +
    Number(room.value.discussionTimeSeconds || 0) +
    Number(room.value.voteTimeSeconds || 0) +
    (room.value.finalDefenseEnabled ? 30 : 0)
  );
});
const gameFlowItems = computed(() => {
  if (!room.value) {
    return [];
  }

  if (isLiarRoom.value) {
    return [
      {
        icon: '🔎',
        label: '제시어 확인',
        description: '역할과 제시어 확인',
        duration: '수동',
      },
      {
        icon: '💬',
        label: '토론',
        description: '설명과 추리',
        duration: `${room.value.discussionTimeSeconds}s`,
      },
      {
        icon: '🗳️',
        label: '투표',
        description: '라이어 지목',
        duration: `${room.value.voteTimeSeconds}s`,
      },
      {
        icon: '🎯',
        label: '최종 추측',
        description: '지목된 라이어만 진행',
        duration: '1회',
      },
    ];
  }

  const items = [
    {
      icon: '🌙',
      label: '밤',
      description: '능력 사용',
      duration: `${room.value.nightTimeSeconds}s`,
    },
    {
      icon: '☀️',
      label: '낮 토론',
      description: '토론',
      duration: `${room.value.discussionTimeSeconds}s`,
    },
    {
      icon: '🗳️',
      label: '투표',
      description: '처형 투표',
      duration: `${room.value.voteTimeSeconds}s`,
    },
  ];

  if (room.value.finalDefenseEnabled) {
    items.push({
      icon: '⚖️',
      label: '최후의 변론',
      description: '처형 여부 결정',
      duration: '30s',
    });
  }

  return items;
});
const isFriendlyEditMode = computed(
  () => editRoomDescription.value === '친선전',
);
const minEditableMaxPlayers = computed(() =>
  Math.max(isLiarRoom.value ? 3 : 4, players.value.length),
);
const editMinStartPlayerOptions = computed(() =>
  Array.from(
    { length: Math.max(1, Number(editRoomMaxPlayers.value) - 1) },
    (_, index) => index + 2,
  ),
);
const isRecommendedEditRolesEnabled = ref(false);
const isEditAdvancedOpen = ref(true);
const editRoomDiscussionTimeSeconds = ref(60);
const editRoomMinStartPlayers = ref(4);
const editRoomTieVoteRule = ref('no_execution');
const editSpectatorAllowed = ref(false);
const editFirstNightAbilityAllowed = ref(true);
const editFinalDefenseEnabled = ref(false);
const editEntryPassword = ref('');
const isEditEntryPasswordVisible = ref(false);
const editRoleConfigTotal = computed(() => {
  return Object.values(editRoomRoleConfig.value).reduce(
    (total, count) => total + Number(count || 0),
    0,
  );
});
const isEditRoleConfigValid = computed(
  () => editRoleConfigTotal.value === Number(editRoomMaxPlayers.value),
);
const editRoleConfigStatusText = computed(() => {
  if (editRoomDescription.value === '클래식') {
    return '기본 밸런스 고정';
  }

  return '커스텀 사용자 설정';
});

function getDefaultRoleConfig(maxPlayers) {
  const defaults = {
    4: { citizen: 2, mafia: 1, police: 1, doctor: 0, stalker: 0 },
    6: { citizen: 2, mafia: 1, police: 1, doctor: 1, stalker: 1 },
    8: { citizen: 3, mafia: 2, police: 1, doctor: 1, stalker: 1 },
    12: { citizen: 6, mafia: 3, police: 1, doctor: 1, stalker: 1 },
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
  const stalker = playerCount >= 8 ? 1 : 0;
  const citizen = Math.max(0, playerCount - mafia - police - doctor - stalker);

  return { citizen, mafia, police, doctor, stalker };
}

function applyClassicEditRoomSettings() {
  editRoomRoleConfig.value = getDefaultRoleConfig(editRoomMaxPlayers.value);
  editNightTimeSeconds.value = DEFAULT_ROOM_DETAIL_SETTINGS.nightTimeSeconds;
  editVoteTimeSeconds.value = DEFAULT_ROOM_DETAIL_SETTINGS.voteTimeSeconds;
  editRoomDiscussionTimeSeconds.value =
    DEFAULT_ROOM_DETAIL_SETTINGS.discussionTimeSeconds;
  editRoomMinStartPlayers.value =
    DEFAULT_ROOM_DETAIL_SETTINGS.minStartPlayers;
  editRoomTieVoteRule.value = DEFAULT_ROOM_DETAIL_SETTINGS.tieVoteRule;
  editSpectatorAllowed.value = DEFAULT_ROOM_DETAIL_SETTINGS.spectatorAllowed;
  editFirstNightAbilityAllowed.value =
    DEFAULT_ROOM_DETAIL_SETTINGS.firstNightAbilityAllowed;
  editFinalDefenseEnabled.value =
    DEFAULT_ROOM_DETAIL_SETTINGS.finalDefenseEnabled;
  editRoleRevealMode.value = 'private';
}

function applyClassicEditLiarSettings() {
  editLiarTargetScore.value = DEFAULT_LIAR_ROOM_SETTINGS.targetScore;
  editLiarCitizenWinScore.value =
    DEFAULT_LIAR_ROOM_SETTINGS.citizenWinScore;
  editLiarWinScore.value = DEFAULT_LIAR_ROOM_SETTINGS.liarWinScore;
  editRoomDiscussionTimeSeconds.value =
    DEFAULT_ROOM_DETAIL_SETTINGS.discussionTimeSeconds;
  editVoteTimeSeconds.value = DEFAULT_ROOM_DETAIL_SETTINGS.voteTimeSeconds;
  editRoomMinStartPlayers.value = 3;
  editRoomTieVoteRule.value = 'revote';
  editSpectatorAllowed.value = false;
  editFirstNightAbilityAllowed.value = false;
  editFinalDefenseEnabled.value = false;
  editRoleRevealMode.value = 'private';
}

function copyLiarSettingsToEdit(nextSettings = liarSettings.value) {
  editLiarCategoryId.value = nextSettings.categoryId || null;
  editLiarTargetScore.value = Number(nextSettings.targetScore);
  editLiarCitizenWinScore.value = Number(nextSettings.citizenWinScore);
  editLiarWinScore.value = Number(nextSettings.liarWinScore);
}

async function syncLiarRoomSettings() {
  if (!isLiarRoom.value) {
    liarSettings.value = { ...DEFAULT_LIAR_ROOM_SETTINGS };
    liarCategories.value = [];
    return;
  }

  const [nextSettings, nextCategories] = await Promise.all([
    getLiarRoomSettings(props.roomId),
    liarCategories.value.length > 0
      ? Promise.resolve(liarCategories.value)
      : getLiarCategories(),
  ]);

  liarSettings.value = nextSettings;
  liarCategories.value = nextCategories;
}

function getEffectiveRoleConfig(roleConfig, maxPlayers) {
  return roleConfig || getDefaultRoleConfig(maxPlayers);
}

function getRoleConfigTotal(roleConfig, maxPlayers) {
  return Object.values(getEffectiveRoleConfig(roleConfig, maxPlayers)).reduce(
    (total, count) => total + Number(count || 0),
    0,
  );
}

function getRoleConfigItems(roleConfig, maxPlayers) {
  const effectiveRoleConfig = getEffectiveRoleConfig(roleConfig, maxPlayers);

  return roleOptions.map((role) => ({
    ...role,
    count: Number(effectiveRoleConfig[role.key] || 0),
  }));
}

function isSameRoleConfig(a, b) {
  return ['citizen', 'mafia', 'police', 'doctor', 'stalker'].every(
    (key) => Number(a?.[key] || 0) === Number(b?.[key] || 0),
  );
}

function selectEditRoomEntryMode(mode) {
  editEntryMode.value = mode;
}

function toggleEditEntryPasswordVisibility() {
  isEditEntryPasswordVisible.value = !isEditEntryPasswordVisible.value;
}

function getInviteRemainingSeconds(invite) {
  if (!invite?.expiresAt) {
    return 0;
  }

  return Math.max(
    0,
    Math.ceil(
      (new Date(invite.expiresAt).getTime() - inviteCountdownTick.value) / 1000,
    ),
  );
}

async function syncRoomPresence() {
  if (!savedUser.value || !room.value) {
    return;
  }

  await setCurrentUserPresence({
    userId: savedUser.value.id,
    nickname: savedUser.value.nickname,
    status: room.value.status === 'playing' ? 'playing' : 'room',
    roomId: props.roomId,
    canReceiveWhisper: room.value.status !== 'playing',
  });
}

function getRoomHeartbeatBackoffMs() {
  return Math.min(
    60_000,
    ROOM_PRESENCE_TIMEOUTS.heartbeatIntervalMs *
      2 ** Math.min(roomHeartbeatFailureCount, 3),
  );
}

async function sendRoomHeartbeat({ force = false, resync = false } = {}) {
  if (!savedUser.value || !room.value?.id) {
    return;
  }

  if (!force && Date.now() < nextRoomHeartbeatAt) {
    return;
  }

  if (!roomHeartbeatPromise) {
    roomHeartbeatPromise = (async () => {
      try {
        await heartbeatRoomPresence(props.roomId);
        roomHeartbeatFailureCount = 0;
        nextRoomHeartbeatAt = 0;
        return true;
      } catch (error) {
        const rawMessage =
          error.cause?.message || error.supabaseError?.message || '';

        if (
          rawMessage.includes('Room participant required') ||
          error.message?.includes('Room participant required') ||
          error.message?.includes('방 참가자')
        ) {
          stopRoomHeartbeat();
          toastStore.error('방에서 강퇴되었습니다.');
          router.push('/home');
          return false;
        }

        roomHeartbeatFailureCount += 1;
        nextRoomHeartbeatAt = Date.now() + getRoomHeartbeatBackoffMs();
        console.warn('[Room] Heartbeat failed.', error);
        return false;
      } finally {
        roomHeartbeatPromise = null;
      }
    })();
  }

  const heartbeatOk = await roomHeartbeatPromise;

  if (heartbeatOk && resync) {
    await syncRoom();
  }
}

function startRoomHeartbeat() {
  if (roomHeartbeatTimer) {
    return;
  }

  roomHeartbeatTimer = setInterval(() => {
    sendRoomHeartbeat();
  }, ROOM_PRESENCE_TIMEOUTS.heartbeatIntervalMs);
}

function stopRoomHeartbeat() {
  if (!roomHeartbeatTimer) {
    return;
  }

  clearInterval(roomHeartbeatTimer);
  roomHeartbeatTimer = null;
}

function handleVisibilityChange() {
  if (document.visibilityState === 'visible') {
    sendRoomHeartbeat({ force: true, resync: true });
  }
}

function startRoomTransitionPolling() {
  if (roomTransitionPollTimer) {
    return;
  }

  roomTransitionPollTimer = setInterval(() => {
    if (
      route.name === 'game-room' &&
      room.value?.status === 'waiting' &&
      !isUpdating.value
    ) {
      syncRoom();
    }
  }, 3_000);
}

function stopRoomTransitionPolling() {
  if (!roomTransitionPollTimer) {
    return;
  }

  clearInterval(roomTransitionPollTimer);
  roomTransitionPollTimer = null;
}

onMounted(() => {
  unsubscribePresenceUsers = subscribeToPresenceUsers((users) => {
    presenceUsers.value = users;
  });

  const sub = subscribeToRoomChat(props.roomId, handleChatEvent);
  roomChatSubscription = sub.unsubscribe;
  chatChannel.value = sub.channel;
  const publicSub = subscribeToPublicChat(handlePublicChatEvent);
  publicChatSubscription = publicSub.unsubscribe;
  publicChatChannel.value = publicSub.channel;

  fetchRoom();
  loadInviteFriends();
  loadSentRoomInvites();
  sentInviteRefreshTimer = setInterval(loadSentRoomInvites, 10000);
  inviteCountdownTimer = setInterval(() => {
    inviteCountdownTick.value = Date.now();
  }, 1000);
  unsubscribeRoom = subscribeToRoom(props.roomId, handleRoomRealtimeEvent);
  startRoomTransitionPolling();
  document.addEventListener('visibilitychange', handleVisibilityChange);
});

onBeforeUnmount(() => {
  unsubscribeRoom?.();
  roomChatSubscription?.();
  publicChatSubscription?.();
  publicChatChannel.value = null;
  unsubscribePresenceUsers?.();
  stopRoomHeartbeat();
  stopRoomTransitionPolling();
  document.removeEventListener('visibilitychange', handleVisibilityChange);
  if (syncTimer) {
    clearTimeout(syncTimer);
  }
  if (sentInviteRefreshTimer) {
    clearInterval(sentInviteRefreshTimer);
  }
  if (inviteCountdownTimer) {
    clearInterval(inviteCountdownTimer);
  }
});

watch([editRoomMaxPlayers, editRoomDescription], () => {
  if (!isEditingRoom.value) {
    return;
  }

  if (isLiarRoom.value) {
    editRoomMinStartPlayers.value = 3;
    editRoomTieVoteRule.value = 'revote';
    editSpectatorAllowed.value = false;
    editFirstNightAbilityAllowed.value = false;
    editFinalDefenseEnabled.value = false;
    editRoleRevealMode.value = 'private';

    if (!isFriendlyEditMode.value) {
      applyClassicEditLiarSettings();
    }

    return;
  }

  if (isFriendlyEditMode.value) {
    if (isRecommendedEditRolesEnabled.value) {
      editRoomRoleConfig.value = getRecommendedRoleConfig(
        editRoomMaxPlayers.value,
      );
    }

    return;
  }

  applyClassicEditRoomSettings();
});

function handleChatEvent(payload) {
  if (payload?.type === 'subscription-status') return;
  if (!payload?.payload) return;

  chatMessages.value.push(normalizeBroadcastMessage(payload.payload));
  scrollToBottom();
}

function handlePublicChatEvent(payload) {
  if (payload?.type === 'subscription-status') return;
  if (!payload?.payload) return;

  const message = normalizeBroadcastMessage(payload.payload);

  if (!message.isWhisper) {
    return;
  }

  if (
    message.userId !== savedUser.value?.id &&
    message.targetUserId !== savedUser.value?.id
  ) {
    return;
  }

  if (
    message.targetUserId === savedUser.value?.id &&
    message.userId !== savedUser.value?.id
  ) {
    lastWhisperReplyTarget.value = {
      id: message.userId,
      nickname: message.nickname,
    };
  }

  chatMessages.value.push(message);
  scrollToBottom();
}

function normalizeMemberNickname(nickname) {
  return String(nickname || '')
    .trim()
    .toLowerCase();
}

function getWhisperMembers() {
  const members = new Map();

  presenceUsers.value.forEach((user) => {
    if (user?.id && user?.nickname) {
      members.set(user.id, user);
    }
  });

  friendships.value
    .filter((friendship) => friendship.status === 'accepted')
    .forEach((friendship) => {
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

function findRoomPlayerByNickname(nickname) {
  const normalizedNickname = normalizeMemberNickname(nickname);

  if (!normalizedNickname) {
    return null;
  }

  return (
    players.value.find(
      (player) =>
        normalizeMemberNickname(player.nickname) === normalizedNickname,
    ) || null
  );
}

function parseChatCommand(content) {
  const kickMatch = content.match(/^\/(?:kick|강퇴)\s+(\S+)$/);

  if (kickMatch) {
    return {
      type: 'kick',
      nickname: kickMatch[1],
    };
  }

  if (content === '/kick' || content.startsWith('/kick ') || content === '/강퇴' || content.startsWith('/강퇴 ')) {
    return {
      type: 'error',
      message: '사용법: /kick 대상닉네임 또는 /강퇴 대상닉네임',
    };
  }

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
  if (room.value?.status === 'playing') {
    throw new Error('게임 진행 중인 방에서는 귓속말을 보낼 수 없습니다.');
  }

  if (!target?.id || target.id === savedUser.value?.id) {
    throw new Error('귓속말 대상을 선택할 수 없습니다.');
  }

  const targetPresence = presenceUsers.value.find((user) => user.id === target.id);
  if (!targetPresence?.canReceiveWhisper) {
    throw new Error('[상대방이 채팅을 볼 수 없는 상태입니다.]');
  }

  await sendWhisperChatMessage(publicChatChannel.value, {
    userId: savedUser.value.id,
    nickname: currentPlayer.value?.nickname || savedUser.value.nickname,
    targetUserId: target.id,
    targetNickname: target.nickname,
    content,
  });
}

async function kickPlayerByNickname(nickname) {
  if (!isHost.value) {
    throw new Error('방장만 강퇴할 수 있습니다.');
  }

  if (room.value?.status !== 'waiting') {
    throw new Error('대기 중인 방에서만 강퇴할 수 있습니다.');
  }

  const target = findRoomPlayerByNickname(nickname);

  if (!target) {
    throw new Error(`${nickname}을(를) 현재 방 참가자 목록에서 찾을 수 없습니다.`);
  }

  if (target.userId === savedUser.value?.id) {
    throw new Error('자기 자신은 강퇴할 수 없습니다.');
  }

  await kickRoomPlayer(props.roomId, target.userId);

  if (chatChannel.value) {
    await sendRoomChatMessage(chatChannel.value, {
      userId: 'system',
      nickname: 'System',
      content: `${target.nickname}님이 방장에 의해 강퇴되었습니다.`,
      isSystem: true,
    }).catch(() => {});
  }

  await syncRoom();
}

async function submitChat() {
  const content = chatDraft.value.trim();
  if (!content || !savedUser.value || !chatChannel.value) return;

  try {
    const command = parseChatCommand(content);

    if (command?.type === 'error') {
      toastStore.error(command.message);
      return;
    }

    if (command?.type === 'kick') {
      await kickPlayerByNickname(command.nickname);
      chatDraft.value = '';
      return;
    }

    if (command?.type === 'whisper') {
      const target = findWhisperMemberByNickname(command.nickname);

      if (!target) {
        toastStore.error(`${command.nickname}을(를) 로비 유저 또는 친구 목록에서 찾을 수 없습니다.`);
        return;
      }

      await sendWhisperToTarget(target, command.content);
      chatDraft.value = '';
      return;
    }

    if (command?.type === 'reply') {
      if (!lastWhisperReplyTarget.value) {
        toastStore.error('답장할 귓속말 대상이 없습니다.');
        return;
      }

      await sendWhisperToTarget(lastWhisperReplyTarget.value, command.content);
      chatDraft.value = '';
      return;
    }

    await sendRoomChatMessage(chatChannel.value, {
      userId: savedUser.value.id,
      nickname: currentPlayer.value?.nickname || savedUser.value.nickname,
      content,
      isSystem: false,
    });
    chatDraft.value = '';
  } catch (error) {
    toastStore.error(error.message);
  }
}

function scrollToBottom() {
  nextTick(() => {
    if (chatLogRef.value) {
      chatLogRef.value.scrollTop = chatLogRef.value.scrollHeight;
    }
  });
}

function isRoomLoadError(error) {
  const raw = error.cause || error.supabaseError || {};
  const message = error.message || '';

  return (
    raw.code === 'PGRST116' ||
    raw.details?.includes('0 rows') ||
    message.includes('Not Found') ||
    message.includes('Failed to load room') ||
    message.includes('방 정보를 불러오지 못했습니다')
  );
}

async function redirectToMainLobby() {
  stopRoomHeartbeat();
  await router.replace({ name: 'home' });
}

async function fetchRoom() {
  isLoading.value = true;

  try {
    const hadLoadedRoom = hasLoadedRoomOnce.value;
    room.value = await getRoom(props.roomId);
    lastSyncedAt.value = new Date();

    if (savedUser.value && !currentPlayer.value) {
      if (hadLoadedRoom) {
        stopRoomHeartbeat();
        router.push('/home');
        return;
      }

      await joinRoom();
    } else if (savedUser.value && route.query.invited === '1') {
      announceRoomEntry();
      clearInviteEntryQuery();
    }

    hasLoadedRoomOnce.value = true;
    await syncLiarRoomSettings();
    await syncRoomPresence();
    await sendRoomHeartbeat({ force: true });
    startRoomHeartbeat();
    redirectToGameIfStarted();
  } catch (error) {
    if (isRoomLoadError(error)) {
      toastStore.error('방 정보를 불러오지 못했습니다. 메인 로비로 이동합니다.');
      await redirectToMainLobby();
      return;
    }

    toastStore.error(error.message);
  } finally {
    isLoading.value = false;
  }
}

async function loadInviteFriends() {
  if (!savedUser.value) {
    friendships.value = [];
    return;
  }

  isLoadingInviteFriends.value = true;

  try {
    friendships.value = await getFriendships(savedUser.value.id);
  } catch (error) {
    toastStore.error(error.message);
  } finally {
    isLoadingInviteFriends.value = false;
  }
}

async function loadSentRoomInvites() {
  if (!savedUser.value) {
    sentRoomInvites.value = [];
    return;
  }

  try {
    sentRoomInvites.value = await getRoomInvites(
      props.roomId,
      savedUser.value.id,
    );
  } catch (error) {
    toastStore.error(error.message);
  }
}

async function inviteFriendToRoom(friend) {
  if (!room.value || room.value.status !== 'waiting') {
    toastStore.error('대기중인 방에서만 초대할 수 있습니다.');
    return;
  }

  if (friend.isOnline === false) {
    toastStore.error('오프라인 유저는 초대할 수 없습니다.');
    return;
  }

  if (players.value.some((player) => player.userId === friend.id)) {
    toastStore.error('이미 방에 있는 유저는 초대할 수 없습니다.');
    return;
  }

  if (friend.isInvited) {
    toastStore.error('초대 쿨타임이 아직 남아 있습니다.');
    return;
  }

  if (invitingUserIds.value.has(friend.id)) {
    return;
  }

  invitingUserIds.value = new Set([...invitingUserIds.value, friend.id]);

  try {
    await sendRoomInvite(props.roomId, friend.id);
    await loadSentRoomInvites();
    toastStore.success(`${friend.nickname}님에게 방 초대를 보냈습니다.`);
  } catch (error) {
    toastStore.error(error.message);
  } finally {
    const nextInvitingIds = new Set(invitingUserIds.value);
    nextInvitingIds.delete(friend.id);
    invitingUserIds.value = nextInvitingIds;
  }
}

function openInviteModal() {
  if (!room.value || room.value.status !== 'waiting') {
    toastStore.error('초대는 대기중인 방에서만 사용할 수 있습니다.');
    return;
  }

  isInviteModalOpen.value = true;
  inviteSearchQuery.value = '';
}

function closeInviteModal() {
  isInviteModalOpen.value = false;
  inviteSearchQuery.value = '';
}

async function inviteByNickname() {
  const query = inviteSearchQuery.value.trim();

  if (!query) {
    return;
  }

  const exactMatch = filteredInviteFriends.value.find(
    (friend) =>
      String(friend.nickname || '')
        .trim()
        .toLowerCase() === query.toLowerCase(),
  );

  if (exactMatch) {
    await inviteFriendToRoom(exactMatch);
    return;
  }

  if (filteredInviteFriends.value.length === 1) {
    await inviteFriendToRoom(filteredInviteFriends.value[0]);
    return;
  }

  if (filteredInviteFriends.value.length === 0) {
    toastStore.error('초대할 수 있는 친구를 찾지 못했습니다.');
    return;
  }

  toastStore.error('검색 결과가 여러 명입니다. 목록에서 대상을 선택하세요.');
}

async function syncRoom() {
  if (isUpdating.value) {
    shouldSyncAfterUpdate.value = true;
    return;
  }

  if (!roomSyncPromise) {
    roomSyncPromise = (async () => {
      try {
        room.value = await getRoom(props.roomId);
        lastSyncedAt.value = new Date();
        await syncLiarRoomSettings();
        await syncRoomPresence();
        redirectToGameIfStarted();
      } catch (error) {
        if (isRoomLoadError(error)) {
          await redirectToMainLobby();
          return;
        }
        toastStore.error(error.message);
      } finally {
        roomSyncPromise = null;
      }
    })();
  }

  await roomSyncPromise;
}

async function joinRoom() {
  if (!room.value || !savedUser.value) {
    router.push('/login');
    return;
  }

  room.value = await joinRoomRequest(props.roomId);
  lastSyncedAt.value = new Date();
  announceRoomEntry();
  await syncRoomPresence();
  await sendRoomHeartbeat({ force: true });
  startRoomHeartbeat();
  return;

  // Send enter message
  if (chatChannel.value) {
    sendRoomChatMessage(chatChannel.value, {
      userId: 'system',
      nickname: 'System',
      content: `${savedUser.value.nickname}님이 입장했습니다.`,
      isSystem: true,
    }).catch(() => {});
  }
}

function announceRoomEntry() {
  if (!savedUser.value || hasAnnouncedEntry.value) {
    return;
  }

  if (chatChannel.value) {
    hasAnnouncedEntry.value = true;
    sendRoomChatMessage(chatChannel.value, {
      userId: 'system',
      nickname: 'System',
      content: `${savedUser.value.nickname}\uB2D8\uC774 \uC785\uC7A5\uD588\uC2B5\uB2C8\uB2E4.`,
      isSystem: true,
    }).catch(() => {});
  }
}

function clearInviteEntryQuery() {
  const nextQuery = { ...route.query };
  delete nextQuery.invited;
  router.replace({ path: route.path, query: nextQuery });
}

function getRoleRevealLabel(mode) {
  return mode === 'public' ? '공개' : '비공개';
}

function getEntryModeLabel(mode) {
  return mode === 'private' ? '비공개방' : '공개방';
}

function redirectToGameIfStarted() {
  if (
    room.value?.status === 'playing' &&
    route.name !== 'game-play'
  ) {
    stopRoomTransitionPolling();
    router.push(`/rooms/${props.roomId}/game`);
  }
}

function getTieVoteRuleLabel(rule) {
  return (
    tieVoteOptions.find((option) => option.value === rule)?.label ||
    '처형 없음'
  );
}

function getEnabledLabel(isEnabled) {
  return isEnabled ? '허용' : '비허용';
}

async function toggleReady() {
  if (!currentPlayer.value || isUpdating.value) {
    return;
  }

  isUpdating.value = true;

  try {
    room.value = await setPlayerReady(
      props.roomId,
      savedUser.value.id,
      !currentPlayer.value.isReady,
    );
    lastSyncedAt.value = new Date();
    await syncRoomPresence();
  } catch (error) {
    toastStore.error(error.message);
  } finally {
    isUpdating.value = false;
    if (shouldSyncAfterUpdate.value) {
      shouldSyncAfterUpdate.value = false;
      syncRoom();
    }
  }
}

function scheduleSyncRoom() {
  if (syncTimer) {
    clearTimeout(syncTimer);
  }

  syncTimer = setTimeout(() => {
    syncTimer = null;
    syncRoom();
  }, 120);
}

function isHeartbeatOnlyRoomPlayerUpdate(payload) {
  if (payload?.table !== 'room_players' || payload?.eventType !== 'UPDATE') {
    return false;
  }

  const previous = payload.old || {};
  const next = payload.new || {};
  const visibleFields = [
    'user_id',
    'is_host',
    'is_ready',
    'role',
    'is_alive',
    'connection_status',
    'disconnected_at',
    'joined_at',
  ];

  return visibleFields.every((field) => previous[field] === next[field]);
}

function toRealtimePlayer(row, existingPlayer = null) {
  return {
    ...(existingPlayer || {}),
    userId: row.user_id,
    nickname: existingPlayer?.nickname || '알 수 없음',
    avatar: existingPlayer?.avatar || 'default-mafia',
    level: existingPlayer?.level || 1,
    title: existingPlayer?.title || 'Rookie Mafia',
    isHost: row.is_host,
    isReady: row.is_ready,
    isAlive: row.is_alive !== false,
    connectionStatus: row.connection_status || existingPlayer?.connectionStatus || 'active',
    isConnected: (row.connection_status || existingPlayer?.connectionStatus || 'active') === 'active',
    lastSeenAt: row.last_seen_at || existingPlayer?.lastSeenAt || row.joined_at,
    disconnectedAt: row.disconnected_at || null,
    joinedAt: row.joined_at || existingPlayer?.joinedAt,
  };
}

function mergeRoomPayload(nextRoom) {
  if (!nextRoom?.id || !room.value) {
    return;
  }

  room.value = {
    ...room.value,
    id: nextRoom.id,
    title: nextRoom.title ?? room.value.title,
    description: nextRoom.description ?? room.value.description,
    code: nextRoom.code ?? room.value.code,
    hostUserId: nextRoom.host_user_id ?? room.value.hostUserId,
    status: nextRoom.status ?? room.value.status,
    maxPlayers: nextRoom.max_players ?? room.value.maxPlayers,
    phase: nextRoom.phase ?? room.value.phase,
    nightTimeSeconds: nextRoom.night_time_seconds ?? room.value.nightTimeSeconds,
    voteTimeSeconds: nextRoom.vote_time_seconds ?? room.value.voteTimeSeconds,
    discussionTimeSeconds: nextRoom.discussion_time_seconds ?? room.value.discussionTimeSeconds,
    minStartPlayers: nextRoom.min_start_players ?? room.value.minStartPlayers,
    tieVoteRule: nextRoom.tie_vote_rule ?? room.value.tieVoteRule,
    spectatorAllowed: nextRoom.spectator_allowed ?? room.value.spectatorAllowed,
    firstNightAbilityAllowed: nextRoom.first_night_ability_allowed ?? room.value.firstNightAbilityAllowed,
    finalDefenseEnabled: nextRoom.final_defense_enabled ?? room.value.finalDefenseEnabled,
    roleRevealMode: nextRoom.role_reveal_mode ?? room.value.roleRevealMode,
    entryMode: nextRoom.entry_mode ?? room.value.entryMode,
    roleConfig: nextRoom.role_config ?? room.value.roleConfig,
    updatedAt: nextRoom.updated_at ?? room.value.updatedAt,
  };
}

function mergeRoomPlayerPayload(payload) {
  if (!room.value || payload?.table !== 'room_players') {
    return false;
  }

  const userId = payload.new?.user_id || payload.old?.user_id;
  if (!userId) {
    return false;
  }

  const currentPlayers = room.value.players || [];

  if (payload.eventType === 'DELETE') {
    room.value = {
      ...room.value,
      players: currentPlayers.filter((player) => player.userId !== userId),
    };
    return true;
  }

  if (!payload.new) {
    return false;
  }

  const existingPlayer = currentPlayers.find((player) => player.userId === userId);
  const nextPlayer = toRealtimePlayer(payload.new, existingPlayer);
  const nextPlayers = existingPlayer
    ? currentPlayers.map((player) => (player.userId === userId ? nextPlayer : player))
    : [...currentPlayers, nextPlayer];

  nextPlayers.sort((a, b) => new Date(a.joinedAt || 0) - new Date(b.joinedAt || 0));

  room.value = {
    ...room.value,
    players: nextPlayers,
    currentPlayers: nextPlayers.length,
  };

  return true;
}

function handleRoomRealtimeEvent(payload) {
  if (payload?.type === 'subscription-status') {
    return;
  }

  if (
    payload?.table === 'room_players' &&
    payload?.eventType === 'DELETE' &&
    payload.old?.user_id === savedUser.value?.id
  ) {
    if (isLeavingRoomExplicitly) {
      return;
    }

    stopRoomHeartbeat();
    toastStore.error('방에서 강퇴되었습니다.');
    router.push('/home');
    return;
  }

  if (isHeartbeatOnlyRoomPlayerUpdate(payload)) {
    return;
  }

  if (payload?.table === 'room_players') {
    const merged = mergeRoomPlayerPayload(payload);

    if (merged && ['INSERT', 'UPDATE', 'DELETE'].includes(payload.eventType)) {
      scheduleSyncRoom();
    }

    return;
  }

  if (payload?.table === 'rooms' && payload.new) {
    mergeRoomPayload(payload.new);
  }

  if (payload?.new?.status === 'playing') {
    room.value = {
      ...(room.value || {}),
      status: payload.new.status,
      phase: payload.new.phase,
    };
    redirectToGameIfStarted();
    return;
  }

  scheduleSyncRoom();
}

function openEditRoomForm() {
  editRoomTitle.value = room.value?.title || '';
  editRoomDescription.value = room.value?.description || '';
  editRoomMaxPlayers.value = room.value?.maxPlayers || 8;
  editRoomRoleConfig.value = room.value?.roleConfig
    ? {
        ...getDefaultRoleConfig(room.value?.maxPlayers || 8),
        stalker: 0,
        ...room.value.roleConfig,
      }
    : getDefaultRoleConfig(room.value?.maxPlayers || 8);
  editRoomDiscussionTimeSeconds.value = room.value?.discussionTimeSeconds || 60;
  editRoomMinStartPlayers.value = room.value?.minStartPlayers || 4;
  isRecommendedEditRolesEnabled.value =
    editRoomDescription.value === '친선전' &&
    isSameRoleConfig(
      editRoomRoleConfig.value,
      getRecommendedRoleConfig(editRoomMaxPlayers.value),
    );
  editNightTimeSeconds.value = room.value?.nightTimeSeconds || 30;
  editVoteTimeSeconds.value = room.value?.voteTimeSeconds || 15;
  editRoomTieVoteRule.value = room.value?.tieVoteRule || 'no_execution';
  editSpectatorAllowed.value = room.value?.spectatorAllowed ?? false;
  editFirstNightAbilityAllowed.value =
    room.value?.firstNightAbilityAllowed ?? true;
  editFinalDefenseEnabled.value = room.value?.finalDefenseEnabled ?? false;
  editRoleRevealMode.value = room.value?.roleRevealMode || 'private';
  editEntryMode.value = room.value?.entryMode || 'public';
  editEntryPassword.value = '';
  isEditEntryPasswordVisible.value = false;
  isEditAdvancedOpen.value = true;
  isEditingRoom.value = true;

  if (isLiarRoom.value) {
    copyLiarSettingsToEdit();
    editRoomMinStartPlayers.value = 3;
    editRoomTieVoteRule.value = 'revote';
    editSpectatorAllowed.value = false;
    editFirstNightAbilityAllowed.value = false;
    editFinalDefenseEnabled.value = false;
    editRoleRevealMode.value = 'private';

    if (!isFriendlyEditMode.value) {
      applyClassicEditLiarSettings();
    }

    return;
  }

  if (!isFriendlyEditMode.value) {
    applyClassicEditRoomSettings();
  }
}

function closeEditRoomForm() {
  isEditingRoom.value = false;
  editRoomTitle.value = '';
  editRoomDescription.value = '';
  editRoomMaxPlayers.value = 8;
  editRoomRoleConfig.value = getDefaultRoleConfig(8);
  editNightTimeSeconds.value = 30;
  editVoteTimeSeconds.value = 15;
  editRoomDiscussionTimeSeconds.value = 60;
  editRoomMinStartPlayers.value = 4;
  editRoomTieVoteRule.value = 'no_execution';
  editSpectatorAllowed.value = false;
  editFirstNightAbilityAllowed.value = true;
  editFinalDefenseEnabled.value = false;
  editRoleRevealMode.value = 'private';
  editEntryMode.value = 'public';
  editEntryPassword.value = '';
  isEditEntryPasswordVisible.value = false;
  isRecommendedEditRolesEnabled.value = false;
  isEditAdvancedOpen.value = true;
  copyLiarSettingsToEdit(DEFAULT_LIAR_ROOM_SETTINGS);
}

function setEditRoomMaxPlayers(count) {
  editRoomMaxPlayers.value = Math.min(
    12,
    Math.max(minEditableMaxPlayers.value, Number(count)),
  );
}

function selectEditRoomMode(mode) {
  editRoomDescription.value = mode;

  if (isLiarRoom.value) {
    if (mode === '클래식') {
      applyClassicEditLiarSettings();
    }

    return;
  }

  if (mode === '친선전') {
    isRecommendedEditRolesEnabled.value = true;
    editRoomRoleConfig.value = getRecommendedRoleConfig(
      editRoomMaxPlayers.value,
    );
    return;
  }

  if (!fixedPlayerCounts.includes(Number(editRoomMaxPlayers.value))) {
    editRoomMaxPlayers.value =
      fixedPlayerCounts.find((count) => count >= minEditableMaxPlayers.value) ||
      12;
  }

  isRecommendedEditRolesEnabled.value = false;
  applyClassicEditRoomSettings();
}

function adjustEditRoomMaxPlayers(amount) {
  setEditRoomMaxPlayers(editRoomMaxPlayers.value + amount);
}

function toggleEditAdvancedSettings() {
  isEditAdvancedOpen.value = !isEditAdvancedOpen.value;
}

function applyRecommendedEditRoomRoles() {
  editRoomRoleConfig.value = getRecommendedRoleConfig(editRoomMaxPlayers.value);
}

function toggleRecommendedEditRoomRoles() {
  isRecommendedEditRolesEnabled.value = !isRecommendedEditRolesEnabled.value;

  if (isRecommendedEditRolesEnabled.value) {
    applyRecommendedEditRoomRoles();
  }
}

function resetEditRoomRoles() {
  if (isRecommendedEditRolesEnabled.value) {
    applyRecommendedEditRoomRoles();
    return;
  }

  editRoomRoleConfig.value = {
    citizen: 0,
    mafia: 0,
    police: 0,
    doctor: 0,
    stalker: 0,
  };
}

function adjustEditRoomRole(roleKey, amount) {
  if (!isFriendlyEditMode.value) {
    return;
  }

  isRecommendedEditRolesEnabled.value = false;
  const currentCount = Number(editRoomRoleConfig.value[roleKey] || 0);
  const nextCount = Math.max(0, currentCount + amount);

  if (
    amount > 0 &&
    editRoleConfigTotal.value >= Number(editRoomMaxPlayers.value)
  ) {
    return;
  }

  editRoomRoleConfig.value = {
    ...editRoomRoleConfig.value,
    [roleKey]: nextCount,
  };
}

async function saveRoomInfo() {
  if (!isHost.value || isUpdating.value) {
    return;
  }

  if (!editRoomTitle.value.trim()) {
    toastStore.error('방 제목을 입력하세요.');
    return;
  }

  if (!editRoomDescription.value.trim()) {
    toastStore.error('방 소개 내용을 입력하세요.');
    return;
  }

  if (players.value.length > Number(editRoomMaxPlayers.value)) {
    toastStore.error(
      `현재 접속 인원(${players.value.length}명)보다 적은 인원(${editRoomMaxPlayers.value}명)으로 변경할 수 없습니다.`,
    );
    return;
  }

  if (!isLiarRoom.value && !isEditRoleConfigValid.value) {
    toastStore.error('역할 인원수 합계가 참가 인원과 같아야 합니다.');
    return;
  }

  const nextEntryPassword = editEntryPassword.value.trim();
  const isSwitchingToPrivate =
    editEntryMode.value === 'private' && room.value?.entryMode !== 'private';

  if (isSwitchingToPrivate && !nextEntryPassword) {
    toastStore.error('비공개방은 비밀번호를 입력해야 합니다.');
    return;
  }

  isUpdating.value = true;

  try {
    room.value = await updateRoom(props.roomId, {
      title: editRoomTitle.value,
      description: editRoomDescription.value,
      maxPlayers: Number(editRoomMaxPlayers.value),
      roleConfig: isLiarRoom.value ? {} : editRoomRoleConfig.value,
      nightTimeSeconds: Number(editNightTimeSeconds.value),
      voteTimeSeconds: Number(editVoteTimeSeconds.value),
      discussionTimeSeconds: Number(editRoomDiscussionTimeSeconds.value),
      minStartPlayers: isLiarRoom.value
        ? 3
        : Number(editRoomMinStartPlayers.value),
      tieVoteRule: isLiarRoom.value ? 'revote' : editRoomTieVoteRule.value,
      spectatorAllowed: isLiarRoom.value
        ? false
        : editSpectatorAllowed.value,
      firstNightAbilityAllowed: isLiarRoom.value
        ? false
        : editFirstNightAbilityAllowed.value,
      finalDefenseEnabled: isLiarRoom.value
        ? false
        : editFinalDefenseEnabled.value,
      roleRevealMode: isLiarRoom.value ? 'private' : editRoleRevealMode.value,
      entryMode: editEntryMode.value,
      ...(editEntryMode.value === 'private' && nextEntryPassword
        ? {
            entryPassword: nextEntryPassword,
          }
        : {}),
    });

    if (isLiarRoom.value) {
      liarSettings.value = await configureLiarRoom(props.roomId, {
        settingMode: isFriendlyEditMode.value ? 'custom' : 'classic',
        categoryId: editLiarCategoryId.value || null,
        targetScore: Number(editLiarTargetScore.value),
        citizenWinScore: Number(editLiarCitizenWinScore.value),
        liarWinScore: Number(editLiarWinScore.value),
      });
    }

    lastSyncedAt.value = new Date();
    await roomStore.fetchRooms();
    closeEditRoomForm();
  } catch (error) {
    toastStore.error(error.message);
  } finally {
    isUpdating.value = false;
    if (shouldSyncAfterUpdate.value) {
      shouldSyncAfterUpdate.value = false;
      syncRoom();
    }
  }
}

async function startGame() {
  if (!isHost.value || !canStartGame.value || isUpdating.value) {
    return;
  }

  isUpdating.value = true;

  try {
    if (isLiarRoom.value) {
      await startLiarMatch(props.roomId);
    } else {
      await startGameRequest(props.roomId);
    }

    await syncRoom();
    if (chatChannel.value) {
      await sendRoomChatMessage(chatChannel.value, {
        userId: 'system',
        nickname: 'System',
        content: '모든 준비가 완료되어 게임이 시작되었습니다.',
        isSystem: true,
      }).catch(() => {});
    }
  } catch (error) {
    toastStore.error(error.message);
  } finally {
    isUpdating.value = false;
    if (shouldSyncAfterUpdate.value) {
      shouldSyncAfterUpdate.value = false;
      syncRoom();
    }
  }
}

async function leaveRoom() {
  if (!currentPlayer.value || isUpdating.value) {
    router.push('/home');
    return;
  }

  isUpdating.value = true;
  isLeavingRoomExplicitly = true;
  stopRoomHeartbeat();

  // Send leave message
  if (chatChannel.value) {
    await sendRoomChatMessage(chatChannel.value, {
      userId: 'system',
      nickname: 'System',
      content: `${savedUser.value.nickname}님이 퇴장했습니다.`,
      isSystem: true,
    }).catch(() => {});
  }

  try {
    await leaveRoomRequest(props.roomId);
    router.push('/home');
  } catch (error) {
    isLeavingRoomExplicitly = false;
    toastStore.error(error.message);
  } finally {
    isUpdating.value = false;
  }
}
</script>

<template>
  <section class="page-card room game-lobby-container">
    <div class="lobby-glow"></div>

    <p class="eyebrow">Game Room #{{ String(roomId).slice(0, 8) }}</p>

    <template v-if="room">
      <div class="room-heading">
        <div class="room-info-cluster">
          <h1 class="room-title">{{ room.title }}</h1>

          <div class="room-badges">
            <span
              class="badge status-badge"
              :class="room.status === 'waiting' ? 'waiting' : 'playing'"
            >
              {{ room.status === 'waiting' ? '🟢 대기중' : '🔴 게임중' }}
            </span>
            <span class="badge mode-badge">
              {{
                room.description === '친선전'
                    ? '🤝 커스텀'
                    : '🎭 클래식'
              }}
            </span>
            <span
              class="badge capacity-badge"
              :class="{ full: players.length >= room.maxPlayers }"
            >
              👥 {{ players.length }} / {{ room.maxPlayers }}
            </span>
          </div>

          <p class="host-info">
            방장: <strong class="host-name">{{ room.hostNickname }}</strong>
          </p>
          <p class="atmosphere-quote">
            {{
              isLiarRoom
                ? '"제시어를 모르는 라이어는 누구인가?"'
                : '"거짓말을 하는 자는 누구인가? 밤이 깊어갑니다..."'
            }}
          </p>
        </div>

        <div v-if="currentPlayer" class="room-control-panel">
          <div class="control-header">
            <span class="control-title">ROOM CONTROL</span>
            <span class="control-status" v-if="canStartGame">READY</span>
            <span class="control-status active" v-else-if="isGameStarted">
              STARTED
            </span>
          </div>
          <div class="room-actions">
            <button
              v-if="isHost"
              type="button"
              class="action-btn primary-btn pulse-anim"
              :disabled="
                isUpdating || !canStartGame || room.status !== 'waiting'
              "
              @click="startGame"
            >
              게임 시작
            </button>

            <button
              v-if="!isHost"
              type="button"
              class="action-btn"
              :class="
                currentPlayer.isReady
                  ? 'secondary-btn'
                  : 'primary-btn pulse-anim'
              "
              :disabled="isUpdating || isGameStarted"
              @click="toggleReady"
            >
              {{
                isGameStarted
                  ? '게임 진행 중'
                  : currentPlayer.isReady
                    ? '준비 취소'
                    : '준비 하기'
              }}
            </button>

            <button
              v-if="isHost"
              type="button"
              class="action-btn secondary-btn"
              :disabled="isUpdating || isGameStarted"
              @click="openEditRoomForm"
            >
              방 설정
            </button>

            <button
              type="button"
              class="action-btn danger-btn"
              :disabled="isUpdating"
              @click="leaveRoom"
            >
              나가기
            </button>
          </div>
        </div>
      </div>

      <form
        v-if="isEditingRoom"
        class="edit-room-form game-styled-form room-form-modal"
        role="dialog"
        aria-modal="true"
        aria-labelledby="edit-room-title"
        @submit.prevent="saveRoomInfo"
      >
        <div class="edit-room-header">
          <div>
            <p class="eyebrow">Room Setup</p>
            <h2 id="edit-room-title">방 설정</h2>
          </div>
          <button
            type="button"
            class="icon-close-btn"
            :disabled="isUpdating"
            aria-label="방 설정 닫기"
            @click="closeEditRoomForm"
          >
            X
          </button>
        </div>

        <div class="form-group">
          <label>방 제목</label>
          <input
            v-model="editRoomTitle"
            type="text"
            class="room-title-input"
            placeholder="방 제목"
          />
        </div>

        <div class="form-group">
          <label>참가 인원</label>
          <div v-if="!isFriendlyEditMode && !isLiarRoom" class="option-group">
            <button
              v-for="count in isLiarRoom ? liarPlayerCountOptions : fixedPlayerCounts"
              :key="count"
              type="button"
              class="option-btn"
              :class="{ active: editRoomMaxPlayers === count }"
              @click="editRoomMaxPlayers = count"
            >
              {{ count }}명
            </button>
          </div>
          <div v-else class="friendly-player-control">
            <div class="friendly-stepper">
              <button
                type="button"
                class="stepper-btn"
                :disabled="editRoomMaxPlayers <= minEditableMaxPlayers"
                @click="adjustEditRoomMaxPlayers(-1)"
              >
                -
              </button>
              <strong>{{ editRoomMaxPlayers }}명</strong>
              <button
                type="button"
                class="stepper-btn"
                :disabled="editRoomMaxPlayers >= 12"
                @click="adjustEditRoomMaxPlayers(1)"
              >
                +
              </button>
            </div>
            <input
              v-model.number="editRoomMaxPlayers"
              class="player-range"
              type="range"
              :min="minEditableMaxPlayers"
              max="12"
              step="1"
            />
            <div class="range-labels">
              <span>{{ minEditableMaxPlayers }}명</span>
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
              :class="{ active: editRoomDescription === '클래식' }"
              @click="selectEditRoomMode('클래식')"
            >
              🎭 클래식
            </button>
            <button
              type="button"
              class="option-btn"
              :class="{ active: editRoomDescription === '친선전' }"
              @click="selectEditRoomMode('친선전')"
            >
              🛠 커스텀
            </button>
          </div>
          <p class="mode-description">
            {{
              isLiarRoom
                ? isFriendlyEditMode
                  ? '테마와 목표 점수, 진영별 승리 점수를 직접 조정할 수 있습니다.'
                  : '표준 라이어 게임 점수 규칙으로 빠르게 시작합니다.'
                : isFriendlyEditMode
                  ? '역할 구성과 세부 규칙을 직접 조정할 수 있습니다.'
                  : '공식 역할 구성과 표준 규칙으로 빠르게 시작합니다.'
            }}
          </p>
        </div>

        <div class="room-custom-grid">
          <div v-if="!isLiarRoom" class="form-group">
            <label>역할 공개</label>
            <div class="option-group">
              <button
                type="button"
                class="option-btn"
                :class="{ active: editRoleRevealMode === 'private' }"
                :disabled="!isFriendlyEditMode"
                @click="editRoleRevealMode = 'private'"
              >
                비공개
              </button>
              <button
                type="button"
                class="option-btn"
                :class="{ active: editRoleRevealMode === 'public' }"
                :disabled="!isFriendlyEditMode"
                @click="editRoleRevealMode = 'public'"
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
                :class="{ active: editEntryMode === 'public' }"
                @click="selectEditRoomEntryMode('public')"
              >
                공개방
              </button>
              <button
                type="button"
                class="option-btn"
                :class="{ active: editEntryMode === 'private' }"
                @click="selectEditRoomEntryMode('private')"
              >
                비공개방
              </button>
            </div>
          </div>

          <div v-if="editEntryMode === 'private'" class="form-group">
            <label for="edit-room-entry-password">비밀번호</label>
            <div class="password-input-shell">
              <input
                id="edit-room-entry-password"
                v-model="editEntryPassword"
                :type="isEditEntryPasswordVisible ? 'text' : 'password'"
                class="text-input"
                placeholder="변경할 경우에만 새 비밀번호를 입력하세요"
                autocomplete="new-password"
              />
              <button
                type="button"
                class="password-toggle-icon"
                :aria-label="
                  isEditEntryPasswordVisible
                    ? '비밀번호 숨기기'
                    : '비밀번호 보기'
                "
                :title="
                  isEditEntryPasswordVisible
                    ? '비밀번호 숨기기'
                    : '비밀번호 보기'
                "
                @click="toggleEditEntryPasswordVisibility"
                >
                  <svg
                    v-if="isEditEntryPasswordVisible"
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
                    <path
                      d="M2.5 12s3.5-6.5 9.5-6.5c1.7 0 3.3.38 4.7 1.04M21.5 12s-3.5 6.5-9.5 6.5c-1.7 0-3.3-.38-4.7-1.04"
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
              </button>
            </div>
          </div>
        </div>

        <section v-if="isLiarRoom" class="advanced-settings-panel">
          <div class="advanced-settings-grid">
            <div class="form-group">
              <label>테마</label>
              <select v-model="editLiarCategoryId">
                <option :value="null">랜덤</option>
                <option
                  v-for="category in liarCategories"
                  :key="category.id"
                  :value="category.id"
                >
                  {{ category.label }}
                </option>
              </select>
            </div>

            <template v-if="isFriendlyEditMode">
              <div class="form-group">
                <label>목표 점수</label>
                <select v-model.number="editLiarTargetScore">
                  <option v-for="score in [3, 5, 7, 10]" :key="`edit-liar-target-${score}`" :value="score">
                    {{ score }}점
                  </option>
                </select>
              </div>

              <div class="form-group">
                <label>일반 유저 승리 점수</label>
                <select v-model.number="editLiarCitizenWinScore">
                  <option v-for="score in [1, 2]" :key="`edit-citizen-score-${score}`" :value="score">
                    +{{ score }}점
                  </option>
                </select>
              </div>

              <div class="form-group">
                <label>라이어 승리 점수</label>
                <select v-model.number="editLiarWinScore">
                  <option v-for="score in [2, 3, 5]" :key="`edit-liar-score-${score}`" :value="score">
                    +{{ score }}점
                  </option>
                </select>
              </div>

              <div class="form-group">
                <label>토론 시간</label>
                <select v-model.number="editRoomDiscussionTimeSeconds">
                  <option
                    v-for="seconds in discussionTimeOptions"
                    :key="`edit-liar-discussion-${seconds}`"
                    :value="seconds"
                  >
                    {{ seconds }}초
                  </option>
                </select>
              </div>

              <div class="form-group">
                <label>투표 시간</label>
                <select v-model.number="editVoteTimeSeconds">
                  <option
                    v-for="seconds in voteTimeOptions"
                    :key="`edit-liar-vote-${seconds}`"
                    :value="seconds"
                  >
                    {{ seconds }}초
                  </option>
                </select>
              </div>
            </template>
          </div>

          <p class="classic-rules-note">
            {{
              isFriendlyEditMode
                ? '라이어 1명, 자기 투표 불가, 동률 시 재투표 규칙은 고정됩니다.'
                : '클래식은 목표 5점, 일반 유저 +1점, 라이어 +2점, 동률 시 재투표로 진행합니다.'
            }}
          </p>
        </section>

        <section v-else-if="isFriendlyEditMode" class="advanced-settings-panel">
          <button
            type="button"
            class="advanced-settings-toggle"
            :class="{ active: isEditAdvancedOpen }"
            @click="toggleEditAdvancedSettings"
          >
            <span>세부 설정</span>
            <strong>{{ isEditAdvancedOpen ? '접기' : '펼치기' }}</strong>
          </button>

          <div v-if="isEditAdvancedOpen" class="advanced-settings-grid">
            <div class="form-group">
              <label>밤 시간</label>
              <select v-model.number="editNightTimeSeconds">
                <option
                  v-for="seconds in nightTimeOptions"
                  :key="`edit-night-${seconds}`"
                  :value="seconds"
                >
                  {{ seconds }}초
                </option>
              </select>
            </div>

            <div class="form-group">
              <label>토론 시간</label>
              <select v-model.number="editRoomDiscussionTimeSeconds">
                <option
                  v-for="seconds in discussionTimeOptions"
                  :key="`edit-discussion-${seconds}`"
                  :value="seconds"
                >
                  {{ seconds }}초
                </option>
              </select>
            </div>

            <div class="form-group">
              <label>최소 시작 인원</label>
              <select v-model.number="editRoomMinStartPlayers">
                <option
                  v-for="count in editMinStartPlayerOptions"
                  :key="`edit-start-${count}`"
                  :value="count"
                >
                  {{ count }}명
                </option>
              </select>
            </div>

            <div class="form-group">
              <label>투표 시간</label>
              <select v-model.number="editVoteTimeSeconds">
                <option
                  v-for="seconds in voteTimeOptions"
                  :key="`edit-vote-${seconds}`"
                  :value="seconds"
                >
                  {{ seconds }}초
                </option>
              </select>
            </div>

            <div class="form-group">
              <label>동점 투표</label>
              <select v-model="editRoomTieVoteRule">
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
                  :class="{ active: editSpectatorAllowed }"
                  @click="editSpectatorAllowed = true"
                >
                  활성화
                </button>
                <button
                  type="button"
                  class="option-btn"
                  :class="{ active: !editSpectatorAllowed }"
                  @click="editSpectatorAllowed = false"
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
                  :class="{ active: editFirstNightAbilityAllowed }"
                  @click="editFirstNightAbilityAllowed = true"
                >
                  활성화
                </button>
                <button
                  type="button"
                  class="option-btn"
                  :class="{ active: !editFirstNightAbilityAllowed }"
                  @click="editFirstNightAbilityAllowed = false"
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
                  :class="{ active: editFinalDefenseEnabled }"
                  @click="editFinalDefenseEnabled = true"
                >
                  활성화
                </button>
                <button
                  type="button"
                  class="option-btn"
                  :class="{ active: !editFinalDefenseEnabled }"
                  @click="editFinalDefenseEnabled = false"
                >
                  비활성화
                </button>
              </div>
            </div>
          </div>
        </section>
        <p v-else class="classic-rules-note">
          클래식은 비공개 역할, 표준 진행 시간, 기본 투표 규칙으로
          고정됩니다. 세부 규칙을 바꾸려면 커스텀을 선택하세요.
        </p>

        <section
          v-if="!isLiarRoom"
          class="role-config-section"
          :class="{
            invalid: !isEditRoleConfigValid,
            locked: !isFriendlyEditMode,
          }"
        >
          <div class="role-config-header">
            <div>
              <p class="eyebrow">Roles</p>
              <h3>역할 구성</h3>
            </div>
            <div>
              <span class="role-lock-status">{{
                editRoleConfigStatusText
              }}</span>
              <strong
                :class="{
                  valid: isEditRoleConfigValid,
                  invalid: !isEditRoleConfigValid,
                }"
              >
                역할 합계 {{ editRoleConfigTotal }} / {{ editRoomMaxPlayers }}
              </strong>
            </div>
          </div>

          <p v-if="isFriendlyEditMode" class="role-config-intro">
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
                    !isFriendlyEditMode || editRoomRoleConfig[role.key] <= 0
                  "
                  @click="adjustEditRoomRole(role.key, -1)"
                >
                  -
                </button>
                <strong>{{ editRoomRoleConfig[role.key] }}</strong>
                <button
                  type="button"
                  :disabled="
                    !isFriendlyEditMode ||
                    editRoleConfigTotal >= editRoomMaxPlayers
                  "
                  @click="adjustEditRoomRole(role.key, 1)"
                >
                  +
                </button>
              </div>
            </article>
          </div>

          <div v-if="isFriendlyEditMode" class="role-config-actions">
            <button
              type="button"
              :class="{ active: isRecommendedEditRolesEnabled }"
              @click="toggleRecommendedEditRoomRoles"
            >
              추천 구성 적용
            </button>
            <button type="button" @click="resetEditRoomRoles">초기화</button>
          </div>

          <p v-if="!isFriendlyEditMode" class="role-config-help">
            {{ editRoleConfigStatusText }}으로 역할 인원수는 수정할 수 없습니다.
          </p>
          <p v-else-if="!isEditRoleConfigValid" class="role-config-warning">
            역할 인원수 합계가 참가 인원과 같아야 저장할 수 있습니다.
          </p>
        </section>

        <div class="edit-actions">
          <button
            type="submit"
            class="submit-btn"
            :disabled="isUpdating || (!isLiarRoom && !isEditRoleConfigValid)"
          >
            {{ isUpdating ? '저장 중...' : '저장' }}
          </button>
          <button
            type="button"
            :disabled="isUpdating"
            @click="closeEditRoomForm"
          >
            취소
          </button>
        </div>
      </form>

      <section v-if="roomBriefing" class="room-rules-disclosure">
        <button
          type="button"
          class="room-rules-toggle"
          :class="{ active: isRoomBriefingOpen }"
          :aria-expanded="isRoomBriefingOpen"
          aria-controls="room-rules-content"
          @click="isRoomBriefingOpen = !isRoomBriefingOpen"
        >
          <span>
            <b>게임 정보 &amp; 라운드 진행</b>
            <small>역할 구성, 방 규칙, 단계별 진행 시간을 확인합니다.</small>
          </span>
          <strong aria-hidden="true">{{ isRoomBriefingOpen ? '−' : '+' }}</strong>
        </button>
      </section>

      <div v-if="roomBriefing && isRoomBriefingOpen" id="room-rules-content" class="room-rules-grid">
        <section class="rules-briefing-panel">
          <div class="rules-panel-heading">
            <p>Room Briefing</p>
            <h2>게임 정보</h2>
          </div>

          <div class="briefing-hero">
            <div>
              <span>현재 인원</span>
              <strong>{{ roomBriefing.players }}</strong>
            </div>
            <div>
              <span>시작 조건</span>
              <strong>{{ roomBriefing.minStartPlayers }}명 이상</strong>
            </div>
          </div>

          <div class="briefing-section">
            <div class="briefing-section-title">
              <span aria-hidden="true">🎭</span>
              <strong>역할 구성</strong>
              <em>합계 {{ roomBriefing.roleTotal }}명</em>
            </div>
            <div class="role-rule-list">
              <span
                v-for="role in roomBriefing.roles"
                :key="role.key"
                class="role-rule-chip"
                :class="role.tone"
              >
                <b>{{ role.label }}</b>
                <em>×{{ role.count }}</em>
              </span>
            </div>
          </div>

          <div class="briefing-section">
            <div class="briefing-section-title">
              <span aria-hidden="true">🔎</span>
              <strong>공개 및 진행 규칙</strong>
            </div>
            <dl class="rule-status-list">
              <div
                v-for="setting in roomBriefing.settings"
                :key="setting.label"
                class="rule-status-row"
              >
                <dt>{{ setting.label }}</dt>
                <dd :class="setting.tone">{{ setting.value }}</dd>
              </div>
            </dl>
          </div>
        </section>

        <section class="rules-flow-panel">
          <div class="rules-panel-heading">
            <p>Game Flow</p>
            <h2>라운드 진행</h2>
          </div>

          <ol class="game-flow-timeline">
            <li v-for="item in gameFlowItems" :key="item.label">
              <span class="flow-icon" aria-hidden="true">{{ item.icon }}</span>
              <div>
                <strong>{{ item.label }}</strong>
                <small>{{ item.description }}</small>
              </div>
              <em>{{ item.duration }}</em>
            </li>
          </ol>

          <p class="flow-summary">
            {{
              isLiarRoom
                ? `기본 ${gameFlowTotalSeconds}초 · 제시어 확인 후 토론과 투표 진행`
                : `총 ${gameFlowTotalSeconds}초 · 밤 능력 사용 후 토론과 투표 진행`
            }}
          </p>
        </section>
      </div>

      <div class="players-section">
        <div class="players-heading">
          <h2>참여 인원 목록</h2>
          <span
            v-if="lastSyncedAt"
            class="sync-status"
            :class="{ 'ready-text': canStartGame || isGameStarted }"
          >
            {{ roomProgressText }}
          </span>
        </div>
        <ul class="player-card-list">
          <li
            v-for="player in players"
            :key="player.userId"
            class="player-card"
            :class="{
              'is-me': player.userId === savedUser?.id,
              disconnected: player.isConnected === false,
            }"
          >
            <div class="player-avatar-wrapper">
              <img
                :src="`/avatars/${player.avatar || 'default-mafia'}.png`"
                alt="Avatar"
                class="player-avatar"
                @error="(e) => (e.target.style.display = 'none')"
              />
              <div class="player-level">Lv.{{ player.level || 1 }}</div>
            </div>

            <div class="player-info">
              <div class="player-name-wrapper">
                <span v-if="player.isHost" class="host-icon">👑</span>
                <strong class="player-name">{{ player.nickname }}</strong>
              </div>
              <span class="player-title">{{
                player.title || '초보 마피아'
              }}</span>
            </div>

            <div class="player-badges">
              <span
                class="badge ready-badge"
                :class="{ active: player.isReady }"
              >
                {{ player.isConnected === false ? 'OFFLINE' : player.isReady ? 'READY' : 'WAIT' }}
              </span>
            </div>
          </li>

          <!-- Empty Slots -->
          <li
            v-for="i in Math.max(0, room.maxPlayers - players.length)"
            :key="'empty-' + i"
            class="player-card empty-slot"
          >
            <button
              type="button"
              class="empty-slot-button"
              :disabled="room.status !== 'waiting'"
              aria-label="친구 초대"
              @click="openInviteModal"
            >
              <span class="empty-content">
                <span class="empty-icon">+ EMPTY SLOT</span>
                <span class="empty-text">
                  {{
                    room.status === 'waiting' ? '친구 초대' : '대기 중에만 가능'
                  }}
                </span>
              </span>
            </button>
          </li>
        </ul>
      </div>

      <div class="room-chat-section">
        <div class="chat-header">대기실 채팅</div>
        <div class="chat-log" ref="chatLogRef">
          <div
            v-for="msg in chatMessages"
            :key="msg.id"
            class="chat-message"
            :class="{ 'system-message': msg.isSystem, whisper: msg.isWhisper }"
          >
            <span class="chat-time">[{{ msg.createdAt }}]</span>
            <template v-if="msg.isSystem">
              <span class="chat-content system">{{ msg.content }}</span>
            </template>
            <template v-else>
              <strong
                class="chat-author"
                :class="{
                  me: msg.userId === savedUser?.id,
                  host: room.hostUserId === msg.userId,
                }"
              >
                <span v-if="msg.isWhisper" class="whisper-label">귓속말</span>
                {{ msg.isWhisper ? `${msg.nickname} → ${msg.targetNickname}` : msg.nickname }}:
              </strong>
              <span class="chat-content">{{ msg.content }}</span>
            </template>
          </div>
        </div>
        <form class="chat-form" @submit.prevent="submitChat">
          <input
            v-model="chatDraft"
            type="text"
            placeholder="메시지 또는 /w 대상닉네임 메시지"
            maxlength="200"
            :disabled="!chatChannel"
          />
          <button
            type="submit"
            :disabled="!chatChannel || !chatDraft.trim() || isUpdating"
          >
            전송
          </button>
        </form>
      </div>

      <div
        v-if="isInviteModalOpen"
        class="invite-modal-backdrop"
        @click.self="closeInviteModal"
      >
        <section
          class="invite-modal room-form-modal"
          role="dialog"
          aria-modal="true"
          aria-labelledby="invite-modal-title"
        >
          <div class="edit-room-header">
            <div>
              <p class="eyebrow">Invite</p>
              <h2 id="invite-modal-title">친구 초대</h2>
            </div>
            <button
              type="button"
              class="icon-close-btn"
              aria-label="초대 모달 닫기"
              @click="closeInviteModal"
            >
              X
            </button>
          </div>

          <form class="invite-search-form" @submit.prevent="inviteByNickname">
            <label for="invite-search">닉네임 검색/입력</label>
            <div class="invite-search-row">
              <input
                id="invite-search"
                v-model="inviteSearchQuery"
                type="text"
                class="text-input"
                placeholder="친구 닉네임을 입력하세요"
              />
              <button type="submit" :disabled="!inviteSearchQuery.trim()">
                초대
              </button>
            </div>
          </form>

          <div class="invite-modal-meta">
            <span>초대 가능 친구 {{ filteredInviteFriends.length }}명</span>
            <span
              >쿨타임 중
              {{
                inviteFriends.filter((friend) => friend.isInvited).length
              }}명</span
            >
          </div>

          <div v-if="isLoadingInviteFriends" class="invite-empty">
            친구 목록을 불러오는 중...
          </div>
          <div
            v-else-if="filteredInviteFriends.length === 0"
            class="invite-empty"
          >
            초대할 수 있는 친구가 없습니다.
          </div>
          <ul v-else class="invite-friend-list">
            <li
              v-for="friend in filteredInviteFriends"
              :key="friend.id"
              class="invite-friend-card"
              :class="{
                disabled: friend.isInvited || !friend.isOnline,
                online: friend.isOnline,
              }"
            >
              <button
                type="button"
                class="invite-friend-main"
                :disabled="friend.isInvited || !friend.isOnline"
                @click="inviteFriendToRoom(friend)"
              >
                <div>
                  <strong>{{ friend.nickname }}</strong>
                  <span>{{ friend.title }}</span>
                </div>
                <small>
                  {{
                    players.some((player) => player.userId === friend.id)
                      ? '이미 방에 있음'
                      : !friend.isOnline
                        ? '오프라인'
                        : friend.isInvited
                          ? `${friend.inviteRemainingSeconds}초 쿨타임`
                          : '초대 가능'
                  }}
                </small>
              </button>
            </li>
          </ul>
        </section>
      </div>
    </template>

    <p v-else-if="isLoading">방 정보를 불러오는 중입니다.</p>
  </section>
</template>

<style scoped>
.game-lobby-container {
  position: relative;
  overflow: hidden;
  background: linear-gradient(
    180deg,
    rgba(30, 20, 15, 0.9),
    rgba(15, 10, 8, 0.95)
  );
  border: 1px solid rgba(255, 120, 52, 0.2);
  box-shadow:
    0 24px 48px rgba(0, 0, 0, 0.6),
    inset 0 0 40px rgba(255, 120, 52, 0.05);
  padding: 2.5rem;
  border-radius: 12px;
  display: flex;
  flex-direction: column;
  gap: 2rem;
}

.lobby-glow {
  position: absolute;
  top: -50%;
  left: -50%;
  width: 200%;
  height: 200%;
  background: radial-gradient(
    circle at 50% 0%,
    rgba(200, 50, 30, 0.12),
    transparent 40%
  );
  pointer-events: none;
  z-index: 0;
}

.eyebrow {
  color: var(--color-accent);
  font-weight: 800;
  position: relative;
  z-index: 1;
  margin: 0;
}

.room-heading {
  align-items: flex-start;
  display: flex;
  gap: 2rem;
  justify-content: space-between;
  position: relative;
  z-index: 1;
}

.room-info-cluster {
  display: flex;
  flex-direction: column;
  gap: 0.6rem;
}

.room-title {
  color: #fff;
  font-size: 2.8rem;
  font-weight: 900;
  text-shadow: 0 0 20px rgba(255, 120, 52, 0.4);
  letter-spacing: -0.02em;
  line-height: 1.1;
  margin: 0;
}

.room-badges {
  display: flex;
  flex-wrap: wrap;
  gap: 0.5rem;
  margin-top: 0.25rem;
}

.badge {
  padding: 0.35rem 0.7rem;
  border-radius: 4px;
  font-size: 0.85rem;
  font-weight: 800;
  letter-spacing: 0.05em;
  background: rgba(0, 0, 0, 0.4);
  border: 1px solid rgba(255, 255, 255, 0.1);
}

.status-badge.waiting {
  color: #86efac;
  border-color: rgba(34, 197, 94, 0.4);
  background: rgba(34, 197, 94, 0.1);
}
.status-badge.playing {
  color: #fca5a5;
  border-color: rgba(239, 68, 68, 0.4);
  background: rgba(239, 68, 68, 0.1);
}
.mode-badge {
  color: #ffbe55;
  border-color: rgba(255, 190, 85, 0.4);
  background: rgba(255, 190, 85, 0.1);
}
.capacity-badge {
  color: #93c5fd;
  border-color: rgba(59, 130, 246, 0.4);
}
.capacity-badge.full {
  color: #fca5a5;
  border-color: rgba(239, 68, 68, 0.4);
}

.host-info {
  color: rgba(255, 245, 224, 0.6);
  font-size: 0.9rem;
  margin: 0;
}
.host-name {
  color: #ffbe55;
}

.atmosphere-quote {
  font-style: italic;
  color: rgba(255, 120, 52, 0.7);
  font-size: 0.95rem;
  margin-top: 0.5rem;
  border-left: 2px solid rgba(255, 120, 52, 0.4);
  padding-left: 0.75rem;
}

.room-control-panel {
  align-self: flex-start;
  background: rgba(20, 15, 10, 0.6);
  border: 1px solid rgba(255, 120, 52, 0.15);
  border-radius: 8px;
  display: flex;
  flex-direction: column;
  gap: 0.62rem;
  max-width: 31rem;
  min-width: min(31rem, 42vw);
  padding: 0.78rem;
  box-shadow: inset 0 0 20px rgba(0, 0, 0, 0.5);
  position: relative;
  z-index: 1;
}

.control-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  border-bottom: 1px solid rgba(255, 120, 52, 0.2);
  padding-bottom: 0.38rem;
}

.control-title {
  color: #ffbe55;
  font-weight: 900;
  font-size: 0.85rem;
  letter-spacing: 0.1em;
}

.control-status {
  color: #86efac;
  font-weight: 900;
  font-size: 0.75rem;
  animation: pulse 1.5s infinite;
}

.control-status.active {
  animation: none;
  color: #ffbe55;
}

.room-actions {
  display: flex;
  flex-wrap: wrap;
  gap: 0.45rem;
}

.action-btn {
  flex: 1 1 auto;
  font-family: inherit;
  font-weight: 900;
  font-size: 0.82rem;
  min-height: 2.35rem;
  padding: 0.58rem 0.78rem;
  border-radius: 6px;
  cursor: pointer;
  transition: all 0.2s cubic-bezier(0.4, 0, 0.2, 1);
  text-transform: uppercase;
  letter-spacing: 0.05em;
  border: none;
}

.primary-btn {
  background: linear-gradient(180deg, #ff8a00, #e52e71);
  color: #fff;
  box-shadow:
    0 4px 15px rgba(229, 46, 113, 0.3),
    inset 0 1px 1px rgba(255, 255, 255, 0.3);
}

.primary-btn:hover:not(:disabled) {
  transform: translateY(-2px);
  box-shadow:
    0 6px 20px rgba(229, 46, 113, 0.5),
    inset 0 1px 1px rgba(255, 255, 255, 0.4);
  filter: brightness(1.1);
}

.secondary-btn {
  background: rgba(255, 255, 255, 0.05);
  color: #ffbe55;
  border: 1px solid rgba(255, 190, 85, 0.3);
}

.secondary-btn:hover:not(:disabled) {
  background: rgba(255, 190, 85, 0.1);
  border-color: #ffbe55;
  transform: translateY(-1px);
}

.danger-btn {
  background: rgba(127, 29, 29, 0.08);
  border: 1px solid rgba(248, 113, 113, 0.16);
  color: rgba(252, 165, 165, 0.72);
  font-size: 0.78rem;
  padding: 0.5rem 0.68rem;
}

.danger-btn:hover:not(:disabled) {
  background: rgba(127, 29, 29, 0.18);
  border-color: rgba(248, 113, 113, 0.34);
  color: #fca5a5;
}

.action-btn:disabled {
  opacity: 0.4;
  cursor: not-allowed;
  filter: grayscale(0.8);
}

@keyframes pulse {
  0% {
    box-shadow: 0 0 0 0 rgba(229, 46, 113, 0.4);
  }
  70% {
    box-shadow: 0 0 0 10px rgba(229, 46, 113, 0);
  }
  100% {
    box-shadow: 0 0 0 0 rgba(229, 46, 113, 0);
  }
}

.pulse-anim:not(:disabled) {
  animation: pulse 2s infinite;
}

.game-started-panel {
  align-items: center;
  background:
    radial-gradient(circle at 12% 0%, rgba(255, 190, 85, 0.16), transparent 34%),
    linear-gradient(135deg, rgba(61, 32, 19, 0.82), rgba(12, 8, 7, 0.92));
  border: 1px solid rgba(255, 190, 85, 0.22);
  border-radius: 12px;
  box-shadow:
    0 16px 34px rgba(0, 0, 0, 0.34),
    inset 0 0 24px rgba(255, 138, 0, 0.05);
  display: flex;
  gap: 1rem;
  justify-content: space-between;
  padding: 1rem 1.15rem;
  position: relative;
  z-index: 1;
}

.game-started-panel p {
  color: rgba(255, 190, 85, 0.66);
  font-size: 0.75rem;
  font-weight: 900;
  letter-spacing: 0.08em;
  margin: 0 0 0.15rem;
  text-transform: uppercase;
}

.game-started-panel h2 {
  color: #fff1d6;
  font-size: clamp(1.2rem, 2vw, 1.55rem);
  font-weight: 900;
  margin: 0;
}

.game-started-panel > span {
  color: rgba(255, 245, 224, 0.68);
  font-size: 0.88rem;
  font-weight: 800;
  text-align: right;
}

.game-board-panel {
  display: grid;
  gap: 1rem;
  grid-template-columns: minmax(12rem, 0.8fr) minmax(0, 1.35fr) minmax(14rem, 0.9fr);
  position: relative;
  z-index: 1;
}

.game-role-card,
.game-phase-card,
.game-survivor-card {
  background:
    linear-gradient(180deg, rgba(255, 255, 255, 0.055), rgba(255, 255, 255, 0.025)),
    rgba(16, 11, 9, 0.72);
  border: 1px solid rgba(255, 190, 85, 0.14);
  border-radius: 12px;
  box-shadow:
    0 14px 30px rgba(0, 0, 0, 0.28),
    inset 0 0 24px rgba(255, 138, 0, 0.035);
  min-width: 0;
  padding: 1rem;
}

.game-role-card {
  display: grid;
  gap: 0.4rem;
}

.game-role-card span,
.game-survivor-card > span {
  color: rgba(255, 190, 85, 0.64);
  font-size: 0.75rem;
  font-weight: 900;
  letter-spacing: 0.08em;
  text-transform: uppercase;
}

.game-role-card strong,
.game-survivor-card > strong {
  color: #fff1d6;
  font-size: 1.55rem;
  font-weight: 900;
}

.game-role-card p,
.game-phase-card p {
  color: rgba(255, 245, 224, 0.68);
  font-size: 0.86rem;
  font-weight: 800;
  line-height: 1.45;
  margin: 0;
}

.game-role-card.mafia {
  border-color: rgba(248, 113, 113, 0.3);
}

.game-role-card.police {
  border-color: rgba(96, 165, 250, 0.3);
}

.game-role-card.doctor {
  border-color: rgba(74, 222, 128, 0.28);
}

.phase-meter-header {
  align-items: center;
  display: flex;
  gap: 1rem;
  justify-content: space-between;
  margin-bottom: 0.85rem;
}

.phase-meter-header span {
  color: rgba(255, 190, 85, 0.7);
  display: block;
  font-size: 0.8rem;
  font-weight: 900;
}

.phase-meter-header strong {
  color: #fff1d6;
  font-size: 1.8rem;
  font-weight: 900;
}

.phase-meter-header button,
.game-action-box button {
  background: linear-gradient(180deg, #ffbe55, #c9711d);
  border: 0;
  border-radius: 7px;
  color: #1a0f08;
  cursor: pointer;
  font: inherit;
  font-size: 0.82rem;
  font-weight: 900;
  padding: 0.58rem 0.78rem;
}

.phase-meter-header button:disabled,
.game-action-box button:disabled {
  cursor: not-allowed;
  filter: grayscale(0.8);
  opacity: 0.45;
}

.game-action-box {
  background: rgba(0, 0, 0, 0.2);
  border: 1px solid rgba(255, 190, 85, 0.12);
  border-radius: 10px;
  display: grid;
  gap: 0.58rem;
  margin-top: 0.85rem;
  padding: 0.75rem;
}

.game-action-box label,
.game-action-box small {
  color: rgba(255, 245, 224, 0.62);
  font-size: 0.78rem;
  font-weight: 800;
}

.game-action-box > div {
  display: grid;
  gap: 0.5rem;
  grid-template-columns: minmax(0, 1fr) auto;
}

.game-action-box select {
  background: rgba(0, 0, 0, 0.34);
  border: 1px solid rgba(255, 190, 85, 0.18);
  border-radius: 7px;
  color: #fff1d6;
  font: inherit;
  min-width: 0;
  padding: 0.55rem 0.65rem;
}

.game-survivor-card {
  display: grid;
  gap: 0.55rem;
}

.game-survivor-card ul {
  display: grid;
  gap: 0.4rem;
  list-style: none;
  margin: 0;
  max-height: 13rem;
  overflow-y: auto;
  padding: 0;
}

.game-survivor-card li {
  align-items: center;
  background: rgba(255, 255, 255, 0.045);
  border: 1px solid rgba(255, 255, 255, 0.06);
  border-radius: 8px;
  display: flex;
  gap: 0.55rem;
  justify-content: space-between;
  min-width: 0;
  padding: 0.5rem 0.6rem;
}

.game-survivor-card li.eliminated {
  opacity: 0.45;
}

.game-survivor-card b {
  color: #fff1d6;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.game-survivor-card em {
  color: rgba(255, 245, 224, 0.58);
  flex: 0 0 auto;
  font-size: 0.76rem;
  font-style: normal;
  font-weight: 900;
}

.room-rules-disclosure {
  position: relative;
  z-index: 1;
}

.room-rules-toggle {
  align-items: center;
  background:
    linear-gradient(90deg, rgba(255, 138, 0, 0.1), rgba(229, 46, 113, 0.045)),
    rgba(15, 9, 6, 0.8);
  border: 1px solid rgba(255, 190, 85, 0.18);
  border-radius: 10px;
  color: #fff1d6;
  cursor: pointer;
  display: flex;
  font: inherit;
  gap: 1rem;
  justify-content: space-between;
  min-height: 3.5rem;
  padding: 0.7rem 0.85rem 0.7rem 1rem;
  text-align: left;
  transition:
    background 0.16s ease,
    border-color 0.16s ease,
    box-shadow 0.16s ease;
  width: 100%;
}

.room-rules-toggle:hover,
.room-rules-toggle.active {
  background:
    linear-gradient(90deg, rgba(255, 138, 0, 0.16), rgba(229, 46, 113, 0.07)),
    rgba(20, 12, 8, 0.88);
  border-color: rgba(255, 190, 85, 0.38);
  box-shadow: 0 10px 24px rgba(0, 0, 0, 0.22);
}

.room-rules-toggle span {
  display: grid;
  gap: 0.18rem;
  min-width: 0;
}

.room-rules-toggle b {
  color: #fff1d6;
  font-size: 0.94rem;
  font-weight: 900;
}

.room-rules-toggle small {
  color: rgba(255, 245, 224, 0.58);
  font-size: 0.76rem;
  font-weight: 800;
  line-height: 1.4;
}

.room-rules-toggle > strong {
  align-items: center;
  background: rgba(255, 190, 85, 0.1);
  border: 1px solid rgba(255, 190, 85, 0.2);
  border-radius: 6px;
  color: #ffbe55;
  display: inline-flex;
  flex: 0 0 auto;
  font-size: 1.25rem;
  height: 2rem;
  justify-content: center;
  line-height: 1;
  width: 2rem;
}

.room-rules-grid {
  background:
    radial-gradient(circle at 12% 0%, rgba(255, 138, 0, 0.12), transparent 34%),
    linear-gradient(135deg, rgba(34, 20, 14, 0.92), rgba(10, 7, 6, 0.94));
  border: 1px solid rgba(255, 190, 85, 0.16);
  border-radius: 14px;
  box-shadow:
    0 18px 44px rgba(0, 0, 0, 0.38),
    inset 0 1px rgba(255, 255, 255, 0.04);
  display: grid;
  gap: 0.85rem;
  grid-template-columns: minmax(0, 1.42fr) minmax(18rem, 0.82fr);
  padding: clamp(1rem, 1.6vw, 1.35rem);
  position: relative;
  z-index: 1;
}

.rules-briefing-panel,
.rules-flow-panel {
  background:
    linear-gradient(180deg, rgba(255, 255, 255, 0.055), rgba(255, 255, 255, 0.025)),
    rgba(16, 11, 9, 0.68);
  border: 1px solid rgba(255, 190, 85, 0.14);
  border-radius: 12px;
  box-shadow:
    0 12px 28px rgba(0, 0, 0, 0.24),
    inset 0 0 28px rgba(255, 138, 0, 0.035);
  display: flex;
  flex-direction: column;
  gap: 0.9rem;
  min-width: 0;
  padding: clamp(1rem, 1.9vw, 1.35rem);
}

.rules-panel-heading {
  display: grid;
  gap: 0.18rem;
}

.rules-panel-heading p {
  color: rgba(255, 190, 85, 0.62);
  font-size: 0.75rem;
  font-weight: 900;
  letter-spacing: 0.08em;
  margin: 0;
  text-transform: uppercase;
}

.rules-panel-heading h2 {
  color: #fff1d6;
  font-size: clamp(1.08rem, 1.7vw, 1.35rem);
  font-weight: 900;
  letter-spacing: 0;
  margin: 0;
}

.briefing-hero {
  display: grid;
  gap: 0.75rem;
  grid-template-columns: repeat(2, minmax(0, 1fr));
}

.briefing-hero > div {
  align-items: center;
  background:
    linear-gradient(180deg, rgba(255, 190, 85, 0.12), rgba(80, 31, 21, 0.2)),
    rgba(0, 0, 0, 0.2);
  border: 1px solid rgba(255, 190, 85, 0.18);
  border-radius: 10px;
  display: flex;
  gap: 0.75rem;
  justify-content: space-between;
  min-width: 0;
  padding: 0.62rem 0.78rem;
}

.briefing-hero span,
.briefing-section-title em,
.game-flow-timeline small {
  color: rgba(255, 245, 224, 0.62);
  font-size: 0.78rem;
  font-weight: 800;
}

.briefing-hero strong {
  color: #fff5e1;
  font-size: clamp(1.08rem, 1.8vw, 1.35rem);
  font-weight: 900;
  white-space: nowrap;
}

.briefing-section {
  display: grid;
  gap: 0.62rem;
}

.briefing-section-title {
  align-items: center;
  display: flex;
  flex-wrap: wrap;
  gap: 0.55rem;
  min-width: 0;
}

.briefing-section-title > span {
  align-items: center;
  background: rgba(255, 190, 85, 0.12);
  border: 1px solid rgba(255, 190, 85, 0.18);
  border-radius: 8px;
  display: inline-flex;
  flex: 0 0 auto;
  height: 1.65rem;
  justify-content: center;
  width: 1.65rem;
}

.briefing-section-title strong {
  color: #fff1d6;
  font-size: 0.95rem;
  font-weight: 900;
}

.role-rule-list {
  display: flex;
  flex-wrap: wrap;
  gap: 0.42rem;
  min-width: 0;
}

.role-rule-chip {
  align-items: center;
  background: rgba(255, 255, 255, 0.055);
  border: 1px solid rgba(255, 190, 85, 0.16);
  border-radius: 999px;
  box-shadow: 0 0 14px rgba(255, 190, 85, 0.06);
  display: flex;
  gap: 0.38rem;
  justify-content: center;
  min-width: 0;
  padding: 0.34rem 0.66rem;
}

.role-rule-chip.citizen {
  border-color: rgba(125, 211, 252, 0.26);
  box-shadow: 0 0 14px rgba(125, 211, 252, 0.08);
}

.role-rule-chip.mafia {
  border-color: rgba(248, 113, 113, 0.34);
  box-shadow: 0 0 16px rgba(248, 113, 113, 0.12);
}

.role-rule-chip.police {
  border-color: rgba(96, 165, 250, 0.34);
  box-shadow: 0 0 16px rgba(96, 165, 250, 0.1);
}

.role-rule-chip.doctor {
  border-color: rgba(74, 222, 128, 0.32);
  box-shadow: 0 0 16px rgba(74, 222, 128, 0.1);
}

.role-rule-chip.stalker {
  border-color: rgba(167, 139, 250, 0.36);
  box-shadow: 0 0 16px rgba(167, 139, 250, 0.12);
}

.role-rule-chip b {
  color: rgba(255, 245, 224, 0.84);
  font-size: 0.8rem;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.role-rule-chip em {
  color: #ffd28a;
  flex: 0 0 auto;
  font-style: normal;
  font-weight: 900;
}

.rule-status-list {
  display: grid;
  gap: 0.45rem;
  grid-template-columns: repeat(3, minmax(0, 1fr));
  margin: 0;
}

.rule-status-row {
  align-items: center;
  background: rgba(0, 0, 0, 0.18);
  border: 1px solid rgba(255, 255, 255, 0.06);
  border-radius: 9px;
  display: flex;
  gap: 0.55rem;
  justify-content: space-between;
  min-width: 0;
  padding: 0.5rem 0.58rem;
}

.rule-status-row dt {
  color: rgba(255, 245, 224, 0.66);
  font-size: 0.76rem;
  font-weight: 800;
}

.rule-status-row dd {
  border-radius: 999px;
  font-size: 0.72rem;
  font-weight: 900;
  margin: 0;
  padding: 0.2rem 0.45rem;
  white-space: nowrap;
}

.rule-status-row dd.allowed {
  background: rgba(34, 197, 94, 0.14);
  color: #86efac;
}

.rule-status-row dd.disabled {
  background: rgba(127, 29, 29, 0.2);
  color: #fca5a5;
}

.rule-status-row dd.public {
  background: rgba(255, 190, 85, 0.14);
  color: #ffd28a;
}

.rule-status-row dd.private {
  background: rgba(82, 82, 91, 0.28);
  color: rgba(255, 245, 224, 0.7);
}

.game-flow-timeline {
  display: grid;
  gap: 0;
  list-style: none;
  margin: 0;
  padding: 0;
}

.game-flow-timeline li {
  align-items: center;
  display: grid;
  gap: 0.72rem;
  grid-template-columns: 2.2rem minmax(0, 1fr) auto;
  min-width: 0;
  padding: 0.52rem 0;
  position: relative;
}

.game-flow-timeline li:not(:last-child)::after {
  background: linear-gradient(180deg, rgba(255, 190, 85, 0.42), transparent);
  bottom: -0.45rem;
  content: '';
  left: 1.1rem;
  position: absolute;
  top: 2.78rem;
  width: 1px;
}

.flow-icon {
  align-items: center;
  background:
    radial-gradient(circle at 50% 20%, rgba(255, 190, 85, 0.22), transparent 64%),
    rgba(0, 0, 0, 0.28);
  border: 1px solid rgba(255, 190, 85, 0.22);
  border-radius: 999px;
  display: inline-flex;
  height: 2.2rem;
  justify-content: center;
  width: 2.2rem;
}

.game-flow-timeline strong {
  color: #fff1d6;
  display: block;
  font-size: 0.95rem;
  font-weight: 900;
}

.game-flow-timeline em {
  color: #ffbe55;
  font-size: 1.02rem;
  font-style: normal;
  font-weight: 900;
}

.flow-summary {
  background: rgba(0, 0, 0, 0.18);
  border: 1px solid rgba(255, 190, 85, 0.1);
  border-radius: 9px;
  color: rgba(255, 245, 224, 0.6);
  font-size: 0.78rem;
  font-weight: 800;
  line-height: 1.4;
  margin: 0;
  padding: 0.62rem 0.7rem;
}

.players-section {
  background: rgba(0, 0, 0, 0.3);
  border: 1px solid rgba(255, 255, 255, 0.05);
  border-radius: 8px;
  padding: 1.5rem;
  position: relative;
  z-index: 1;
  box-shadow: inset 0 0 20px rgba(0, 0, 0, 0.5);
}

.invite-friend-list {
  display: grid;
  gap: 0.75rem;
  grid-template-columns: repeat(auto-fill, minmax(220px, 1fr));
  list-style: none;
  margin: 0;
  padding: 0;
}

.invite-friend-card {
  align-items: center;
  background: linear-gradient(
    135deg,
    rgba(40, 30, 25, 0.74),
    rgba(14, 8, 5, 0.9)
  );
  border: 1px solid rgba(255, 255, 255, 0.08);
  border-radius: 8px;
  display: flex;
  gap: 0.95rem;
  justify-content: space-between;
  min-width: 0;
  padding: 0.95rem;
}

.invite-friend-card div {
  display: grid;
  gap: 0.32rem;
  min-width: 0;
}

.invite-friend-card strong {
  color: #fff;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.invite-friend-card span,
.invite-empty {
  color: rgba(255, 245, 224, 0.52);
  font-size: 0.82rem;
}

.invite-friend-main {
  align-items: center;
  background: transparent;
  border: 0;
  color: inherit;
  cursor: pointer;
  display: grid;
  gap: 0.7rem;
  grid-template-columns: minmax(0, 1fr) auto;
  min-width: 0;
  font: inherit;
  font-weight: 900;
  padding: 0.85rem;
  text-align: left;
  width: 100%;
}

.invite-friend-main div {
  display: grid;
  gap: 0.32rem;
  min-width: 0;
}

.invite-friend-main strong {
  color: #fff;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.invite-friend-main span,
.invite-empty {
  color: rgba(255, 245, 224, 0.52);
  font-size: 0.82rem;
}

.invite-friend-main small {
  color: rgba(255, 245, 224, 0.7);
  font-size: 0.72rem;
  font-weight: 900;
  white-space: nowrap;
}

.invite-friend-main:hover:not(:disabled) {
  background: rgba(255, 190, 85, 0.08);
}

.invite-friend-main:disabled {
  cursor: not-allowed;
  opacity: 0.55;
}

.invite-friend-card.disabled {
  border-color: rgba(255, 255, 255, 0.05);
  opacity: 0.68;
}

.invite-friend-card.online .invite-friend-main small {
  color: #86efac;
}

.invite-modal-backdrop {
  align-items: center;
  background: rgba(0, 0, 0, 0.78);
  display: flex;
  inset: 0;
  justify-content: center;
  padding: 1.5rem;
  position: fixed;
  z-index: 85;
}

.invite-modal {
  max-width: 760px;
  width: min(100%, 760px);
}

.invite-modal.room-form-modal {
  background:
    linear-gradient(180deg, rgba(46, 28, 18, 0.98), rgba(18, 11, 8, 0.99)),
    rgba(18, 11, 8, 0.99);
  border: 1px solid rgba(255, 190, 85, 0.2);
  display: grid;
  gap: 0;
  left: auto;
  max-height: min(86vh, 760px);
  padding: 2.25rem 2.35rem 2.35rem;
  overflow-y: auto;
  position: relative;
  top: auto;
  transform: none;
  box-shadow:
    0 36px 100px rgba(0, 0, 0, 0.78),
    0 0 26px rgba(255, 143, 54, 0.16);
}

.invite-modal .edit-room-header {
  margin-bottom: 1.5rem;
}

.invite-modal.room-form-modal::after {
  background: rgba(0, 0, 0, 0.2);
  content: '';
  inset: 0;
  position: absolute;
  z-index: -1;
}

.invite-search-form {
  display: grid;
  gap: 0.85rem;
  margin-bottom: 0;
}

.invite-search-form label {
  color: rgba(255, 245, 224, 0.7);
  font-size: 0.84rem;
  font-weight: 800;
}

.invite-search-row {
  display: grid;
  gap: 0.75rem;
  grid-template-columns: minmax(0, 1fr) auto;
  margin-bottom: 0.875rem;
}

.invite-search-row input {
  background:
    linear-gradient(180deg, rgba(10, 6, 4, 0.92), rgba(22, 14, 10, 0.96)),
    rgba(10, 6, 4, 0.92);
  border: 1px solid rgba(255, 190, 85, 0.24);
  border-radius: 12px;
  box-shadow:
    inset 0 1px 0 rgba(255, 255, 255, 0.04),
    0 8px 18px rgba(0, 0, 0, 0.18);
  color: #fff4db;
  min-height: 48px;
  padding: 0.85rem 1rem;
}

.invite-search-row input::placeholder {
  color: rgba(255, 245, 224, 0.42);
}

.invite-search-row input:focus {
  background:
    linear-gradient(180deg, rgba(14, 8, 5, 0.98), rgba(24, 15, 10, 0.98)),
    rgba(14, 8, 5, 0.98);
  border-color: rgba(255, 190, 85, 0.62);
  box-shadow:
    0 0 0 3px rgba(255, 138, 0, 0.12),
    inset 0 1px 0 rgba(255, 255, 255, 0.04),
    0 10px 24px rgba(0, 0, 0, 0.22);
  outline: none;
}

.invite-search-row button {
  align-self: stretch;
  background: linear-gradient(180deg, #ffbe55, #c9711d);
  border: 1px solid rgba(255, 230, 160, 0.3);
  border-radius: 6px;
  color: #1a0f08;
  font-weight: 900;
  min-width: 88px;
  padding: 0.65rem 0.95rem;
}

.invite-search-row button:disabled {
  cursor: not-allowed;
  opacity: 0.48;
}

.invite-modal-meta {
  display: flex;
  flex-wrap: wrap;
  gap: 0.5rem;
  margin-bottom: 1.125rem;
}

.invite-modal-meta span {
  background: rgba(255, 255, 255, 0.05);
  border: 1px solid rgba(255, 190, 85, 0.14);
  border-radius: 999px;
  color: rgba(255, 245, 224, 0.68);
  font-size: 0.75rem;
  font-weight: 800;
  padding: 0.3rem 0.55rem;
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
  color: #ffd28a;
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

.players-heading {
  display: flex;
  justify-content: space-between;
  align-items: center;
  border-bottom: 1px solid rgba(255, 255, 255, 0.1);
  padding-bottom: 1rem;
  margin-bottom: 1.25rem;
}

.players-heading h2 {
  color: #fff;
  margin: 0;
  font-size: 1.25rem;
}

.sync-status {
  color: rgba(255, 245, 224, 0.4);
  font-size: 0.85rem;
}

.sync-status.ready-text {
  color: #ff8a00;
  font-weight: 900;
  animation: pulse 1s infinite;
}

.player-card-list {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
  gap: 1rem;
  list-style: none;
  padding: 0;
  margin: 0;
}

.player-card {
  display: flex;
  align-items: center;
  gap: 1rem;
  background: linear-gradient(
    135deg,
    rgba(40, 30, 25, 0.8),
    rgba(20, 15, 10, 0.9)
  );
  border: 1px solid rgba(255, 255, 255, 0.08);
  padding: 0.85rem;
  border-radius: 8px;
  box-shadow: 0 4px 12px rgba(0, 0, 0, 0.3);
  transition: all 0.2s ease;
}

.player-card:hover:not(.empty-slot) {
  transform: translateY(-2px);
  border-color: rgba(255, 120, 52, 0.3);
  box-shadow:
    0 8px 16px rgba(0, 0, 0, 0.4),
    0 0 12px rgba(255, 120, 52, 0.1);
}

.player-card.is-me {
  border-color: #ffbe55;
  background: linear-gradient(
    135deg,
    rgba(60, 40, 20, 0.9),
    rgba(20, 15, 10, 0.95)
  );
}

.player-card.disconnected {
  opacity: 0.58;
}

.player-card.disconnected .player-avatar {
  filter: grayscale(1);
}

.player-avatar-wrapper {
  position: relative;
  width: 48px;
  height: 48px;
  border-radius: 50%;
  border: 2px solid #555;
  overflow: hidden;
}

.player-avatar {
  width: 100%;
  height: 100%;
  object-fit: cover;
}

.player-level {
  position: absolute;
  bottom: -4px;
  left: 50%;
  transform: translateX(-50%);
  background: #ff8a00;
  color: #fff;
  font-size: 0.6rem;
  font-weight: 900;
  padding: 0.1rem 0.3rem;
  border-radius: 4px;
  white-space: nowrap;
}

.player-info {
  display: flex;
  flex-direction: column;
  flex: 1;
  min-width: 0;
}

.player-name-wrapper {
  display: flex;
  align-items: center;
  gap: 0.25rem;
}

.host-icon {
  font-size: 0.9rem;
}

.player-name {
  color: #fff;
  font-size: 1.1rem;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.player-title {
  color: rgba(255, 245, 224, 0.5);
  font-size: 0.75rem;
}

.player-badges {
  display: flex;
  gap: 0.5rem;
}

.ready-badge {
  background: rgba(0, 0, 0, 0.5);
  color: rgba(255, 255, 255, 0.3);
  border: 1px solid rgba(255, 255, 255, 0.1);
  padding: 0.4rem 0.6rem;
  border-radius: 4px;
  font-weight: 900;
  font-size: 0.7rem;
}

.ready-badge.active {
  background: rgba(34, 197, 94, 0.15);
  color: #86efac;
  border-color: rgba(34, 197, 94, 0.4);
  box-shadow: 0 0 10px rgba(34, 197, 94, 0.2);
}

.player-card.disconnected .ready-badge {
  background: rgba(148, 163, 184, 0.14);
  border-color: rgba(148, 163, 184, 0.28);
  color: rgba(226, 232, 240, 0.72);
}

.empty-slot {
  background: rgba(0, 0, 0, 0.2);
  border: 1px dashed rgba(255, 255, 255, 0.15);
  justify-content: center;
  opacity: 0.6;
  padding: 0;
}

.empty-slot-button {
  align-items: center;
  background: transparent;
  border: 0;
  color: inherit;
  cursor: pointer;
  display: flex;
  justify-content: center;
  padding: 0.85rem;
  width: 100%;
}

.empty-slot:hover {
  border-color: rgba(255, 190, 85, 0.32);
  box-shadow:
    0 8px 16px rgba(0, 0, 0, 0.4),
    0 0 12px rgba(255, 120, 52, 0.08);
}

.empty-slot-button:disabled {
  cursor: not-allowed;
}

.empty-slot-button:hover:not(:disabled) .empty-icon,
.empty-slot-button:focus-visible:not(:disabled) .empty-icon {
  color: #ffd28a;
}

.empty-slot-button:hover:not(:disabled) .empty-text,
.empty-slot-button:focus-visible:not(:disabled) .empty-text {
  color: rgba(255, 224, 168, 0.9);
}

.empty-slot-button .empty-content {
  pointer-events: none;
}

.empty-content {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 0.25rem;
}

.empty-icon {
  color: rgba(255, 255, 255, 0.3);
  font-weight: 900;
  letter-spacing: 0.05em;
}

.empty-text {
  color: rgba(255, 255, 255, 0.2);
  font-size: 0.8rem;
}

.room-chat-section {
  background: rgba(10, 5, 0, 0.8);
  border: 1px solid rgba(255, 120, 52, 0.2);
  border-radius: 8px;
  display: flex;
  flex-direction: column;
  height: 300px;
  position: relative;
  z-index: 1;
}

.chat-header {
  padding: 0.75rem 1rem;
  background: rgba(255, 120, 52, 0.1);
  border-bottom: 1px solid rgba(255, 120, 52, 0.2);
  color: #ffbe55;
  font-weight: 900;
  font-size: 0.9rem;
  border-top-left-radius: 8px;
  border-top-right-radius: 8px;
}

.chat-log {
  flex: 1;
  overflow-y: auto;
  padding: 1rem;
  display: flex;
  flex-direction: column;
  gap: 0.4rem;
}

.chat-message {
  font-size: 0.95rem;
  line-height: 1.4;
  word-break: break-all;
}

.chat-message.whisper {
  color: #f9a8d4;
}

.chat-time {
  color: rgba(255, 255, 255, 0.3);
  font-size: 0.75rem;
  margin-right: 0.4rem;
}

.chat-author {
  color: #93c5fd;
  margin-right: 0.4rem;
}
.chat-author.host {
  color: #ffd28a;
}
.chat-author.me {
  color: #86efac;
}

.whisper-label {
  display: inline-block;
  margin-right: 0.35rem;
  color: #f9a8d4;
  font-size: 0.72rem;
  font-weight: 900;
}

.chat-content {
  color: rgba(255, 245, 224, 0.9);
}

.chat-message.whisper .chat-content {
  color: #fbcfe8;
}

.system-message .chat-content.system {
  color: #fca5a5;
  font-weight: bold;
}

.chat-form {
  display: flex;
  padding: 0.75rem;
  gap: 0.5rem;
  background: rgba(0, 0, 0, 0.4);
  border-top: 1px solid rgba(255, 255, 255, 0.1);
  border-bottom-left-radius: 8px;
  border-bottom-right-radius: 8px;
}

.chat-form input {
  flex: 1;
  background: rgba(255, 255, 255, 0.05);
  border: 1px solid rgba(255, 255, 255, 0.1);
  color: #fff;
  padding: 0.6rem 0.8rem;
  border-radius: 4px;
  font-family: inherit;
}

.chat-form input:focus {
  outline: none;
  border-color: rgba(255, 120, 52, 0.4);
}

.chat-form button {
  background: #ffbe55;
  color: #000;
  border: none;
  padding: 0 1rem;
  font-weight: 900;
  border-radius: 4px;
  cursor: pointer;
  transition: background 0.2s;
}
.chat-form button:hover:not(:disabled) {
  background: #ff8a00;
}
.chat-form button:disabled {
  opacity: 0.5;
  cursor: not-allowed;
}

.edit-room-form {
  background:
    linear-gradient(135deg, rgba(60, 32, 18, 0.82), rgba(14, 8, 5, 0.96)),
    radial-gradient(circle at 15% 0%, rgba(255, 138, 0, 0.16), transparent 34%);
  border: 1px solid rgba(255, 138, 0, 0.28);
  border-radius: 10px;
  box-shadow:
    0 18px 36px rgba(0, 0, 0, 0.45),
    inset 0 0 24px rgba(255, 120, 52, 0.05);
  display: grid;
  gap: 1.35rem;
  padding: 2rem 2.1rem 2.15rem;
  position: relative;
  z-index: 1;
}

.edit-room-form.room-form-modal {
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
  box-shadow:
    0 32px 90px rgba(0, 0, 0, 0.62),
    0 0 26px rgba(255, 143, 54, 0.12);
  scrollbar-color: rgba(255, 190, 85, 0.5) rgba(20, 14, 11, 0.7);
  scrollbar-width: thin;
}

.edit-room-form.room-form-modal::after {
  background: rgba(0, 0, 0, 0.72);
  content: '';
  inset: 0;
  position: fixed;
  z-index: -1;
}

.edit-room-form.room-form-modal::-webkit-scrollbar {
  width: 0.62rem;
}

.edit-room-form.room-form-modal::-webkit-scrollbar-track {
  background: rgba(20, 14, 11, 0.72);
  border-radius: 999px;
}

.edit-room-form.room-form-modal::-webkit-scrollbar-thumb {
  background: linear-gradient(
    180deg,
    rgba(255, 190, 85, 0.74),
    rgba(201, 113, 29, 0.72)
  );
  border: 2px solid rgba(20, 14, 11, 0.72);
  border-radius: 999px;
}

.edit-room-form::before {
  background: linear-gradient(
    90deg,
    rgba(255, 190, 85, 0.75),
    rgba(229, 46, 113, 0)
  );
  content: '';
  height: 1px;
  left: 1.25rem;
  position: absolute;
  right: 1.25rem;
  top: 0;
}

.edit-room-header {
  align-items: flex-start;
  border-bottom: 1px solid rgba(255, 190, 85, 0.16);
  display: flex;
  justify-content: space-between;
  gap: 1.2rem;
  padding-bottom: 1.15rem;
}

.edit-room-header h2 {
  color: #fff;
  font-size: 1.3rem;
  margin: 0.15rem 0 0;
  text-shadow: 0 0 14px rgba(255, 138, 0, 0.24);
}

.password-input-shell {
  position: relative;
  width: 100%;
  max-width: 267px;
}

.password-input-shell .text-input {
  width: 100%;
  box-sizing: border-box;
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

.icon-close-btn {
  align-items: center;
  background: rgba(0, 0, 0, 0.42);
  border: 1px solid rgba(255, 190, 85, 0.24);
  border-radius: 6px;
  color: #ffbe55;
  cursor: pointer;
  display: inline-flex;
  font-weight: 900;
  height: 34px;
  justify-content: center;
  transition:
    transform 0.16s ease,
    border-color 0.16s ease,
    background 0.16s ease;
  width: 34px;
}

.icon-close-btn:hover:not(:disabled) {
  background: rgba(255, 120, 52, 0.12);
  border-color: rgba(255, 190, 85, 0.55);
  transform: translateY(-1px);
}

.edit-room-summary {
  display: flex;
  flex-wrap: wrap;
  gap: 0.7rem;
}

.edit-room-summary span {
  background: rgba(0, 0, 0, 0.36);
  border: 1px solid rgba(255, 255, 255, 0.08);
  border-radius: 4px;
  color: rgba(255, 245, 224, 0.75);
  font-size: 0.8rem;
  font-weight: 800;
  padding: 0.35rem 0.55rem;
}

.edit-room-form label {
  display: grid;
  gap: 0.65rem;
  font-weight: 800;
  color: rgba(255, 245, 224, 0.78);
  font-size: 0.9rem;
}

.edit-room-form input,
.edit-room-form textarea {
  background: rgba(7, 4, 2, 0.68);
  border: 1px solid rgba(255, 190, 85, 0.18);
  border-radius: 6px;
  color: #fff;
  font: inherit;
  min-height: 44px;
  padding: 0.75rem 0.9rem;
  transition:
    border-color 0.18s ease,
    box-shadow 0.18s ease,
    background 0.18s ease;
}

.edit-room-form .room-title-input {
  box-sizing: border-box;
  width: 100%;
}

.edit-room-form input:focus,
.edit-room-form textarea:focus {
  background: rgba(12, 7, 4, 0.82);
  border-color: rgba(255, 190, 85, 0.56);
  box-shadow: 0 0 0 3px rgba(255, 138, 0, 0.12);
  outline: none;
}

.option-group {
  display: grid;
  gap: 0.85rem;
  grid-template-columns: repeat(3, minmax(0, 1fr));
}

.room-custom-grid {
  display: grid;
  gap: 1.15rem;
  grid-template-columns: repeat(2, minmax(0, 1fr));
}

.mode-description,
.classic-rules-note {
  color: rgba(255, 245, 224, 0.64);
  font-size: 0.82rem;
  line-height: 1.55;
  margin: 0;
}

.mode-description {
  margin-top: 0.55rem;
}

.classic-rules-note {
  background: rgba(255, 190, 85, 0.05);
  border: 1px solid rgba(255, 190, 85, 0.14);
  border-radius: 0.7rem;
  padding: 0.85rem 1rem;
}

.option-btn:disabled {
  cursor: not-allowed;
  opacity: 0.52;
}

.advanced-settings-panel {
  background:
    linear-gradient(135deg, rgba(60, 32, 18, 0.3), rgba(14, 8, 5, 0.72)),
    rgba(14, 8, 5, 0.66);
  border: 1px solid rgba(255, 138, 0, 0.18);
  border-radius: 0.8rem;
  display: grid;
  gap: 1rem;
  padding: 1rem;
}

.advanced-settings-toggle {
  align-items: center;
  background: rgba(0, 0, 0, 0.28);
  border: 1px solid rgba(255, 190, 85, 0.18);
  border-radius: 0.6rem;
  color: #ffd28a;
  cursor: pointer;
  display: flex;
  font: inherit;
  font-weight: 900;
  justify-content: space-between;
  min-height: 2.65rem;
  padding: 0.65rem 0.85rem;
}

.advanced-settings-toggle.active {
  background: linear-gradient(
    180deg,
    rgba(255, 138, 0, 0.18),
    rgba(229, 46, 113, 0.12)
  );
  border-color: rgba(255, 190, 85, 0.34);
}

.advanced-settings-toggle:hover {
  background: rgba(255, 138, 0, 0.1);
  border-color: rgba(255, 190, 85, 0.34);
}

.advanced-settings-toggle strong {
  color: #fff1d6;
}

.advanced-settings-grid {
  display: grid;
  gap: 0.85rem;
  grid-template-columns: repeat(2, minmax(0, 1fr));
}

.game-styled-form select {
  background: rgba(12, 8, 6, 0.78);
  border: 1px solid rgba(255, 190, 85, 0.22);
  border-radius: 0.65rem;
  color: #fff1d6;
  font: inherit;
  min-height: 2.75rem;
  padding: 0.65rem 0.8rem;
  width: 100%;
}

.option-btn {
  background: rgba(0, 0, 0, 0.34);
  border: 1px solid rgba(255, 255, 255, 0.09);
  border-radius: 6px;
  color: rgba(255, 245, 224, 0.62);
  cursor: pointer;
  font: inherit;
  font-weight: 900;
  min-height: 44px;
  padding: 0.7rem 0.8rem;
  transition:
    transform 0.16s ease,
    border-color 0.16s ease,
    color 0.16s ease,
    background 0.16s ease;
}

.option-btn:hover {
  background: rgba(255, 138, 0, 0.1);
  border-color: rgba(255, 190, 85, 0.38);
  color: #fff;
  transform: translateY(-1px);
}

.option-btn.active {
  background: linear-gradient(
    180deg,
    rgba(255, 138, 0, 0.24),
    rgba(229, 46, 113, 0.16)
  );
  border-color: rgba(255, 190, 85, 0.7);
  box-shadow:
    0 0 16px rgba(255, 138, 0, 0.16),
    inset 0 0 12px rgba(255, 255, 255, 0.04);
  color: #ffdf9e;
}

.friendly-player-control {
  background:
    linear-gradient(180deg, rgba(255, 190, 85, 0.06), rgba(12, 7, 4, 0.34)),
    rgba(9, 5, 3, 0.58);
  border: 1px solid rgba(255, 190, 85, 0.14);
  border-radius: 0.75rem;
  display: grid;
  gap: 0.8rem;
  padding: 1rem;
}

.friendly-stepper {
  align-items: center;
  display: grid;
  gap: 0.55rem;
  grid-template-columns: 2.35rem minmax(4rem, 1fr) 2.35rem;
}

.friendly-stepper strong {
  color: #ffd28a;
  font-size: 1.08rem;
  font-weight: 900;
  text-align: center;
}

.stepper-btn {
  align-self: center;
  background: rgba(0, 0, 0, 0.34);
  border: 1px solid rgba(255, 190, 85, 0.28);
  border-radius: 0.45rem;
  color: #ffd28a;
  cursor: pointer;
  font-size: 1.15rem;
  font-weight: 900;
  min-height: 2.2rem;
  padding: 0;
}

.stepper-btn:disabled {
  cursor: not-allowed;
  opacity: 0.38;
}

.player-range {
  accent-color: #f59e0b;
  cursor: pointer;
  min-height: auto;
  padding: 0;
}

.range-labels {
  color: rgba(255, 245, 224, 0.5);
  display: flex;
  font-size: 0.78rem;
  font-weight: 800;
  justify-content: space-between;
}

.role-config-section {
  background:
    linear-gradient(135deg, rgba(60, 32, 18, 0.48), rgba(14, 8, 5, 0.76)),
    radial-gradient(circle at 12% 0%, rgba(255, 138, 0, 0.09), transparent 38%),
    rgba(14, 8, 5, 0.74);
  border: 1px solid rgba(255, 138, 0, 0.22);
  border-radius: 0.75rem;
  display: grid;
  gap: 1rem;
  padding: 1.05rem;
}

.role-config-section.invalid {
  border-color: rgba(248, 113, 113, 0.5);
  box-shadow: 0 0 18px rgba(248, 113, 113, 0.1);
}

.role-config-section.locked {
  background:
    linear-gradient(135deg, rgba(49, 28, 18, 0.42), rgba(14, 8, 5, 0.8)),
    radial-gradient(circle at 12% 0%, rgba(255, 138, 0, 0.06), transparent 38%),
    rgba(14, 8, 5, 0.78);
}

.role-config-header {
  align-items: center;
  border-bottom: 1px solid rgba(255, 190, 85, 0.1);
  display: flex;
  gap: 0.95rem;
  justify-content: space-between;
  padding-bottom: 0.85rem;
}

.role-config-header h3 {
  color: #fff;
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
  gap: 0.75rem;
  grid-template-columns: repeat(2, minmax(0, 1fr));
}

.role-config-row {
  align-items: center;
  background: rgba(255, 255, 255, 0.045);
  border: 1px solid rgba(255, 190, 85, 0.1);
  border-radius: 0.6rem;
  display: flex;
  gap: 0.75rem;
  justify-content: space-between;
  min-width: 0;
  padding: 0.75rem 0.8rem;
}

.role-config-row > span {
  color: #fff;
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
  border-radius: 0.45rem;
  color: #ffd28a;
  cursor: pointer;
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
  margin: 0 0 0.18rem;
  padding: 0.08rem 0.1rem 0.25rem;
}

.role-config-help {
  color: rgba(255, 245, 224, 0.6);
}

.role-config-warning {
  color: #fca5a5;
}

.edit-actions {
  display: flex;
  justify-content: flex-end;
  gap: 0.6rem;
  padding-top: 0.65rem;
}

.edit-actions button {
  padding: 0.8rem 1.25rem;
  border-radius: 6px;
  font-weight: 900;
  border: 1px solid transparent;
  cursor: pointer;
  min-width: 112px;
  transition:
    transform 0.16s ease,
    filter 0.16s ease,
    box-shadow 0.16s ease;
}
.edit-actions button[type='submit'] {
  background: linear-gradient(180deg, #ffbe55, #c9711d);
  box-shadow:
    0 8px 18px rgba(201, 113, 29, 0.2),
    inset 0 1px rgba(255, 255, 255, 0.35);
  color: #1a0f08;
}
.edit-actions button[type='button'] {
  background: rgba(0, 0, 0, 0.32);
  border-color: rgba(255, 255, 255, 0.1);
  color: rgba(255, 245, 224, 0.68);
}

.edit-actions button:hover:not(:disabled) {
  filter: brightness(1.08);
  transform: translateY(-1px);
}

.edit-actions button:disabled,
.icon-close-btn:disabled {
  cursor: not-allowed;
  opacity: 0.5;
}

@media (max-width: 1100px) {
  .room-rules-grid {
    grid-template-columns: 1fr;
  }

  .game-board-panel {
    grid-template-columns: 1fr 1fr;
  }

  .game-phase-card {
    grid-column: 1 / -1;
    order: -1;
  }
}

@media (max-width: 760px) {
  .room-heading {
    flex-direction: column;
  }
  .room-control-panel {
    max-width: none;
    min-width: 0;
    width: 100%;
  }
  .room-actions {
    flex-direction: row;
    flex-wrap: wrap;
  }
  .action-btn {
    flex: 1;
    text-align: center;
  }

  .role-config-list,
  .room-custom-grid {
    grid-template-columns: 1fr;
  }

  .advanced-settings-grid {
    grid-template-columns: 1fr;
  }

  .room-rules-grid {
    grid-template-columns: 1fr;
    padding: 1rem;
  }

  .game-started-panel {
    align-items: flex-start;
    flex-direction: column;
  }

  .game-started-panel > span {
    text-align: left;
  }

  .game-board-panel,
  .game-action-box > div {
    grid-template-columns: 1fr;
  }

  .briefing-hero {
    grid-template-columns: 1fr;
  }

  .rule-status-list {
    grid-template-columns: repeat(2, minmax(0, 1fr));
  }

  .game-flow-timeline li {
    grid-template-columns: 2.45rem minmax(0, 1fr);
  }

  .game-flow-timeline em {
    grid-column: 2;
    font-size: 1rem;
  }
}

@media (max-width: 480px) {
  .room-rules-toggle small {
    display: none;
  }

  .rule-status-list {
    grid-template-columns: 1fr;
  }

  .briefing-hero > div,
  .rule-status-row {
    align-items: flex-start;
    flex-direction: column;
  }
}
</style>
