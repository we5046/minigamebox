import { defineStore } from 'pinia'
import { ref } from 'vue'
import { supabase } from '@/api/supabaseClient'
import { getProfile, toCurrentUser } from '@/api/authApi'
import {
  getMyPageData,
  updateMyPageProfile,
  upsertMyPageCosmetic,
} from '@/api/myPageApi'
import { useAuthStore } from '@/stores/auth'

function createDefaultProfile() {
  return {
    id: null,
    loginId: 'guest',
    nickname: 'GuestPlayer',
    characterName: 'Rookie Mafia',
    title: 'Rookie Mafia',
    avatar: 'default-mafia',
    level: 1,
    coin: 0,
    exp: 0,
    expPercent: 0,
    winRate: '0%',
    winRateValue: 0,
    winStreak: 0,
    quote: '오늘 밤 누가 거짓말을 하고 있을까?',
    representativeTitle: '',
  }
}

function createDefaultStats() {
  return [
    { label: '총 플레이', value: '0' },
    { label: '전체 승률', value: '0%' },
    { label: '시민 승률', value: '0%' },
    { label: '마피아 승률', value: '0%' },
    { label: '생존율', value: '0%' },
    { label: '평균 생존 턴', value: '0' },
  ]
}

function normalizeProfileDisplay(bundle, authProfile = null) {
  const profile = bundle?.profile || {}
  const stats = bundle?.stats || {}

  const winRateValue = Number(stats.overall_win_rate || 0)
  const winRate = `${Math.round(winRateValue)}%`

  return {
    id: profile.id || authProfile?.id || null,
    loginId: profile.login_id || authProfile?.login_id || 'guest',
    nickname: profile.nickname || authProfile?.nickname || 'GuestPlayer',
    characterName:
      profile.character_name || authProfile?.character_name || 'Rookie Mafia',
    title:
      profile.representative_title ||
      profile.character_name ||
      authProfile?.representative_title ||
      authProfile?.character_name ||
      'Rookie Mafia',
    representativeTitle: profile.representative_title || '',
    avatar: profile.avatar || authProfile?.avatar || 'default-mafia',
    level: profile.level ?? authProfile?.level ?? 1,
    coin: profile.coin ?? authProfile?.coin ?? 0,
    exp: profile.experience_percent ?? authProfile?.experience_percent ?? 0,
    expPercent: profile.experience_percent ?? authProfile?.experience_percent ?? 0,
    winRate,
    winRateValue,
    winStreak: bundle?.winStreak || 0,
    quote:
      profile.profile_quote ||
      authProfile?.profile_quote ||
      '오늘 밤 누가 거짓말을 하고 있을까?',
  }
}

function createDefaultBundle() {
  return {
    profile: createDefaultProfile(),
    stats: createDefaultStats(),
    roleRecords: [],
    recentMatches: [],
    achievements: [],
    cosmetics: [],
  }
}

function buildAuthSyncProfile(rawProfile, rawStats) {
  return toCurrentUser({
    ...rawProfile,
    stats: rawStats || null,
  })
}

let profileSubscription = null
let currentUserId = null
let refreshTimer = null

