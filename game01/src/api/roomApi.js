import { request } from './httpClient'

export function normalizeRoom(room) {
  const players = room.players || []

  return {
    ...room,
    players,
    currentPlayers: players.length || room.currentPlayers || 0,
  }
}

export async function getRooms() {
  const rooms = await request('/rooms')
  return rooms.map(normalizeRoom)
}

export async function getRoom(roomId) {
  return normalizeRoom(await request(`/rooms/${roomId}`))
}

export async function createRoom({ hostUser, roomCount }) {
  const createdAt = new Date().toISOString()

  return normalizeRoom(
    await request('/rooms', {
      method: 'POST',
      body: JSON.stringify({
        title: `${hostUser.nickname}의 방`,
        code: `ROOM-${Date.now().toString().slice(-6)}`,
        hostUserId: hostUser.id,
        hostNickname: hostUser.nickname,
        status: 'waiting',
        maxPlayers: 8,
        currentPlayers: 1,
        phase: '시작 전',
        createdAt,
        order: roomCount,
        players: [
          {
            userId: hostUser.id,
            nickname: hostUser.nickname,
            isHost: true,
            isReady: false,
            joinedAt: createdAt,
          },
        ],
      }),
    }),
  )
}

export async function updateRoom(roomId, payload) {
  return normalizeRoom(
    await request(`/rooms/${roomId}`, {
      method: 'PATCH',
      body: JSON.stringify(payload),
    }),
  )
}

export async function deleteRoom(roomId) {
  return request(`/rooms/${roomId}`, {
    method: 'DELETE',
  })
}
