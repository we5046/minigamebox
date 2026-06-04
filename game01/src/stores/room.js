import { defineStore } from 'pinia'
import { ref } from 'vue'
import { supabase } from '@/api/supabaseClient'
import { createRealtimeSubscription } from '@/api/realtimeSubscription'
import { getRooms as getRoomsFromApi } from '@/api/roomApi'

export const useRoomStore = defineStore('room', () => {
  const rooms = ref([])
  let roomSubscription = null

  async function fetchRooms() {
    try {
      const data = await getRoomsFromApi()
      rooms.value = data
    } catch (error) {
      console.error(error)
    }
  }

  function subscribeToRooms() {
    unsubscribeFromRooms()

    roomSubscription = createRealtimeSubscription({
      createChannel: (handleStatus) =>
        supabase
          .channel('public:rooms')
          .on('postgres_changes', { event: '*', schema: 'public', table: 'rooms' }, () => {
            fetchRooms()
          })
          .on('postgres_changes', { event: '*', schema: 'public', table: 'room_players' }, () => {
            fetchRooms()
          })
          .subscribe(handleStatus),
    })

    return unsubscribeFromRooms
  }

  function unsubscribeFromRooms() {
    if (!roomSubscription) {
      return
    }

    const subscription = roomSubscription
    roomSubscription = null
    subscription.unsubscribe()
  }

  return { rooms, fetchRooms, subscribeToRooms, unsubscribeFromRooms }
})
