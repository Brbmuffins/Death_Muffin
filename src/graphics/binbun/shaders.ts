/**
 * GLSL ports of the Binbun gdshaders (BINBUN-VFX-PORT §3 "gdshader → GLSL").
 *
 * - `transparent` / `particle` (shared/shader): ported line for line — up to three
 *   scrolling / rotating / radial masks with `blendf`, the tertiary colour ramp, the
 *   `min(0.5 + smoothness/2, mask)³` alpha, vertex displacement and billboarding.
 *   `particle` adds the per-particle `COLOR.r` UV offset.
 * - `glow_fresnel` (shared/shader): ported line for line.
 * - Everything else (per-pack flame / impact / loot / portal / beam shaders) goes
 *   through `generic`: the material's main mask × a per-mesh envelope, coloured
 *   secondary → primary. It reads close enough for review in the gallery; exact ports
 *   of those shaders are a follow-up (docs/BINBUN-VFX-PORT.md).
 *
 * `alpha_mode` is always 0 (smooth) and `proximity_fade` is off (no depth pre-pass).
 * Output follows the port doc: lit = ALBEDO·0.25 + EMISSION, unshaded = ALBEDO.
 */
import * as THREE from 'three';
import type { MaterialTemplate, MeshShape, ParamValue } from './godot';

const VERTEX_HEAD = /* glsl */ `
#ifdef USE_INSTANCING
attribute vec4 aColor;
attribute vec4 aCustom;
#endif
uniform float uBillboard;
uniform float uTime;
varying vec2 vUv;
varying vec4 vColor;
varying vec3 vViewPos;
varying vec3 vNormal;
`;

const VERTEX_MAIN = /* glsl */ `
void main() {
  // Godot's UV origin is the top-left; three's primitives put v = 1 at the top.
  vUv = vec2(uv.x, 1.0 - uv.y);
#ifdef USE_INSTANCING
  mat4 m = modelMatrix * instanceMatrix;
  vColor = aColor;
  float ang = aCustom.x;
#else
  mat4 m = modelMatrix;
  vColor = vec4(1.0);
  float ang = 0.0;
#endif
  vec3 pos = position;
#ifdef DISPLACE
  pos += normal * (mask(vUv, MASK_OFFSET) - displacement_offset) * displacement_scale;
#endif
  vec4 mv;
  if (uBillboard > 0.5) {
    vec3 s = vec3(length(m[0].xyz), length(m[1].xyz), length(m[2].xyz));
    float c = cos(ang);
    float sn = sin(ang);
    vec2 p2 = pos.xy * s.xy;
    p2 = vec2(p2.x * c - p2.y * sn, p2.x * sn + p2.y * c);
    mv = viewMatrix * vec4(m[3].xyz, 1.0) + vec4(p2, pos.z * s.z, 0.0);
    vNormal = normalize(normal);
  } else {
    mv = viewMatrix * m * vec4(pos, 1.0);
    vNormal = normalize(mat3(viewMatrix * m) * normal);
  }
  vViewPos = mv.xyz;
  gl_Position = projectionMatrix * mv;
}
`;

