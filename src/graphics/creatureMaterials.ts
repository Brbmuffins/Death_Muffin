import * as THREE from 'three';

/**
 * Shared body materials. Every Creature used to clone every material of its template, so a wave of twenty robbers was twenty
 * copies of the same material (twenty uniform refreshes and program lookups per frame, and no state sorting). Bodies that look
 * the same now draw with the same material objects: one set per template + look (tint, emissive, spectral, rim).
 *
 * What differs per body is handled without a material of its own:
 *  - hit flash: a few shared "flashed" copies per look (FLASH_LEVELS emissive steps); the body swaps between them. Same program
 *    as the plain material (only a uniform differs), so a hit never compiles anything.
 *  - fades (corpse sink, shroud): a pooled transparent copy that returns to the pool when the fade ends. Pooled materials are
 *    never disposed, so their transparent program stays compiled for the next fade.
 * Bodies with per-instance shader state (hero gear tint, wing-flap phase) keep their own materials (see Creature).
 * Nothing here is ever disposed: shared materials live for the session, which also keeps their shader programs alive.
 */
export const FLASH_LEVELS = 8;

export type MaterialBuilder = (src: THREE.Material) => THREE.MeshStandardMaterial;

/** The materials of one template in one look. */
export class MaterialVariant {
  private base = new Map<THREE.Material, THREE.MeshStandardMaterial>();
  private flashed = new Map<string, THREE.MeshStandardMaterial>();
  private pool = new Map<THREE.Material, THREE.MeshStandardMaterial[]>();
  /** Emissive of the first material built: the rest-state every flash and fade starts from (as the per-body path did with mats[0]). */
  readonly emissive = new THREE.Color(0);
  intensity = 0;
  private first = true;

  constructor(private build: MaterialBuilder) {}

  get(src: THREE.Material): THREE.MeshStandardMaterial {
    let m = this.base.get(src);
    if (!m) {
      m = this.build(src);
      if (this.first) {
        this.first = false;
        this.emissive.copy(m.emissive);
        this.intensity = m.emissiveIntensity;
      }
      this.base.set(src, m);
    }
    return m;
  }

  /** The plain material pulsed toward the flash colour, `level` of FLASH_LEVELS (1..FLASH_LEVELS). */
  flash(src: THREE.Material, level: number, color: THREE.Color): THREE.MeshStandardMaterial {
    const key = `${level}|${src.uuid}`;
    let m = this.flashed.get(key);
    if (!m) {
      this.get(src);
      m = this.build(src);
      applyFlash(m, this.emissive, this.intensity, level / FLASH_LEVELS, color);
      this.flashed.set(key, m);
    }
    return m;
  }

  /** A transparent copy for one body's fade (taken from the pool when one is free). */
  takeFade(src: THREE.Material): THREE.MeshStandardMaterial {
    const free = this.pool.get(src)?.pop();
    if (free) return free;
    this.get(src);
    return this.build(src);
  }

  giveFade(src: THREE.Material, m: THREE.MeshStandardMaterial) {
    let a = this.pool.get(src);
    if (!a) this.pool.set(src, (a = []));
    a.push(m);
  }
}

/** Emissive pulse toward `color` by `v` (0..1). PBR Tripo materials are largely metallic: the intensity gain stays faint or it whites out. */
export function applyFlash(m: THREE.MeshStandardMaterial, base: THREE.Color, baseIntensity: number, v: number, color: THREE.Color) {
  if (v > 0.01) {
    m.emissive.copy(base).lerp(color, Math.min(1, v));
    m.emissiveIntensity = baseIntensity + v * 0.16;
  } else {
    m.emissive.copy(base);
    m.emissiveIntensity = baseIntensity;
  }
}

const variants = new WeakMap<object, Map<string, MaterialVariant>>();

/** The shared material set for `template` in the look `key`; `build` is only called for a look not seen yet. */
export function variantFor(template: object, key: string, build: MaterialBuilder): MaterialVariant {
  let byKey = variants.get(template);
  if (!byKey) variants.set(template, (byKey = new Map()));
  let v = byKey.get(key);
  if (!v) byKey.set(key, (v = new MaterialVariant(build)));
  return v;
}
