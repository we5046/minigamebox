<script setup>
import { RouterLink, RouterView, useRouter } from 'vue-router'
import { logoutUser } from '@/api/authApi'

const router = useRouter()

async function logout() {
  await logoutUser()
  router.push('/login')
}
</script>

<template>
  <header class="app-header">
    <RouterLink class="brand" to="/home">Mafia Night</RouterLink>

    <nav class="app-nav" aria-label="Main navigation">
      <RouterLink to="/home">Home</RouterLink>
      <RouterLink to="/shop">상점</RouterLink>
      <RouterLink to="/mypage">마이페이지</RouterLink>
      <button type="button" @click="logout">로그아웃</button>
    </nav>
  </header>

  <RouterView v-slot="{ Component }">
    <main class="page-shell">
      <component :is="Component" />
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
  letter-spacing: -0.04em;
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
