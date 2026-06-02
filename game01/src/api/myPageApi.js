import { createSupabaseError, logSupabaseError, supabase } from './supabaseClient'

const DEFAULT_QUOTE = '오늘은 어떤 게임을 즐겨볼까요?'
const DEFAULT_PLAYER_TITLE = 'Rookie Player'
const GAME_CATALOG = {
  mafia: {
    type: 'mafia',
    icon: '🎭',
    name: '마피아 게임',
    description: '역할 추리 게임에서 쌓은 기록입니다.',
  },
  catchmind: {
    type: 'catchmind',
    icon: '🎨',
    name: '캐치마인드',
    description: '그림 퀴즈 게임에서 쌓은 기록입니다.',
  },
  liar: {
    type: 'liar',
    icon: '🤥',
    name: '라이어 게임',
    description: '라이어 게임에서 쌓은 기록입니다.',
  },
}
const DEFAULT_GAME_TYPE = 'mafia'

function normalizeDefaultPlayerTitle(value) {
  return value && value !== 'Rookie Mafia' ? value : DEFAULT_PLAYER_TITLE
}

function createOverviewStats(stats = {}) {
  return [
    { label: '총 플레이', value: String(stats.total_games ?? 0) },
    { label: '전체 승률', value: toPercent(stats.overall_win_rate) },
  ]
}

function getGameDefinition(gameType) {
  return (
    GAME_CATALOG[gameType] || {
      type: gameType,
      icon: '🎮',
      name: gameType,
      description: '이 게임에서 쌓은 기록입니다.',
    }
  )
}

function createDefaultMafiaRoleRecords() {
  return [
    { role: '시민', games: 0, winRate: 0, icon: 'C', featured: false },
    { role: '마피아', games: 0, winRate: 0, icon: 'M', featured: false },
    { role: '경찰', games: 0, winRate: 0, icon: 'P', featured: false },
    { role: '의사', games: 0, winRate: 0, icon: 'D', featured: false },
    { role: '스토커', games: 0, winRate: 0, icon: 'S', featured: false },
  ]
}

function createGameStats(gameType, stats = {}) {
  const result = [
    { label: '플레이', value: String(stats.total_games ?? 0) },
    { label: '승률', value: toPercent(stats.win_rate ?? stats.overall_win_rate) },
  ]

  if (gameType === 'mafia') {
    result.push(
      { label: '시민 승률', value: toPercent(stats.citizen_win_rate) },
      { label: '마피아 승률', value: toPercent(stats.mafia_win_rate) },
      { label: '생존률', value: toPercent(stats.survival_rate) },
      {
        label: '평균 플레이 라운드',
        value: String(stats.average_played_rounds ?? stats.average_survival_turn ?? 0),
      },
    )
  }

  return result
}

function normalizeRoleRecords(roles = []) {
  return roles.map((role) => ({
    role: role.role_name,
    games: role.games_played ?? 0,
    winRate: role.win_rate ?? 0,
    icon: role.icon || role.role_name?.slice(0, 1) || '?',
    featured: role.is_most_played,
  }))
}

function createGameRecord(gameType, stats, roleRecords) {
  return {
    ...getGameDefinition(gameType),
    stats: createGameStats(gameType, stats),
    roleRecords,
  }
}

function getEmptyMyPage(user) {
  const roleRecords = createDefaultMafiaRoleRecords()

  return {
    profile: {
      nickname: user?.nickname || 'GuestPlayer',
      loginId: user?.loginId || 'guest',
      level: user?.character?.level || 1,
      title: normalizeDefaultPlayerTitle(user?.character?.name),
      characterName: normalizeDefaultPlayerTitle(user?.character?.name),
      representativeTitle: user?.representativeTitle || '',
      avatar: user?.character?.avatar || 'default-mafia',
      coin: user?.character?.coin || 0,
      exp: 0,
      status: user ? 'Online' : 'Guest',
      quote: DEFAULT_QUOTE,
    },
    stats: createOverviewStats(),
    gameRecords: [createGameRecord(DEFAULT_GAME_TYPE, {}, roleRecords)],
    recentMatches: [],
    achievements: [],
    cosmetics: [
      { label: '프로필 테두리', value: '기본 테두리' },
      { label: '배경 스킨', value: '기본 배경' },
      { label: '채팅 말풍선', value: '기본 말풍선' },
      { label: '닉네임 색상', value: '기본 색상' },
    ],
  }
}

