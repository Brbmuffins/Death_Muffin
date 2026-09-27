import * as THREE from 'three';
import { fx } from './fxTextures';

type Vec3 = { x: number; y: number; z: number };

// ---------------------------------------------------------------------------
// Particles — one Points draw call per blend mode, CPU-simulated ring buffer.
// ---------------------------------------------------------------------------

const PARTICLE_VS = /* glsl */ `
  attribute float aSize;
  attribute float aAlpha;
  attribute vec3 aColor;
  varying float vAlpha;
  varying vec3 vColor;
  uniform float uScale;
  void main() {
    vec4 mv = modelViewMatrix * vec4(position, 1.0);
    gl_Position = projectionMatrix * mv;
    gl_PointSize = aSize * uScale / max(0.1, -mv.z);
    vAlpha = aAlpha;
    vColor = aColor;
  }
`;
const PARTICLE_FS = /* glsl */ `
  uniform sampler2D uMap;
  varying float vAlpha;
  varying vec3 vColor;
  void main() {
    vec4 t = texture2D(uMap, gl_PointCoord);
    if (t.a * vAlpha < 0.004) discard;
    gl_FragColor = vec4(vColor * t.rgb, t.a * vAlpha);
  }
`;

export interface EmitOptions {
  x: number;
  y: number;
  z: number;
  count: number;
  color: THREE.ColorRepresentation;
  /** Spawn jitter radius. */
  spread?: number;
  /** Radial speed. */
  speed?: number;
  /** Extra upward speed. */
  up?: number;
  life?: number;
  size?: number;
  gravity?: number;
  drag?: number;
  /** Shrink (1) or grow (-1) over life. */
  shrink?: number;
  /** Pull toward the emit point instead of bursting away (implosions). */
  inward?: boolean;
}

class ParticleSystem {
  readonly points: THREE.Points;
  private pos: Float32Array;
  private col: Float32Array;
  private size: Float32Array;
  private alpha: Float32Array;
  private vel: Float32Array;
  private life: Float32Array;
  private maxLife: Float32Array;
  private baseSize: Float32Array;
  private grav: Float32Array;
  private drag: Float32Array;
  private shrink: Float32Array;
  private cursor = 0;
  private material: THREE.ShaderMaterial;
  private tmp = new THREE.Color();

  constructor(private capacity: number, map: THREE.Texture, blending: THREE.Blending) {
    this.pos = new Float32Array(capacity * 3);
    this.col = new Float32Array(capacity * 3);
    this.size = new Float32Array(capacity);
    this.alpha = new Float32Array(capacity);
    this.vel = new Float32Array(capacity * 3);
    this.life = new Float32Array(capacity);
    this.maxLife = new Float32Array(capacity);
    this.baseSize = new Float32Array(capacity);
    this.grav = new Float32Array(capacity);
    this.drag = new Float32Array(capacity);
    this.shrink = new Float32Array(capacity);
    const geo = new THREE.BufferGeometry();
    geo.setAttribute('position', new THREE.BufferAttribute(this.pos, 3).setUsage(THREE.DynamicDrawUsage));
    geo.setAttribute('aColor', new THREE.BufferAttribute(this.col, 3).setUsage(THREE.DynamicDrawUsage));
    geo.setAttribute('aSize', new THREE.BufferAttribute(this.size, 1).setUsage(THREE.DynamicDrawUsage));
    geo.setAttribute('aAlpha', new THREE.BufferAttribute(this.alpha, 1).setUsage(THREE.DynamicDrawUsage));
    this.material = new THREE.ShaderMaterial({
      vertexShader: PARTICLE_VS,
      fragmentShader: PARTICLE_FS,
      uniforms: { uMap: { value: map }, uScale: { value: 400 } },
      transparent: true,
      depthWrite: false,
      blending,
    });
    this.points = new THREE.Points(geo, this.material);
    this.points.frustumCulled = false;
    this.points.renderOrder = 5;
  }

