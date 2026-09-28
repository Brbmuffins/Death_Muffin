import * as THREE from 'three';

/**
 * Vertex-shader wing flap for flying creatures (the flying pack). Tripo has no
 * flight presets, and its avian auto-rig only boned one wing of a symmetric
 * model, so wings are bent on the GPU instead: every vertex further from the
 * body's centre line than `body` rotates up/down around the wing root, more
 * toward the tip. No bones, no mixer, no CPU per vertex; one shared program.
 *
 * The span axis is whichever horizontal axis of the geometry is wider (Tripo
 * meshes differ), measured in geometry space, i.e. before skinning, so rigged
 * flyers (gargoyle, seraph) flap on top of their clips.
 */
export interface WingOpts {
  /** Radians per second of the flap cycle. */
  speed: number;
  /** Peak wing angle (radians). */
  amp: number;
  /** Half-width of the rigid body as a share of the half-span (default 0.3). */
  body?: number;
}

/** Shared clock; EntityViews advances it once per frame. */
export const wingClock = { value: 0 };

export function applyWingFlap(mesh: THREE.Mesh, mat: THREE.Material, o: WingOpts, phase: number) {
  const g = mesh.geometry;
  if (!g.boundingBox) g.computeBoundingBox();
  const b = g.boundingBox!;
  const ex = b.max.x - b.min.x;
  const ez = b.max.z - b.min.z;
  const axisZ = ez > ex;
  const center = axisZ ? (b.min.z + b.max.z) / 2 : (b.min.x + b.max.x) / 2;
  const half = (axisZ ? ez : ex) / 2;
  const body = half * (o.body ?? 0.3);
  const wing = new THREE.Vector4(o.speed, o.amp, body, half);
  const root = new THREE.Vector2(center, phase);
  mat.onBeforeCompile = (sh) => {
    sh.uniforms.uWingT = wingClock;
    sh.uniforms.uWing = { value: wing };
    sh.uniforms.uWingRoot = { value: root };
    const s = axisZ ? 'transformed.z' : 'transformed.x';
    sh.vertexShader = 'uniform float uWingT;\nuniform vec4 uWing;\nuniform vec2 uWingRoot;\n' + sh.vertexShader.replace(
      '#include <begin_vertex>',
      `#include <begin_vertex>
      {
        float ws = ${s} - uWingRoot.x;
        float wd = abs(ws) - uWing.z;
        if (wd > 0.0) {
          float wf = smoothstep(0.0, max(0.001, uWing.w - uWing.z), wd);
          float wa = uWing.y * sin(uWingT * uWing.x + uWingRoot.y) * (0.35 + 0.65 * wf);
          ${s} = uWingRoot.x + sign(ws) * (uWing.z + wd * cos(wa));
          transformed.y += wd * sin(wa);
        }
      }`,
    );
  };
  mat.customProgramCacheKey = () => (axisZ ? 'wingflap-z' : 'wingflap-x');
}
