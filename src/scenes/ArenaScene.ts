import * as THREE from 'three';
import type { GameScene } from './SceneManager';
import { createRenderer, fitToWindow } from '../graphics/renderer';
import { getInventory, saveInventory } from '../net/api';
import type { InventorySlot } from '../net/types';
import { computeStats } from '../gameplay/stats';
import { classByIndex } from '../gameplay/classes';
import {
  EnemySimulation,
  type EnemyState,
  ENEMY_ATTACK_RANGE,
} from '../gameplay/enemies';
import { rollLoot, addToSlots, toSavePayload } from '../gameplay/loot';
import { ClickToMove } from '../gameplay/movement';
import { abilitiesFor, type Ability } from '../gameplay/abilities';
import { RealtimeClient, type RemotePlayer } from '../net/realtime';
import { CharacterModel, type AnimState } from '../graphics/CharacterModel';
import { MODEL_PATHS, CLASS_TO_MODEL } from '../graphics/modelPaths';

const ARENA_RADIUS = 12;
const MOVE_SPEED = 5;
const SEND_RATE_MS = 100;
const LERP_RATE = 12;
const ENEMY_DPS_TICK_MS = 800;
const ENEMY_HIT_DAMAGE = 5;
const PICKUP_RANGE = 1.3;
const PORTAL_RANGE = 1.6;
const BROADCAST_MS = 100;

const RARITY_COLORS: Record<string, number> = {
  common: 0xb8c2cc,
  uncommon: 0x4ade80,
  rare: 0x60a5fa,
  epic: 0xc084fc,
};

interface EnemyEntity {
  mesh: THREE.Mesh;
  hpBar: THREE.Sprite;
  state: EnemyState;
  target: THREE.Vector3;
}

interface LootEntity {
  mesh: THREE.Mesh;
  item_id: string;
  quantity: number;
}

interface RemoteEntity {
  player: RemotePlayer;
  mesh: THREE.Mesh;
  target: THREE.Vector3;
  targetOrientation: number;
}

/**
 * Arena combat slice (Phase 4). Simplifications, per plan: waypoint patrol
 * (no NavMesh), client-authoritative combat with the room host simulating
 * enemies (PvE-only assumption), per-player loot rolls.
 */
export class ArenaScene implements GameScene {
  private canvas = document.getElementById('scene') as HTMLCanvasElement;
  private root = document.getElementById('ui-root')!;
  private renderer: THREE.WebGLRenderer | null = null;
  private scene: THREE.Scene | null = null;
  private camera: THREE.PerspectiveCamera | null = null;
  private hudEl: HTMLDivElement | null = null;
  private raf = 0;

  private realtime = new RealtimeClient();
  private remotes = new Map<string, RemoteEntity>();
  private sim: EnemySimulation | null = null; // host only
  private enemies = new Map<number, EnemyEntity>();
  private loot: LootEntity[] = [];
  private slots: InventorySlot[] = [];
  private savingLoot = false;

  private player: THREE.Mesh | null = null;
  private playerModel: CharacterModel | null = null;
  private playerModelLastPos = new THREE.Vector3(Infinity, 0, 0);
  private playerModelState: AnimState = 'idle';
  private keys = new Set<string>();
  private mover = new ClickToMove(ARENA_RADIUS - 1);
  private abilities: Ability[] = [];
  private cooldownUntil: Record<number, number> = { 1: 0, 2: 0, 3: 0, 4: 0 };
  private attackTargetId: number | null = null;
  private lastSent = 0;
  private lastSentPos = new THREE.Vector3(Infinity, 0, 0);
  private lastBroadcast = 0;
  private lastEnemyTick = 0;

  private maxHp = 100;
  private hp = 100;
  private attackPower = 10;
  private kills = 0;
  private xpEarned = 0;
  private static readonly XP_PER_KILL = 10;

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

