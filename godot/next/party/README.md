# godot/next/party: the lobby, hosting, joining, and the joiner's own account

Owner 2026-10-07: the lobby is private 6-digit codes plus a public list of open sessions. Host's game is authoritative (D1); a host quitting ends the session (D6).
Files: `dm_next_party.gd` (`DmNextParty`, child `Party` of `DmNextGame`, every peer), `dm_next_joiner.gd` (`DmNextJoiner`, child `Joiner`, joiners only),
`ui/panels/dm_lobby_panel.gd` (the Party window, pure UI), `game_ui/dm_ui_lobby.gd` (window <-> game wiring), `DmNextUiHost.party_*` (the contract), `main/main.gd` (game swap).

## Flows
| | what happens |
|---|---|
| **Solo** | nothing: no socket, no per-frame work. Opening the Party window (key F, HUD button, Settings -> Play together) opens a lobby socket and lists every 10 s; closing it closes the socket again. Offline characters see "Online play needs an online account". |
| **Host** | `host_session(name, private)` -> lobby `create` -> `DmRelayPeer.host` -> `DmSession.swap_transport(relay)`: the running world, the host's body and its rewards stay; joiners come in through the normal session handshake. Private = a six-digit code to share; public = in everyone's list. Open/Closed (`set_open`) stops new players (and hides it from the list). `kick(peer)`. `leave()` or a lost lobby socket -> back to the offline peer, the game plays on solo (`hosting_changed`). |
| **Join** | `join_session(id, code?)` / `join_by_code(code)` from a solo game: the lobby seats us (`join_ready(lobby, info)`), `main.gd` saves + frees the solo game and starts a client `DmNextGame` (`opts.lobby`) on the same socket. A refusal (`full`, `bad_code`, `closed`, `not_found`, `rate_limit`, ...) stays a message in the window; the solo game never stopped. |
| **Client ends** | left, removed, host gone, connection lost, handshake refused: `client_ended(reason, text)` -> `main.gd` saves the joiner, frees the client game, re-enters the player's own hub solo with the reason as a toast. |
| **A joiner appears** | next to the host (`DmSession.spawn_override`), except in the Depths (Chapterhouse). The relay peer is held (`DmRelayPeer.hold`) until the client's nodes exist, so the host's first spawn / RPC packets never arrive early. |

## The joiner's own account (D1: value stays on the backend)
1. After the roster arrives the client sends its profile (`character_id, class_index, level, experience`); the host makes a **remote** `DmRewardsMember` (no api, blocked `pending_join`), binds the body's character (level clamped to 100) and answers with the host's backend session id.
2. The client calls `session_join(sid, character_id)` with **its own token**, heartbeats every 20 s, and tells the host (`_rpc_backend`): the host then credits the member. A refusal leaves the member blocked and the joiner is told on screen.
3. The host's session reports carry the joiner's kills (`party-sessions.cjs` credits each member with its own caps). The accepted XP / kill counts go back to the joiner (`_rpc_credit`) and are applied to ITS `DmProgression`, saved by ITS `DmProgressSync`.
4. Drops of a remote member are not held on the host: `loot_dropped` -> `_rpc_loot` -> the joiner's own loot view (walk-over, its Settings -> Loot rules). Gear leaves the host as plain base gear with `roll: {level, source}` and is rolled by the joiner's own `roll_loot`. The bag is the joiner's `DmInventory`.
Not carried yet: the joiner's gear / upgrades / vows for its body's damage (the host builds its body from class + reported level), flasks and brews, first-kill trophies (remote members never get them), per-joiner area / Depths.

## Errors in words (`DmNextParty.ERROR_TEXT` / `CLOSE_TEXT`)
`full bad_code closed not_found rate_limit in_session not_in_session not_host busy bad_request auth` and `host_left kicked idle shutdown`; socket failures (4401 login, 4402 replaced, 4429 too fast, unreachable) map in `_connection_text`.

## Cost of a hosted session (measured, `tests/next_lobby`)
Idle host -> relay ~5 KB/s, ~50 packets/s. 25 chasing enemies ~95 KB/s, ~145 packets/s (enemy state is the bulk: 20 Hz x ~180 B each); that is ONE copy from the host, the relay fans it out, so each joiner receives about the same ~95 KB/s.
The relay allows 600 packets/s and 1 MiB/s per connection. Frame time (headless, 25 enemies): solo 8.9 ms, hosting with nobody 8.7-8.9 ms, hosted with a joiner (client game in the same process) 9.1-9.5 ms: the relay peer polls one WebSocket per frame, nothing else runs per frame.

## Tests
`tests/next_lobby/run.gd` (real local lobby service, two games in-process on ONE shared offline backend: solo untouched, errors, host, list, join by id and code, chat, open/closed, kick, full, rewards + XP + loot on the joiner's account, drops, cost),
`ui_run.gd` (the window on synthetic views + in the real HUD), `proc_run.gd` (separate processes: full `DmMain` per player over the real relay, the game swap, movement, chat, leave, host death).
Each needs `node` and `cd server/death-muffin/lobby && npm install`, else prints a skip line. `shoot.gd`: rendered screenshots of the window (under the renderer lock).