  emit(o: EmitOptions) {
    this.tmp.set(o.color);
    for (let n = 0; n < o.count; n++) {
      const i = this.cursor;
      this.cursor = (this.cursor + 1) % this.capacity;
      const a = Math.random() * Math.PI * 2;
      const r = (o.spread ?? 0.2) * Math.sqrt(Math.random());
      this.pos[i * 3] = o.x + Math.cos(a) * r;
      this.pos[i * 3 + 1] = o.y + (Math.random() - 0.5) * (o.spread ?? 0.2) * 0.5;
      this.pos[i * 3 + 2] = o.z + Math.sin(a) * r;
      const sp = (o.speed ?? 1) * (0.4 + Math.random() * 0.8);
      const va = o.inward ? a + Math.PI : Math.random() * Math.PI * 2;
      this.vel[i * 3] = Math.cos(va) * sp;
      this.vel[i * 3 + 1] = (o.up ?? 0.5) * (0.5 + Math.random());
      this.vel[i * 3 + 2] = Math.sin(va) * sp;
      const l = (o.life ?? 0.8) * (0.7 + Math.random() * 0.6);
      this.life[i] = l;
      this.maxLife[i] = l;
      this.baseSize[i] = (o.size ?? 0.3) * (0.7 + Math.random() * 0.6);
      this.grav[i] = o.gravity ?? 0;
      this.drag[i] = o.drag ?? 1.5;
      this.shrink[i] = o.shrink ?? 1;
      this.col[i * 3] = this.tmp.r;
      this.col[i * 3 + 1] = this.tmp.g;
      this.col[i * 3 + 2] = this.tmp.b;
    }
  }

  update(dt: number, scale: number) {
    this.material.uniforms.uScale.value = scale;
    for (let i = 0; i < this.capacity; i++) {
      if (this.life[i] <= 0) {
        this.alpha[i] = 0;
        continue;
      }
      this.life[i] -= dt;
      const t = 1 - Math.max(0, this.life[i]) / this.maxLife[i];
      const k = Math.max(0, 1 - this.drag[i] * dt);
      this.vel[i * 3] *= k;
      this.vel[i * 3 + 1] = this.vel[i * 3 + 1] * k - this.grav[i] * dt;
      this.vel[i * 3 + 2] *= k;
      this.pos[i * 3] += this.vel[i * 3] * dt;
      this.pos[i * 3 + 1] += this.vel[i * 3 + 1] * dt;
      this.pos[i * 3 + 2] += this.vel[i * 3 + 2] * dt;
      this.alpha[i] = t < 0.15 ? t / 0.15 : 1 - (t - 0.15) / 0.85;
      const sh = this.shrink[i];
      this.size[i] = this.baseSize[i] * (sh >= 0 ? 1 - sh * t * 0.7 : 1 + -sh * t);
    }
    const g = this.points.geometry;
    (g.attributes.position as THREE.BufferAttribute).needsUpdate = true;
    (g.attributes.aColor as THREE.BufferAttribute).needsUpdate = true;
    (g.attributes.aSize as THREE.BufferAttribute).needsUpdate = true;
    (g.attributes.aAlpha as THREE.BufferAttribute).needsUpdate = true;
  }
}

// ---------------------------------------------------------------------------
// Pooled transient meshes (decals, billboards, beams)
// ---------------------------------------------------------------------------

export interface DecalOptions {
  tex?: THREE.Texture;
  color: THREE.ColorRepresentation;
  x: number;
  z: number;
  /** Half-extent in world units. */
  r: number;
  y?: number;
  rot?: number;
  duration: number;
  opacity?: number;
  fadeIn?: number;
  fadeOut?: number;
  /** Radius multiplier at start → 1 at end. */
  growFrom?: number;
  spin?: number;
  blending?: THREE.Blending;
  /** Rectangular decals (cones) — width/length multipliers. */
  sx?: number;
  sz?: number;
  /** Anchor offset along local +z (cones apex at origin). */
  anchor?: number;
  follow?: () => { x: number; z: number } | null;
  pulse?: number;
  /** Seconds before the decal appears (duration counts after the delay). */
  delay?: number;
}

interface Transient {
  mesh: THREE.Mesh | THREE.Sprite;
  t: number;
  duration: number;
  update: (t: number, k: number, dt: number) => void;
  pool: THREE.Object3D[];
}

export interface Handle {
  kill(): void;
  readonly alive: boolean;
}

