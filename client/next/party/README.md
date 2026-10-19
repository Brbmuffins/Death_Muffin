# client/next/party: friends, the lobby, hosting, joining, and the guest's own account

Parties are Open (in the public list, anyone joins; the default since 2026-10-14) or Closed (invite only; friends can ask), DECISIONS D11 / B18. A player who left can come back while the session lives. Host's game is authoritative (D1); a host quitting ends the session (D6).
How the host and the guest share one fight (the puppet core, the snapshot and reliable messages, bosses in a party, the Social window, launch arguments, the local trial and the proofs) is client/README.md "Co-op on the core"; this guide is the lobby, friends and account side.
Files: `dm_next_party.gd` (`DmNextParty`, child `Party` of `DmNextGame`, every peer), `dm_next_joiner.gd` (`DmNextJoiner`, child `Joiner`, guests only),
`dm_next_friends.gd` (`DmNextFriends`, child `Friends`), `client/ui/panels/dm_social_window.gd` (the Social window, key O: tabs Friends and Party),
`client/ui/panels/dm_friends_pane.gd` / `client/ui/panels/dm_party_pane.gd` (the tabs, pure UI), `client/game_ui/dm_ui_social.gd` (window <-> game wiring),
`DmNextUiHost.party_*` / `friends_*` (the contract), `client/main/main.gd` (game swap).

