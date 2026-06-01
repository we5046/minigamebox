<script setup>
import { computed, watch } from 'vue'
import { RouterLink, RouterView, useRoute, useRouter } from 'vue-router'
import { logoutUser } from '@/api/authApi'
import { clearCurrentUserPresence, setCurrentUserPresence } from '@/api/presenceApi'
import ToastNotification from '@/components/ToastNotification.vue'
import { useAuthStore } from '@/stores/auth'

const router = useRouter()
const route = useRoute()
const authStore = useAuthStore()

const isAuthenticated = computed(() => !!authStore.user)
const showAppNav = computed(
  () => isAuthenticated.value && route.name === 'home',
)
const isAuthPage = computed(() =>
  ['login', 'signup', 'forgot-password'].includes(route.name),
)
const brandTarget = computed(() => (isAuthenticated.value ? '/home' : '/login'))

watch(
  () => route.name,
  async (nextRouteName) => {
    if (!authStore.user?.id) {
      return
    }

    if (nextRouteName === 'shop' || nextRouteName === 'mypage') {
      await setCurrentUserPresence({
        userId: authStore.user.id,
        nickname: authStore.user.nickname,
        canReceiveWhisper: false,
      })
    }
  },
  { immediate: true },
)

async function logout() {
  await clearCurrentUserPresence()
  await logoutUser()
  router.push('/login')
}
</script>

<template>
  <ToastNotification />
  <header class="app-header" :class="{ 'auth-header': isAuthPage }">
    <RouterLink class="brand" :to="brandTarget">Minigamebox</RouterLink>

    <nav v-if="showAppNav" class="app-nav" aria-label="Main navigation">
      <RouterLink to="/home">Home</RouterLink>
      <RouterLink to="/shop">상점</RouterLink>
      <RouterLink to="/mypage">마이페이지</RouterLink>
      <button type="button" @click="logout">로그아웃</button>
    </nav>
  </header>

  <RouterView v-slot="{ Component }">
    <main class="page-shell" :class="{ 'auth-page-shell': isAuthPage }">
      <Transition name="auth-switch" mode="out-in">
        <component :is="Component" :key="route.fullPath" />
      </Transition>
    </main>
  </RouterView>
</template>

<style scoped>
.app-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 1.5rem;
  padding: 1.25rem 0;
  min-width: 0;
}

.brand {
  color: var(--color-heading);
  flex: 0 0 auto;
  font-size: 1.4rem;
  font-weight: 800;
  letter-spacing: 0;
}

.app-nav {
  display: flex;
  flex-wrap: wrap;
  justify-content: flex-end;
  gap: 0.5rem;
  min-width: 0;
}

.app-nav a,
.app-nav button {
  background: transparent;
  border: 1px solid var(--color-border);
  border-radius: 999px;
  color: var(--color-text);
  cursor: pointer;
  font: inherit;
  padding: 0.45rem 0.8rem;
  white-space: nowrap;
}

.app-nav a.router-link-exact-active {
  background: var(--color-heading);
  border-color: var(--color-heading);
  color: var(--color-background);
}

.page-shell {
  padding: 2rem 0 4rem;
  min-width: 0;
}

.app-header.auth-header {
  left: clamp(0.75rem, 2vw, 1.5rem);
  position: absolute;
  right: clamp(0.75rem, 2vw, 1.5rem);
  top: 0;
  z-index: 2;
}

.auth-page-shell {
  padding: 0;
}

.auth-switch-enter-active,
.auth-switch-leave-active {
  transition:
    opacity 0.24s ease,
    transform 0.24s ease;
}

.auth-switch-enter-from,
.auth-switch-leave-to {
  opacity: 0;
  transform: translateY(8px);
}

@media (prefers-reduced-motion: reduce) {
  .auth-switch-enter-active,
  .auth-switch-leave-active {
    transition: none;
  }
}

@media (max-width: 720px) {
  .app-header {
    align-items: flex-start;
    flex-direction: column;
  }

  .app-nav {
    justify-content: flex-start;
  }
}

@media (max-width: 460px) {
  .app-nav {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    width: 100%;
  }

  .app-nav a,
  .app-nav button {
    text-align: center;
  }
}
</style>
