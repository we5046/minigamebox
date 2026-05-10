import { supabase } from './supabaseClient'

const DEFAULT_QUOTE = '오늘 밤, 진실은 침묵하는 사람의 눈빛에 숨어 있다.'

function getEmptyMyPage(user) {
  return {
    profile: {
      nickname: user?.nickname || 'GuestPlayer',
      loginId: user?.loginId || 'guest',
      level: user?.character?.level || 1,
      title: user?.character?.name || 'Rookie Mafia',
      coin: user?.character?.coin || 0,
      exp: 0,
      status: user ? 'Online' : 'Guest',
      quote: DEFAULT_QUOTE,
    },
    rank: {
      tier: 'Unranked',
      rp: 0,
      topPercent: '-',
      emblem: '-',
    },
    stats: [
      { label: '총 플레이', value: '0' },
      { label: '전체 승률', value: '0%' },
      { label: '시민 승률', value: '0%' },
      { label: '마피아 승률', value: '0%' },
      { label: '생존률', value: '0%' },
      { label: '평균 생존 턴', value: '0' },
    ],
    roleRecords: [
      { role: '시민', games: 0, winRate: 0, icon: 'C', featured: false },
      { role: '마피아', games: 0, winRate: 0, icon: 'M', featured: false },
      { role: '경찰', games: 0, winRate: 0, icon: 'P', featured: false },
      { role: '의사', games: 0, winRate: 0, icon: 'D', featured: false },
    ],
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
  const rankRow = rows.rank

  return {
    profile: {
      ...empty.profile,
      nickname: profileRow?.nickname || empty.profile.nickname,
      loginId: profileRow?.login_id || empty.profile.loginId,
      level: profileRow?.level ?? empty.profile.level,
      title: profileRow?.representative_title || profileRow?.character_name || empty.profile.title,
      coin: profileRow?.coin ?? empty.profile.coin,
      exp: profileRow?.experience_percent ?? empty.profile.exp,
      quote: profileRow?.profile_quote || empty.profile.quote,
    },
    rank: {
      tier: rankRow?.tier || empty.rank.tier,
      rp: rankRow?.rp ?? empty.rank.rp,
      topPercent: rankRow?.top_percent ?? empty.rank.topPercent,
      emblem: rankRow?.emblem || empty.rank.emblem,
    },
    stats: [
      { label: '총 플레이', value: String(statsRow?.total_games ?? 0) },
      { label: '전체 승률', value: toPercent(statsRow?.overall_win_rate) },
      { label: '시민 승률', value: toPercent(statsRow?.citizen_win_rate) },
      { label: '마피아 승률', value: toPercent(statsRow?.mafia_win_rate) },
      { label: '생존률', value: toPercent(statsRow?.survival_rate) },
      { label: '평균 생존 턴', value: String(statsRow?.average_survival_turn ?? 0) },
    ],
    roleRecords:
      rows.roles?.length > 0
        ? rows.roles.map((role) => ({
            role: role.role_name,
            games: role.games_played ?? 0,
            winRate: role.win_rate ?? 0,
            icon: role.icon || role.role_name?.slice(0, 1) || '?',
            featured: role.is_most_played,
          }))
        : empty.roleRecords,
    recentMatches:
      rows.matches?.length > 0
        ? rows.matches.map((match) => ({
            id: match.id,
            result: match.won ? '승리' : '패배',
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
    return null
  }

  return data
}

export async function getMyPageData(user) {
  if (!user?.id) {
    return getEmptyMyPage(user)
  }

  try {
    const [profile, stats, rank, roles, matches, achievements, cosmetics] = await Promise.all([
      selectMaybe(supabase.from('profiles').select('*').eq('id', user.id).maybeSingle()),
      selectMaybe(supabase.from('player_stats').select('*').eq('user_id', user.id).maybeSingle()),
      selectMaybe(supabase.from('player_ranks').select('*').eq('user_id', user.id).maybeSingle()),
      selectMaybe(
        supabase
          .from('player_role_stats')
          .select('*')
          .eq('user_id', user.id)
          .order('games_played', { ascending: false }),
      ),
      selectMaybe(
        supabase
          .from('player_recent_matches')
          .select('*')
          .eq('user_id', user.id)
          .order('played_at', { ascending: false })
          .limit(5),
      ),
      selectMaybe(
        supabase
          .from('player_achievements')
          .select('*')
          .eq('user_id', user.id)
          .order('unlocked_at', { ascending: false }),
      ),
      selectMaybe(
        supabase
          .from('player_cosmetics')
          .select('*')
          .eq('user_id', user.id)
          .order('sort_order', { ascending: true }),
      ),
    ])

    return normalizeMyPageData(user, {
      profile,
      stats,
      rank,
      roles,
      matches,
      achievements,
      cosmetics,
    })
  } catch {
    return getEmptyMyPage(user)
  }
}