interface Projectile {
  mesh: THREE.Object3D;
  from: THREE.Vector3;
  to: () => Vec3 | null;
  lastTo: THREE.Vector3;
  speed: number;
  color: THREE.Color;
  trail: number;
  onArrive?: (p: THREE.Vector3) => void;
  arc: number;
  t: number;
  dist: number;
}

interface Spike {
  x: number;
  z: number;
  yaw: number;
  tilt: number;
  h: number;
  born: number;
  life: number;
}

/**
 * All transient visual effects, updated from the single runtime loop.
 */
export class Effects {
  readonly group = new THREE.Group();
  private additive: ParticleSystem;
  private smoke: ParticleSystem;
  private transients: Transient[] = [];
  private decalPool: THREE.Object3D[] = [];
  private spritePool: THREE.Object3D[] = [];
  private beamPool: THREE.Object3D[] = [];
  private projectiles: Projectile[] = [];
  private needlePool: THREE.Mesh[] = [];
  private orbPool: THREE.Mesh[] = [];
  private projectileDirection = new THREE.Vector3();
  private needleGeo = new THREE.ConeGeometry(0.085, 0.95, 5).rotateX(Math.PI / 2);
  private needleMat = new THREE.MeshStandardMaterial({
    color: 0xe8dfcc,
    emissive: 0xe9c98f,
    emissiveIntensity: 1.3,
    roughness: 0.5,
  });
  private orbGeo = new THREE.SphereGeometry(0.16, 10, 8);
  private spikes: Spike[] = [];
  private spikeMesh: THREE.InstancedMesh;
  private spikeDummy = new THREE.Object3D();
  private time = 0;
  private lights: { light: THREE.PointLight; t: number; life: number; peak: number }[] = [];

  constructor(scene: THREE.Scene) {
    this.additive = new ParticleSystem(3500, fx.glow(), THREE.AdditiveBlending);
    this.smoke = new ParticleSystem(900, fx.smoke(), THREE.NormalBlending);
    this.group.add(this.additive.points, this.smoke.points);
    const spikeGeo = new THREE.ConeGeometry(0.2, 1, 4).translate(0, 0.5, 0);
    this.spikeMesh = new THREE.InstancedMesh(
      spikeGeo,
      new THREE.MeshStandardMaterial({ color: 0xc9b99a, roughness: 0.85, metalness: 0, emissive: 0x3a0e10, emissiveIntensity: 0.5 }),
      320,
    );
    this.spikeMesh.count = 0;
    this.spikeMesh.castShadow = true;
    this.spikeMesh.frustumCulled = false;
    this.group.add(this.spikeMesh);
    // Fixed light count: toggling visibility would change NUM_POINT_LIGHTS and
    // force every lit material to recompile (visible hitches).
    for (let i = 0; i < 2; i++) {
      const light = new THREE.PointLight(0xa26bff, 0, 9, 1.6);
      this.group.add(light);
      this.lights.push({ light, t: 0, life: 0, peak: 0 });
    }
    scene.add(this.group);
  }

  emit(o: EmitOptions) {
    this.additive.emit(o);
  }

  emitSmoke(o: EmitOptions) {
    this.smoke.emit(o);
  }

  private take<T extends THREE.Object3D>(pool: THREE.Object3D[], make: () => T): T {
    const m = (pool.pop() as T | undefined) ?? make();
    m.visible = true;
    this.group.add(m);
    return m;
  }

  private add(tr: Transient): Handle {
    // Cosmetic meshes have a fixed ceiling even in dense co-op bursts. Game
    // callbacks live on projectiles, so retiring old visuals never drops hits.
    if (this.transients.length >= 160) {
      const old = this.transients.shift()!;
      old.t = old.duration;
      old.mesh.visible = false;
      this.group.remove(old.mesh);
      old.pool.push(old.mesh);
    }
    tr.update(tr.t, tr.t / tr.duration, 0);
    this.transients.push(tr);
    return {
      kill: () => {
        tr.t = tr.duration;
      },
      get alive() {
        return tr.t < tr.duration;
      },
    };
  }

