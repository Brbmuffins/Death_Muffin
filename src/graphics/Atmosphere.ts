import * as THREE from 'three';
import { settings } from '../app/settings';
import type { AreaId } from '../content/areas';
import { mulberry32 } from '../gameplay/rng';

/**
 * Per-area weather around the camera focus: ash and leaves over the Hollow
 * Graves, bone-dust motes in the Ossuary, drips and faint rain in the Drowned
 * Nave, rising embers in the Bell Sanctum. One Points draw call; every particle
 * moves on the GPU from a seed + time and wraps around the focus, so the CPU
 * only touches attributes when the area changes.
 */

type Shape = 0 | 1 | 2 | 3; // dot, flake, leaf, streak (atlas cells)

interface Kind {
  count: number;
  shape: Shape;
  colors: number[];
  size: [number, number];
  alpha: [number, number];
  /** Vertical speed range (negative falls). */
  vy: [number, number];
  /** Horizontal drift (x, z) and sway amplitude. */
  drift: [number, number];
  sway: number;
  /** 0 = normal blend, 1 = additive (glowing). */
  add: number;
}

const PROFILES: Record<AreaId, Kind[]> = {
  chapterhouse: [
    { count: 70, shape: 0, colors: [0xd8c8a8, 0xbfae92], size: [0.05, 0.1], alpha: [0.25, 0.5], vy: [-0.05, 0.08], drift: [0.08, 0.05], sway: 0.25, add: 0.6 },
  ],
  // Overcast dusk: falling leaves, drifting seed-fluff, and far-off crows wheeling high.
  acre: [
    { count: 70, shape: 2, colors: [0x7a5a2a, 0x8d6b30, 0x5f4a26, 0x6e7a3a], size: [0.26, 0.4], alpha: [0.7, 0.9], vy: [-0.7, -0.35], drift: [0.5, 0.25], sway: 1.2, add: 0 },
    { count: 90, shape: 0, colors: [0xd8d4c4, 0xbfc4b0], size: [0.04, 0.08], alpha: [0.25, 0.5], vy: [-0.08, 0.12], drift: [0.2, 0.1], sway: 0.4, add: 0.3 },
    { count: 14, shape: 1, colors: [0x14121a, 0x1c1a22], size: [0.35, 0.5], alpha: [0.75, 0.9], vy: [-0.02, 0.02], drift: [1.6, 0.9], sway: 2.4, add: 0 },
  ],
  graves: [
    { count: 240, shape: 1, colors: [0x8d8794, 0x6f6a78, 0xa29aa6], size: [0.08, 0.16], alpha: [0.35, 0.6], vy: [-0.55, -0.25], drift: [0.35, 0.12], sway: 0.5, add: 0 },
    { count: 46, shape: 2, colors: [0x5a3e24, 0x6d4a26, 0x3f2f22], size: [0.28, 0.42], alpha: [0.7, 0.9], vy: [-0.9, -0.5], drift: [0.6, 0.2], sway: 1.1, add: 0 },
  ],
  ossuary: [
    { count: 280, shape: 0, colors: [0xe8dcc0, 0xcbb994, 0xf2e8d2], size: [0.05, 0.12], alpha: [0.3, 0.65], vy: [-0.06, 0.1], drift: [0.1, 0.06], sway: 0.35, add: 0.5 },
  ],
  nave: [
    { count: 150, shape: 3, colors: [0x8f95c8, 0xa8a4d8], size: [0.35, 0.6], alpha: [0.1, 0.2], vy: [-11, -8], drift: [0.4, 0.1], sway: 0, add: 0.8 },
    { count: 90, shape: 0, colors: [0xbcc4f0, 0xd8dcff], size: [0.05, 0.08], alpha: [0.45, 0.8], vy: [-6, -4], drift: [0, 0], sway: 0, add: 0.9 },
    { count: 60, shape: 0, colors: [0x5a5890, 0x6c68a6], size: [0.1, 0.18], alpha: [0.15, 0.3], vy: [-0.04, 0.05], drift: [0.05, 0.05], sway: 0.3, add: 0 },
  ],
  cloister: [
    // Drifting plague spores and flies over the moss.
    { count: 220, shape: 0, colors: [0x9cc43a, 0x7fa02a, 0xc8e060], size: [0.05, 0.11], alpha: [0.35, 0.75], vy: [-0.08, 0.14], drift: [0.14, 0.08], sway: 0.5, add: 0.7 },
    { count: 60, shape: 0, colors: [0x1a1a10, 0x2a2818], size: [0.04, 0.07], alpha: [0.6, 0.9], vy: [-0.3, 0.3], drift: [0.6, 0.4], sway: 1.2, add: 0 },
  ],
  sanctum: [
    { count: 200, shape: 0, colors: [0xa66bff, 0x8a4fe0, 0xd2a8ff], size: [0.07, 0.15], alpha: [0.5, 0.9], vy: [0.5, 1.3], drift: [0.1, 0.1], sway: 0.6, add: 1 },
    { count: 50, shape: 1, colors: [0x55486a, 0x3f3552], size: [0.1, 0.18], alpha: [0.3, 0.5], vy: [-0.4, -0.2], drift: [0.15, 0.1], sway: 0.4, add: 0 },
  ],
};

