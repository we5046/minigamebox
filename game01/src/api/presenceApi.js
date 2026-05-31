import { supabase } from './supabaseClient'

const PRESENCE_CHANNEL_NAME = 'user-presence'
const PRESENCE_READY_TIMEOUT_MS = 8000

let presenceChannel = null
let presenceUserId = null
let presenceReadyPromise = null
let resolvePresenceReady = null
let rejectPresenceReady = null
let presenceReadyTimer = null
const presenceSubscribers = new Set()
let lastPresenceUsers = []
let currentPresencePayload = null
let hasWarnedPresenceUnavailable = false
let presenceTrackPromise = null
let pendingPresencePayload = null

function clearPresenceReadyTimer() {
  if (presenceReadyTimer) {
    clearTimeout(presenceReadyTimer)
    presenceReadyTimer = null
  }
}

function resolvePresenceReadyOnce() {
  clearPresenceReadyTimer()
  resolvePresenceReady?.()
  resolvePresenceReady = null
  rejectPresenceReady = null
}

function rejectPresenceReadyOnce(reason) {
  clearPresenceReadyTimer()
  rejectPresenceReady?.(reason)
  resolvePresenceReady = null
  rejectPresenceReady = null
}

function normalizePresenceUsers(state) {
  return Object.entries(state).map(([id, presences]) => {
    const latestPresence = presences[presences.length - 1] || {}

    return {
      id,
      nickname: latestPresence.nickname || 'GuestPlayer',
      status: latestPresence.status || 'offline',
      roomId: latestPresence.roomId || null,
      canReceiveWhisper: latestPresence.canReceiveWhisper === true,
    }
  })
}

function emitPresenceUsers() {
  if (!presenceChannel) {
    lastPresenceUsers = []
    presenceSubscribers.forEach((callback) => callback([]))
    return
  }

  lastPresenceUsers = normalizePresenceUsers(presenceChannel.presenceState())
  presenceSubscribers.forEach((callback) => callback(lastPresenceUsers))
}

function hasSamePresencePayload(left, right) {
  return (
    left?.userId === right?.userId &&
    left?.nickname === right?.nickname &&
    left?.status === right?.status &&
    left?.roomId === right?.roomId &&
    left?.canReceiveWhisper === right?.canReceiveWhisper
  )
}

function createPresenceChannel(userId) {
  presenceReadyPromise = new Promise((resolve, reject) => {
    resolvePresenceReady = resolve
    rejectPresenceReady = reject
    presenceReadyTimer = setTimeout(() => {
      rejectPresenceReadyOnce(new Error('Presence subscription timed out.'))
    }, PRESENCE_READY_TIMEOUT_MS)
  })

  presenceChannel = supabase
    .channel(PRESENCE_CHANNEL_NAME, {
      config: {
        presence: {
          key: userId,
        },
      },
    })
    .on('presence', { event: 'sync' }, emitPresenceUsers)
    .subscribe((status) => {
      if (status === 'SUBSCRIBED') {
        resolvePresenceReadyOnce()
        emitPresenceUsers()
        return
      }

      if (status === 'CHANNEL_ERROR' || status === 'TIMED_OUT' || status === 'CLOSED') {
        rejectPresenceReadyOnce(new Error(`Presence subscription failed: ${status}`))
      }
    })
}

function ensurePresenceChannel(userId) {
  if (!userId) {
    return null
  }

  if (presenceChannel && presenceUserId === userId) {
    return presenceChannel
  }

  if (presenceChannel) {
    supabase.removeChannel(presenceChannel)
  }

  presenceChannel = null
  presenceUserId = userId
  currentPresencePayload = null
  createPresenceChannel(userId)
  return presenceChannel
}

async function waitForPresenceReady() {
  if (!presenceReadyPromise) {
    return true
  }

  try {
    await presenceReadyPromise
    return true
  } catch (error) {
    if (!hasWarnedPresenceUnavailable) {
      hasWarnedPresenceUnavailable = true
      console.warn('[Presence] Realtime presence is unavailable.', error)
    }
    return false
  }
}

export function subscribeToPresenceUsers(callback) {
  presenceSubscribers.add(callback)
  callback(lastPresenceUsers)

  return () => {
    presenceSubscribers.delete(callback)
  }
}

export async function setCurrentUserPresence({
  userId,
  nickname,
  status,
  roomId = null,
  canReceiveWhisper = true,
}) {
  const channel = ensurePresenceChannel(userId)

  if (!channel) {
    return
  }

  const isPresenceReady = await waitForPresenceReady()

  if (!isPresenceReady) {
    return
  }

  const nextPresencePayload = {
    userId,
    nickname: nickname || currentPresencePayload?.nickname || 'GuestPlayer',
    status: status || currentPresencePayload?.status || 'offline',
    roomId,
    canReceiveWhisper,
  }

  if (
    hasSamePresencePayload(currentPresencePayload, nextPresencePayload) ||
    hasSamePresencePayload(pendingPresencePayload, nextPresencePayload)
  ) {
    return
  }

  const previousTrackPromise = presenceTrackPromise
  pendingPresencePayload = nextPresencePayload
  const nextTrackPromise = (async () => {
    await previousTrackPromise?.catch(() => {})
    const result = await channel.track({
      nickname: nextPresencePayload.nickname,
      status: nextPresencePayload.status,
      roomId: nextPresencePayload.roomId,
      canReceiveWhisper: nextPresencePayload.canReceiveWhisper,
      onlineAt: new Date().toISOString(),
    })

    if (result === 'ok' && presenceChannel === channel) {
      currentPresencePayload = nextPresencePayload
      hasWarnedPresenceUnavailable = false
      return
    }

    if (!hasWarnedPresenceUnavailable) {
      hasWarnedPresenceUnavailable = true
      console.warn('[Presence] Failed to track current user presence.', { result })
    }
  })()
  presenceTrackPromise = nextTrackPromise

  try {
    await nextTrackPromise
  } finally {
    if (presenceTrackPromise === nextTrackPromise) {
      presenceTrackPromise = null
      pendingPresencePayload = null
    }
  }
}

export async function clearCurrentUserPresence() {
  if (!presenceChannel) {
    return
  }

  const channel = presenceChannel
  presenceChannel = null
  presenceUserId = null
  presenceReadyPromise = null
  resolvePresenceReady = null
  rejectPresenceReady = null
  clearPresenceReadyTimer()
  currentPresencePayload = null
  presenceTrackPromise = null
  pendingPresencePayload = null
  hasWarnedPresenceUnavailable = false
  lastPresenceUsers = []

  presenceSubscribers.forEach((callback) => callback([]))
  await supabase.removeChannel(channel)
}
