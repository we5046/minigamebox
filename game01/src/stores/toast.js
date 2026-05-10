import { defineStore } from 'pinia'
import { ref } from 'vue'

export const useToastStore = defineStore('toast', () => {
  const toasts = ref([])
  let nextId = 0

  function addToast(message, type = 'info', duration = 3000) {
    const id = nextId++
    toasts.value.push({ id, message, type })
    setTimeout(() => {
      removeToast(id)
    }, duration)
  }

  function removeToast(id) {
    toasts.value = toasts.value.filter(t => t.id !== id)
  }

  function error(message, duration = 3000) {
    addToast(message, 'error', duration)
  }

  function success(message, duration = 3000) {
    addToast(message, 'success', duration)
  }

  function info(message, duration = 3000) {
    addToast(message, 'info', duration)
  }

  return { toasts, addToast, removeToast, error, success, info }
})
