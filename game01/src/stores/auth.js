import { defineStore } from 'pinia'
import { ref } from 'vue'
import { supabase } from '@/api/supabaseClient'
import { getProfile, toCurrentUser } from '@/api/authApi'
import { clearCurrentUser, setCurrentUser } from '@/api/session'

export const useAuthStore = defineStore('auth', () => {
  const user = ref(null)
  const isInitialized = ref(false)
  let initializePromise = null
  let authSubscription = null

  function setUser(nextUser) {
    user.value = nextUser
  }

  async function fetchUser(sessionUser) {
    if (!sessionUser) {
      setUser(null)
      clearCurrentUser()
      return
    }
    try {
      const profile = await getProfile(sessionUser.id)
      setUser(toCurrentUser(profile))
      setCurrentUser(user.value)
    } catch (error) {
      console.error('Failed to fetch user profile:', error)
      setUser(null)
      clearCurrentUser()
    }
  }

  async function initialize() {
    if (initializePromise) {
      return initializePromise
    }

    initializePromise = (async () => {
      try {
        const { data: { session } } = await supabase.auth.getSession()
        await fetchUser(session?.user)

        if (!authSubscription) {
          const { data } = supabase.auth.onAuthStateChange(async (event, nextSession) => {
            if (event === 'SIGNED_IN' || event === 'TOKEN_REFRESHED') {
              await fetchUser(nextSession?.user)
              return
            }

            if (event === 'SIGNED_OUT') {
              await fetchUser(null)
            }
          })
          authSubscription = data.subscription
        }
      } finally {
        isInitialized.value = true
      }
    })()

    return initializePromise
  }

  function reset() {
    setUser(null)
    isInitialized.value = false
    initializePromise = null
    if (authSubscription) {
      authSubscription.unsubscribe()
      authSubscription = null
    }
  }

  return { user, isInitialized, initialize, reset, setUser }
})
