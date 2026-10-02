import { describe, expect, it } from 'vitest';
import { AREAS } from '../../content/areas';
import { BOSSES, BOSS_IDS } from '../../content/bosses';
import { LABEL, TOPICS, adviceLines, greetingLines, topicLines, farewell } from '../../content/dialogue';
import { NPCS, NPC_IDS, NPC_LOOKS, npcFromInteractable, npcInteractableId } from '../../content/npcs';
import { CREATURE_MODELS } from '../../graphics/modelPaths';
import { codexPeopleRows } from '../../content/codex';
import { existsSync } from 'node:fs';
import type { StorageLike } from '../codexJournal';
import {
  Guidance, baseState, bossesWaiting, loadMemory, newsFor, nextSuggestion, pendingSeals, saveMemory, suggestionFor, suggestions, summarizeContracts,
  summarizeLabor, guidanceStorageKey,
} from '../guidance';
import type { ContractBoard, LaborView } from '../../net/api';

const memStore = (): StorageLike & { data: Map<string, string> } => {
  const data = new Map<string, string>();
  return { data, getItem: (k) => data.get(k) ?? null, setItem: (k, v) => void data.set(k, v) };
};

describe('suggested next step: the road', () => {
  it('sends a brand-new character to the Hollow Graves', () => {
    const s = baseState({ area: 'acre' });
    const n = nextSuggestion(s)!;
    expect(n.kind).toBe('first-steps');
    expect(n.place).toBe('graves');
    expect(n.target).toBeDefined();
  });

  it('shows the live seal count, with the same wording the owner asked for', () => {
    const s = baseState({ area: 'graves', totalKills: 172, areaKills: { graves: 172 } });
    const n = nextSuggestion(s)!;
    expect(n.kind).toBe('seal');
    expect(n.text).toBe('Hollow Graves: 172 / 300 to open the Marrow Ossuary');
  });

  it('honours the Swift Seals multiplier and caps the count at the need', () => {
    const s = baseState({ area: 'graves', totalKills: 500, areaKills: { graves: 500 }, unlockMult: 0.5 });
    expect(pendingSeals(s)[0]).toMatchObject({ area: 'ossuary', kills: 150, need: 150 });
  });

  it('names a king you can afford, ahead of the seal count', () => {
    const s = baseState({ area: 'graves', totalKills: 80, areaKills: { graves: 80 }, shards: 2 });
    const n = nextSuggestion(s)!;
    expect(n.kind).toBe('boss-ready');
    expect(n.text).toBe("The Gravedigger King waits at the King's Grave — 2 soul shards");
    expect(n.target).toEqual({ x: expect.any(Number), z: expect.any(Number) });
    expect(n.pingInPlace).toBe(true);
  });

  it('prefers the seal while shards are short, and still says what the king needs', () => {
    const s = baseState({ area: 'graves', totalKills: 80, areaKills: { graves: 80 }, shards: 1 });
    expect(nextSuggestion(s)!.kind).toBe('seal');
    const short = suggestions(s).find((x) => x.kind === 'boss-short')!;
    expect(short.text).toContain('1 / 2');
  });

  it('does not offer a king whose hall is still sealed, or one already buried', () => {
    const s = baseState({ shards: 99, totalKills: 50, bossesBeaten: ['gravedigger'] });
    expect(bossesWaiting(s)).toEqual([]);
    expect(suggestions(s).some((x) => x.kind.startsWith('boss'))).toBe(false);
    const open = baseState({ shards: 99, totalKills: 50, unlocked: ['ossuary'] });
    expect(bossesWaiting(open)).toEqual(['gravedigger', 'abbess']);
  });

  it('walks the whole road in order as seals open', () => {
    const chain = ['ossuary', 'nave', 'sanctum', 'cloister', 'pyre', 'fen'] as const;
    const seen: string[] = [];
    const unlocked: (typeof chain)[number][] = [];
    for (const next of chain) {
      const s = baseState({ totalKills: 99, unlocked: [...unlocked], bossesBeaten: [...BOSS_IDS].filter((b) => b !== 'prelate') as never, prelateThisRun: true, shards: 0, areaKills: { graves: 1, ossuary: 1, nave: 1, sanctum: 1, cloister: 1, pyre: 1 } });
      const sg = suggestions(s).find((x) => x.kind === 'seal')!;
      seen.push(sg.id);
      unlocked.push(next);
    }
    expect(seen).toEqual(chain.map((a) => `seal:${a}`));
  });

  it('keeps side halls off the main road suggestion', () => {
    const s = baseState({ totalKills: 200, areaKills: { graves: 200 } });
    const seals = pendingSeals(s);
    expect(seals[0].area).toBe('ossuary');
    expect(seals.map((x) => x.area)).toContain('warren');
    expect(suggestions(s).filter((x) => x.kind === 'seal')).toHaveLength(1);
  });

  it('offers Ascension once the Prelate has fallen this run', () => {
    const s = baseState({ totalKills: 5000, canAscend: true, ashesOnAscend: 12, unlocked: ['ossuary', 'nave', 'sanctum'], prelateThisRun: true });
    const n = suggestions(s).find((x) => x.kind === 'ascend')!;
    expect(n.text).toBe('The Altar of Ascension is ready: +12 Ashes when you choose');
    expect(n.place).toBe('chapterhouse');
  });

  it('falls back to a hunting ground when everything is done', () => {
    const all = ['ossuary', 'nave', 'sanctum', 'cloister', 'pyre', 'fen', 'warren', 'coliseum'] as never;
    const s = baseState({ totalKills: 9999, unlocked: all, bossesBeaten: BOSS_IDS.filter((b) => b !== 'prelate'), prelateThisRun: true, skills: { mining: 3 } });
    const n = nextSuggestion(s)!;
    expect(n.kind).toBe('hunt');
    expect(n.data.clear).toBe(1);
    expect(n.text).toContain('Mourning Fen');
  });

  it('a dismissed suggestion steps aside for the next one, and returns on its own id only', () => {
    const s = baseState({ totalKills: 99, areaKills: { graves: 10 }, bagUsed: 45, bagSize: 48 });
    expect(nextSuggestion(s)!.id).toBe('bag-full');
    expect(nextSuggestion(s, 'bag-full')!.kind).toBe('seal');
  });

  it('only suggests unbeaten kings in the order of the road', () => {
    const s = baseState({ totalKills: 300, unlocked: ['ossuary', 'nave'], shards: 10 });
    expect(suggestions(s).find((x) => x.kind === 'boss-ready')!.id).toBe('boss-ready:gravedigger');
    const after = baseState({ totalKills: 300, unlocked: ['ossuary', 'nave'], shards: 10, bossesBeaten: ['gravedigger'] });
    expect(suggestions(after).find((x) => x.kind === 'boss-ready')!.id).toBe('boss-ready:abbess');
  });
});

