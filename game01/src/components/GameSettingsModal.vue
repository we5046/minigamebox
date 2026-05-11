<script setup>
const props = defineProps({
  modelValue: {
    type: Boolean,
    default: false,
  },
  title: {
    type: String,
    default: '게임 설정',
  },
  eyebrow: {
    type: String,
    default: 'Settings',
  },
  extraSections: {
    type: Array,
    default: () => [],
  },
})

const emit = defineEmits(['update:modelValue', 'select'])

const baseSections = [
  {
    title: '오디오',
    items: ['BGM 볼륨', '효과음 볼륨', '알림음'],
  },
  {
    title: '화면',
    items: ['채팅 효과', '배경 애니메이션', '저사양 모드'],
  },
  {
    title: '접근성',
    items: ['폰트 크기', '고대비 모드', '모션 줄이기'],
  },
]

function close() {
  emit('update:modelValue', false)
}

function selectItem(section, item) {
  emit('select', { section, item })
}
</script>

<template>
  <Teleport to="body">
    <div v-if="props.modelValue" class="settings-backdrop" @click.self="close">
      <section class="settings-modal" role="dialog" aria-modal="true" aria-labelledby="game-settings-title">
        <header class="settings-header">
          <div>
            <p class="settings-eyebrow">{{ eyebrow }}</p>
            <h2 id="game-settings-title">{{ title }}</h2>
          </div>
          <button type="button" class="settings-close-button" @click="close">닫기</button>
        </header>

        <div class="settings-grid">
          <article v-for="section in baseSections" :key="section.title" class="settings-section">
            <h3>{{ section.title }}</h3>
            <button
              v-for="item in section.items"
              :key="item"
              type="button"
              @click="selectItem(section.title, item)"
            >
              {{ item }}
            </button>
          </article>

          <article v-for="section in extraSections" :key="section.title" class="settings-section">
            <h3>{{ section.title }}</h3>
            <button
              v-for="item in section.items"
              :key="item"
              type="button"
              @click="selectItem(section.title, item)"
            >
              {{ item }}
            </button>
          </article>

          <slot name="extra" :close="close" :select-item="selectItem" />
        </div>
      </section>
    </div>
  </Teleport>
</template>

<style scoped>
.settings-backdrop {
  align-items: center;
  background: rgba(0, 0, 0, 0.72);
  display: flex;
  inset: 0;
  justify-content: center;
  padding: 1rem;
  position: fixed;
  z-index: 50;
}

.settings-modal {
  background:
    linear-gradient(135deg, rgba(255, 255, 255, 0.1), rgba(255, 255, 255, 0.03)),
    #171114;
  border: 1px solid rgba(248, 113, 113, 0.32);
  border-radius: 1rem;
  box-shadow: 0 32px 90px rgba(0, 0, 0, 0.62);
  display: grid;
  gap: 1rem;
  max-height: min(86vh, 760px);
  max-width: 860px;
  overflow: auto;
  padding: clamp(1rem, 3vw, 1.5rem);
  width: min(100%, 860px);
}

.settings-header {
  align-items: center;
  display: flex;
  gap: 1rem;
  justify-content: space-between;
}

.settings-eyebrow {
  color: #f87171;
  font-size: 0.78rem;
  font-weight: 900;
  letter-spacing: 0.12em;
  margin: 0;
  text-transform: uppercase;
}

h2,
h3 {
  color: var(--color-heading);
  font-weight: 900;
  margin: 0;
}

.settings-grid {
  display: grid;
  gap: 1rem;
  grid-template-columns: repeat(2, minmax(0, 1fr));
}

.settings-section {
  background: rgba(255, 255, 255, 0.06);
  border: 1px solid var(--color-border);
  border-radius: 0.8rem;
  display: grid;
  gap: 0.6rem;
  padding: 1rem;
}

.settings-close-button,
.settings-section button {
  background: rgba(255, 255, 255, 0.06);
  border: 1px solid rgba(248, 113, 113, 0.35);
  border-radius: 0.8rem;
  color: var(--color-text);
  cursor: pointer;
  font: inherit;
  padding: 0.75rem 1rem;
  transition:
    background 0.16s ease,
    border-color 0.16s ease,
    transform 0.16s ease;
}

.settings-section button {
  text-align: left;
}

.settings-close-button:hover,
.settings-section button:hover {
  background: rgba(248, 113, 113, 0.12);
  border-color: rgba(248, 113, 113, 0.64);
  transform: translateY(-2px);
}

.settings-close-button:active,
.settings-section button:active {
  transform: translateY(0) scale(0.98);
}

.settings-modal::-webkit-scrollbar {
  width: 0.55rem;
}

.settings-modal::-webkit-scrollbar-thumb {
  background: rgba(248, 113, 113, 0.45);
  border-radius: 999px;
}

@media (max-width: 900px) {
  .settings-grid {
    grid-template-columns: 1fr;
  }
}

@media (max-width: 560px) {
  .settings-header {
    align-items: flex-start;
    flex-direction: column;
  }

  .settings-close-button {
    width: 100%;
  }
}
</style>
