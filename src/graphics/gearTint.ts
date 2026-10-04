import * as THREE from 'three';

/**
 * Body gear without new art: each region of a skinned hero (chest, legs, hands, feet) recolours only
 * where the skin weights say that body part is, so a copper chestplate tints the torso and sleeves but
 * not the hood. Per-vertex region weights are baked once per geometry from the skeleton's bone names;
 * the tint itself is a few uniforms per creature, so swapping gear is free.
 */
export type GearRegion = 'chest' | 'legs' | 'hands' | 'feet';
export const GEAR_REGIONS: GearRegion[] = ['chest', 'legs', 'hands', 'feet'];

const REGION_OF_BONE: [RegExp, number][] = [
  [/Foot|ToeBase/, 3],
  [/Hand|Forearm/, 2],
  [/Thigh|Calf|Pelvis|^Hip$/, 1],
  [/Spine|Waist|Clavicle|Upperarm/, 0],
];

export interface GearTintState {
  /** rgb = tint colour, w = strength (0 = off). One entry per GEAR_REGIONS. */
  tint: THREE.Vector4[];
  /** Emissive tell for the rare tiers, per region. */
  glow: THREE.Vector3[];
  /** The head (hood, cowl or built-in helmet): rgb = tint, w = strength; and its glow. Driven by Creature.setHeadTint. */
  head: THREE.Vector4;
  headGlow: THREE.Vector3;
}

export function makeGearTintState(): GearTintState {
  return { tint: GEAR_REGIONS.map(() => new THREE.Vector4(1, 1, 1, 0)), glow: GEAR_REGIONS.map(() => new THREE.Vector3()), head: new THREE.Vector4(1, 1, 1, 0), headGlow: new THREE.Vector3() };
}

const MASK = 'gearMask';
const HEAD = 'gearHead';

/** Bake the four region weights per vertex (idempotent: geometry is shared by every instance). */
function bakeMask(mesh: THREE.SkinnedMesh) {
  const geo = mesh.geometry;
  if (geo.getAttribute(MASK) && geo.getAttribute(HEAD)) return true;
  const idx = geo.getAttribute('skinIndex');
  const wgt = geo.getAttribute('skinWeight');
  if (!idx || !wgt) return false;
  const region = mesh.skeleton.bones.map((b) => REGION_OF_BONE.find(([re]) => re.test(b.name))?.[1] ?? -1);
  const headBone = mesh.skeleton.bones.findIndex((b) => b.name === 'Head');
  const out = new Float32Array(idx.count * 4);
  const head = new Float32Array(idx.count);
  for (let v = 0; v < idx.count; v++) {
    for (let k = 0; k < 4; k++) {
      const bi = idx.getComponent(v, k);
      const r = region[bi];
      if (r >= 0) out[v * 4 + r] += wgt.getComponent(v, k);
      if (bi === headBone) head[v] += wgt.getComponent(v, k);
    }
  }
  geo.setAttribute(MASK, new THREE.BufferAttribute(out, 4));
  geo.setAttribute(HEAD, new THREE.BufferAttribute(head, 1));
  return true;
}

/** Patch a hero material so the shared `state` recolours its regions. Safe to chain after other patches. */
export function applyGearTint(mesh: THREE.Mesh, material: THREE.Material, state: GearTintState) {
  if (!(mesh as THREE.SkinnedMesh).isSkinnedMesh || !bakeMask(mesh as THREE.SkinnedMesh)) return;
  const prev = material.onBeforeCompile;
  const key = material.customProgramCacheKey.bind(material);
  material.customProgramCacheKey = () => `${key()}|gearTint`;
  material.onBeforeCompile = (shader, renderer) => {
    prev?.call(material, shader, renderer);
    shader.uniforms.uGearTint = { value: state.tint };
    shader.uniforms.uGearGlow = { value: state.glow };
    shader.uniforms.uHeadTint = { value: state.head };
    shader.uniforms.uHeadGlow = { value: state.headGlow };
    shader.vertexShader = shader.vertexShader
      .replace('#include <common>', `#include <common>\nattribute vec4 ${MASK};\nattribute float ${HEAD};\nvarying vec4 vGearMask;\nvarying float vGearHead;`)
      .replace('#include <begin_vertex>', `#include <begin_vertex>\nvGearMask = ${MASK};\nvGearHead = ${HEAD};`);
    shader.fragmentShader = shader.fragmentShader
      .replace('#include <common>', '#include <common>\nvarying vec4 vGearMask;\nvarying float vGearHead;\nuniform vec4 uGearTint[4];\nuniform vec3 uGearGlow[4];\nuniform vec4 uHeadTint;\nuniform vec3 uHeadGlow;')
      .replace(
        '#include <color_fragment>',
        `#include <color_fragment>
        {
          // Keep the texture's light and shade; swap its hue for the gear's.
          float gearLum = dot(diffuseColor.rgb, vec3(0.299, 0.587, 0.114));
          for (int gi = 0; gi < 4; gi++) {
            float gm = clamp(vGearMask[gi] * uGearTint[gi].w, 0.0, 1.0);
            diffuseColor.rgb = mix(diffuseColor.rgb, uGearTint[gi].rgb * (0.22 + gearLum * 1.5), gm);
          }
          float gh = clamp(vGearHead * uHeadTint.w, 0.0, 1.0);
          diffuseColor.rgb = mix(diffuseColor.rgb, uHeadTint.rgb * (0.22 + gearLum * 1.5), gh);
        }`,
      )
      .replace(
        '#include <emissivemap_fragment>',
        `#include <emissivemap_fragment>
        for (int ge = 0; ge < 4; ge++) totalEmissiveRadiance += uGearGlow[ge] * vGearMask[ge] * uGearTint[ge].w;
        totalEmissiveRadiance += uHeadGlow * vGearHead * uHeadTint.w;`,
      );
  };
  material.needsUpdate = true;
}
