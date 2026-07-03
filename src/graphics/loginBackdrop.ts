import * as THREE from 'three';
import { createRenderer, fitToWindow } from './renderer';

// Palette pulled from the Crossworlds logo: crystal purple, ring teal, seal gold.
const CRYSTAL_COLORS = [0x8b5cf6, 0x6ee7ff, 0xc9a44a];
const CRYSTAL_COUNT = 90;

interface Crystal {
  mesh: THREE.Mesh;
  spin: THREE.Vector3;
  drift: number;
}

/**
 * Animated backdrop for the login / character-select screens: a slow-drifting
 * field of glowing crystal shards in the logo's palette, with subtle mouse
 * parallax. Purely atmospheric — no gameplay state.
 */
export class LoginBackdrop {
  private renderer: THREE.WebGLRenderer | null = null;
  private scene: THREE.Scene | null = null;
  private camera: THREE.PerspectiveCamera | null = null;
  private crystals: Crystal[] = [];
  private raf = 0;
  private mouse = new THREE.Vector2(0, 0);

  private onPointerMove = (e: PointerEvent) => {
    this.mouse.set(
      (e.clientX / window.innerWidth) * 2 - 1,
      (e.clientY / window.innerHeight) * 2 - 1,
    );
  };

  mount(canvas: HTMLCanvasElement) {
    const scene = new THREE.Scene();
    this.scene = scene;
    scene.background = new THREE.Color(0x04060c);
    scene.fog = new THREE.Fog(0x04060c, 10, 34);

    this.camera = new THREE.PerspectiveCamera(55, window.innerWidth / window.innerHeight, 0.1, 100);
    this.camera.position.set(0, 2, 14);

    scene.add(new THREE.AmbientLight(0x223044, 1.2));
    const glow = new THREE.PointLight(0x8b5cf6, 60, 40);
    glow.position.set(0, 4, 4);
    scene.add(glow);

    const geometry = new THREE.OctahedronGeometry(1);
    for (let i = 0; i < CRYSTAL_COUNT; i++) {
      const color = CRYSTAL_COLORS[i % CRYSTAL_COLORS.length];
      const mesh = new THREE.Mesh(
        geometry,
        new THREE.MeshStandardMaterial({
          color,
          emissive: color,
          emissiveIntensity: 0.45,
          roughness: 0.25,
          transparent: true,
          opacity: 0.85,
        }),
      );
      const s = 0.06 + Math.random() * 0.3;
      mesh.scale.set(s, s * (1.4 + Math.random()), s);
      mesh.position.set(
        (Math.random() - 0.5) * 36,
        Math.random() * 14 - 2,
        (Math.random() - 0.5) * 22,
      );
      mesh.rotation.set(Math.random() * Math.PI, Math.random() * Math.PI, Math.random() * Math.PI);
      scene.add(mesh);
      this.crystals.push({
        mesh,
        spin: new THREE.Vector3(Math.random() - 0.5, Math.random() - 0.5, Math.random() - 0.5)
          .multiplyScalar(0.6),
        drift: 0.2 + Math.random() * 0.5,
      });
    }

    this.renderer = createRenderer(canvas);
    fitToWindow(this.renderer, this.camera);
    window.addEventListener('pointermove', this.onPointerMove);

    const clock = new THREE.Clock();
    const animate = () => {
      const dt = Math.min(clock.getDelta(), 0.1);
      const t = clock.getElapsedTime();
      for (const c of this.crystals) {
        c.mesh.rotation.x += c.spin.x * dt;
        c.mesh.rotation.y += c.spin.y * dt;
        c.mesh.rotation.z += c.spin.z * dt;
        c.mesh.position.y += c.drift * dt;
        if (c.mesh.position.y > 12) c.mesh.position.y = -2;
      }
      // Mouse parallax + a slow ambient sway.
      const targetX = this.mouse.x * 1.6 + Math.sin(t * 0.12) * 0.6;
      const targetY = 2 - this.mouse.y * 1.0 + Math.cos(t * 0.09) * 0.3;
      this.camera!.position.x += (targetX - this.camera!.position.x) * 0.04;
      this.camera!.position.y += (targetY - this.camera!.position.y) * 0.04;
      this.camera!.lookAt(0, 3, 0);
      this.renderer!.render(scene, this.camera!);
      this.raf = requestAnimationFrame(animate);
    };
    animate();
  }

  unmount() {
    cancelAnimationFrame(this.raf);
    window.removeEventListener('pointermove', this.onPointerMove);
    for (const c of this.crystals) {
      (c.mesh.material as THREE.Material).dispose();
    }
    this.crystals[0]?.mesh.geometry.dispose();
    this.crystals = [];
    this.scene = null;
    this.camera = null;
    this.renderer?.dispose();
    this.renderer = null;
  }
}
