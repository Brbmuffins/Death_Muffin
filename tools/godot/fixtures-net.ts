/**
 * Golden fixtures for godot/net: calls every exported src/net/api.ts function with a stubbed fetch and records the request
 * the TS client made (method, path, JSON body, headers), plus response-handling scenarios and killReporter/releaseWatch/session cases.
 * Run:  npx vite-node tools/godot/fixtures-net.ts   ->  godot/tests/net/fixtures/net.json
 */
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import * as api from '../../src/net/api';
import { KillReporter } from '../../src/net/killReporter';
import { parseRelease } from '../../src/net/releaseWatch';
import { reconcileBoolPref } from '../../src/net/accountPrefs';
import { claimSession, probeSessionNow, isReplacedReply, SESSION_REPLACED_MESSAGE } from '../../src/net/session';

type Rec = { method: string; path: string; headers: Record<string, string>; body: unknown };
let recorded: Rec[] = [];
let reply: { status: number; body: unknown; throws?: boolean } = { status: 200, body: { success: true, data: [] } };

(globalThis as any).fetch = async (url: string, init: RequestInit = {}) => {
  recorded.push({
    method: String(init.method ?? 'GET').toUpperCase(),
    path: String(url),
    headers: { ...((init.headers as Record<string, string>) ?? {}) },
    body: init.body === undefined ? undefined : JSON.parse(String(init.body)),
  });
  if (reply.throws) throw new TypeError('network down');
  return { ok: reply.status >= 200 && reply.status < 300, status: reply.status, json: async () => { if (reply.body === undefined) throw new Error('no json'); return reply.body; } };
};

const OK = { success: true, data: [] };
const calls: { name: string; token: boolean; run: () => Promise<unknown> }[] = [];
const add = (name: string, run: () => Promise<unknown>, token = true) => calls.push({ name, token, run });

