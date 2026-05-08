<template>
  <section class="page-card shop">
    <p class="eyebrow">Shop</p>
    <h1>상점</h1>
    <p>프로필 테두리, 칭호, 이모트 같은 꾸미기 아이템을 판매할 페이지입니다.</p>

    <div class="items">
      <article>
        <strong>검은 망토</strong>
        <span>1,200 coin</span>
      </article>
      <article>
        <strong>탐정 배지</strong>
        <span>900 coin</span>
      </article>
      <article>
        <strong>유령 말풍선</strong>
        <span>700 coin</span>
      </article>
    </div>
  </section>
</template>

<style scoped>
.shop {
  display: grid;
  gap: 1rem;
}

.eyebrow {
  color: var(--color-accent);
  font-weight: 800;
}

h1 {
  color: var(--color-heading);
  font-size: 3rem;
  font-weight: 900;
}

.items {
  display: grid;
  gap: 1rem;
  grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
  margin-top: 1rem;
}

article {
  background: rgba(255, 255, 255, 0.08);
  border: 1px solid var(--color-border);
  border-radius: 1rem;
  display: grid;
  gap: 0.35rem;
  padding: 1rem;
}

strong {
  color: var(--color-heading);
}
</style>
