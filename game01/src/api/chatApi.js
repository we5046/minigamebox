import { supabase } from './supabaseClient'

const chatChannels = new Map()

const CHAT_CHANNELS = {
  publicLobby: 'public-lobby-chat',
  room: (roomId) => `room-chat-${roomId}`,
  game: (roomId) => `game-chat-${roomId}`,
  dead: (roomId) => `dead-chat-${roomId}`,
}

const GAME_LOG_BUCKET = 'game-logs'

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
    targetUserId: payload.targetUserId || null,
    targetNickname: payload.targetNickname || '',
    nickname: payload.nickname || '알 수 없음',
    content: payload.content,
    createdAt: formatChatTime(payload.createdAt),
    isSystem: payload.isSystem === true,
    isWhisper: payload.isWhisper === true,
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

export function normalizeGameMessage(row) {
  return {
    id: row.id,
    roomId: row.room_id,
    gameId: row.game_id,
    roundNo: row.round_no,
    userId: row.user_id,
    nickname: row.nickname || 'System',
    content: row.content || '',
    createdAt: formatChatTime(row.created_at),
    isSystem: row.is_system === true,
    messageType: row.message_type || (row.is_system === true ? 'system' : 'chat'),
    channelType: row.channel_type || 'public',
    eventKey: row.event_key || null,
  }
}

export async function getGameMessages(roomId, gameId, { limit = 120 } = {}) {
  if (!gameId) {
    return []
  }

  const { data, error } = await supabase
    .from('game_messages')
    .select('id, room_id, game_id, round_no, user_id, nickname, content, message_type, channel_type, event_key, is_system, created_at')
    .eq('room_id', roomId)
    .eq('game_id', gameId)
    .order('created_at', { ascending: true })
    .limit(limit)

  if (error) {
    throw new Error('게임 채팅을 불러오지 못했습니다.')
  }

  return (data || []).map(normalizeGameMessage)
}

function formatGameLogMarkdown({ room, game, messages }) {
  const lines = [
    '# Mafia Game Log',
    '',
    `- Room ID: ${room?.id || game?.room_id || ''}`,
    `- Room Title: ${room?.title || ''}`,
    `- Game ID: ${game?.id || ''}`,
    `- Started At: ${game?.created_at || ''}`,
    `- Exported At: ${new Date().toISOString()}`,
    '',
    '## Messages',
    '',
  ]

  if (!messages.length) {
    lines.push('_No messages._')
  } else {
    messages.forEach((message) => {
      const label = message.messageType === 'system' ? 'System' : message.nickname
      const round = message.roundNo ? ` R${message.roundNo}` : ''
      lines.push(`- ${message.createdAt}${round} [${label}] ${message.content}`)
    })
  }

  return `${lines.join('\n')}\n`
}

export async function uploadGameLogMarkdown({ room, game, messages }) {
  if (!room?.id || !game?.id) {
    return null
  }

  const path = `${room.id}/${game.id}.md`
  const body = new Blob([formatGameLogMarkdown({ room, game, messages })], {
    type: 'text/markdown;charset=utf-8',
  })

  const { data, error } = await supabase.storage.from(GAME_LOG_BUCKET).upload(path, body, {
    contentType: 'text/markdown;charset=utf-8',
    upsert: false,
  })

  if (error) {
    throw new Error('게임 로그 파일 저장에 실패했습니다.')
  }

  return data
}

export async function sendGameMessage({ roomId, gameId, userId, nickname, content, channelType = 'public' }) {
  const trimmedContent = content.trim()

  if (!trimmedContent) {
    return null
  }

  const { data, error } = await supabase
    .from('game_messages')
    .insert({
      room_id: roomId,
      game_id: gameId,
      user_id: userId,
      nickname,
      content: trimmedContent,
      message_type: 'chat',
      channel_type: channelType,
      event_key: null,
      is_system: false,
    })
    .select('id, room_id, game_id, round_no, user_id, nickname, content, message_type, channel_type, event_key, is_system, created_at')
    .single()

  if (error) {
    throw new Error('게임 채팅 전송에 실패했습니다.')
  }

  return normalizeGameMessage(data)
}

export function subscribeToGameMessages(roomId, gameId, callback) {
  if (!gameId) {
    return () => {}
  }

  const channelKey = `game-messages-${roomId}-${gameId}`
  unsubscribeFromChatChannel(channelKey)

  const channel = supabase
    .channel(channelKey)
    .on(
      'postgres_changes',
      {
        event: 'INSERT',
        schema: 'public',
        table: 'game_messages',
        filter: `game_id=eq.${gameId}`,
      },
      (payload) => {
        if (payload.new?.room_id === roomId) {
          callback(payload)
        }
      },
    )
    .subscribe((status) => {
      callback({ type: 'subscription-status', status })
    })

  chatChannels.set(channelKey, channel)

  return () => unsubscribeFromChatChannel(channelKey)
}

export async function sendPublicChatMessage(channel, { userId, nickname, content }) {
  return sendChatMessage(channel, { userId, nickname, content, isSystem: false })
}

export async function sendWhisperChatMessage(
  channel,
  { userId, nickname, targetUserId, targetNickname, content },
) {
  return sendChatMessage(channel, {
    userId,
    nickname,
    targetUserId,
    targetNickname,
    content,
    isSystem: false,
    isWhisper: true,
  })
}

export async function sendRoomChatMessage(channel, { userId, nickname, content, isSystem = false }) {
  return sendChatMessage(channel, { userId, nickname, content, isSystem })
}

export async function sendChatMessage(
  channel,
  {
    userId,
    nickname,
    content,
    targetUserId = null,
    targetNickname = '',
    isSystem = false,
    isWhisper = false,
  },
) {
  if (!channel) {
    throw new Error('채팅 채널이 아직 연결되지 않았습니다.')
  }

  const result = await channel.send({
    type: 'broadcast',
    event: 'message',
    payload: {
      id: `${userId}-${Date.now()}`,
      userId,
      targetUserId,
      targetNickname,
      nickname,
      content: content.trim(),
      createdAt: new Date().toISOString(),
      isSystem,
      isWhisper,
    },
  })

  if (result !== 'ok') {
    throw new Error('채팅 메시지 전송에 실패했습니다.')
  }
}