/** Upper bound across profiles (the attribute buffers are sized once). */
export const ATMOSPHERE_MAX = Math.max(...Object.values(PROFILES).map((ks) => ks.reduce((s, k) => s + k.count, 0)));

const BOX = { x: 28, y: 9, z: 24 };

const VS = /* glsl */ `
  uniform float uTime;
  uniform float uScale;
  uniform float uFade;
  uniform vec3 uFocus;
  uniform vec3 uBox;
  attribute vec4 aSeed;   // x0, y0, z0, phase
  attribute vec4 aMotion; // vx, vy, vz, sway
  attribute vec4 aLook;   // size, shape, alpha, additive
  attribute vec3 aColor;
  varying vec4 vLook;
  varying vec3 vColor;
  varying float vA;
  varying float vRot;
  void main() {
    float t = uTime;
    vec3 p = aSeed.xyz + aMotion.xyz * t;
    p.x += sin(t * 0.9 + aSeed.w * 6.2831) * aMotion.w;
    p.z += cos(t * 0.7 + aSeed.w * 4.1) * aMotion.w * 0.6;
    vec3 rel = vec3(
      mod(p.x - uFocus.x + uBox.x, 2.0 * uBox.x) - uBox.x,
      mod(p.y, uBox.y),
      mod(p.z - uFocus.z + uBox.z, 2.0 * uBox.z) - uBox.z
    );
    vec3 wp = vec3(uFocus.x + rel.x, rel.y, uFocus.z + rel.z);
    float fy = smoothstep(0.0, 0.6, rel.y) * smoothstep(uBox.y, uBox.y - 1.5, rel.y);
    float fxz = smoothstep(uBox.x, uBox.x - 4.0, abs(rel.x)) * smoothstep(uBox.z, uBox.z - 4.0, abs(rel.z));
    float tw = 0.75 + 0.25 * sin(t * 2.7 + aSeed.w * 21.0);
    vA = aLook.z * fy * fxz * tw * uFade;
    vec4 mv = modelViewMatrix * vec4(wp, 1.0);
    gl_Position = projectionMatrix * mv;
    gl_PointSize = aLook.x * uScale / max(0.1, -mv.z);
    vLook = aLook;
    vColor = aColor;
    vRot = aSeed.w * 6.2831 + t * (0.6 + aMotion.w * 1.8);
  }
`;
const FS = /* glsl */ `
  uniform sampler2D uAtlas;
  varying vec4 vLook;
  varying vec3 vColor;
  varying float vA;
  varying float vRot;
  void main() {
    vec2 uv = gl_PointCoord - 0.5;
    // Flakes and leaves tumble; dots and streaks don't.
    if (vLook.y > 0.5 && vLook.y < 2.5) {
      float c = cos(vRot), s = sin(vRot);
      uv = mat2(c, -s, s, c) * uv;
    }
    uv += 0.5;
    if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) discard;
    vec2 cell = vec2(mod(vLook.y, 2.0), floor(vLook.y / 2.0));
    vec4 tx = texture2D(uAtlas, (uv + cell) * 0.5);
    float a = tx.a * vA;
    if (a < 0.003) discard;
    // Premultiplied: additive particles write no alpha, normal ones occlude.
    gl_FragColor = vec4(vColor * tx.rgb * a, a * (1.0 - vLook.w));
  }
`;

