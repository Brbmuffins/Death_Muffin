import { describe, expect, it } from 'vitest';
import { AREAS } from '../../content/areas';
import { BOSSES } from '../../content/bosses';
import { NPCS, NPC_IDS } from '../../content/npcs';
import { ITEMS } from '../../content/items';
import { adviceLines, greetingLines, TOPICS, topicLines } from '../../content/dialogue';
import { baseState, nextSuggestion, suggestions } from '../../gameplay/guidance';
import { TIPS, renderText } from '../Onboarding';
import { HERE, kindOf } from '../counselCadence';

const plain = (s: string) => s.replace(/<[^>]+>/g, '');
const sentences = (s: string) => plain(s).split(/(?<=[.!?])\s+/);

/** Every player-facing line about brewing, from every source that gives directions. */
function brewingLines(): { where: string; line: string }[] {
  const out: { where: string; line: string }[] = [];
  const add = (where: string, text: string) => sentences(text).forEach((line) => out.push({ where, line }));
  for (const [id, t] of Object.entries(TIPS)) add(`tip ${id}`, renderText(t.body));
  for (const id of NPC_IDS) add(`npc ${id}`, NPCS[id].blurb);
  const s = baseState({ dust: 6, level: 5, totalKills: 40 });
  for (const sg of suggestions(s)) add(`suggestion ${sg.kind}`, sg.text);
  for (const id of NPC_IDS) {
    adviceLines(id, s).forEach((l) => add(`advice ${id}`, l));
    greetingLines(id, s, [], false).forEach((l) => add(`greeting ${id}`, l));
    for (const t of TOPICS[id]) topicLines(id, t.id, s).forEach((l) => add(`topic ${id}/${t.id}`, l));
  }
  add('item grave dust', ITEMS.reagent_grave_dust?.lore ?? '');
  return out;
}

describe('first-hour wording', () => {
  it('no direction sends a player to the Workbench to brew (brewing lives in the Alchemist\'s Wing)', () => {
    const bad = brewingLines().filter(({ line }) => /workbench/i.test(line) && /(brew|alchemy|tonic|elixir)/i.test(line));
    expect(bad).toEqual([]);
  });

  it('the Vault is described the same way everywhere: Chapterhouse or Acre', () => {
    const vault = brewingLines().filter(({ line }) => /vault/i.test(line) && /chapterhouse/i.test(line) && !/acre/i.test(line) && !/shared|account|every character/i.test(line));
    expect(vault).toEqual([]);
  });

  it('a new player in the Acre is told to walk east to the Chapterhouse first, not "north" into the Graves from there', () => {
    const fromAcre = nextSuggestion(baseState({ area: 'acre' }));
    expect(fromAcre?.kind).toBe('first-steps');
    expect(fromAcre?.text).toMatch(/east to the Chapterhouse/);
    const fromHall = nextSuggestion(baseState({ area: 'chapterhouse' }));
    expect(fromHall?.text).toMatch(/north into the Hollow Graves/);
  });

  it('the opening card does not repeat the Next line\'s directions', () => {
    const body = plain(TIPS.welcome.body);
    expect(body).not.toMatch(/Hollow Graves/);
    expect(body).toMatch(/Next/);
  });
});

describe('counsel cadence tables', () => {
  it('place tips name real places', () => {
    for (const [tip, areas] of Object.entries(HERE)) {
      expect(TIPS, tip).toHaveProperty(tip);
      for (const a of areas) expect(AREAS, `${tip} -> ${a}`).toHaveProperty(a);
    }
    for (const id of ['gravedigger', 'abbess', 'congregation', 'saint', 'regent', 'mire'] as const) {
      expect(HERE[`boss_${id}`], id).toEqual([BOSSES[id].area]);
    }
  });

  it('only hurt jumps the queue, and the fight-time kinds are the enemy and corpse lessons', () => {
    const urgent = Object.keys(TIPS).filter((id) => kindOf(id) === 'urgent');
    expect(urgent).toEqual(['hurt']);
    for (const id of ['wraith', 'moth', 'gargoyle', 'exhume', 'move']) expect(kindOf(id), id).toBe('danger');
    for (const id of ['welcome', 'acre', 'people', 'omen', 'wave', 'codex']) expect(kindOf(id), id).toBe('calm');
  });
});
