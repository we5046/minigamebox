<template>
  <div class="auth-layout">
    <div class="auth-glow auth-glow-one" aria-hidden="true"></div>
    <div class="auth-glow auth-glow-two" aria-hidden="true"></div>
    <slot />
  </div>
</template>

<style scoped>
.auth-layout {
  display: flex;
  align-items: center;
  justify-content: center;
  min-height: 100vh;
  overflow: hidden;
  padding: clamp(5.5rem, 10vw, 7rem) 0;
  position: relative;
}

.auth-glow {
  border-radius: 50%;
  filter: blur(10px);
  opacity: 0.08;
  pointer-events: none;
  position: absolute;
}

.auth-glow-one {
  animation: drift-one 16s ease-in-out infinite alternate;
  background: #4967d7;
  height: min(52vw, 620px);
  left: -12%;
  top: 4%;
  width: min(52vw, 620px);
}

.auth-glow-two {
  animation: drift-two 19s ease-in-out infinite alternate;
  background: #d98b47;
  bottom: -20%;
  height: min(44vw, 520px);
  right: -8%;
  width: min(44vw, 520px);
}

.auth-layout :deep(.auth-card) {
  animation: auth-card-enter 0.55s cubic-bezier(0.22, 1, 0.36, 1) both;
  backdrop-filter: blur(18px);
  background:
    linear-gradient(145deg, rgba(255, 255, 255, 0.13), rgba(255, 255, 255, 0.045)),
    rgba(16, 23, 38, 0.76);
  box-shadow:
    0 24px 80px rgba(0, 0, 0, 0.34),
    inset 0 1px 0 rgba(255, 255, 255, 0.08);
  position: relative;
  width: min(100%, 560px);
  z-index: 1;
}

.auth-layout :deep(input) {
  outline: none;
  transition:
    border-color 0.22s ease,
    box-shadow 0.22s ease,
    transform 0.22s ease;
}

.auth-layout :deep(input:focus) {
  border-color: rgba(255, 190, 85, 0.86);
  box-shadow:
    0 0 0 3px rgba(255, 190, 85, 0.12),
    0 8px 22px rgba(0, 0, 0, 0.2);
  transform: translateY(-1px);
}

.auth-layout :deep(button) {
  transition:
    box-shadow 0.22s ease,
    filter 0.22s ease,
    transform 0.22s ease;
}

.auth-layout :deep(button:not(:disabled):hover) {
  box-shadow: 0 10px 26px rgba(255, 190, 85, 0.22);
  filter: brightness(1.08);
  transform: translateY(-2px);
}

.auth-layout :deep(button:not(:disabled):active) {
  box-shadow: 0 5px 14px rgba(255, 190, 85, 0.18);
  transform: translateY(0);
}

@keyframes auth-card-enter {
  from {
    opacity: 0;
    transform: translateY(20px) scale(0.98);
  }

  to {
    opacity: 1;
    transform: translateY(0) scale(1);
  }
}

@keyframes drift-one {
  from {
    transform: translate3d(-3%, -2%, 0) scale(1);
  }

  to {
    transform: translate3d(8%, 6%, 0) scale(1.08);
  }
}

@keyframes drift-two {
  from {
    transform: translate3d(4%, 5%, 0) scale(1.05);
  }

  to {
    transform: translate3d(-8%, -5%, 0) scale(0.96);
  }
}

@media (max-width: 680px) {
  .auth-layout {
    padding-inline: 0.25rem;
  }
}

@media (prefers-reduced-motion: reduce) {
  .auth-glow,
  .auth-layout :deep(.auth-card) {
    animation: none;
  }

  .auth-layout :deep(input),
  .auth-layout :deep(button) {
    transition: none;
  }
}
</style>
