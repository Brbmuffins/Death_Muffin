import { describe, expect, it, vi, afterEach } from 'vitest';
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import {
  NECRO_DISCIPLINES, NECRO_MAIN_KINDS, NECRO_OFF_KINDS, NECRO_RECIPES, NECRO_TIERS, NECRO_WEAPONS, NECRO_WEAPON_BY_ID,
  NECRO_WEAPON_TUNING, isTwoHanded, necroWeaponLoot, necroWeaponTooltip,
} from '../necroWeapons';
import { AREAS } from '../areas';
import { ITEMS } from '../items';
import { gearTier, offhandKind, weaponKind } from '../gear';
import { DISCIPLINES } from '../disciplines';
import { handleMock } from '../../net/mockBackend';

describe('necro weapon catalogue', () => {
  it('has 4 main-hand kinds and 3 off-hands in 5 tiers (35 items) with unique ids that do not collide with existing items', () => {
    expect(NECRO_WEAPONS).toHaveLength((NECRO_MAIN_KINDS.length + NECRO_OFF_KINDS.length) * NECRO_TIERS.length);
    expect(new Set(NECRO_WEAPONS.map((w) => w.id)).size).toBe(35);
    for (const w of NECRO_WEAPONS) expect(w.id).toMatch(/^(staff|scythe|wand|sickle|skull_focus|grimoire|mourning_bell)_(bone|iron|gold|hell|moon)$/);
  });

  it('classifies every id with the gear regexes (kind and material tier)', () => {
    const tierColor = Object.fromEntries(NECRO_TIERS.map((t) => [t, gearTier(`wand_${t}`).color]));
    expect(new Set(Object.values(tierColor)).size).toBe(5);
    for (const w of NECRO_WEAPONS) {
      if (w.slot === 'main_hand') expect(weaponKind(w.id), w.id).toBe(w.kind);
      else expect(offhandKind(w.id), w.id).toBe(w.kind === 'skull_focus' ? 'skull' : w.kind === 'mourning_bell' ? 'bell' : 'tome');
      expect(gearTier(w.id).color, w.id).toBe(tierColor[w.tier]);
    }
  });

  it('rises in rarity, level, stats and price with tier, and staff/scythe are the two-handers', () => {
    const order = ['common', 'uncommon', 'rare', 'epic'];
    for (const kind of [...NECRO_MAIN_KINDS, ...NECRO_OFF_KINDS]) {
      const row = NECRO_TIERS.map((t) => NECRO_WEAPON_BY_ID[`${kind}_${t}`]);
      for (let i = 1; i < row.length; i++) {
        expect(order.indexOf(row[i].rarity), row[i].id).toBeGreaterThanOrEqual(order.indexOf(row[i - 1].rarity));
        expect(row[i].level).toBeGreaterThan(row[i - 1].level);
        expect(row[i].stats.stat_int).toBeGreaterThan(row[i - 1].stats.stat_int);
        expect(row[i].sell).toBeGreaterThan(row[i - 1].sell);
      }
      expect(row.map((w) => w.level)).toEqual([1, 15, 30, 45, 60]);
    }
    expect(NECRO_WEAPONS.filter((w) => w.twoHanded).map((w) => w.kind).sort()).toEqual([...Array(5).fill('scythe'), ...Array(5).fill('staff')]);
    expect(isTwoHanded('staff_moon')).toBe(true);
    expect(isTwoHanded('wand_moon')).toBe(false);
  });

  it('states the mechanic in every tooltip line and lore line', () => {
    for (const w of NECRO_WEAPONS) {
      expect(necroWeaponTooltip(w.id)?.effect.length, w.id).toBeGreaterThan(20);
      expect(w.lore.length).toBeGreaterThan(20);
    }
    expect(necroWeaponTooltip('staff_oak')).toBeNull();
    expect(NECRO_WEAPON_BY_ID.staff_bone.effect).toContain('25%');
    expect(NECRO_WEAPON_BY_ID.wand_bone.effect).toContain('30%');
  });

  it('registers every item in the client catalogue as equippable gear with its icon', () => {
    for (const w of NECRO_WEAPONS) {
      expect(ITEMS[w.id]?.type, w.id).toBe(w.type);
      expect(ITEMS[w.id]?.offlineStats).toEqual(w.stats);
      expect(existsSync(resolve(`public/art/items/${w.id}.svg`)), w.id).toBe(true);
    }
  });

  it('names only disciplines the game has', () => {
    for (const d of NECRO_DISCIPLINES) expect(DISCIPLINES[d as keyof typeof DISCIPLINES], d).toBeTruthy();
    expect(NECRO_DISCIPLINES).toEqual(['ossuary', 'gravecaller', 'mourner', 'rotweaver']);
  });
});

