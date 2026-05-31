<script setup>
import { computed, onMounted, ref, watch } from 'vue'
import { useAuthStore } from '@/stores/auth'
import { useProfileStore } from '@/stores/profile'
import { useToastStore } from '@/stores/toast'
import GameSettingsModal from '@/components/GameSettingsModal.vue'

const authStore = useAuthStore()
const profileStore = useProfileStore()
const toastStore = useToastStore()
const savedUser = computed(() => authStore.user)
const profile = computed(() => profileStore.profile)
const stats = computed(() => profileStore.stats)
const roleRecords = computed(() => profileStore.roleRecords)
const recentMatches = computed(() => profileStore.recentMatches)
const achievements = computed(() => profileStore.achievements)
const cosmetics = computed(() => profileStore.cosmetics)

const isSettingsOpen = ref(false)
const isLoading = ref(true)

const myPageSettingsSections = [
  {
    title: '계정',
    items: ['닉네임 변경', '비밀번호 변경', '대표 칭호 변경'],
  },
  {
    title: '꾸미기',
    items: ['닉네임 색상 변경', '프로필 테두리 변경', '프로필 배경 변경'],
  },
]

const settingSections = [
  { title: '계정', items: ['닉네임 변경', '비밀번호 변경', '대표 칭호 변경'] },
  { title: '오디오', items: ['BGM 음량', '효과음 음량'] },
  { title: '표현', items: ['채팅 효과 ON/OFF', '배경 애니메이션 ON/OFF', '저사양 모드'] },
  { title: '꾸미기', items: ['닉네임 색상 변경', '프로필 테두리 변경'] },
  { title: '접근성', items: ['색약 모드', '폰트 크기 조절'] },
]

async function loadData() {
  if (!savedUser.value?.id) {
    profileStore.resetProfile()
    isLoading.value = false
    return
  }

  isLoading.value = true
  await profileStore.reloadProfile(savedUser.value.id)
  isLoading.value = false
}

async function handleSettingSelect({ item }) {
  try {
    if (item === '닉네임 변경') {
      const nextNickname = window.prompt('새 닉네임을 입력하세요.', profile.value.nickname)
      if (!nextNickname?.trim()) return
      await profileStore.updateProfileFields({ nickname: nextNickname })
      toastStore.success('닉네임을 저장했습니다.')
      return
    }

    if (item === '대표 칭호 변경') {
      const nextTitle = window.prompt(
        '대표 칭호를 입력하세요.',
        profile.value.representativeTitle || profile.value.title,
      )
      if (!nextTitle?.trim()) return
      await profileStore.updateProfileFields({ representativeTitle: nextTitle })
      toastStore.success('대표 칭호를 저장했습니다.')
      return
    }

    if (item === '닉네임 색상 변경') {
      const nextValue = window.prompt('닉네임 색상 값을 입력하세요.', 'red')
      if (!nextValue?.trim()) return
      await profileStore.updateCosmetic('닉네임 색상', nextValue.trim(), 4)
      toastStore.success('닉네임 색상을 저장했습니다.')
      return
    }

    if (item === '프로필 테두리 변경') {
      const nextValue = window.prompt('프로필 테두리 값을 입력하세요.', '기본 테두리')
      if (!nextValue?.trim()) return
      await profileStore.updateCosmetic('프로필 테두리', nextValue.trim(), 1)
      toastStore.success('프로필 테두리를 저장했습니다.')
      return
    }

    if (item === '프로필 배경 변경') {
      const nextValue = window.prompt('프로필 배경 값을 입력하세요.', '기본 배경')
      if (!nextValue?.trim()) return
      await profileStore.updateCosmetic('프로필 배경', nextValue.trim(), 2)
      toastStore.success('프로필 배경을 저장했습니다.')
      return
    }

    if (item === '비밀번호 변경') {
      toastStore.error('비밀번호 변경은 별도 인증 흐름이 필요합니다.')
    }
  } catch (error) {
    toastStore.error(error.message)
  }
}

