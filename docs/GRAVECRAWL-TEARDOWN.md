# Gravecrawl teardown and what Death Muffin should learn

*2 October 2026, branch `dm/gravecrawl-study`. Study only: no game code changed. Screenshots are in [`docs/gravecrawl-study/`](gravecrawl-study/).*

**Subject:** [Gravecrawl](https://www.gravecrawl.com/), "A CO-OP DESCENT", a free browser co-op gothic survival ARPG by Majid Manzarpour. Nothing from it was downloaded into this repo. Only principles and my own screenshots are used.

## Bottom line

The owner is right that Gravecrawl feels better, but it is not better in the way he probably thinks. Its world is small (4 classes, about 6 enemy types, 1 boss, 2 modes) and in the fight itself it looks plainer than we do. What it does better is **clarity, packaging and loop**:

1. It says what it is in 3 words ("A co-op descent") on every screen and the pitch matches the first minute.
2. You are fighting about 5 seconds after pressing Start, with no account.
3. Every run ends in a number (wave reached), a results card, a personal best, a Share button and a one-click Play Again. A daily leaderboard sits next to the lobby.
4. A 3-card draft between waves makes every run different.
5. One restrained palette and a HUD of about 6 groups, against our violet wash and about 14 groups.

Death Muffin already beats it on depth, art in the fight itself and persistence. The gap is the **frame around the fight**, and that is cheaper to close than a new game.

## Method and limits (read this first)

- Played Gravecrawl as a normal visitor: about 20 short sessions (most of them 15-100 s), a private solo lobby each time, nothing posted to chat or public lobbies. Playwright Chromium with software GL (SwiftShader) at 1280x800 and 390x844 phone.
- **The VPS load average was 25-60 the whole time** (other agents plus a game server). On software GL the game runs at 1-3 fps, and Gravecrawl's client only moves you a small amount per frame, so my bot could mostly stand and cast. It survived to wave 3 once and died in wave 1 (15-25 s) in most runs. So I saw waves 1-3, one intermission draft, the death/results screen and the first room of The Descent. **I did not see the mini-boss (wave 5), the boss (wave 10) or a Descent combat room.** Their descriptions below come from the lobby text and preloaded asset names. Judge combat depth after wave 3 as unknown.
- For gameplay frames I read client state from `window.__GRAVEBOUND__` (a global the page exposes) to steer the bot. I did not alter anything, and I did not read or copy game logic.
- Our screenshots come from the worktree dev server, offline mode. **Dev-server fonts fall back to a system serif** (the `@fontsource` 403 noted in `tools/qa/lib/qa-common.cjs`), so type in our dev shots is plainer than live. Live login pages were captured from production.
- Frame rates are not comparable. Draw-call and triangle counts are, and are read from each game's own diagnostics.

## 1. Identity and pitch

| | Gravecrawl | Death Muffin |
|---|---|---|
| Tagline on screen | "A CO-OP DESCENT" under a painted logo, on every menu | Live portal: "THE CINDER PYRE IS OPEN" (a patch note). Worktree login: "The dead don't stay buried. Neither does the fire." |
| `<title>` / share card | "GRAVECRAWL - Co-op Gothic Survival ARPG", full Open Graph and Twitter card, 1200x630 image | "Death Muffin" / "Death Muffin - Muffin Developed". **No Open Graph tags** in `index.html` or `site/index.html`, so a pasted link shows no card |
| What you do | Hold the arena, wave by wave; or delve a daily crypt. Goal = wave reached / Warden of Depth 8 | Gather, craft, fight through zones, break seals, kill the Prelate, Ascend. Never stated in the first minutes |
| Session | Lobby (public/private) then Onslaught (waves, mini-boss every 5, boss every 10) or The Descent (daily seeded crypt, 5+ rooms, a Warden) | Persistent character and world, no session boundary, "continuous waves" with Damage / Wave Speed dials |
| Unit of play | 5-15 minute run | Open-ended |

Evidence: [`01-title-live`](gravecrawl-study/01-title-live.webp), [`02b-title-offline`](gravecrawl-study/02b-title-offline.webp), [`09-gc-lobby`](gravecrawl-study/09-gc-lobby.webp).

The point: Gravecrawl's tagline is a verb phrase that tells you the structure ("descent", "co-op"). Ours tells you the weather. The worktree tagline is better than the live one, but neither says what you do or what you are working towards.

## 2. First 60 seconds

| | Gravecrawl | Death Muffin |
|---|---|---|
| Account | None. Name field pre-filled ("Gravecaller") | Username + password (+ email on create), on a static portal page, then a second scene |
| Clicks to first combat | 3: Enter the Gates, Create Private (or Public), Start Game. Wave 1 begins about 4-5 s later | Create account (3 fields), then 1 discipline click, then a 2-zone walk (Acre, Chapterhouse, Graves) |
| First enemy | About 15-20 s after landing | About 45 s of game time (`docs/FIRST-HOUR-AUDIT.md`), after a "Take your time, no enemies here" card |
| Tutorial | One card, 4 lines, "click to dismiss". It sits mid-screen as wave 1 spawns, a small flaw | Covenant counsel cards: good copy, before the 2 Oct cadence fix an audit found one on screen 95% of the first 160 s |
| Choices before play | 4 class cards with a one-line role | 9 disciplines on two scrolling screens, a paragraph plus a passive each |
| Bytes to first fight | About 12.5 MB, 148 requests (title, lobby, wave 1) | About 28 MB of art/models/audio to reach the Graves in dev (models 21.9, art 4.9, audio 1.4), plus a 1.86 MB JS build (555 KB gzip); the offline edition is 105 MB |

[`03-first-moments`](gravecrawl-study/03-first-moments.webp): Gravecrawl is already in a lit arena with enemies spawning; ours is a quiet, atmospheric but empty yard.

Their loader paints the logo from inline CSS before any JS parses, with a progress bar, so there is never a blank screen. That is a nice touch for slow connections.

## 3. Core loop and goal

Gravecrawl, as observed:

- **Wave** (13, 18, 19 enemies in waves 1-3; "N LEFT" counter) then **Intermission**: three power cards ("Vigor +25 max life", "Resonance: area spells echo a second blast", "Searing Trail: projectiles leave a burning pool", "Warded", "Gravewax +4% damage per wave", "Berserker +22% damage but +10% taken"), a 15 s auto-advance timer, **Ready for Next Wave**, empty Weapon / Armor / Trinket slots ("slay for loot"), and a vendor strip: Potion 40g, Full Heal 60g, Reroll Draft 30g. Draft picks become stacking chips above the character.
- **Streak meter** above the player ("BLOODIED") and pickup motes that stack temporary power.
- **Death** ("The Party Has Fallen"): wave reached, party kills, gold, time, "New personal best" stars per stat, **Play Again**, **Share** (copies "GRAVECRAWL - I held until wave 1 · 2 kills. Crawl with me: URL"), Return to Lobbies.
- **Daily Descent leaderboard** on the lobby page: Today / Yesterday / Waves·week, filter All / Solo / Party, with a reset countdown.
- **The Descent**: shared daily seeded crypt, "Depth 1 of 8", "0/5 rooms", an objective chip ("Find the Warden"), fog-of-war reveal, procedurally generated rooms with types (entrance, combat, treasure, boss) and a critical path.

Why it works: every run has a **scoreboard number, a reason to retry (draft variance, personal best) and a way to tell a friend**. The reward cadence is about 60-90 s, not 40 minutes.

Death Muffin's loop is deeper but its goals are far apart: gather, craft, level, unlock a seal at 150 or 300 kills, Ascend. The "Next" box is a good device, but the *objective* never reaches the screen or the title. Our death screen (`You have fallen / The Chapterhouse will call you back`, [`07-death-results`](gravecrawl-study/07-death-results.webp)) has no result, no retry and no hook.

## 4. Art direction

**Gravecrawl**
- *Palette:* almost-black blue-violet ground (`#0a0910` ink, `#050309` void) with desaturated blue-grey cobble. **One signature accent: necro jade `#7affb0`** for the logo glow, summoning circle, headings and class color. Warm gold `#f0c64b` for rewards and the primary start button, blood `#b5202a` for the call-to-action and danger, torch orange only as small warm points. Rarity colors follow the Diablo convention (grey, blue, yellow, orange). The whole token set is about 20 variables.
- *Lighting:* a 5-light rig (hemisphere, moon key, fill, rim, accent) plus a carried lantern, volumetric-looking light shafts and low fog; in-engine bloom is on only at high quality, with a color-grade pass at medium.
- *Characters:* dark, small silhouettes; readability comes from a cool floor against warm hit sparks and white numbers, not from detail. In wave shots enemies are *less* detailed than ours.
- *Painted 2D art does the heavy lifting:* a 687 KB painted logo (cracked metal and green fire), painted full-body hero cutout with green rim glow over the 3D scene on the title, four painted class cards, painted ability icons in a consistent frame, painted mode thumbnails (an arena at moonrise, an isometric crypt). It is all one illustrator-grade look, which makes a modest 3D game feel authored.
- *Type:* Cinzel for display and Spectral for body, loaded as preloaded woff2; spaced small caps for kickers ("READY UP - THE HOST BEGINS THE DESCENT"). In-run labels ("WAVE 1", "The Party Has Fallen") fall back to a plain bold sans, which looks unfinished next to the panels.
- *UI frames:* near-black panels with a thin violet-grey edge, chamfered corners, tiny corner studs, a mint glow on titles, red and gold beveled buttons.

**Death Muffin**
- Painted art is strong: nine discipline portraits, login backdrops, boss paintings. We also have a rim light and an ACES + bloom stack. `SPELL_FX` gives every spell a color identity and the VFX is richer than theirs.
- But the world is washed in **one color, violet**: fog `0x0b0810`, hemisphere `0x4a3866`, rim `0x7a5cd6`, spells `0x9b5cff`, the UI accent `--cw-spell-400`, the minimap, the cards. In [`04-midfight-vfx`](gravecrawl-study/04-midfight-vfx.webp) and [`05-hud-density`](gravecrawl-study/05-hud-density.webp) the enemies, the player and the floor sit in nearly the same value and hue. Gravecrawl solves this by making the floor cool and neutral so the accent can pop.
- No logo art. The wordmark is text (live: blackletter "Death Muffin" with a sigil, a good start but small).

## 5. Combat feel and VFX

- *Telegraphs:* Gravecrawl: not enough observed. We have gold-outlined cones and bronze rings (`ZONE-POLISH-AUDIT`), which are good, but they sit on a violet field and compete with player VFX.
- *Hit feedback:* Gravecrawl: big white/gold damage numbers, white-hot expanding ring on the big AoE, kill streak banner, a **red screen-edge low-HP vignette** and a faded hotbar when dead. Ours has all of these (`.hud-vignette`, hitstop, knockback, `killChain.ts`) and more.
- *Density:* waves of 13-19 enemies in a bare circular arena, the camera far out and steep. Ours is much denser (30-60 plus thralls) in a prop-heavy world.
- *Camera:* both fixed-angle top-down perspective. Theirs adds `pushIn`, `fovPunch` and shake with a Settings toggle for **Screen Shake** and **Screen Flashes** plus music/sound sliders.
- *Verdict:* VFX quality is a **draw or a win for us**; readability is a loss. Reduce simultaneous layers and separate hue/value of enemy, player, and ground.

## 6. UI / HUD

| | Gravecrawl | Death Muffin |
|---|---|---|
| Always-on groups | About 6: wave chip (top), level + XP + gold (top-left), party frame (top-right), minimap, orbs + 5 ability slots + potion + dash (bottom), settings and chat | About 14: player card, buff chip, boss bar, counsel card, area title, Next box, 8-button menu grid, upgrades panel (Damage / Wave Speed / Empower / Quicken / tier), kill chain, hotbar with swap, XP bar, two orbs, currencies, chat, offline note |
| Keyboard hints | Persistent strip on title; first-run card | Counsel cards, Codex |
| Phone | **Full twin-stick**: left stick move, right stick aim and fire, arc of ability buttons, dash, potion, flag-ping; portrait layout, name field and cards re-flowed | Phone layout exists (MENU button, hotbar, orbs) but is click-to-move; wave banner and counsel card overlap in [`08-phone-deathmuffin`](gravecrawl-study/08-phone-deathmuffin.webp) |
| Small-screen verdict | Better for casual one-thumb play | Better menus and information; worse in a fight |

Evidence: [`05-hud-density`](gravecrawl-study/05-hud-density.webp), [`08-phone-gravecrawl`](gravecrawl-study/08-phone-gravecrawl.webp).

## 7. Social / co-op

- Join by link (`?g=<lobby id>`), by public list, or by opening a second tab. Up to 4. Host presses Start; lobby shows classes, ready state, a Copy button and chat (T). Ping with G or Alt+click. The client has spectate and revive state (not exercised). Party and Solo leaderboard filters.
- Share is a clipboard text blurb, not an image; the link preview depends on their OG card.
- Ours: shared world up to 10, realtime on Socket.io, but joining is "log in, find each other". There is no copyable invite and no link preview.

## 8. Tech hints (observed, not decompiled)

- Three.js r171, single module bundle **1.14 MB raw, 376 KB gzip** (ours: 1.29 MB + 0.57 MB `three` chunk, about 555 KB gzip), CSS 87 KB.
- Draw calls **73-109**, **70-115k triangles**, 30-33 shader programs, 48-63 geometries at wave 1-3. Ours in the Graves: 143 calls, 330k triangles, 1.3M scene triangles, 36 programs, 12 lights.
- Server-authoritative over WebSocket with client prediction and interpolation, input at 30 Hz, a `/track` beacon, and per-run diagnostics exposed through `window.__THREE_GAME_DIAGNOSTICS__`.
- **Adaptive quality tiers**: `dprCap 1.25`, bloom off at medium, grade pass on, shadow map 1024 at 30 Hz with 12 casters, animation LOD by distance (near 14, mid 26 at 24 Hz, far at 10 Hz), 3-4 arena lights, HUD updated at 20 Hz. A Render Quality toggle (Auto/...) is in Settings.
- Per-asset sizing: heroes and enemies are about 0.5 MB GLB each with animation baked in; ability icons 5-13 KB WebP; portraits about 100-130 KB. No texture or mesh compression observed.
- Post look: soft bloom on bright accents, mild color grade; no heavy SSAO or depth of field.

## 9. Where Death Muffin is already ahead

- **Depth and persistence:** nine disciplines with distinct resources and kits against four, an eight-zone world, bosses, ascension, weekly omens, professions, alchemy, laborers.
- **Gear you can read:** upgrade arrows, set bonuses, runes, a Character sheet. Gravecrawl's gear is three empty slots.
- **Necromancer identity:** thralls, corpses, the Legion and four necro disciplines. Gravecrawl's Necromancer is a mana caster.
- **VFX variety** and per-spell color meaning (`SPELL_FX`, Binbun port).
- **Offline edition** and PWA; **phones and tablets** have a full panel layout.
- **Audio:** combat sample set; Gravecrawl's is untested here.
- **Content breadth:** 27+ enemies against about 6.

## 10. Steal list

Ranked by impact divided by effort. "Code / art / design" is the main kind of work.

### Quick wins (one day or less)

1. **One-sentence identity, everywhere (design / copy, 2 h).** Pick a verb-phrase tagline (see the recommendation below), put it under the logo on the live portal (`site/index.html`), the worktree `LoginScene.ts` kicker, the page `<title>`/`description` in `index.html` and as the first area banner for a new character. Retire "THE CINDER PYRE IS OPEN" from the hero slot (move it to a news line).
2. **Open Graph / Twitter card (code + art, 2 h).** Add OG tags to `index.html` and `site/index.html` with a 1200x630 image cut from existing key art (`public/art/login-backdrop*.webp`). Costs nothing and every shared link becomes an ad.
3. **A real death screen (code + copy, 4-6 h).** Replace the `HUD.death()` caption (`src/ui/HUD.ts` near line 872, and the death handler in `WorldScene.ts`) with a results panel: zone, time alive, kills, thralls raised, gold lost, "new best" stars (use `progression.ts` local store), Play Again / Return to Chapterhouse / Copy result. A text share blurb copied to the clipboard is enough.
4. **HUD diet, default view (code / design, 1 day).** Fold the 8-button menu grid, the Upgrades panel and the area description into a collapsed state that opens on hover or a key; keep player, boss, hotbar, orbs, minimap, one objective. Make counsel cards and banners mutually exclusive (the `counselCadence.ts` kinds already model it). Files: `src/ui/ui.css`, `HUD.ts`, `mobile.css`. Target six groups in a fight.
5. **Cool the world, keep violet for magic (art / light, 4 h plus review).** Make the floor and fog a neutral cool grey-blue and the hemisphere/rim less saturated (`WorldScene.ts` lines 695-717, `Atmosphere.ts`, per-area `ambient.fog` in `content/areas.ts`), so violet, jade and bone enemy outlines can separate. A/B by screenshot at the same spot before and after. This is the cheapest "looks authored" win.
6. **Discipline select on a diet (code / art, 1 day).** `CharacterSelectScene.ts`: pre-select a recommended first discipline (Gravecaller), show the hero large with a short role line, five ability icons and one resource, and put the other eight in a single row of portraits like their class strip. Move passive text behind "details". Name field pre-filled.
7. **Instant splash and honest progress (code, 3 h).** An inline-CSS logo + bar in `index.html` that paints before the module loads (theirs preloads the logo and font), with real progress for the 28 MB of models.

### Medium (two to five days)

8. **Drop a new character into a fight in under 20 s (design + code, 2-3 days).** Spawn brand-new characters in the Graves' edge with a pre-cleared walk, a one-card tutorial, and the Acre as a reward at level 2. Keep the Acre card for return visits. Files: `Onboarding.ts`, `guidance.ts`, spawn logic in `WorldScene.ts`. Target: first kill under 20 s of game time (now about 45 s).
9. **Sortie: a bounded run with a draft (design + code, about 1 week; this is the big idea below).** A "Sortie" launched from the Chapterhouse or the Graves gate: 5-8 waves in the current zone's arena, mini-boss every 3rd, a 15 s intermission with a **3-card draft** (reroll for gold, ready button), a result card, and rewards that flow back to the persistent character. Seed it from what exists: `content/upgrades.ts` (Damage/Wave Speed dials), `omens.ts`, `WorldSim` wave logic, the HUD "Next" box. New files: `content/boons.ts`, `ui/DraftPanel.ts`, `gameplay/sortie.ts`.
10. **Army-themed boons (design, 2-3 days of content).** Write about 20 boons that change the *legion* (thrall cap, a second Wraith, corpses explode, shield bearers taunt, laborers fight) plus a handful of necro spell echoes, using the nine disciplines' mods in `content/disciplines.ts` and `legionKit.ts`. This is what Gravecrawl cannot copy.
11. **Copyable invite link and party frame (code, 2-3 days).** `?party=<id>` join, a Copy button in the party frame, a toast "X joined"; uses the existing realtime client in `src/net/`. Already half true: `coop-ten-smoke` proves 10 players.
12. **Twin-stick phone controls (code, 3-5 days).** A real "Action" mode for phones in `mobile.css` + `Player.ts` input: left stick, right stick aim/fire, ability arc, dash, potion. Keep tap-to-move as the relaxed mode.
13. **Painted logo lockup (art, 1 day).** Generate and ship a metal-and-ember Death Muffin logo (the Gemini/Tripo pipeline in `ASSET_PIPELINE.md`) for the title, loader, OG card and favicon.
14. **Enemy silhouette pass (art / code, 2 days).** Rim-light or outline hostile creatures in a warm, desaturated rim color, value-separated from the floor (`graphics/Creature.ts`, `EntityViews.ts`, `friendRim.ts` for the friendly case). Gravecrawl's floor-vs-spark contrast is the model.

### Big bets (weeks)

15. **Daily Descent leaderboard (code + server, 1-2 weeks).** The weekly omen system already makes a shared seed; a daily seeded Sortie plus a board (`site/leaderboard.html`, `server/death-muffin/`) with Today / Week and Solo / Party filters and a reset countdown gives every player a reason to come back tomorrow and a reason to post.
16. **Procedural crypt "Descent" (code + art, 3-6 weeks).** Gravecrawl's second mode: a graph of room types with a critical path, a warden at the end. We already hand-built the Catacomb Warren; a generated version of it, seeded daily, would be a natural endgame.
17. **Campaign meter: "Diocese reclaimed N/8" (design + code + art, 2-3 weeks).** Put the seal/zone progress where Gravecrawl puts "wave reached": on the title, the HUD and the results card, tied to Sortie wins.

## Identity: my honest recommendation

The owner floated "your army is your character / reclaim the diocese / necropolis grows". Gravecrawl does not argue for dropping any of them. It argues for **choosing one sentence and building a visible, repeatable loop under it**. Our trouble is not that the game lacks identity (the legion is more distinctive than anything Gravecrawl has). It is that the identity lives in menus and docs, and the first 10 minutes do not show it.

My view:

1. **Lead with the army, justify it with the diocese.** Tagline: *"Raise a legion from the dead. Reclaim the diocese."* "Your army is your character" is the differentiator and should shape the draft (item 10). "Reclaim the diocese" is the long goal and gives the meter (item 17). "Necropolis grows" is the persistent reward (the Acre, the Wing, laborers, the Vault), not the pitch.
2. **Add a session layer on top of the persistent necromancer; do not replace it.** Gravecrawl's real lesson is the 8-minute run with a draft, a result, a score and a retry. A *Sortie* (item 9) gives us that without losing the persistent character: the run is the verb, the necropolis is the meta. Rewards (relics, souls, corpses for laborers) go home to the Acre.
3. **Do not copy co-op-first.** Our shared world and crowd are an asset, but a four-person link lobby is a better invitation than a 10-person world. Make joining one click (item 11), keep the world.
4. **Order of work:** items 1, 2, 3, 5, 4 this week (identity, share card, results screen, color, HUD). Then 8, 9, 10 as one design effort. 15 and 17 only after the Sortie loop proves fun.
5. **Risks:** (a) the Sortie must not feel like a separate game, so reuse zones, enemies and the same character; (b) if the draft is not army-flavored it will just be Gravecrawl-lite; (c) I only saw about 3 waves of Gravecrawl, so do not assume its mid-run depth is good.

## Appendix: screenshots

| File | What |
|---|---|
| `01-title-live` | Gravecrawl title vs Death Muffin live first screen |
| `02-class-select` | 4 classes vs 9 disciplines (dev fonts) |
| `02b-title-offline` | Death Muffin worktree title vs Gravecrawl |
| `03-first-moments` | Wave 1 start vs the Acre |
| `04-midfight-vfx` | Same-moment AoE comparison |
| `05-hud-density` | HUD group count at wave 3 vs a Graves fight |
| `06-reward-moment` | Gravecrawl draft vs our bag |
| `07-death-results` | Results screen vs "You have fallen" |
| `08-phone-gravecrawl`, `08-phone-deathmuffin` | 390x844 title, lobby, play |
| `09-gc-lobby`, `09-gc-browser-leaderboard` | Lobby with mode cards; lobby list and daily board |
| `10-gc-descent-dungeon` | The Descent, depth 1 |
| `11-gc-settings` | Settings (shake, flashes, render quality) |
| `12-dm-character-sheet`, `13-dm-ring-fight` | Our depth |
