// Golden fixtures for godot/world animation maths (run: npx vite-node tools/godot/fixtures-world.ts)
// planLocomotion (stride-matched walk/run) and strikeTiming (impact-frame matching) straight from the TypeScript.
import { mkdirSync, writeFileSync } from 'node:fs';
import { mulberry32 } from '../../src/gameplay/rng';
import { planLocomotion, STRIDES } from '../../src/graphics/locomotion';
import { strikeTiming } from '../../src/graphics/Creature';

const out = 'godot/tests/world/fixtures';
mkdirSync(out, { recursive: true });
const w = (name: string, v: unknown) => writeFileSync(`${out}/${name}.json`, JSON.stringify(v) + '\n');

const r = mulberry32(2026);
const slugs = Object.keys(STRIDES);
const loco: unknown[] = [];
for (let i = 0; i < 400; i++) {
  const slug = i % 25 === 0 ? 'unmeasured_rig' : slugs[Math.floor(r() * slugs.length)];
  const row = (STRIDES as Record<string, { walk?: number; run?: number }>)[slug];
  const height = 0.5 + r() * 4;
  const ground = r() < 0.1 ? 0.001 : r() * 9;
  const hasRun = r() < 0.7;
  const wasRun = r() < 0.5;
  const p = planLocomotion(row, height, ground, hasRun, wasRun);
  loco.push({ row: row ?? null, height, ground, hasRun, wasRun, clip: p.clip, timeScale: p.timeScale, stride: p.stride, residual: p.residual });
}
w('locomotion', loco);

const strikes: unknown[] = [];
for (let i = 0; i < 200; i++) {
  const duration = 0.5 + r() * 6;
  const impact = r() < 0.2 ? undefined : r() * duration;
  const impactIn = r() * 1.2;
  const follow = r() < 0.5 ? 0.3 : r() * 0.6;
  const t = strikeTiming(duration, impact, impactIn, follow);
  strikes.push({ duration, impact: impact ?? null, impactIn, follow, speed: t.speed, startAt: t.startAt, endAt: t.endAt, impactAfter: t.impactAfter });
}
w('strike_timing', strikes);
console.log(`fixtures-world ok: ${loco.length} locomotion, ${strikes.length} strike cases`);
