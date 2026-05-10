import { defineStore } from 'pinia'
import { ref } from 'vue'
import { supabase } from '@/api/supabaseClient'
import { getRooms as getRoomsFromApi } from '@/api/roomApi'

export const useRoomStore = defineStore('room', () => {
  const rooms = ref([])

  async function fetchRooms() {
    try {
      const data = await getRoomsFromApi()
      rooms.value = data
    } catch (error) {
      console.error(error)
    }
  }

  // Subscribe to room changes
  function subscribeToRooms() {
    const roomSubscription = supabase
      .channel('public:rooms')
      .on('postgres_changes', { event: '*', schema: 'public', table: 'rooms' }, () => {
        fetchRooms() // Simply refetch on change for simplicity
      })
      .on('postgres_changes', { event: '*', schema: 'public', table: 'room_players' }, () => {
        fetchRooms()
      })
      .subscribe()
      
    return roomSubscription
  }

  return { rooms, fetchRooms, subscribeToRooms }
})
