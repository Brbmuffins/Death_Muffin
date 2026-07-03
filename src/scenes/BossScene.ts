import * as THREE from 'three';
import type { GameScene } from './SceneManager';
import { createRenderer, fitToWindow } from '../graphics/renderer';
import { saveInventory } from '../net/api';
import type { InventorySlot } from '../net/types';
import { addToSlots, toSavePayload } from '../gameplay/loot';
import { ClickToMove } from '../gameplay/movement';
import { abilitiesFor, type Ability } from '../gameplay/abilities';
import { RealtimeClient, type RemotePlayer } from '../net/realtime';
import { BossSimulation, type BossState, type BossEvent } from '../gameplay/boss';
import { classByIndex } from '../gameplay/classes';

const BOSS_ROOM_RADIUS = 16;
const MOVE_SPEED = 5;
const SEND_RATE_MS = 100;
const LERP_RATE = 12;
const BROADCAST_MS = 100;
const CONTACT_RANGE = 3.5;
const CONTACT_TICK_MS = 1000;
const CONTACT_DAMAGE = 15;
const SLAM_WARN_MS = 1500;
const SLAM_RADIUS = 5;
const SLAM_DAMAGE = 25;
const BOLT_TRAVEL_MS = 600;
const BOLT_HIT_RADIUS = 1.8;
const BOLT_DAMAGE = 20;
const PORTAL_RANGE = 1.8;
const XP_REWARD = 250;

const PHASE_COLORS: Record<1 | 2 | 3, number> = {
  1: 0x6d28d9,
  2: 0x9d174d,
  3: 0xdc2626,
};
const PHASE_EMISSIVE: Record<1 | 2 | 3, number> = { 1: 0.4, 2: 0.9, 3: 1.6 };
const PHASE_NAMES: Record<1 | 2 | 3, string> = {
  1: 'THE VOID WARDEN',
  2: 'AWAKENED',
  3: 'ENRAGED',
};

interface RemoteEntity {
  player: RemotePlayer;
  mesh: THREE.Mesh;
  target: THREE.Vector3;
}

/** Single world-boss fight. Host simulates boss, broadcasts state + events at 10Hz. */
export class BossScene implements GameScene {
  private canvas = document.getElementById('scene') as HTMLCanvasElement;
  private root = document.getElementById('ui-root')!;
  private renderer: THREE.WebGLRenderer | null = null;
  private scene: THREE.Scene | null = null;
  private camera: THREE.PerspectiveCamera | null = null;
  private hudEl: HTMLDivElement | null = null;
  private raf = 0;

  private realtime = new RealtimeClient();
  private remotes = new Map<string, RemoteEntity>();
  private sim: BossSimulation | null = null; // host only
  private bossState: BossState = { hp: 800, maxHp: 800, phase: 1, x: 0, z: 0, alive: true };
  private bossMesh: THREE.Mesh | null = null;
  private bossMeshTarget = new THREE.Vector3();
  private pendingPhase: 1 | 2 | 3 = 1;

  private slots: InventorySlot[] = [];
  private savingLoot = false;
  private bossDeadHandled = false;

  private player: THREE.Mesh | null = null;
  private keys = new Set<string>();
  private mover = new ClickToMove(BOSS_ROOM_RADIUS - 1);
  private abilities: Ability[] = [];
  private cooldownUntil: Record<number, number> = { 1: 0, 2: 0, 3: 0, 4: 0 };
  private lastSent = 0;
  private lastSentPos = new THREE.Vector3(Infinity, 0, 0);
  private lastBroadcast = 0;
  private lastContactTick = 0;
  private portal: THREE.Mesh | null = null;

  private maxHp = 100;
  private hp = 100;
  private attackPower = 10;
  private xpEarned = 0;

  private vfxTextures = new Map<string, THREE.Texture>();
  private static readonly HIT_SPRITES: Record<string, string> = {
    '#f59e0b': 'art/vfx/hit-physical.png',
    '#a78bfa': 'art/vfx/hit-void.png',
    '#fde68a': 'art/vfx/hit-holy.png',
    '#60a5fa': 'art/vfx/hit-frost.png',
  };

  private onKeyDown = (e: KeyboardEvent) => {
    if (document.activeElement instanceof HTMLInputElement) return;
    if (e.key >= '1' && e.key <= '4') this.castAbility(Number(e.key) as 1 | 2 | 3 | 4);
    else this.keys.add(e.key.toLowerCase());
  };
  private onKeyUp = (e: KeyboardEvent) => this.keys.delete(e.key.toLowerCase());

