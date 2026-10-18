# client/next/rewards: host-side session rewards, and this player's loot

`DmSessionRewards` (Node) runs on the session HOST only. Value goes through the backend (DECISIONS.md D1); `--dev-offline` is the same code with the
mock backend's DmApi (D4). Per-member state lives in `DmRewardsMember` (RefCounted). `DmNextLoot` (`dm_next_loot.gd`, the client's own) is this player's drops and bag, on the host and on a guest. How the game scene earns value
on the core (the credited kill, the meta nodes, a guest's own account, ground drops between members): client/README.md "Value on the server".

## What the game shell (DmNextGame) provides

```gdscript
var rewards := DmSessionRewards.new()
rewards.local_peer_id = multiplayer.get_unique_id()   # only this peer's member loot is visible/rendered here
rewards.area_id = "graves"                           # default area for enemies without a level / area of their own
rewards.difficulty / wave_tier / ascension           # world context, keep current
add_child(rewards)
rewards.attach_game(shell)                           # the shell's `kill_credited` signal and the core host's `struck` (lifesteal)
rewards.add_member(DmRewardsMember.make(character_id, peer_id, player_body, api))   # one per player, host first
await rewards.start(host_character_id)               # session_open (host api) + session_join for the others (their api)
...                                                  # kills arrive as the shell's `kill_credited`
await rewards.end_session({"seconds": n})            # final batch + session_end (also when the host quits, D6)
```

| Need | Contract |
|---|---|
| Kills | the game scene's `kill_credited(enemy_id, def, level, elite, area, killer_peer, x, z)`: the host's one credit per kill, from the core's death event (the killer is a peer: the hero who struck it, or the owner of the thrall whose blow it was). A shell with its own death pipeline can call `on_kill({def, area, level, elite, x, z, killer})` |
| Roster | `DmRewardsMember`: `character_id`, `peer_id`, `body` (Node3D; position read per tick; optional `dm_alive() -> bool`), `api` (that member's own DmApi/JWT), `prog` (DmProgression: XP/level/gold are applied here), `discipline {id, family}`, multipliers `wisdom`, `fortune`, `omen_reward`, `omen_shard`. `api == null` for a remote peer that joins/heartbeats with its own client (then its gear drops land unrolled). `add_member`/`remove_member` any time. |
| Ticking | `auto_tick` (default true) lets `_process` drive it; tests call `tick(dt)`. |
| Loot display | each member has its own `loot_view` (DmLootView, child of the node, visible only when `peer_id == local_peer_id`). For remote peers the shell mirrors the `loot_dropped(character_id, drop, pos)` / `loot_picked` / `loot_expired` signals to that peer. Bag: `member.bag` (cap 24) or set `member.take_item` (the loot node does). |
| Signals | `session_opened`, `session_failed`, `session_closed`, `member_credited`, `member_refused`, `batch_reported`, `kill_earned`, `killer_paid`, `kill_counted`, `chain_tier_up`, `boss_earned`, `loot_dropped/picked/expired` |

## Rules (`client/game/dm_game_rewards.gd`'s kill range, kept as the single source)

- A kill pays every member that is alive and within `DmGameRewards.KILL_REWARD_RANGE` (38) of it, each at its own multipliers
  (the node calls `DmGameRewards.boss_reward_eligible` itself, no copy). Inert defs pay nothing.
- Per member: `DmLoot.roll_kill` (items/reagents/runes/shards/gold/xp), Kill Chain only for the killer in unsafe ground, the omen multiplier, wisdom on XP, new-blood XP catch-up, gold pooled over `goldEveryKills` kills (elites always pay out), "elite" gear quality.
  The world's heat is 0 in the game (no Ascension: B36), so the rank in the reports is 0.
- Gold and shards are credited at once; items wait 3 min for a click (pickup within 1.3 m), loot never flies to anyone (DmLootView). A rune the owner already has (learned, bag, sockets, Vault) does not drop at all (`DmLootView.rune_owned`). Each member's `rune_dry` (elites in rune-shedding ground without a new rune) raises the next elite's rune chance (`DmLootRunes.pity_mult`, DECISIONS B17); a new rune resets it (a remote member's runes are not known to the host: any rune resets it).

## Backend flow

1. `start`: host `session_open(host_character_id)`; every other member `session_join` with its own api. Non-host members `session_heartbeat` every 20 s.
2. Kills are grouped per member (DmKillReporter) and sent as `session_report(sid, batch, members)` every `flush_interval` s (5), early at 60 open
   groups, and in the final `session_end`. Batch numbers strictly increase; an unanswered batch is re-sent under the SAME number.
3. The reply decides value: XP and kill counts (and area kills) are applied only for what the backend accepted (`accepted.kills / claimed`
   share of the XP). `credited:false` -> `member_refused(reason)`; `left`/`not_member` also stop that member's rewards. A `duplicate` reply
   (lost answer) is reconciled from `session_get` counters. 403/404/409 on report = session lost (`session_failed`); transport errors retry.
4. Gold/shards are credited to the member's purse at once; the member's own save path persists them (capped by the kill ledger from these reports).
5. **Items are decided by the server** (DECISIONS B20). A local member has a drop tape (`m.tape`, `DmDropTape`, filled from `api.drops_tape`): each kill,
   elite, boss or surge takes the next event of its kind and rolls it at once (`_roll_event` -> `DmLoot.roll_event` on that event's seed), gear with its
   affixes. Every item carries `claim {kind, n, index, facts, expect}`; picking it up (`DmNextLoot._claim_from_tape`, runes at once) is
   `api.drops_claim`: the server rolls the same event and puts its own roll in the bag (`inventory.replace` with its rows). A remote member whose
   client says it rolls its own drops (`rolls_own_drops`) gets the event instead (`drop_event_for`), see `client/next/party/README.md`. The Depths'
   floor clears and chests take their own kinds (`roll_depths`, from `DmDepths`). With a tape but no seed dealt yet, the kill pays its gold and
   XP and drops no item (the server keeps unclaimed drop items out of the bag). Only a member without a tape (tests that pin `rng`) rolls the
   old way. A claim the server refuses over budget carries `resync`: `DmDropTape.rewind` goes back to the server's position, so the next
   honest event pays again (e.g. after a host's GM-summoned bosses the server did not credit a guest).

## Backend without `/api/sessions` (legacy ledger)
The backend's host-session routes need migration 041 (`server/death-muffin/backend/party-sessions.cjs`); on a backend without them `session_open` answers an HTML 404 and `start()` sets `legacy_ledger` (signal `ledger_fallback`, no `session_failed`):
each member with its own api reports to **its own kill ledger** (`api.report_kills`), and XP / kill counts are applied from that reply's `accepted.kills`
(a reply without it, e.g. ledger off or a duplicate, applies the claim whole. Same cadence, `flush()` and `end_session()` (final flush) as the session path; a transport failure keeps batches and claim for the next flush.
Joiners without an api are not credited in this mode (they need the session routes). 503 (tables missing) falls back the same way.

## Brews
`DmRewardsMember.sync_brews()` (host; called before every kill reward) sets `wisdom` / `fortune` from the active brews of the member's body (`DmPlayerRules.brew_value` on `clock_ms()`),
so a drink, an extension, a replacement and an expiry all take effect with no extra wiring; a body without a rules state (test stubs) keeps hand-set values. Lifesteal: the node hears the core host's `struck`
(a hero's direct blow, never a DoT tick or a thrall's swing); direct hits of a `DmHeroBody` with a live `lifesteal` elixir are summed per frame and healed once at the end of it,
`DmBrews.lifesteal_heal(average hit, hits, frac, max_hp)` (target cap + one per-cast cap, >= 1 hp only). Boss kills do not apply wisdom.

## Bosses (first kills, Empowered)
`on_boss_defeated` pays each eligible member; its XP is applied at once, and for a remote member also sent as `member_credited` (`kills` 0) so the guest's own client gets it. `m.claim_trophy(id)` is `DmNextChronicle.claim_trophy` (persisted through the Chronicle, `client/next/progress/README.md`); an Empowered kill adds the backend `summon`
id to the report (`m.empower_pending / empower_summon_id`, set by `DmBossMeta`).

## This player's loot (`dm_next_loot.gd`, `client/loot_view/loot_view.gd`)
`DmNextLoot` (child `Loot` of `DmNextGame`, host or guest) holds this player's drops and bag: `inventory` (`DmInventory`, the server's rows), the runes owned, a click on a drop. It sends `event(id, ctx)` (the `game_event` shape) to the HUD. Worn gear feeds the stats (`DmNextProgress.request_stats`) and pays for the belt.
- Click to pick up (DECISIONS B15): `DmNextInput` asks `loot_click(screen)` after the enemy pick (Alt+click: drops first); the hero walks there and `DmLootView` takes it on arrival (within 1.3 m). Any other click or a WASD step calls `loot_cancel()`. The 10 Hz hover pick (`loot_hover`)
  shows the hovered drop's name; Alt shows every name. Loot never flies to you; a drop expires after 3 min, and past 60 item drops on the ground the oldest go early, ordinary ones first.
- Gold / shards are credited at once; everything credited within `GOT_WINDOW_S` (1.2 s) is one float and one sound.
- A drop rolled from the tape is claimed on pickup (`api.drops_claim`: the server's own roll goes in the bag, the ground copy goes once it answers; it stays when the bag is full or the server could not be reached); a piece a party member dropped on the session's ground is picked up with
  `api.ground_pickup` (the first pickup wins, everyone else's copy goes: `DmNextParty.share_taken`). A refusal is a toast with the server's words.
- Runes (`_owns_rune`: learned runes, bag and socket rows + the Vault from `note_vault`): a new rune goes into the bag with the pickup feedback and a chat line; one the character already has does not drop at all. Legendaries landing are a chat line. In a party `DmNextParty.announce` sends the line to everyone ("{who}" = the finder's roster name).
- Dropped gear (DECISIONS B16): Reliquary -> Drop (`DmUiInventory`, epic and legendary ask "Drop it / Keep it") calls `DmNextUiHost.drop_gear(row)`: bag committed, `api.ground_drop`, the server's bag adopted, the piece drawn at the hero's feet (`DmLootView.shared_item`) and relayed.
- Bag full: "Reliquary full" float plus one toast; re-armed once there is room.
- Pickup toast colour = beam colour; better-than-worn gear says "(upgrade)".
- Ground: item names in rarity colour within 7 m (3 m ordinary; `DmLootView.near_labels = false` turns them off), icon is the inventory's own item art (`DmUiArt.item`; a rarity tile only for an item without art) and blinks in the last 8 s, drops from one kill land >= 0.65 m apart.

## Tests
`client/tests/rewards.gd` replays the old game's rewards suite on the port (sessions, batches, lost replies, refusals, the end, per-member loot, on the mock backend; a test double emits `kill_credited`); `client/tests/value.gd` plays the game scene (a drop claimed into the bag, the purse, brews and lifesteal);
`client/tests/panels.gd` the Reliquary on the server's bag. Not covered in the client: the loot view's own suite (the ground, labels, expiry, the pickup radius; the old game's loot-view suite).
