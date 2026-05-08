const BASE_URL = 'http://localhost:3001'

export async function request(path, options = {}) {
  const response = await fetch(`${BASE_URL}${path}`, {
    headers: {
      'Content-Type': 'application/json',
      ...options.headers,
    },
    ...options,
  })

  if (!response.ok) {
    const message = await response.text()
    throw new Error(message || 'API 요청에 실패했습니다.')
  }

  if (response.status === 204) {
    return null
  }

  return response.json()
}

export function toQueryString(params) {
  return new URLSearchParams(params).toString()
}