  decal(o: DecalOptions): Handle {
    const mesh = this.take(this.decalPool, () => {
      const m = new THREE.Mesh(
        new THREE.PlaneGeometry(1, 1).rotateX(-Math.PI / 2),
        new THREE.MeshBasicMaterial({ transparent: true, depthWrite: false, side: THREE.DoubleSide }),
      );
      m.renderOrder = 2;
      return m;
    }) as THREE.Mesh;
    const mat = mesh.material as THREE.MeshBasicMaterial;
    mat.map = o.tex ?? fx.disc();
    mat.color.set(o.color);
    mat.blending = o.blending ?? THREE.AdditiveBlending;
    mat.needsUpdate = true;
    const base = o.opacity ?? 1;
    const fadeIn = o.fadeIn ?? 0.12;
    const fadeOut = o.fadeOut ?? 0.25;
    mesh.geometry.translate(0, 0, 0);
    const anchor = o.anchor ?? 0;
    let hidden = false;
    const place = () => {
      const f = o.follow?.();
      hidden = !!o.follow && !f;
      const x = f ? f.x : o.x;
      const z = f ? f.z : o.z;
      mesh.position.set(x + Math.sin(o.rot ?? 0) * anchor * o.r, o.y ?? 0.04, z + Math.cos(o.rot ?? 0) * anchor * o.r);
    };
    place();
    mesh.rotation.set(0, o.rot ?? 0, 0);
    const delay = o.delay ?? 0;
    if (delay) mat.opacity = 0;
    return this.add({
      mesh,
      t: -delay,
      duration: o.duration,
      pool: this.decalPool,
      update: (t, k) => {
        if (t < 0) {
          mat.opacity = 0;
          return;
        }
        if (o.follow) place();
        const grow = o.growFrom !== undefined ? o.growFrom + (1 - o.growFrom) * Math.min(1, k * 1.2) : 1;
        const s = o.r * 2 * grow;
        mesh.scale.set(s * (o.sx ?? 1), 1, s * (o.sz ?? 1));
        if (o.spin) mesh.rotation.y = (o.rot ?? 0) + o.spin * t;
        const inA = Math.min(1, t / fadeIn);
        const outA = Math.min(1, (o.duration - t) / fadeOut);
        const pulse = o.pulse ? 0.75 + 0.25 * Math.sin(t * o.pulse) : 1;
        mat.opacity = hidden ? 0 : base * Math.max(0, Math.min(inA, outA)) * pulse;
      },
    });
  }

  flash(o: { x: number; y: number; z: number; color: THREE.ColorRepresentation; size: number; duration: number; tex?: THREE.Texture }) {
    const sprite = this.take(this.spritePool, () => {
      const s = new THREE.Sprite(
        new THREE.SpriteMaterial({ transparent: true, depthWrite: false, blending: THREE.AdditiveBlending }),
      );
      s.renderOrder = 6;
      return s;
    }) as THREE.Sprite;
    const mat = sprite.material;
    mat.map = o.tex ?? fx.glow();
    mat.color.set(o.color);
    mat.needsUpdate = true;
    sprite.position.set(o.x, o.y, o.z);
    return this.add({
      mesh: sprite,
      t: 0,
      duration: o.duration,
      pool: this.spritePool,
      update: (_t, k) => {
        const s = o.size * (0.35 + 0.65 * Math.sin(Math.min(1, k * 1.4) * Math.PI * 0.5));
        sprite.scale.set(s, s, s);
        mat.opacity = k < 0.3 ? 1 : 1 - (k - 0.3) / 0.7;
      },
    });
  }

  /** Glowing tether from A to B (litany tethers, deacon raise beams). */
  beam(a: Vec3, b: () => Vec3 | null, color: THREE.ColorRepresentation, width: number, duration: number) {
    const mesh = this.take(this.beamPool, () => {
      const m = new THREE.Mesh(
        new THREE.CylinderGeometry(1, 1, 1, 6, 1, true).rotateX(Math.PI / 2),
        new THREE.MeshBasicMaterial({ transparent: true, depthWrite: false, blending: THREE.AdditiveBlending }),
      );
      m.renderOrder = 6;
      return m;
    }) as THREE.Mesh;
    const mat = mesh.material as THREE.MeshBasicMaterial;
    mat.color.set(color);
    const pa = new THREE.Vector3();
    const pb = new THREE.Vector3();
    return this.add({
      mesh,
      t: 0,
      duration,
      pool: this.beamPool,
      update: (t, k) => {
        const end = b();
        if (!end) return;
        pa.set(a.x, a.y, a.z);
        pb.set(end.x, end.y, end.z);
        const len = pa.distanceTo(pb);
        mesh.position.copy(pa).lerp(pb, 0.5);
        mesh.lookAt(pb);
        const w = width * (0.7 + 0.3 * Math.sin(t * 30));
        mesh.scale.set(w, w, len);
        mat.opacity = Math.min(1, (1 - k) * 2);
      },
    });
  }