function toPercent(value) {
  return `${Math.round(Number(value || 0))}%`
}

function toDateLabel(value) {
  if (!value) {
    return '잠김'
  }

  return value
}

function normalizeMyPageData(user, rows) {
  const empty = getEmptyMyPage(user)
  const profileRow = rows.profile
  const statsRow = rows.stats
  const fallbackRoleRecords =
    rows.roles?.length > 0
      ? normalizeRoleRecords(rows.roles)
      : empty.gameRecords[0].roleRecords
  const gameStats = rows.gameStats || []
  const gameRoles = rows.gameRoles || []
  const gameTypes = new Set([
    DEFAULT_GAME_TYPE,
    ...gameStats.map((stats) => stats.game_type),
    ...gameRoles.map((role) => role.game_type),
  ])
  const gameRecords = [...gameTypes].map((gameType) => {
    const scopedStats =
      gameStats.find((stats) => stats.game_type === gameType) ||
      (gameType === DEFAULT_GAME_TYPE ? statsRow : {})
    const scopedRoles = normalizeRoleRecords(
      gameRoles.filter((role) => role.game_type === gameType),
    )

    return createGameRecord(
      gameType,
      scopedStats,
      scopedRoles.length > 0 || gameType !== DEFAULT_GAME_TYPE
        ? scopedRoles
        : fallbackRoleRecords,
    )
  })

  return {
    profile: {
      ...empty.profile,
      nickname: profileRow?.nickname || empty.profile.nickname,
      loginId: profileRow?.login_id || empty.profile.loginId,
      level: profileRow?.level ?? empty.profile.level,
      title:
        profileRow?.representative_title ||
        normalizeDefaultPlayerTitle(profileRow?.character_name),
      characterName: normalizeDefaultPlayerTitle(profileRow?.character_name),
      representativeTitle:
        profileRow?.representative_title || empty.profile.representativeTitle,
      avatar: profileRow?.avatar || empty.profile.avatar,
      coin: profileRow?.coin ?? empty.profile.coin,
      exp: profileRow?.experience_percent ?? empty.profile.exp,
      quote: profileRow?.profile_quote || empty.profile.quote,
    },
    stats: createOverviewStats(statsRow),
    gameRecords,
    recentMatches:
      rows.matches?.length > 0
        ? rows.matches.map((match) => ({
            id: match.id,
            result: match.won ? '승리' : '패배',
            gameType: match.game_type || DEFAULT_GAME_TYPE,
            gameName: getGameDefinition(match.game_type || DEFAULT_GAME_TYPE).name,
            gameIcon: getGameDefinition(match.game_type || DEFAULT_GAME_TYPE).icon,
            role: match.role_name,
            icon: match.role_icon || match.role_name?.slice(0, 1) || '?',
            summary: match.summary,
            detail: match.detail,
            won: match.won,
          }))
        : empty.recentMatches,
    achievements:
      rows.achievements?.length > 0
        ? rows.achievements.map((item) => ({
            name: item.name,
            icon: item.icon,
            rarity: item.rarity,
            unlocked: item.unlocked,
            date: toDateLabel(item.unlocked_at),
            description: item.description,
          }))
        : empty.achievements,
    cosmetics:
      rows.cosmetics?.length > 0
        ? rows.cosmetics.map((item) => ({
            label: item.label,
            value: item.value,
          }))
        : empty.cosmetics,
  }
}

async function selectMaybe(query) {
  const { data, error } = await query

  if (error) {
    logSupabaseError('myPageApi: optional select failed', error)
    return null
  }

  return data
}

async function selectRecentMatches(userId) {
  const extendedMatches = await selectMaybe(
    supabase
      .from('player_recent_matches')
      .select('id, user_id, game_id, game_type, role_name, role_icon, won, summary, detail, played_at')
      .eq('user_id', userId)
      .order('played_at', { ascending: false })
      .limit(5),
  )

  if (extendedMatches !== null) {
    return extendedMatches
  }

  return selectMaybe(
    supabase
      .from('player_recent_matches')
      .select('id, user_id, role_name, role_icon, won, summary, detail, played_at')
      .eq('user_id', userId)
      .order('played_at', { ascending: false })
      .limit(5),
  )
}

