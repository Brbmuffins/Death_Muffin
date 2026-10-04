import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { PREF_ONLY_CRAFTABLE, fetchAccountPrefs, reconcileBoolPref, saveAccountPref } from '../accountPrefs';

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
});
