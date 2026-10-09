import { describe, expect, it } from 'vitest';
import { ABILITIES, FRACTURE, SIGNATURE_LEVEL, SOUL_HARVEST, type AbilityId } from '../../content/abilities';
import { CODEX_RITES } from '../../content/codex';
import { DISCIPLINES } from '../../../server/rules/content/disciplines';
import { spellTooltip } from '../spellTooltip';

const metric = (id: AbilityId, label: string) => spellTooltip(id).metrics.find((m) => m.label === label)?.value;

describe('spell hover information', () => {
  it('uses the ability definitions and Codex for every spell, with relevant controls and targeting', () => {
    for (const id of Object.keys(ABILITIES) as AbilityId[]) {
      const tooltip = spellTooltip(id);
      expect(tooltip.name).toBe(ABILITIES[id].name);
      expect(tooltip.description).toBe(ABILITIES[id].description);
      expect(tooltip.tip).toBe(CODEX_RITES[id].tip);
      expect(tooltip.metrics.find((m) => m.label === 'Cooldown')?.value).toBe(`${ABILITIES[id].cooldownMs / 1000}s`);
      expect(tooltip.control).toBeTruthy();
      expect(tooltip.targeting).toBeTruthy();
      expect(tooltip.details.length).toBeGreaterThan(0);
    }
    expect(spellTooltip('corpse_explosion').control).toContain('Right-click');
    expect(spellTooltip('marrow_spear').control).toContain('hold 1');
    expect(spellTooltip('command_rend').control).toContain('R or 6');
    expect(spellTooltip('exhume').targeting).toContain('corpse');
  });

  it('shows active class Miasma area and Withered limit, including corpse consumption', () => {
    const rot = spellTooltip('miasma', DISCIPLINES.rotweaver);
    const radius = Number((ABILITIES.miasma.radius * DISCIPLINES.rotweaver.mods.miasmaRadiusMult).toFixed(2));
    expect(rot.metrics.find((m) => m.label === 'Radius')?.value).toBe(`${radius}m`);
    expect(rot.details.join(' ')).toContain(`${DISCIPLINES.rotweaver.mods.witheredMaxStacks} stacks`);
    expect(rot.details.join(' ')).toContain('bodies are consumed');
    expect(spellTooltip('miasma', DISCIPLINES.ossuary).details.join(' ')).not.toContain('bodies are consumed');
  });

  it('explains class thrall cap and correctly distinguishes Exhume and Litany healing', () => {
    expect(spellTooltip('exhume', DISCIPLINES.gravecaller).details.join(' ')).toContain(`cap is ${DISCIPLINES.gravecaller.mods.thrallCap}`);
    const mourner = DISCIPLINES.mourner;
    expect(spellTooltip('exhume', mourner).details.join(' ')).toContain(`${mourner.mods.corpseHeal * 100}%`);
    expect(spellTooltip('black_litany', mourner).details.join(' ')).toContain(`${mourner.mods.corpseHeal * 0.5 * 100}%`);
    expect(spellTooltip('black_litany', DISCIPLINES.gravecaller).details.join(' ')).toContain('fresh corpses');
    expect(spellTooltip('black_litany', DISCIPLINES.ossuary).details.join(' ')).toContain('barrier');
  });

  it('only empowers eligible spells and updates cost, spear reach and combined class area', () => {
    const spear = spellTooltip('marrow_spear', undefined, { empowered: true, affordable: false });
    expect(spear.metrics.find((m) => m.label === 'Essence')?.value).toContain('Free');
    expect(spear.metrics.find((m) => m.label === 'Range')?.value).toBe(`${ABILITIES.marrow_spear.range * SOUL_HARVEST.areaMult}m`);
    expect(spear.status).toBe('Soul Harvest ready.');
    const rot = spellTooltip('miasma', DISCIPLINES.rotweaver, { empowered: true });
    const r = Number((ABILITIES.miasma.radius * DISCIPLINES.rotweaver.mods.miasmaRadiusMult * SOUL_HARVEST.areaMult).toFixed(2));
    expect(rot.metrics.find((m) => m.label === 'Radius')?.value).toBe(`${r}m`);
    expect(spellTooltip('exhume', undefined, { empowered: true }).empowered).toBe(false);
    expect(spellTooltip('exhume', undefined, { empowered: true }).metrics.find((m) => m.label === 'Essence')?.value).toBe(String(ABILITIES.exhume.essenceCost));
  });

  it('Grimoire rites: loadout key, level lock and their own mechanics', () => {
    // On the bar, the HUD passes the real key; off it, the card points at the Grimoire.
    expect(spellTooltip('grave_frost', undefined, { key: '2' }).control).toContain('hold 2');
    expect(spellTooltip('grave_frost').control).toContain('Grimoire (L)');
    expect(spellTooltip('marrow_spear', undefined, { key: '4' }).control).toContain('hold 4');
    expect(spellTooltip('bone_mantle', undefined, { locked: true }).status).toBe(`Locked — unlocks at level ${ABILITIES.bone_mantle.unlockLevel}.`);
    expect(spellTooltip('wailing_skull').details.join(' ')).toContain('earns another leap');
    expect(spellTooltip('grave_step').details.join(' ')).toContain('not consumed');
    expect(spellTooltip('grave_frost').details.join(' ')).toContain('shatter');
    expect(spellTooltip('bone_mantle').details.join(' ')).toContain('Barrier');
  });

  it('separates the total cooldown from the live remaining time and locked/unaffordable state', () => {
    expect(metric('black_litany', 'Cooldown')).toBe(`${ABILITIES.black_litany.cooldownMs / 1000}s`);
    expect(spellTooltip('black_litany', undefined, { left: 2700 }).status).toBe('Ready in 3s.');
    expect(spellTooltip('black_litany', undefined, { left: 0, affordable: false }).status).toBe('Not enough Grave Essence.');
    expect(spellTooltip('dirge', undefined, { locked: true, left: 1000 }).status).toBe(`Locked — unlocks at level ${SIGNATURE_LEVEL}.`);
    expect(spellTooltip('miasma', undefined, { locked: true }).locked).toBe(false);
  });

  it('explains spear statuses and the corpse/army tradeoff without implying that explosions raise thralls', () => {
    expect(spellTooltip('marrow_spear').details.join(' ')).toContain(`${FRACTURE.maxStacks} stacks`);
    expect(spellTooltip('marrow_spear').details.join(' ')).toContain('Hemorrhage');
    expect(spellTooltip('corpse_explosion').details.join(' ')).toContain('cannot also become a thrall');
    expect(spellTooltip('black_litany').details.join(' ')).toContain('sacrifices');
    expect(spellTooltip('command_rend').details.join(' ')).toContain('Requires at least one thrall');
  });
});
