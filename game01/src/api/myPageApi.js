import { createSupabaseError, logSupabaseError, supabase } from './supabaseClient'

const DEFAULT_QUOTE = '오늘은 어떤 게임을 즐겨볼까요?'
const DEFAULT_PLAYER_TITLE = 'Rookie Player'
const MAFIA_GAME = {
  type: 'mafia',
  icon: '🎭',
  name: '마피아 게임',
  description: '역할 추리 게임에서 쌓은 기록입니다.',
}

function normalizeDefaultPlayerTitle(value) {
  return value && value !== 'Rookie Mafia' ? value : DEFAULT_PLAYER_TITLE
}

function createOverviewStats(stats = {}) {
  return [
    { label: '총 플레이', value: String(stats.total_games ?? 0) },
    { label: '전체 승률', value: toPercent(stats.overall_win_rate) },
  ]
}

function createMafiaStats(stats = {}) {
  return [
    { label: '시민 승률', value: toPercent(stats.citizen_win_rate) },
    { label: '마피아 승률', value: toPercent(stats.mafia_win_rate) },
    { label: '생존률', value: toPercent(stats.survival_rate) },
    { label: '평균 생존 턴', value: String(stats.average_survival_turn ?? 0) },
  ]
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

function createMafiaGameRecord(stats, roleRecords) {
  return {
    ...MAFIA_GAME,
    stats: createMafiaStats(stats),
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
    gameRecords: [createMafiaGameRecord({}, roleRecords)],
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
  const roleRecords =
    rows.roles?.length > 0
      ? rows.roles.map((role) => ({
          role: role.role_name,
          games: role.games_played ?? 0,
          winRate: role.win_rate ?? 0,
          icon: role.icon || role.role_name?.slice(0, 1) || '?',
          featured: role.is_most_played,
        }))
      : empty.gameRecords[0].roleRecords

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
    gameRecords: [createMafiaGameRecord(statsRow, roleRecords)],
    recentMatches:
      rows.matches?.length > 0
        ? rows.matches.map((match) => ({
            id: match.id,
            result: match.won ? '승리' : '패배',
            gameType: MAFIA_GAME.type,
            gameName: MAFIA_GAME.name,
            gameIcon: MAFIA_GAME.icon,
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
    const [profile, stats, roles, matches, achievements, cosmetics] = await Promise.all([
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
          .from('player_role_stats')
          .select('user_id, role_name, icon, games_played, win_rate, is_most_played')
          .eq('user_id', user.id)
          .order('games_played', { ascending: false }),
      ),
      selectMaybe(
        supabase
          .from('player_recent_matches')
          .select('id, user_id, role_name, role_icon, won, summary, detail, played_at')
          .eq('user_id', user.id)
          .order('played_at', { ascending: false })
          .limit(5),
      ),
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
      roles,
      matches,
      achievements,
      cosmetics,
    })
  } catch (error) {
    console.error('[Supabase] getMyPageData: failed to load my page bundle', error)
    return getEmptyMyPage(user)
  }
}
