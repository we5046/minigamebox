import { supabase } from './supabaseClient'

let publicChatChannel = null

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
    isSystem: false,
  }
}

export function subscribeToPublicChat(callback) {
  publicChatChannel = supabase
    .channel('public-lobby-chat', {
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

  return () => {
    const channel = publicChatChannel
    publicChatChannel = null
    supabase.removeChannel(channel)
  }
}

export async function sendPublicChatMessage({ userId, nickname, content }) {
  if (!publicChatChannel) {
    throw new Error('공용 채팅 채널에 아직 연결되지 않았습니다.')
  }

  const result = await publicChatChannel.send({
    type: 'broadcast',
    event: 'message',
    payload: {
      id: `${userId}-${Date.now()}`,
      userId,
      nickname,
      content: content.trim(),
      createdAt: new Date().toISOString(),
    },
  })

  if (result !== 'ok') {
    throw new Error('공용 채팅 메시지 전송에 실패했습니다.')
  }
}

export function subscribeToRoomChat(roomId, callback) {
  const roomChatChannel = supabase
    .channel(`room-chat-${roomId}`, {
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

  return {
    channel: roomChatChannel,
    unsubscribe: () => {
      supabase.removeChannel(roomChatChannel)
    }
  }
}

export async function sendRoomChatMessage(channel, { userId, nickname, content, isSystem = false }) {
  if (!channel) {
    throw new Error('채팅 채널에 연결되지 않았습니다.')
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
