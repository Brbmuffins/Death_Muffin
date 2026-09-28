import * as THREE from 'three';

/** Gameplay owns hero position and heading; generated clips own limb poses. */
export function inPlaceHeroClip(clip: THREE.AnimationClip): THREE.AnimationClip {
  // Keep the authored collapse for corpses.
  if (clip.name.startsWith('death')) return clip;
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