  private onPointer = (e: PointerEvent) => {
    if (!this.camera || this.hp <= 0) return;
    if (e.type === 'pointerdown') {
      const p = this.mover.groundPoint(e, this.camera);
      if (p) this.mover.setTarget(p);
    } else if (e.type === 'pointermove' && e.buttons & 1) {
      const p = this.mover.groundPoint(e, this.camera);
      if (p) this.mover.setTarget(p);
    }
  };

  constructor(
    private character: any,
    private onExit: (xpEarned: number) => void,
  ) {}

  mount() {
    const scene = new THREE.Scene();
    this.scene = scene;
    scene.background = new THREE.Color(0x020008);
    scene.fog = new THREE.FogExp2(0x020008, 0.04);

    const camera = new THREE.PerspectiveCamera(50, window.innerWidth / window.innerHeight, 0.1, 200);
    this.camera = camera;

    // Ominous lighting — blood-red key + deep purple fill
    scene.add(new THREE.HemisphereLight(0x2d0a4e, 0x000000, 0.5));
    const key = new THREE.DirectionalLight(0xff2020, 1.2);
    key.position.set(4, 10, 4);
    scene.add(key);
    const fill = new THREE.DirectionalLight(0x6d28d9, 0.8);
    fill.position.set(-4, 6, -4);
    scene.add(fill);

    // Ground
    const ground = new THREE.Mesh(
      new THREE.CircleGeometry(BOSS_ROOM_RADIUS, 64),
      new THREE.MeshStandardMaterial({ color: 0x0c0010, roughness: 1 }),
    );
    ground.rotation.x = -Math.PI / 2;
    scene.add(ground);

    // Rune ring on floor
    const runeRing = new THREE.Mesh(
      new THREE.RingGeometry(BOSS_ROOM_RADIUS - 0.5, BOSS_ROOM_RADIUS, 64),
      new THREE.MeshBasicMaterial({ color: 0x6d28d9, side: THREE.DoubleSide }),
    );
    runeRing.rotation.x = -Math.PI / 2;
    runeRing.position.y = 0.02;
    scene.add(runeRing);

    // Pillars around the perimeter
    for (let i = 0; i < 8; i++) {
      const angle = (i / 8) * Math.PI * 2;
      const pillar = new THREE.Mesh(
        new THREE.CylinderGeometry(0.4, 0.5, 5, 8),
        new THREE.MeshStandardMaterial({ color: 0x1a0030, roughness: 0.8 }),
      );
      pillar.position.set(
        Math.sin(angle) * (BOSS_ROOM_RADIUS - 1.5),
        2.5,
        Math.cos(angle) * (BOSS_ROOM_RADIUS - 1.5),
      );
      scene.add(pillar);
    }

    // Boss mesh — spiky crystalline void entity
    this.bossMesh = new THREE.Mesh(
      new THREE.IcosahedronGeometry(1.8, 1),
      new THREE.MeshStandardMaterial({
        color: PHASE_COLORS[1],
        emissive: new THREE.Color(PHASE_COLORS[1]),
        emissiveIntensity: PHASE_EMISSIVE[1],
        roughness: 0.2,
        metalness: 0.8,
      }),
    );
    this.bossMesh.position.set(0, 2.0, 0);
    scene.add(this.bossMesh);

    // Exit portal
    this.portal = new THREE.Mesh(
      new THREE.TorusGeometry(1.0, 0.1, 12, 32),
      new THREE.MeshStandardMaterial({ color: 0xffffff, emissive: 0xffffff, emissiveIntensity: 0.5 }),
    );
    this.portal.position.set(0, 1.2, BOSS_ROOM_RADIUS - 2);
    scene.add(this.portal);

    // Player
    const classColor = new THREE.Color(classByIndex(this.character?.class_index ?? 0).color);
    this.player = new THREE.Mesh(
      new THREE.CapsuleGeometry(0.5, 1.2, 4, 8),
      new THREE.MeshStandardMaterial({ color: classColor, emissive: classColor, emissiveIntensity: 0.15 }),
    );
    this.player.position.set(0, 1.1, BOSS_ROOM_RADIUS - 3.5);
    scene.add(this.player);

    this.abilities = abilitiesFor(this.character?.class_index ?? 1);
    const { total } = this.computeStats();
    this.maxHp = 100 + total.vit * 2;
    this.attackPower = 10 + total.str + total.int;
    this.hp = this.maxHp;

    this.renderer = createRenderer(this.canvas);
    fitToWindow(this.renderer, camera);

    window.addEventListener('keydown', this.onKeyDown);
    window.addEventListener('keyup', this.onKeyUp);
    this.canvas.addEventListener('pointerdown', this.onPointer);
    this.canvas.addEventListener('pointermove', this.onPointer);

    const camOffset = new THREE.Vector3(0, 12, 7);
    const clock = new THREE.Clock();
    const animate = () => {
      this.raf = requestAnimationFrame(animate);
      const dt = Math.min(clock.getDelta(), 0.1);
      const now = performance.now();
      this.updateMovement(dt, now);
      this.updateRemotes(dt);
      this.updateBoss(dt, now);
      this.updateContactDamage(now);
      this.updateCooldownBar(now);
      this.checkPortal();
      camera.position.copy(this.player!.position).add(camOffset);
      camera.lookAt(this.player!.position.x, 0.5, this.player!.position.z);
      this.portal!.rotation.y += dt * 0.8;
      this.renderer!.render(scene, camera);
    };
    animate();

    this.mountHud();
    this.loadSlots();
    this.connectRealtime();
  }

