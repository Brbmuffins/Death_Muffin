import { OFFLINE, getAccountPrefs, setAccountPrefs } from './api';
import { settings, updateSettings } from '../app/settings';
import { DEFAULT_LOOT_RULES, LOOT_TIERS, actionsFor, type LootAction, type LootRules, type LootTier } from '../gameplay/lootFilter';

/**
 * Account preferences: small UI settings that follow the account to any browser or device (server: backend/prefs.cjs, table account_prefs).
 * Every one keeps a browser copy too (localStorage), which is what the UI reads first and what remains when the server cannot be reached
 * or in the offline edition, where nothing here talks to a server at all. The keys must match DEFS in the server's prefs.cjs.
 */
export const PREF_ONLY_CRAFTABLE = 'only_craftable';
/** Settings -> Loot: one preference per gear rarity ('ground' | 'auto' | 'gold'), loot_common ... loot_legendary. */
export const lootPrefKey = (tier: LootTier) => `loot_${tier}`;

/** The account's saved preferences, or null when they cannot be had (offline edition, not signed in, server down): keep the browser copy. */
export async function fetchAccountPrefs(): Promise<Record<string, unknown> | null> {
  if (OFFLINE) return null;
  try {
    return await getAccountPrefs();
  } catch {
    return null;
  }
}

/** Save one preference to the account. Never throws: a failed save leaves the browser copy, and the next change tries again. */
export async function saveAccountPref(key: string, value: boolean | number | string): Promise<void> {
  if (OFFLINE) return;
  try {
    await setAccountPrefs({ [key]: value });
  } catch {
    /* offline, replaced window or server trouble: the browser copy stands */
  }
}

/**
 * Settle the loot rules between this browser and the account. For each rarity the account's value wins when it has a valid one; when it
 * has none yet and this browser's rule is not the default, that rule is sent up (so rules a player already set are not lost).
 */
export function reconcileLootRules(local: LootRules, remote: Record<string, unknown> | null): { rules: LootRules; pushUp: Record<string, LootAction> } {
  const rules: LootRules = { ...local };
  const pushUp: Record<string, LootAction> = {};
  if (!remote) return { rules, pushUp };
  for (const { id } of LOOT_TIERS) {
    const saved = remote[lootPrefKey(id)];
    const ok = actionsFor(id).find((a) => a.id === saved);
    if (ok) rules[id] = ok.id;
    else if (local[id] !== DEFAULT_LOOT_RULES[id]) pushUp[lootPrefKey(id)] = local[id];
  }
  return { rules, pushUp };
}

/** Pull the account's loot rules into Settings (once the world mounts), and send up any this browser holds that the account lacks. */
export async function syncLootRulesWithAccount(): Promise<void> {
  const remote = await fetchAccountPrefs();
  if (!remote) return;
  const { rules, pushUp } = reconcileLootRules(settings.lootRules, remote);
  if (LOOT_TIERS.some(({ id }) => rules[id] !== settings.lootRules[id])) updateSettings({ lootRules: rules });
  if (Object.keys(pushUp).length) {
    try {
      await setAccountPrefs(pushUp);
    } catch {
      /* the browser copy stands; the next change or visit tries again */
    }
  }
}

/** A loot rule was changed in Settings: keep it on the account too. */
export const saveLootRuleToAccount = (tier: LootTier, action: LootAction) => saveAccountPref(lootPrefKey(tier), action);

/**
 * Settle a boolean preference between the browser copy and the account. The account wins when it has a value; when it has none yet
 * and this browser has the setting on, that choice is sent up (so the box a player already ticked is not lost to the new store).
 * `value` is what to show; `pushUp` says whether to write it to the account.
 */
export function reconcileBoolPref(local: boolean, remote: Record<string, unknown> | null, key: string): { value: boolean; pushUp: boolean } {
  if (!remote) return { value: local, pushUp: false };
  const saved = remote[key];
  if (typeof saved === 'boolean') return { value: saved, pushUp: false };
  return { value: local, pushUp: local };
}
