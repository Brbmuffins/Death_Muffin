/**
 * Test support for held-prop clearance: loads the shipped hero rigs and weapon GLBs without WebGL, drives a real
 * NecromancerAvatar through idle / run / combat gestures, and measures how deep the prop's vertices sink into a
 * simple body volume (torso, robe skirt, head, legs) built from the animated bones. Used by prop-clipping.test.ts.
 */
import * as THREE from 'three';
import { NodeIO } from '@gltf-transform/core';
import { ALL_EXTENSIONS } from '@gltf-transform/extensions';
import type { ModelTemplate } from '../AssetCache';

const io = new NodeIO().registerExtensions(ALL_EXTENSIONS);

/** AssetCache measures every rigged GLB at 0.998 tall (tools/build-stride-speeds.mjs bindHeight). */
export const RIG_HEIGHT = 0.998;

export async function creatureTemplate(slug: string, height: number): Promise<ModelTemplate> {
  const doc = await io.read(`public/models/${slug}/character.glb`);
  const scene = new THREE.Group();
  const nodes = new Map(doc.getRoot().listNodes().map((node) => {
    const bone = new THREE.Bone();
    bone.name = THREE.PropertyBinding.sanitizeNodeName(node.getName()); // as GLTFLoader names them
    bone.position.fromArray(node.getTranslation());
    bone.quaternion.fromArray(node.getRotation());
    bone.scale.fromArray(node.getScale());
    return [node, bone] as const;
  }));
  for (const [node, bone] of nodes) (nodes.get(node.getParentNode()!) ?? scene).add(bone);
  const clips = new Map(doc.getRoot().listAnimations().map((animation) => {
    const tracks = animation.listChannels().map((channel) => {
      const sampler = channel.getSampler()!;
      const times = sampler.getInput()!.getArray()!;
      const values = sampler.getOutput()!.getArray()!;
      const property = { translation: 'position', rotation: 'quaternion', scale: 'scale' }[channel.getTargetPath() as 'translation' | 'rotation' | 'scale'];
      const name = `${THREE.PropertyBinding.sanitizeNodeName(channel.getTargetNode()!.getName())}.${property}`;
      return property === 'quaternion'
        ? new THREE.QuaternionKeyframeTrack(name, times, values)
        : new THREE.VectorKeyframeTrack(name, times, values);
    });
    return [animation.getName(), new THREE.AnimationClip(animation.getName(), -1, tracks)] as const;
  }));
  // The body: skin the mesh by hand so tests can read real surface points.
  const skinNode = doc.getRoot().listNodes().find((n) => n.getSkin());
  let skinned = false;
  if (skinNode) {
    const skin = skinNode.getSkin()!;
    const joints = skin.listJoints().map((j) => nodes.get(j) as THREE.Bone);
    const prim = skinNode.getMesh()!.listPrimitives()[0];
    const pos = prim.getAttribute('POSITION')!;
    const jnt = prim.getAttribute('JOINTS_0')!;
    const wgt = prim.getAttribute('WEIGHTS_0')!;
    const n = pos.getCount();
    const p = new Float32Array(n * 3);
    const si = new Uint16Array(n * 4);
    const sw = new Float32Array(n * 4);
    const el: number[] = [];
    for (let i = 0; i < n; i++) {
      pos.getElement(i, el);
      p.set(el.slice(0, 3), i * 3);
      jnt.getElement(i, el);
      si.set(el.slice(0, 4), i * 4);
      wgt.getElement(i, el);
      sw.set(el.slice(0, 4), i * 4);
    }
    const geo = new THREE.BufferGeometry();
    geo.setAttribute('position', new THREE.BufferAttribute(p, 3));
    geo.setAttribute('skinIndex', new THREE.BufferAttribute(si, 4));
    geo.setAttribute('skinWeight', new THREE.BufferAttribute(sw, 4));
    const idx = prim.getIndices();
    if (idx) geo.setIndex(Array.from(idx.getArray()!));
    const mesh = new THREE.SkinnedMesh(geo, new THREE.MeshStandardMaterial());
    scene.add(mesh);
    scene.updateMatrixWorld(true);
    const ibm = skin.getInverseBindMatrices()!.getArray()!;
    mesh.bind(new THREE.Skeleton(joints, joints.map((_, i) => new THREE.Matrix4().fromArray(ibm, i * 16))), new THREE.Matrix4());
    // Vertices owned mostly by an arm are the carrier of a held prop: left out of clearance tests.
    const arm = new Uint8Array(n);
    for (let i = 0; i < n; i++) {
      let w = 0;
      for (let k = 0; k < 4; k++) if (/Upperarm|Forearm|Hand|Clavicle|Finger|Thumb/.test(joints[si[i * 4 + k]].name)) w += sw[i * 4 + k];
      arm[i] = w > 0.5 ? 1 : 0;
    }
    mesh.userData.armMask = arm;
    skinned = true;
  }
  return { scene, clips, scale: height / RIG_HEIGHT, groundOffset: 0, skinned };
}