onMounted(() => {
  loadData()
})

watch(savedUser, (nextUser, previousUser) => {
  if (nextUser?.id === previousUser?.id) {
    return
  }

  loadData()
})
</script>

<template>
  <section class="mypage">
    <header class="mypage-top">
      <div>
        <p class="eyebrow">Personal Dossier</p>
        <h1>마이페이지</h1>
      </div>
    </header>

    <p v-if="isLoading" class="loading-state">프로필 정보를 불러오는 중입니다.</p>

    <template v-else>
      <section class="profile-card page-card">
        <div class="profile-fog" aria-hidden="true"></div>
        <button
          type="button"
          class="settings-icon-button"
          aria-label="설정"
          title="설정"
          @click="isSettingsOpen = true"
        >
          <svg viewBox="0 0 512 512" aria-hidden="true" focusable="false">
            <path
              d="M487.4 315.7l-42.6-24.6c4.3-23.2 4.3-47 0-70.2l42.6-24.6c4.9-2.8 7.1-8.6 5.5-14-11.1-35.6-30-67.8-54.7-94.6-3.8-4.1-10-5.1-14.8-2.3l-42.6 24.6c-18-15.2-38.6-27.1-60.8-35.1V25.8c0-5.6-3.9-10.5-9.4-11.7-36.7-8.2-74.3-7.8-109.2 0-5.5 1.2-9.4 6.1-9.4 11.7v49.2c-22.2 8-42.8 19.9-60.8 35.1L88.6 85.5c-4.9-2.8-11-1.9-14.8 2.3-24.7 26.7-43.6 58.9-54.7 94.6-1.7 5.4.6 11.2 5.5 14l42.6 24.6c-4.3 23.2-4.3 47 0 70.2l-42.6 24.6c-4.9 2.8-7.1 8.6-5.5 14 11.1 35.6 30 67.8 54.7 94.6 3.8 4.1 10 5.1 14.8 2.3l42.6-24.6c18 15.2 38.6 27.1 60.8 35.1v49.2c0 5.6 3.9 10.5 9.4 11.7 36.7 8.2 74.3 7.8 109.2 0 5.5-1.2 9.4-6.1 9.4-11.7v-49.2c22.2-8 42.8-19.9 60.8-35.1l42.6 24.6c4.9 2.8 11 1.9 14.8-2.3 24.7-26.7 43.6-58.9 54.7-94.6 1.6-5.4-.6-11.2-5.5-14zM256 336c-44.1 0-80-35.9-80-80s35.9-80 80-80 80 35.9 80 80-35.9 80-80 80z"
            />
          </svg>
        </button>
        <div class="avatar-wrap">
          <div class="avatar">{{ profile.nickname.slice(0, 1).toUpperCase() }}</div>
        </div>

        <div class="profile-info">
          <p class="eyebrow">Current Identity</p>
          <h2>{{ profile.nickname }}</h2>
          <p class="title-badge">{{ profile.title }}</p>
          <blockquote>{{ profile.quote }}</blockquote>
          <div class="level-row">
            <span>Lv. {{ profile.level }}</span>
            <span>{{ profile.exp }}%</span>
          </div>
          <div class="exp-bar" aria-label="experience">
            <span :style="{ width: `${profile.exp}%` }"></span>
          </div>
        </div>

      </section>

      <section class="stats-grid">
        <article v-for="stat in stats" :key="stat.label" class="stat-card page-card">
          <span>{{ stat.label }}</span>
          <strong>{{ stat.value }}</strong>
        </article>
      </section>

      <section class="content-grid">
        <article class="page-card role-card">
          <div class="section-title">
            <p class="eyebrow">Roles</p>
            <h2>역할별 기록</h2>
          </div>
          <div class="role-list">
            <div v-for="role in roleRecords" :key="role.role" class="role-row" :class="{ featured: role.featured }">
              <span class="role-icon">{{ role.icon }}</span>
              <div class="role-copy">
                <strong>{{ role.role }}</strong>
                <p>{{ role.games }}회 플레이</p>
                <div class="role-progress">
                  <span :style="{ width: `${role.winRate}%` }"></span>
                </div>
              </div>
              <span class="role-rate">{{ role.winRate }}%</span>
            </div>
          </div>
        </article>

        <article class="page-card recent-card">
          <div class="section-title">
            <p class="eyebrow">Recent</p>
            <h2>최근 전적</h2>
          </div>
        <div class="match-list">
          <p v-if="recentMatches.length === 0" class="empty-state">아직 기록된 최근 전적이 없습니다.</p>
          <div v-for="match in recentMatches" :key="match.id" class="match-row" :class="{ won: match.won }">
              <span class="result">{{ match.result }}</span>
              <span class="role-icon small">{{ match.icon }}</span>
              <strong>{{ match.role }}</strong>
              <p>{{ match.summary }}</p>
              <small>{{ match.detail }}</small>
            </div>
          </div>
        </article>

        <article class="page-card achievement-card">
          <div class="section-title">
            <p class="eyebrow">Badges</p>
            <h2>업적 및 칭호</h2>
          </div>
        <div class="achievement-grid">
          <p v-if="achievements.length === 0" class="empty-state">아직 획득한 업적이 없습니다.</p>
          <div
              v-for="item in achievements"
              :key="item.name"
              class="achievement"
              :class="[{ locked: !item.unlocked }, item.rarity.toLowerCase()]"
            >
              <span>{{ item.icon }}</span>
              <strong>{{ item.name }}</strong>
              <small>{{ item.rarity }} · {{ item.date }}</small>
              <p class="tooltip">{{ item.description }}</p>
            </div>
          </div>
        </article>

        <article class="page-card cosmetic-card">
          <div class="section-title">
            <p class="eyebrow">Cosmetics</p>
            <h2>꾸미기</h2>
          </div>
          <div class="cosmetic-preview">
            <div class="mini-profile">{{ profile.nickname.slice(0, 1).toUpperCase() }}</div>
            <div>
              <strong class="preview-name">{{ profile.nickname }}</strong>
              <p>오늘 밤, 누가 거짓말을 하고 있을까?</p>
            </div>
          </div>
          <ul>
            <li v-for="item in cosmetics" :key="item.label">
              <span>{{ item.label }}</span>
              <strong>{{ item.value }}</strong>
            </li>
          </ul>
        </article>
      </section>
    </template>

    <GameSettingsModal
      v-model="isSettingsOpen"
      title="마이페이지 설정"
      :extra-sections="myPageSettingsSections"
      @select="handleSettingSelect"
    />
  </section>
