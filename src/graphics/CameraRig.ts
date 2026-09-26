import * as THREE from 'three';
import { settings } from '../app/settings';

/**
 * Fixed three-quarter ARPG camera (reference: high oblique over the horde).
 * Smooth follow, wheel zoom, and trauma-based shake that honours reduced motion.
 */
export class CameraRig {
  readonly camera = new THREE.PerspectiveCamera(40, window.innerWidth / window.innerHeight, 0.5, 260);
  private focus = new THREE.Vector3();
  private zoom = 1;
  private targetZoom = 1;
  private trauma = 0;
  private t = 0;

  onWheel = (e: WheelEvent) => {
    this.targetZoom = THREE.MathUtils.clamp(this.targetZoom + Math.sign(e.deltaY) * 0.12, 0.7, 1.45);
  };

  setZoom(z: number) {
    this.targetZoom = THREE.MathUtils.clamp(z, 0.4, 1.6);
    this.zoom = this.targetZoom;
  }

  snap(x: number, z: number) {
    this.focus.set(x, 0, z);
    this.update(0, x, z);
  }

  shake(amount: number) {
    if (settings.reducedMotion) return;
    this.trauma = Math.min(1, this.trauma + amount);
  }

  update(dt: number, x: number, z: number) {
    this.t += dt;
    const k = dt ? 1 - Math.exp(-dt * 7) : 1;
    this.focus.x += (x - this.focus.x) * k;
    this.focus.z += (z - this.focus.z) * k;
    this.zoom += (this.targetZoom - this.zoom) * (dt ? 1 - Math.exp(-dt * 8) : 1);
    const dist = 22 * this.zoom;
    // ~55° pitch, looking slightly ahead (north) where the waves come from.
    this.camera.position.set(this.focus.x, dist * 0.82, this.focus.z + dist * 0.6);
    this.camera.lookAt(this.focus.x, 0.6, this.focus.z - 1.5);
    if (this.trauma > 0) {
      const s = this.trauma * this.trauma * 0.35;
      this.camera.position.x += Math.sin(this.t * 53) * s;
      this.camera.position.y += Math.sin(this.t * 61 + 1) * s * 0.6;
      this.camera.position.z += Math.cos(this.t * 47 + 2) * s;
      this.trauma = Math.max(0, this.trauma - dt * 1.8);
    }
  }
}
