import * as THREE from 'three';

/**
 * Necromancer combat clips (tools/build-characters.mjs COMBAT_TRIMS). Their Hip position is stored relative to the
 * source clip's standing first frame, so the crouch / leap survives (feet stay planted) while the ground-plane
 * drift is dropped.
 */
export const COMBAT_CLIPS: ReadonlySet<string> = new Set(['slam', 'sweep', 'flick', 'channel', 'summon']);

/** Gameplay owns hero position and heading; generated clips own limb poses. */
export function inPlaceHeroClip(clip: THREE.AnimationClip, anchor?: { x: number; y: number; z?: number }): THREE.AnimationClip {
  // Keep the authored collapse for corpses.
  if (clip.name.startsWith('death')) return clip;
  if (COMBAT_CLIPS.has(clip.name) && anchor?.z !== undefined) return combatClip(clip, anchor as { x: number; y: number; z: number });
  const tracks = clip.tracks.filter((track) => {
    const { nodeName, propertyName } = THREE.PropertyBinding.parseTrackName(track.name);
    // Root rotations also contain authored turns, which fight mouse aiming.
    if (nodeName === 'Root' && ['position', 'quaternion', 'scale'].includes(propertyName)) return false;
    // All clips use different hip offsets; hold the rig's bind-position instead.
    // Hip and descendant rotations still animate the cast, stride and breathing.
    return !(nodeName === 'Hip' && propertyName === 'position');
  });
  const anchored = new THREE.AnimationClip(clip.name, clip.duration, tracks, clip.blendMode);
  // Generated hero rites include a long ceremonial follow-through. Keep the
  // opening gesture so repeated attacks return to locomotion promptly.
  if (clip.name === 'cast' || clip.name === 'dig') {
    const seconds = Math.min(clip.duration, clip.name === 'dig' ? 1.3 : 1.1);
    return THREE.AnimationUtils.subclip(anchored, clip.name, 0, Math.ceil(seconds * 30), 30);
  }
  return anchored;
}

/** Combat clip: no Root motion or turns, Hip pinned to the bind ground position, vertical travel kept. */
function combatClip(clip: THREE.AnimationClip, anchor: { x: number; y: number; z: number }): THREE.AnimationClip {
  const tracks: THREE.KeyframeTrack[] = [];
  for (const track of clip.tracks) {
    const { nodeName, propertyName } = THREE.PropertyBinding.parseTrackName(track.name);
    if (nodeName === 'Root' && ['position', 'quaternion', 'scale'].includes(propertyName)) continue;
    if (nodeName === 'Hip' && propertyName === 'position') {
      const v = Array.from(track.values);
      for (let i = 0; i < v.length; i += 3) {
        v[i] = anchor.x;
        v[i + 1] = anchor.y;
        v[i + 2] = anchor.z + v[i + 2];
      }
      tracks.push(new THREE.VectorKeyframeTrack(track.name, Array.from(track.times), v));
      continue;
    }
    tracks.push(track);
  }
  return new THREE.AnimationClip(clip.name, clip.duration, tracks, clip.blendMode);
}

/**
 * Enemy clips carry root motion on the Hip (its local X/Y are the ground plane, Z is height): a walk
 * cycle drifts ~1.5 units then snaps back on loop, `attack2` lunges ~0.85. The sim already moves the
 * body, so pin the Hip's ground-plane travel to `anchor` and keep only the vertical bob. Death (the
 * authored collapse), dive and dig (deliberate travel) are left alone.
 */
const stripped = new WeakMap<THREE.AnimationClip, THREE.AnimationClip>();

export function stripRootTravel(clip: THREE.AnimationClip, anchor?: { x: number; y: number }): THREE.AnimationClip {
  if (/^(death|dive|dig)\d?$/.test(clip.name)) return clip;
  const hit = stripped.get(clip);
  if (hit) return hit;
  let changed = false;
  const tracks = clip.tracks.map((track) => {
    const { nodeName, propertyName } = THREE.PropertyBinding.parseTrackName(track.name);
    if (nodeName !== 'Hip' || propertyName !== 'position') return track;
    const v = track.values.slice();
    const ax = anchor?.x ?? v[0];
    const ay = anchor?.y ?? v[1];
    for (let i = 0; i < v.length; i += 3) {
      v[i] = ax;
      v[i + 1] = ay;
    }
    changed = true;
    return new THREE.VectorKeyframeTrack(track.name, Array.from(track.times), Array.from(v));
  });
  const out = changed ? new THREE.AnimationClip(clip.name, clip.duration, tracks, clip.blendMode) : clip;
  stripped.set(clip, out);
  return out;
}

/** The idle clip's first Hip position, used as the shared ground-plane anchor. */
export function hipAnchor(clip: THREE.AnimationClip | undefined): { x: number; y: number; z: number } | undefined {
  const t = clip?.tracks.find((tr) => tr.name === 'Hip.position');
  return t ? { x: t.values[0], y: t.values[1], z: t.values[2] } : undefined;
}
