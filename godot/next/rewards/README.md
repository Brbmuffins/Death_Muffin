# godot/next/rewards: host-side session rewards

`DmSessionRewards` (Node) runs on the session HOST only. Value goes through the backend (REBUILD D1); offline is the same code with the
offline backend's DmApi (D4). Per-member state lives in `DmRewardsMember` (RefCounted).

## What the game shell (DmNextGame) must provide

```gdscript
var rewards := DmSessionRewards.new()
rewards.local_peer_id = multiplayer.get_unique_id()   # only this peer's member loot is visible/rendered here
rewards.area_id = "graves"                           # default area for enemies without meta dm_area
rewards.difficulty / wave_tier / ascension           # world context, keep current
add_child(rewards)
rewards.attach_spawner(shell)                        # shell: signal enemy_spawned(enemy)   (or call rewards.watch_enemy(e))
rewards.add_member(DmRewardsMember.make(character_id, peer_id, player_body, api))   # one per player, host first
await rewards.start(host_character_id)               # session_open (host api) + session_join for the others (their api)
...                                                  # kills are picked up from the enemies' `died` signal
await rewards.end_session({"seconds": n})            # final batch + session_end (also when the host quits, D6)
```

| Need | Contract |
|---|---|
| Enemies | `died(enemy)` (DmEnemy emits it on the authority); optional `damaged(amount, hp, from)` gives the killer (the last hitter; a node equal to a member's `body`). Optional `get("def_id")`, meta `dm_level` (default 1), `dm_elite` (false), `dm_area` (default `area_id`). Shells with their own death pipeline can call `on_kill({def, area, level, elite, x, z, killer})`. |
| Roster | `DmRewardsMember`: `character_id`, `peer_id`, `body` (Node3D; position read per tick; optional `dm_alive() -> bool`), `api` (that member's own DmApi/JWT), `prog` (DmProgression: XP/level/gold are applied here), `discipline {id, family}`, multipliers `wisdom`, `fortune`, `omen_reward`, `omen_shard`. `api == null` for a remote peer that joins/heartbeats with its own client (then its gear drops land unrolled). `add_member`/`remove_member` any time. |
| Ticking | `auto_tick` (default true) lets `_process` drive it; tests/shell call `tick(dt)`. |
| Loot display | each member has its own `loot_view` (DmLootView, child of the node, visible only when `peer_id == local_peer_id`). For remote peers the shell mirrors the `loot_dropped(character_id, drop, pos)` / `loot_picked` / `loot_expired` signals to that peer. Bag: `member.bag` (cap 24) or set `member.take_item`. |
| Signals | `session_opened`, `session_failed`, `session_closed`, `member_credited`, `member_refused`, `batch_reported`, `kill_earned`, `loot_dropped/picked/expired` |

## Rules (same as the current game, `dm_game_rewards.gd on_kill`)

- A kill pays every member that is alive and within `DmGameRewards.KILL_REWARD_RANGE` (38) of it, each at its own multipliers
  (the node calls `DmGameRewards.boss_reward_eligible` itself, no copy). Inert defs pay nothing.
- Per member: `DmLoot.roll_kill` (items/reagents/runes/shards/gold/xp), Kill Chain only for the killer in unsafe ground, ascension and omen
  multipliers, wisdom on XP, new-blood XP catch-up, gold pooled over `goldEveryKills` kills (elites always pay out), "elite" gear quality.
- Walk-over pickup (1.3 m), 60 s expiry, loot never flies to anyone (DmLootView rules; gold/shards still magnet from a few steps, as in the game).

## Backend flow

1. `start`: host `session_open(host_character_id)`; every other member `session_join` with its own api. Non-host members `session_heartbeat` every 20 s.
2. Kills are grouped per member (DmKillReporter) and sent as `session_report(sid, batch, members)` every `flush_interval` s (5), early at 60 open
   groups, and in the final `session_end`. Batch numbers strictly increase; an unanswered batch is re-sent under the SAME number.
3. The reply decides value: XP and kill counts (and area kills) are applied only for what the backend accepted (`accepted.kills / claimed`
   share of the XP). `credited:false` -> `member_refused(reason)`; `left`/`not_member` also stop that member's rewards. A `duplicate` reply
   (lost answer) is reconciled from `session_get` counters. 403/404/409 on report = session lost (`session_failed`); transport errors retry.
4. Gold/shards are ground drops; the member's own save path persists them (capped by the kill ledger from these reports). Gear is rolled
   by `member.api.roll_loot` (server RNG online, offline backend offline); a failed roll leaves plain base gear.

## Not covered yet

Surge rewards, Depths floors (solo-only), Settings->Loot rules wiring (set `member.loot_view.rules/keep`),
saving the bag to the backend, level-up presentation (read `member_credited.levels`), a client-side mirror of remote members' loot views.

## Bosses (first kills, Empowered)
`on_boss_defeated` pays each eligible member. `m.claim_trophy(id)` is `DmNextChronicle.claim_trophy` in the slice (persisted through the Chronicle, `next/progress/README.md`); an Empowered kill adds the backend `summon`
id to the report (`m.empower_pending / empower_summon_id`, set by `DmBossMeta`).
