<script setup>
import { ref } from 'vue'
import { RouterLink, useRouter } from 'vue-router'
import { signupUser } from '@/api/authApi'
import { useToastStore } from '@/stores/toast'

const router = useRouter()
const toastStore = useToastStore()
const loginId = ref('')
const nickname = ref('')
const password = ref('')
const passwordConfirm = ref('')
const isLoading = ref(false)

async function signup() {
  if (!loginId.value.trim() || !nickname.value.trim() || !password.value || !passwordConfirm.value) {
    toastStore.error('모든 항목을 입력하세요.')
    return
  }

  if (password.value !== passwordConfirm.value) {
    toastStore.error('비밀번호가 일치하지 않습니다.')
    return
  }

  isLoading.value = true

  try {
    await signupUser({
      loginId: loginId.value.trim(),
      nickname: nickname.value.trim(),
      password: password.value,
    })
    toastStore.success('회원가입이 완료되었습니다. 로그인해주세요.')
    router.push('/login')
  } catch (error) {
    toastStore.error(error.message)
  } finally {
    isLoading.value = false
  }
}
</script>

<template>
  <section class="page-card auth-card">
    <p class="eyebrow">Sign Up</p>
    <h1>회원가입</h1>

    <form class="form" @submit.prevent="signup">
      <label>
        로그인 ID
        <input v-model="loginId" type="text" placeholder="로그인에 사용할 ID" />
      </label>

      <label>
        게임 닉네임
        <input v-model="nickname" type="text" placeholder="게임에서 표시될 이름" />
      </label>

      <label>
        비밀번호
        <input v-model="password" type="password" placeholder="비밀번호" />
      </label>

      <label>
        비밀번호 확인
        <input v-model="passwordConfirm" type="password" placeholder="비밀번호 확인" />
      </label>

      <button type="submit" :disabled="isLoading">
        {{ isLoading ? '저장 중...' : '계정 만들기' }}
      </button>

      <RouterLink class="sub-link" to="/login">이미 계정이 있다면 로그인</RouterLink>
    </form>
  </section>
</template>

<style scoped>
.auth-card {
  max-width: 560px;
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

.sub-link {
  color: var(--color-accent);
  justify-self: start;
}
</style>
