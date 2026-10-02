import * as THREE from 'three';
import { fx } from './fxTextures';

/**
 * The stairs and the chest of the Catacomb Depths, built from primitives (the spec asks for no new art): a stone-framed stairwell whose
 * steps drop into a glowing dark, a ring on the floor and a soft column of light, or a banded chest. One small group each, so a floor
 * costs a handful of draw calls. `state` sets how loud it is: a sealed stair is cold and quiet, an open one is amber and bright.
 */
export type StairKind = 'down' | 'up' | 'warren' | 'chest';
export type StairState = 'sealed' | 'open' | 'opened';

const PALETTE: Record<StairKind, { open: number; sealed: number }> = {
  down: { open: 0xffb347, sealed: 0x6a4a6a },
  warren: { open: 0xffb347, sealed: 0xffb347 },
  up: { open: 0x8fb8d8, sealed: 0x8fb8d8 },
  chest: { open: 0xf3d27a, sealed: 0xf3d27a },
};

const STONE = new THREE.MeshStandardMaterial({ color: 0x6a6258, roughness: 0.95, metalness: 0.02, flatShading: true });
const STONE_DARK = new THREE.MeshStandardMaterial({ color: 0x3a342e, roughness: 1, metalness: 0, flatShading: true });
const WOOD = new THREE.MeshStandardMaterial({ color: 0x4a2f1c, roughness: 0.85, metalness: 0.05 });
const IRON = new THREE.MeshStandardMaterial({ color: 0x2a2a30, roughness: 0.5, metalness: 0.7 });

export class StairView {
  readonly group = new THREE.Group();
  private glow: THREE.MeshBasicMaterial;
  private ring: THREE.MeshBasicMaterial;
  private beam: THREE.Mesh | null = null;
  private beamMat: THREE.MeshBasicMaterial | null = null;
  private lid: THREE.Object3D | null = null;
  private stepMats: THREE.MeshStandardMaterial[] = [];
  private state: StairState = 'sealed';
  private t = Math.random() * 10;
  private disposables: (THREE.BufferGeometry | THREE.Material)[] = [];
  /** 0..1 eased loudness, so a stair that opens swells instead of switching. */
  private level = 0;

  constructor(readonly kind: StairKind, x: number, z: number) {
    this.group.position.set(x, 0, z);
    const own = <T extends THREE.BufferGeometry | THREE.Material>(o: T): T => {
      this.disposables.push(o);
      return o;
    };
    const pal = PALETTE[kind];
    this.glow = own(new THREE.MeshBasicMaterial({ color: pal.sealed, transparent: true, blending: THREE.AdditiveBlending, depthWrite: false, opacity: 0.4 }));
    this.ring = own(new THREE.MeshBasicMaterial({ map: fx.ring(), color: pal.sealed, transparent: true, blending: THREE.AdditiveBlending, depthWrite: false, opacity: 0.5, side: THREE.DoubleSide }));

    if (kind === 'chest') {
      const body = new THREE.Mesh(own(new THREE.BoxGeometry(1.5, 0.75, 0.9)).translate(0, 0.375, 0), WOOD);
      const band1 = new THREE.Mesh(own(new THREE.BoxGeometry(0.12, 0.8, 0.95)).translate(-0.45, 0.4, 0), IRON);
      const band2 = new THREE.Mesh(own(new THREE.BoxGeometry(0.12, 0.8, 0.95)).translate(0.45, 0.4, 0), IRON);
      const lid = new THREE.Group();
      lid.position.set(0, 0.75, -0.45);
      const lidMesh = new THREE.Mesh(own(new THREE.CylinderGeometry(0.45, 0.45, 1.5, 12, 1, false, 0, Math.PI)).rotateZ(Math.PI / 2).rotateY(Math.PI / 2).translate(0, 0, 0.45), WOOD);
      const lidBand = new THREE.Mesh(own(new THREE.BoxGeometry(0.14, 0.12, 0.92)).translate(0, 0.42, 0.45), IRON);
      lid.add(lidMesh, lidBand);
      this.lid = lid;
      const lock = new THREE.Mesh(own(new THREE.BoxGeometry(0.22, 0.26, 0.1)).translate(0, 0.7, 0.47), own(new THREE.MeshStandardMaterial({ color: 0xc9a24a, roughness: 0.4, metalness: 0.8, emissive: 0x3a2a08 })));
      this.group.add(body, band1, band2, lid, lock);
    } else {
      // The stairwell: a stone frame round a dark well, steps stepping down into a glow that comes from below.
      const w = 2.4;
      const frame = (sx: number, sz: number, x: number, z: number) => this.group.add(new THREE.Mesh(own(new THREE.BoxGeometry(sx, 0.3, sz)).translate(x, 0.15, z), STONE));
      frame(w + 0.8, 0.5, 0, -w / 2 - 0.25);
      frame(w + 0.8, 0.5, 0, w / 2 + 0.25);
      frame(0.5, w, -w / 2 - 0.25, 0);
      frame(0.5, w, w / 2 + 0.25, 0);
      this.group.add(new THREE.Mesh(own(new THREE.PlaneGeometry(w, w)).rotateX(-Math.PI / 2).translate(0, 0.02, 0), own(new THREE.MeshBasicMaterial({ color: 0x030202 }))));
      const up = kind === 'up';
      const steps = 5;
      for (let i = 0; i < steps; i++) {
        // Funnel of steps, narrower and darker as they go down (up: they climb toward the viewer's far side).
        const t = i / (steps - 1);
        const mat = own(new THREE.MeshStandardMaterial({ color: new THREE.Color().setHex(up ? 0x8a8478 : 0x7a7066).multiplyScalar(up ? 0.7 + 0.3 * t : 1 - 0.62 * t), roughness: 0.95, metalness: 0, flatShading: true, emissive: 0x000000 }));
        this.stepMats.push(mat);
        const width = w - 0.2 - i * 0.26;
        const h = up ? 0.1 + i * 0.08 : 0.07;
        const step = new THREE.Mesh(own(new THREE.BoxGeometry(width, h, 0.36)).translate(0, h / 2, 0), mat);
        step.position.set(0, 0.02, w / 2 - 0.34 - i * 0.4);
        this.group.add(step);
      }
      const bottom = new THREE.Mesh(own(new THREE.PlaneGeometry(w * 1.5, w * 1.5)).rotateX(-Math.PI / 2).translate(0, 0.1, -0.35), this.glow);
      this.glow.map = fx.glow();
      bottom.renderOrder = 3;
      this.group.add(bottom);
      // A soft column of light so the way down reads from across the room.
      this.beamMat = own(new THREE.MeshBasicMaterial({ map: fx.glow(), color: pal.sealed, transparent: true, blending: THREE.AdditiveBlending, depthWrite: false, opacity: 0.25, side: THREE.DoubleSide }));
      this.beam = new THREE.Mesh(own(new THREE.PlaneGeometry(2.2, 6.5)).translate(0, 3.25, 0), this.beamMat);
      this.beam.renderOrder = 4;
      this.group.add(this.beam);
    }
    const ring = new THREE.Mesh(own(new THREE.PlaneGeometry(1, 1)).rotateX(-Math.PI / 2).translate(0, 0.045, 0), this.ring);
    ring.scale.setScalar(kind === 'chest' ? 3.2 : 4.4);
    ring.renderOrder = 3;
    this.group.add(ring);
    this.setState(kind === 'warren' ? 'open' : 'sealed');
  }

