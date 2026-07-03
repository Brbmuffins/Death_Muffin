import * as THREE from 'three';
import { GLTFLoader } from 'three/examples/jsm/loaders/GLTFLoader.js';
import type { CharacterPaths } from './modelPaths';

export type AnimState = 'idle' | 'walk' | 'run' | 'hurt' | 'attack';

const FADE_DURATION = 0.2; // crossfade seconds
const TARGET_HEIGHT = 1.8;  // world units — matches the capsule the model replaces

/**
 * Tripo clips bake root motion. Gameplay code moves the character, so zero the
 * HORIZONTAL components of the top root bone's position track only — vertical
 * stays (gait bob / jumps live there). Touch no other track: limb position
 * tracks carry values that differ from rest pose and must remain intact.
 */
function stripHorizontalRootMotion(clip: THREE.AnimationClip) {
  for (const tr of clip.tracks) {
    const bone = tr.name.split('.')[0].split('|').pop() ?? '';
    if (!tr.name.endsWith('.position') || !/^(Root|Hip)$/i.test(bone)) continue;
    const v = tr.values as Float32Array;
    const x0 = v[0], z0 = v[2];
    for (let i = 0; i < v.length; i += 3) { v[i] = x0; v[i + 2] = z0; }
    break; // top root only
  }
}

/**
 * Loads a Tripo-generated biped character: rigged GLB mesh + FBX animation
 * clips. Exposes a THREE.Group that can be added to any scene. Falls back
 * gracefully — if loading fails the group stays empty and update() is a no-op.
 *
 * Usage:
 *   const model = new CharacterModel(paths);
 *   scene.add(model.root);
 *   await model.load();  // async, non-blocking — call fire-and-forget
 *   model.root.position.copy(capsule.position);
 *   model.setState('walk');
 *   // in render loop: model.update(dt);
 */
export class CharacterModel {
  /** Add this to the scene. Position it in the render loop. */
  readonly root = new THREE.Group();

  private mixer: THREE.AnimationMixer | null = null;
  private clips = new Map<string, THREE.AnimationClip>();
  private currentState: AnimState = 'idle';
  private currentAction: THREE.AnimationAction | null = null;
  private _loaded = false;

  get loaded() { return this._loaded; }

  constructor(private paths: CharacterPaths) {}

  /** Fire-and-forget loader. Sets loaded=true and plays idle when done. */
  async load(): Promise<void> {
    try {
      const gltfLoader = new GLTFLoader();
      const gltf = await gltfLoader.loadAsync(this.paths.rig);
      const model = gltf.scene;

      // Normalize by measured bounds — export scale varies per asset/optimizer
      // (raw Tripo rigs are in cm; quantized rebuilds bake their own node scale).
      const bounds = new THREE.Box3().setFromObject(model);
      const height = bounds.max.y - bounds.min.y;
      if (height > 0) model.scale.setScalar(TARGET_HEIGHT / height);
      // Group origin is at feet: lift so the mesh's lowest point sits on y=0.
      model.position.y = -bounds.min.y * model.scale.y;
      model.traverse((obj) => {
        if ((obj as THREE.Mesh).isMesh) {
          obj.castShadow = true;
          obj.receiveShadow = false;
        }
      });
      this.root.add(model);

      this.mixer = new THREE.AnimationMixer(model);

      // Load all animation-only GLBs (built by tools/build-models.mjs) in parallel
      const animTargets: [AnimState, string][] = (
        [
          ['idle',   this.paths.idle],
          ['walk',   this.paths.walk],
          ['run',    this.paths.run],
          ['hurt',   this.paths.hurt],
          ['attack', this.paths.attack],
        ] as [AnimState, string | undefined][]
      ).filter((e): e is [AnimState, string] => !!e[1]);

      await Promise.all(
        animTargets.map(async ([state, path]) => {
          try {
            const anim = await gltfLoader.loadAsync(path);
            if (anim.animations.length > 0) {
              // FBX-derived files carry each take twice under different node-path
              // prefixes; the SHALLOW variant (fewer '|' segments) binds correctly.
              const clip = anim.animations.reduce((a, b) =>
                (a.name.split('|').length <= b.name.split('|').length ? a : b));
              stripHorizontalRootMotion(clip);
              clip.name = state;
              this.clips.set(state, clip);
            }
          } catch {
            // Missing animation is fine — will fall back to idle
          }
        }),
      );

      this._loaded = true;
      this.setState(this.currentState);
    } catch {
      // Loading failed — model stays invisible, no crash
    }
  }

  setState(state: AnimState, loop = true) {
    this.currentState = state;
    if (!this._loaded || !this.mixer) return;

    const clip = this.clips.get(state) ?? this.clips.get('idle');
    if (!clip) return;

    const next = this.mixer.clipAction(clip);
    next.setLoop(loop ? THREE.LoopRepeat : THREE.LoopOnce, Infinity);
    if (!loop) next.clampWhenFinished = true;

    if (next === this.currentAction) return;

    if (this.currentAction) {
      next.reset().fadeIn(FADE_DURATION);
      this.currentAction.fadeOut(FADE_DURATION);
    } else {
      next.reset().play();
    }
    this.currentAction = next;

    // One-shot animations (hurt, attack) return to idle when done
    if (!loop) {
      const onFinish = () => {
        this.mixer!.removeEventListener('finished', onFinish);
        this.setState('idle');
      };
      this.mixer.addEventListener('finished', onFinish);
    }
  }

  update(dt: number) {
    this.mixer?.update(dt);
  }

  dispose() {
    this.mixer?.stopAllAction();
    this.root.traverse((obj) => {
      const mesh = obj as THREE.Mesh;
      if (mesh.isMesh) {
        mesh.geometry?.dispose();
        if (Array.isArray(mesh.material)) mesh.material.forEach((m) => m.dispose());
        else mesh.material?.dispose();
      }
    });
    this.root.clear();
    this.mixer = null;
  }
}