  private computeStats() {
    const base = {
      str: this.character?.stat_str ?? 5,
      agi: this.character?.stat_agi ?? 5,
      int: this.character?.stat_int ?? 5,
      vit: this.character?.stat_vit ?? 10,
    };
    const bonus = { str: 0, agi: 0, int: 0, vit: 0 };
    for (const slot of this.slots) {
      if (slot.equipped && slot.stat_bonus) {
        for (const k of Object.keys(bonus) as (keyof typeof bonus)[]) {
          bonus[k] += slot.stat_bonus[k] ?? 0;
        }
      }
    }
    const total = { str: base.str + bonus.str, agi: base.agi + bonus.agi, int: base.int + bonus.int, vit: base.vit + bonus.vit };
    return { total, bonus };
  }

  // --- Realtime ---

  private async connectRealtime() {
    try {
      const others = await this.realtime.connect(
        {
          room: 'boss',
          characterId: this.character.id,
          classIndex: this.character.class_index ?? 0,
          x: this.player!.position.x,
          y: this.player!.position.y,
          z: this.player!.position.z,
          orientation: this.player!.rotation.y,
        },
        {
          onPlayerJoin: (p) => { this.addRemote(p); this.sim?.setPlayerPos(p.id, { x: p.x, z: p.z }); },
          onPlayerLeave: (id) => {
            const r = this.remotes.get(id);
            if (r) { this.scene?.remove(r.mesh); this.remotes.delete(id); }
            this.sim?.removePlayer(id);
          },
          onPlayerMove: (u) => {
            const r = this.remotes.get(u.id);
            if (r) r.target.set(u.x, 1.1, u.z);
            this.sim?.setPlayerPos(u.id, { x: u.x, z: u.z });
          },
          onChat: () => {},
          onDisconnect: () => { for (const r of this.remotes.values()) this.scene?.remove(r.mesh); this.remotes.clear(); },
          onArenaEvent: (ev: any) => this.onBossEvent(ev),
          onHostChange: () => this.ensureHostSim(),
        },
      );
      others.forEach((p) => { this.addRemote(p); this.sim?.setPlayerPos(p.id, { x: p.x, z: p.z }); });
      this.ensureHostSim();
    } catch {
      this.ensureHostSim(); // solo mode
    }
  }

  private ensureHostSim() {
    const shouldSim = !this.realtime.connected || this.realtime.isHost;
    if (shouldSim && !this.sim) {
      this.sim = new BossSimulation();
      if (this.player) this.sim.setPlayerPos('local', { x: this.player.position.x, z: this.player.position.z });
    }
  }

  private addRemote(p: RemotePlayer) {
    if (this.remotes.has(p.id) || !this.scene) return;
    const c = new THREE.Color(classByIndex(p.classIndex).color);
    const mesh = new THREE.Mesh(
      new THREE.CapsuleGeometry(0.5, 1.2, 4, 8),
      new THREE.MeshStandardMaterial({ color: c, emissive: c, emissiveIntensity: 0.15 }),
    );
    mesh.position.set(p.x, 1.1, p.z);
    this.scene.add(mesh);
    this.remotes.set(p.id, { player: p, mesh, target: new THREE.Vector3(p.x, 1.1, p.z) });
  }

