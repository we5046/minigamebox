<script setup>
import { ref } from 'vue'
import { RouterLink, useRouter } from 'vue-router'
import { loginUser } from '@/api/authApi'
import { useAuthStore } from '@/stores/auth'
import { useToastStore } from '@/stores/toast'

const router = useRouter()
const authStore = useAuthStore()
const toastStore = useToastStore()
const loginId = ref('')
const password = ref('')
const isLoading = ref(false)

async function login() {
  if (!loginId.value.trim() || !password.value) {
    toastStore.error('로그인 ID와 비밀번호를 입력하세요.')
    return
  }

  isLoading.value = true

  try {
    const currentUser = await loginUser({
      loginId: loginId.value.trim(),
      password: password.value,
    })
    authStore.setUser(currentUser)
    toastStore.success('로그인 되었습니다.')
    router.replace({ name: 'home' })
  } catch (error) {
    toastStore.error(error.message)
  } finally {
    isLoading.value = false
  }
}
</script>

<template>
  <section class="page-card auth-card">
    <p class="eyebrow">Login</p>
    <h1>로그인</h1>

    <form class="form" @submit.prevent="login">
      <label>
        로그인 ID
        <input v-model="loginId" type="text" placeholder="로그인 ID를 입력하세요" />
      </label>

      <label>
        비밀번호
        <input v-model="password" type="password" placeholder="비밀번호를 입력하세요" />
      </label>

      <button type="submit" :disabled="isLoading">
        {{ isLoading ? '확인 중...' : '로그인' }}
      </button>

      <div class="links">
        <RouterLink class="sub-link" to="/signup">아직 계정이 없다면 회원가입</RouterLink>
        <RouterLink class="sub-link" to="/forgot-password">비밀번호 찾기</RouterLink>
      </div>
    </form>
  </section>
</template>

<style scoped>
.auth-card {
  max-width: 520px;
}

.eyebrow {
  color: var(--color-accent);
  font-weight: 800;
}

h1 {
  color: var(--color-heading);
  font-size: 2.5rem;
  font-weight: 900;
}

.form {
  display: grid;
  gap: 1rem;
  margin-top: 1.5rem;
}

label {
  display: grid;
  gap: 0.4rem;
  font-weight: 700;
}

input {
  background: rgba(255, 255, 255, 0.08);
  border: 1px solid var(--color-border);
  border-radius: 0.8rem;
  color: var(--color-text);
  padding: 0.9rem 1rem;
}

button {
  background: var(--color-accent);
  border: 0;
  border-radius: 0.8rem;
  color: #14110f;
  cursor: pointer;
  font-weight: 900;
  padding: 0.9rem 1rem;
}

button:disabled {
  cursor: wait;
  opacity: 0.7;
}

.message {
  color: #ff8f70;
  font-weight: 700;
}

.links {
  display: flex;
  flex-wrap: wrap;
  gap: 0.75rem;
  justify-content: space-between;
}

.sub-link {
  color: var(--color-accent);
}
</style>