  // Diablo-style pointer: click an enemy to attack it, click ground to move.
  private onPointer = (e: PointerEvent) => {
    if (!this.camera || this.hp <= 0) return;
    if (e.type === 'pointerdown') {
      const enemyMeshes = [...this.enemies.values()].filter((en) => en.state.alive).map((en) => en.mesh);
      const hit = this.mover.pick(e, this.camera, enemyMeshes);
      if (hit) {
        const entity = [...this.enemies.values()].find((en) => en.mesh === hit);
        if (entity) {
          this.attackTargetId = entity.state.id;
          this.mover.clear();
          return;
        }
      }
      this.attackTargetId = null;
    } else if (!(e.buttons & 1)) {
      return;
    }
    if (this.attackTargetId !== null) return; // holding onto a target
    const p = this.mover.groundPoint(e, this.camera);
    if (p) this.mover.setTarget(p);
  };

  constructor(
    private character: any,
    private onReturnHub: (xpEarned: number) => void,
  ) {}

  mount() {
    const scene = new THREE.Scene();
    this.scene = scene;
    scene.background = new THREE.Color(0x0d0508);
    scene.fog = new THREE.Fog(0x0d0508, 10, 36);

    // Diablo-style top-down camera (user directive: mimic the Unity project).
    this.camera = new THREE.PerspectiveCamera(50, window.innerWidth / window.innerHeight, 0.1, 200);
    this.abilities = abilitiesFor(this.character?.class_index ?? 1);

    scene.add(new THREE.HemisphereLight(0xff9a6e, 0x1c1013, 0.55));
    const key = new THREE.DirectionalLight(0xffd9c2, 1.2);
    key.position.set(-5, 9, 3);
    key.castShadow = true;
    scene.add(key);

    const ground = new THREE.Mesh(
      new THREE.CircleGeometry(ARENA_RADIUS, 48),
      new THREE.MeshStandardMaterial({ color: 0x1a1114, roughness: 0.95 }),
    );
    ground.rotation.x = -Math.PI / 2;
    ground.receiveShadow = true;
    scene.add(ground);

    // Return portal at the entrance (+z edge).
    const portal = new THREE.Mesh(
      new THREE.TorusGeometry(1.2, 0.12, 12, 32),
      new THREE.MeshStandardMaterial({
        color: 0x6ee7ff,
        emissive: 0x6ee7ff,
        emissiveIntensity: 0.8,
      }),
    );
    portal.position.set(0, 1.4, ARENA_RADIUS - 1.5);
    scene.add(portal);
    this.portal = portal;

    this.player = this.makeCapsule(this.character?.class_index ?? 0);
    this.player.position.set(0, 1.1, ARENA_RADIUS - 3.5);
    scene.add(this.player);

    // Load real character model — hides capsule when ready
    const slug = CLASS_TO_MODEL[this.character?.class_index ?? 0];
    const paths = slug ? MODEL_PATHS[slug] : null;
    if (paths) {
      const model = new CharacterModel(paths);
      this.playerModel = model;
      scene.add(model.root);
      model.load().then(() => {
        if (this.player) this.player.visible = false;
      });
    }

    this.renderer = createRenderer(this.canvas);
    fitToWindow(this.renderer, this.camera);

    window.addEventListener('keydown', this.onKeyDown);
    window.addEventListener('keyup', this.onKeyUp);
    this.canvas.addEventListener('pointerdown', this.onPointer);
    this.canvas.addEventListener('pointermove', this.onPointer);

    this.mountHud();
    this.loadData();
    this.connectRealtime();

    const camOffset = new THREE.Vector3(0, 12, 7);
    const clock = new THREE.Clock();
    const animate = () => {
      const dt = Math.min(clock.getDelta(), 0.1);
      const now = performance.now();
      this.updateMovement(dt, now);
      this.updateAutoAttack(dt, now);
      this.updateSimulation(dt, now);
      this.updateEnemyMeshes(dt);
      this.updateRemotes(dt);
      this.updateLoot(dt, now);
      this.updateContactDamage(now);
      this.updateCooldownBar(now);
      this.checkPortal();
      this.portal!.rotation.y += dt * 0.8;
      this.updatePlayerModel(dt);
      this.camera!.position.copy(this.player!.position).add(camOffset);
      this.camera!.lookAt(this.player!.position.x, 0.5, this.player!.position.z);
      this.renderer!.render(scene, this.camera!);
      this.raf = requestAnimationFrame(animate);
    };
    animate();
  }

  private portal: THREE.Mesh | null = null;

