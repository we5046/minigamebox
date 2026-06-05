<script setup>
import { computed, onMounted, ref } from 'vue'
import { useRoute } from 'vue-router'
import { getRoom } from '@/api/roomApi'
import GamePlayView from './GamePlayView.vue'
import LiarGamePlayView from './LiarGamePlayView.vue'
import CatchmindGamePlayView from './CatchmindGamePlayView.vue'

const route = useRoute()
const room = ref(null)
const loadError = ref('')
const roomId = computed(() => String(route.params.roomId || ''))
const gameComponent = computed(() => {
  if (room.value?.gameType === 'liar') return LiarGamePlayView
  if (room.value?.gameType === 'catchmind') return CatchmindGamePlayView
  return GamePlayView
})

onMounted(async () => {
  try {
    room.value = await getRoom(roomId.value)
  } catch (error) {
    loadError.value = error.message
  }
})
</script>

<template>
  <p v-if="loadError" class="route-state">{{ loadError }}</p>
  <p v-else-if="!room" class="route-state">게임 정보를 불러오는 중입니다.</p>
  <component :is="gameComponent" v-else />
  <p v-if="!room && !loadError" class="refresh-guide">
    ※ 뭔가 이상하다면 새로고침(F5)을 한번 눌러주세요.
  </p>
</template>

<style scoped>
.route-state {
  color: rgba(255, 245, 224, 0.7);
  padding: 2rem 0;
  text-align: center;
}

.refresh-guide {
  color: rgba(255, 245, 224, 0.62);
  font-size: 0.82rem;
  margin: 0;
  text-align: center;
}
</style>