describe('suggested next step: the Acre and the Workbench', () => {
  const labor = (over: Partial<NonNullable<ReturnType<typeof summarizeLabor>>> = {}) => ({ unlocked: 2, assigned: 2, ready: 0, ...over });

  it('a full bag outranks everything but the first steps', () => {
    const s = baseState({ totalKills: 99, shards: 2, bagUsed: 42, bagSize: 48 });
    expect(nextSuggestion(s)!.kind).toBe('bag-full');
    expect(nextSuggestion(baseState({ bagUsed: 20, bagSize: 48, totalKills: 99 }))!.kind).not.toBe('bag-full');
  });

  it('reports laborers that are ready, not those still working', () => {
    expect(suggestions(baseState({ totalKills: 50, labor: labor({ ready: 2 }) })).find((x) => x.kind === 'labor-ready')!.text).toBe('Your laborers are ready in the Acre (H)');
    expect(suggestions(baseState({ totalKills: 50, labor: labor() })).some((x) => x.kind === 'labor-ready')).toBe(false);
    expect(suggestions(baseState({ totalKills: 50, labor: null })).some((x) => x.kind === 'labor-ready')).toBe(false);
  });

  it('notes an idle laborer and open contracts, but only when known', () => {
    const s = baseState({ totalKills: 50, labor: labor({ assigned: 1 }), contracts: { open: 3, total: 3 } });
    const kinds = suggestions(s).map((x) => x.kind);
    expect(kinds).toContain('labor-idle');
    expect(suggestions(s).find((x) => x.kind === 'contracts')!.text).toBe('3 Sexton’s Contracts wait for delivery (O)');
    expect(suggestions(baseState({ totalKills: 50, contracts: { open: 0, total: 3 } })).some((x) => x.kind === 'contracts')).toBe(false);
  });

  it('introduces gathering only to a fighter who has not tried it', () => {
    expect(suggestions(baseState({ totalKills: 30 })).some((x) => x.kind === 'gather-intro')).toBe(true);
    expect(suggestions(baseState({ totalKills: 30, skills: { mining: 4 } })).some((x) => x.kind === 'gather-intro')).toBe(false);
    expect(suggestions(baseState({ totalKills: 30, labor: { unlocked: 1, assigned: 1, ready: 0 } })).some((x) => x.kind === 'gather-intro')).toBe(false);
  });

  it('brews: enough dust is a pointer to the Workbench; too little is a quiet hint only the Apothecary gives', () => {
    const rich = suggestions(baseState({ totalKills: 30, dust: 5 })).find((x) => x.kind === 'brew-dust')!;
    expect(rich.text).toBe('You carry 5 Grave Dust: brew a tonic at the Workbench (C)');
    const poor = suggestions(baseState({ totalKills: 30, dust: 1 })).find((x) => x.kind === 'brew-first')!;
    expect(poor.quiet).toBe(true);
    expect(nextSuggestion(baseState({ totalKills: 30, dust: 1, areaKills: { graves: 5 } }))!.kind).not.toBe('brew-first');
    expect(suggestions(baseState({ totalKills: 30, dust: 9, skills: { alchemy: 8 } })).some((x) => x.kind === 'brew-dust')).toBe(false);
  });

  it('each person answers on their own subject', () => {
    const s = baseState({ totalKills: 99, areaKills: { graves: 10 }, bagUsed: 45, bagSize: 48, dust: 6 });
    expect(suggestionFor('prior', s)!.topic).toBe('route');
    expect(suggestionFor('sexton', s)!.kind).toBe('bag-full');
    expect(suggestionFor('apothecary', s)!.kind).toBe('brew-dust');
  });

  it('summarizes the labor and contract views the API returns', () => {
    const v = {
      now: 0, capMs: 8 * 3_600_000, totalLevel: 7, levelsPerSlot: 50,
      slots: [
        { slot: 0, unlocked: true, nodeType: 'coffin_oak', elapsedMs: 40 * 60_000, capped: false },
        { slot: 1, unlocked: true, nodeType: 'seam_copper', elapsedMs: 5 * 60_000, capped: false },
        { slot: 2, unlocked: true, nodeType: null, elapsedMs: 0, capped: false },
        { slot: 3, unlocked: false, nodeType: null, elapsedMs: 0, capped: false },
      ],
    } as unknown as LaborView;
    expect(summarizeLabor(v)).toEqual({ unlocked: 3, assigned: 2, ready: 1 });
    const b = { contracts: [{ done: true }, { done: false }, { done: false }] } as unknown as ContractBoard;
    expect(summarizeContracts(b)).toEqual({ open: 2, total: 3 });
  });
});