</template>

<style scoped>
.mypage {
  --panel-shadow: 0 24px 70px rgba(0, 0, 0, 0.34);
  display: grid;
  gap: 1rem;
}

.mypage :deep(.page-card),
.mypage .page-card {
  box-shadow: var(--panel-shadow);
}

.mypage-top {
  align-items: center;
  display: grid;
  gap: 1rem;
  grid-template-columns: minmax(0, 1fr);
}

.loading-state {
  color: rgba(255, 245, 224, 0.68);
}

.empty-state {
  color: rgba(255, 245, 224, 0.6);
  margin: 0;
}

.eyebrow {
  color: #f87171;
  font-size: 0.78rem;
  font-weight: 900;
  letter-spacing: 0.12em;
  text-transform: uppercase;
}

h1,
h2,
h3 {
  color: var(--color-heading);
  font-weight: 900;
}

h1 {
  font-size: clamp(2.4rem, 6vw, 4.8rem);
  line-height: 0.95;
}

.ghost-button,
.settings-modal button {
  background: rgba(255, 255, 255, 0.06);
  border: 1px solid rgba(248, 113, 113, 0.35);
  border-radius: 0.8rem;
  color: var(--color-text);
  cursor: pointer;
  font: inherit;
  padding: 0.75rem 1rem;
  transition: transform 0.16s ease, border-color 0.16s ease, background 0.16s ease;
}

