import { existsSync, readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import manifest from '../../../art-manifest/binbun-effects.json';
import { BINBUN_EFFECTS, BINBUN_WORLD_KITS } from '../../graphics/binbun/catalog';
import { effectTemplate, sampleCurve } from '../../graphics/binbun/godot';
import { bakeTexture } from '../../graphics/binbun/textures';

const file = (id: string) => JSON.parse(readFileSync(`public/fx/binbun/${id}.json`, 'utf8'));

describe('BinbunVFX runtime data', () => {
  it('the catalog covers every converted id exactly once', () => {
    const ids = manifest.effects.map((e: { id: string }) => e.id).sort();
    expect([...BINBUN_EFFECTS, ...BINBUN_WORLD_KITS].sort()).toEqual(ids);
    expect(new Set(BINBUN_EFFECTS).size).toBe(BINBUN_EFFECTS.length);
  });

  it('every spawnable effect resolves to drawable nodes with materials', () => {
    for (const id of BINBUN_EFFECTS) {
      const t = effectTemplate(file(id));
      const drawn = t.nodes.filter((n) => n.type !== 'light');
      expect(drawn.length, id).toBeGreaterThan(0);
      for (const n of drawn) {
        expect(n.matrix.every(Number.isFinite), id).toBe(true);
        if (n.type === 'particles') expect(n.process && n.amount! > 0 && n.lifetime! > 0, `${id} ${n.name}`).toBeTruthy();
      }
      // Every PNG a material points at was shipped.
      for (const n of drawn) for (const ref of Object.values(n.material?.samplers ?? {})) if (ref.kind === 'png') expect(existsSync(`public/${ref.url}`), ref.url).toBe(true);
    }
  });

  it('ports the shared shaders exactly and the rest through the generic program', () => {
    const programs = new Set(BINBUN_EFFECTS.flatMap((id) => effectTemplate(file(id)).nodes.map((n) => n.material?.program)).filter(Boolean));
    expect(programs).toEqual(new Set(['transparent', 'particle', 'glow_fresnel', 'generic']));
  });

  it('samples Godot curves with the Bézier rule', () => {
    const lin = sampleCurve([{ $type: 'Vector2', args: [0, 0] }, 0, 1, 0, 0, { $type: 'Vector2', args: [1, 1] }, 1, 0, 0, 0], 5);
    expect(lin.map((v) => +v.toFixed(3))).toEqual([0, 0.25, 0.5, 0.75, 1]);
  });

  it('bakes procedural noise normalised 0–1 and tileable, and gradients along their fill', () => {
    const n = bakeTexture({ kind: 'noise', key: 'k', size: [512, 512], seed: 3, frequency: 0.01, octaves: 3, gain: 0.5, fractal: 1, invert: false, cellular: false, ramp: null })!;
    const r = Array.from({ length: n.width * n.height }, (_, i) => n.data[i * 4]);
    expect(Math.min(...r)).toBe(0);
    expect(Math.max(...r)).toBe(255);
    // Seam: the last column continues into the first about as smoothly as neighbours do.
    let seam = 0;
    let inner = 0;
    for (let y = 0; y < n.height; y++) {
      seam += Math.abs(n.data[(y * n.width + n.width - 1) * 4] - n.data[y * n.width * 4]);
      inner += Math.abs(n.data[(y * n.width + 1) * 4] - n.data[y * n.width * 4]);
    }
    expect(seam).toBeLessThan(inner * 2 + n.height * 4);
    const g = bakeTexture({ kind: 'gradient', key: 'g', size: [8, 1], stops: [{ t: 0, c: [0, 0, 0, 1] }, { t: 1, c: [1, 1, 1, 1] }], constant: false, fill: 0, from: [0, 0], to: [1, 0], repeat: 0, oneD: true })!;
    expect(g.data[0]).toBeLessThan(g.data[7 * 4]);
  });
});