  private onBossEvent(ev: any) {
    if (ev.type === 'boss:state' && !this.sim) {
      this.applyBossState(ev.state as BossState);
      if (ev.events) for (const e of ev.events) this.applyBossAttack(e);
    } else if (ev.type === 'boss:hit' && this.sim) {
      this.sim.applyHit(Number(ev.dmg) || 0);
    }
  }

  // --- Movement ---

  private updateMovement(dt: number, now: number) {
    if (!this.player) return;
    const dir = new THREE.Vector3(
      (this.keys.has('d') || this.keys.has('arrowright') ? 1 : 0) -
        (this.keys.has('a') || this.keys.has('arrowleft') ? 1 : 0),
      0,
      (this.keys.has('s') || this.keys.has('arrowdown') ? 1 : 0) -
        (this.keys.has('w') || this.keys.has('arrowup') ? 1 : 0),
    );
    if (dir.lengthSq() > 0) {
      this.mover.clear();
      dir.normalize().multiplyScalar(MOVE_SPEED * dt);
      this.player.position.add(dir);
      const flat = new THREE.Vector2(this.player.position.x, this.player.position.z);
      if (flat.length() > BOSS_ROOM_RADIUS - 1) { flat.setLength(BOSS_ROOM_RADIUS - 1); this.player.position.x = flat.x; this.player.position.z = flat.y; }
      this.player.rotation.y = Math.atan2(dir.x, dir.z);
    } else {
      this.mover.update(this.player, MOVE_SPEED, dt);
    }

    if (this.sim) this.sim.setPlayerPos('local', { x: this.player.position.x, z: this.player.position.z });

    if (this.realtime.connected && now - this.lastSent >= SEND_RATE_MS &&
        this.player.position.distanceToSquared(this.lastSentPos) > 1e-6) {
      this.lastSent = now;
      this.lastSentPos.copy(this.player.position);
      this.realtime.sendMove({ x: this.player.position.x, y: this.player.position.y, z: this.player.position.z, orientation: this.player.rotation.y });
    }
  }

  private updateRemotes(dt: number) {
    const t = Math.min(1, LERP_RATE * dt);
    for (const r of this.remotes.values()) r.mesh.position.lerp(r.target, t);
  }

  // --- Boss simulation & rendering ---

  private updateBoss(dt: number, now: number) {
    if (!this.bossMesh) return;

    // Pulsing float animation
    this.bossMesh.position.y = 2.0 + Math.sin(now * 0.002) * 0.3;
    this.bossMesh.rotation.y += dt * (this.bossState.phase === 3 ? 1.8 : 0.6);
    this.bossMesh.rotation.x += dt * 0.3;

    // Lerp mesh to boss position
    this.bossMeshTarget.set(this.bossState.x, this.bossMesh.position.y, this.bossState.z);
    this.bossMesh.position.lerp(this.bossMeshTarget, Math.min(1, LERP_RATE * dt));
    this.bossMesh.position.y = 2.0 + Math.sin(now * 0.002) * 0.3;

    // Phase visual change
    if (this.bossState.phase !== this.pendingPhase) {
      this.pendingPhase = this.bossState.phase;
      const mat = this.bossMesh.material as THREE.MeshStandardMaterial;
      mat.color.setHex(PHASE_COLORS[this.bossState.phase]);
      mat.emissive.setHex(PHASE_COLORS[this.bossState.phase]);
      mat.emissiveIntensity = PHASE_EMISSIVE[this.bossState.phase];
      this.showPhaseAnnounce(PHASE_NAMES[this.bossState.phase]);
    }

    this.refreshBossBar();

    if (!this.sim) return;

    // Host: tick simulation, broadcast state + events
    const events = this.sim.tick(now, dt);
    const state = this.sim.getState();
    this.applyBossState(state);
    for (const e of events) this.applyBossAttack(e);

    if (now - this.lastBroadcast >= BROADCAST_MS) {
      this.lastBroadcast = now;
      this.realtime.sendArenaEvent({ type: 'boss:state', state, events });
    }
  }

  private applyBossState(state: BossState) {
    this.bossState = state;
    if (state.alive === false && !this.bossDeadHandled) this.onBossDeath();
  }

  private applyBossAttack(event: BossEvent) {
    if (event.type === 'slam') this.spawnSlamWarning(event);
    else if (event.type === 'bolt') this.spawnBolt(event);
    else if (event.type === 'enrage') this.spawnEnrageEffect();
  }