describe('something new to say', () => {
  const s0 = baseState({ totalKills: 40 });

  it('a stranger always has a welcome; telling it clears the mark', () => {
    const g = new Guidance(1, memStore());
    expect(g.hasSomethingNew('prior', s0)).toBe(true);
    g.told('prior', s0);
    expect(g.hasSomethingNew('prior', s0)).toBe(false);
  });

  it('a first meeting does not replay what was already true as news', () => {
    const rich = baseState({ totalKills: 900, unlocked: ['ossuary', 'nave'], bossesBeaten: ['gravedigger'] });
    const g = new Guidance(1, memStore());
    g.told('prior', rich);
    expect(g.unheard('prior', rich)).toEqual([]);
  });

  it('a broken seal, a buried king and a ready Altar are each told once', () => {
    const g = new Guidance(1, memStore());
    g.told('prior', s0);
    const s1 = baseState({ totalKills: 400, unlocked: ['ossuary'] });
    expect(g.unheard('prior', s1).map((x) => x.key)).toEqual(['seal:ossuary:0']);
    expect(g.hasSomethingNew('prior', s1)).toBe(true);
    g.told('prior', s1);
    expect(g.hasSomethingNew('prior', s1)).toBe(false);
    const s2 = { ...s1, bossesBeaten: ['gravedigger' as const] };
    expect(g.unheard('prior', s2).map((x) => x.key)).toEqual(['boss:gravedigger:0']);
    const s3 = { ...s2, canAscend: true, ashesOnAscend: 3, prelateThisRun: true };
    expect(g.unheard('prior', s3).map((x) => x.key)).toContain('ascend:ready:0');
  });

  it('seals opened again after an Ascension are news again', () => {
    const g = new Guidance(1, memStore());
    g.told('prior', baseState({ unlocked: ['ossuary'] }));
    const again = baseState({ ascension: 1, unlocked: ['ossuary'] });
    expect(g.unheard('prior', again).map((x) => x.key).sort()).toEqual(['rank:1', 'seal:ossuary:1']);
  });

  it('transient news (bag, laborers) returns after a new session but not while you are in this one', () => {
    const store = memStore();
    const busy = baseState({ totalKills: 40, bagUsed: 45, bagSize: 48, labor: { unlocked: 1, assigned: 1, ready: 1 } });
    const g = new Guidance(1, store);
    g.told('sexton', busy);
    expect(g.hasSomethingNew('sexton', busy)).toBe(false);
    expect(new Guidance(1, store).hasSomethingNew('sexton', busy)).toBe(true); // a new session hears it again
    expect(new Guidance(1, store).met('sexton')).toBe(true);
    expect(new Guidance(1, store).unheard('sexton', busy).map((x) => x.key).sort()).toEqual(['bag:full', 'labor:ready']);
  });

  it('keeps the memory per character and survives broken storage', () => {
    const store = memStore();
    const a = new Guidance(1, store);
    a.told('prior', s0);
    a.hearTopic('prior', 'seals');
    expect(new Guidance(1, store).heardTopic('prior', 'seals')).toBe(true);
    expect(new Guidance(2, store).met('prior')).toBe(false);
    expect(new Guidance(3, null).hasSomethingNew('prior', s0)).toBe(true);
    store.data.set(guidanceStorageKey(9), '{not json');
    expect(loadMemory(store, 9).met).toEqual([]);
    store.data.set(guidanceStorageKey(8), JSON.stringify({ met: ['prior', 'ghost', 4], heard: ['x', 7] }));
    expect(loadMemory(store, 8)).toMatchObject({ met: ['prior'], heard: ['x'] });
    saveMemory({ getItem: () => null, setItem: () => { throw new Error('quota'); } }, 1, a.mem);
  });

  it('first sight fires once per person', () => {
    const g = new Guidance(1, memStore());
    expect(g.firstSight('sexton')).toBe(true);
    expect(g.firstSight('sexton')).toBe(false);
    expect(g.firstSight('prior')).toBe(true);
  });

  it('newsFor stays inside each person’s subject', () => {
    const s = baseState({ canAscend: true, bagUsed: 47, bagSize: 48, dust: 8 });
    expect(newsFor('prior', s).some((n) => n.key.startsWith('ascend'))).toBe(true);
    expect(newsFor('sexton', s).map((n) => n.key)).toEqual(['bag:full']);
    expect(newsFor('apothecary', s).map((n) => n.key)).toEqual(['dust:first']);
  });
});

