# Death Muffin audio map (ESM Fantasy Game pack)

Owner goal: every sound the game makes comes from the licensed ESM Fantasy Game pack (Epic Stock Media), immersive but never a wall of noise. This is the design; the data is `src/content/audioMap.ts` (`AUDIO_MAP`). **No audio files are in the repo** (licence): the table names clips only. A local agent wires it into `src/audio/`.

Clip names in the table are exactly the lines of `docs/audio/esm-fantasy-game-files.txt` (folder + name, minus the `ESM_Fantasy_Game_` prefix and `.wav`). The map was made from names alone, never by ear, so every entry marked `partial` below needs a listen before it ships. Everything marked `keep` stays on today's sound.

## Numbers

- Sound ids mapped: **181** (90 existing ids, call sites unchanged, plus 91 new ids).
- Fully mapped: 167; `partial` (pack clip used, imperfect fit, listen first): 11; `keep` (no pack clip fits, existing sound stays): 3.
- New events to wire (silent or overloaded today): 91 ids across 14 files.

The pack is 517 clips; 318 are referenced (including layers), the rest are listed under "Rejected" or are spare footstep variants.

## What the pack does not have (and what that costs)

| Gap | Effect | Decision |
|---|---|---|
| No bells | toll, tollSmall, bossToll, distantBell, the monk "toll" family | `toll`, `tollSmall`, `bossToll` are `partial`: a metallic ring clip is layered over the existing Kenney bell, which STAYS. `distantBell` is `keep`. Bells are the diocese's signature, so do not drop them. |
| No wind / air movement | windGust, the zone wind beds | `windGust` is `keep`. |
| No looping ambience beds | all 13 zone beds in `ambience.ts` | **Keep the existing beds** (`bed_wind/hollow/water/fire/murmur`). The pack is one-shot accents; a one-shot cannot be a seamless 60 s loop without audible seams. Only the sparse accents (drips, bubbles, dust, ember crackle, crows, creaks, moans) move to the pack, all quiet and low priority. |
| No heartbeat / pulse | `lowHealth` (new) | `keep`: add a tiny synth heartbeat in `Audio.ts`. |
| No human or NPC voices | hurt grunts, NPC talk | Player hurt is an impact only. NPC dialogue gets a parchment rustle (`dialogueOpen`) and nothing spoken. |
| No water drip | `waterDrip` | `partial`: single liquid pops. |
| No per-material footsteps for bone / wood / mud | | Four surfaces only: stone, dirt, grass, water. |

## Buses and mapping to today's mixer

`SoundDef.bus` is one of `sfx`, `ui`, `ambience`, `voice`. Today's mixer (`src/audio/mixer.ts`) has `combat / enemies / thralls / ui / ambience`; map them like this and keep its priority and thinning logic:

| SoundDef bus | Existing mixer bus | Notes |
|---|---|---|
| `sfx` | `combat` for the player's own rites and boss sounds, `enemies` for enemy-side sfx, `thralls` for `thrall*` ids | Decide by id, as `PROFILES` does today. |
| `voice` | `enemies` | Creature growls and roars, capped separately (see below). |
| `ui` | `ui` | Non-spatial. |
| `ambience` | `ambience` | Spatial accents only; beds stay as they are. |

`priority` (1-5) maps to the mixer's 0-10 as `priority * 2` (5 = 10 = player hurt, boss tells). Under load, lowest priority sheds first, as today.

## Mixing rules