export const useProfileStore = defineStore('profile', () => {
  const profile = ref(createDefaultProfile())
  const stats = ref(createDefaultStats())
  const roleRecords = ref([])
  const recentMatches = ref([])
  const achievements = ref([])
  const cosmetics = ref([])
  const isLoading = ref(false)
  const isInitialized = ref(false)

  function clearRefreshTimer() {
    if (refreshTimer) {
      clearTimeout(refreshTimer)
      refreshTimer = null
    }
  }

  function unsubscribeFromProfileChanges() {
    if (!profileSubscription) {
      return
    }

    const channel = profileSubscription
    profileSubscription = null
    supabase.removeChannel(channel)
  }

  function setProfileBundle(displayData, authProfile = null) {
    const nextProfile = normalizeProfileDisplay(displayData, authProfile)

    profile.value = nextProfile
    stats.value = displayData?.stats || createDefaultStats()
    roleRecords.value = displayData?.roleRecords || []
    recentMatches.value = displayData?.recentMatches || []
    achievements.value = displayData?.achievements || []
    cosmetics.value = displayData?.cosmetics || []

    const authStore = useAuthStore()
    if (authProfile) {
      authStore.setUser(buildAuthSyncProfile(authProfile, authProfile.stats))
    } else if (nextProfile.id) {
      authStore.setUser({
        id: nextProfile.id,
        loginId: nextProfile.loginId,
        nickname: nextProfile.nickname,
        representativeTitle: nextProfile.representativeTitle,
        quote: nextProfile.quote,
        experiencePercent: nextProfile.exp,
        stats: {
          totalGames: 0,
          winRate: nextProfile.winRateValue,
          citizenWinRate: 0,
          mafiaWinRate: 0,
          survivalRate: 0,
          averageSurvivalTurn: 0,
        },
        character: {
          name: nextProfile.characterName,
          level: nextProfile.level,
          coin: nextProfile.coin,
          avatar: nextProfile.avatar,
        },
      })
    }
  }

  function subscribeToProfileChanges(userId) {
    unsubscribeFromProfileChanges()

    if (!userId) {
      return
    }

    profileSubscription = supabase
      .channel(`profile-${userId}`)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'profiles', filter: `id=eq.${userId}` }, queueRefresh)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'player_stats', filter: `user_id=eq.${userId}` }, queueRefresh)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'player_role_stats', filter: `user_id=eq.${userId}` }, queueRefresh)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'player_recent_matches', filter: `user_id=eq.${userId}` }, queueRefresh)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'player_achievements', filter: `user_id=eq.${userId}` }, queueRefresh)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'player_cosmetics', filter: `user_id=eq.${userId}` }, queueRefresh)
      .subscribe()
  }

  function queueRefresh() {
    clearRefreshTimer()
    refreshTimer = setTimeout(() => {
      refreshTimer = null
      if (currentUserId) {
        reloadProfile(currentUserId)
      }
    }, 120)
  }

  async function reloadProfile(userId = currentUserId) {
    currentUserId = userId || null

    if (!currentUserId) {
      resetProfile()
      isInitialized.value = true
      return createDefaultBundle()
    }

    isLoading.value = true
    subscribeToProfileChanges(currentUserId)

    try {
      const [authProfile, pageData] = await Promise.all([
        getProfile(currentUserId),
        getMyPageData({ id: currentUserId }),
      ])

      setProfileBundle(pageData, authProfile)
      isInitialized.value = true
      return pageData
    } finally {
      isLoading.value = false
    }
  }

  function resetProfile() {
    clearRefreshTimer()
    unsubscribeFromProfileChanges()
    currentUserId = null
    profile.value = createDefaultProfile()
    stats.value = createDefaultStats()
    roleRecords.value = []
    recentMatches.value = []
    achievements.value = []
    cosmetics.value = []
    isLoading.value = false
    isInitialized.value = false
  }

  async function updateProfileFields(payload) {
    if (!currentUserId) {
      throw new Error('프로필을 불러올 수 없습니다.')
    }

    const nextProfile = await updateMyPageProfile(currentUserId, payload)
    await reloadProfile(currentUserId)
    return nextProfile
  }

  async function updateCosmetic(label, value, sortOrder) {
    if (!currentUserId) {
      throw new Error('프로필을 불러올 수 없습니다.')
    }

    await upsertMyPageCosmetic(currentUserId, label, value, sortOrder)
    await reloadProfile(currentUserId)
  }

  function setCurrentUserId(userId) {
    currentUserId = userId || null
  }

  return {
    profile,
    stats,
    roleRecords,
    recentMatches,
    achievements,
    cosmetics,
    isLoading,
    isInitialized,
    reloadProfile,
    resetProfile,
    setCurrentUserId,
    updateProfileFields,
    updateCosmetic,
  }
})
