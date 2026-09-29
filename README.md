# Death Muffin — Player Guide

*A dark fantasy action RPG in your browser, alone or in a shared world of up to 10 players.*

![A fight in the Hollow Graves](docs/screenshots/graves-battle.webp)

The Ossuary Covenant stands in a diocese overrun by the dead. Choose one of nine disciplines, gather and craft in the safety of the Sexton's Acre, then fight through connected hunting grounds. Build your character, open the sealed passages, defeat the Bell-Sworn Prelate, and Ascend for permanent boons and a harder, more rewarding world.

**Play:** [muffindevelopment.com/death-muffin](https://muffindevelopment.com/death-muffin/). Create an account or sign in, then choose a discipline. You can change class later in **Settings** while keeping the same character's level, gold, items, and permanent progress.

## Contents

- [Your first hour](#your-first-hour)
- [Controls](#controls)
- [Choose a discipline](#choose-a-discipline)
- [Combat and corpses](#combat-and-corpses)
- [The world and its bosses](#the-world-and-its-bosses)
- [Gold, gear, and difficulty](#gold-gear-and-difficulty)
- [Gathering and crafting](#gathering-and-crafting)
- [Ascension](#ascension)
- [Playing together and getting help](#playing-together-and-getting-help)

## Your first hour

1. **Start in the Sexton's Acre.** This is a safe gathering area. Click a Coffin-Oak, Copper or Tin Seam, Still Pool, or Pauper's Grave to begin a level 1 skill. Press **P** to see your skills. You can leave gathering for later if you want to fight immediately.
2. **Walk east into the Chapterhouse.** This safe hub has the Reliquary for your inventory, the Workbench for crafting, the Altar of Ascension, and a Waystone. Press **T** to channel a return here when you need a break.
3. **Go north into the Hollow Graves.** Click ground to move and enemies to use your basic attack. Aim with the mouse and use **1–4** for your equipped rites. Watch the ground for attack warnings. The count beneath the minimap shows progress toward the next sealed area.
4. **Collect loot and grow stronger.** Open the Reliquary with **I** to equip items. Spend gold on **Damage** and **Wave Speed** in the HUD. Wave Speed has a separate active dial, so you can turn the pressure back down after buying a tier.
5. **Read what you meet.** Hover a rite for its cost and targeting advice, open the **Codex** with **K** for enemies and professions, and follow the Covenant counsel tips as they appear.

![The Sexton's Acre, a safe place to learn gathering](docs/screenshots/sextons-acre.webp)

On **Easy**, auto combat can engage enemies, use equipped rites, heal, and drink flasks. It turns on when you switch to Easy unless you turn it off. **G** toggles it; clicking or moving takes manual control. **Medium** is the default difficulty.

## Controls

| Input | Action |
|---|---|
| Left click ground / enemy / object | Walk, use your basic attack, interact, or gather |
| Shift + left click | Use your basic attack without moving |
| Click the minimap | Walk to a reachable point; the amber marker is your destination |
| Mouse / wheel | Aim / zoom |
| WASD or arrow keys | Walk manually |
| **1–4** | Use equipped rites at the cursor; hold to repeat when ready |
| Right click or **5** | Use your class's fifth rite, often a corpse action |
| **R** or **6** | Use your class's signature rite after level 10 |
| **Q** | Drink a healing flask |
| **T** | Recall to the Chapterhouse |
| **L** | Open the Grimoire to inspect rites and set the four keys |
| **I** or **B** / **C** / **P** | Reliquary / Workbench / Skills and AFK gathering |
| **M** / **K** | Waystone map / Codex |
| **G** | Toggle auto combat on Easy |
| **Enter** | Chat |
| **Esc** | Close an open panel, then open Settings |

You can also click hotbar icons. Right click a hotbar slot to open the Grimoire. In **Settings**, you can change class, difficulty, graphics, volume, reduced motion, damage numbers, gathering behavior, and counsel tips.

## Choose a discipline

Every class has a basic attack, four rites on **1–4**, a fifth rite on right click, and a signature on **R** at level 10. The four necromancers share a larger pool of rites and can change their loadout in the Grimoire as they level. The other five classes have their own resource and fixed rite choices for now; their four keys can be rearranged.

| Portrait | Discipline | Resource and style |
|---|---|---|
| <img src="public/art/portraits/ossuary.webp" alt="" width="64" /> | **Ossuary** | Grave Essence. Defensive necromancer: shield-bearing thralls draw attacks, and each active thrall reduces the damage you take. |
| <img src="public/art/portraits/gravecaller.webp" alt="" width="64" /> | **Gravecaller** | Grave Essence. Leads the largest, fastest-attacking legion; sacrifices leave corpses to raise again. |
| <img src="public/art/portraits/mourner.webp" alt="" width="64" /> | **Mourner** | Grave Essence. Ranged wraiths, faster essence recovery, and healing when consuming corpses. |
| <img src="public/art/portraits/rotweaver.webp" alt="" width="64" /> | **Rotweaver** | Grave Essence. Larger Miasma, more Withered stacks, and corpses that burst inside its rot field. |
| <img src="public/art/portraits/grave_warden.webp" alt="" width="64" /> | **Grave Warden** | Oil refills over time and from burning bodies. A flail, lantern, chain, and protective wards support close fighting and allies. |
| <img src="public/art/portraits/bell_monk.webp" alt="" width="64" /> | **Bell Monk** | Build Resonance by landing hits, especially on the beat. Toll and corpse-sounding rites reward timing. |
| <img src="public/art/portraits/carrion_witch.webp" alt="" width="64" /> | **Carrion Witch** | Harvest bodies for Offal; use hooks, crows, and hexes to control a pack. Offal does not refill on its own. |
| <img src="public/art/portraits/hollow_knight.webp" alt="" width="64" /> | **Hollow Knight** | Build Rage by fighting and taking hits, especially with a well-timed block; spend it on a leap and slam. |
| <img src="public/art/portraits/veilwalker.webp" alt="" width="64" /> | **Veilwalker** | Veil refills in Life form and drains in Veil form. Move between forms and make temporary spectral allies from fallen enemies. |

**New player picks:** Ossuary gives you a sturdy front line; Mourner has forgiving sustain; Hollow Knight suits players who want to stand close and time blocks. Any discipline can change later through Settings.

At **level 10**, each discipline unlocks its own signature rite on **R**:

| Discipline | Signature | What it brings |
|---|---|---|
| Ossuary | <img src="public/art/abilities/necro-ossuary-wall.png" alt="" width="36" /> **Ossuary Wall** | Blocks the dead with a wall of bone. |
| Gravecaller | <img src="public/art/abilities/necro-command-rend.png" alt="" width="36" /> **Command: Rend** | Sends the legion leaping into a target area. |
| Mourner | <img src="public/art/abilities/necro-dirge.png" alt="" width="36" /> **Dirge** | Mends allies and silences enemy casters nearby. |
| Rotweaver | <img src="public/art/abilities/necro-plague-bloom.png" alt="" width="36" /> **Plague Bloom** | Starts a rot bloom that spreads through corpses. |
| Grave Warden | <img src="public/art/abilities/warden-last-light.png" alt="" width="36" /> **Last Light** | Stuns nearby enemies and heals allies. |
| Bell Monk | <img src="public/art/abilities/monk-great-toll.png" alt="" width="36" /> **Great Toll** | Spends Resonance on a damaging, silencing toll. |
| Carrion Witch | <img src="public/art/abilities/witch-murder-of-crows.png" alt="" width="36" /> **Murder of Crows** | Sends a moving swarm after enemies. |
| Hollow Knight | <img src="public/art/abilities/knight-oath-unbroken.png" alt="" width="36" /> **Oath Unbroken** | Briefly refuses death and increases damage. |
| Veilwalker | <img src="public/art/abilities/veil-between-worlds.png" alt="" width="36" /> **Between Worlds** | Gains Veil protection with Life-form damage. |

## Combat and corpses

The necromancers begin with this kit. The icons are the same ones used on the hotbar:

| Icon | Input | Rite | Use |
|---|---|---|---|
| <img src="public/art/abilities/necro-needle.png" alt="" width="42" /> | Left click | **Bone Needle** | Free basic attack; hits restore Grave Essence. |
| <img src="public/art/abilities/necro-spear.png" alt="" width="42" /> | **1** | **Marrow Spear** | Pierces a line and applies Fracture, making targets take more damage. |
| <img src="public/art/abilities/necro-exhume.png" alt="" width="42" /> | **2** | **Exhume** | Raises the corpse nearest your cursor as a fighting thrall. |
| <img src="public/art/abilities/necro-miasma.png" alt="" width="42" /> | **3** | **Miasma Circle** | Slows and withers enemies standing in the field. |
| <img src="public/art/abilities/necro-litany.png" alt="" width="42" /> | **4** | **Black Litany** | Sacrifices nearby corpses and thralls for a stronger burst. |
| <img src="public/art/abilities/necro-corpse-explosion.png" alt="" width="42" /> | Right click / **5** | **Corpse Explosion** | Detonates a corpse near the cursor under a pack. |

Your **Grimoire (L)** shows unlock levels, costs, cooldowns, and available alternatives. Necromancers gain new primaries and rites while leveling; put any four unlocked Grimoire rites on **1–4**. Swapping slots does not clear a rite's cooldown. Your loadout is remembered for your character, and Easy auto combat uses the rites you equipped. Other classes can use the Grimoire to inspect and rearrange their starting kit.

A corpse is an opportunity, but it will not last forever. Necromancers can raise it, explode it, or save it for Black Litany. The kind of corpse affects the thrall: a Penitent becomes an archer, a Deacon a bone mage, and a Carrion Sac a plague bearer. The other classes have their own corpse rites. **Crypt Deacons** can steal unattended bodies and raise enemies from them, so deal with a Deacon before letting corpses pile up.

Necromancers also fill a **Soul Harvest** meter through kills by themselves or their thralls. When it fills, the next Marrow Spear, Miasma Circle, or Black Litany costs no essence and covers a larger area. Watch the skull meter above the hotbar for the ready state.

![Exhume raises a thrall from a fallen enemy](docs/screenshots/exhume.webp)

**Practical combat habits:**

- Keep using your basic attack between costly rites. For necromancers, Bone Needle restores the essence you spend.
- Put Fracture on a tough target before a large burst. Pull a pack into Miasma or another area effect, then use corpses when the enemies are close.
- Read an elite's tag in the target frame. Soul shards come from elites and pay for boss summons.
- Step out of marked ground before it resolves. Use **Q** for a flask, **T** to recall, or reduce the Wave Speed dial when fights get too dense.
- Death returns you to the Chapterhouse without taking your level, gold, or gear.

## The world and its bosses

The diocese is one connected world. Kill enough enemies in the preceding area to break each seal. The Chapterhouse, the Acre, and the Hollow Graves are open from the start. Waystones can travel among areas you have unlocked.

| Area | Base level | How to open it | What to expect |
|---|---:|---|---|
| **The Chapterhouse** | Safe | Always open | Reliquary, Workbench, Altar, and Waystone. |
| **The Sexton's Acre** | Safe | Always open | Gathering nodes and processing stations; no enemy waves. |
| **The Hollow Graves** | 1 | Always open | Your first waves, corpses, elites, and the Gravedigger King. |
| **The Marrow Ossuary** | 5 | 300 kills in the Graves | Bone-lined halls and Crypt Deacons. |
| **The Drowned Nave** | 9 | 420 kills in the Ossuary | Flooded cathedral and the Drowned Congregation. |
| **The Bell Sanctum** | 13 | 520 kills in the Nave | The Sundered Bell and the Bell-Sworn Prelate. |
| **The Plague Cloister** | 20 minimum | 600 kills in the Sanctum | A scaling hunting ground: its enemies keep pace with the highest-level player inside it. |

<table><tr>
<td><img src="docs/screenshots/chapterhouse.webp" alt="The Chapterhouse" /><br /><sub>The Chapterhouse</sub></td>
<td><img src="docs/screenshots/marrow-ossuary.webp" alt="The Marrow Ossuary" /><br /><sub>The Marrow Ossuary</sub></td>
<td><img src="docs/screenshots/drowned-nave.webp" alt="The Drowned Nave" /><br /><sub>The Drowned Nave</sub></td>
</tr></table>

Every hunting ground has a boss summon object. Bosses cost **soul shards**, and only one can be active in a shared world at a time. Waves in that boss's area pause during the fight. Their first defeat per character awards extra shards, a rare or better relic, and a Codex trophy.

| Boss | Where and cost | Fight clue |
|---|---|---|
| **Gravedigger King** | King's Grave, Hollow Graves · **2 shards** | Leave the marked burial ground before it roots you; watch for pits later in the fight. |
| **Bone Abbess** | Abbess's Reliquary, Marrow Ossuary · **3 shards** | Break the skull niches that heal her; spend corpses before she draws them in. |
| **Drowned Congregation** | Drowned Font, Drowned Nave · **4 shards** | Use pews to block the Flood Hymn and leave grasping rings. |
| **Bell-Sworn Prelate** | Sundered Bell, Bell Sanctum · **5 shards** | Leave the expanding Toll ring, the frontal Slam, and marked Bell Rain circles. Defeating it unlocks Ascension for the run. |
| **Plague Saint** | Saint's Litter, Plague Cloister · **5 shards** | Move her off rot pools, where she heals. Her level scales with the Cloister. |

![The Bell-Sworn Prelate in the Bell Sanctum](docs/screenshots/bell-sworn-prelate.webp)

**Grave Surges** occasionally open a special breach in an active hunting area. Clear most of its rapid waves before it closes to earn an item and bonus gold.

## Gold, gear, and difficulty

Gold and experience come from fighting. Open the **Reliquary (I)** to equip gear, use consumables, and see your inventory. Loot pillars mark better drops; item rarity is shown by color and marks. The **Workbench (C)** turns materials into equipment and tools. Healing flasks are used with **Q**; cooked meals can be eaten from the bag for healing over time.

<table><tr>
<td><img src="public/art/items/staff_oak.png" alt="Oak Staff" width="56" /></td>
<td><img src="public/art/items/helm_gold.png" alt="Gold Helm" width="56" /></td>
<td><img src="public/art/items/chest_iron.png" alt="Iron Chestplate" width="56" /></td>
<td><img src="public/art/items/ring_copper.png" alt="Copper Ring" width="56" /></td>
<td><img src="public/art/items/flask_hp_major.png" alt="Major Healing Flask" width="56" /></td>
</tr></table>

The HUD has two gold upgrades:

- **Damage:** each purchased tier adds 8% spell power, up to 25 tiers.
- **Wave Speed:** buy up to 8 tiers, then choose an **active** tier from 0 up to what you own. Higher settings mean faster, larger waves, stronger enemies, more gold, more loot chances, and more elites. The diamonds mark added pressure at tiers **3** (Elite Vanguard), **6** (Restless Crypts), and **8** (Nightfall). Lower the active tier when you need room to recover.

![Nightfall at Wave Speed tier 8](docs/screenshots/nightfall.webp)

Choose difficulty in **Settings (Esc)**. **Medium** is the starting balance. **Easy** reduces enemy health and damage and pays less gold and XP; it allows auto combat. **Hard** raises enemy health and damage, adds elites, and pays more gold and XP. In a shared world, the world keeper's difficulty and Ascension rank govern the enemies; your Easy auto combat choice remains yours.

## Gathering and crafting

The **Sexton's Acre**, west of the Chapterhouse, contains every tier of the four gathering skills without combat. Click a node to work it; it depletes and later returns. Higher tiers need the matching skill level. Press **P** for your skill levels, next unlocks, and AFK controls. The **Codex (K)** has a Professions tab for node details.

| Skill | Level 1 start | What you collect and make |
|---|---|---|
| **Woodcutting** | Coffin-Oak | Logs; mill them into planks at the **Sawpit**. |
| **Mining** | Copper or Tin Seam | Ore for ingots, equipment, and tools at the **Workbench**. |
| **Fishing** | Still Pool | Fish; cook them into healing meals at the **Cooking Fire**. |
| **Gravedigging** | Pauper's Grave | Bones and occasional finds; grind bones into bone meal at the **Bone Kiln**. |

Keep a matching hatchet, pickaxe, rod, or spade **in your bag** to improve gathering success; the best one you carry counts. The Workbench crafts stronger tools from ingots and planks. Some hunting grounds also hold richer nodes, but enemy hits interrupt gathering there.

With **Auto gathering** enabled in Settings, clicking a node can continue to another of the same kind. For longer sessions, use **P → choose a node tier → Start AFK** while in the Acre. Your character keeps working while the game is open. A full bag pauses work; make space and start again. Movement, casting, or **Pause AFK** stops it. Closing the game ends the session, so this does not earn rewards while offline.

<table><tr>
<td><img src="docs/screenshots/gathering.webp" alt="Working a gathering node" /><br /><sub>Working a node</sub></td>
<td><img src="docs/screenshots/skills-panel.webp" alt="The Skills panel" /><br /><sub>Skills (P)</sub></td>
<td><img src="docs/screenshots/codex-professions.webp" alt="The Codex Professions tab" /><br /><sub>Codex professions</sub></td>
</tr></table>

## Ascension

After defeating the **Bell-Sworn Prelate** during a run, visit the **Altar of Ascension** in the Chapterhouse. Ascending trades your current run for **Ashes** and one Ascension rank. The Altar shows the reward and asks you to confirm the reset.

| Reset on Ascension | Kept on Ascension |
|---|---|
| Damage and Wave Speed tiers, soul shards, area kill counts, and opened seals | Character level and XP, gold, items, profession progress, Ashes, purchased Covenant Boons, and Ascension rank |

Ashes buy permanent **Covenant Boons** at the Altar, including more health, cheaper upgrades, a stronger start, faster seals, and an extra thrall. More Prelate kills, a higher peak Wave Speed, and more kills during a run increase its Ashes reward. Each Ascension rank makes enemies and bosses three levels older and raises gold and XP rewards. The rank cap is **20**.

![The Altar of Ascension and its Covenant Boons](docs/screenshots/altar-of-ascension.webp)

## Playing together and getting help

When co-op is available, joining places you in a world with room for up to **10 players**. Players in the same world share chat, combat, gathering node depletion, and boss activity; each character receives their own finds and progression. Press **Enter** to chat. If the realtime service is unavailable, the game continues as a solo world.

**Covenant counsel** cards appear when you first encounter important systems. You can move them, turn them off in Settings, or choose **Show tips again** there. Hover or focus an ability icon for its cost, target, effects, and combat tip. The **Codex (K)** records rites, enemies, bosses, and professions you have encountered.

![A Covenant counsel tip in game](docs/screenshots/covenant-counsel.webp)

For technical setup and deployment, see [docs/README.md](docs/README.md) and the [VPS handoff](docs/DEATH-MUFFIN-HANDOFF.md).