// util/blend.gdshaderinc + util/uvtools.gdshaderinc, verbatim apart from types.
const UTIL = /* glsl */ `
#define PI 3.14159265359
float blendf(float a, float b, int mode) {
  float result = 0.0;
  if (mode == 0) result = a + b;
  if (mode == 1) result = a - b;
  if (mode == 2) result = a * b;
  if (mode == 3) result = min(a, b);
  if (mode == 4) result = max(a, b);
  if (mode == 5) result = 1.0 - (1.0 - a) * (1.0 - b);
  if (mode == 6) result = a < 0.5 ? (2.0 * a * b) : (1.0 - 2.0 * (1.0 - a) * (1.0 - b));
  if (mode == 7) result = b < 0.5 ? (2.0 * a * b) : (1.0 - 2.0 * (1.0 - a) * (1.0 - b));
  if (mode == 8) result = b < 0.5 ? (2.0 * a * b + a * a * (1.0 - 2.0 * b)) : (sqrt(a) * (2.0 * b - 1.0) + (2.0 * a) * (1.0 - b));
  if (mode == 9) result = a / (1.0 - b);
  if (mode == 10) result = 1.0 - (1.0 - a) / b;
  if (mode == 11) result = a + b - 1.0;
  return result;
}
vec2 uv_align(vec2 uv, int align_mode) {
  if (align_mode == 1) return vec2(uv.y, uv.x);
  if (align_mode == 2) return vec2(1.0 - uv.x, uv.y);
  if (align_mode == 3) return vec2(1.0 - uv.y, uv.x);
  return uv;
}
vec2 uv_radial(vec2 uv) {
  vec2 c = uv - vec2(0.5);
  return vec2(atan(c.x, c.y) / (2.0 * PI), length(c));
}
vec2 uv_rotate(vec2 uv, float angle) {
  mat2 rotation = mat2(vec2(sin(angle), -cos(angle)), vec2(cos(angle), sin(angle)));
  return (uv - vec2(0.5)) * rotation + vec2(0.5);
}
// Masks are data: white-on-alpha sprites and grey maps both read as r·a.
float tap(sampler2D t, vec2 uv) { vec4 c = texture2D(t, uv); return c.r * c.a; }
`;

const MASKS = /* glsl */ `
uniform sampler2D mask1_texture;
uniform vec2 mask1_scroll;
uniform vec2 mask1_scale;
uniform float mask1_radial;
uniform float mask1_rotation;
uniform float use_mask2;
uniform sampler2D mask2_texture;
uniform vec2 mask2_scroll;
uniform vec2 mask2_scale;
uniform float mask2_strength;
uniform int mask2_blend_mode;
uniform float mask2_radial;
uniform float mask2_rotation;
uniform float use_mask3;
uniform sampler2D mask3_texture;
uniform vec2 mask3_scroll;
uniform vec2 mask3_scale;
uniform float mask3_strength;
uniform int mask3_blend_mode;
uniform float mask3_radial;
uniform float mask3_rotation;
uniform float time_scale;
uniform int uv_alignment;
uniform float displacement_scale;
uniform float displacement_offset;
float maskLayer(sampler2D t, vec2 uv, vec2 scale, vec2 scroll, float radial, float rotation, float offset) {
  vec2 mapped = (radial > 0.5 ? uv_radial(uv) : uv) * scale + vec2(offset);
  return tap(t, uv_rotate(uv_align(mapped, uv_alignment) + vec2(uTime * time_scale) * scroll, uTime * rotation));
}
float mask(vec2 uv, float offset) {
  float m = maskLayer(mask1_texture, uv, mask1_scale, mask1_scroll, mask1_radial, mask1_rotation, offset);
  if (use_mask2 > 0.5) m = mix(m, blendf(m, maskLayer(mask2_texture, uv, mask2_scale, mask2_scroll, mask2_radial, mask2_rotation, 0.0), mask2_blend_mode), mask2_strength);
  if (use_mask3 > 0.5) m = mix(m, blendf(m, maskLayer(mask3_texture, uv, mask3_scale, mask3_scroll, mask3_radial, mask3_rotation, 0.0), mask3_blend_mode), mask3_strength);
  return m;
}
`;

const FRAG_HEAD = /* glsl */ `
uniform float uTime;
uniform float uFade;
uniform float uGain;
uniform vec3 primary_color;
uniform vec3 secondary_color;
uniform vec3 tertiary_color;
uniform float alpha_multiplier;
uniform float emission_strength;
varying vec2 vUv;
varying vec4 vColor;
varying vec3 vViewPos;
varying vec3 vNormal;
`;