describe('dialogue', () => {
  const states = {
    fresh: baseState({ area: 'chapterhouse' }),
    mid: baseState({ level: 8, totalKills: 400, unlocked: ['ossuary'], areaKills: { graves: 400, ossuary: 33 }, shards: 3, bagUsed: 44, bagSize: 48, dust: 6, labor: { unlocked: 2, assigned: 1, ready: 1 }, contracts: { open: 2, total: 3 } }),
    late: baseState({ level: 60, totalKills: 9000, ascension: 2, canAscend: true, ashesOnAscend: 40, prelateThisRun: true, unlocked: ['ossuary', 'nave', 'sanctum', 'cloister', 'pyre', 'fen', 'warren', 'coliseum'], bossesBeaten: BOSS_IDS.filter((b) => b !== 'prelate'), skills: { alchemy: 12 } }),
  };

  it('every person has a root question, three topics, and every line is short plain text', () => {
    const lines: string[] = [];
    for (const npc of NPC_IDS) {
      expect(LABEL.advice[npc].length).toBeGreaterThan(5);
      expect(TOPICS[npc]).toHaveLength(3);
      for (const [name, s] of Object.entries(states)) {
        for (const met of [false, true]) lines.push(...greetingLines(npc, s, newsFor(npc, s), met));
        lines.push(...adviceLines(npc, s));
        for (const t of TOPICS[npc]) lines.push(...topicLines(npc, t.id, s));
        lines.push(farewell(npc, s));
        expect(name).toBeTruthy();
      }
    }
    for (const l of lines) {
      expect(l.trim().length, l).toBeGreaterThan(10);
      expect(l.length, l).toBeLessThan(260);
      expect(l, l).not.toMatch(/undefined|NaN|\[object|<\w+>|\$\{/);
    }
  });

  it('an answer is never more than three short lines', () => {
    for (const npc of NPC_IDS) for (const s of Object.values(states)) {
      expect(adviceLines(npc, s).length).toBeLessThanOrEqual(3);
      for (const t of TOPICS[npc]) expect(topicLines(npc, t.id, s).length).toBeLessThanOrEqual(3);
    }
  });

  it('the Prior quotes real numbers: seal progress and boss shards', () => {
    const s = states.mid;
    const a = adviceLines('prior', s).join(' ');
    expect(a).toMatch(/Marrow Ossuary|Drowned Nave|Gravedigger|Abbess/);
    const seals = topicLines('prior', 'seals', s).join(' ');
    expect(seals).toContain('33 of 420');
    const bosses = topicLines('prior', 'bosses', s).join(' ');
    expect(bosses).toContain('you hold 3');
  });

  it('greets by situation: stranger, then ascension, then a new seal', () => {
    const s = states.late;
    expect(greetingLines('prior', s, [], false).join(' ')).toMatch(/Welcome to the Chapterhouse/);
    const ascend = newsFor('prior', s).filter((n) => n.key.startsWith('ascend'));
    expect(greetingLines('prior', s, ascend, true).join(' ')).toContain('40 Ashes');
    const seal = [{ key: 'seal:nave:0', persist: true }];
    expect(greetingLines('prior', states.mid, seal, true).join(' ')).toContain('Drowned Nave');
  });

  it('the Sexton and the Apothecary respond to bag, laborers, contracts and dust', () => {
    const s = states.mid;
    expect(adviceLines('sexton', s).join(' ')).toContain('44 of 48');
    expect(topicLines('sexton', 'contracts', s).join(' ')).toContain('2 of today');
    expect(topicLines('sexton', 'gather', s).join(' ')).toContain('work waiting');
    expect(adviceLines('apothecary', s).join(' ')).toContain('6 Grave Dust');
    expect(topicLines('apothecary', 'brewing', states.fresh).join(' ')).toContain('You hold 0');
  });

  it('boss hints exist for every king and match a real fight', () => {
    for (const id of BOSS_IDS) {
      const s = baseState({ totalKills: 99, shards: 99, unlocked: ['ossuary', 'nave', 'sanctum', 'cloister', 'pyre', 'fen'], bossesBeaten: BOSS_IDS.filter((b) => b !== id && b !== 'prelate') });
      const waiting = bossesWaiting({ ...s, prelateThisRun: id !== 'prelate' });
      expect(waiting).toEqual([id]);
      expect(adviceLines('prior', { ...s, prelateThisRun: id !== 'prelate' }).join(' ')).toContain(BOSSES[id].name);
    }
  });

  it('every area a seal names exists', () => {
    for (const s of Object.values(states)) for (const sg of suggestions(s)) if (sg.place) expect(AREAS[sg.place]).toBeDefined();
  });
});

describe('where the people stand', () => {
  it('each is a clickable interactable in its own hall, inside the walls, and clear of the other stations', () => {
    for (const id of NPC_IDS) {
      const def = NPCS[id];
      const area = AREAS[def.area];
      const it = area.interactables.find((i) => i.id === npcInteractableId(id))!;
      expect(it.kind).toBe('npc');
      expect({ x: it.x, z: it.z }).toEqual({ x: def.x, z: def.z });
      expect(def.x).toBeGreaterThan(area.rect.x0 + 2);
      expect(def.x).toBeLessThan(area.rect.x1 - 2);
      expect(def.z).toBeGreaterThan(area.rect.z0 + 2);
      expect(def.z).toBeLessThan(area.rect.z1 - 2);
      for (const other of area.interactables) if (other.id !== it.id) expect(Math.hypot(other.x - def.x, other.z - def.z), `${id} vs ${other.id}`).toBeGreaterThan(2.4);
      expect(npcFromInteractable(it.id)).toBe(id);
    }
  });
});

describe('looks and help', () => {
  it('every stand-in model is a registered creature whose GLB ships', () => {
    for (const id of NPC_IDS) {
      const look = NPC_LOOKS[id];
      expect(CREATURE_MODELS[look.slug], id).toBeDefined();
      expect(existsSync(`public/${CREATURE_MODELS[look.slug].url}`), look.slug).toBe(true);
      if (look.fallback) {
        expect(CREATURE_MODELS[look.fallback]).toBeDefined();
        expect(existsSync(`public/${CREATURE_MODELS[look.fallback].url}`), look.fallback).toBe(true);
      }
    }
  });

  it('the Codex People rows list everyone with a place and what to ask', () => {
    const rows = codexPeopleRows();
    expect(rows.map((r) => r.id)).toEqual(NPC_IDS);
    for (const r of rows) {
      expect(r.where).toContain(AREAS[NPCS[r.id].area].name);
      expect(r.ask.length).toBeGreaterThan(20);
    }
  });
});
