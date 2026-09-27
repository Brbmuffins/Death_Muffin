/**
 * DEV-only review grid of every converted Binbun effect (`__cwDebug.vfxGallery()`), so the
 * owner can judge each one in the game's own lighting and bloom. One-shots replay every
 * couple of seconds; loopers run until the gallery closes. Labels are an HTML overlay.
 */
import * as THREE from 'three';
import type { BinbunFX, BinbunHandle } from './BinbunFX';
import { BINBUN_EFFECTS, isBinbunImpact, isBinbunLooper, type BinbunId } from './catalog';

export interface Gallery {
  update(dt: number): void;
  dispose(): void;
  readonly ids: readonly BinbunId[];
}

export function openGallery(fx: BinbunFX, camera: THREE.Camera, host: HTMLElement, center: { x: number; z: number }, page = 0, perPage = 16, colors?: readonly THREE.ColorRepresentation[]): Gallery {
  const ids = BINBUN_EFFECTS.slice(page * perPage, (page + 1) * perPage);
  const cols = Math.ceil(Math.sqrt(ids.length));
  const spacing = 4.2;
  const layer = document.createElement('div');
  layer.style.cssText = 'position:fixed;inset:0;pointer-events:none;z-index:40;font:600 11px/1.2 system-ui,sans-serif;color:#f3e8d2;text-shadow:0 1px 2px #000,0 0 4px #000';
  host.appendChild(layer);
  const cells = ids.map((id, i) => {
    const x = center.x + ((i % cols) - (cols - 1) / 2) * spacing;
    const z = center.z + (Math.floor(i / cols) - (cols - 1) / 2) * spacing;
    const label = document.createElement('div');
    label.textContent = id;
    label.style.cssText = 'position:absolute;transform:translate(-50%,0);white-space:nowrap';
    layer.appendChild(label);
    return { id, x, z, label, handle: null as BinbunHandle | null, timer: 0 };
  });
  const v = new THREE.Vector3();
  const play = (c: (typeof cells)[number]) => {
    c.handle?.kill();
    c.handle = fx.spawn(c.id, { x: c.x, y: 0.05, z: c.z, colors, once: isBinbunImpact(c.id) });
  };
  cells.forEach(play);
  return {
    ids,
    update(dt) {
      for (const c of cells) {
        c.timer += dt;
        if (!isBinbunLooper(c.id) && c.timer > 2.4) {
          c.timer = 0;
          play(c);
        }
        v.set(c.x, 0, c.z + 1.4).project(camera);
        c.label.style.left = `${((v.x + 1) / 2) * window.innerWidth}px`;
        c.label.style.top = `${((1 - v.y) / 2) * window.innerHeight}px`;
        c.label.style.display = v.z > 1 ? 'none' : '';
      }
    },
    dispose() {
      for (const c of cells) c.handle?.kill();
      layer.remove();
    },
  };
}
