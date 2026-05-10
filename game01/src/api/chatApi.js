import { supabase } from './supabaseClient'

const chatChannels = new Map()

const CHAT_CHANNELS = {
  publicLobby: 'public-lobby-chat',
  room: (roomId) => `room-chat-${roomId}`,
  game: (roomId) => `game-chat-${roomId}`,
  dead: (roomId) => `dead-chat-${roomId}`,
}

function formatChatTime(value) {
  const date = new Date(value)

  if (Number.isNaN(date.getTime())) {
    return ''
  }

  return date.toLocaleTimeString('ko-KR', {
    hour: '2-digit',
    minute: '2-digit',
  })
}

export function normalizeBroadcastMessage(payload) {
  return {
    id: payload.id,
    userId: payload.userId,
    nickname: payload.nickname || 'Unknown',
    content: payload.content,
    createdAt: formatChatTime(payload.createdAt),
    isSystem: payload.isSystem === true,
  }
}

function subscribeToChatChannel(channelKey, callback) {
  unsubscribeFromChatChannel(channelKey)

  const channel = supabase
    .channel(channelKey, {
      config: {
        broadcast: {
          self: true,
        },
      },
    })
    .on('broadcast', { event: 'message' }, callback)
    .subscribe((status) => {
      callback({ type: 'subscription-status', status })
    })

  chatChannels.set(channelKey, channel)

  return {
    channel,
    unsubscribe: () => unsubscribeFromChatChannel(channelKey),
  }
}

function unsubscribeFromChatChannel(channelKey) {
  const channel = chatChannels.get(channelKey)

  if (!channel) {
    return
  }

  chatChannels.delete(channelKey)
  supabase.removeChannel(channel)
}

export function subscribeToPublicChat(callback) {
  return subscribeToChatChannel(CHAT_CHANNELS.publicLobby, callback)
}

export function subscribeToRoomChat(roomId, callback) {
  return subscribeToChatChannel(CHAT_CHANNELS.room(roomId), callback)
}

export function subscribeToGameChat(roomId, callback) {
  return subscribeToChatChannel(CHAT_CHANNELS.game(roomId), callback)
}

export function subscribeToDeadChat(roomId, callback) {
  return subscribeToChatChannel(CHAT_CHANNELS.dead(roomId), callback)
}

export async function sendPublicChatMessage(channel, { userId, nickname, content }) {
  return sendChatMessage(channel, { userId, nickname, content, isSystem: false })
}

export async function sendRoomChatMessage(channel, { userId, nickname, content, isSystem = false }) {
  return sendChatMessage(channel, { userId, nickname, content, isSystem })
}

export async function sendChatMessage(channel, { userId, nickname, content, isSystem = false }) {
  if (!channel) {
    throw new Error('채팅 채널이 아직 연결되지 않았습니다.')
  }

  const result = await channel.send({
    type: 'broadcast',
    event: 'message',
    payload: {
      id: `${userId}-${Date.now()}`,
      userId,
      nickname,
      content: content.trim(),
      createdAt: new Date().toISOString(),
      isSystem,
    },
  })

  if (result !== 'ok') {
    throw new Error('채팅 메시지 전송에 실패했습니다.')
  }
}
