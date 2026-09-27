import * as THREE from 'three';

/** Gameplay owns hero position and heading; generated clips own limb poses. */
export function inPlaceHeroClip(clip: THREE.AnimationClip): THREE.AnimationClip {
  // Keep the authored collapse for corpses.
  if (clip.name === 'death') return clip;
  const tracks = clip.tracks.filter((track) => {
    const { nodeName, propertyName } = THREE.PropertyBinding.parseTrackName(track.name);
    // Root rotations also contain authored turns, which fight mouse aiming.
    if (nodeName === 'Root' && ['position', 'quaternion', 'scale'].includes(propertyName)) return false;
    // All clips use different hip offsets; hold the rig's bind-position instead.
    // Hip and descendant rotations still animate the cast, stride and breathing.
    return !(nodeName === 'Hip' && propertyName === 'position');
  });
  return new THREE.AnimationClip(clip.name, clip.duration, tracks, clip.blendMode);
}
