const CURRENT_USER_KEY = 'currentUser'
const LAST_LOGIN_ID_KEY = 'lastLoginId'

export function getCurrentUser() {
  return JSON.parse(localStorage.getItem(CURRENT_USER_KEY) || 'null')
}

export function setCurrentUser(user) {
  localStorage.setItem(CURRENT_USER_KEY, JSON.stringify(user))

  if (user?.loginId) {
    setLastLoginId(user.loginId)
  }
}

export function clearCurrentUser() {
  localStorage.removeItem(CURRENT_USER_KEY)
}

export function getLastLoginId() {
  return localStorage.getItem(LAST_LOGIN_ID_KEY) || ''
}

export function setLastLoginId(loginId) {
  const trimmedLoginId = loginId?.trim()

  if (!trimmedLoginId) {
    return
  }

  localStorage.setItem(LAST_LOGIN_ID_KEY, trimmedLoginId)
}

export function clearLoginStorageExceptLastLoginId() {
  const lastLoginId = getLastLoginId()

  clearCurrentUser()

  Object.keys(localStorage)
    .filter((key) => key.startsWith('sb-') && key.includes('auth-token'))
    .forEach((key) => localStorage.removeItem(key))

  if (lastLoginId) {
    setLastLoginId(lastLoginId)
  }
}
