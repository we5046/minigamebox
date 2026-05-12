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
  await authStore.initialize()
  const profileStore = useProfileStore()
  if (authStore.user?.id) {
    await profileStore.reloadProfile(authStore.user.id)
  } else {
    profileStore.resetProfile()
  }

  app.use(router)
  app.mount('#app')
}

bootstrap()