add('login', () => api.login('qa_user', 'pw'), false);
add('register', () => api.register('qa_user', 'a@b.co', 'pw12345678'), false);
add('health', () => api.health(), false);
add('loadOrCreateCharacter_undefined', () => api.loadOrCreateCharacter());
add('loadOrCreateCharacter_3', () => api.loadOrCreateCharacter(3));
add('loadOrCreateCharacter_7', () => api.loadOrCreateCharacter(7));
add('getCharacter', () => api.getCharacter());
add('changeDiscipline', () => api.changeDiscipline(12, 6));
add('getInventory', () => api.getInventory(12));
add('saveInventory', () => api.saveInventory(12, [{ slot_index: 0, item_id: 'x', quantity: 1, equipped: 0 }], 48));
add('saveInventory_nobag', () => api.saveInventory(12, []));
add('equipItem', () => api.equipItem(12, 3, 1));
add('rollLoot', () => api.rollLoot(12, [{ item_id: 'sword', level: 5, source: 'enemy' as any }]));
add('beltTool', () => api.beltTool(12, 4, 0));
add('kitMove', () => api.kitMove(12, 4, 1));
add('runeSocket', () => api.runeSocket(12, 'bone_spear', 'rune_x'));
add('runeSocket_null', () => api.runeSocket(12, 'bone_spear', null));
add('listLoadouts', () => api.listLoadouts(12));
add('saveLoadout', () => api.saveLoadout(12, 2, { name: 'p' } as any));
add('deleteLoadout', () => api.deleteLoadout(12, 2));
add('applyLoadoutPreset', () => api.applyLoadoutPreset(12, 2));
add('getAccountPrefs', () => api.getAccountPrefs());
add('setAccountPrefs', () => api.setAccountPrefs({ only_craftable: true, loot_common: 'auto' }));
add('getProfessions', () => api.getProfessions(12));
add('getRecipes', () => api.getRecipes('black smith/x'), false);
add('craft', () => api.craft(12, 'recipe_copper_bar'));
add('gather', () => api.gather(12, 'copper_vein', 5));
add('gather_afk', () => api.gather(12, 'copper_vein', 5, true, true));
add('beginAfkGather', () => api.beginAfkGather(12, 'copper_vein'));
add('saveProgress', () => api.saveProgress({ characterId: 12, level: 5, xp: 10, gold: 3, stat_str: 5, stat_agi: 5, stat_int: 5, stat_vit: 5 }));
add('saveProgress_kills', () => api.saveProgress({ characterId: 12, level: 5, xp: 10, gold: 3, stat_str: 5, stat_agi: 5, stat_int: 5, stat_vit: 5, killReports: [{ seq: 1, groups: [], bosses: [], floors: [] } as any] }));
add('reportKills', () => api.reportKills(12, [{ seq: 1, groups: [], bosses: [], floors: [] } as any]));
add('necro_get', () => api.necroApi.get(12));
add('necro_save', () => api.necroApi.save(12, { kills: 3 } as any));
add('necro_purchase', () => api.necroApi.purchase(12, 'damage'));
add('necro_summonPrelate', () => api.necroApi.summonPrelate(12));
add('necro_summonBoss', () => api.necroApi.summonBoss(12, 'warden'));
add('necro_ascend', () => api.necroApi.ascend(12));
add('necro_vows', () => api.necroApi.vows(12, { a: 1 }));
add('necro_unlock', () => api.necroApi.unlock(12, 'k'));
add('necro_boon', () => api.necroApi.boon(12, 'b'));
add('necro_importLocal', () => api.necroApi.importLocal(12, { r: 1 }));
add('getChronicle', () => api.getChronicle(12));
add('addChronicle', () => api.addChronicle(12, { kills: 3 }, { 'peak.depth': 4 }));
add('ascendChronicle', () => api.ascendChronicle(12, 2));
add('getContracts', () => api.getContracts(12));
add('deliverContract', () => api.deliverContract(12, 1));
add('getGarden', () => api.getGarden(12));
add('plantGarden', () => api.plantGarden(12, 'herb1', 'seed_x', true));
add('harvestGarden', () => api.harvestGarden(12, 'herb1'));
add('getLabor', () => api.getLabor(12));
add('assignLabor', () => api.assignLabor(12, 0, 'copper_vein'));
add('assignLabor_null', () => api.assignLabor(12, 0, null));
add('collectLabor', () => api.collectLabor(12, 0));
add('getCosmetics', () => api.getCosmetics(12));
add('selectCosmetics', () => api.selectCosmetics(12, { cape: null }));
add('adoptPet', () => api.adoptPet(12, 'raven'));
add('getVault', () => api.getVault(12));
add('vaultDeposit', () => api.vaultDeposit(12, 3, 2));
add('vaultDeposit_noqty', () => api.vaultDeposit(12, 3));
add('vaultWithdraw', () => api.vaultWithdraw(12, 3, 2));
add('vaultDepositAll', () => api.vaultDepositAll(12, 'materials', [0, 1]));
add('vaultSort', () => api.vaultSort(12));
add('salvageGear', () => api.salvageGear(12, [1, 2]));
add('reforgeQuote', () => api.reforgeQuote(12));
add('reforgeAffix', () => api.reforgeAffix(12, 3, 1, 500));
add('bossKeyStatus', () => api.bossKeyStatus(12));
add('bossKeySummon', () => api.bossKeySummon(12, 'warden'));
add('bossKeyRefund', () => api.bossKeyRefund(12, 'warden'));
add('bossKeyClaim', () => api.bossKeyClaim(12, 'warden', 'gravecaller', 30));
add('sendBugReport', () => api.sendBugReport({ category: 'bug', message: 'it broke badly', characterId: 12, context: { a: 1 } }));
add('getMyBugReports', () => api.getMyBugReports());

