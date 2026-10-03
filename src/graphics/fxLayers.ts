import * as THREE from 'three';

/**
 * Instanced layers for the short-lived billboards and beams of Effects: one draw call per texture (sprites) or one in all
 * (beams), however many are alive. They used to be a Sprite / Mesh plus a SpriteMaterial / MeshBasicMaterial each, so a fight
 * with a few dozen flashes and tethers cost a few dozen draw calls and a few dozen uniform uploads per frame. The look is the
 * same: additive, tinted by the caller's SPELL_FX colour, faded by per-instance opacity, fogged like the scene, drawn after the
 * ground decals (renderOrder 6).
 */

export interface SpriteInstance {
  x: number;
  y: number;
  z: number;
  /** World-unit width (sprites are square), like `Sprite.scale`. */
  size: number;
  /** Radians around the view axis, like `SpriteMaterial.rotation`. */
  rot: number;
  color: THREE.Color;
  opacity: number;
}

export interface BeamInstance {
  /** Mid point. */
  x: number;
  y: number;
  z: number;
  /** End point the beam points its +Z toward (its length axis). */
  tx: number;
  ty: number;
  tz: number;
  width: number;
  length: number;
  color: THREE.Color;
  opacity: number;
}

/** Shared bookkeeping: a growable InstancedMesh with per-instance colour and opacity. */
abstract class InstanceLayer<T extends { color: THREE.Color; opacity: number }> {
  readonly items: T[] = [];
  /** Seconds the layer has had nothing to draw; long-idle layers are freed. */
  idleS = 0;
  mesh!: THREE.InstancedMesh;
  protected opacity!: THREE.InstancedBufferAttribute;

  protected constructor(protected readonly parent: THREE.Group, protected capacity: number) {}

  protected abstract geometry(): THREE.BufferGeometry;
  protected abstract materialOf(): THREE.Material;
  protected abstract order(): number;

  protected make() {
    const geo = this.geometry().clone();
    this.opacity = new THREE.InstancedBufferAttribute(new Float32Array(this.capacity), 1);
    this.opacity.setUsage(THREE.DynamicDrawUsage);
    geo.setAttribute('aOpacity', this.opacity);
    const mesh = new THREE.InstancedMesh(geo, this.materialOf(), this.capacity);
    mesh.instanceMatrix.setUsage(THREE.DynamicDrawUsage);
    mesh.setColorAt(0, new THREE.Color());
    mesh.instanceColor!.setUsage(THREE.DynamicDrawUsage);
    mesh.count = 0;
    mesh.frustumCulled = false;
    mesh.renderOrder = this.order();
    this.parent.add(mesh);
    return mesh;
  }

  add(item: T) {
    this.items.push(item);
    if (this.items.length > this.capacity) {
      this.capacity *= 2;
      this.parent.remove(this.mesh);
      this.mesh.geometry.dispose();
      this.mesh.dispose();
      this.mesh = this.make();
    }
  }

  remove(item: T) {
    const i = this.items.indexOf(item);
    if (i >= 0) this.items.splice(i, 1);
  }

  protected abstract write(item: T, n: number, m: THREE.InstancedMesh): void;

  flush() {
    const mesh = this.mesh;
    let n = 0;
    for (const it of this.items) {
      if (it.opacity <= 0.001) continue;
      this.write(it, n, mesh);
      mesh.setColorAt(n, it.color);
      this.opacity.setX(n, it.opacity);
      n++;
    }
    mesh.count = n;
    mesh.visible = n > 0;
    if (n) {
      mesh.instanceMatrix.needsUpdate = true;
      mesh.instanceColor!.needsUpdate = true;
      this.opacity.needsUpdate = true;
    }
  }

  protected abstract disposeMaterial(): void;

  dispose() {
    this.parent.remove(this.mesh);
    this.mesh.geometry.dispose();
    this.mesh.dispose();
    this.disposeMaterial();
  }
}

