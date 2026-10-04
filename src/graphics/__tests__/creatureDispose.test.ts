import { describe, expect, it } from 'vitest';
import * as THREE from 'three';
import { disposeSkeletons } from '../Creature';

// Regression: a dead body's SkinnedMesh clone owns a Skeleton whose bone texture is only freed by skeleton.dispose().
// Missing it leaked ~4 GPU textures per kill (renderer.info.memory.textures climbing during fights).
describe('disposeSkeletons', () => {
  it('disposes the bone texture of every skinned mesh under the root', () => {
    const root = new THREE.Group();
    const disposed: THREE.Texture[] = [];
    for (let i = 0; i < 3; i++) {
      const bone = new THREE.Bone();
      const mesh = new THREE.SkinnedMesh(new THREE.BufferGeometry(), new THREE.MeshBasicMaterial());
      mesh.add(bone);
      mesh.bind(new THREE.Skeleton([bone]));
      mesh.skeleton.computeBoneTexture(); // what the first draw does
      const tex = mesh.skeleton.boneTexture!;
      expect(tex).toBeTruthy();
      tex.addEventListener('dispose', () => disposed.push(tex));
      const holder = new THREE.Group();
      holder.add(mesh);
      root.add(holder);
    }
    root.add(new THREE.Mesh()); // non-skinned children are ignored
    disposeSkeletons(root);
    expect(disposed.length).toBe(3);
  });
});
