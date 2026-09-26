import * as THREE from 'three';

/**
 * See-through cutout: world geometry standing between the camera and the hero
 * is dithered away inside a screen-space circle around the player, so pillars,
 * walls and statues never hide the character (standard ARPG occlusion fade).
 * One shared uniform block drives every patched material.
 */
export const occlusionUniforms = {
  uOccVP: { value: new THREE.Matrix4() },
  uOccPlayer: { value: new THREE.Vector2() },
  uOccDist: { value: 0 },
  uOccRadius: { value: 0.16 },
  uOccAspect: { value: 1 },
  uOccOn: { value: 0 },
};

const patched = new WeakSet<THREE.Material>();

export function applyOcclusion(material: THREE.Material) {
  if (patched.has(material)) return;
  patched.add(material);
  const prev = material.onBeforeCompile;
  material.onBeforeCompile = (shader, renderer) => {
    prev?.call(material, shader, renderer);
    Object.assign(shader.uniforms, occlusionUniforms);
    shader.vertexShader = shader.vertexShader
      .replace('#include <common>', '#include <common>\nvarying vec3 vOccWorld;')
      .replace(
        '#include <project_vertex>',
        `#include <project_vertex>
        #ifdef USE_INSTANCING
          vOccWorld = (modelMatrix * instanceMatrix * vec4(transformed, 1.0)).xyz;
        #else
          vOccWorld = (modelMatrix * vec4(transformed, 1.0)).xyz;
        #endif`,
      );
    shader.fragmentShader = shader.fragmentShader
      .replace(
        '#include <common>',
        `#include <common>
        varying vec3 vOccWorld;
        uniform mat4 uOccVP;
        uniform vec2 uOccPlayer;
        uniform float uOccDist;
        uniform float uOccRadius;
        uniform float uOccAspect;
        uniform float uOccOn;`,
      )
      .replace(
        '#include <clipping_planes_fragment>',
        `#include <clipping_planes_fragment>
        if (uOccOn > 0.5) {
          vec4 occClip = uOccVP * vec4(vOccWorld, 1.0);
          vec2 occSp = occClip.xy / occClip.w;
          float occR = length((occSp - uOccPlayer) * vec2(uOccAspect, 1.0));
          float occFd = distance(vOccWorld, cameraPosition);
          if (occFd < uOccDist - 1.2 && occR < uOccRadius) {
            // Ordered dither: soft edge, ~70% see-through in the core.
            vec2 cell = mod(floor(gl_FragCoord.xy), 4.0);
            float bayer = mod(cell.x * 3.0 + cell.y * 7.0, 16.0) / 16.0;
            float edge = smoothstep(uOccRadius, uOccRadius * 0.55, occR);
            if (bayer < edge * 0.72) discard;
          }
        }`,
      );
  };
  material.needsUpdate = true;
}

/** Call once per frame with the current camera and the hero's world position. */
export function updateOcclusion(camera: THREE.PerspectiveCamera, player: THREE.Vector3) {
  const vp = occlusionUniforms.uOccVP.value;
  vp.multiplyMatrices(camera.projectionMatrix, camera.matrixWorldInverse);
  const p = player.clone().applyMatrix4(vp);
  occlusionUniforms.uOccPlayer.value.set(p.x, p.y);
  // Radius follows the hero's on-screen height, so zooming keeps them visible.
  const head = player.clone().setY(player.y + 1.6).applyMatrix4(vp);
  const feet = player.clone().setY(0).applyMatrix4(vp);
  occlusionUniforms.uOccRadius.value = THREE.MathUtils.clamp(Math.abs(head.y - feet.y) * 1.05, 0.1, 0.5);
  occlusionUniforms.uOccDist.value = camera.position.distanceTo(player);
  occlusionUniforms.uOccAspect.value = camera.aspect;
  occlusionUniforms.uOccOn.value = 1;
}