  // --- Boss attack VFX + local damage ---

  private spawnSlamWarning(event: BossEvent) {
    if (!this.scene) return;
    // Red warning ring
    const warnMat = new THREE.MeshBasicMaterial({ color: 0xff2020, transparent: true, opacity: 0.5, side: THREE.DoubleSide });
    const warnMesh = new THREE.Mesh(new THREE.CircleGeometry(SLAM_RADIUS, 48), warnMat);
    warnMesh.rotation.x = -Math.PI / 2;
    warnMesh.position.set(event.x, 0.05, event.z);
    this.scene.add(warnMesh);

    // Pulse + then deal damage
    const started = performance.now();
    const pulse = () => {
      const t = (performance.now() - started) / SLAM_WARN_MS;
      if (t >= 1 || !this.scene) {
        this.scene?.remove(warnMesh);
        warnMat.dispose();
        // Damage check
        if (this.hp > 0) {
          const dx = this.player!.position.x - event.x;
          const dz = this.player!.position.z - event.z;
          if (Math.sqrt(dx * dx + dz * dz) <= SLAM_RADIUS) {
            this.hp = Math.max(0, this.hp - SLAM_DAMAGE);
            this.spawnDamageText(this.player!.position, `-${SLAM_DAMAGE}`, '#ff4444');
            this.refreshHud();
            if (this.hp <= 0) this.onPlayerDeath();
          }
        }
        // Expanding impact ring
        this.spawnImpactRing(new THREE.Vector3(event.x, 0.1, event.z), SLAM_RADIUS, 0xff2020);
        return;
      }
      warnMat.opacity = 0.3 + 0.4 * Math.abs(Math.sin(t * Math.PI * 4));
      requestAnimationFrame(pulse);
    };
    pulse();
  }

  private spawnBolt(event: BossEvent) {
    if (!this.scene || !this.player) return;
    const from = new THREE.Vector3(event.x, 2.0, event.z);
    const to = new THREE.Vector3(event.targetX ?? this.player.position.x, 0.5, event.targetZ ?? this.player.position.z);

    const mat = new THREE.LineBasicMaterial({ color: 0x9d174d, transparent: true });
    const geo = new THREE.BufferGeometry().setFromPoints([from, to]);
    const line = new THREE.Line(geo, mat);
    this.scene.add(line);

    const started = performance.now();
    const travel = () => {
      const t = (performance.now() - started) / BOLT_TRAVEL_MS;
      if (t >= 1 || !this.scene) {
        this.scene?.remove(line);
        geo.dispose(); mat.dispose();
        // Damage if player close to impact point
        if (this.hp > 0) {
          const dx = this.player!.position.x - to.x;
          const dz = this.player!.position.z - to.z;
          if (Math.sqrt(dx * dx + dz * dz) <= BOLT_HIT_RADIUS) {
            this.hp = Math.max(0, this.hp - BOLT_DAMAGE);
            const fakeAbility = { color: '#9d174d' } as any;
            this.spawnHitSprite(this.player!.position, fakeAbility, 1.4);
            this.spawnDamageText(this.player!.position, `-${BOLT_DAMAGE}`, '#ff4444');
            this.refreshHud();
            if (this.hp <= 0) this.onPlayerDeath();
          }
        }
        return;
      }
      mat.opacity = 1 - t * 0.5;
      requestAnimationFrame(travel);
    };
    travel();
  }

  private spawnImpactRing(pos: THREE.Vector3, maxRadius: number, color: number) {
    if (!this.scene) return;
    const mat = new THREE.MeshBasicMaterial({ color, transparent: true, side: THREE.DoubleSide });
    const ring = new THREE.Mesh(new THREE.RingGeometry(maxRadius * 0.8, maxRadius, 48), mat);
    ring.rotation.x = -Math.PI / 2;
    ring.position.copy(pos);
    this.scene.add(ring);
    const started = performance.now();
    const fade = () => {
      const t = (performance.now() - started) / 500;
      if (t >= 1 || !this.scene) { this.scene?.remove(ring); ring.geometry.dispose(); mat.dispose(); return; }
      mat.opacity = (1 - t) * 0.8;
      requestAnimationFrame(fade);
    };
    fade();
  }

  private spawnEnrageEffect() {
    this.showPhaseAnnounce('⚠ ENRAGE ⚠');
    if (!this.bossMesh) return;
    const mat = this.bossMesh.material as THREE.MeshStandardMaterial;
    // Flash white
    mat.emissive.setHex(0xffffff);
    setTimeout(() => mat.emissive.setHex(PHASE_COLORS[3]), 400);
  }

