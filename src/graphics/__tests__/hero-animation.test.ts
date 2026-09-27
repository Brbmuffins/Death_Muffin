import * as THREE from 'three';
import { NodeIO } from '@gltf-transform/core';
import { ALL_EXTENSIONS } from '@gltf-transform/extensions';
import { describe, expect, it, vi } from 'vitest';
import type { ModelTemplate } from '../AssetCache';
import { Creature } from '../Creature';

const templates = vi.hoisted(() => new Map<string, ModelTemplate>());
vi.mock('../AssetCache', () => ({ assets: { model: async (url: string) => templates.get(url) } }));

/** Read the shipped rig and clips without textures or a WebGL renderer. */
async function template(slug: string): Promise<ModelTemplate> {
  const doc = await new NodeIO().registerExtensions(ALL_EXTENSIONS).read(`public/models/${slug}/character.glb`);
  const scene = new THREE.Group();
  const nodes = new Map(doc.getRoot().listNodes().map((node) => {
    const bone = new THREE.Bone();
    bone.name = node.getName();
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
      const name = `${channel.getTargetNode()!.getName()}.${property}`;
      return property === 'quaternion'
        ? new THREE.QuaternionKeyframeTrack(name, times, values)
        : new THREE.VectorKeyframeTrack(name, times, values);
    });
    return [animation.getName(), new THREE.AnimationClip(animation.getName(), -1, tracks)] as const;
  }));
  return { scene, clips, scale: 1, groundOffset: 0, skinned: false };
}

describe('shipped hero animations', () => {
  it.each(['necromancer', 'hero_ossuary', 'hero_gravecaller', 'hero_mourner', 'hero_rotweaver'] as const)(
    '%s stays anchored through running, casting, digging and repeated casts', async (slug) => {
      const t = await template(slug);
      // Use the registry URL requested by Creature, independent of deploy base.
      const { CREATURE_MODELS } = await import('../modelPaths');
      templates.set(CREATURE_MODELS[slug].url, t);
      const hero = new Creature(slug, { inPlace: true });
      await vi.waitFor(() => expect(hero.loaded).toBe(true));
      const hip = hero.root.getObjectByName('Hip')!;
      const root = hero.root.getObjectByName('Root')!;
      const hand = hero.root.getObjectByName('R_Hand')!;
      const anchor = hip.getWorldPosition(new THREE.Vector3());
      const heading = root.quaternion.clone();
      const handStart = hand.getWorldPosition(new THREE.Vector3());
      let gestureDistance = 0;
      const sample = (seconds: number) => {
        for (let i = 0; i < seconds * 60; i++) {
          hero.update(1 / 60);
          expect(hip.getWorldPosition(new THREE.Vector3()).distanceTo(anchor)).toBeLessThan(1e-6);
          expect(root.quaternion.angleTo(heading)).toBeLessThan(1e-6);
          gestureDistance = Math.max(gestureDistance, hand.getWorldPosition(new THREE.Vector3()).distanceTo(handStart));
        }
      };
      sample(0.4);
      hero.setLoop('run'); sample(1.2);
      hero.playOnce('cast', 3.2);
      hero.setLoop('idle'); sample(0.1);
      // Loop updates must not slow the cast back down to movement speed.
      hero.setLoop('idle', 0.8);
      const state = hero as unknown as { current: THREE.AnimationAction; oneShot: THREE.AnimationAction | null };
      expect(state.current.timeScale).toBe(3.2);
      hero.playOnce('cast', 3.2);
      hero.update(1 / 60);
      expect(state.current.getEffectiveWeight()).toBe(1);
      sample(t.clips.get('cast')!.duration / 3.2 + 0.3);
      expect(state.oneShot === null).toBe(true);
      hero.playOnce('dig', 2.4); sample(t.clips.get('dig')!.duration / 2.4 + 0.3);
      hero.playOnce('hurt', 1.6); sample(t.clips.get('hurt')!.duration / 1.6 + 0.3);
      expect(gestureDistance).toBeGreaterThan(0.1);
      // Death retains its authored collapse rather than staying upright.
      hero.playOnce('death'); hero.update(0.3);
      expect(hip.getWorldPosition(new THREE.Vector3()).distanceTo(anchor)).toBeGreaterThan(0.01);
      hero.dispose();
    },
  );
});