  private updatePlayerModel(dt: number) {
    const model = this.playerModel;
    if (!model || !this.player) return;
    model.root.position.set(this.player.position.x, 0, this.player.position.z);
    model.root.rotation.y = this.player.rotation.y;
    model.update(dt);
    if (!model.loaded) return;
    const moved = this.player.position.distanceToSquared(this.playerModelLastPos) > 4e-4;
    if (moved) {
      this.playerModelLastPos.copy(this.player.position);
      if (this.playerModelState !== 'run') {
        this.playerModelState = 'run';
        model.setState('run');
      }
    } else if (this.playerModelState === 'run') {
      this.playerModelState = 'idle';
      model.setState('idle');
    }
  }

  private makeCapsule(classIndex: number): THREE.Mesh {
    const color = new THREE.Color(classByIndex(classIndex).color);
    const mesh = new THREE.Mesh(
      new THREE.CapsuleGeometry(0.5, 1.2, 4, 8),
      new THREE.MeshStandardMaterial({ color, emissive: color, emissiveIntensity: 0.15 }),
    );
    mesh.position.y = 1.1;
    mesh.castShadow = true;
    return mesh;
  }

  private makeEnemyEntity(state: EnemyState): EnemyEntity {
    const mesh = new THREE.Mesh(
      new THREE.SphereGeometry(0.7, 16, 12),
      new THREE.MeshStandardMaterial({
        color: 0x8b1e3f,
        emissive: 0x8b1e3f,
        emissiveIntensity: 0.25,
        roughness: 0.4,
      }),
    );
    mesh.position.set(state.x, 0.7, state.z);
    mesh.castShadow = true;
    this.scene!.add(mesh);

    const hpCanvas = document.createElement('canvas');
    hpCanvas.width = 64;
    hpCanvas.height = 8;
    const hpBar = new THREE.Sprite(
      new THREE.SpriteMaterial({ map: new THREE.CanvasTexture(hpCanvas), depthTest: false }),
    );
    hpBar.scale.set(1.4, 0.18, 1);
    hpBar.position.set(state.x, 1.8, state.z);
    this.scene!.add(hpBar);

    const entity: EnemyEntity = {
      mesh,
      hpBar,
      state,
      target: new THREE.Vector3(state.x, 0.7, state.z),
    };
    this.drawHpBar(entity);
    return entity;
  }

  private drawHpBar(e: EnemyEntity) {
    const canvas = (e.hpBar.material.map as THREE.CanvasTexture).image as HTMLCanvasElement;
    const ctx = canvas.getContext('2d')!;
    ctx.clearRect(0, 0, 64, 8);
    ctx.fillStyle = '#000';
    ctx.fillRect(0, 0, 64, 8);
    ctx.fillStyle = '#e34a5f';
    ctx.fillRect(1, 1, Math.max(0, (e.state.hp / e.state.maxHp) * 62), 6);
    (e.hpBar.material.map as THREE.CanvasTexture).needsUpdate = true;
  }

  // --- Data ---

  private async loadData() {
    try {
      this.slots = await getInventory(this.character.id);
    } catch {
      this.toast('Failed to load inventory — loot pickup disabled');
    }
    const { total } = computeStats(this.character, this.slots);
    this.maxHp = 50 + total.stat_vit * 5;
    this.hp = this.maxHp;
    this.attackPower = 8 + total.stat_str;
    this.refreshHud();
  }

  // --- Realtime ---

  private async connectRealtime() {
    try {
      const others = await this.realtime.connect(
        {
          room: 'arena',
          characterId: this.character.id,
          classIndex: this.character.class_index ?? 0,
          x: this.player!.position.x,
          y: this.player!.position.y,
          z: this.player!.position.z,
          orientation: 0,
        },
        {
          onPlayerJoin: (p) => {
            this.addRemote(p);
            this.refreshHud();
          },
          onPlayerLeave: (id) => {
            const r = this.remotes.get(id);
            if (r) {
              this.scene?.remove(r.mesh);
              this.remotes.delete(id);
              this.refreshHud();
            }
          },
          onPlayerMove: (u) => {
            const r = this.remotes.get(u.id);
            if (r) {
              r.target.set(u.x, 1.1, u.z);
              r.targetOrientation = u.orientation;
            }
          },
          onChat: () => {},
          onDisconnect: () => {
            for (const r of this.remotes.values()) this.scene?.remove(r.mesh);
            this.remotes.clear();
            this.ensureHostSim();
            this.refreshHud();
          },
          onArenaEvent: (ev) => this.onArenaEvent(ev),
          onHostChange: () => this.ensureHostSim(),
        },
      );
      others.forEach((p) => this.addRemote(p));
    } catch (err) {
      this.toast(err instanceof Error ? err.message : 'Realtime unavailable — solo arena');
    }
    this.ensureHostSim();
    this.refreshHud();
  }

