# GAME OVER Result Flow Fix Log

## Problem

- When a game ended, the room was moved back to `waiting` immediately.
- The gameplay view redirected to the lobby as soon as the room became `waiting`.
- There was no persisted end-state payload for the result screen.

## Changes

### Database / Supabase

- Added `games.winner`, `games.end_reason`, `games.ended_at`, and `games.return_to_lobby_at`.
- Added `public.game_results` with a unique `game_id`.
- Added `finish_game(p_game_id, p_winner, p_reason)` RPC.
- Reworked `check_game_ended(p_room_id)` so it ends the game without returning the room to the lobby immediately.
- Added `get_current_game(p_room_id)`, `get_game_result(p_game_id)`, and `return_room_to_lobby(p_room_id)`.
- Stored a `game_end` system message and a result snapshot JSON in `game_results.summary`.

### Frontend

- `GamePlayView.vue` now renders a dedicated GAME OVER screen when the game is ended.
- The result screen shows the winning team, end reason, winners, and per-player role / action logs.
- Added a 15-second countdown based on `return_to_lobby_at`.
- Added a manual `지금 대기방으로 돌아가기` action that returns to lobby immediately.
- The auto-return path avoids duplicate RPC calls with a guard flag.

## Verification

- `npm run build` should be run after applying the schema changes in Supabase.
- Frontend logic was updated to read the stored result data instead of recomputing winners locally.