  // --- Boss death ---

  private async onBossDeath() {
    this.bossDeadHandled = true;
    if (!this.bossMesh || !this.scene) return;

    // Death burst
    const deathPos = this.bossMesh.position.clone();
    this.spawnImpactRing(deathPos, 8, 0x9d174d);
    this.spawnImpactRing(deathPos.clone(), 5, 0xffffff);
    this.scene.remove(this.bossMesh);
    this.bossMesh = null;

    this.toast('The Void Warden has fallen!');
    this.xpEarned = XP_REWARD;

    // Guaranteed boss loot
    if (!this.savingLoot) {
      this.savingLoot = true;
      try {
        const drops = [
          { item_id: 'ring_copper', quantity: 1 },
          { item_id: 'material_copper_bar', quantity: 2 },
          { item_id: 'material_copper_shard', quantity: 3 },
        ];
        let slots = this.slots;
        for (const drop of drops) slots = addToSlots(slots, drop) ?? slots;
        await saveInventory(this.character.id, toSavePayload(slots));
        this.slots = slots;
      } catch { /* silently fail */ }
      this.savingLoot = false;
    }

    // Return to hub after celebration
    setTimeout(() => this.onExit(this.xpEarned), 3000);
  }

  // --- Player contact damage ---

  private updateContactDamage(now: number) {
    if (this.hp <= 0 || !this.bossState.alive || now - this.lastContactTick < CONTACT_TICK_MS) return;
    if (!this.player || !this.bossMesh) return;
    const dx = this.player.position.x - this.bossState.x;
    const dz = this.player.position.z - this.bossState.z;
    if (Math.sqrt(dx * dx + dz * dz) <= CONTACT_RANGE) {
      this.lastContactTick = now;
      this.hp = Math.max(0, this.hp - CONTACT_DAMAGE);
      this.spawnDamageText(this.player.position, `-${CONTACT_DAMAGE}`, '#ff4444');
      this.refreshHud();
      if (this.hp <= 0) this.onPlayerDeath();
    }
  }

  private onPlayerDeath() {
    this.toast('You fall before the Warden — returning to the entrance');
    setTimeout(() => {
      this.player!.position.set(0, 1.1, BOSS_ROOM_RADIUS - 3.5);
      this.hp = this.maxHp;
      this.refreshHud();
    }, 1500);
  }

  // --- Abilities ---

  private castAbility(slot: 1 | 2 | 3 | 4) {
    const now = performance.now();
    const ability = this.abilities[slot - 1];
    if (!ability || this.hp <= 0 || now < this.cooldownUntil[slot] || !this.bossState.alive) return;
    this.cooldownUntil[slot] = now + ability.cooldownMs;

    if (ability.kind === 'nova' || ability.kind === 'ult') {
      const bossDist = Math.hypot(this.bossState.x - this.player!.position.x, this.bossState.z - this.player!.position.z);
      if (bossDist <= ability.range) {
        const dmg = Math.round(this.attackPower * ability.damageMult);
        this.applyDamageToBoss(dmg, ability);
      }
      this.spawnNovaRing(ability);
      return;
    }

    // Strike / heavy — check boss in range
    const bossDist = Math.hypot(this.bossState.x - this.player!.position.x, this.bossState.z - this.player!.position.z);
    if (bossDist > ability.range) return;
    const dmg = Math.round(this.attackPower * ability.damageMult);
    if (ability.ranged) this.spawnBossHitBolt(ability);
    this.applyDamageToBoss(dmg, ability);
  }

  private applyDamageToBoss(dmg: number, ability: Ability) {
    if (this.sim) {
      this.sim.applyHit(dmg);
    } else {
      this.realtime.sendArenaEvent({ type: 'boss:hit', dmg });
    }
    if (this.bossMesh) {
      const mat = this.bossMesh.material as THREE.MeshStandardMaterial;
      mat.emissiveIntensity = 3.0;
      setTimeout(() => { if (this.bossMesh) (this.bossMesh.material as THREE.MeshStandardMaterial).emissiveIntensity = PHASE_EMISSIVE[this.bossState.phase]; }, 120);
    }
    this.spawnHitSprite(new THREE.Vector3(this.bossState.x, 2.0, this.bossState.z), ability);
    this.spawnDamageText(new THREE.Vector3(this.bossState.x, 2.0, this.bossState.z), `${dmg}`, ability.color);
  }

