import { afterEach, describe, expect, it, vi } from 'vitest';
import * as THREE from 'three';
import { NodeViews } from '../NodeViews';

const nodes = [{ id: 'pool', type: 'pool_still', x: -31.8, z: 28.2, area: 'acre' as const, rot: 0 }];
afterEach(() => vi.unstubAllGlobals());

describe('gathering markers', () => {
  it('keeps fishing ripples anchored to their node while they animate', () => {
    const views = new NodeViews(new THREE.Scene(), nodes);
    const batch = views.group.children[0];
    const mesh = batch.children[0] as THREE.InstancedMesh;
    const before = new THREE.Matrix4(); mesh.getMatrixAt(0, before);
    for (let i = 0; i < 100; i++) views.update(.1);
    views.group.updateMatrixWorld(true);
    const after = new THREE.Matrix4(); mesh.getMatrixAt(0, after);
    expect(after.elements).toEqual(before.elements);
    expect(batch.scale.toArray()).toEqual([1, 1, 1]);
    const position = new THREE.Vector3().setFromMatrixPosition(mesh.matrixWorld.clone().multiply(after));
    expect(position.x).toBeCloseTo(nodes[0].x, 5);
    expect(position.z).toBeCloseTo(nodes[0].z, 5);
    views.dispose();
  });

  it('draws work progress as bounded ring geometry rather than a shader plane', () => {
    const views = new NodeViews(new THREE.Scene(), nodes);
    views.progress(-30, 23.5, .5, '#d8cfa8');
    const arc = views.group.children.at(-1) as THREE.Mesh<THREE.RingGeometry, THREE.MeshBasicMaterial>;
    expect(arc.geometry.type).toBe('RingGeometry');
    expect(arc.material.type).toBe('MeshBasicMaterial');
    expect(arc.geometry.drawRange.count).toBeGreaterThan(0);
    expect(arc.geometry.drawRange.count).toBeLessThan(arc.geometry.index!.count);
    arc.geometry.computeBoundingSphere();
    expect(arc.geometry.boundingSphere!.radius).toBeLessThan(1);
    views.progress(-30, 23.5, 0, '#d8cfa8');
    expect(arc.visible).toBe(false);
    views.dispose();
  });
});
