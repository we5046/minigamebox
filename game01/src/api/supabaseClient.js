import { createClient } from '@supabase/supabase-js'

const supabaseUrl = import.meta.env.VITE_SUPABASE_URL
const supabaseAnonKey = import.meta.env.VITE_SUPABASE_ANON_KEY
const missingConfigMessage = '.env에 VITE_SUPABASE_URL과 VITE_SUPABASE_ANON_KEY를 설정하세요.'

export function logSupabaseError(context, error, extra = {}) {
  if (!error) {
    return
  }

  console.error(`[Supabase] ${context}`, {
    message: error.message,
    code: error.code,
    details: error.details,
    hint: error.hint,
    ...extra,
    raw: error,
  })
}

export function createSupabaseError(context, error, userMessage) {
  logSupabaseError(context, error)
  const wrappedError = new Error(userMessage)
  wrappedError.cause = error
  wrappedError.supabaseError = error
  return wrappedError
}

function throwMissingConfig() {
  console.error(`[Supabase] Missing configuration: ${missingConfigMessage}`)
  throw new Error(missingConfigMessage)
}

function createMissingSupabaseClient() {
  const channel = {
    on() {
      return channel
    },
    subscribe(callback) {
      callback?.('CHANNEL_ERROR')
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
      getSession: async () => ({ data: { session: null }, error: null }),
      onAuthStateChange: () => ({
        data: {
          subscription: {
            unsubscribe() {},
          },
        },
      }),
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
    storage: {
      from: throwMissingConfig,
    },
  }
}

export const supabase =
  supabaseUrl && supabaseAnonKey
    ? createClient(supabaseUrl, supabaseAnonKey)
    : createMissingSupabaseClient()
