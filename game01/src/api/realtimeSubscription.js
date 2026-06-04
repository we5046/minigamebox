import { supabase } from './supabaseClient'

const RECONNECT_STATUSES = new Set(['CHANNEL_ERROR', 'TIMED_OUT', 'CLOSED'])

export function createRealtimeSubscription({
  createChannel,
  onStatus,
  reconnectDelayMs = 800,
  maxReconnectDelayMs = 10_000,
}) {
  let channel = null
  let reconnectTimer = null
  let reconnectAttempt = 0
  let isStopped = false

  function clearReconnectTimer() {
    if (reconnectTimer) {
      clearTimeout(reconnectTimer)
      reconnectTimer = null
    }
  }

  async function removeCurrentChannel() {
    const currentChannel = channel
    channel = null

    if (currentChannel) {
      await supabase.removeChannel(currentChannel).catch(() => {})
    }
  }

  function getReconnectDelay() {
    return Math.min(
      maxReconnectDelayMs,
      reconnectDelayMs * 2 ** Math.min(reconnectAttempt, 4),
    )
  }

  function scheduleReconnect() {
    if (isStopped || reconnectTimer) {
      return
    }

    const delay = getReconnectDelay()
    reconnectAttempt += 1
    reconnectTimer = setTimeout(async () => {
      reconnectTimer = null
      await removeCurrentChannel()
      start()
    }, delay)
  }

  function handleStatus(status) {
    onStatus?.(status)

    if (status === 'SUBSCRIBED') {
      reconnectAttempt = 0
      return
    }

    if (RECONNECT_STATUSES.has(status)) {
      scheduleReconnect()
    }
  }

  function start() {
    if (isStopped) {
      return
    }

    channel = createChannel(handleStatus)
  }

  start()

  return {
    get channel() {
      return channel
    },
    send(...args) {
      if (!channel) {
        return Promise.resolve('error')
      }

      return channel.send(...args)
    },
    unsubscribe() {
      isStopped = true
      clearReconnectTimer()
      return removeCurrentChannel()
    },
  }
}
