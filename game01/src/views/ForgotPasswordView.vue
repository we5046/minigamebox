<script setup>
import { ref } from 'vue'
import { RouterLink, useRouter } from 'vue-router'
import { resetPassword as resetUserPassword } from '@/api/authApi'
import AuthLayout from '@/components/AuthLayout.vue'

const router = useRouter()
const loginId = ref('')
const nickname = ref('')
const newPassword = ref('')
const newPasswordConfirm = ref('')
const message = ref('')
const isSuccess = ref(false)
const isLoading = ref(false)

async function resetPassword() {
  message.value = ''
  isSuccess.value = false

  if (
    !loginId.value.trim() ||
    !nickname.value.trim() ||
    !newPassword.value ||
    !newPasswordConfirm.value
  ) {
    message.value = '모든 항목을 입력하세요.'
    return
  }

  if (newPassword.value !== newPasswordConfirm.value) {
    message.value = '새 비밀번호가 일치하지 않습니다.'
    return
  }

  isLoading.value = true

  try {
    await resetUserPassword({
      loginId: loginId.value.trim(),
      nickname: nickname.value.trim(),
      newPassword: newPassword.value,
    })
    isSuccess.value = true
    message.value = '비밀번호가 새 값으로 갱신되었습니다.'

    window.setTimeout(() => {
      router.push('/login')
    }, 900)
  } catch (error) {
    message.value = error.message
  } finally {
    isLoading.value = false
  }
}
</script>

<template>
  <AuthLayout>
    <section class="page-card auth-card">
    <p class="eyebrow">Password Reset</p>
    <h1>비밀번호 찾기</h1>
    <p class="description">
      현재는 로그인 ID와 게임 닉네임이 모두 일치할 때만 새 비밀번호로 갱신합니다.
    </p>

    <form class="form" @submit.prevent="resetPassword">
      <label>
        로그인 ID
        <input v-model="loginId" type="text" placeholder="로그인 ID" />
      </label>

      <label>
        게임 닉네임
        <input v-model="nickname" type="text" placeholder="게임 닉네임" />
      </label>

      <label>
        새 비밀번호
        <input v-model="newPassword" type="password" placeholder="새 비밀번호" />
      </label>

      <label>
        새 비밀번호 확인
        <input v-model="newPasswordConfirm" type="password" placeholder="새 비밀번호 확인" />
      </label>

      <p v-if="message" class="message" :class="{ success: isSuccess }">{{ message }}</p>

      <button type="submit" :disabled="isLoading">
        {{ isLoading ? '갱신 중...' : '새 비밀번호로 갱신' }}
      </button>

      <RouterLink class="sub-link" to="/login">로그인으로 돌아가기</RouterLink>
    </form>
    </section>
  </AuthLayout>
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

.description {
  margin-top: 0.75rem;
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

.message.success {
  color: #7de39b;
}

.sub-link {
  color: var(--color-accent);
  justify-self: start;
}
</style>
