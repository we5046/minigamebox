const CURRENT_USER_KEY = 'currentUser'

export function getCurrentUser() {
  return JSON.parse(localStorage.getItem(CURRENT_USER_KEY) || 'null')
}

export function setCurrentUser(user) {
  localStorage.setItem(CURRENT_USER_KEY, JSON.stringify(user))
}

export function clearCurrentUser() {
  localStorage.removeItem(CURRENT_USER_KEY)
}
