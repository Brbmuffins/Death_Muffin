# Discipline armor sets

Two collections of nine five-piece sets use the existing head, chest, hands, legs and feet slots. They are themed for each discipline, but any class can equip them; changing class never strands worn gear. Each set has its own color, accent, head ornament and five matching vector inventory icons. The hero's existing body-region shader colors worn chest, hands, legs and feet. Ascended gear adds a second crown rim and a brighter material glow. The Reliquary counts pieces within each specific set.

| Discipline | First set | Ascended set | Stat focus |
| --- | --- | --- | --- |
| Gravecaller | Gravecall | Epitaph Sovereign | INT, VIT |
| Grave Warden | Lamplight | Nightwatch Beacon | VIT, STR |
| Bell Monk | Bellwake | Last Toll | STR, AGI |
| Ossuary | Ivory Reliquary | Marrow Regent | INT, VIT |
| Mourner | Widowveil | Pale Requiem | INT, AGI |
| Carrion Witch | Carrionbloom | Thorn Covenant | INT, VIT |
| Rotweaver | Blightweave | Virulent Choir | INT, VIT |
| Hollow Knight | Hollow Oath | Oathbreaker | STR, VIT |
| Veilwalker | Threshold | Umbral Crossing | AGI, INT |

Every class has the same drop progression: uncommon crowns and grips in the Hollow Graves, rare vestments in the Marrow Ossuary, rare legguards in the Drowned Nave, and epic treads in the Bell Sanctum. The Plague Cloister and Cinder Pyre can also drop the three later pieces. All five pieces enter normal area loot and boss rolls; item chance, elite bonus and wave modifiers still apply. There is no set bonus or class restriction.

The ascended collection continues that path for every class: rare crowns and grips in the Bell Sanctum, epic vestments and legguards in the Plague Cloister, and epic treads in the Cinder Pyre. The Cinder Pyre can also drop the ascended Cloister pieces. Each ascended part grants more of the same two stats than its first-set counterpart, so gear upgrades remain legible. The later collection has distinct IDs and can displace first-set gear through the normal equip flow.

The catalog lives in `src/content/armorSets.ts`. Run `node tools/generate-armor-assets.mjs` after changing it to regenerate 90 SVG icons and both additive migrations: `011-class-armor.sql` for the first collection and `012-ascended-armor.sql` for the second. Apply both in order to the **Death Muffin database** after a backup and before publishing a client that can drop these IDs. The server's item rows supply real stats and equipment slots; the offline catalog reads the same manifest. Run `npm run build:server-rules` after changing area loot.
