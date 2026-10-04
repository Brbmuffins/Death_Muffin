/**
 * World-sim static data export (godot/data/sim/world.json): what WorldScene/WorldView feed the real WorldSim from the generated layout.
 *  - obstacles + sightBlockers: the Nav colliders (ponds, node colliders, interior walls, prop colliders), in registration order.
 *  - crypts, nodes: sim.setCrypts / sim.setNodes input.  cover: the nave pews' boxes (sim.setCover).
 * Run: npx vite-node tools/godot/export-sim.ts   (also run by tools/godot/gen-fixtures.sh)
 */
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { generateLayout, PROPS, wallObstacle, placementObstacle, NODE_COLLIDER } from '../../src/content/layout';
import { NODES } from '../../src/gameplay/gatheringRules';
import { exactStringify } from './exact-json';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const OUT = resolve(ROOT, 'godot/data/sim');
mkdirSync(OUT, { recursive: true });

const layout = generateLayout();
const obstacles: unknown[] = [];
const sight: unknown[] = [];
for (const p of layout.ponds) obstacles.push({ kind: 'box', x0: p.x0, z0: p.z0, x1: p.x1, z1: p.z1 });
for (const n of layout.nodes) {
  const r = NODE_COLLIDER[NODES[n.type].kind];
  if (r) obstacles.push({ kind: 'circle', x: n.x, z: n.z, r });
}
for (const w of layout.walls) {
  const box = wallObstacle(w);
  obstacles.push(box);
  if (w.height >= 2.5) sight.push(box);
}
for (const p of layout.props) {
  const o = placementObstacle(p);
  if (o) obstacles.push(o);
}
const cover = layout.props
  .filter((p) => p.prop === 'church_pew' && p.area === 'nave')
  .map((p) => {
    const c = PROPS.church_pew.collider as { hw: number; hd: number };
    const cos = Math.abs(Math.cos(p.rot));
    const sin = Math.abs(Math.sin(p.rot));
    const hw = (c.hw * cos + c.hd * sin) * p.scale;
    const hd = (c.hw * sin + c.hd * cos) * p.scale;
    return { x0: p.x - hw, z0: p.z - hd, x1: p.x + hw, z1: p.z + hd };
  });
const out = { obstacles, sightBlockers: sight, crypts: layout.crypts.map(({ area, x, z }) => ({ area, x, z })), nodes: layout.nodes.map(({ id, type, area, x, z, rich }) => ({ id, type, area, x, z, rich: !!rich })), cover };
writeFileSync(resolve(OUT, 'world.json'), exactStringify(out) + '\n');
console.log('sim world data:', obstacles.length, 'obstacles,', sight.length, 'sight blockers,', out.crypts.length, 'crypts,', out.nodes.length, 'nodes,', cover.length, 'cover boxes');