  /** Host (or offline solo player) owns the simulation. */
  private ensureHostSim() {
    const shouldSimulate = !this.realtime.connected || this.realtime.isHost;
    if (shouldSimulate && !this.sim) {
      this.sim = new EnemySimulation(ARENA_RADIUS);
      this.applyEnemyStates(this.sim.snapshot(), true);
    } else if (!shouldSimulate && this.sim) {
      this.sim = null; // demoted (shouldn't happen; hosts only change on leave)
    }
  }

  private addRemote(p: RemotePlayer) {
    if (this.remotes.has(p.id) || !this.scene) return;
    const mesh = this.makeCapsule(p.classIndex);
    mesh.position.set(p.x, 1.1, p.z);
    this.scene.add(mesh);
    this.remotes.set(p.id, {
      player: p,
      mesh,
      target: new THREE.Vector3(p.x, 1.1, p.z),
      targetOrientation: p.orientation,
    });
  }

  private onArenaEvent(ev: any) {
    if (ev.type === 'enemies' && !this.sim) {
      this.applyEnemyStates(ev.enemies as EnemyState[], false);
    } else if (ev.type === 'hit' && this.sim) {
      this.sim.applyHit(Number(ev.enemyId), Number(ev.dmg) || 0);
    }
  }

  /** Reconcile enemy meshes with a state snapshot; detect deaths for loot/VFX. */
  private applyEnemyStates(states: EnemyState[], snap: boolean) {
    for (const state of states) {
      let entity = this.enemies.get(state.id);
      if (!entity) {
        entity = this.makeEnemyEntity(state);
        this.enemies.set(state.id, entity);
      }
      const wasAlive = entity.state.alive;
      entity.state = state;
      entity.target.set(state.x, 0.7, state.z);
      if (snap) entity.mesh.position.copy(entity.target);
      entity.mesh.visible = state.alive;
      entity.hpBar.visible = state.alive;
      this.drawHpBar(entity);
      if (wasAlive && !state.alive) this.onEnemyDeath(entity);
    }
  }

  private onEnemyDeath(entity: EnemyEntity) {
    this.kills++;
    // XP accumulates locally; POST /api/character/save-progress happens on hub
    // return (not per kill — matches the server design intent).
    this.xpEarned += ArenaScene.XP_PER_KILL;
    this.refreshHud();
    this.spawnDamageText(entity.mesh.position, 'DEAD', '#ff8a8a');
    const drop = rollLoot();
    if (drop) this.spawnLoot(entity.mesh.position, drop);
  }

  private spawnLoot(at: THREE.Vector3, drop: { item_id: string; quantity: number }) {
    const rarity = drop.item_id === 'ring_copper' ? 'uncommon' : 'common';
    const color = RARITY_COLORS[rarity];
    const mesh = new THREE.Mesh(
      new THREE.OctahedronGeometry(0.35),
      new THREE.MeshStandardMaterial({ color, emissive: color, emissiveIntensity: 0.6 }),
    );
    mesh.position.set(at.x, 0.8, at.z);
    this.scene!.add(mesh);
    this.loot.push({ mesh, item_id: drop.item_id, quantity: drop.quantity });
  }

  // --- Update loop pieces (order: input → sim → remote state → combat → camera) ---