## Friends (DECISIONS B18)
Mutual friends kept on the backend (`server/death-muffin/backend/friends.cjs`, table `friendships`, migration 045). The Friends tab (O, or the HUD's Social button) adds a
friend by login name (any case), lists requests both ways (Accept / Decline, Cancel) and friends with the class and level of the character they last
played (`DmNextFriends.class_line`). Asking someone who already asked you makes you friends at once. Remove asks "Sure?" first. Caps: 100 accepted and pending rows per account, 20 requests waiting at once. The list is one `GET /api/friends` after the world's loading cover (`check_requests`), one per open of the tab, and
one whenever the lobby says a friendship changed (`friends_changed`: the other player answered or removed us, or sent a request while we are
online); each write answers the whole list and nudges the lobby (`DmNextParty.friends_changed`, queued until the link is up). New requests become
a toast and the tab's NEW pip, once each per run. Offline characters see why instead (an override `lobby_url` enables it for tests).

**Presence, invites, asks (`server/death-muffin/lobby/README.md` "Friends").** After loading, `go_online()` keeps one lobby socket (10 Hz timer poll, reconnect after
5/15/60/120 s, not after a refused login or a replaced session). It sends our presence (discipline, level, area: on connect, on area change, on
level-up, re-checked every 30 s) and keeps `friends_online` (account id -> presence incl. party: id, Open/Closed, players, host). Rows show a
dot, "Online · class · area · hosting 2/4" or "Offline · last played ...", and `DmNextFriends.actions_for`: **Join** (their Open party has room),
**Ask to join** (a Closed party, or they play solo: they answer from their Friends tab; accepting while solo hosts an Open party first, then the
asker is let in and joins at once), **Invite** (into our party; playing solo it hosts an Open party first). Invites and asks wait in the tab's
"Party invites" section for 5 min (toasts open the window). Only the host invites or answers; a guest's friend's ask goes to the host.

## Flows
| | what happens |
|---|---|
| **Solo** | the friends link only (above); no game packets, no per-frame work. Opening the Social window (key O on Friends, key F on Party, the HUD's Social button, Settings -> Co-op tab) also lists Open sessions every 10 s. Without `go_online()` (tests) the window opens a socket and closes it again. In `--dev-offline` the window says "Online play needs an online account". |
| **Host** | `host_session(name, private)` -> lobby `create` -> `DmRelayPeer.host` -> `DmSession.swap_transport(relay)`: the running world, the host's body, its fight and its rewards stay; guests come in through the normal session handshake. Open (`host_session(name)`, the default) = in everyone's list; Closed (`host_session(name, true)`, `set_closed`) = invite only, out of the list. `set_open(false)` (relay `refuse_new_connections`) stops new players altogether. `kick(peer)`. `leave()` or a lost lobby socket -> back to the offline peer, the game plays on solo (`hosting_changed`). |
| **Join** | `join_session(id)` (the list, a friend's Open party, an invite) from a solo game: the lobby seats us (`join_ready(lobby, info)`), `main.gd` saves + frees the solo game and starts a guest `DmNextGame` (`opts.lobby`) on the same socket. The guest says hello only after its world is built (`DmRelayPeer.hold`), so the host waits `DmSession.HELLO_TIMEOUT` (90 s) for it; the guest gives up `CLIENT_ACTIVE_S` (20 s of running frames) after its hello went out, at most `CLIENT_HARD_S` (85 s). The join path logs `[coop]` lines with `printerr`: a release build buffers `print` output and only flushes the log file on an error or a clean exit, so plain prints never reached bug reports. A refusal (`full`, `bad_code`, `closed`, `not_found`, `rate_limit`, ...) stays a message in the window; the solo game never stopped. The host refuses a different release build and another core wire version (`DmSession.PROTOCOL` 3: the hello carries `DmBuild.version()` and `DmCore.wire_version()`); the guest lands back in its own world with which side is behind and "restart from the launcher" (DECISIONS B28). |
| **Guest ends** | left, removed, host gone, connection lost, handshake refused: `client_ended(reason, text)` -> `main.gd` saves the guest, frees its game, re-enters the player's own hub solo with the reason as a toast. |
| **A guest appears** | next to the host (`DmSession.spawn_override`), moved onto the navmesh (`spawn_resolve`: the ring point fell off it about one time in five, and the host's mover then snapped the body back on every step), except in the Depths (Chapterhouse). The relay peer is held (`DmRelayPeer.hold`) until the guest's nodes exist, so the host's first spawn / RPC packets never arrive early. |

## The guest's own account (D1: value stays on the backend)
1. After the roster arrives the guest sends its profile (`character_id, class_index, level, experience`); the host makes a **remote** `DmRewardsMember` (no api, blocked `pending_join`), binds the body's character (level clamped to 100) and answers with the host's backend session id.
2. The guest calls `session_join(sid, character_id)` with **its own token**, heartbeats every 20 s, and tells the host (`_rpc_backend`): the host then credits the member. A refusal leaves the member blocked and the guest is told on screen.
3. The host's session reports carry the guest's kills (`party-sessions.cjs` credits each member with its own caps). The accepted XP / kill counts, and a boss kill's XP, go back to the guest (`_rpc_credit`) and are applied to ITS `DmProgression`, saved by ITS `DmProgressSync` (client/README.md "Value on the server").
4. Drops of a remote member are not held on the host: `loot_dropped` -> `_rpc_loot` -> the guest's own loot view (gold/shards credited, items picked up by a click, runes resolved against the guest's own bag and Vault). Finds worth telling go to the whole party with `announce(line)` (host fills in `{who}`). Gear a member drops from the bag (`ground.cjs`) is relayed by the host only to the members the server named in `eligible` (`share_ground`), and a pickup takes it off everyone's ground (`share_taken`); the server decides every hand-off. Items: the guest's profile says it rolls its own drops (`rolls_drops`), so the host sends it each drop event (`drop_event_for` -> `_rpc_drop_event` -> `DmNextJoiner.on_drop_event`) and the guest rolls it from its own tape (DECISIONS B20) and claims the pickup itself with the party session (the host's ground counts as carried); Wave Speed is capped at the guest's own. The host's roll still pays the guest's gold and shards. A guest that does not say so gets finished items as before (gear as plain base gear with `roll: {level, source}`, rolled by its own `roll_loot`). The bag is the guest's `DmInventory`, held by its loot node (`DmNextLoot`).
5. Levels: a guest's puppets carry no character, so the host sends `{peer: level}` (`_rpc_levels`, reliable) to everyone when a profile is bound and on every member's level-up, never per frame. `DmNextParty.level_of(body)` is the one place the party frames read a hero's level.
6. Shared objectives are the WHOLE party's: a kill the rule does not pay a member for (dead, or out of range) still rides that member's own report as an `objective` group (`DmSessionRewards._count_only`; the backend credits the area kill and no XP, gold or shards), so every member's area tally, seals and the "slain here" count go up for any party kill. A guest's kills count in a ground its own character has not opened (`record_kill(..., carried)`), the backend persists them, and the guest checks its own seals after each credit (`DmNextJoiner._check_unlocks`). The Depths are a solo descent, so a floor quota is never shared.
7. World scaling follows the host: `DmWaveDirector.scaling_levels` gives enemies (and boss arenas) the leader's level whoever stands where; solo is unchanged.
8. **Its build is the server's** (DECISIONS B22): once its backend join succeeds the host reads the member's build (`fetch_build` -> `api.session_member_build`, `party-sessions.cjs` `memberBuild`) into `DmNextGame.remote_builds`, and `build_for(peer)` builds its body and caster from it, the vows and boons it carries left out (`without_ascension`: B36). The guest's HUD host calls `build_changed()` when what it wears changes; the host reads it again (at most once a second). The profile's level (clamped to `MAX_LEVEL`) only stands until then.
9. **Belt and boss summons are the guest's own.** Its belt (`DmNextLoot.guest_belt`, a `DmNextBelt` with `remote_use`) takes flasks, brews and meals from the guest's own bag, then `guest_use(id)` -> `_rpc_guest_use`: the host heals its hero, applies the brew to its body and caster, or heals a meal over time (`_guest_meals`). A summon is paid with the guest's own shards (`DmBossHost.request_summon_plain`: too few is refused on the guest; the host checks far / busy / dead, wakes it and answers `_rpc_summoned`, then the guest spends them; the host never charges a remote member).

## Errors in words (`DmNextParty.ERROR_TEXT` / `CLOSE_TEXT`)
`full bad_code closed not_found rate_limit in_session not_in_session not_host busy bad_request auth` and `host_left kicked idle shutdown`;
friends' requests (invite / ask / answer / set_private) use `SOCIAL_ERROR_TEXT` (`not_friend not_host already_in in_session rate_limit not_found`); socket failures (4401 login, 4402 replaced, 4429 too fast, unreachable) map in `_connection_text`.

## Cost of a hosted session
The Full Party's bandwidth for one guest was about 28 KB/s in 82 packets/s on the host's connection (2.7 % and 14 % of the relay's limits of 1 MiB/s and 600 packets/s): client/README.md "Co-op on the core" ("The proof"). The relay peer polls one WebSocket per
frame (and the UDP lane when it is up, DECISIONS B31); nothing else runs per frame.

## Tests
`client/tests/coop.gd` (a real local lobby and relay, a host and a guest in one process: the party flow, the connection, the fight, kills and rewards on the guest's account, the seals, refused versions), `client/tests/lobby/ui.gd` (the Social window, a guest that is the real boot scene, friends) and
`client/tests/value.gd` (a guest's account). Each needs `node` and `cd server/death-muffin/lobby && npm ci`, else it prints a skip line.

## Known gaps
- Not carried yet: first-kill trophies (remote members never get them), per-guest area / Depths. The guest's rune sockets for its rites come from the server's record of it.