let atlas: THREE.Texture | null = null;
function atlasTexture() {
  if (atlas) return atlas;
  const S = 64;
  const canvas = document.createElement('canvas');
  canvas.width = canvas.height = S * 2;
  const c = canvas.getContext('2d')!;
  const cell = (i: number, draw: () => void) => {
    c.save();
    c.translate((i % 2) * S, Math.floor(i / 2) * S);
    c.beginPath();
    c.rect(0, 0, S, S);
    c.clip();
    draw();
    c.restore();
  };
  // 0: soft dot
  cell(0, () => {
    const g = c.createRadialGradient(S / 2, S / 2, 0, S / 2, S / 2, S / 2);
    g.addColorStop(0, 'rgba(255,255,255,1)');
    g.addColorStop(0.35, 'rgba(255,255,255,0.6)');
    g.addColorStop(1, 'rgba(255,255,255,0)');
    c.fillStyle = g;
    c.fillRect(0, 0, S, S);
  });
  // 1: ash flake — an irregular grey shard
  cell(1, () => {
    c.fillStyle = 'rgba(255,255,255,0.9)';
    c.beginPath();
    const pts = [[0.5, 0.18], [0.74, 0.34], [0.8, 0.6], [0.56, 0.8], [0.3, 0.7], [0.22, 0.42]];
    pts.forEach(([x, y], i) => (i ? c.lineTo(x * S, y * S) : c.moveTo(x * S, y * S)));
    c.closePath();
    c.fill();
  });
  // 2: leaf with a midrib
  cell(2, () => {
    c.fillStyle = 'rgba(255,255,255,1)';
    c.beginPath();
    c.moveTo(S * 0.5, S * 0.08);
    c.quadraticCurveTo(S * 0.92, S * 0.45, S * 0.5, S * 0.92);
    c.quadraticCurveTo(S * 0.08, S * 0.45, S * 0.5, S * 0.08);
    c.fill();
    c.strokeStyle = 'rgba(120,120,120,0.9)';
    c.lineWidth = 2;
    c.beginPath();
    c.moveTo(S * 0.5, S * 0.12);
    c.lineTo(S * 0.5, S * 0.88);
    c.stroke();
  });
  // 3: rain streak — thin vertical line
  cell(3, () => {
    const g = c.createLinearGradient(0, 0, 0, S);
    g.addColorStop(0, 'rgba(255,255,255,0)');
    g.addColorStop(0.7, 'rgba(255,255,255,0.9)');
    g.addColorStop(1, 'rgba(255,255,255,0)');
    c.fillStyle = g;
    c.fillRect(S / 2 - 1.2, 0, 2.4, S);
  });
  atlas = new THREE.CanvasTexture(canvas);
  atlas.colorSpace = THREE.SRGBColorSpace;
  // gl_PointCoord's origin is top-left, like the canvas.
  atlas.flipY = false;
  return atlas;
}

export class Atmosphere {
  readonly points: THREE.Points;
  private area: AreaId | null = null;
  private fade = 0;
  private time = 0;
  private seed: THREE.BufferAttribute;
  private motion: THREE.BufferAttribute;
  private look: THREE.BufferAttribute;
  private color: THREE.BufferAttribute;
  private uniforms = {
    uTime: { value: 0 },
    uScale: { value: 400 },
    uFade: { value: 0 },
    uFocus: { value: new THREE.Vector3() },
    uBox: { value: new THREE.Vector3(BOX.x, BOX.y, BOX.z) },
    uAtlas: { value: null as THREE.Texture | null },
  };
  private pending: AreaId | null = null;

