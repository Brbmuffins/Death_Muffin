/**
 * Golden fixtures for godot/game_ui/dm_spell_tooltip.gd (src/ui/spellTooltip.ts): run `npx vite-node tools/godot/fixtures-spelltip.ts`.
 * Every ability x (no discipline + every discipline) x a set of HUD states, with the web's own output.
 * Output: godot/tests/ui_parity/fixtures/spelltip.json (gitignored when large).
 */
import { mkdirSync, writeFileSync } from 'node:fs';
import { ABILITIES, type AbilityId } from '../../src/content/abilities';
import { DISCIPLINES } from '../../src/content/disciplines';
import { kitFor } from '../../src/content/kits';
import { setActiveCharacter } from '../../src/app/settings';
import { spellTooltip, type SpellTooltipState } from '../../src/ui/spellTooltip';

const OUT = 'godot/tests/ui_parity/fixtures';
mkdirSync(OUT, { recursive: true });
const STATES: SpellTooltipState[] = [
  {},
  { key: '1' },
  { key: 'RMB' },
  { key: 'LMB' },
  { key: '3', affordable: false },
  { key: '2', left: 4200 },
  { empowered: true },
  { empowered: true, affordable: false, key: '4' },
  { locked: true },
];
const cases: unknown[] = [];
for (const auto of [false, true]) {
  setActiveCharacter(null, auto);
  for (const id of Object.keys(ABILITIES) as AbilityId[]) {
    for (const disc of [undefined, ...Object.values(DISCIPLINES)]) {
      for (const st of STATES) {
        if (auto && (st.key || st.locked || st.left || st.empowered)) continue; // auto only changes the R-slot control line
        const state = { ...st, ...(disc ? { kit: kitFor(disc.family) } : {}) };
        const { kit, ...stateIn } = state as SpellTooltipState & { kit?: unknown };
        cases.push({ in: { id, discipline: disc?.id ?? null, state: stateIn, family: disc?.family ?? null, auto }, out: spellTooltip(id, disc, state) });
      }
    }
  }
}
writeFileSync(`${OUT}/spelltip.json`, JSON.stringify({ fn: 'spellTooltip', cases }) + '\n');
console.log(`spelltip: ${cases.length} cases`);