  /** Transient coloured light for big casts. */
  lightFlash(x: number, y: number, z: number, color: THREE.ColorRepresentation, intensity: number, life = 0.35) {
    const slot = this.lights.reduce((a, b) => (a.t / (a.life || 1) > b.t / (b.life || 1) ? a : b));
    slot.light.position.set(x, y, z);
    slot.light.color.set(color);
    slot.t = 0;
    slot.life = life;
    slot.peak = intensity;
  }

  projectile(o: {
    from: Vec3;
    to: () => Vec3 | null;
    speed: number;
    color: THREE.ColorRepresentation;
    kind: 'needle' | 'orb';
    arc?: number;
    onArrive?: (p: THREE.Vector3) => void;
  }) {
    const mesh = o.kind === 'needle'
      ? this.needlePool.pop() ?? new THREE.Mesh(this.needleGeo, this.needleMat)
      : this.orbPool.pop() ?? new THREE.Mesh(
          this.orbGeo,
          new THREE.MeshBasicMaterial({ transparent: true, depthWrite: false, blending: THREE.AdditiveBlending }),
        );
    if (o.kind === 'orb') (mesh.material as THREE.MeshBasicMaterial).color.set(o.color);
    mesh.visible = true;
    mesh.position.set(o.from.x, o.from.y, o.from.z);
    this.group.add(mesh);
    const first = o.to();
    const lastTo = new THREE.Vector3(first?.x ?? o.from.x, first?.y ?? o.from.y, first?.z ?? o.from.z);
    this.projectiles.push({
      mesh,
      from: new THREE.Vector3(o.from.x, o.from.y, o.from.z),
      to: o.to,
      lastTo,
      speed: o.speed,
      color: new THREE.Color(o.color),
      trail: 0,
      onArrive: o.onArrive,
      arc: o.arc ?? 0,
      t: 0,
      dist: Math.max(0.1, lastTo.distanceTo(new THREE.Vector3(o.from.x, o.from.y, o.from.z))),
    });
  }

  /** A line of bone spikes erupting sequentially (Marrow Spear). */
  spikeLine(x: number, z: number, dirX: number, dirZ: number, length: number, width: number, sequential = true) {
    const yaw = Math.atan2(dirX, dirZ);
    const n = Math.round(length / 0.55);
    for (let i = 0; i < n; i++) {
      const d = 0.8 + i * 0.55;
      for (let j = 0; j < 2; j++) {
        const side = (Math.random() - 0.5) * width;
        this.spikes.push({
          x: x + dirX * d + Math.cos(yaw) * side,
          z: z + dirZ * d - Math.sin(yaw) * side,
          yaw: Math.random() * Math.PI,
          tilt: (Math.random() - 0.5) * 0.7,
          h: 0.8 + Math.random() * 0.9 + (i / n) * 0.4,
          born: this.time + (sequential ? i * 0.018 : 0),
          life: 0.7,
        });
      }
    }
    if (this.spikes.length > 300) this.spikes.splice(0, this.spikes.length - 300);
  }