  /** The loudness of the thing: sealed (cold), open (bright) or, for a chest, opened (spent: dim, lid up). */
  setState(s: StairState) {
    this.state = s;
  }

  /** The point light a stair casts (so the lights list can show it): colour and strength for the current state. */
  light(): { color: number; intensity: number } {
    const pal = PALETTE[this.kind];
    const open = this.state === 'open';
    return { color: open ? pal.open : pal.sealed, intensity: this.state === 'opened' ? 0 : this.kind === 'chest' ? 6 : open ? 9 : 3 };
  }

  update(dt: number) {
    this.t += dt;
    const target = this.state === 'opened' ? 0.05 : this.kind === 'chest' ? 0.85 : this.state === 'open' ? 1 : 0.25;
    this.level += (target - this.level) * Math.min(1, dt * 2.5);
    const pal = PALETTE[this.kind];
    const open = this.state === 'open';
    const colour = open ? pal.open : pal.sealed;
    const flick = 0.85 + 0.15 * Math.sin(this.t * 2.2) * Math.sin(this.t * 1.3);
    this.glow.color.setHex(colour);
    this.glow.opacity = (0.1 + 0.55 * this.level) * flick;
    this.stepMats.forEach((m, i) => {
      m.emissive.setHex(colour);
      m.emissiveIntensity = (0.05 + 0.55 * this.level) * ((i + 1) / this.stepMats.length) * (this.kind === 'up' ? 0.5 : 1);
    });
    this.ring.color.setHex(colour);
    this.ring.opacity = (0.18 + 0.6 * this.level) * (0.8 + 0.2 * Math.sin(this.t * 3));
    if (this.beam && this.beamMat) {
      this.beamMat.color.setHex(colour);
      this.beamMat.opacity = (0.04 + 0.34 * this.level) * flick;
      this.beam.visible = this.level > 0.06;
      // A flat plane always facing across the camera's way: it turns with the camera's yaw only when asked (set by the owner).
    }
    if (this.lid) {
      const want = this.state === 'opened' ? -1.15 : 0;
      this.lid.rotation.x += (want - this.lid.rotation.x) * Math.min(1, dt * 6);
    }
  }

  /** Face the column of light toward the camera (a single plane reads as a beam from any side). */
  faceCamera(cameraYaw: number) {
    if (this.beam) this.beam.rotation.y = cameraYaw - this.group.rotation.y;
  }

  dispose() {
    this.group.removeFromParent();
    for (const d of this.disposables) d.dispose();
  }
}