.ghost-button:hover,
.settings-modal button:hover {
  background: rgba(248, 113, 113, 0.12);
  border-color: rgba(248, 113, 113, 0.64);
  transform: translateY(-2px);
}

.ghost-button:active,
.settings-modal button:active {
  transform: translateY(0) scale(0.98);
}

.ghost-button.strong {
  border-color: rgba(192, 132, 252, 0.52);
}

.profile-card {
  align-items: center;
  display: grid;
  gap: 1.25rem;
  grid-template-columns: auto minmax(0, 1fr);
  overflow: hidden;
  position: relative;
}

.settings-icon-button {
  align-items: center;
  background: rgba(255, 255, 255, 0.08);
  border: 1px solid rgba(192, 132, 252, 0.45);
  border-radius: 999px;
  box-shadow: 0 0 22px rgba(168, 85, 247, 0.18);
  color: #f5d0fe;
  cursor: pointer;
  display: flex;
  height: 2.75rem;
  justify-content: center;
  padding: 0;
  position: absolute;
  right: 1.15rem;
  top: 1.15rem;
  transition: transform 0.18s ease, border-color 0.18s ease, background 0.18s ease, box-shadow 0.18s ease;
  width: 2.75rem;
  z-index: 2;
}

.settings-icon-button svg {
  fill: currentColor;
  height: 1.05rem;
  width: 1.05rem;
}

.settings-icon-button:hover {
  background: rgba(168, 85, 247, 0.16);
  border-color: rgba(216, 180, 254, 0.75);
  box-shadow: 0 0 30px rgba(168, 85, 247, 0.32);
  transform: translateY(-2px) rotate(18deg);
}

.settings-icon-button:active {
  transform: translateY(0) scale(0.96) rotate(18deg);
}

.profile-fog {
  animation: fog-drift 9s ease-in-out infinite alternate;
  background:
    radial-gradient(circle at 10% 20%, rgba(248, 113, 113, 0.16), transparent 18rem),
    radial-gradient(circle at 82% 38%, rgba(168, 85, 247, 0.18), transparent 20rem);
  inset: -30%;
  opacity: 0.7;
  pointer-events: none;
  position: absolute;
}

.avatar-wrap,
.profile-info {
  position: relative;
  z-index: 1;
}

.avatar-wrap {
  display: grid;
  gap: 0.75rem;
  justify-items: center;
}