const SPRITE_VS = /* glsl */ `
  attribute float aOpacity;
  attribute float aRot;
  varying vec2 vUv;
  varying vec3 vTint;
  varying float vOpacity;
  #include <fog_pars_vertex>
  void main() {
    vUv = uv;
    vTint = instanceColor;
    vOpacity = aOpacity;
    // Same billboard as THREE.Sprite: centre in view space, corner offset rotated about the view axis.
    vec4 mvPosition = modelViewMatrix * instanceMatrix * vec4(0.0, 0.0, 0.0, 1.0);
    float s = length(instanceMatrix[0].xyz);
    vec2 a = position.xy * s;
    float c = cos(aRot);
    float sn = sin(aRot);
    mvPosition.xy += vec2(c * a.x - sn * a.y, sn * a.x + c * a.y);
    gl_Position = projectionMatrix * mvPosition;
    #include <fog_vertex>
  }
`;
const SPRITE_FS = /* glsl */ `
  uniform sampler2D uMap;
  varying vec2 vUv;
  varying vec3 vTint;
  varying float vOpacity;
  #include <fog_pars_fragment>
  void main() {
    vec4 t = texture2D(uMap, vUv);
    gl_FragColor = vec4(vTint * t.rgb, t.a * vOpacity);
    #include <tonemapping_fragment>
    #include <colorspace_fragment>
    #include <fog_fragment>
  }
`;

/** Every live tinted billboard of one texture: one additive InstancedMesh. */
export class SpriteLayer extends InstanceLayer<SpriteInstance> {
  private static readonly geo = new THREE.PlaneGeometry(1, 1);
  private static discGeo: THREE.BufferGeometry | null = null;
  private readonly material: THREE.ShaderMaterial;
  private readonly round: boolean;
  private rot!: THREE.InstancedBufferAttribute;

  /** `round`: the texture is a radial sprite (alpha zero outside its inscribed circle), drawn on a 16-gon instead of a square. */
  constructor(parent: THREE.Group, map: THREE.Texture, capacity = 32, round = false) {
    super(parent, capacity);
    this.round = round;
    this.material = new THREE.ShaderMaterial({
      vertexShader: SPRITE_VS,
      fragmentShader: SPRITE_FS,
      uniforms: THREE.UniformsUtils.merge([THREE.UniformsLib.fog, { uMap: { value: map } }]),
      transparent: true,
      depthWrite: false,
      blending: THREE.AdditiveBlending,
      fog: true,
    });
    this.mesh = this.make();
  }

  protected geometry() {
    if (!this.round) return SpriteLayer.geo;
    return (SpriteLayer.discGeo ??= footprintGeometry('disc', 'xy'));
  }
  protected materialOf() {
    return this.material;
  }
  protected order() {
    return 6;
  }
  protected override make() {
    this.rot = new THREE.InstancedBufferAttribute(new Float32Array(this.capacity), 1);
    this.rot.setUsage(THREE.DynamicDrawUsage);
    const mesh = super.make();
    mesh.geometry.setAttribute('aRot', this.rot);
    return mesh;
  }

  protected write(it: SpriteInstance, n: number, m: THREE.InstancedMesh) {
    const e = m.instanceMatrix.array as Float32Array;
    const o = n * 16;
    e[o] = it.size;
    e[o + 1] = e[o + 2] = e[o + 3] = 0;
    e[o + 4] = 0;
    e[o + 5] = it.size;
    e[o + 6] = e[o + 7] = 0;
    e[o + 8] = e[o + 9] = 0;
    e[o + 10] = it.size;
    e[o + 11] = 0;
    e[o + 12] = it.x;
    e[o + 13] = it.y;
    e[o + 14] = it.z;
    e[o + 15] = 1;
    this.rot.setX(n, it.rot);
  }

  override flush() {
    super.flush();
    if (this.mesh.count) this.rot.needsUpdate = true;
  }

  protected disposeMaterial() {
    this.material.dispose();
  }
}

/** Every live tether: one additive InstancedMesh of 6-sided open tubes. */
export class BeamLayer extends InstanceLayer<BeamInstance> {
  private static readonly geo = new THREE.CylinderGeometry(1, 1, 1, 6, 1, true).rotateX(Math.PI / 2);
  private static readonly m = new THREE.Matrix4();
  private static readonly q = new THREE.Quaternion();
  private static readonly p = new THREE.Vector3();
  private static readonly t = new THREE.Vector3();
  private static readonly s = new THREE.Vector3();
  private static readonly up = new THREE.Vector3(0, 1, 0);
  private readonly material: THREE.MeshBasicMaterial;

