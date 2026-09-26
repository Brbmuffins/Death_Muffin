import * as THREE from 'three';
import { mergeGeometries } from 'three/examples/jsm/utils/BufferGeometryUtils.js';
import { settings, onSettingsChange, type Quality } from '../app/settings';
import type { Puddle, Rect } from '../content/layout';

/**
 * Standing water: the flooded Drowned Nave and the graveyard's rain puddles,
 * merged into one mesh (one draw call). Every vertex carries `aEdge`, its
 * distance to the shore, so the shader can fade the rim, deepen the middle and
 * never needs a per-pixel rect test. High quality perturbs a standard material
 * with two scrolling procedural normal maps, fresnel, a moon glint and up to
 * 16 ripple rings; low quality is a flat glossy sheet.
 */

const RIPPLES = 16;
const RIPPLE_LIFE = 2.2;
/** How far in from the shore the water reaches full depth (world units). */
const DEPTH_INSET = 3.2;
const Y = 0.06;
/** Open-sky puddles mirror the moon (1); the roofed nave only faintly (this). */
const NAVE_SHEEN = 0.25;

/** Tileable ripple normals drawn once on a canvas (no asset files). */
let normalTex: THREE.Texture | null = null;
function waterNormals(): THREE.Texture {
  if (normalTex) return normalTex;
  const size = 256;
  const canvas = document.createElement('canvas');
  canvas.width = canvas.height = size;
  const ctx = canvas.getContext('2d')!;
  const img = ctx.createImageData(size, size);
  // Integer frequencies keep the height field seamless across the tile.
  const waves: [number, number, number, number][] = [
    [1, 2, 0.9, 0.3],
    [3, -1, 0.6, 1.7],
    [-2, 3, 0.45, 4.1],
    [5, 2, 0.28, 2.2],
    [-4, -5, 0.2, 5.3],
    [7, -3, 0.14, 0.8],
    [2, 9, 0.1, 3.6],
  ];
  const TAU = Math.PI * 2;
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const u = x / size;
      const v = y / size;
      let dx = 0;
      let dy = 0;
      for (const [a, b, amp, ph] of waves) {
        const c = Math.cos(TAU * (a * u + b * v) + ph) * amp * TAU;
        dx += c * a;
        dy += c * b;
      }
      const s = 0.045;
      const n = new THREE.Vector3(-dx * s, -dy * s, 1).normalize();
      const i = (y * size + x) * 4;
      img.data[i] = (n.x * 0.5 + 0.5) * 255;
      img.data[i + 1] = (n.y * 0.5 + 0.5) * 255;
      img.data[i + 2] = (n.z * 0.5 + 0.5) * 255;
      img.data[i + 3] = 255;
    }
  }
  ctx.putImageData(img, 0, 0);
  normalTex = new THREE.CanvasTexture(canvas);
  normalTex.wrapS = normalTex.wrapT = THREE.RepeatWrapping;
  normalTex.colorSpace = THREE.NoColorSpace;
  return normalTex;
}

/** A rect as a frame: outer ring at the shore (edge 0), inner ring inset to full depth. */
function rectGeometry(r: Rect): THREE.BufferGeometry {
  const inset = Math.min(DEPTH_INSET, (r.x1 - r.x0) / 2 - 0.01, (r.z1 - r.z0) / 2 - 0.01);
  const o = [
    [r.x0, r.z0],
    [r.x1, r.z0],
    [r.x1, r.z1],
    [r.x0, r.z1],
  ];
  const i = [
    [r.x0 + inset, r.z0 + inset],
    [r.x1 - inset, r.z0 + inset],
    [r.x1 - inset, r.z1 - inset],
    [r.x0 + inset, r.z1 - inset],
  ];
  const pos: number[] = [];
  const edge: number[] = [];
  for (const [x, z] of o) pos.push(x, Y, z), edge.push(0);
  for (const [x, z] of i) pos.push(x, Y, z), edge.push(inset);
  const sheen = new Array(8).fill(NAVE_SHEEN);
  // Four trapezoids (outer k,k+1 → inner k+1,k) and the inner quad (drawn double-sided).
  const idx: number[] = [];
  for (let k = 0; k < 4; k++) {
    const n = (k + 1) % 4;
    idx.push(k, 4 + k, n, n, 4 + k, 4 + n);
  }
  idx.push(4, 7, 5, 5, 7, 6);
  return build(pos, edge, sheen, idx);
}

