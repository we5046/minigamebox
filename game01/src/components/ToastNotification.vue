<template>
  <div class="toast-container">
    <TransitionGroup name="toast-list">
      <div
        v-for="toast in toastStore.toasts"
        :key="toast.id"
        class="toast"
        :class="`toast-${toast.type}`"
      >
        {{ toast.message }}
      </div>
    </TransitionGroup>
  </div>
</template>

<script setup>
import { useToastStore } from '../stores/toast'

const toastStore = useToastStore()
</script>

<style scoped>
.toast-container {
  position: fixed;
  top: 20px;
  right: 20px;
  z-index: 9999;
  display: flex;
  flex-direction: column;
  gap: 10px;
}

.toast {
  padding: 12px 20px;
  border-radius: 8px;
  color: white;
  font-weight: bold;
  box-shadow: 0 4px 12px rgba(0, 0, 0, 0.5);
  min-width: 200px;
  text-align: center;
}

.toast-info { background-color: #3498db; }
.toast-success { background-color: #2ecc71; }
.toast-error { background-color: #e74c3c; }

.toast-list-enter-active,
.toast-list-leave-active {
  transition: all 0.3s ease;
}
.toast-list-enter-from {
  opacity: 0;
  transform: translateX(30px);
}
.toast-list-leave-to {
  opacity: 0;
  transform: translateY(-30px);
}
</style>
