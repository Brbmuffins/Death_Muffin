import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { PREF_ONLY_CRAFTABLE, fetchAccountPrefs, lootPrefKey, reconcileBoolPref, reconcileLootRules, saveAccountPref } from '../accountPrefs';
import { DEFAULT_LOOT_RULES, LOOT_TIERS, actionsFor, type LootRules } from '../../gameplay/lootFilter';

const K = PREF_ONLY_CRAFTABLE;

describe('reconcileBoolPref', () => {
  it('the account wins when it has a value, either way', () => {
    expect(reconcileBoolPref(false, { [K]: true }, K)).toEqual({ value: true, pushUp: false });
    expect(reconcileBoolPref(true, { [K]: false }, K)).toEqual({ value: false, pushUp: false });
  });
  it('with no account value yet, a ticked browser copy is sent up and an unticked one is not', () => {
    expect(reconcileBoolPref(true, {}, K)).toEqual({ value: true, pushUp: true });
    expect(reconcileBoolPref(false, {}, K)).toEqual({ value: false, pushUp: false });
  });
  it('an unusable account value is ignored like a missing one', () => {
    expect(reconcileBoolPref(true, { [K]: 'yes' }, K)).toEqual({ value: true, pushUp: true });
  });
  it('unreachable account: the browser copy stands and nothing is sent', () => {
    expect(reconcileBoolPref(true, null, K)).toEqual({ value: true, pushUp: false });
    expect(reconcileBoolPref(false, null, K)).toEqual({ value: false, pushUp: false });
  });
});

describe('reconcileLootRules', () => {
  const rules = (o: Partial<LootRules> = {}): LootRules => ({ ...DEFAULT_LOOT_RULES, ...o });
  it('the account wins for every rarity it has a valid rule for', () => {
    const r = reconcileLootRules(rules({ common: 'gold' }), { loot_common: 'auto', loot_rare: 'gold', loot_legendary: 'auto' });
    expect(r.rules).toEqual(rules({ common: 'auto', rare: 'gold', legendary: 'auto' }));
    expect(r.pushUp).toEqual({});
  });
  it('a rarity the account lacks keeps the browser rule, and a non-default one is sent up', () => {
    const r = reconcileLootRules(rules({ uncommon: 'gold', epic: 'auto' }), { loot_common: 'ground' });
    expect(r.rules).toEqual(rules({ uncommon: 'gold', epic: 'auto' }));
    expect(r.pushUp).toEqual({ loot_uncommon: 'gold', loot_epic: 'auto' });
  });
  it('an invalid account value (a sold legendary, junk) is ignored like a missing one', () => {
    const r = reconcileLootRules(rules({ legendary: 'auto', rare: 'gold' }), { loot_legendary: 'gold', loot_rare: 'sell' });
    expect(r.rules).toEqual(rules({ legendary: 'auto', rare: 'gold' }));
    expect(r.pushUp).toEqual({ loot_legendary: 'auto', loot_rare: 'gold' });
  });
  it('unreachable account: nothing changes and nothing is sent', () => {
    expect(reconcileLootRules(rules({ rare: 'gold' }), null)).toEqual({ rules: rules({ rare: 'gold' }), pushUp: {} });
  });
});

describe('account preference calls never throw', () => {
  // Not signed in / no server in the test run: the request fails, and the helpers swallow it.
  it('fetch answers null and save resolves', async () => {
    expect(await fetchAccountPrefs()).toBeNull();
    await expect(saveAccountPref(K, true)).resolves.toBeUndefined();
  });
});

describe('the browser key matches the server', () => {
  it('only_craftable is a key the server knows', () => {
    const src = readFileSync(join(__dirname, '../../../server/death-muffin/backend/prefs.cjs'), 'utf8');
    expect(src).toContain(`${PREF_ONLY_CRAFTABLE}: { type: 'boolean' }`);
  });
  it('every loot rarity is a key the server knows, with the same choices (a legendary is never sold)', () => {
    const src = readFileSync(join(__dirname, '../../../server/death-muffin/backend/prefs.cjs'), 'utf8');
    for (const { id } of LOOT_TIERS) {
      const choices = actionsFor(id).map((a) => `'${a.id}'`).join(', ');
      expect(src, id).toContain(`${lootPrefKey(id)}: { type: 'enum', values: [${choices}] }`);
    }
  });
});
