# godot/next/party: friends, the lobby, hosting, joining, and the joiner's own account

Owner 2026-10-07: the lobby is private 6-digit codes plus a public list of open sessions. Host's game is authoritative (D1); a host quitting ends the session (D6).
Files: `dm_next_party.gd` (`DmNextParty`, child `Party` of `DmNextGame`, every peer), `dm_next_joiner.gd` (`DmNextJoiner`, child `Joiner`, joiners only),
`dm_next_friends.gd` (`DmNextFriends`, child `Friends`), `ui/panels/dm_social_window.gd` (the Social window, key O: tabs Friends and Party),
`ui/panels/dm_friends_pane.gd` / `ui/panels/dm_party_pane.gd` (the tabs, pure UI), `game_ui/dm_ui_social.gd` (window <-> game wiring),
`DmNextUiHost.party_*` / `friends_*` (the contract), `main/main.gd` (game swap).

## Friends (DECISIONS B18)
Mutual friends kept on the backend (`backend/friends.cjs`, table `friendships`, migration 045). The Friends tab (O, or the HUD's Social button) adds a
friend by login name (any case), lists requests both ways (Accept / Decline, Cancel) and friends with the class and level of the character they last
played (`DmNextFriends.class_line`). Asking someone who already asked you makes you friends at once. Remove asks "Sure?" first. Caps: 100 per
account, 20 requests waiting. No socket and no per-frame work: one `GET /api/friends` after the world's loading cover (`check_requests`: waiting
requests become a toast and the tab's NEW pip, once per run) and one per open of the tab; each write answers the whole list. Offline characters
see why instead (same rule as the lobby: an override `lobby_url` enables it for tests). Online / offline status, joining a friend and invites are
not built yet (ROADMAP).

## Flows
| | what happens |
|---|---|
| **Solo** | nothing: no socket, no per-frame work. Opening the Social window (key O on Friends, key F on Party, the HUD's Social button, Settings -> Co-op tab -> Open the Party tab) opens a lobby socket and lists every 10 s; closing it closes the socket again. In `--dev-offline` the window says "Online play needs an online account". |
| **Host** | `host_session(name, private)` -> lobby `create` -> `DmRelayPeer.host` -> `DmSession.swap_transport(relay)`: the running world, the host's body and its rewards stay; joiners come in through the normal session handshake. Private = a six-digit code to share; public = in everyone's list. Open/Closed (`set_open`) stops new players (and hides it from the list). `kick(peer)`. `leave()` or a lost lobby socket -> back to the offline peer, the game plays on solo (`hosting_changed`). |
| **Join** | `join_session(id, code?)` / `join_by_code(code)` from a solo game: the lobby seats us (`join_ready(lobby, info)`), `main.gd` saves + frees the solo game and starts a client `DmNextGame` (`opts.lobby`) on the same socket. The joiner says hello only after its world is built (`DmRelayPeer.hold`), so the host waits `DmSession.HELLO_TIMEOUT` (90 s) for it; the joiner gives up `CLIENT_ACTIVE_S` (20 s of running frames) after its hello went out, at most `CLIENT_HARD_S` (85 s): the first frames after a build can stall for seconds on the Compatibility renderer. The join path logs `[coop]` lines with `printerr`: a release build buffers `print` output and only flushes the log file on an error or a clean exit, so plain prints never reached bug reports. A refusal (`full`, `bad_code`, `closed`, `not_found`, `rate_limit`, ...) stays a message in the window; the solo game never stopped. |
| **Client ends** | left, removed, host gone, connection lost, handshake refused: `client_ended(reason, text)` -> `main.gd` saves the joiner, frees the client game, re-enters the player's own hub solo with the reason as a toast. |
| **A joiner appears** | next to the host (`DmSession.spawn_override`), moved onto the navmesh (`spawn_resolve`: the ring point fell off it about one time in five, and the host's mover then snapped the body back on every step), except in the Depths (Chapterhouse). The relay peer is held (`DmRelayPeer.hold`) until the client's nodes exist, so the host's first spawn / RPC packets never arrive early. |

## The joiner's own account (D1: value stays on the backend)
1. After the roster arrives the client sends its profile (`character_id, class_index, level, experience`); the host makes a **remote** `DmRewardsMember` (no api, blocked `pending_join`), binds the body's character (level clamped to 100) and answers with the host's backend session id.
2. The client calls `session_join(sid, character_id)` with **its own token**, heartbeats every 20 s, and tells the host (`_rpc_backend`): the host then credits the member. A refusal leaves the member blocked and the joiner is told on screen.
3. The host's session reports carry the joiner's kills (`party-sessions.cjs` credits each member with its own caps). The accepted XP / kill counts, and a boss kill's XP, go back to the joiner (`_rpc_credit`) and are applied to ITS `DmProgression`, saved by ITS `DmProgressSync`.
4. Drops of a remote member are not held on the host: `loot_dropped` -> `_rpc_loot` -> the joiner's own loot view (gold/shards credited, items picked up by a click, runes resolved against the joiner's own bag and Vault). Finds worth telling go to the whole party with `announce(line)` (host fills in `{who}`). Gear a member drops from the bag (`ground.cjs`) is relayed by the host only to the members the server named in `eligible` (`share_ground`), and a pickup takes it off everyone's ground (`share_taken`); the server decides every hand-off. Gear leaves the host as plain base gear with `roll: {level, source}` and is rolled by the joiner's own `roll_loot`. The bag is the joiner's `DmInventory`.
5. Levels: a joiner's puppets carry no character, so the host sends `{peer: level}` (`_rpc_levels`, reliable) to everyone when a profile is bound and on every member's level-up, never per frame. `DmNextParty.level_of(body)` is the one place the party frames read a hero's level.
6. Shared objectives are the WHOLE party's: a kill the rule does not pay a member for (dead, or out of range) still rides that member's own report as an `objective` group (`DmSessionRewards._count_only`; the backend credits the area kill and no XP, gold or shards), so every member's area tally, seals and the "slain here" count go up for any party kill. A joiner's kills count in a ground its own character has not opened (`record_kill(..., carried)`), the backend persists them (below), and the joiner checks its own seals after each credit (`DmNextJoiner._check_unlocks`). The Depths are a solo descent, so a floor quota is never shared.
7. World scaling follows the host: `DmWaveDirector.scaling_levels` gives enemies (and boss arenas) the leader's level whoever stands where; solo is unchanged.
Known gaps. Not carried yet: the joiner's gear / upgrades / vows for its body's damage (the host builds its body from class + reported level), flasks and brews, first-kill trophies (remote members never get them), per-joiner area / Depths.

## Errors in words (`DmNextParty.ERROR_TEXT` / `CLOSE_TEXT`)
`full bad_code closed not_found rate_limit in_session not_in_session not_host busy bad_request auth` and `host_left kicked idle shutdown`; socket failures (4401 login, 4402 replaced, 4429 too fast, unreachable) map in `_connection_text`.

## Cost of a hosted session (measured, `tests/next_lobby`)
Idle host -> relay ~5 KB/s, ~50 packets/s. 25 chasing enemies ~95 KB/s, ~145 packets/s (enemy state is the bulk: 20 Hz x ~180 B each); that is ONE copy from the host, the relay fans it out, so each joiner receives about the same ~95 KB/s.
The relay allows 600 packets/s and 1 MiB/s per connection. Frame time (headless, 25 enemies): solo 8.9 ms, hosting with nobody 8.7-8.9 ms, hosted with a joiner (client game in the same process) 9.1-9.5 ms: the relay peer polls one WebSocket per frame, nothing else runs per frame.

## Tests
`tests/next_lobby/run.gd` (real local lobby service, two games in-process on ONE shared offline backend: solo untouched, errors, host, list, join by id and code, chat, open/closed, kick, full, rewards + XP + loot on the joiner's account, drops, cost),
`ui_run.gd` (the Social window: both panes on synthetic views, the Party tab in the real HUD, two players befriending each other through their windows), `proc_run.gd` (separate processes: full `DmMain` per player over the real relay, the game swap, movement, chat, leave, host death).
Each needs `node` and `cd server/death-muffin/lobby && npm install`, else prints a skip line. `shoot.gd`: rendered screenshots of the window (under the renderer lock).