const TRANSPARENT_FS = /* glsl */ `
uniform float use_tertiary;
uniform float color_smoothness;
uniform float alpha_smoothness;
uniform vec4 edge_cutoff;
uniform float uUnshaded;
void main() {
  float mask_value = mask(vUv, MASK_OFFSET);
  float color_mask = smoothstep(0.5 - color_smoothness * 0.5, 0.5 + color_smoothness * 0.5, mask_value);
  vec3 albedo = use_tertiary > 0.5 ? mix(tertiary_color, secondary_color, pow(color_mask, 3.0)) : mix(secondary_color, primary_color, pow(color_mask, 3.0));
  vec3 emission = albedo * emission_strength;
  // clamp(0.5 - s/2, 0.5 + s/2, mask) in the source is min(0.5 + s/2, mask).
  float alpha_mask = max(0.0, min(0.5 + alpha_smoothness * 0.5, mask_value));
  float alpha = clamp(pow(alpha_mask, 3.0) * alpha_multiplier * vColor.a, 0.0, 1.0) * uFade;
  if (edge_cutoff != vec4(0.0)) {
    if (vUv.x < edge_cutoff.x || vUv.y < edge_cutoff.y || vUv.x > 1.0 - edge_cutoff.z || vUv.y > 1.0 - edge_cutoff.w) discard;
  }
  if (alpha < 0.003) discard;
  gl_FragColor = vec4((uUnshaded > 0.5 ? albedo : albedo * 0.25 + emission) * uGain, alpha);
}
`;

const GLOW_FRESNEL_FS = /* glsl */ `
uniform float fresnel_amount;
uniform float fresnel_exponent;
uniform sampler2D fresnel_gradient;
uniform float enable_mask;
uniform sampler2D mask_texture;
uniform vec2 mask_scroll;
uniform vec2 mask_scale;
uniform int mask_blend_mode;
uniform float mask_blend;
void main() {
  float fres = pow(1.0 - clamp(dot(normalize(vNormal), normalize(-vViewPos)), 0.0, 1.0), fresnel_amount);
  float value = pow(max(texture2D(fresnel_gradient, vec2(fres, 0.5)).r, 0.0), fresnel_exponent);
  if (enable_mask > 0.5) {
    float mask_value = tap(mask_texture, vUv * mask_scale + vec2(uTime) * mask_scroll);
    value = clamp(mix(value, blendf(value, mask_value, mask_blend_mode), mask_blend), 0.0, 1.0);
  }
  vec3 albedo = mix(secondary_color, primary_color, value) * emission_strength;
  float alpha = value * alpha_multiplier * vColor.a * uFade;
  if (alpha < 0.003) discard;
  gl_FragColor = vec4(albedo * uGain, alpha);
}
`;

const GENERIC_FS = /* glsl */ `
uniform sampler2D uMap;
uniform float uHasMap;
uniform vec2 uScroll;
uniform vec2 uScale;
uniform float uShape;
uniform float uUnshaded;
uniform float uSmoke;
void main() {
  float facing = clamp(abs(dot(normalize(vNormal), normalize(-vViewPos))), 0.0, 1.0);
  float env;
  if (uShape < 0.5) env = 1.0 - smoothstep(0.15, 0.5, length(vUv - 0.5));
  else if (uShape < 1.5) env = facing * facing;
  else if (uShape < 2.5) env = facing * facing * sin(clamp(vUv.y, 0.0, 1.0) * PI);
  else env = facing;
  float m = env;
  if (uHasMap > 0.5) m *= tap(uMap, vUv * uScale + uScroll * uTime + vec2(vColor.r));
  vec3 albedo = mix(secondary_color, primary_color, smoothstep(0.0, 1.0, m));
  float alpha = clamp(m * 1.6 * alpha_multiplier * vColor.a, 0.0, 1.0) * uFade;
  if (alpha < 0.003) discard;
  vec3 col = uSmoke > 0.5 ? albedo * 0.5 : uUnshaded > 0.5 ? albedo * max(1.0, emission_strength * 0.5) : albedo * 0.25 + albedo * emission_strength;
  gl_FragColor = vec4(col * uGain, uSmoke > 0.5 ? alpha * 0.55 : alpha);
}
`;