  private updateMovement(dt: number, now: number) {
    if (!this.player || this.hp <= 0) return;
    const dir = new THREE.Vector3(
      (this.keys.has('d') || this.keys.has('arrowright') ? 1 : 0) -
        (this.keys.has('a') || this.keys.has('arrowleft') ? 1 : 0),
      0,
      (this.keys.has('s') || this.keys.has('arrowdown') ? 1 : 0) -
        (this.keys.has('w') || this.keys.has('arrowup') ? 1 : 0),
    );
    if (dir.lengthSq() > 0) {
      this.mover.clear(); // keyboard overrides click-to-move
      this.attackTargetId = null;
      dir.normalize().multiplyScalar(MOVE_SPEED * dt);
      this.player.position.add(dir);
      const flat = new THREE.Vector2(this.player.position.x, this.player.position.z);
      if (flat.length() > ARENA_RADIUS - 1) {
        flat.setLength(ARENA_RADIUS - 1);
        this.player.position.x = flat.x;
        this.player.position.z = flat.y;
      }
      this.player.rotation.y = Math.atan2(dir.x, dir.z);
    } else if (this.attackTargetId === null) {
      this.mover.update(this.player, MOVE_SPEED, dt);
    }

    if (
      this.realtime.connected &&
      now - this.lastSent >= SEND_RATE_MS &&
      this.player.position.distanceToSquared(this.lastSentPos) > 1e-6
    ) {
      this.lastSent = now;
      this.lastSentPos.copy(this.player.position);
      this.realtime.sendMove({
        x: this.player.position.x,
        y: this.player.position.y,
        z: this.player.position.z,
        orientation: this.player.rotation.y,
      });
    }
  }

  private updateSimulation(dt: number, now: number) {
    if (!this.sim) return;
    const players = [
      { id: this.realtime.selfId ?? 'self', x: this.player!.position.x, z: this.player!.position.z },
      ...[...this.remotes.values()].map((r) => ({
        id: r.player.id,
        x: r.mesh.position.x,
        z: r.mesh.position.z,
      })),
    ];
    this.sim.update(dt, players, now);
    this.applyEnemyStates(this.sim.snapshot(), false);
    if (this.realtime.connected && now - this.lastBroadcast >= BROADCAST_MS) {
      this.lastBroadcast = now;
      this.realtime.sendArenaEvent({ type: 'enemies', enemies: this.sim.snapshot() });
    }
  }

  private updateEnemyMeshes(dt: number) {
    const t = Math.min(1, LERP_RATE * dt);
    for (const e of this.enemies.values()) {
      if (!e.state.alive) continue;
      e.mesh.position.lerp(e.target, t);
      e.hpBar.position.set(e.mesh.position.x, 1.8, e.mesh.position.z);
    }
  }

  private updateRemotes(dt: number) {
    const t = Math.min(1, LERP_RATE * dt);
    for (const r of this.remotes.values()) {
      r.mesh.position.lerp(r.target, t);
      r.mesh.rotation.y += (r.targetOrientation - r.mesh.rotation.y) * t;
    }
  }

  private updateLoot(dt: number, _now: number) {
    for (let i = this.loot.length - 1; i >= 0; i--) {
      const l = this.loot[i];
      l.mesh.rotation.y += dt * 2;
      l.mesh.position.y = 0.8 + Math.sin(performance.now() / 400 + i) * 0.15;
      if (
        !this.savingLoot &&
        this.hp > 0 &&
        l.mesh.position.distanceTo(this.player!.position) < PICKUP_RANGE + 0.8
      ) {
        this.pickupLoot(l, i);
      }
    }
  }

  private async pickupLoot(l: LootEntity, index: number) {
    const next = addToSlots(this.slots, { item_id: l.item_id, quantity: l.quantity });
    if (!next) {
      this.toast('Bag full');
      return;
    }
    this.savingLoot = true;
    this.loot.splice(index, 1);
    this.scene!.remove(l.mesh);
    try {
      // Full slot array upsert — server responds with the joined rows.
      this.slots = await saveInventory(this.character.id, toSavePayload(next));
      this.toast(`+${l.quantity} ${this.slots.find((s) => s.item_id === l.item_id)?.name ?? l.item_id}`);
    } catch (err) {
      this.toast(err instanceof Error ? err.message : 'Could not save loot');
      // Put the drop back so it isn't silently lost.
      this.spawnLoot(l.mesh.position, { item_id: l.item_id, quantity: l.quantity });
    } finally {
      this.savingLoot = false;
    }
  }

