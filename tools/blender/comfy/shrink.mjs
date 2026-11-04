// node shrink.mjs <dir>: finish.py's meshopt shrink. In <dir>: job.json {"targets": [triangles per group]}, pos.f32 (the corners, xyz float32)
// and idx-<k>.u32 (group k's triangles). meshoptimizer's simplifyWithUpdate shrinks each group to its target: edge collapse that refuses folds and
// moves the kept corners to where they hold the shape best. Corners two groups share stay put, so no crack opens between them.
// Writes pos.out.f32 (the corners, moved) and idx.out.u32 (every group's kept triangles) and prints a report line of JSON.
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { MeshoptSimplifier as M } from 'meshoptimizer';

const dir = process.argv[2];
const job = JSON.parse(readFileSync(join(dir, 'job.json'), 'utf8'));
const read = (f, T) => new T(new Uint8Array(readFileSync(join(dir, f))).buffer);
const pos = read('pos.f32', Float32Array);
const n = pos.length / 3;
const groups = job.targets.map((_, k) => read(`idx-${k}.u32`, Uint32Array));
const owner = new Int32Array(n).fill(-1), lock = new Uint8Array(n);
groups.forEach((idx, k) => {
  for (const v of idx) {
    if (owner[v] === -1) owner[v] = k;
    else if (owner[v] !== k) lock[v] = 1;
  }
});
await M.ready;
const out = [], rep = [];
groups.forEach((idx, k) => {
  const want = Math.min(job.targets[k], idx.length / 3);
  const [count, error] = M.simplifyWithUpdate(idx, pos, 3, new Float32Array(0), 0, [], lock, want * 3, 1);
  out.push(idx.slice(0, count));
  rep.push({ from: idx.length / 3, to: count / 3, error: +error.toFixed(5) });
});
const all = new Uint32Array(out.reduce((s, a) => s + a.length, 0));
out.reduce((o, a) => (all.set(a, o), o + a.length), 0);
writeFileSync(join(dir, 'pos.out.f32'), Buffer.from(pos.buffer));
writeFileSync(join(dir, 'idx.out.u32'), Buffer.from(all.buffer));
console.log(JSON.stringify({ groups: rep, locked: lock.reduce((s, x) => s + x, 0) }));
