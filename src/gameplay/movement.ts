import * as THREE from 'three';

/**
 * Diablo-style click-to-move: raycast the cursor onto the ground plane and
 * walk the player toward it. WASD also moves directly; keyboard input
 * clears the click target.
 */
export class ClickToMove {
  moveTarget: THREE.Vector3 | null = null;

  private ray = new THREE.Raycaster();
  private ndc = new THREE.Vector2();
  private plane = new THREE.Plane(new THREE.Vector3(0, 1, 0), 0);

  constructor(private walkRadius: number) {}

  private toNdc(e: PointerEvent | MouseEvent) {
    this.ndc.set(
      (e.clientX / window.innerWidth) * 2 - 1,
      -(e.clientY / window.innerHeight) * 2 + 1,
    );
    return this.ndc;
  }

  /** Cursor → point on the ground plane, clamped to the walkable radius. */
  groundPoint(e: PointerEvent | MouseEvent, camera: THREE.Camera): THREE.Vector3 | null {
    this.ray.setFromCamera(this.toNdc(e), camera);
    const p = new THREE.Vector3();
    if (!this.ray.ray.intersectPlane(this.plane, p)) return null;
    const flat = new THREE.Vector2(p.x, p.z);
    if (flat.length() > this.walkRadius) {
      flat.setLength(this.walkRadius);
      p.set(flat.x, 0, flat.y);
    }
    return p;
  }

  /** Cursor → first intersected object among `meshes` (enemy picking). */
  pick(e: PointerEvent | MouseEvent, camera: THREE.Camera, meshes: THREE.Object3D[]): THREE.Object3D | null {
    this.ray.setFromCamera(this.toNdc(e), camera);
    const hits = this.ray.intersectObjects(meshes, false);
    return hits.length ? hits[0].object : null;
  }

  setTarget(p: THREE.Vector3) {
    this.moveTarget = p.clone();
  }

  clear() {
    this.moveTarget = null;
  }

  /** Walk toward the target. Returns true while moving. */
  update(player: THREE.Object3D, speed: number, dt: number): boolean {
    if (!this.moveTarget) return false;
    const dx = this.moveTarget.x - player.position.x;
    const dz = this.moveTarget.z - player.position.z;
    const d = Math.hypot(dx, dz);
    if (d < 0.15) {
      this.moveTarget = null;
      return false;
    }
    const step = Math.min(speed * dt, d);
    player.position.x += (dx / d) * step;
    player.position.z += (dz / d) * step;
    player.rotation.y = Math.atan2(dx, dz);
    return true;
  }
}