  constructor(parent: THREE.Group, capacity = 32) {
    super(parent, capacity);
    this.material = new THREE.MeshBasicMaterial({ transparent: true, depthWrite: false, blending: THREE.AdditiveBlending });
    this.material.onBeforeCompile = (shader) => {
      shader.vertexShader = shader.vertexShader
        .replace('#include <common>', '#include <common>\nattribute float aOpacity;\nvarying float vBeamOpacity;')
        .replace('#include <begin_vertex>', '#include <begin_vertex>\nvBeamOpacity = aOpacity;');
      shader.fragmentShader = shader.fragmentShader
        .replace('#include <common>', '#include <common>\nvarying float vBeamOpacity;')
        .replace('#include <color_fragment>', '#include <color_fragment>\ndiffuseColor.a *= vBeamOpacity;');
    };
    this.material.customProgramCacheKey = () => 'dm-beam-layer';
    this.mesh = this.make();
  }

  protected geometry() {
    return BeamLayer.geo;
  }
  protected materialOf() {
    return this.material;
  }
  protected order() {
    return 6;
  }

  protected write(it: BeamInstance, n: number, m: THREE.InstancedMesh) {
    const { m: mat, q, p, t, s, up } = BeamLayer;
    p.set(it.x, it.y, it.z);
    t.set(it.tx, it.ty, it.tz);
    // Object3D.lookAt for a non-camera: +Z from the mid point toward the far end.
    mat.lookAt(t, p, up);
    q.setFromRotationMatrix(mat);
    mat.compose(p, q, s.set(it.width, it.width, it.length));
    m.setMatrixAt(n, mat);
  }

  protected disposeMaterial() {
    this.material.dispose();
  }
}

/**
 * Footprint meshes for the procedural radial sprites (fx.disc / ring / glow / sigil / cracks): their alpha is exactly zero
 * outside the inscribed circle (and a ring's inside its inner radius), so rasterising the whole square only pays for empty
 * corners. A 16-gon around that circle drops about a fifth of the fill, a ring's annulus drops about three fifths, with the
 * same pixels lit. UVs are position + 0.5 like the plane they replace; the shape lies flat (XZ) or stands (XY) on request.
 */
export function footprintGeometry(kind: 'disc' | 'ring', plane: 'xz' | 'xy', sides = 16): THREE.BufferGeometry {
  // Circumscribe the radius-0.5 circle so the polygon's edges never clip a lit texel.
  const outer = 0.5 / Math.cos(Math.PI / sides);
  // fx.ring()'s gradient starts at 0.36 of the half-width (alpha 0 inside it); stay a little inside that.
  const inner = kind === 'ring' ? 0.348 : 0;
  const pos: number[] = [];
  const uv: number[] = [];
  const idx: number[] = [];
  const put = (x: number, y: number) => {
    if (plane === 'xz') pos.push(x, 0, y);
    else pos.push(x, y, 0);
    // Plane UVs: x to the right, the plane's "up" (y, or -z once laid flat by rotateX(-PI/2)) to the top.
    uv.push(x + 0.5, plane === 'xz' ? 0.5 - y : y + 0.5);
  };
  if (inner === 0) put(0, 0);
  // Half a step round, so a flat edge (not a corner) lies on each axis: the polygon stays inside the square and never
  // samples past the texture's edge (clamping would smear its faint edge texels outward).
  for (let i = 0; i < sides; i++) {
    const a = ((i + 0.5) / sides) * Math.PI * 2;
    put(Math.cos(a) * outer, Math.sin(a) * outer);
  }
  if (inner === 0) {
    for (let i = 0; i < sides; i++) idx.push(0, 1 + i, 1 + ((i + 1) % sides));
  } else {
    for (let i = 0; i < sides; i++) {
      const a = ((i + 0.5) / sides) * Math.PI * 2;
      put(Math.cos(a) * inner, Math.sin(a) * inner);
    }
    for (let i = 0; i < sides; i++) {
      const j = (i + 1) % sides;
      idx.push(i, sides + i, j, j, sides + i, sides + j);
    }
  }
  const g = new THREE.BufferGeometry();
  g.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3));
  g.setAttribute('uv', new THREE.Float32BufferAttribute(uv, 2));
  g.setAttribute('normal', new THREE.Float32BufferAttribute(Array.from({ length: pos.length / 3 }, () => (plane === 'xz' ? [0, 1, 0] : [0, 0, 1])).flat(), 3));
  g.setIndex(idx);
  return g;
}