/** Surface points of the animated body (every `step`-th vertex not owned by an arm), world space. */
export function bodyPoints(root: THREE.Object3D, step = 6): THREE.Vector3[] {
  const pts: THREE.Vector3[] = [];
  root.updateMatrixWorld(true);
  root.traverse((o) => {
    const m = o as THREE.SkinnedMesh;
    if (!m.isSkinnedMesh) return;
    m.skeleton.update();
    const mask = m.userData.armMask as Uint8Array | undefined;
    const n = m.geometry.getAttribute('position').count;
    for (let i = 0; i < n; i += step) {
      if (mask?.[i]) continue;
      pts.push(m.getVertexPosition(i, new THREE.Vector3()).applyMatrix4(m.matrixWorld));
    }
  });
  return pts;
}

/** A prop GLB as plain meshes (geometry baked through its node transforms, no textures). */
export async function propTemplate(path: string, targetHeight: number): Promise<ModelTemplate> {
  const doc = await io.read(path);
  const scene = new THREE.Group();
  for (const node of doc.getRoot().listNodes()) {
    const mesh = node.getMesh();
    if (!mesh) continue;
    const m = new THREE.Matrix4().fromArray(node.getWorldMatrix());
    for (const prim of mesh.listPrimitives()) {
      const pos = prim.getAttribute('POSITION')!;
      const arr = new Float32Array(pos.getCount() * 3);
      const el: number[] = [];
      const v = new THREE.Vector3();
      for (let i = 0; i < pos.getCount(); i++) {
        pos.getElement(i, el);
        v.set(el[0], el[1], el[2]).applyMatrix4(m);
        arr.set([v.x, v.y, v.z], i * 3);
      }
      const geo = new THREE.BufferGeometry();
      geo.setAttribute('position', new THREE.BufferAttribute(arr, 3));
      const idx = prim.getIndices();
      if (idx) geo.setIndex(Array.from(idx.getArray()!));
      scene.add(new THREE.Mesh(geo, new THREE.MeshStandardMaterial()));
    }
  }
  scene.updateMatrixWorld(true);
  const box = new THREE.Box3().setFromObject(scene);
  const height = Math.max(1e-3, box.max.y - box.min.y);
  const scale = targetHeight / height;
  return { scene, clips: new Map(), scale, groundOffset: -box.min.y * scale, skinned: false };
}

export interface Capsule { a: THREE.Vector3; b: THREE.Vector3; r: number }

const _p = new THREE.Vector3();
const _q = new THREE.Vector3();
const _ab = new THREE.Vector3();

