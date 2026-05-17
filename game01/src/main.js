import './assets/main.css'

import { createApp } from 'vue'
import { createPinia, setActivePinia } from 'pinia'

import App from './App.vue'
import router from './router'
import { useAuthStore } from './stores/auth'
import { useProfileStore } from './stores/profile'

async function bootstrap() {
  const app = createApp(App)
  const pinia = createPinia()

  app.use(pinia)
  setActivePinia(pinia)

  const authStore = useAuthStore()
  const profileStore = useProfileStore()

  try {
    await authStore.initialize()

    if (authStore.user?.id) {
      await profileStore.reloadProfile(authStore.user.id)
    } else {
      profileStore.resetProfile()
    }
  } catch (error) {
    console.error('[Bootstrap] Failed to initialize app state', error)
    profileStore.resetProfile()
  }

  app.use(router)
  app.mount('#app')
}

bootstrap().catch((error) => {
  console.error('[Bootstrap] Unhandled bootstrap failure', error)
})