  update(dt: number, camera: THREE.PerspectiveCamera, viewportHeight: number) {
    this.time += dt;
    const scale = (viewportHeight * 0.5) / Math.tan(THREE.MathUtils.degToRad(camera.fov) / 2);
    this.additive.update(dt, scale);
    this.smoke.update(dt, scale);

    for (let i = this.transients.length - 1; i >= 0; i--) {
      const tr = this.transients[i];
      tr.t += dt;
      if (tr.t >= tr.duration) {
        tr.mesh.visible = false;
        this.group.remove(tr.mesh);
        tr.pool.push(tr.mesh);
        this.transients.splice(i, 1);
        continue;
      }
      tr.update(tr.t, tr.t / tr.duration, dt);
    }

    for (let i = this.projectiles.length - 1; i >= 0; i--) {
      const p = this.projectiles[i];
      const target = p.to();
      if (target) p.lastTo.set(target.x, target.y, target.z);
      const pos = p.mesh.position;
      const toVec = this.projectileDirection.subVectors(p.lastTo, pos);
      const d = toVec.length();
      const step = p.speed * dt;
      p.t += dt;
      const arcProgress = Math.min(1, p.t * p.speed / p.dist);
      if ((p.arc ? arcProgress >= 1 : d <= step) || p.t > 3) {
        pos.copy(p.lastTo);
        this.group.remove(p.mesh);
        const mesh = p.mesh as THREE.Mesh;
        const pool = mesh.material === this.needleMat ? this.needlePool : this.orbPool;
        if (pool.length < 64) pool.push(mesh);
        else if (mesh.material !== this.needleMat) (mesh.material as THREE.Material).dispose();
        this.projectiles.splice(i, 1);
        p.onArrive?.(pos.clone());
        continue;
      }
      if (p.arc) {
        // Time-based travel keeps the arc from slowing itself down as its
        // raised visual position changes the remaining 3D distance.
        pos.copy(p.from).lerp(p.lastTo, arcProgress);
        pos.y += Math.sin(arcProgress * Math.PI) * p.arc * 0.1;
      } else pos.add(toVec.multiplyScalar(step / Math.max(0.001, d)));
      p.mesh.lookAt(p.lastTo);
      p.trail += dt;
      if (p.trail > 0.024) {
        p.trail = 0;
        this.additive.emit({ x: pos.x, y: pos.y, z: pos.z, count: 1, color: p.color, spread: 0.05, speed: 0.15, up: 0.1, life: 0.28, size: 0.32 });
      }
    }

    // Spikes: rise fast, hold, sink.
    let n = 0;
    for (let i = this.spikes.length - 1; i >= 0; i--) {
      const s = this.spikes[i];
      const age = this.time - s.born;
      if (age > s.life) {
        this.spikes.splice(i, 1);
        continue;
      }
      if (age < 0) continue;
      const rise = age < 0.08 ? age / 0.08 : age > s.life - 0.25 ? (s.life - age) / 0.25 : 1;
      this.spikeDummy.position.set(s.x, -0.1, s.z);
      this.spikeDummy.rotation.set(s.tilt, s.yaw, s.tilt * 0.5);
      this.spikeDummy.scale.set(1, Math.max(0.01, s.h * rise), 1);
      this.spikeDummy.updateMatrix();
      this.spikeMesh.setMatrixAt(n++, this.spikeDummy.matrix);
    }
    this.spikeMesh.count = n;
    this.spikeMesh.instanceMatrix.needsUpdate = true;

    for (const l of this.lights) {
      if (l.life <= 0) continue;
      l.t += dt;
      const k = l.t / l.life;
      if (k >= 1) {
        l.life = 0;
        l.light.intensity = 0;
      } else l.light.intensity = l.peak * (1 - k) * (1 - k);
    }
  }

  dispose() {
    const geometries = new Set<THREE.BufferGeometry>();
    const materials = new Set<THREE.Material>();
    const collect = (o: THREE.Object3D) => {
      const m = o as THREE.Mesh;
      if (m.geometry) geometries.add(m.geometry);
      const mat = m.material as THREE.Material | THREE.Material[] | undefined;
      if (Array.isArray(mat)) mat.forEach((x) => materials.add(x));
      else if (mat) materials.add(mat);
    };
    this.group.traverse(collect);
    // Expired pooled meshes are no longer children of the scene group, but
    // their GPU resources still belong to this Effects instance.
    for (const pool of [this.decalPool, this.spritePool, this.beamPool, this.needlePool, this.orbPool]) {
      for (const mesh of pool) collect(mesh);
      pool.length = 0;
    }
    geometries.add(this.needleGeo);
    geometries.add(this.orbGeo);
    materials.add(this.needleMat);
    for (const geometry of geometries) geometry.dispose();
    for (const material of materials) material.dispose();
    this.projectiles.length = 0;
    this.transients.length = 0;
    this.group.removeFromParent();
  }
}