/** Envelope for the generic port: 0 quad/plane, 1 sphere, 2 cylinder, 3 torus. */
export function shapeCode(shape: MeshShape | undefined) {
  if (!shape) return 0;
  return shape.kind === 'sphere' ? 1 : shape.kind === 'cylinder' ? 2 : shape.kind === 'torus' ? 3 : 0;
}

/** Godot `source_color` values are sRGB; the renderer works in linear. */
export function linear(c: readonly number[] | undefined, fallback: readonly number[] = [1, 1, 1]) {
  const v = c ?? fallback;
  return new THREE.Color().setRGB(v[0] ?? 1, v[1] ?? 1, v[2] ?? 1, THREE.SRGBColorSpace);
}

type TextureFor = (ref: MaterialTemplate['samplers'][string] | null | undefined) => THREE.Texture;

const num = (v: ParamValue | undefined, d: number) => (typeof v === 'number' ? v : typeof v === 'boolean' ? (v ? 1 : 0) : d);
const v2 = (v: ParamValue | undefined, d: [number, number]) => (Array.isArray(v) && v.length >= 2 ? new THREE.Vector2(v[0], v[1]) : new THREE.Vector2(...d));
const v4 = (v: ParamValue | undefined) => (Array.isArray(v) && v.length >= 4 ? new THREE.Vector4(v[0], v[1], v[2], v[3]) : new THREE.Vector4());

/**
 * One material per node per live effect (animation tracks write its uniforms).
 * `defaults` records the starting value of every animatable uniform so a pooled
 * effect can be reset.
 */