function normalizeProfileUpdatePayload(payload) {
  const profilePayload = {}

  if (Object.prototype.hasOwnProperty.call(payload, 'nickname')) {
    profilePayload.nickname = payload.nickname.trim()
  }

  if (Object.prototype.hasOwnProperty.call(payload, 'representativeTitle')) {
    profilePayload.representative_title = payload.representativeTitle.trim()
  }

  if (Object.prototype.hasOwnProperty.call(payload, 'characterName')) {
    profilePayload.character_name = payload.characterName.trim()
  }

  if (Object.prototype.hasOwnProperty.call(payload, 'quote')) {
    profilePayload.profile_quote = payload.quote.trim()
  }

  if (Object.prototype.hasOwnProperty.call(payload, 'avatar')) {
    profilePayload.avatar = payload.avatar.trim()
  }

  return profilePayload
}

export async function updateMyPageProfile(userId, payload) {
  const profilePayload = normalizeProfileUpdatePayload(payload)

  if (Object.keys(profilePayload).length === 0) {
    return null
  }

  const { error } = await supabase.from('profiles').update(profilePayload).eq('id', userId)

  if (error) {
    throw createSupabaseError('updateMyPageProfile: profiles update failed', error, '프로필 저장에 실패했습니다.')
  }

  return selectMaybe(supabase.from('profiles').select('*').eq('id', userId).maybeSingle())
}

export async function upsertMyPageCosmetic(userId, label, value, sortOrder = 0) {
  const { error } = await supabase.from('player_cosmetics').upsert(
    {
      user_id: userId,
      label,
      value,
      sort_order: sortOrder,
    },
    {
      onConflict: 'user_id,label',
    },
  )

  if (error) {
    throw createSupabaseError('upsertMyPageCosmetic: player_cosmetics upsert failed', error, '꾸미기 정보를 저장하지 못했습니다.')
  }
}

export async function getMyPageData(user) {
  if (!user?.id) {
    return getEmptyMyPage(user)
  }

  try {
    const [
      profile,
      stats,
      gameStats,
      roles,
      gameRoles,
      matches,
      achievements,
      cosmetics,
    ] = await Promise.all([
      selectMaybe(
        supabase
          .from('profiles')
          .select('id, login_id, nickname, character_name, level, coin, avatar, representative_title, profile_quote, experience_percent')
          .eq('id', user.id)
          .maybeSingle(),
      ),
      selectMaybe(
        supabase
          .from('player_stats')
          .select('user_id, total_games, overall_win_rate, citizen_win_rate, mafia_win_rate, survival_rate, average_survival_turn')
          .eq('user_id', user.id)
          .maybeSingle(),
      ),
      selectMaybe(
        supabase
          .from('player_game_stats')
          .select('user_id, game_type, total_games, win_rate, citizen_win_rate, mafia_win_rate, survival_rate, average_played_rounds')
          .eq('user_id', user.id)
          .order('game_type', { ascending: true }),
      ),
      selectMaybe(
        supabase
          .from('player_role_stats')
          .select('user_id, role_name, icon, games_played, win_rate, is_most_played')
          .eq('user_id', user.id)
          .order('games_played', { ascending: false }),
      ),
      selectMaybe(
        supabase
          .from('player_game_role_stats')
          .select('user_id, game_type, role_key, role_name, icon, games_played, win_rate, is_most_played')
          .eq('user_id', user.id)
          .order('games_played', { ascending: false }),
      ),
      selectRecentMatches(user.id),
      selectMaybe(
        supabase
          .from('player_achievements')
          .select('id, user_id, name, icon, rarity, unlocked, unlocked_at, description')
          .eq('user_id', user.id)
          .order('unlocked_at', { ascending: false }),
      ),
      selectMaybe(
        supabase
          .from('player_cosmetics')
          .select('id, user_id, label, value, sort_order')
          .eq('user_id', user.id)
          .order('sort_order', { ascending: true }),
      ),
    ])

    return normalizeMyPageData(user, {
      profile,
      stats,
      gameStats,
      roles,
      gameRoles,
      matches,
      achievements,
      cosmetics,
    })
  } catch (error) {
    console.error('[Supabase] getMyPageData: failed to load my page bundle', error)
    return getEmptyMyPage(user)
  }
}