  constructor() {
    const n = ATMOSPHERE_MAX;
    const geo = new THREE.BufferGeometry();
    // Positions are unused by the shader but three needs the attribute for draw counts.
    geo.setAttribute('position', new THREE.BufferAttribute(new Float32Array(n * 3), 3));
    this.seed = new THREE.BufferAttribute(new Float32Array(n * 4), 4);
    this.motion = new THREE.BufferAttribute(new Float32Array(n * 4), 4);
    this.look = new THREE.BufferAttribute(new Float32Array(n * 4), 4);
    this.color = new THREE.BufferAttribute(new Float32Array(n * 3), 3);
    geo.setAttribute('aSeed', this.seed);
    geo.setAttribute('aMotion', this.motion);
    geo.setAttribute('aLook', this.look);
    geo.setAttribute('aColor', this.color);
    geo.setDrawRange(0, 0);
    this.uniforms.uAtlas.value = atlasTexture();
    this.points = new THREE.Points(
      geo,
      new THREE.ShaderMaterial({
        vertexShader: VS,
        fragmentShader: FS,
        uniforms: this.uniforms,
        transparent: true,
        depthWrite: false,
        blending: THREE.CustomBlending,
        blendSrc: THREE.OneFactor,
        blendDst: THREE.OneMinusSrcAlphaFactor,
      }),
    );
    this.points.frustumCulled = false;
    this.points.renderOrder = 5;
  }

  private fill(area: AreaId) {
    const rand = mulberry32(area.length * 977 + area.charCodeAt(0));
    const tmp = new THREE.Color();
    const lowQ = settings.quality === 'low';
    let i = 0;
    for (const k of PROFILES[area]) {
      const count = lowQ ? Math.ceil(k.count / 2) : k.count;
      for (let n = 0; n < count; n++, i++) {
        const lerp = (r: [number, number]) => r[0] + rand() * (r[1] - r[0]);
        this.seed.setXYZW(i, rand() * BOX.x * 2, rand() * BOX.y, rand() * BOX.z * 2, rand());
        this.motion.setXYZW(i, (rand() - 0.3) * k.drift[0], lerp(k.vy), (rand() - 0.5) * k.drift[1], k.sway * (0.5 + rand() * 0.5));
        this.look.setXYZW(i, lerp(k.size), k.shape, lerp(k.alpha), k.add);
        tmp.set(k.colors[Math.floor(rand() * k.colors.length)]);
        this.color.setXYZ(i, tmp.r, tmp.g, tmp.b);
      }
    }
    for (const a of [this.seed, this.motion, this.look, this.color]) a.needsUpdate = true;
    this.points.geometry.setDrawRange(0, i);
  }

  /** Cross-fades to the weather of the area the focus stands in (null = corridor: keep). */
  update(dt: number, area: AreaId | null, focusX: number, focusZ: number, scale: number) {
    this.time += dt;
    if (area && area !== this.area && area !== this.pending) this.pending = area;
    if (this.pending) {
      this.fade = Math.max(0, this.fade - dt * 1.6);
      if (this.fade === 0 || this.area === null) {
        this.fill(this.pending);
        this.area = this.pending;
        this.pending = null;
      }
    } else this.fade = Math.min(1, this.fade + dt * 0.8);
    const reduced = settings.reducedMotion ? 0.6 : 1;
    this.uniforms.uTime.value = this.time * reduced;
    this.uniforms.uFade.value = this.fade;
    this.uniforms.uScale.value = scale;
    this.uniforms.uFocus.value.set(focusX, 0, focusZ);
  }

  dispose() {
    this.points.geometry.dispose();
    (this.points.material as THREE.Material).dispose();
    this.points.removeFromParent();
  }
}