  /** Chase the clicked target and auto-cast the basic (slot 1) ability in range. */
  private updateAutoAttack(dt: number, _now: number) {
    if (this.attackTargetId === null || this.hp <= 0) return;
    const entity = this.enemies.get(this.attackTargetId);
    if (!entity || !entity.state.alive) {
      this.attackTargetId = null;
      return;
    }
    const basic = this.abilities[0];
    const d = entity.mesh.position.distanceTo(this.player!.position);
    if (d > basic.range) {
      // Walk into range.
      const dx = entity.mesh.position.x - this.player!.position.x;
      const dz = entity.mesh.position.z - this.player!.position.z;
      const step = MOVE_SPEED * dt;
      this.player!.position.x += (dx / d) * step;
      this.player!.position.z += (dz / d) * step;
      this.player!.rotation.y = Math.atan2(dx, dz);
    } else {
      this.player!.rotation.y = Math.atan2(
        entity.mesh.position.x - this.player!.position.x,
        entity.mesh.position.z - this.player!.position.z,
      );
      this.castAbility(1);
    }
  }

  private castAbility(slot: 1 | 2 | 3 | 4) {
    const now = performance.now();
    const ability = this.abilities[slot - 1];
    if (!ability || this.hp <= 0 || now < this.cooldownUntil[slot]) return;
    this.playerModelState = 'attack';
    this.playerModel?.setState('attack', false);

    if (ability.kind === 'nova' || ability.kind === 'ult') {
      // AoE centered on the player — hits every living enemy in radius.
      const hits: EnemyEntity[] = [];
      for (const e of this.enemies.values()) {
        if (e.state.alive && e.mesh.position.distanceTo(this.player!.position) <= ability.range) {
          hits.push(e);
        }
      }
      this.cooldownUntil[slot] = now + ability.cooldownMs;
      this.spawnNovaRing(ability);
      const dmg = Math.round(this.attackPower * ability.damageMult);
      for (const e of hits) this.dealDamage(e, dmg, ability);
      return;
    }

    // Targeted strike/heavy — clicked target if in range, else nearest in range.
    let target: EnemyEntity | null =
      this.attackTargetId !== null ? (this.enemies.get(this.attackTargetId) ?? null) : null;
    if (!target || !target.state.alive ||
        target.mesh.position.distanceTo(this.player!.position) > ability.range) {
      target = null;
      let nearestD = Infinity;
      for (const e of this.enemies.values()) {
        if (!e.state.alive) continue;
        const d = e.mesh.position.distanceTo(this.player!.position);
        if (d < nearestD && d <= ability.range) {
          nearestD = d;
          target = e;
        }
      }
    }
    if (!target) return;
    this.cooldownUntil[slot] = now + ability.cooldownMs;
    if (ability.ranged) this.spawnBolt(target.mesh.position, ability);
    this.dealDamage(target, Math.round(this.attackPower * ability.damageMult), ability);
  }

  private dealDamage(entity: EnemyEntity, dmg: number, ability: Ability) {
    if (this.sim) {
      this.sim.applyHit(entity.state.id, dmg);
    } else {
      this.realtime.sendArenaEvent({ type: 'hit', enemyId: entity.state.id, dmg });
    }
    const mat = entity.mesh.material as THREE.MeshStandardMaterial;
    mat.emissiveIntensity = 1.2;
    setTimeout(() => (mat.emissiveIntensity = 0.25), 120);
    this.spawnHitSprite(entity.mesh.position, ability);
    this.spawnDamageText(entity.mesh.position, `${dmg}`, ability.color);
  }

  /** Quick fading bolt line for ranged strikes. */
  private spawnBolt(to: THREE.Vector3, ability: Ability) {
    if (!this.scene) return;
    const from = this.player!.position.clone().setY(1.2);
    const material = new THREE.LineBasicMaterial({ color: ability.color, transparent: true });
    const geometry = new THREE.BufferGeometry().setFromPoints([from, to.clone().setY(0.8)]);
    const line = new THREE.Line(geometry, material);
    this.scene.add(line);
    // Impact sprite at bolt endpoint, slightly delayed so it lands with the hit.
    setTimeout(() => this.spawnHitSprite(to, ability, 1.4), 80);
    const started = performance.now();
    const fade = () => {
      const t = (performance.now() - started) / 180;
      if (t >= 1 || !this.scene) {
        this.scene?.remove(line);
        geometry.dispose();
        material.dispose();
        return;
      }
      material.opacity = 1 - t;
      requestAnimationFrame(fade);
    };
    fade();
  }

