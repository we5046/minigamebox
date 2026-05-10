import { createClient } from '@supabase/supabase-js'

const supabaseUrl = import.meta.env.VITE_SUPABASE_URL
const supabaseAnonKey = import.meta.env.VITE_SUPABASE_ANON_KEY
const missingConfigMessage = '.env에 VITE_SUPABASE_URL과 VITE_SUPABASE_ANON_KEY를 설정하세요.'

function throwMissingConfig() {
  throw new Error(missingConfigMessage)
}

function createMissingSupabaseClient() {
  const channel = {
    on() {
      return channel
    },
    subscribe() {
      return channel
    },
    presenceState() {
      return {}
    },
    track: throwMissingConfig,
    untrack: async () => {},
  }

  return {
    auth: {
      signInWithPassword: throwMissingConfig,
      signUp: throwMissingConfig,
      signOut: async () => {},
    },
    channel() {
      return channel
    },
    from: throwMissingConfig,
    removeChannel: async () => {},
    rpc: throwMissingConfig,
  }
}

export const supabase =
  supabaseUrl && supabaseAnonKey
    ? createClient(supabaseUrl, supabaseAnonKey)
    : createMissingSupabaseClient()
