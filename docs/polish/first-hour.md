# First-hour polish (3 Oct 2026, branch `dm/polish-firsthour`)

Played login, discipline select, Acre, Chapterhouse, first Graves fights, level-ups, death, and every panel at 1280x800 (spot checks at 1920x1080), with `first-hour-audit.cjs`, `first-hour-smoke.cjs` and scripted `__cwDebug` runs. Screenshots were looked at, not just logged.

| # | Issue | Severity | Status / commit |
|---|---|---|---|
| 1 | Codex (Bone Needle), signature tip, Grimoire tip and rite tooltip told every player about "Auto (G)" / "Easy auto", an owner-only feature | High (text for a feature players do not have) | Fixed: `{auto}...{/auto}` markup, `gateAuto()` in settings.ts |
| 2 | Counsel card sat on top of Settings / Map / Craft / Skills / Codex titles and tabs for ~6 s at 1280 wide | High | Fixed: calm and fight cards fade the moment a panel opens (Hurt? and a panel's own "asked" card stay) |
| 3 | Toasts: up to four boxes stacked mid-screen (three milestones from one kill), 8 s minimum | Medium | Fixed: max 3, identical lines merge, 6 s minimum |
| 4 | Upgrades plate: "Elite Vanguard at tier 3" wrapped to three lines beside the dial | Medium | Fixed: own line |
| 5 | Workbench recipes: name wrapped to 3 lines, ingredients to 4 (540 px panel) | Medium | Fixed: panel 720 px, controls wrap under the name when narrow |
| 6 | Menu says Bag / Craft / Spells / Map, panels say Reliquary / Workbench / Grimoire / Waystones | Medium | Fixed: panel title carries the menu name ("Reliquary  BAG · I") |
| 7 | Discipline cards showed legacy server class names (Guardian, Shadowblade, Cleric, Arcanist) | Medium | Fixed: removed; necromancers tagged |
| 8 | Grimoire tip was 11 lines, repeated the panel's own text | Low | Fixed: 4 lines |
| 9 | Sign-up error "username must be at least 3 characters" lower case | Low | Fixed (first letter capitalised, text otherwise verbatim) |
| 10 | Settings key list missed O U H N | Low | Fixed |
| 11 | Area text counts the Warren seal (0/150) while Next counts the Ossuary (0/300) | Low | Open: both are true (side hall vs main road) but the formats differ ("Slay 0/150" vs "0 / 300"); owner call |
| 12 | "Your first thrall" card returned after a respawn with no thrall alive | Low | Open: sendBack re-queues a card that has lost its context |
| 13 | "Bone Ward -0%" readout shown with no thralls | Low | Open: Ossuary-only readout, harmless noise |
| 14 | Hurt? (urgent) still covers a panel's tabs at 1280 | Low | Open on purpose (it must not vanish) |
| 15 | Hotbar shows SWAP under every slot from level 1 | Low | Open: owner call (discoverability vs clutter) |

No console errors, no 404 (fontsource 403s are the known symlinked-node_modules artefact).

## Performance guard
All changes are CSS or one-time DOM. Fixed-fight (graves, nave): draw calls 139/139 high, 83/79 low before vs 139/139, 82/83 after; tris within spawn noise; main bundle gzip 444.94 kB before, 444.87 kB after (CSS 22.80 -> 22.92 kB).