/** How far `p` sinks inside the capsule (0 when outside). */
export function capsuleDepth(p: THREE.Vector3, c: Capsule): number {
  _ab.subVectors(c.b, c.a);
  const len2 = _ab.lengthSq();
  const t = len2 > 1e-9 ? Math.max(0, Math.min(1, _q.subVectors(p, c.a).dot(_ab) / len2)) : 0;
  _p.copy(c.a).addScaledVector(_ab, t);
  return Math.max(0, c.r - p.distanceTo(_p));
}

/**
 * The solid core of the hero: radii small enough that anything inside is certainly inside the robe (torso column, head,
 * thighs), measured against the skinned mesh (the robe is 0.2 m half-width at the hips, 0.3 m at the knees). A prop
 * vertex in here is buried in the body, not just resting on cloth.
 */
export function bodyCore(root: THREE.Object3D): Capsule[] {
  const at = (name: string) => root.getObjectByName(name)!.getWorldPosition(new THREE.Vector3());
  const hip = at('Hip');
  const spine = at('Spine02');
  const head = at('Head');
  return [
    { a: hip, b: spine, r: 0.13 },
    { a: spine, b: head.clone().add(new THREE.Vector3(0, -0.04, 0)), r: 0.11 },
    { a: head.clone().add(new THREE.Vector3(0, 0.08, 0)), b: head.clone().add(new THREE.Vector3(0, 0.12, 0)), r: 0.11 },
    { a: hip.clone().add(new THREE.Vector3(0, -0.1, 0)), b: new THREE.Vector3(hip.x, 0.4, hip.z), r: 0.14 },
  ];
}

/** Sample up to `n` vertices of a prop in world space. */
export function propPoints(obj: THREE.Object3D, n = 260): THREE.Vector3[] {
  obj.updateWorldMatrix(true, true);
  const pts: THREE.Vector3[] = [];
  obj.traverse((o) => {
    const mesh = o as THREE.Mesh;
    if (!mesh.isMesh || !mesh.visible) return;
    const pos = mesh.geometry.getAttribute('position');
    const step = Math.max(1, Math.floor(pos.count / n));
    for (let i = 0; i < pos.count; i += step) pts.push(new THREE.Vector3().fromBufferAttribute(pos, i).applyMatrix4(mesh.matrixWorld));
  });
  return pts;
}

export interface ClipStats {
  /** Share of sampled prop vertices (over all frames) buried in the body core. */
  deep: number;
  /** Share lying within `touch` of the robe / body surface. */
  touching: number;
  /** Deepest vertex inside the core, metres. */
  maxDepth: number;
  frames: number;
  nDeep: number;
  nTouch: number;
  /** Vertices within `touch` of another held prop (main hand versus off hand). */
  nCross: number;
  cross: number;
  total: number;
}

export function emptyStats(): ClipStats {
  return { deep: 0, touching: 0, maxDepth: 0, frames: 0, nDeep: 0, nTouch: 0, nCross: 0, cross: 0, total: 0 };
}

/** Add one frame: `surface` are the body's vertices, `core` its solid capsules. */
export function accumulate(s: ClipStats, core: Capsule[], surface: THREE.Vector3[], pts: THREE.Vector3[], others: THREE.Vector3[] = [], touch = 0.045) {
  s.frames++;
  const t2 = touch * touch;
  for (const p of pts) {
    let d = 0;
    for (const c of core) d = Math.max(d, capsuleDepth(p, c));
    s.total++;
    if (d > 0) {
      s.nDeep++;
      s.maxDepth = Math.max(s.maxDepth, d);
    }
    for (const q of surface) {
      if (p.distanceToSquared(q) < t2) {
        s.nTouch++;
        break;
      }
    }
    for (const q of others) {
      if (p.distanceToSquared(q) < t2) {
        s.nCross++;
        break;
      }
    }
  }
  s.cross = s.total ? s.nCross / s.total : 0;
  s.deep = s.total ? s.nDeep / s.total : 0;
  s.touching = s.total ? s.nTouch / s.total : 0;
}