  private spawnBossHitBolt(ability: Ability) {
    if (!this.scene || !this.player) return;
    const from = this.player.position.clone().setY(1.2);
    const to = new THREE.Vector3(this.bossState.x, 2.0, this.bossState.z);
    const mat = new THREE.LineBasicMaterial({ color: ability.color, transparent: true });
    const geo = new THREE.BufferGeometry().setFromPoints([from, to]);
    const line = new THREE.Line(geo, mat);
    this.scene.add(line);
    const started = performance.now();
    const fade = () => {
      const t = (performance.now() - started) / 200;
      if (t >= 1 || !this.scene) { this.scene?.remove(line); geo.dispose(); mat.dispose(); return; }
      mat.opacity = 1 - t;
      requestAnimationFrame(fade);
    };
    fade();
  }

  private spawnNovaRing(ability: Ability) {
    if (!this.scene || !this.player) return;
    const mat = new THREE.MeshBasicMaterial({ color: ability.color, transparent: true, side: THREE.DoubleSide });
    const ring = new THREE.Mesh(new THREE.RingGeometry(0.9, 1, 48), mat);
    ring.rotation.x = -Math.PI / 2;
    ring.position.copy(this.player.position).setY(0.05);
    this.scene.add(ring);
    const started = performance.now();
    const grow = () => {
      const t = (performance.now() - started) / 350;
      if (t >= 1 || !this.scene) { this.scene?.remove(ring); ring.geometry.dispose(); mat.dispose(); return; }
      const s = 1 + t * ability.range;
      ring.scale.set(s, s, 1);
      mat.opacity = 1 - t;
      requestAnimationFrame(grow);
    };
    grow();
  }

  // --- Shared VFX (same as ArenaScene) ---

  private spawnHitSprite(pos: THREE.Vector3, ability: { color: string }, baseScale = 1.8) {
    if (!this.scene) return;
    const path = BossScene.HIT_SPRITES[ability.color] ?? 'art/vfx/hit-void.png';
    let tex = this.vfxTextures.get(path);
    if (!tex) { tex = new THREE.TextureLoader().load(path); this.vfxTextures.set(path, tex); }
    const mat = new THREE.SpriteMaterial({ map: tex, transparent: true, blending: THREE.AdditiveBlending, depthWrite: false });
    const sprite = new THREE.Sprite(mat);
    sprite.position.copy(pos);
    sprite.scale.set(0.01, 0.01, 0.01);
    this.scene.add(sprite);
    const started = performance.now();
    const tick = () => {
      const t = (performance.now() - started) / 280;
      if (t >= 1 || !this.scene) { this.scene?.remove(sprite); mat.dispose(); return; }
      const s = baseScale * Math.sin(t * Math.PI);
      sprite.scale.set(s, s, s);
      mat.opacity = t < 0.25 ? 1 : 1 - (t - 0.25) / 0.75;
      requestAnimationFrame(tick);
    };
    tick();
  }

  private spawnDamageText(worldPos: THREE.Vector3, text: string, color: string) {
    if (!this.camera) return;
    const proj = worldPos.clone().project(this.camera);
    const el = document.createElement('div');
    el.className = 'cw-dmg-num';
    el.style.cssText = `left:${(proj.x * 0.5 + 0.5) * window.innerWidth}px;top:${(-proj.y * 0.5 + 0.5) * window.innerHeight}px;color:${color};font-size:${text.startsWith('-') ? '14' : '18'}px`;
    el.textContent = text;
    document.body.appendChild(el);
    setTimeout(() => el.remove(), 900);
  }

  // --- Portal ---

  private checkPortal() {
    if (!this.portal || this.hp <= 0 || this.bossState.alive) return;
    if (Math.hypot(this.player!.position.x - this.portal.position.x, this.player!.position.z - this.portal.position.z) < PORTAL_RANGE) {
      this.onExit(this.xpEarned);
    }
  }

  // --- HUD ---

