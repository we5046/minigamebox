import { createSupabaseError, supabase } from './supabaseClient'
import { clearCurrentUser, setCurrentUser } from './session'

function toAuthEmail(loginId) {
  return `${loginId.trim().toLowerCase()}@mafia.local`
}

export function toCurrentUser(profile) {
  const stats = profile.stats || {}
  const rank = profile.rank || {}

  return {
    id: profile.id,
    loginId: profile.login_id,
    nickname: profile.nickname,
    representativeTitle: profile.representative_title,
    quote: profile.profile_quote,
    experiencePercent: profile.experience_percent,
    rank: {
      tier: rank.tier,
      rp: rank.rp,
      topPercent: rank.top_percent,
      emblem: rank.emblem,
    },
    stats: {
      totalGames: stats.total_games,
      winRate: stats.overall_win_rate,
      citizenWinRate: stats.citizen_win_rate,
      mafiaWinRate: stats.mafia_win_rate,
      survivalRate: stats.survival_rate,
      averageSurvivalTurn: stats.average_survival_turn,
    },
    character: {
      name: profile.character_name,
      level: profile.level,
      coin: profile.coin,
      avatar: profile.avatar,
    },
  }
}

export async function getProfile(userId) {
  const [profileResult, rankResult, statsResult] = await Promise.all([
    supabase
      .from('profiles')
      .select('id, login_id, nickname, character_name, level, coin, avatar, representative_title, profile_quote, experience_percent')
      .eq('id', userId)
      .single(),
    supabase.from('player_ranks').select('user_id, tier, rp, top_percent, emblem').eq('user_id', userId).maybeSingle(),
    supabase
      .from('player_stats')
      .select('user_id, total_games, overall_win_rate, citizen_win_rate, mafia_win_rate, survival_rate, average_survival_turn')
      .eq('user_id', userId)
      .maybeSingle(),
  ])

  if (profileResult.error) {
    throw createSupabaseError('getProfile: profiles select failed', profileResult.error, '프로필 정보를 불러오지 못했습니다.')
  }

  return {
    ...profileResult.data,
    rank: rankResult.data,
    stats: statsResult.data,
  }
}

export async function loginUser({ loginId, password }) {
  const { data, error } = await supabase.auth.signInWithPassword({
    email: toAuthEmail(loginId),
    password,
  })

  if (error || !data.user) {
    throw createSupabaseError('loginUser: signInWithPassword failed', error, '로그인 ID가 없거나 비밀번호가 일치하지 않습니다.')
  }

  const currentUser = toCurrentUser(await getProfile(data.user.id))
  setCurrentUser(currentUser)
  return currentUser
}

export async function signupUser({ loginId, nickname, password }) {
  const trimmedLoginId = loginId.trim()
  const trimmedNickname = nickname.trim()

  const { data: sameLoginUsers, error: loginError } = await supabase
    .from('profiles')
    .select('id')
    .eq('login_id', trimmedLoginId)

  if (loginError) {
    throw createSupabaseError('signupUser: duplicate login check failed', loginError, '회원 확인 요청에 실패했습니다.')
  }

  if (sameLoginUsers.length > 0) {
    throw new Error('이미 사용 중인 로그인 ID입니다.')
  }

  const { data: sameNicknameUsers, error: nicknameError } = await supabase
    .from('profiles')
    .select('id')
    .eq('nickname', trimmedNickname)

  if (nicknameError) {
    throw createSupabaseError('signupUser: duplicate nickname check failed', nicknameError, '닉네임 확인 요청에 실패했습니다.')
  }

  if (sameNicknameUsers.length > 0) {
    throw new Error('이미 사용 중인 게임 닉네임입니다.')
  }

  const { data: authData, error: authError } = await supabase.auth.signUp({
    email: toAuthEmail(trimmedLoginId),
    password,
  })

  if (authError || !authData.user) {
    throw createSupabaseError('signupUser: auth signUp failed', authError, authError?.message || '회원가입에 실패했습니다.')
  }

  const { error: profileError } = await supabase.from('profiles').insert({
    id: authData.user.id,
    login_id: trimmedLoginId,
    nickname: trimmedNickname,
    character_name: 'Rookie Mafia',
    level: 1,
    coin: 0,
    avatar: 'default-mafia',
  })

  if (profileError) {
    throw createSupabaseError('signupUser: profile insert failed', profileError, '프로필 저장에 실패했습니다.')
  }

  return authData.user
}

export async function resetPassword() {
  throw new Error(
    'Supabase Auth에서는 로그인 ID와 닉네임만으로 비밀번호를 갱신할 수 없습니다. 이메일 기반 재설정으로 전환해야 합니다.',
  )
}

export async function logoutUser() {
  await supabase.auth.signOut()
  clearCurrentUser()
}
