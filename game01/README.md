# game01

This template should help get you started developing with Vue 3 in Vite.

## Game modes

- 마피아 게임
- 라이어 게임
- 캐치마인드

캐치마인드는 한 명의 출제자가 제시된 단어를 그림으로 표현하고, 나머지
플레이어들이 채팅으로 정답을 맞히는 그림 퀴즈 게임입니다. 라운드마다
출제자가 바뀌며, 정답을 맞힌 플레이어는 점수를 얻습니다.

## Recommended IDE Setup

[VS Code](https://code.visualstudio.com/) + [Vue (Official)](https://marketplace.visualstudio.com/items?itemName=Vue.volar) (and disable Vetur).

## Recommended Browser Setup

- Chromium-based browsers (Chrome, Edge, Brave, etc.):
  - [Vue.js devtools](https://chromewebstore.google.com/detail/vuejs-devtools/nhdogjmejiglipccpnnnanhbledajbpd)
  - [Turn on Custom Object Formatter in Chrome DevTools](http://bit.ly/object-formatters)
- Firefox:
  - [Vue.js devtools](https://addons.mozilla.org/en-US/firefox/addon/vue-js-devtools/)
  - [Turn on Custom Object Formatter in Firefox DevTools](https://fxdx.dev/firefox-devtools-custom-object-formatters/)

## Customize configuration

See [Vite Configuration Reference](https://vite.dev/config/).

## Project Setup

```sh
npm install
```

### Compile and Hot-Reload for Development

```sh
npm run dev
```

### Compile and Minify for Production

```sh
npm run build
```

## Supabase RPC deployment

Apply the SQL files in this order after the base tables exist:

1. `room-admin.sql`
2. `liar-game.sql`
3. `liar-game-statement-fix.sql`
4. `catchmind-game.sql`
5. `admin-access.sql`

`room-admin.sql` removes historical `create_room` overloads before recreating
the RPC used by the frontend. This avoids PostgREST `PGRST203` errors. It also
recreates the room presence heartbeat and stale-player cleanup RPCs used by the
lobby and game screens.

`admin-access.sql` adds user/admin roles, account and chat sanctions, audit
logs, and the RPCs used by the `/admin` page. After applying it, bootstrap the
first administrator with the SQL example at the bottom of that file.

After applying the file in the Supabase SQL Editor, verify that only one
`create_room` function remains:

```sql
select p.oid::regprocedure
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'create_room';
```