  /** Expanding ground ring for nova/ult AoE. */
  private spawnNovaRing(ability: Ability) {
    if (!this.scene) return;
    const material = new THREE.MeshBasicMaterial({
      color: ability.color,
      transparent: true,
      side: THREE.DoubleSide,
    });
    const ring = new THREE.Mesh(new THREE.RingGeometry(0.9, 1, 48), material);
    ring.rotation.x = -Math.PI / 2;
    ring.position.copy(this.player!.position).setY(0.05);
    this.scene.add(ring);
    const started = performance.now();
    const grow = () => {
      const t = (performance.now() - started) / 350;
      if (t >= 1 || !this.scene) {
        this.scene?.remove(ring);
        ring.geometry.dispose();
        material.dispose();
        return;
      }
      const s = 1 + t * ability.range;
      ring.scale.set(s, s, 1);
      material.opacity = 1 - t;
      requestAnimationFrame(grow);
    };
    grow();
  }

  /** Billboard sprite flash at impact point — scales up then fades. */
  private spawnHitSprite(pos: THREE.Vector3, ability: Ability, baseScale = 1.8) {
    if (!this.scene) return;
    const path = ArenaScene.HIT_SPRITES[ability.color] ?? 'art/vfx/hit-physical.png';
    let tex = this.vfxTextures.get(path);
    if (!tex) {
      tex = new THREE.TextureLoader().load(path);
      this.vfxTextures.set(path, tex);
    }
    const mat = new THREE.SpriteMaterial({
      map: tex,
      transparent: true,
      blending: THREE.AdditiveBlending,
      depthWrite: false,
    });
    const sprite = new THREE.Sprite(mat);
    sprite.position.copy(pos).setY(0.9);
    sprite.scale.set(0.01, 0.01, 0.01);
    this.scene.add(sprite);
    const started = performance.now();
    const DURATION = 280;
    const tick = () => {
      const t = (performance.now() - started) / DURATION;
      if (t >= 1 || !this.scene) {
        this.scene?.remove(sprite);
        mat.dispose();
        return;
      }
      const s = baseScale * Math.sin(t * Math.PI);
      sprite.scale.set(s, s, s);
      mat.opacity = t < 0.25 ? 1 : 1 - (t - 0.25) / 0.75;
      requestAnimationFrame(tick);
    };
    tick();
  }

  private updateContactDamage(now: number) {
    if (this.hp <= 0 || now - this.lastEnemyTick < ENEMY_DPS_TICK_MS) return;
    for (const e of this.enemies.values()) {
      if (!e.state.alive) continue;
      if (e.mesh.position.distanceTo(this.player!.position) <= ENEMY_ATTACK_RANGE) {
        this.lastEnemyTick = now;
        this.hp = Math.max(0, this.hp - ENEMY_HIT_DAMAGE);
        this.spawnDamageText(this.player!.position, `-${ENEMY_HIT_DAMAGE}`, '#ff8a8a');
        this.refreshHud();
        if (this.hp <= 0) this.onPlayerDeath();
        break;
      }
    }
  }

  private onPlayerDeath() {
    this.toast('You died — returning to the entrance');
    setTimeout(() => {
      this.player!.position.set(0, 1.1, ARENA_RADIUS - 3.5);
      this.hp = this.maxHp;
      this.refreshHud();
    }, 1500);
  }

  private checkPortal() {
    if (!this.portal || this.hp <= 0) return;
    const d = Math.hypot(
      this.player!.position.x - this.portal.position.x,
      this.player!.position.z - this.portal.position.z,
    );
    if (d < PORTAL_RANGE) this.onReturnHub(this.xpEarned);
  }

  // --- HUD ---