/** An ellipse as a triangle fan: centre at full depth for its size, rim at 0. */
function puddleGeometry(p: Puddle): THREE.BufferGeometry {
  const seg = 18;
  const pos: number[] = [p.x, Y - 0.02, p.z];
  const edge: number[] = [p.r];
  const c = Math.cos(p.rot);
  const s = Math.sin(p.rot);
  for (let k = 0; k < seg; k++) {
    const a = (k / seg) * Math.PI * 2;
    // A little wobble so puddles aren't perfect ellipses.
    const wob = 1 + 0.12 * Math.sin(a * 3 + p.x) + 0.07 * Math.sin(a * 5 + p.z);
    const lx = Math.cos(a) * p.r * p.sx * wob;
    const lz = Math.sin(a) * p.r * wob;
    pos.push(p.x + lx * c - lz * s, Y - 0.02, p.z + lx * s + lz * c);
    edge.push(0);
  }
  const idx: number[] = [];
  for (let k = 0; k < seg; k++) idx.push(0, 1 + ((k + 1) % seg), 1 + k);
  return build(pos, edge, new Array(seg + 1).fill(1), idx);
}

function build(pos: number[], edge: number[], sheen: number[], idx: number[]) {
  const g = new THREE.BufferGeometry();
  g.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3));
  g.setAttribute('aEdge', new THREE.Float32BufferAttribute(edge, 1));
  g.setAttribute('aSheen', new THREE.Float32BufferAttribute(sheen, 1));
  const up = new Float32Array(pos.length);
  for (let i = 1; i < up.length; i += 3) up[i] = 1;
  g.setAttribute('normal', new THREE.BufferAttribute(up, 3));
  g.setIndex(idx);
  return g;
}

const VERT_HEAD = /* glsl */ `
  attribute float aEdge;
  attribute float aSheen;
  varying float vEdge;
  varying float vSheen;
  varying vec3 vWPos;
`;
const VERT_BODY = /* glsl */ `
  vEdge = aEdge;
  vSheen = aSheen;
  vWPos = (modelMatrix * vec4(transformed, 1.0)).xyz;
`;
const FRAG_HEAD = /* glsl */ `
  uniform float uTime;
  uniform sampler2D uNormals;
  uniform vec4 uRipples[${RIPPLES}];
  uniform vec3 uDeep;
  uniform vec3 uRim;
  uniform vec3 uMoon;
  varying float vEdge;
  varying float vSheen;
  varying vec3 vWPos;
`;
// Replaces normal_fragment_maps: world-space ripple normals → view space.
const FRAG_NORMAL = /* glsl */ `
  vec2 wp = vWPos.xz;
  vec3 na = texture2D(uNormals, wp * 0.085 + vec2(uTime * 0.012, uTime * 0.006)).xyz * 2.0 - 1.0;
  vec3 nb = texture2D(uNormals, vec2(wp.y, -wp.x) * 0.21 + vec2(-uTime * 0.019, uTime * 0.015)).xyz * 2.0 - 1.0;
  vec2 slope = na.xy * 0.08 + nb.xy * 0.12;
  // A fine third octave only steers the moon glint into sparkles.
  vec2 fine = (texture2D(uNormals, wp * 0.63 + vec2(uTime * 0.05, -uTime * 0.035)).xy * 2.0 - 1.0) * 0.15;
  float rippleLight = 0.0;
  for (int i = 0; i < ${RIPPLES}; i++) {
    vec4 rp = uRipples[i];
    float age = uTime - rp.z;
    if (rp.w <= 0.0 || age < 0.0 || age > ${RIPPLE_LIFE.toFixed(1)}) continue;
    vec2 d = wp - rp.xy;
    float dist = length(d);
    float x = dist - age * 1.5;
    float env = exp(-x * x * 5.0) * (1.0 - age / ${RIPPLE_LIFE.toFixed(1)}) * rp.w;
    float w = cos(x * 13.0) * env;
    slope += (d / max(dist, 0.001)) * w * 0.32;
    rippleLight += env * max(0.0, w);
  }
  vec3 wn = normalize(vec3(-slope.x, 1.0, -slope.y));
  normal = normalize((viewMatrix * vec4(wn, 0.0)).xyz);
`;
// Before opaque_fragment: depth tint, fresnel rim, moon glint, shore fade.
const FRAG_COLOR = /* glsl */ `
  {
    vec3 V = normalize(cameraPosition - vWPos);
    float fres = pow(1.0 - clamp(dot(V, wn), 0.0, 1.0), 3.0);
    float depth = smoothstep(0.15, ${DEPTH_INSET.toFixed(1)}, vEdge);
    // A virtual low moon up-screen, so the glint reaches this camera angle.
    vec3 R = reflect(-V, normalize(wn + vec3(-fine.x, 0.0, -fine.y)));
    // Clustered by a slow large-scale swell so the glints drift in patches, not glitter.
    float patchy = smoothstep(0.1, 0.7, texture2D(uNormals, wp * 0.021 + uTime * 0.004).x);
    float glint = pow(max(dot(R, normalize(vec3(0.12, 0.42, -0.9))), 0.0), 220.0) * patchy;
    outgoingLight = mix(outgoingLight, uDeep, depth * 0.6);
    outgoingLight += uRim * (fres * 0.6 + rippleLight * 0.3) + uMoon * glint * 0.6;
    // A still mirror of the moonlit sky, broken up by the swell.
    outgoingLight += uMoon * vSheen * (0.025 + 0.05 * patchy + 0.2 * fres);
    diffuseColor.a = smoothstep(0.0, 0.45, vEdge) * mix(0.5, 0.86, depth);
  }
`;