.avatar,
.mini-profile {
  align-items: center;
  background: radial-gradient(circle at 35% 25%, #fca5a5, #7f1d1d 48%, #14090b);
  border: 3px solid #ef4444;
  border-radius: 50%;
  box-shadow: 0 0 28px rgba(239, 68, 68, 0.38);
  color: #fff7ed;
  display: flex;
  font-size: 3.5rem;
  font-weight: 900;
  height: 8.5rem;
  justify-content: center;
  width: 8.5rem;
}

.online-dot,
.title-badge {
  border: 1px solid rgba(192, 132, 252, 0.42);
  border-radius: 999px;
  color: #c084fc;
  padding: 0.35rem 0.7rem;
}

.profile-info {
  display: grid;
  gap: 0.7rem;
  min-width: 0;
}

.profile-info h2 {
  font-size: clamp(2rem, 5vw, 3.8rem);
}

blockquote {
  border-left: 3px solid rgba(248, 113, 113, 0.55);
  color: rgba(255, 245, 224, 0.72);
  font-style: italic;
  margin: 0;
  padding-left: 0.9rem;
}

.level-row {
  display: flex;
  justify-content: space-between;
  max-width: 28rem;
}

.exp-bar,
.role-progress {
  background: rgba(255, 255, 255, 0.08);
  border-radius: 999px;
  overflow: hidden;
}

.exp-bar {
  height: 0.75rem;
  max-width: 28rem;
}

.exp-bar span,
.role-progress span {
  background: linear-gradient(90deg, #ef4444, #a855f7);
  display: block;
  height: 100%;
}

.stats-grid {
  display: grid;
  gap: 1rem;
  grid-template-columns: repeat(6, minmax(0, 1fr));
}

.stat-card {
  display: grid;
  gap: 0.45rem;
  min-height: 8rem;
  transition: transform 0.2s ease, border-color 0.2s ease, box-shadow 0.2s ease;
}

.stat-card:hover,
.role-row:hover,
.achievement:hover,
.match-row:hover {
  border-color: rgba(248, 113, 113, 0.5);
  box-shadow: 0 0 26px rgba(248, 113, 113, 0.14);
  transform: translateY(-3px);
}

.stat-card span,
.role-row p,
.match-row p,
.cosmetic-card li span {
  color: rgba(255, 245, 224, 0.62);
}

.stat-card strong {
  color: var(--color-heading);
  font-size: 2rem;
  font-weight: 900;
}

.content-grid {
  display: grid;
  gap: 1rem;
  grid-template-columns: repeat(2, minmax(0, 1fr));
}

.role-card,
.recent-card,
.achievement-card,
.cosmetic-card {
  display: grid;
  gap: 1rem;
}

.role-list,
.match-list,
.cosmetic-card ul {
  display: grid;
  gap: 0.75rem;
  list-style: none;
  margin: 0;
  padding: 0;
}

.role-row,
.match-row,
.cosmetic-card li {
  background: rgba(255, 255, 255, 0.07);
  border: 1px solid var(--color-border);
  border-radius: 0.9rem;
  display: grid;
  gap: 0.65rem;
  padding: 0.85rem;
  transition: transform 0.2s ease, border-color 0.2s ease, box-shadow 0.2s ease;
}

.role-row {
  grid-template-columns: auto minmax(0, 1fr) auto;
}

.role-row.featured {
  border-color: rgba(192, 132, 252, 0.56);
  box-shadow: 0 0 24px rgba(168, 85, 247, 0.18);
}

.role-icon,
.achievement span {
  align-items: center;
  background: rgba(239, 68, 68, 0.14);
  border: 1px solid rgba(239, 68, 68, 0.35);
  border-radius: 0.8rem;
  color: #fca5a5;
  display: flex;
  font-weight: 900;
  height: 2.5rem;
  justify-content: center;
  width: 2.5rem;
}

.role-progress {
  height: 0.45rem;
  margin-top: 0.35rem;
}

.role-rate {
  color: #fca5a5;
  font-weight: 900;
}

.match-row {
  grid-template-columns: 4rem auto 4rem minmax(0, 1fr);
  position: relative;
}

.match-row .result {
  color: #f87171;
  font-weight: 900;
}

.match-row.won .result {
  color: #86efac;
}

.match-row small {
  background: rgba(20, 17, 15, 0.96);
  border: 1px solid rgba(248, 113, 113, 0.28);
  border-radius: 0.75rem;
  color: rgba(255, 245, 224, 0.76);
  left: 1rem;
  opacity: 0;
  padding: 0.65rem 0.75rem;
  pointer-events: none;
  position: absolute;
  right: 1rem;
  top: calc(100% - 0.2rem);
  transform: translateY(-0.4rem);
  transition: opacity 0.18s ease, transform 0.18s ease;
  z-index: 3;
}

.match-row:hover small {
  opacity: 1;
  transform: translateY(0);
}

.role-icon.small {
  height: 2rem;
  width: 2rem;
}

.achievement-grid {
  display: grid;
  gap: 0.75rem;
  grid-template-columns: repeat(4, minmax(0, 1fr));
}

.achievement {
  background: rgba(255, 255, 255, 0.07);
  border: 1px solid var(--color-border);
  border-radius: 1rem;
  display: grid;
  gap: 0.5rem;
  justify-items: center;
  min-height: 10rem;
  padding: 1rem;
  position: relative;
  text-align: center;
  transition: transform 0.2s ease, border-color 0.2s ease, box-shadow 0.2s ease;
}

.achievement.epic,
.achievement.legendary {
  border-color: rgba(192, 132, 252, 0.4);
}

.achievement.locked {
  filter: grayscale(1);
  opacity: 0.42;
}

.tooltip {
  background: rgba(20, 17, 15, 0.96);
  border: 1px solid rgba(192, 132, 252, 0.36);
  border-radius: 0.75rem;
  bottom: calc(100% - 0.4rem);
  color: rgba(255, 245, 224, 0.78);
  left: 0.5rem;
  opacity: 0;
  padding: 0.65rem;
  pointer-events: none;
  position: absolute;
  right: 0.5rem;
  transform: translateY(0.35rem);
  transition: opacity 0.18s ease, transform 0.18s ease;
  z-index: 4;
}

.achievement:hover .tooltip {
  opacity: 1;
  transform: translateY(0);
}

.cosmetic-preview {
  align-items: center;
  background: linear-gradient(135deg, rgba(127, 29, 29, 0.34), rgba(88, 28, 135, 0.28));
  border: 1px solid rgba(248, 113, 113, 0.22);
  border-radius: 1rem;
  display: flex;
  gap: 0.9rem;
  padding: 1rem;
}

.mini-profile {
  border-width: 2px;
  font-size: 1.4rem;
  height: 3.5rem;
  width: 3.5rem;
}

.preview-name {
  color: #c084fc;
}

.cosmetic-card li {
  align-items: center;
  grid-template-columns: minmax(0, 1fr) auto;
}

.modal-backdrop {
  align-items: center;
  background: rgba(0, 0, 0, 0.72);
  display: flex;
  inset: 0;
  justify-content: center;
  padding: 1rem;
  position: fixed;
  z-index: 20;
}

.settings-modal {
  background:
    linear-gradient(135deg, rgba(255, 255, 255, 0.1), rgba(255, 255, 255, 0.03)),
    #171114;
  border: 1px solid rgba(248, 113, 113, 0.32);
  border-radius: 1.4rem;
  box-shadow: 0 32px 90px rgba(0, 0, 0, 0.62);
  display: grid;
  gap: 1rem;
  max-height: min(86vh, 760px);
  max-width: 860px;
  overflow: auto;
  padding: clamp(1rem, 3vw, 1.5rem);
  width: min(100%, 860px);
}

.settings-modal header {
  align-items: center;
  display: flex;
  gap: 1rem;
  justify-content: space-between;
}

.settings-grid {
  display: grid;
  gap: 1rem;
  grid-template-columns: repeat(2, minmax(0, 1fr));
}

.settings-grid article {
  background: rgba(255, 255, 255, 0.06);
  border: 1px solid var(--color-border);
  border-radius: 1rem;
  display: grid;
  gap: 0.6rem;
  padding: 1rem;
}

.settings-grid button {
  text-align: left;
}

.mypage *::-webkit-scrollbar,
.settings-modal::-webkit-scrollbar {
  width: 0.55rem;
}

.mypage *::-webkit-scrollbar-thumb,
.settings-modal::-webkit-scrollbar-thumb {
  background: rgba(248, 113, 113, 0.45);
  border-radius: 999px;
}

@keyframes fog-drift {
  from {
    transform: translate3d(-1.5%, -1%, 0) scale(1);
  }
  to {
    transform: translate3d(1.5%, 1%, 0) scale(1.04);
  }
}

@media (max-width: 1180px) {
  .stats-grid {
    grid-template-columns: repeat(3, minmax(0, 1fr));
  }
}

@media (max-width: 900px) {
  .mypage-top,
  .profile-card,
  .content-grid,
  .settings-grid {
    grid-template-columns: 1fr;
  }

  .stats-grid,
  .achievement-grid {
    grid-template-columns: repeat(2, minmax(0, 1fr));
  }
}

@media (max-width: 560px) {
  .stats-grid,
  .achievement-grid,
  .role-row,
  .match-row,
  .cosmetic-card li {
    grid-template-columns: 1fr;
  }

  .ghost-button {
    width: 100%;
  }

  .settings-modal header {
    align-items: flex-start;
    flex-direction: column;
  }
}
</style>
