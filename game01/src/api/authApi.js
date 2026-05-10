import { supabase } from './supabaseClient'
import { clearCurrentUser, setCurrentUser } from './session'

function toAuthEmail(loginId) {
  return `${loginId.trim().toLowerCase()}@mafia.local`
}

export function toCurrentUser(profile) {
  return {
    id: profile.id,
    loginId: profile.login_id,
    nickname: profile.nickname,
    character: {
      name: profile.character_name,
      level: profile.level,
      coin: profile.coin,
      avatar: profile.avatar,
    },
  }
}

export async function getProfile(userId) {
  const { data, error } = await supabase.from('profiles').select('*').eq('id', userId).single()

  if (error) {
    throw new Error('프로필 정보를 불러오지 못했습니다.')
  }

  return data
}

export async function loginUser({ loginId, password }) {
  const { data, error } = await supabase.auth.signInWithPassword({
    email: toAuthEmail(loginId),
    password,
  })

  if (error || !data.user) {
    throw new Error('로그인 ID가 없거나 비밀번호가 일치하지 않습니다.')
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
    throw new Error('회원 확인 요청에 실패했습니다.')
  }

  if (sameLoginUsers.length > 0) {
    throw new Error('이미 사용 중인 로그인 ID입니다.')
  }

  const { data: sameNicknameUsers, error: nicknameError } = await supabase
    .from('profiles')
    .select('id')
    .eq('nickname', trimmedNickname)

  if (nicknameError) {
    throw new Error('닉네임 확인 요청에 실패했습니다.')
  }

  if (sameNicknameUsers.length > 0) {
    throw new Error('이미 사용 중인 게임 닉네임입니다.')
  }

  const { data: authData, error: authError } = await supabase.auth.signUp({
    email: toAuthEmail(trimmedLoginId),
    password,
  })

  if (authError || !authData.user) {
    throw new Error(authError?.message || '회원가입에 실패했습니다.')
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
    throw new Error('프로필 저장에 실패했습니다.')
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
