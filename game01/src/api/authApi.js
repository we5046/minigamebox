import { request, toQueryString } from './httpClient'
import { setCurrentUser } from './session'

export async function loginUser({ loginId, password }) {
  const query = toQueryString({
    loginId: loginId.trim(),
    password,
  })
  const users = await request(`/users?${query}`)

  if (users.length === 0) {
    throw new Error('로그인 ID가 없거나 비밀번호가 일치하지 않습니다.')
  }

  setCurrentUser(users[0])
  return users[0]
}

export async function signupUser({ loginId, nickname, password }) {
  const trimmedLoginId = loginId.trim()
  const trimmedNickname = nickname.trim()

  const sameLoginUsers = await request(`/users?${toQueryString({ loginId: trimmedLoginId })}`)

  if (sameLoginUsers.length > 0) {
    throw new Error('이미 사용 중인 로그인 ID입니다.')
  }

  const sameNicknameUsers = await request(`/users?${toQueryString({ nickname: trimmedNickname })}`)

  if (sameNicknameUsers.length > 0) {
    throw new Error('이미 사용 중인 게임 닉네임입니다.')
  }

  return request('/users', {
    method: 'POST',
    body: JSON.stringify({
      loginId: trimmedLoginId,
      nickname: trimmedNickname,
      password,
      isRegistered: true,
      createdAt: new Date().toISOString(),
      lastLoginAt: null,
      character: {
        name: 'Rookie Mafia',
        level: 1,
        coin: 0,
        avatar: 'default-mafia',
      },
    }),
  })
}

export async function resetPassword({ loginId, nickname, newPassword }) {
  const users = await request(
    `/users?${toQueryString({
      loginId: loginId.trim(),
      nickname: nickname.trim(),
    })}`,
  )

  if (users.length === 0) {
    throw new Error('일치하는 회원 정보를 찾을 수 없습니다.')
  }

  return request(`/users/${users[0].id}`, {
    method: 'PATCH',
    body: JSON.stringify({
      password: newPassword,
      passwordUpdatedAt: new Date().toISOString(),
    }),
  })
}
