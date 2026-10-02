import * as THREE from 'three';

/**
 * A soft fresnel rim in the necromancer's thrall jade, added to a thrall's material so "mine" reads at a glance in a busy
 * fight without a second mesh or a draw call: the silhouette edge picks up a thin jade glow while the face stays as modelled.
 * Enemies never get one. It adds to the emissive term, so it blooms a touch but cannot wash a body out (kept low).
 * Chains after other patches (`onBeforeCompile`); each material keeps its own colour and strength uniforms.
 */
export interface FriendRim {
  color: THREE.ColorRepresentation;
  /** 0..1: how strong the rim is (an ally's legion uses a little less than your own). */
  strength: number;
}

const patched = new WeakSet<THREE.Material>();

export function applyFriendRim(material: THREE.Material, rim: FriendRim) {
  if (patched.has(material)) return;
  patched.add(material);
  const prev = material.onBeforeCompile;
  const key = material.customProgramCacheKey.bind(material);
  material.customProgramCacheKey = () => `${key()}|friendRim`;
  const color = new THREE.Color(rim.color);
  const uniform = { value: new THREE.Vector4(color.r, color.g, color.b, rim.strength) };
  material.onBeforeCompile = (shader, renderer) => {
    prev?.call(material, shader, renderer);
    shader.uniforms.uFriendRim = uniform;
    shader.fragmentShader = shader.fragmentShader
      .replace('#include <common>', '#include <common>\nuniform vec4 uFriendRim;')
      .replace(
        '#include <emissivemap_fragment>',
        `#include <emissivemap_fragment>
        {
          float rimFres = 1.0 - clamp(dot(normalize(normal), normalize(vViewPosition)), 0.0, 1.0);
          totalEmissiveRadiance += uFriendRim.rgb * uFriendRim.a * smoothstep(0.35, 0.95, rimFres) * 0.9;
        }`,
      );
  };
  material.needsUpdate = true;
}