  private mountHud() {
    this.hudEl = document.createElement('div');
    this.hudEl.innerHTML = `
      <div class="cw-hud">
        <div class="pill">${this.character?.class_name ?? 'Character'}</div>
        <div class="pill hp"><div class="cw-hpbar"><div class="fill" data-hp-fill></div></div><span data-hp-text></span></div>
        <div class="pill" data-kills>Kills 0</div>
      </div>
      <div class="cw-party" data-party></div>
      <div class="cw-abilitybar" data-abilities>
        ${this.abilities
          .map(
            (a) => `
          <button class="cw-ability" data-slot="${a.slot}" title="${a.name}" style="--ability-color:${a.color}">
            <span class="key">${a.slot}</span>
            <span class="icon"><img src="${a.iconPng}" alt="${a.name}" onerror="this.style.display='none';this.parentElement.dataset.fallback='${a.icon}'"></span>
            <span class="cd" data-cd="${a.slot}"></span>
          </button>`,
          )
          .join('')}
      </div>
      <div class="cw-hint">Click — move / attack target · 1–4 abilities · portal to leave</div>
      <div class="cw-toast" data-toast></div>
    `;
    this.root.appendChild(this.hudEl);
    this.hudEl.querySelectorAll<HTMLButtonElement>('[data-slot]').forEach((btn) => {
      btn.addEventListener('click', () => this.castAbility(Number(btn.dataset.slot) as 1 | 2 | 3 | 4));
    });
    this.refreshHud();
  }

  /** Diablo-style cooldown sweep: overlay height = remaining fraction. */
  private updateCooldownBar(now: number) {
    if (!this.hudEl) return;
    for (const a of this.abilities) {
      const el = this.hudEl.querySelector<HTMLSpanElement>(`[data-cd="${a.slot}"]`);
      if (!el) continue;
      const remaining = this.cooldownUntil[a.slot] - now;
      el.style.height = remaining > 0 ? `${Math.min(100, (remaining / a.cooldownMs) * 100)}%` : '0';
    }
  }

  private refreshHud() {
    if (!this.hudEl) return;
    const fill = this.hudEl.querySelector<HTMLDivElement>('[data-hp-fill]');
    const text = this.hudEl.querySelector<HTMLSpanElement>('[data-hp-text]');
    if (fill) fill.style.width = `${(this.hp / this.maxHp) * 100}%`;
    if (text) text.textContent = `${this.hp}/${this.maxHp}`;
    const kills = this.hudEl.querySelector<HTMLDivElement>('[data-kills]');
    if (kills) kills.textContent = `Kills ${this.kills} · +${this.xpEarned}xp`;

    const party = this.hudEl.querySelector<HTMLDivElement>('[data-party]');
    if (party) {
      const members = [
        { name: `${this.character?.class_name ?? 'You'} (you)`, classIndex: this.character?.class_index ?? 0 },
        ...[...this.remotes.values()].map((r) => ({
          name: `${r.player.name} · ${classByIndex(r.player.classIndex).name}`,
          classIndex: r.player.classIndex,
        })),
      ];
      party.innerHTML = Array.from({ length: 4 })
        .map((_, i) => {
          const m = members[i];
          return m
            ? `<div class="slot filled" style="border-left: 3px solid ${classByIndex(m.classIndex).color}">${m.name}</div>`
            : '<div class="slot">Open slot</div>';
        })
        .join('');
    }
  }

  private spawnDamageText(worldPos: THREE.Vector3, text: string, color: string) {
    if (!this.camera) return;
    const projected = worldPos.clone().project(this.camera);
    const el = document.createElement('div');
    el.className = 'cw-damage';
    el.style.color = color;
    el.style.left = `${((projected.x + 1) / 2) * window.innerWidth}px`;
    el.style.top = `${((1 - projected.y) / 2) * window.innerHeight - 40}px`;
    el.textContent = text;
    this.root.appendChild(el);
    setTimeout(() => el.remove(), 900);
  }

  private toast(message: string) {
    const el = this.hudEl?.querySelector<HTMLDivElement>('[data-toast]');
    if (!el) return;
    el.textContent = message;
    el.classList.add('show');
    setTimeout(() => el.classList.remove('show'), 4000);
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
    this.enemies.clear();
    this.remotes.clear();
    this.loot = [];
    this.sim = null;
    this.vfxTextures.forEach((t) => t.dispose());
    this.vfxTextures.clear();
    this.playerModel?.dispose();
    this.playerModel = null;
    this.scene = null;
    this.player = null;
    this.portal = null;
    this.renderer?.dispose();
    this.renderer = null;
  }
}
