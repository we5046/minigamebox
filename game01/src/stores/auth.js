import { defineStore } from 'pinia'
import { ref } from 'vue'
import { supabase } from '@/api/supabaseClient'
import { getProfile, toCurrentUser } from '@/api/authApi'

export const useAuthStore = defineStore('auth', () => {
  const user = ref(null)
  const isInitialized = ref(false)
  let initializePromise = null
  let authSubscription = null

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
    if (initializePromise) {
      return initializePromise
    }

    initializePromise = supabase.auth.getSession().then(async ({ data: { session } }) => {
      await fetchUser(session?.user)
      if (!authSubscription) {
        const { data } = supabase.auth.onAuthStateChange((_event, nextSession) => {
          fetchUser(nextSession?.user)
        })
        authSubscription = data.subscription
      }
    }).finally(() => {
      isInitialized.value = true
    })

    return initializePromise
  }

  function reset() {
    user.value = null
    isInitialized.value = false
    initializePromise = null
    if (authSubscription) {
      authSubscription.unsubscribe()
      authSubscription = null
    }
  }

  return { user, isInitialized, initialize, reset }
})
