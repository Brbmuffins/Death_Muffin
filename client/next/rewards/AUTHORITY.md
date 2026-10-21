# Value on the server

How the game scene keeps value on the server (DECISIONS D1, B20, B32). The rewards node and this player's loot: [README.md](README.md).

The backend owns value (DECISIONS D1, B20, B32), and the game scene earns it as follows. On the host (`DmNextGame._start_value`, under the loading cover):
- **Rewards** (`next/rewards/dm_session_rewards.gd`): a kill is the game's `kill_credited` (the core's EV_ENEMY_DIED, credited once, to the hero who struck it or the owner of the thrall
  whose blow it was), not each enemy's `died`; everything after it: who earned it (alive, within 38 m), the Kill Chain for the killer, the loot roll from the member's drop tape,
  the gold pool, and the numbered kill reports of the backend's party session, whose replies decide the XP and kill counts applied. Lifesteal hears `DmCoreHost.struck` (a hero's direct blow
  through `damage`; a DoT tick or a thrall's swing never is one). A boss's defeat pays through `on_boss_defeated` (the boss host calls it).
- **Meta, milestones, Chronicle, progression** (`next/meta/dm_next_meta.gd`, `next/areas/dm_wave_milestones.gd`, the Chronicle and `DmNextProgress`):
  difficulty, the week's Omen, Soul Harvest, the Kill Chain, the level-ups, the upgrade tiers, the belt, and the saves through
  `DmProgressSync`. The host's world (its difficulty) reaches the lobby (`DmNextParty.sync_world`).
- **No Ascension** (DECISIONS B36): a character's saved vows, boons and Ashes stay on the server, untouched, and do nothing here: the world runs without vows (no heat,
  the rewards' rank 0, the base corpse lifetime), a build reads its progression without them (`DmNextGame.without_ascension`), no Covenant Boon acts (the Bonded Dead
  do not rise) and the party's world carries no heat. One switch, `DmAscension.OPEN` (false), hides what is left of it on screen: the
  Chapterhouse's Altar is scenery (not interactable; the `altar` station opens nothing), the guides neither offer it nor name a rank
  (`DmGameUi.guidance_state`), the Prior has no Altar topic, the Codex no Altar page (`DmCodexPanel.shown_tabs`), and party, friends and
  invite rows show the host's difficulty without Heat (`DmNextFriends.world_line`). The redesign turns it back on.
- **The loot node** (`next/rewards/dm_next_loot.gd`: the take, pickup, claim and rune-ownership paths, apart from the
  panels): a click on a drop walks the hero there and takes it on arrival (loot never flies; walking over it takes nothing); a drop rolled from the tape is claimed, and the server puts its
  own roll in the bag; a rune the character owns (learned, bag, Vault) never drops. The bag is the server's rows (`DmInventory`); worn gear feeds the build, and the belt drinks from it.
- **The HUD** reads the member's progression (level, XP, gold, shards, tiers), shows the upgrades box and the wave dial by the veteran-reveal rules (`DmHudReveal.veteran_reveals`), the belt, the Kill
  Chain, the Omen and the save chip, and the toasts, banners, floats and pickup lines of `DmNextGame.game_event`.
- **Saving:** `flush_all` (leave, the window's close) ends the party session with its last batch and flushes the Chronicle, the progression and the bag.

**A party guest earns on its own account** (DECISIONS B22, the handshake in `DmNextParty`): the host makes it a rewards member (its character id, remote, rolling its own
drops), its `DmNextJoiner` (`next/party/dm_next_joiner.gd`) joins the host's backend party session with the guest's own token and holds its progression,
saves and drop tape; the host reads the guest's build from the server (`remote_builds`: gear, sets, boons, vows, runes) once it joined and whenever its worn gear changes; the
host's accepted reports, gold, shards and drop events go to the guest, which rolls its items from its own tape and claims them into its own bag; its belt drinks from its own
bag and the host applies the drink.

**Ground drops between members** (ground.cjs): the Reliquary's Drop (`DmNextUiHost.drop_gear`) puts a piece on the party session's ground; the party draws it for the members the server
lets take it (`DmNextParty.share_ground`), the first pickup wins (`DmNextLoot`'s claim, `api.ground_pickup`) and the other copies go (`share_taken`). A rune's or a legendary's find is a
chat line the party reads (`DmNextParty.announce`).

The Covenant Seal's altar choice and the boss key prompt (`DmBossMeta`) are in ([The bosses](../bosses/CORE-INTEGRATION.md)).
The suites, `rewards.gd` and `value.gd`, and what each plays: [README.md](README.md) "Tests".
