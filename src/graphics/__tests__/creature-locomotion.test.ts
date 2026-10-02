import * as THREE from 'three';
import { describe, expect, it, vi } from 'vitest';
import type { ModelTemplate } from '../AssetCache';
import { Creature } from '../Creature';
import { CREATURE_MODELS, type CreatureSlug } from '../modelPaths';
import { creatureTemplate } from './propHarness';

const store = vi.hoisted(() => ({ models: new Map<string, ModelTemplate>() }));
vi.mock('../AssetCache', () => ({ assets: { model: async (url: string) => store.models.get(url) } }));

async function make(slug: CreatureSlug, opts: ConstructorParameters<typeof Creature>[1] = {}) {
  const t = await creatureTemplate(slug, CREATURE_MODELS[slug].height);
  t.skinned = true;
  store.models.set(CREATURE_MODELS[slug].url, t);
  const c = new Creature(slug, opts);
  await vi.waitFor(() => expect(c.loaded).toBe(true));
  return c;
}

const world = (c: Creature, name: string) => c.root.getObjectByName(name)!.getWorldPosition(new THREE.Vector3());

describe('creatures face their heading', () => {
  it.each([
    'grave_robber', 'penitent', 'deacon', 'skeleton_thrall', 'bone_golem', 'barrow_ghoul', 'bell_templar', 'cinder_husk', 'boss_plague_saint', 'slag_brute',
    'thrall_sentinel',
  ] as const)('%s: toes point along +Z at heading 0 with no yaw option', async (slug) => {
    const c = await make(slug);
    c.root.updateMatrixWorld(true);
    const front = new THREE.Vector3();
    for (const side of ['L', 'R']) front.add(world(c, `${side}_ToeBase`).sub(world(c, `${side}_Foot`)));
    front.y = 0;
    front.normalize();
    expect(front.z).toBeGreaterThan(0.9);
  });

  it.each(['bone_hound', 'skull_rat', 'cinderhound'] as const)('%s: head leads the spine along +Z', async (slug) => {
    const c = await make(slug);
    c.root.updateMatrixWorld(true);
    const head = world(c, 'tripoHead_1');
    const spine = world(c, 'tripoSpine_0');
    expect(head.z - spine.z).toBeGreaterThan(0.05);
  });
});

describe('locomotion playback', () => {
  it('runs a hero at the pace of its feet and walks a slow one', async () => {
    const hero = await make('hero_gravecaller', { inPlace: true });
    const fast = hero.setGroundSpeed(5.2);
    expect(fast.clip).toBe('run');
    expect(fast.timeScale).toBeGreaterThan(1);
    expect(fast.timeScale).toBeLessThanOrEqual(2.4);
    hero.update(1 / 60);
    expect(hero.lastPlan?.clip).toBe('run');
    const slow = hero.setGroundSpeed(1.0);
    expect(slow.clip).toBe('walk');
    expect(slow.residual).toBeLessThan(0.05);
  });

  it('keeps a walk-only enemy on its walk clip and speeds it up', async () => {
    const c = await make('penitent');
    expect(c.has('run')).toBe(false);
    const p = c.setGroundSpeed(2);
    expect(p.clip).toBe('walk');
    expect(p.timeScale).toBeGreaterThan(1.3);
  });

  it('a big body strides in bigger steps (world height counts)', async () => {
    const golem = await make('bone_golem');
    const robber = await make('grave_robber');
    expect(golem.setGroundSpeed(2).stride).toBeGreaterThan(robber.setGroundSpeed(2).stride * 1.5);
  });

  it('eases between locomotion states over about a quarter second instead of snapping', async () => {
    const c = await make('hero_gravecaller', { inPlace: true });
    for (let i = 0; i < 30; i++) c.update(1 / 60);
    c.setLoop('run', 1.5);
    const run = (c as unknown as { actions: Map<string, THREE.AnimationAction> }).actions.get('run')!;
    const idle = (c as unknown as { actions: Map<string, THREE.AnimationAction> }).actions.get('idle')!;
    for (let i = 0; i < 6; i++) c.update(1 / 60); // 0.1 s in
    expect(run.getEffectiveWeight()).toBeGreaterThan(0.2);
    expect(run.getEffectiveWeight()).toBeLessThan(0.6);
    expect(idle.getEffectiveWeight()).toBeGreaterThan(0.4);
    for (let i = 0; i < 24; i++) c.update(1 / 60); // 0.5 s in
    expect(run.getEffectiveWeight()).toBeCloseTo(1, 1);
  });

  it('a rig with no idle clip shuffles its walk slowly instead of trotting on the spot', async () => {
    const hound = await make('bone_hound');
    // Every shipped quadruped has an idle clip now (the hound got a procedural one on 2026-10-02), so take it away to test the fallback.
    (hound as unknown as { actions: Map<string, unknown> }).actions.delete('idle');
    hound.setLoop('walk', 2.5);
    hound.update(1 / 60);
    hound.setLoop('idle');
    hound.update(1 / 60);
    const cur = (hound as unknown as { current: THREE.AnimationAction }).current;
    expect(cur.getClip().name).toBe('walk');
    expect(cur.timeScale).toBeLessThan(0.5);
  });
});

describe('additive flinch', () => {
  it('lays a hit-react over a running swing without cutting it', async () => {
    const c = await make('grave_robber');
    const st = c as unknown as { oneShot: THREE.AnimationAction | null; flinchAct: THREE.AnimationAction | null };
    expect(c.playStrike('attack', 0.5)).toBe(true);
    c.update(1 / 60);
    const swing = st.oneShot;
    expect(swing).not.toBeNull();
    expect(c.playOnce('hurt', 1.9)).toBe(true);
    c.update(1 / 60);
    expect(st.oneShot).toBe(swing);
    expect(st.flinchAct?.blendMode).toBe(THREE.AdditiveAnimationBlendMode);
    expect(st.flinchAct?.isRunning()).toBe(true);
    // Eased in: no pop on the first frame, and it lets go by the end.
    expect(st.flinchAct!.getEffectiveWeight()).toBeLessThan(0.5);
    for (let i = 0; i < 12; i++) c.update(1 / 60);
    expect(st.flinchAct!.getEffectiveWeight()).toBeGreaterThan(0.2);
    for (let i = 0; i < 60; i++) c.update(1 / 60);
    expect(st.flinchAct!.isRunning()).toBe(false);
  });

  it('is gentler during a swing than while walking, and never replaces the loop', async () => {
    const c = await make('grave_robber');
    const st = c as unknown as { current: THREE.AnimationAction; flinchStrength: number };
    c.setGroundSpeed(2);
    c.update(1 / 60);
    const walk = st.current;
    c.flinch();
    expect(st.flinchStrength).toBeCloseTo(0.85);
    c.update(1 / 60);
    expect(st.current).toBe(walk);
    c.playStrike('attack', 0.3);
    c.flinch();
    expect(st.flinchStrength).toBeCloseTo(0.425);
  });

  it('is skipped for a rig with no hurt clip and once the body is dying', async () => {
    const hound = await make('bone_hound');
    expect(hound.flinch()).toBe(false);
    const c = await make('grave_robber');
    c.playOnce('death');
    c.update(1 / 60);
    expect(c.flinch()).toBe(true);
    const st = c as unknown as { flinchAct: THREE.AnimationAction };
    c.update(1 / 60);
    expect(st.flinchAct.isRunning()).toBe(false);
  });
});
