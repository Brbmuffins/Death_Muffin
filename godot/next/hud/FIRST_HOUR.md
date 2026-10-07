# First hour + loot polish notes (branch godot/next-loot)

Method: a fresh offline Gravecaller (class 2) booted through `DmNextGame` headless with the waves on, a scripted fight in the Graves and the
event / counsel / guidance stream printed with timestamps (loot walk-overs by teleport), plus code reading of the shared panels (they are the
same `DmGameUi` as the current game, so tooltips, compare chips, Forge / reforge / salvage flows are identical to `godot-port` by construction).
Not done: a rendered, human-paced hour (VPS rule: few rendered runs); the Gravedigger fight and the discipline panel were checked by code and tests only.

## Checked (fine as is)
- Spawn in the Chapterhouse: Next line = "Walk north into the Hollow Graves and fight your first dead"; the welcome / belt / people cards come calm and one at a time.
- Entering the Graves: area banner + Codex entry, `elite` / `move` / `hurt` cards (the `hurt` card says Q + T), "Kennel Loosed" banner, Kill Chain card, Chain of 10 milestone gold.
- First gear pickup: loot toast + `relic` card ("Loot goes to your Reliquary, equip it there"), then `atlas` / `affix` cards; bag arrows (green up / red down) and the compare chips come from the shared card.
- Settings -> Loot text already promises "upgrades for you are never sold": now true in the rebuild (see below).
- Dying mid-fight puts the Next line back to "Walk north into the Hollow Graves" until 10 kills: correct, not a bug.

## Changed
Loot (rebuild adapter `dm_next_ui_host.gd` + shared `loot_view/loot_view.gd`; test `tests/next_loot`):
- **Bug: rule "Sell for gold" lost the item AND the gold** (the rebuild never listened to `auto_sold`). Now paid into the purse with a "+Ng  <name>" float and the coin sound.
- **Bug: rule "Auto-loot"** put the piece in the bag silently: now the same pickup feedback as a walk-over (loot toast, rarity sound, counsel facts, Legendary toast).
- `keep` was never set, so the "gold" rule would have sold upgrades; it now asks `DmItemText.keeps_for_you` (current game's `stat_context`).
- Gold / shards walked over in one frame give ONE float + one sound (was one per coin); the gold / shard puff (`pickup_fx`) was not connected, now is.
- Bag full: besides the "Reliquary full" float, one toast explains what to do (Sell all junk, Vault, Bone Grinder, "stays on the ground for a minute"), as the current game; re-armed once there is room.
- Pickup toast colour = the beam colour (affix-raised rarity, was the base item rarity) and gear that beats what you wear says "(upgrade)".
- Ground: item names show in the rarity colour when you are within 7 m (3 m for ordinary pieces), built on first approach and hidden when you leave (no per-drop cost far away); the icon blinks in the last 8 s (faster in the last 3) so "about to expire" is visible; drops from one kill land >= 0.65 m apart when there is room. Loot still never flies to you. Cost: 60 items tick = 67 -> 79 us.

## Open (owner opinion / other tracks)
1. Right after entering the Graves the Next line becomes "Ossuary seal: 0/300 kills" (shared `DmGuidance`, fixture-tied to the web). A softer first goal ("kill 10 dead, walk over what drops") would read better; changing it means changing the shared rules and their TS fixtures, so not done here.
2. The Gravedigger shard hint (2 shards, "elites carry them") is priority 50, under the seal line (60), so it only shows once shards are in hand (86). The `boss_gravedigger` card at the altar covers it.
3. Counsel events the Depths track owns (`depths_solo`, `depths_floor`, `depths_affix`) and `laborers_seen` are still not raised by the rebuild.
4. `main/qa_driver.gd` teleports the hero to z=9 (inside the Chapterhouse now); the Graves start at z<=4. Harmless (QA only), noted.
5. Ground labels are on for everyone; if the owner finds them too busy in big fights, `DmLootView.near_labels = false` is the single switch.
