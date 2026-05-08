<script setup>
import { RouterLink, RouterView } from 'vue-router'
</script>

<template>
  <header class="app-header">
    <RouterLink class="brand" to="/home">Mafia Night</RouterLink>

    <nav class="app-nav" aria-label="Main navigation">
      <RouterLink to="/home">Home</RouterLink>
      <RouterLink to="/login">로그인</RouterLink>
      <RouterLink to="/signup">회원가입</RouterLink>
      <RouterLink to="/rooms/1">게임 방</RouterLink>
      <RouterLink to="/shop">상점</RouterLink>
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
}

.brand {
  color: var(--color-heading);
  font-size: 1.4rem;
  font-weight: 800;
  letter-spacing: -0.04em;
}

.app-nav {
  display: flex;
  flex-wrap: wrap;
  justify-content: flex-end;
  gap: 0.5rem;
}

.app-nav a {
  border: 1px solid var(--color-border);
  border-radius: 999px;
  color: var(--color-text);
  padding: 0.45rem 0.8rem;
}

.app-nav a.router-link-exact-active {
  background: var(--color-heading);
  border-color: var(--color-heading);
  color: var(--color-background);
}

.page-shell {
  padding: 2rem 0 4rem;
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
</style>
