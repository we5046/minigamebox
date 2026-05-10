import { defineStore } from 'pinia'
import { ref } from 'vue'
import { supabase } from '@/api/supabaseClient'
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

    roomSubscription = supabase
      .channel('public:rooms')
      .on('postgres_changes', { event: '*', schema: 'public', table: 'rooms' }, () => {
        fetchRooms()
      })
      .on('postgres_changes', { event: '*', schema: 'public', table: 'room_players' }, () => {
        fetchRooms()
      })
      .subscribe()

    return unsubscribeFromRooms
  }

  function unsubscribeFromRooms() {
    if (!roomSubscription) {
      return
    }

    const channel = roomSubscription
    roomSubscription = null
    supabase.removeChannel(channel)
  }

  return { rooms, fetchRooms, subscribeToRooms, unsubscribeFromRooms }
})
