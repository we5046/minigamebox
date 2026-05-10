import { defineStore } from 'pinia'
import { ref } from 'vue'
import { supabase } from '@/api/supabaseClient'
import { getProfile, toCurrentUser } from '@/api/authApi'

export const useAuthStore = defineStore('auth', () => {
  const user = ref(null)
  const isInitialized = ref(false)

  async function fetchUser(sessionUser) {
    if (!sessionUser) {
      user.value = null
      return
    }
    try {
      const profile = await getProfile(sessionUser.id)
      user.value = toCurrentUser(profile)
    } catch (error) {
      console.error('Failed to fetch user profile:', error)
      user.value = null
    }
  }

  function initialize() {
    supabase.auth.getSession().then(({ data: { session } }) => {
      fetchUser(session?.user).finally(() => {
        isInitialized.value = true
      })
    })

    supabase.auth.onAuthStateChange((_event, session) => {
      fetchUser(session?.user)
    })
  }

  return { user, isInitialized, initialize }
})