  private mountHud() {
    this.hudEl = document.createElement('div');
    this.hudEl.innerHTML = `
      <div class="cw-boss-bar">
        <div class="cw-boss-name" data-boss-name>THE VOID WARDEN</div>
        <div class="cw-boss-hp-track">
          <div class="fill" data-boss-fill style="width:100%"></div>
          <div class="phase-mark" style="left:50%"></div>
          <div class="phase-mark" style="left:25%"></div>
        </div>
        <div class="cw-boss-phase" data-boss-phase>Phase 1</div>
      </div>
      <div class="cw-phase-announce" data-phase-announce></div>
      <div class="cw-hud">
        <div class="pill">${this.character?.class_name ?? 'Character'}</div>
        <div class="pill hp"><div class="cw-hpbar"><div class="fill" data-hp-fill></div></div><span data-hp-text></span></div>
      </div>
      <div class="cw-abilitybar" data-abilities>
        ${this.abilities.map((a) => `
          <button class="cw-ability" data-slot="${a.slot}" title="${a.name}" style="--ability-color:${a.color}">
            <span class="key">${a.slot}</span>
            <span class="icon"><img src="${a.iconPng}" alt="${a.name}" onerror="this.style.display='none';this.parentElement.dataset.fallback='${a.icon}'"></span>
            <span class="cd" data-cd="${a.slot}"></span>
          </button>`).join('')}
      </div>
      <div class="cw-hint">Click to move · 1–4 abilities · Boss: 800 HP · Portal appears on kill</div>
      <div class="cw-toast" data-toast></div>
    `;
    this.root.appendChild(this.hudEl);
    this.hudEl.querySelectorAll<HTMLButtonElement>('[data-slot]').forEach((btn) => {
      btn.addEventListener('click', () => this.castAbility(Number(btn.dataset.slot) as 1 | 2 | 3 | 4));
    });
    this.refreshHud();
    this.refreshBossBar();
  }

  private refreshHud() {
    if (!this.hudEl) return;
    const fill = this.hudEl.querySelector<HTMLDivElement>('[data-hp-fill]');
    const text = this.hudEl.querySelector<HTMLSpanElement>('[data-hp-text]');
    if (fill) fill.style.width = `${(this.hp / this.maxHp) * 100}%`;
    if (text) text.textContent = `${this.hp}/${this.maxHp}`;
  }

  private refreshBossBar() {
    if (!this.hudEl) return;
    const fill = this.hudEl.querySelector<HTMLDivElement>('[data-boss-fill]');
    const phase = this.hudEl.querySelector<HTMLDivElement>('[data-boss-phase]');
    if (fill) fill.style.width = `${(this.bossState.hp / this.bossState.maxHp) * 100}%`;
    if (phase) phase.textContent = this.bossState.alive ? `Phase ${this.bossState.phase}` : 'DEFEATED';
  }

  private showPhaseAnnounce(text: string) {
    const el = this.hudEl?.querySelector<HTMLDivElement>('[data-phase-announce]');
    if (!el) return;
    el.textContent = text;
    el.classList.add('show');
    setTimeout(() => el.classList.remove('show'), 2500);
  }

  private updateCooldownBar(now: number) {
    if (!this.hudEl) return;
    for (const a of this.abilities) {
      const el = this.hudEl.querySelector<HTMLSpanElement>(`[data-cd="${a.slot}"]`);
      if (!el) continue;
      const remaining = this.cooldownUntil[a.slot] - now;
      el.style.height = remaining > 0 ? `${Math.min(100, (remaining / a.cooldownMs) * 100)}%` : '0';
    }
  }

  private toast(message: string) {
    const el = this.hudEl?.querySelector<HTMLDivElement>('[data-toast]');
    if (!el) return;
    el.textContent = message;
    el.classList.add('show');
    setTimeout(() => el.classList.remove('show'), 4000);
  }

  private async loadSlots() {
    try {
      const { getInventory } = await import('../net/api');
      this.slots = await getInventory(this.character.id);
      const { total } = this.computeStats();
      this.maxHp = 100 + total.vit * 2;
      this.attackPower = 10 + total.str + total.int;
    } catch { /* use defaults */ }
  }

  unmount() {
    cancelAnimationFrame(this.raf);
    this.realtime.disconnect();
    window.removeEventListener('keydown', this.onKeyDown);
    window.removeEventListener('keyup', this.onKeyUp);
    this.canvas.removeEventListener('pointerdown', this.onPointer);
    this.canvas.removeEventListener('pointermove', this.onPointer);
    this.hudEl?.remove();
    this.hudEl = null;
    this.remotes.clear();
    this.sim = null;
    this.bossMesh = null;
    this.portal = null;
    this.vfxTextures.forEach((t) => t.dispose());
    this.vfxTextures.clear();
    this.scene = null;
    this.player = null;
    this.renderer?.dispose();
    this.renderer = null;
  }
}