export function buildMaterial(m: MaterialTemplate | null | undefined, shape: MeshShape | undefined, texture: TextureFor): THREE.ShaderMaterial {
  const p = m?.params ?? {};
  const program = m?.program ?? 'generic';
  const base: Record<string, THREE.IUniform> = {
    uTime: { value: 0 },
    uFade: { value: 1 },
    uGain: { value: 1 },
    uBillboard: { value: m?.billboard ? 1 : 0 },
    primary_color: { value: linear(m?.colors[0]) },
    secondary_color: { value: linear(m?.colors[1]) },
    tertiary_color: { value: linear(m?.colors[2]) },
    alpha_multiplier: { value: num(p.alpha_multiplier, 0.954) },
    emission_strength: { value: num(p.emission_strength, m?.emission ?? 2) },
  };
  let defines: Record<string, string> = {};
  let vertex = VERTEX_HEAD + VERTEX_MAIN;
  let fragment: string;
  if (program === 'transparent' || program === 'particle') {
    Object.assign(base, {
      mask1_texture: { value: texture(m?.samplers.mask1_texture) },
      mask1_scroll: { value: v2(p.mask1_scroll, [0, 0]) },
      mask1_scale: { value: v2(p.mask1_scale, [1, 1]) },
      mask1_radial: { value: num(p.mask1_radial, 0) },
      mask1_rotation: { value: num(p.mask1_rotation, 0) },
      use_mask2: { value: num(p.use_mask2, 0) },
      mask2_texture: { value: texture(m?.samplers.mask2_texture) },
      mask2_scroll: { value: v2(p.mask2_scroll, [0, 0]) },
      mask2_scale: { value: v2(p.mask2_scale, [1, 1]) },
      mask2_strength: { value: num(p.mask2_strength, 0) },
      mask2_blend_mode: { value: num(p.mask2_blend_mode, 0) },
      mask2_radial: { value: num(p.mask2_radial, 0) },
      mask2_rotation: { value: num(p.mask2_rotation, 0) },
      use_mask3: { value: num(p.use_mask3, 0) },
      mask3_texture: { value: texture(m?.samplers.mask3_texture) },
      mask3_scroll: { value: v2(p.mask3_scroll, [0, 0]) },
      mask3_scale: { value: v2(p.mask3_scale, [1, 1]) },
      mask3_strength: { value: num(p.mask3_strength, 0) },
      mask3_blend_mode: { value: num(p.mask3_blend_mode, 0) },
      mask3_radial: { value: num(p.mask3_radial, 0) },
      mask3_rotation: { value: num(p.mask3_rotation, 0) },
      time_scale: { value: num(p.time_scale, 1) },
      uv_alignment: { value: num(p.uv_alignment, 0) },
      displacement_scale: { value: num(p.displacement_scale, 0) },
      displacement_offset: { value: num(p.displacement_offset, 0.5) },
      use_tertiary: { value: num(p.use_tertiary, 0) },
      color_smoothness: { value: num(p.color_smoothness, 0.5) },
      alpha_smoothness: { value: num(p.alpha_smoothness, 0.954) },
      edge_cutoff: { value: v4(p.edge_cutoff) },
      uUnshaded: { value: 0 },
    });
    defines = { MASK_OFFSET: program === 'particle' ? 'vColor.r' : '0.0' };
    if (num(p.displacement_scale, 0) !== 0) defines.DISPLACE = '';
    vertex = VERTEX_HEAD + UTIL + MASKS + VERTEX_MAIN;
    fragment = FRAG_HEAD + UTIL + MASKS + TRANSPARENT_FS;
  } else if (program === 'glow_fresnel') {
    Object.assign(base, {
      fresnel_amount: { value: num(p.fresnel_amount, 1) },
      fresnel_exponent: { value: num(p.fresnel_exponent, 1) },
      fresnel_gradient: { value: texture(m?.samplers.fresnel_gradient) },
      enable_mask: { value: num(p.enable_mask, 0) },
      mask_texture: { value: texture(m?.samplers.mask_texture) },
      mask_scroll: { value: v2(p.mask_scroll, [0, 0]) },
      mask_scale: { value: v2(p.mask_scale, [1, 1]) },
      mask_blend_mode: { value: num(p.mask_blend_mode, 0) },
      mask_blend: { value: num(p.mask_blend, 0) },
    });
    base.emission_strength.value = num(p.emission_strength, 1);
    fragment = FRAG_HEAD + UTIL + GLOW_FRESNEL_FS;
  } else {
    const tex = m?.texture ?? null;
    Object.assign(base, {
      uMap: { value: texture(tex) },
      uHasMap: { value: tex ? 1 : 0 },
      uScroll: { value: v2(p.mask1_scroll ?? p.mask_scroll ?? p.scroll_speed ?? p.noise_scroll, [0, 0]) },
      uScale: { value: v2(p.mask1_scale ?? p.mask_scale ?? p.texture_scale ?? p.noise_scale, [1, 1]) },
      uShape: { value: shapeCode(shape) },
      uUnshaded: { value: m?.unshaded ? 1 : 0 },
      uSmoke: { value: m?.smoke ? 1 : 0 },
    });
    base.emission_strength.value = m?.emission ?? 2;
    fragment = FRAG_HEAD + UTIL + GENERIC_FS;
  }
  const mat = new THREE.ShaderMaterial({
    uniforms: base,
    defines,
    vertexShader: vertex,
    fragmentShader: fragment,
    transparent: true,
    depthWrite: false,
    blending: m?.additive ? THREE.AdditiveBlending : THREE.NormalBlending,
    side: m?.doubleSide || program === 'generic' ? THREE.DoubleSide : THREE.FrontSide,
  });
  mat.userData.defaults = Object.fromEntries(Object.entries(base).filter(([, u]) => typeof u.value === 'number').map(([k, u]) => [k, u.value as number]));
  return mat;
}

/** Recolour: the root `vfx_controller` pushes these into every child material. */
export function setColors(mat: THREE.ShaderMaterial, colors: readonly THREE.Color[]) {
  const u = mat.uniforms;
  if (colors[0]) u.primary_color.value.copy(colors[0]);
  if (colors[1]) u.secondary_color.value.copy(colors[1]);
  if (colors[2]) u.tertiary_color.value.copy(colors[2]);
}
