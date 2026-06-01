<script setup>
import { computed, onMounted, ref } from 'vue'
import { useRoute } from 'vue-router'
import { getRoom } from '@/api/roomApi'
import GamePlayView from './GamePlayView.vue'
import LiarGamePlayView from './LiarGamePlayView.vue'

const route = useRoute()
const room = ref(null)
const loadError = ref('')
const roomId = computed(() => String(route.params.roomId || ''))
const gameComponent = computed(() =>
  room.value?.gameType === 'liar' ? LiarGamePlayView : GamePlayView,
)

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
</template>

<style scoped>
.route-state {
  color: rgba(255, 245, 224, 0.7);
  padding: 2rem 0;
  text-align: center;
}
</style>