/** Per-endpoint canned replies so wrappers that read fields (vault bag/vault, salvage bag, applyLoadout report) do not crash. */
const SHAPED: Record<string, unknown> = {
  getVault: { success: true, data: { bag: [], vault: [] } }, vaultDeposit: { success: true, data: { bag: [], vault: [] } },
  vaultDeposit_noqty: { success: true, data: { bag: [], vault: [] } }, vaultWithdraw: { success: true, data: { bag: [], vault: [] } },
  vaultDepositAll: { success: true, data: { bag: [], vault: [] } }, vaultSort: { success: true, data: { bag: [], vault: [] } },
  salvageGear: { success: true, data: { bag: [], salvaged: [], gained: [], xp: 0 } },
  reforgeAffix: { success: true, data: { bag: [], gold: 1 } },
  bossKeySummon: { success: true, data: { bag: [], gold: 1 } }, bossKeyRefund: { success: true, data: { bag: [], gold: 1 } },
  applyLoadoutPreset: { success: true, data: [], report: { x: 1 }, preset: { name: 'p' } },
  loadOrCreateCharacter_7: { id: 12 }, loadOrCreateCharacter_3: { id: 12 }, loadOrCreateCharacter_undefined: { id: 12 },
};

async function run() {
  const requests: Record<string, Rec[]> = {};
  for (const c of calls) {
    api.setToken(c.token ? 'TESTJWT' : null);
    recorded = [];
    reply = { status: 200, body: SHAPED[c.name] ?? (c.name === 'login' || c.name === 'register' ? { token: 'T' } : OK) };
    await c.run().catch(() => {});
    requests[c.name] = recorded;
  }

  // Response handling: same call, different server replies, record what the TS client returned / threw.
  const scenarios: { id: string; call: string; reply: { status: number; body: unknown; throws?: boolean }; token: boolean; outcome: any; notices: string[] }[] = [];
  const scenario = async (id: string, call: string, r: typeof reply, token = true) => {
    api.setToken(token ? 'TESTJWT' : null);
    recorded = [];
    reply = r;
    const notices: string[] = [];
    const off = api.onServerNotice((m) => notices.push(m));
    const fn = calls.find((c) => c.name === call)!;
    let outcome: any;
    try { outcome = { ok: true, value: await fn.run() }; } catch (e: any) { outcome = { ok: false, name: e.name, message: e.message, status: e.status }; }
    off();
    scenarios.push({ id, call, reply: r, token, outcome, notices });
  };
  await scenario('login_ok', 'login', { status: 200, body: { token: 'abc' } }, false);
  await scenario('login_401', 'login', { status: 401, body: { error: 'Invalid username or password.' } }, false);
  await scenario('login_429', 'login', { status: 429, body: undefined }, false);
  await scenario('login_500_nojson', 'login', { status: 500, body: undefined }, false);
  await scenario('login_network', 'login', { status: 0, body: undefined, throws: true }, false);
  await scenario('inv_unauth', 'getCharacter', { status: 200, body: { id: 1 } }, false);
  await scenario('inv_success_false', 'getProfessions', { status: 200, body: { success: false, error: 'no way' } });
  await scenario('inv_success_false_noerr', 'getProfessions', { status: 200, body: { success: false } });
  await scenario('inv_403', 'getProfessions', { status: 403, body: { success: false, error: 'character not found or not owned by this account' } });
  await scenario('save_authority', 'saveProgress', { status: 200, body: { success: true, data: { saved: true }, authority: { message: 'The server held some XP back.' } } });
  await scenario('gather_reply', 'gather', { status: 200, body: { success: true, data: { node: 'copper_vein', accepted: 3, items: [{ itemId: 'copper_ore', qty: 3 }] } } });
  await scenario('applyLoadout_fail', 'applyLoadoutPreset', { status: 200, body: { success: false, error: 'That loadout is empty.' } });
  await scenario('applyLoadout_ok', 'applyLoadoutPreset', { status: 200, body: { success: true, data: [], report: { skipped: [] }, preset: { name: 'x' } } });
  await scenario('necro_ok', 'necro_get', { status: 200, body: { success: true, data: { progress: { kills: 4 }, gold: 9 } } });
  await scenario('necro_404', 'necro_get', { status: 404, body: { error: 'Not found' } });
  // The replaced-session flag is module state that never resets: these must stay last.
  await scenario('save_409_replaced', 'saveProgress', { status: 409, body: { success: false, error: 'This account was opened somewhere else.', code: 'session_replaced' } });
  await scenario('after_replaced_write_blocked', 'saveProgress', { status: 200, body: { success: true, data: {} } });
  await scenario('after_replaced_read_allowed', 'getProfessions', { status: 200, body: { success: true, data: [{ profession_id: 'mining', skill_level: 2, skill_xp: 5 }] } });

  const prefix = (s: string) => s;
  const releaseCases = ['abc1234 2026-10-04T10:00:00Z', 'ABCDEF0123456789\n', '', 'zzz', 'abc12 x', 'a'.repeat(64) + ' t', 'a'.repeat(65)].map((t) => ({ text: t, out: parseRelease(t) }));
  const boolPref = [[true, null, 'k'], [false, null, 'k'], [true, { k: false }, 'k'], [false, { k: true }, 'k'], [true, {}, 'k'], [false, {}, 'k'], [true, { k: 'yes' }, 'k']].map(([l, r, k]: any) => ({ local: l, remote: r, key: k, out: reconcileBoolPref(l, r, k) }));
  const replacedCases = [[409, { code: 'session_replaced' }], [409, { code: 'x' }], [409, null], [500, { code: 'session_replaced' }], [409, 'str']].map(([s, b]: any) => ({ status: s, body: b, out: isReplacedReply(s, b) }));

  // session claim / probe
  recorded = []; reply = { status: 200, body: { token: 'NEW' } };
  const claimed = await claimSession('OLDJWT');
  const claimReq = recorded.slice();
  recorded = []; reply = { status: 401, body: { error: 'x' } };
  const claimedFail = await claimSession('OLDJWT');
  recorded = []; reply = { status: 200, body: { success: true, active: true } };
  await probeSessionNow('TOK');
  const probeReq = recorded.slice();

  // killReporter: scripted sequence with an injected clock
  const kr = (() => {
    let t = 1_000_000;
    const r = new KillReporter(() => t);
    const log: any[] = [];
    const snap = (label: string) => log.push({ label, hasPending: r.hasPending, crowded: r.crowded, batches: JSON.parse(JSON.stringify(r.batches())) });
    const k = (o: any = {}) => ({ area: 'hollow', def: 'ghoul', level: 3, elite: false, tier: 1, diff: 'medium', rank: 0, xpMult: 1.234, goldMult: 1, shardMult: 1, ...o });
    log.push({ label: 'start', hasPending: r.hasPending });
    r.kill(k()); r.kill(k()); r.kill(k({ elite: true })); r.kill(k({ xpMult: 1.236 }));
    r.boss({ boss: 'warden', tier: 1, diff: 'medium', first: true, summon: 4 } as any); r.boss({ boss: 'warden', tier: 1, diff: 'medium', first: true, summon: 4 } as any);
    r.floor({ depth: 2, mult: 1.005 } as any);
    log.push({ label: 'open', hasPending: r.hasPending });
    snap('seal1');
    t = 900_000; // clock goes backwards: seq must still increase
    r.kill(k({ level: 9 }));
    snap('seal2_clock_back');
    r.ack(1_000_000);
    snap('after_ack');
    for (let i = 0; i < 6; i++) { t += 1; r.kill(k({ level: 20 + i })); r.batches(); }
    snap('overflow_drop_oldest');
    r.discard();
    log.push({ label: 'discarded', hasPending: r.hasPending });
    const r2 = new KillReporter(() => 5);
    for (let i = 0; i < 119; i++) r2.kill(k({ level: i }));
    const a = r2.crowded; r2.kill(k({ level: 500 }));
    log.push({ label: 'crowded', before: a, after: r2.crowded });
    return log;
  })();

  const out = { generatedBy: 'tools/godot/fixtures-net.ts', requests, scenarios, releaseCases, boolPref, replacedCases, claim: { ok: claimed, req: claimReq, fail: claimedFail }, probeReq, killReporter: kr, sessionReplacedMessage: SESSION_REPLACED_MESSAGE };
  const file = resolve(dirname(new URL(import.meta.url).pathname), '../../godot/tests/net/fixtures/net.json');
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(file, JSON.stringify(out, null, 1));
  console.log(`wrote ${file}: ${Object.keys(requests).length} request fixtures, ${scenarios.length} scenarios`);
}
run();
