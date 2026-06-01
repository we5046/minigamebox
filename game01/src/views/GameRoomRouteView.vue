<script setup>
import { computed, onMounted, ref } from 'vue'
import { getRoom } from '@/api/roomApi'
import GameRoomView from './GameRoomView.vue'
import LiarGameRoomView from './LiarGameRoomView.vue'

const props = defineProps({
  roomId: {
    type: String,
    required: true,
  },
})

const room = ref(null)
const loadError = ref('')

const roomComponent = computed(() =>
  room.value?.gameType === 'liar' ? LiarGameRoomView : GameRoomView,
)

onMounted(async () => {
  try {
    room.value = await getRoom(props.roomId)
  } catch (error) {
    loadError.value = error.message
  }
})
</script>

<template>
  <p v-if="loadError" class="route-state">{{ loadError }}</p>
  <p v-else-if="!room" class="route-state">게임방 정보를 불러오는 중입니다.</p>
  <component :is="roomComponent" v-else :room-id="roomId" />
</template>

<style scoped>
.route-state {
  color: rgba(255, 245, 224, 0.7);
  padding: 2rem 0;
  text-align: center;
}
</style>