1. **Own sounds are full, others are faint.** Same rule as the visuals ("own spells full, others faint"). The player's own casts and impacts play at `volume`. A partner's (remote player's) spells and hits play at `MIX_RULES.partnerSpellGain` (0.35), footsteps at 0.25, and only within 22 m, at most 4 partner sounds at once. A 10-player party is therefore at most one extra "voice" worth of sound, not ten.
2. **Per-id caps and cooldowns** are in the table (`maxVoices`, `cooldownMs`). Spammed ids (needle, hits, coins, thrall attacks) have tight cooldowns (40-120 ms); big moments (litany, bossAwaken, levelUp) have `maxVoices: 1` and long cooldowns. A repeated id also attenuates by the existing `repeatGain` (1, 0.78, 0.6, ...).
3. **Bus ceilings:** sfx 14, voice 5, ui 6, ambience 6, global 32 (`MIX_RULES`). Priority 5 sounds are always admitted (plus the existing reserve).
4. **Voice (creature) thinning:** same enemy voice id at most twice per 500 ms and `eliteAggro` once per 4 s. Enemy attack growls play only for enemies within 18 m of the listener and never for more than two enemies per second. Deaths: one voice per 100 ms window max 3 (already the case for `enemyDeath`).
5. **Thralls stay quiet:** `thrall*` ids are 0.22-0.28 volume, thinned to 3 per 100 ms (existing), and have NO footsteps.
6. **Ducking under danger tells.** `bossToll`, `bossTell*`, `bossAwaken`, `bossPhase`, `hurt`, `playerDeath` and `surgeStart` duck sfx/voice/ambience (`MIX_RULES.duck`: e.g. bossToll takes 30% off sfx, 40% off voices, 60% off ambience for 0.7 s then releases over 0.7 s). Danger tells are priority 5 and are never culled by distance. Play a boss tell once at the START of the telegraph, not on release, so the player hears it while it can still be dodged.
7. **Combat steps the ambience back** exactly as `CombatActivity` does now; accents (`waterDrip`, `crowCaw`, ...) wait until the fight is quiet.
8. **Footsteps:** one id per surface, round-robin 4 clips, a step every ~1.6 stride units as now. Wading overrides the surface. Own steps only (partners at 0.25 in range 22 m, max 1 at a time). Hush: graves 0.8x.
9. **UI never carries reverb:** the `Dry` clip variants are chosen on purpose. `uiNew` has a 4 s cooldown so a queue of counsel tips is not a jingle.
10. **Loops:** the pack has no loopable clips. Rite beds (`miasmaLoop`, `siphonLoop`, ...) set `loopMs`: play a short quiet clip every `loopMs` while the effect lasts, `maxVoices: 1`. Stop on the matching `*Gone` event.
11. **Pitch jitter** 5-10% on everything frequent, ~1-3% on UI so it stays crisp. `rate` derives darker/brighter variants of one clip (e.g. enemy death voices at 0.8x-1.1x) instead of spending more clips.
12. **Trim:** clips with `trim.maxMs` are faded at that length (crafting clips are workshop sequences several seconds long; rite casts should be cut to the telegraph).

## Rites: which sound carries which element

Elements follow `SPELL_FX` colour meaning: shadow/dark conjure for the necromancer, poison for rot, ice for frost, fire for ember, earth for bone.

| Rite | Id (cast / extra) | Pack family | Why |
|---|---|---|---|
| Bone Needle | needleCast / needleHit | Knife Throw, Shadow Arrow / cloth + weapon impact | ivory sliver, small dry tick |
| Marrow Spear | spear / boneHit | Earth Instant Cast | bone = earth |
| Exhume | exhume | Earth Spell + Shadow Spell | grave earth then spirit |
| Miasma Circle | miasma / miasmaLoop | Long Poison, Poison | rot green |
| Black Litany | litany | Arcane Long Cast + Dark Transition Lightning | violet void |
| Corpse Explosion | **corpseExplode** (new) | Fire Instant Cast, Felflame + gore tail | ember + crimson |
| Wailing Skull | wail | Water Bolt (hollow, creepy) | jade spirit |
| Grave Step | bloodStep | Dark Transition Airy + Shadow Instant | crimson mist |
| Grave Frost | frost | Ice Instant Cast | cold blue |
| Bone Mantle | mantle | Earth Long Cast | aged bone |
| Bone Fan | **boneFan** | Crossbow volley | three slivers at once |
| Rot Lance | **rotLance** | Poison + Shadow Instant | chartreuse rot |
| Grave Offering | **graveOffering** | Item Collect Dark Magic | essence taken |
| Ivory Cleave | **ivoryCleave** | Axe Throw + Draw Heavy | wide crescent |
| Veil Step | **veilStep** | Airy Sting + Shadow Instant | jade, distinct from Grave Step |
| Rally the Dead | **rallyDead** | Craft Magic Buff, Conjure Upgrade | a buff, not a raise |
| Carrion Seed | **carrionSeed** / seedBurst | Craft Drop Reagent / Poison | plant, then pop |
| Soul Siphon | siphon / siphonLoop | Magic Essence | draining |
| Bone Prison | prison | Earth Long + Instant | spikes ring |
| Grave Hands | hands / handsLoop | Stone debris + slide | clawing up |
| Bone Storm | storm / boneStormLoop | Rain of Bolts / Arrows, debris | flying fragments (not weather: Lightning rejected) |
| Thralls | thrallRise, thrallMelee/Shot/Magic, **thrallDeath** | Poof Buff, Cloth Hit, Bow, Magic Arrow, Crate Break | quiet by design |
| Ossuary Wall | sigWall | Stone Door drag, Stone Slide | wall rises |
| Command: Rend | sigRend | Shadow Instant + Weapon Impact | legion cleave |
| Dirge | sigDirge / dirgeLoop | Ice Long Spell | cold-blue funeral song |
| Plague Bloom | sigBloom / bloomPulse | Poof Buff + Poison | chartreuse |
| Hollow Knight: Hollow Cut, Shield Bash, Grave Slam (+Land), Bulwark (+Block), Oath Unbroken, Corpse Vigil, Grave Brand | **hollowCut, shieldBash, graveSlam, graveSlamLand, bulwarkRaise, bulwarkBlock, oathUnbroken, corpseVigil, graveBrand** | Axe Throw / Draw Heavy, Weapon Impact + Metal Latch, Meteor Hit, Metallic Sting, Dark Conjure, Meditation, Magic Trap | cold steel + oath crimson, never bronze |
| Warden / Monk / Witch / Veilwalker | pyre, lantern, ward, flail, chain, choir, palm, crow, bloodRite, veilRite, spiritBolt | Fire Long, Holy A-D, Draw Heavy, Trap, Holy B + Meditation, Target Weakness, Crow, Blood Impact, Airy Sting, Arcane Missile | colour = element |

## Enemies and bosses

Enemy melee is **silent today** (`WorldScene.ts:2818`). New voice ids by family (`ENEMY_VOICE` in the data): beast (hound, rat, bat, ghoul, cinderhound, mire leech), humanoid (robber, penitent, deacon, risen, censer, acolyte, templar, plague doctor, flagellant, cinder husk, pyre priest, bog hag, drowned sexton), brute (bone golem, slag brute, carrion sac, gargoyle), spirit (choir wraith, weeping seraph, shroud moth, fen wisp). The skull niche is silent (its break is `nicheBreak`). Each family has `enemyAttack*` and `enemyDeath*` (the existing `enemyDeath` body-drop still plays; the voice is on top, rate-shifted per family).

Boss and enemy tells are the danger channel (priority 4-5, ducking, never distance-culled):

| Boss | Tell id (`BOSS_TELL`) | Pack family |
|---|---|---|
| Bell-Sworn Prelate | bossToll (+ raise) | Metallic Sting + Dark Conjure (no bell: partial) |
| Gravedigger King, Bone Abbess | bossTellEarth | Earth Long Cast |
| Drowned Congregation, Mire Mother | bossTellWater | Water Bolt |
| Plague Saint | bossTellRot | Long Poison |
| Cinder Regent | bossTellFire | Fire Long Spell |

Plus `bossSlam` (Meteor Hit), `bossAwaken` (dark lightning + long low growl), `bossPhase` (thunderstorm + growl), `bossDefeat` (holy release), `bossSummon` (totem scroll), `nicheBreak` (pot smash), `slagSlam` (molten lava hit), `emberBurst/emberThrow` (Felflame, fire arrow), `tellStrike` for ordinary enemy wind-ups.

## Footstep surfaces per area

`AREA_SURFACE` in the data. `stepWater` overrides wherever the player wades (`worldView.isWet`, the same test the ripples use).

| Area | Surface | Notes |
|---|---|---|
| The Chapterhouse | stone | |
| The Sexton's Acre | grass | 0.9x |
| The Hollow Graves | dirt | 0.8x (hushed, as today) |
| The Marrow Ossuary | stone | |
| The Drowned Nave | stone | water in flooded aisles |
| The Bell Sanctum | stone | |
| The Plague Cloister | stone | water in rot pools |
| The Cinder Pyre | dirt | ash and cinder |
| The Alchemist's Wing | stone | no wood-floor clips; 0.8x |
| The Catacomb Warren | dirt | packed earth tunnels |
| The Bone Coliseum | dirt | sand arena |
| The Catacomb Depths | stone | |
| The Mourning Fen | grass | dry hummocks; water everywhere it wades |

## Ambience per area

Keep every existing bed (`ZONE_BEDS`): the pack has no loops. Accents (`ZONE_ACCENTS`) keep their ids; the ones with a fitting clip move to the pack (marked below). Quiet by design.

| Area | Bed (kept) | Accents from pack | Accents kept on old sound |
|---|---|---|---|
| Chapterhouse | hollow + wind | waterDrip (partial), graveCreak (partial) | distantBell |
| Sexton's Acre, Hollow Graves | wind | crowCaw (partial), graveCreak | distantBell, windGust |
| Marrow Ossuary, Catacomb Warren, Depths | hollow | waterDrip, dustFall, graveCreak | |
| Drowned Nave | hollow + water | waterDrip, crowdMoan (partial) | distantBell |
| Bell Sanctum | hollow + wind | graveCreak, crowdMoan | distantBell |
| Plague Cloister, Mourning Fen | water + hollow + wind | bogBubble, waterDrip | |
| Cinder Pyre | fire | emberCrackle | windGust |
| Bone Coliseum | murmur + wind | crowdMoan | distantBell, windGust |
| Alchemist's Wing | fire (low) + hollow | waterDrip, emberCrackle, optional gardenReady / forgeFire | |

## New call sites to wire

All of these are silent today or reuse an unrelated sound. Line numbers are at the time of writing (branch `dm/audio-map`).

| New id | Where to call it / trigger | Notes |
|---|---|---|
| `rotLance` | src/gameplay/AbilitySystem.ts:1712 (cast, today needleCast), src/gameplay/AbilitySystem.ts:1744 (hit, today needleHit) | Rot Lance: chartreuse rot, a poison hiss on a dark cast. |
| `boneFan` | src/gameplay/AbilitySystem.ts:1646 (cast, today needleCast) | Bone Fan: three slivers loosed together; crossbow volley. |
| `ivoryCleave` | src/gameplay/AbilitySystem.ts:1832 (today spear 1.3) | Wide bone crescent sweep. |
| `hollowCut` | src/gameplay/AbilitySystem.ts:1999 (today spear 1.45) | Hollow Knight sword arc. Cold steel, never bronze. |
| `veilStep` | src/gameplay/AbilitySystem.ts:1864 (today bloodStep 1.3) | Veil Step (spirit jade) must not sound like Grave Step (crimson mist), same as the visual rule. |
| `rallyDead` | src/gameplay/AbilitySystem.ts:1905 (today thrallRise) | Rally the Dead: a buff, not a raise. |
| `carrionSeed` | src/gameplay/AbilitySystem.ts:1918 (plant, today miasma 1.2) | Planting a rot seed: a sizzling reagent drop. |
| `seedBurst` | src/gameplay/AbilitySystem.ts:1949 (today burst), src/scenes/WorldScene.ts:2905 case 'seeded' | Seed pops when an enemy nears. |
| `graveOffering` | src/gameplay/AbilitySystem.ts:1786 (today shard) and src/gameplay/AbilitySystem.ts:1789 (today exhume) | Burning a corpse for essence. |
| `corpseExplode` | src/gameplay/AbilitySystem.ts:2245 (today burst), src/scenes/WorldScene.ts:2992 case 'detonated' | Corpse Explosion (ember + crimson, bone shrapnel): fire boom with a gore tail. The big signature of the necromancer, so it can be loud, but cap at 3 voices for chain detonations. |
| `shieldBash` | src/gameplay/AbilitySystem.ts:2025 (today bloodStep 1.2) | Shield bash: steel on bone. |
| `graveSlam` | src/gameplay/AbilitySystem.ts:2055 (leap, today bloodStep 0.9) |  |
| `graveSlamLand` | src/gameplay/AbilitySystem.ts:2082 (today boneHit 0.8) | Landing; quieter than a boss slam (bossSlam v 0.9). |
| `bulwarkRaise` | src/gameplay/AbilitySystem.ts:2095 (today shard 0.8) |  |
| `bulwarkBlock` | src/gameplay/Player.ts (where bulwarkPerfectUntil is tested on a hit; silent today) | Perfect block: a ringing clank. Needs a tiny hook; the player-hurt path must NOT also play hurt for it. |
| `oathUnbroken` | src/gameplay/AbilitySystem.ts:2134 (today litany 0.9) | Oath crimson: dark conjure, not the violet litany. |
| `corpseVigil` | src/gameplay/AbilitySystem.ts:2148 (today exhume 0.9) |  |
| `graveBrand` | src/gameplay/AbilitySystem.ts:2167 (sprung, today boneHit) and src/gameplay/AbilitySystem.ts:2172 (today shard) | A magic trap snapping shut. |
| `thrallDeath` | src/graphics/EntityViews.ts:710 (today boneHit 0.6) | Thrall collapses into bones. Quiet, within 24 m of the focus only (existing rule). |
| `thrallBind` | src/graphics/EntityViews.ts:718 (today thrallRise) | Optional: partner-raised thralls (EntityViews). Same clip family as thrallRise, so can be skipped. |
| `miasmaLoop` | src/gameplay/AbilitySystem.ts:835 start, src/scenes/WorldScene.ts:2839 case 'zone' / 2842 'zoneGone' stop | Rot pool bed, 6 s: a soft hiss every 1.8 s while enemies stand in it. |
| `siphonLoop` | src/gameplay/AbilitySystem.ts:1170 start (3 s tether) |  |
| `handsLoop` | src/gameplay/AbilitySystem.ts:1261 start (3 s field) | Raking earth. |
| `boneStormLoop` | src/gameplay/AbilitySystem.ts:1306 start (4 s tornado) | Fragments shredding; rapid dry debris ticks. |
| `dirgeLoop` | src/gameplay/AbilitySystem.ts:2199 (signature dirge, 4 s mend) |  |
| `bloomPulse` | src/gameplay/AbilitySystem.ts:2199 (plague bloom pulse every 2 s) |  |
| `crowSwarmLoop` | src/gameplay/NewBloodSystem.ts (crowsUntil / murderUntil ticks) | Crow Swarm / Murder of Crows beds. Creature_High_* may read as monster squeals; verify, else keep the synth. |
| `enemyAttackBeast` | src/scenes/WorldScene.ts:2818 (WorldScene.ts:2818 case melee, look up the def like the Pyre spark code beside it) | Hound, rat, bat, ghoul, cinderhound, mire leech. Silent today: enemy melee has no sound at all. |
| `enemyAttackHumanoid` | src/scenes/WorldScene.ts:2818 | Robber, penitent, deacon, risen, censer, acolyte, templar, plague doctor, flagellant, cinder husk, pyre priest, bog hag, drowned sexton. |
| `enemyAttackBrute` | src/scenes/WorldScene.ts:2818 | Bone golem, slag brute, carrion sac, gargoyle. |
| `enemyAttackSpirit` | src/scenes/WorldScene.ts:2818 | Choir wraith, weeping seraph, shroud moth, fen wisp. |
| `enemyDeathBeast` | src/scenes/WorldScene.ts:2799 case death, in addition to enemyDeath (look up ev.def) |  |
| `enemyDeathHumanoid` | src/scenes/WorldScene.ts:2799 |  |
| `enemyDeathBrute` | src/scenes/WorldScene.ts:2799 |  |
| `enemyDeathSpirit` | src/scenes/WorldScene.ts:2799 |  |
| `eliteAggro` | src/scenes/WorldScene.ts:3057 case spawn, elites only, within 40 m | An elite announces itself. Global 4 s cooldown so a pack does not roar in unison. |
| `tellStrike` | src/scenes/WorldScene.ts:3190 telegraph default branch (today boneHit) | The wind-up of an ordinary enemy blow or ground ring. Danger tells outrank everything but boss tells. |
| `affixTell` | src/scenes/WorldScene.ts:3018 case affix (hungering feed, vengeful burst) |  |
| `surgeStart` | src/scenes/WorldScene.ts:3023 case surge | Grave Surge (enemy bell bronze): ominous thunder under the crypt. |
| `surgeCleared` | src/scenes/WorldScene.ts:3026 case surgeCleared |  |
| `surgeFailed` | src/scenes/WorldScene.ts:3029 case surgeFailed |  |
| `bossTell` | src/scenes/WorldScene.ts:3964 areaBossEvent, ms > 0 for any boss without an element entry | Generic boss wind-up. Play once at the START of the telegraph, never on release. Ducks thralls/enemies/ambience. |
| `bossTellEarth` | src/scenes/WorldScene.ts:3964 areaBossEvent: at the start of every telegraph (ms > 0), pick by ev.boss via BOSS_TELL (Gravedigger King, Bone Abbess) | Grave dirt and bone. |
| `bossTellWater` | src/scenes/WorldScene.ts:3964 areaBossEvent, ms > 0, ev.boss congregation or mire (BOSS_TELL) | Hollow liquid; the Nave and Fen bosses. |
| `bossTellRot` | src/scenes/WorldScene.ts:3964 areaBossEvent, ms > 0, ev.boss saint (BOSS_TELL) | Rot gas hiss. |
| `bossTellFire` | src/scenes/WorldScene.ts:3964 areaBossEvent, ms > 0, ev.boss regent (BOSS_TELL) | Rising fire. |
| `bossPhase` | src/scenes/WorldScene.ts:4281 case phase | Phase change / enrage. |
| `bossSummon` | src/scenes/WorldScene.ts:2097 interactable kind boss (the altar that wakes it) | The ritual that wakes a boss, just before bossAwaken. |
| `nicheBreak` | src/scenes/WorldScene.ts:4243 case nicheBreak (Abbess skull niches) | Shattering a skull niche. Pot smash reads as dry brittle shatter. |
| `lowHealth` | src/scenes/WorldScene.ts:3790 onHurt, and a 2.5 s tick while hp < 30% | NO FIT: no heartbeat / pulse clip. Add a synth heartbeat in Audio.ts (low sine thump pair). Not routed through the pack. |
| `drinkFlask` | src/scenes/WorldScene.ts:1989 drinkFlask after player.heal | Heal flask (Q). Own action, non-spatial. |
| `drinkElixir` | src/scenes/WorldScene.ts:1864 drinkBuff (Z elixir / X tonic) |  |
| `eatMeal` | src/scenes/WorldScene.ts:1848 eatMeal |  |
| `lootDrop` | src/graphics/LootView.ts:157 item() when rarity is common/uncommon | A gear piece clatters to the ground. |
| `lootDropRare` | LootView.ts:157, rare | Magic touch variant: a glint in the clatter. |
| `lootDropEpic` | LootView.ts:157, epic |  |
| `lootDropLegendary` | LootView.ts:157, legendary (and legendary-set pieces) | A bright chime so it can be heard across the room. Rare, so loud is fine. |
| `lootLegendary` | src/audio/mixer.ts lootSfx() (returns lootEpic for legendary today) | Pickup of a legendary; lootSfx should return it before the epic check. |
| `goldPileDrop` | LootView.ts:89 gold() | Optional. Skip if coin spam is a concern; coin pickup already covers gold. |
| `pickOre` | src/scenes/WorldScene.ts:2556 and src/graphics/LaborerViews.ts:351, node.kind === 'seam' (SKILLS.mining.sfx is one id for seams and geodes) | Ore seams ring; geodes use pick (stone). |
| `gatherHerb` | src/scenes/WorldScene.ts:2556, node.kind === 'herb' |  |
| `nodeDepleted` | src/scenes/WorldScene.ts:2808 case nodeGone | The node is spent. Quiet. |
| `gardenTend` | src/scenes/WorldScene.ts:2556 and LaborerViews.ts:351 for skill gardening (today shovel) |  |
| `gardenPlant` | src/scenes/WorldScene.ts:1385 onGardenResult plant (today click) |  |
| `gardenHarvest` | src/scenes/WorldScene.ts:1385 onGardenResult harvest (today coin) |  |
| `gardenReady` | src/scenes/WorldScene.ts:314 gardenReady (when a bed turns ripe) | Optional soft cue. |
| `brewTick` | src/scenes/WorldScene.ts:2556 and LaborerViews.ts:351 for skill alchemy (today splash) |  |
| `brewCraft` | src/scenes/WorldScene.ts:1077 forge callback, station === 'cauldron' (today craft) |  |
| `craftWeapon` | src/scenes/WorldScene.ts:1077 forge callback when the crafted item is a weapon or staff (today craft) |  |
| `craftArmor` | src/scenes/WorldScene.ts:1077, armor or shield |  |
| `craftMagic` | src/scenes/WorldScene.ts:1077, runes, rings, gems, enchanted pieces |  |
| `forgeFire` | src/scenes/WorldScene.ts:2060 interactable fire/kiln when the forge panel opens | Optional: a flare as the hearth is opened. |
| `chestOpen` | src/scenes/DepthsController.ts:300 openChest (silent today; the drops that fan out play lootDrop*) | Latch then lid. |
| `waystoneTravel` | src/scenes/WorldScene.ts:2027 teleportTo (silent today) | Waystone / recall arrival. |
| `recallStart` | src/scenes/WorldScene.ts:1994 startRecall (silent today) |  |
| `recallCancel` | src/scenes/WorldScene.ts:2001 cancelRecall |  |
| `runeSocket` | src/scenes/WorldScene.ts:871 runeSocketed |  |
| `dialogueOpen` | src/scenes/WorldScene.ts:1096 DialoguePanel onChange (talkTo an NPC) | The pack has no voices; a parchment rustle marks a conversation opening. |
| `questAccept` | src/ui/ContractsPanel.ts (accept an order) |  |
| `orderFilled` | src/scenes/WorldScene.ts:1440 (Order filled toast) |  |
| `uiTab` | tab switches: src/ui/CodexPanel.ts:118-122 [data-tab], and the same pattern in Grimoire / Forge / Professions / Ascension panels |  |
| `uiSelect` | selecting a rite / slot / list row in Grimoire, Legion, Reagent Shelf |  |
| `uiConfirm` | confirm buttons: bind rune, craft, assign loadout |  |
| `uiNew` | src/ui/Onboarding.ts:699 show() when a counsel card opens; HUD.ts:806 banner() for non-combat news | The NEW cue: soft sparkle. Cooldown 4 s so a tip queue is not a jingle. |
| `panelOpenInventory` | src/scenes/WorldScene.ts:1447 togglePanel, p === 'inventory' |  |
| `panelOpenBook` | src/scenes/WorldScene.ts:1447, codex, grimoire, ascension, atlas, contracts |  |
| `panelOpenForge` | src/scenes/WorldScene.ts:2060-2072 opening forge / cauldron / salvage |  |
| `stepStone` | src/scenes/WorldScene.ts:4614 (today step) | Chapterhouse, Ossuary, Bell Sanctum, Depths, Warren floors, Alchemist's Wing. |
| `stepDirt` | src/scenes/WorldScene.ts:4614 | Hollow Graves, Warren, Pyre, Coliseum. |
| `stepGrass` | src/scenes/WorldScene.ts:4614 | Sexton's Acre and the dry hummocks of the Fen. |
| `stepWater` | src/scenes/WorldScene.ts:4614 when worldView.isWet(p.x, p.z) (the wade test the ripples use) | Overrides the area surface wherever the player wades (Nave flood, Fen, Cloister pools). |

Also change existing call sites that reuse an id for the wrong thing: `step` becomes `STEP_SOUND[AREA_SURFACE[area]]` (water if `isWet`) at `WorldScene.ts:4614`; `lootSfx()` in `mixer.ts` returns `lootLegendary` before `lootEpic`; `SKILLS[...].sfx` (`gatheringRules.ts:35-41`) should resolve to `pickOre` / `gatherHerb` by node kind, `brewTick` for alchemy, `gardenTend` for gardening.

## IDs with no (or only a partial) pack fit

| Id | Status | Reason |
|---|---|---|
| `distantBell` | **keep** | NO FIT: the pack has no bell. Keep the existing amb_bell clips. |
| `windGust` | **keep** | NO FIT: no wind / air-movement clips in the pack. Keep the existing amb_gust. |
| `lowHealth` | **keep** | NO FIT: no heartbeat / pulse clip. Add a synth heartbeat in Audio.ts (low sine thump pair). Not routed through the pack. |
| `crow` | **partial** | Witch crows. Only one clip is named Crow; verify by ear, else keep existing amb_crow. |
| `toll` | **partial** | Bell-Tolled elite tell. NO bell in the pack: a metallic ring only. Keep the existing Kenney bell and layer this sting on top. |
| `tollSmall` | **partial** | Small bell toll (affixes, boss rings, corpse-explosion ring). PARTIAL as for toll: keep the existing bell, layer the pack ring. |
| `bossToll` | **partial** | Prelate toll tell (danger). No bell: dark conjure body plus metallic sting. Keep the existing octave-down Kenney bell underneath until a bell exists. |
| `wave` | **partial** | Wave spawn / breach: a low distant rumble. Verify it is not too musical. |
| `shovel` | **partial** | Gravedigging (grave node). Gritty drags read as a spade in soil; verify by ear. Gardening and salvaging share this id today: use gardenTend / grind. |
| `graveCreak` | **partial** | Wood-lever creaks stand in for crypt creaks; low and rare. Verify; else keep the synth. |
| `waterDrip` | **partial** | No true drip clip: single liquid pops/plops (UI dry versions). Verify; else keep amb_drip. |
| `crowCaw` | **partial** | "Creature Crow Distant" is monster-voice processed. Verify it reads as a bird; else keep amb_crow. |
| `crowdMoan` | **partial** | Massed dead far off (Nave, Coliseum): low growl and insanity whisper at a whisper, low-passed by the ambience bus. Verify; else keep amb_moan. |
| `crowSwarmLoop` | **partial** | Crow Swarm / Murder of Crows beds. Creature_High_* may read as monster squeals; verify, else keep the synth. |

## Rejected clips and why

| Clips | Why not |
|---|---|
| `Magic_Lightning_*`, `Magic_Thunderstorm_*` (mostly) | Weather/storm colour; no necromancer rite is lightning. Two thunderstorm clips are used only for the Grave Surge and boss phase change, where thunder is the point. |
| `Magic_Ice_Blizzard_*`, `Attack_Ice_Arrow`, `Magic_Ice_Instant_Cast_D`, `UI_Ice_*` | Frost is only Grave Frost and Dirge, already covered. |
| `Magic_Fire_Instant_Cast_C/E`, `Magic_Fire_Spell_B`, `Felflame_4` | Fire is limited to Pyre enemies, the Regent and Corpse Explosion; spares kept in reserve. |
| `Arcane_Missile_*_Dry` | A drier twin of the wet missile; one set is enough for spiritBolt. |
| `Item_Pickup_Sword/Axe/Mace/Maul/*_Armor`, `Item_Pick_Up_*` | Per-gear-type pickups. Good optional upgrade: `lootDrop` could vary by gear type (`Item_Pickup_Sword` for weapons, `Item_Pickup_Metal_Armor` for plate). Not in the base table to keep ids simple. |
| `Item_Collect_Magic_D-K`, `Item_Collect_Dark_Magic_F/I/J` | Spare pickup variants; the cap is 4 variations per id. |
| `Item_Crafting_*` (most) | Workshop clips are multi-hit sequences several seconds long; one or two per category are used, trimmed. The rest are spares for item-specific crafting if the ForgePanel ever exposes the crafted type. |
| `Item_Crafting_Crystal_Bow`, `Crossbow`, `Bolts`, `Wooden_Shield` | The necromancer's gear has no bows, bolts or crystal weapons in the Forge. |
| `Attack_Bow_D-F`, `Attack_Crossbow_D/E` | Spares; thralls and Bone Fan use A-C. |
| `Door_Open/Close_Medium_Small`, `Large_Gate_Close*`, `Box_Raise_Latch`, `Material_Wood_Lever_1-3` | Wooden-door clips: the game's doors are stone arches and gates. `Stone_Door_*` is used. Wooden doors are kept as spares for the Alchemist's Wing door if one is added. |
| `Craft_Armor_or_Weapon_1/2`, `Crafting_Select_Ore/Wood`, `Crafting_Metal_Trap` | "Select" clicks for a crafting UI the game does not have. |
| `Material_Stone_Pick_Up_*`, `Material_Stone_Light_Hit_*`, `Material_Stone_Touch_7/8`, `Inventory_Material_Stone_UI_*` | Stone-material accents, near duplicates of clips already used for the Vault, dust and loot drops. |
| `UI_Earth/Fire/Ice/Lightning_Select`, `UI_Metal_Armory_*_Wet`, `Craft_Air_Bubble_Suction_Pop_Cork_3-7` | UI must stay dry and calm; elemental selects would colour a neutral menu. |
| `Footstep_*_Light_*`, `Footstep_*_Heavy_*`, extra Medium variants | Four medium variants per surface are enough. Light is a spare for sneaking/Veil form; Heavy for the Hollow Knight or a stampede if ever wanted. |
| `Fairy_Dust` (as spells) | Sparkly: used only for the soft NEW cue, never for combat. |
| `Magic_Holy_*` as a necromancer sound | Reserved for the warden/monk families and level-up/boss-defeat release; not for necromancer rites. |

## Suggested wiring order

1. Loader: resolve `AUDIO_MAP[id].files` to the pack files you place under `public/audio/esm/` (not committed), decode lazily, keep the Kenney/synth path as the fallback for `keep`/`partial` and for any load failure.
2. Existing ids first (no call-site change), then footsteps, then the enemy voices and boss tells (largest immersion gain, silent today), then loot drop/chest/drinks, then loops and UI polish.
3. Listen to every `partial` and the first clip of each id; the names are the only evidence used here.