describe('necro weapon drops and recipes', () => {
  it('drops each tier in its zones with item ids the client (and so the server migration) knows', () => {
    const where = (id: string) => Object.values(AREAS).filter((a) => a.loot.some((d) => d.item === id)).map((a) => a.id);
    for (const w of NECRO_WEAPONS) {
      expect(where(w.id).sort(), w.id).toEqual([...(w.tier === 'bone' ? ['graves', 'warren'] : w.tier === 'iron' ? ['ossuary', 'coliseum'] : w.tier === 'gold' ? ['nave', 'sanctum'] : w.tier === 'hell' ? ['cloister', 'pyre'] : ['pyre'])].sort());
    }
    for (const a of Object.values(AREAS)) for (const d of a.loot) expect(ITEMS[d.item], `${a.id}:${d.item}`).toBeTruthy();
    expect(necroWeaponLoot('chapterhouse')).toEqual([]);
    expect(necroWeaponLoot('pyre').filter((d) => d.weight < 1)).toHaveLength(7);
  });

  it('keeps the line a modest share of each area table', () => {
    for (const a of Object.values(AREAS)) {
      const total = a.loot.reduce((n, d) => n + d.weight, 0);
      if (!total) continue;
      const line = a.loot.filter((d) => NECRO_WEAPON_BY_ID[d.item]).reduce((n, d) => n + d.weight, 0);
      expect(line / total, a.id).toBeLessThan(0.12);
    }
  });

  it('crafts every item from ingredients that exist', () => {
    expect(NECRO_RECIPES).toHaveLength(35);
    for (const [id, , prof, level, result, qty, ings] of NECRO_RECIPES) {
      expect(['mining', 'woodcutting'], id).toContain(prof);
      expect(level).toBeGreaterThan(0);
      expect(NECRO_WEAPON_BY_ID[result], id).toBeTruthy();
      expect(qty).toBe(1);
      for (const [item] of ings) expect(ITEMS[item], `${id}:${item}`).toBeTruthy();
    }
  });
});

describe('generated migration', () => {
  it('013-necro-weapons.sql and the icons match the catalogue (run node tools/generate-necro-weapons.mjs if this fails)', () => {
    expect(() => execFileSync('node', ['tools/generate-necro-weapons.mjs', '--check'], { stdio: 'pipe' })).not.toThrow();
    const sql = readFileSync(resolve('server/death-muffin/backend/migrations/013-necro-weapons.sql'), 'utf8');
    expect(sql).toContain('INSERT IGNORE INTO items');
    expect(sql).not.toMatch(/INSERT INTO|DROP|DELETE|UPDATE/);
    for (const w of NECRO_WEAPONS) expect(sql, w.id).toContain(`'${w.id}'`);
    // Two-handed flag rides on the row.
    expect(sql).toMatch(/'staff_bone', 'Vertebral Staff', 'common', 'weapon', 'main_hand', 1,/);
    expect(sql).toMatch(/'wand_bone', 'Knucklebone Wand', 'common', 'weapon', 'main_hand', 0,/);
    expect(sql).toContain("'grimoire_bone', 'Gravedigger''s Grimoire', 'common', 'offhand', 'off_hand', 0,");
  });

  it('never reuses an id the earlier migrations own', () => {
    for (const f of ['004-processing.sql', '009-alchemy.sql', '010-cosmetics.sql', '011-class-armor.sql', '012-ascended-armor.sql']) {
      const sql = readFileSync(resolve(`server/death-muffin/backend/migrations/${f}`), 'utf8');
      for (const w of NECRO_WEAPONS) expect(sql.includes(`'${w.id}'`), `${f} ${w.id}`).toBe(false);
    }
  });
});

describe('two-handed equip in offline play (the server enforces the same rule in /api/inventory/equip)', () => {
  afterEach(() => vi.unstubAllGlobals());
  it('a two-handed weapon displaces the off-hand, and an off-hand displaces a two-hander', async () => {
    const records = new Map<string, string>();
    vi.stubGlobal('localStorage', { getItem: (k: string) => records.get(k) ?? null, setItem: (k: string, v: string) => records.set(k, v) });
    records.set('cw_offline_db_v1', JSON.stringify({ nextCharacterId: 2, accounts: {
      nw_test: { username: 'nw_test', character: { id: 1 }, professions: [], slots: [
        { slot_index: 0, item_id: 'staff_iron', quantity: 1, equipped: 0 },
        { slot_index: 1, item_id: 'grimoire_iron', quantity: 1, equipped: 0 },
        { slot_index: 2, item_id: 'wand_iron', quantity: 1, equipped: 0 },
      ] },
    } }));
    const post = (body: object) => handleMock('/api/inventory/equip', { method: 'POST', body: JSON.stringify({ characterId: 1, ...body }) }, 'offline:nw_test');
    const where = (rows: { item_id: string; slot_index: number }[], id: string) => rows.find((s) => s.item_id === id)!.slot_index;
    // Off-hand first, then a two-hander: the grimoire goes back to the bag.
    let rows = (await post({ slot_index: 1, equipped: 1 })).data;
    expect(where(rows, 'grimoire_iron')).toBe(106);
    rows = (await post({ slot_index: 0, equipped: 1 })).data;
    expect(where(rows, 'staff_iron')).toBe(105);
    expect(where(rows, 'grimoire_iron')).toBeLessThan(24);
    // A two-hander worn, then an off-hand: the staff goes back.
    rows = (await post({ slot_index: where(rows, 'grimoire_iron'), equipped: 1 })).data;
    expect(where(rows, 'grimoire_iron')).toBe(106);
    expect(where(rows, 'staff_iron')).toBeLessThan(24);
    // A one-hander coexists with the off-hand.
    rows = (await post({ slot_index: where(rows, 'wand_iron'), equipped: 1 })).data;
    expect(where(rows, 'wand_iron')).toBe(105);
    expect(where(rows, 'grimoire_iron')).toBe(106);
  });
});

describe('server equip rule', () => {
  it('already enforces two_handed in POST /api/inventory/equip (no server change needed)', () => {
    const src = readFileSync(resolve('server/death-muffin/backend/server.js'), 'utf8');
    expect(src).toContain("if (inv.two_handed && row.equipped_slot === 'off_hand') return true;");
    expect(src).toContain("inv.equipment_slot === 'off_hand' && row.equipped_slot === 'main_hand' && row.two_handed");
  });
  it('tuning covers every number the prose quotes', () => {
    expect(NECRO_WEAPON_TUNING.scythe.arcDeg).toBe(100);
    expect(NECRO_WEAPON_TUNING.scythe.maxHits).toBe(3);
  });
});
