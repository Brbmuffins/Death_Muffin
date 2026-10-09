# First hour and loot notes

Findings from a scripted first-hour run through DmNextGame (new Gravecaller, waves on, headless; event / counsel / guidance stream read with
timestamps) and the loot fixes that came out of it. Not done: a human-paced rendered hour. Loot test: `tests/next_loot/run.gd`.

## Behaves as intended
- Spawn in the Chapterhouse: Next line "Walk north into the Hollow Graves and fight your first dead"; welcome / belt / people cards come calm, one at a time.
- Entering the Graves: area banner + Codex entry, `elite` / `move` / `hurt` cards, "Kennel Loosed" banner, Kill Chain card, Chain of 10 gold.
- First gear pickup: loot toast + `relic` card ("Loot goes to your Reliquary"), then `atlas` / `affix` cards.
- Dying mid-fight puts the Next line back to the Graves until 10 kills.

## Loot fixes now in the code (`next/hud/dm_next_ui_host.gd`, `loot_view/loot_view.gd`)
- Rule "Sell for gold" pays the purse (`auto_sold` is connected) with a "+Ng name" float and the coin sound. Rule "Auto-loot" gives the walk-over feedback.
- `keep` is set from `DmItemText.keeps_for_you`, so the gold rule never sells upgrades for you.
- Gold / shards walked over in one frame give one float and one sound; the gold / shard puff is connected.
- Bag full: the "Reliquary full" float plus one toast on what to do; re-armed once there is room.
- Pickup toast colour = beam colour; better-than-worn gear says "(upgrade)".
- Ground: item names in rarity colour within 7 m (3 m ordinary), icon blinks in the last 8 s, drops from one kill land >= 0.65 m apart. Loot never flies to you.
  `DmLootView.near_labels = false` turns the names off.

## Open
1. After entering the Graves the Next line is "Ossuary seal: 0/300 kills" (shared `DmGuidance`). A softer first goal ("kill 10 dead, walk over what drops") would read better; it means changing the shared rules.
2. The Gravedigger shard hint is priority 50, under the seal line (60), so it only shows once shards are in hand.
3. Counsel events `depths_solo`, `depths_floor`, `depths_affix` and `laborers_seen` are not raised by DmNextGame.