export class Water {
  readonly mesh: THREE.Mesh;
  private high: THREE.MeshStandardMaterial;
  private low: THREE.MeshStandardMaterial;
  private uniforms = {
    uTime: { value: 0 },
    uNormals: { value: null as THREE.Texture | null },
    uRipples: { value: Array.from({ length: RIPPLES }, () => new THREE.Vector4(0, 0, -99, 0)) },
    uDeep: { value: new THREE.Color(0x04040b) },
    uRim: { value: new THREE.Color(0x2c3a7a) },
    uMoon: { value: new THREE.Color(0x8f86d8) },
  };
  private next = 0;
  private time = 0;
  private offSettings: () => void;

  constructor(
    private rects: Rect[],
    private puddles: Puddle[],
  ) {
    const parts = [...rects.map(rectGeometry), ...puddles.map(puddleGeometry)];
    const geo = parts.length ? mergeGeometries(parts, false)! : new THREE.BufferGeometry();
    for (const p of parts) p.dispose();
    geo.computeBoundingSphere();

    this.uniforms.uNormals.value = waterNormals();
    this.high = new THREE.MeshStandardMaterial({ color: 0x15142a, roughness: 0.16, metalness: 0.1, transparent: true, depthWrite: false, side: THREE.DoubleSide });
    this.high.onBeforeCompile = (shader) => {
      Object.assign(shader.uniforms, this.uniforms);
      shader.vertexShader = VERT_HEAD + shader.vertexShader.replace('#include <begin_vertex>', `#include <begin_vertex>\n${VERT_BODY}`);
      shader.fragmentShader =
        FRAG_HEAD +
        shader.fragmentShader
          .replace('#include <normal_fragment_maps>', FRAG_NORMAL)
          .replace('#include <opaque_fragment>', `${FRAG_COLOR}\n#include <opaque_fragment>`);
    };
    this.high.customProgramCacheKey = () => 'cw-water';
    this.low = new THREE.MeshStandardMaterial({ color: 0x131228, roughness: 0.2, metalness: 0.1, transparent: true, opacity: 0.72, depthWrite: false, side: THREE.DoubleSide });

    this.mesh = new THREE.Mesh(geo, this.materialFor(settings.quality));
    this.mesh.receiveShadow = true;
    // Under spell decals (renderOrder 2) so telegraphs stay readable on water.
    this.mesh.renderOrder = 1;
    this.offSettings = onSettingsChange((s) => {
      this.mesh.material = this.materialFor(s.quality);
    });
  }

  private materialFor(q: Quality) {
    return q === 'high' ? this.high : this.low;
  }

  /** Is this point standing in water (nave pools or a puddle)? */
  isWet(x: number, z: number): boolean {
    for (const r of this.rects) if (x >= r.x0 && x <= r.x1 && z >= r.z0 && z <= r.z1) return true;
    for (const p of this.puddles) {
      const dx = x - p.x;
      const dz = z - p.z;
      const c = Math.cos(p.rot);
      const s = Math.sin(p.rot);
      const lx = (dx * c + dz * s) / (p.r * p.sx);
      const lz = (-dx * s + dz * c) / p.r;
      if (lx * lx + lz * lz <= 1) return true;
    }
    return false;
  }

  /** A ring spreading from (x, z); ignored on dry ground. Oldest ring is recycled. */
  addRipple(x: number, z: number, strength = 1) {
    if (!this.isWet(x, z)) return;
    this.uniforms.uRipples.value[this.next].set(x, z, this.time, strength);
    this.next = (this.next + 1) % RIPPLES;
  }

  setMoon(color: number) {
    this.uniforms.uMoon.value.set(color);
  }

  update(dt: number) {
    this.time += dt;
    this.uniforms.uTime.value = this.time;
  }

  dispose() {
    this.offSettings();
    this.mesh.geometry.dispose();
    this.high.dispose();
    this.low.dispose();
    this.mesh.removeFromParent();
  }
}
