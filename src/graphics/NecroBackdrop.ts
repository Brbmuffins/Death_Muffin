import * as THREE from 'three';
import { getRuntime, type RuntimeView } from '../app/GameRuntime';
import { settings } from '../app/settings';
import { assets } from './AssetCache';
import { Effects } from './Effects';
import { fx } from './fxTextures';

/**
 * Login / discipline-select backdrop: the burning graveyard vista as a deep
 * matte, with parallax, drifting grave-mist, embers and a ritual sigil.
 */
export class NecroBackdrop implements RuntimeView {
  readonly scene = new THREE.Scene();
  readonly camera = new THREE.PerspectiveCamera(40, window.innerWidth / window.innerHeight, 0.1, 200);
  readonly bloom = { strength: 0.75, radius: 0.6, threshold: 0.78 };
  private effects: Effects;
  private matte: THREE.Mesh;
  private sigil: THREE.Mesh;
  private mouse = new THREE.Vector2();
  private t = 0;
  private onMove = (e: PointerEvent) => this.mouse.set((e.clientX / window.innerWidth) * 2 - 1, (e.clientY / window.innerHeight) * 2 - 1);

  constructor() {
    this.scene.background = new THREE.Color(0x07060a);
    this.scene.fog = new THREE.FogExp2(0x0b0810, 0.012);
    this.camera.position.set(0, 1.6, 12);
    const tex = assets.texture('art/login-backdrop-pyre.webp');
    this.matte = new THREE.Mesh(
      new THREE.PlaneGeometry(96, 54),
      new THREE.MeshBasicMaterial({ map: tex, color: 0xe8dfe0, fog: false }),
    );
    this.matte.position.set(0, 6, -48);
    this.scene.add(this.matte);
    this.sigil = new THREE.Mesh(
      new THREE.PlaneGeometry(9, 9).rotateX(-Math.PI / 2),
      new THREE.MeshBasicMaterial({ map: fx.sigil(), color: 0xc26537, transparent: true, opacity: 0.3, blending: THREE.AdditiveBlending, depthWrite: false }),
    );
    this.sigil.position.set(0, -2.4, -4);
    this.scene.add(this.sigil);
    this.effects = new Effects(this.scene);
    window.addEventListener('pointermove', this.onMove);
  }

  mount() {
    getRuntime().setView(this);
  }

  update(dt: number) {
    this.t += dt;
    const still = settings.reducedMotion;
    // Mist banks and motes.
    if (!still && Math.random() < dt * 6) {
      this.effects.emitSmoke({ x: (Math.random() - 0.5) * 40, y: -2 + Math.random(), z: -6 - Math.random() * 14, count: 1, color: 0x3a3048, spread: 2, speed: 0.4, up: 0.05, life: 9, size: 9, shrink: -0.6, drag: 0.1 });
    }
    if (!still && Math.random() < dt * 14) {
      const left = Math.random() < 0.62;
      this.effects.emit({ x: left ? -9 - Math.random() * 9 : 2 + Math.random() * 10, y: -2.5, z: -2 - Math.random() * 12, count: 1, color: left ? 0xf29a4d : 0x9b5cff, spread: 0.5, speed: 0.15, up: left ? 1.25 : 0.9, life: 5, size: 0.16, drag: 0.2 });
    }
    this.sigil.rotation.y += dt * 0.05;
    (this.sigil.material as THREE.MeshBasicMaterial).opacity = 0.25 + Math.sin(this.t * 0.9) * 0.05;
    const tx = still ? 0 : this.mouse.x * 1.4 + Math.sin(this.t * 0.1) * 0.4;
    const ty = still ? 1.6 : 1.6 - this.mouse.y * 0.6;
    this.camera.position.x += (tx - this.camera.position.x) * 0.03;
    this.camera.position.y += (ty - this.camera.position.y) * 0.03;
    this.camera.lookAt(window.innerWidth < 640 ? -9 : 0, 2, -20);
    this.effects.update(dt, this.camera, window.innerHeight * getRuntime().renderer.getPixelRatio());
  }

  dispose() {
    window.removeEventListener('pointermove', this.onMove);
    this.effects.dispose();
    this.scene.clear();
  }
}
