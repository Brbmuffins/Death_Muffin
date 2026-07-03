import * as THREE from 'three';
import type { GameScene } from './SceneManager';
import { createRenderer, fitToWindow } from '../graphics/renderer';
import { MAX_PARTY_SIZE } from '../net/config';
import { getInventory, getProfessions } from '../net/api';
import type { InventorySlot, Profession } from '../net/types';
import { computeStats, STAT_KEYS, STAT_LABELS } from '../gameplay/stats';
import { classByIndex } from '../gameplay/classes';
import { ClickToMove } from '../gameplay/movement';
import { InventoryPanel } from '../ui/InventoryPanel';
import { ProfessionsPanel } from '../ui/ProfessionsPanel';
import { ForgePanel } from '../ui/ForgePanel';
import { RealtimeClient, type RemotePlayer } from '../net/realtime';
import { CharacterModel } from '../graphics/CharacterModel';
import { MODEL_PATHS, CLASS_TO_MODEL } from '../graphics/modelPaths';

const GROUND_RADIUS = 14;
const WALK_RADIUS = GROUND_RADIUS - 1;
const MOVE_SPEED = 5; // units/sec
const SEND_RATE_MS = 100; // ~10Hz position updates
const LERP_RATE = 12; // remote interpolation stiffness

interface RemoteEntity {
  player: RemotePlayer;
  mesh: THREE.Mesh;
  target: THREE.Vector3;
  targetOrientation: number;
  model?: CharacterModel;
  moving?: boolean;
}

/** Attach a CharacterModel for a class; hides the capsule when loaded. */
function attachModel(scene: THREE.Scene, capsule: THREE.Mesh, classIndex: number): CharacterModel | undefined {
  const slug = CLASS_TO_MODEL[classIndex];
  const paths = slug ? MODEL_PATHS[slug] : null;
  if (!paths) return undefined;
  const model = new CharacterModel(paths);
  scene.add(model.root);
  model.load().then(() => { capsule.visible = false; });
  return model;
}

/**
 * Placeholder hub environment — proves the render pipeline end to end.
 * Replace geometry with real environment art in the AAA graphics pass (Phase 6).
 * Realtime: connects to the Phase 3 Socket.io service on mount; hub still
 * works solo if the service is missing or the room is full.
 */
export class HubScene implements GameScene {
  private canvas = document.getElementById('scene') as HTMLCanvasElement;
  private root = document.getElementById('ui-root')!;
  private renderer: THREE.WebGLRenderer | null = null;
  private hudEl: HTMLDivElement | null = null;
  private raf = 0;

  private slots: InventorySlot[] = [];
  private professions: Profession[] = [];
  private inventoryPanel: InventoryPanel | null = null;
  private professionsPanel: ProfessionsPanel | null = null;
  private forgePanel: ForgePanel | null = null;

  private realtime = new RealtimeClient();
  private remotes = new Map<string, RemoteEntity>();
  private scene: THREE.Scene | null = null;
  private camera: THREE.PerspectiveCamera | null = null;
  private player: THREE.Mesh | null = null;
  private playerModel: CharacterModel | null = null;
  private playerModelMoving = false;
  private playerModelLastPos = new THREE.Vector3();
  private keys = new Set<string>();
  private mover = new ClickToMove(WALK_RADIUS);

  private onPointer = (e: PointerEvent) => {
    if (!this.camera || (e.type === 'pointermove' && !(e.buttons & 1))) return;
    const p = this.mover.groundPoint(e, this.camera);
    if (p) this.mover.setTarget(p);
  };
  private lastSent = 0;
  private lastSentPos = new THREE.Vector3(Infinity, 0, 0);

  private onKeyDown = (e: KeyboardEvent) => {
    if (document.activeElement instanceof HTMLInputElement) return;
    this.keys.add(e.key.toLowerCase());
  };
  private onKeyUp = (e: KeyboardEvent) => {
    this.keys.delete(e.key.toLowerCase());
  };

  private portal: THREE.Mesh | null = null;
  private bossPortal: THREE.Mesh | null = null;
  private entering = false;

  constructor(
    private character: any,
    private onEnterArena?: () => void,
    private onEnterBoss?: () => void,
    private initialToast?: string,
  ) {}

  mount() {
    const scene = new THREE.Scene();
    this.scene = scene;
    scene.background = new THREE.Color(0x05070d);
    scene.fog = new THREE.Fog(0x05070d, 12, 40);

    // Diablo-style top-down camera (user directive: mimic the Unity project).
    const camera = new THREE.PerspectiveCamera(50, window.innerWidth / window.innerHeight, 0.1, 200);
    this.camera = camera;

    const hemi = new THREE.HemisphereLight(0x6ee7ff, 0x10131c, 0.6);
    scene.add(hemi);
    const key = new THREE.DirectionalLight(0xffffff, 1.4);
    key.position.set(5, 8, 4);
    key.castShadow = true;
    scene.add(key);

    const ground = new THREE.Mesh(
      new THREE.CircleGeometry(GROUND_RADIUS, 48),
      new THREE.MeshStandardMaterial({ color: 0x11151f, roughness: 0.9 }),
    );
    ground.rotation.x = -Math.PI / 2;
    ground.receiveShadow = true;
    scene.add(ground);

    this.player = this.makeCapsule(this.character?.class_index ?? 0);
    scene.add(this.player);
    this.playerModel = attachModel(scene, this.player, this.character?.class_index ?? 0) ?? null;

    // Arena portal — north edge
    this.portal = new THREE.Mesh(
      new THREE.TorusGeometry(1.2, 0.12, 12, 32),
      new THREE.MeshStandardMaterial({ color: 0xff9a6e, emissive: 0xff9a6e, emissiveIntensity: 0.8 }),
    );
    this.portal.position.set(0, 1.4, -(GROUND_RADIUS - 2));
    scene.add(this.portal);

    // Boss portal — east edge, dark void purple
    this.bossPortal = new THREE.Mesh(
      new THREE.TorusGeometry(1.2, 0.12, 12, 32),
      new THREE.MeshStandardMaterial({ color: 0x6d28d9, emissive: 0x6d28d9, emissiveIntensity: 1.2 }),
    );
    this.bossPortal.position.set(GROUND_RADIUS - 2, 1.4, 0);
    scene.add(this.bossPortal);

    this.renderer = createRenderer(this.canvas);
    fitToWindow(this.renderer, camera);
    if (import.meta.env.DEV) (window as any).__cwDebug = { scene, camera, player: this.player, model: this.playerModel };

    window.addEventListener('keydown', this.onKeyDown);
    window.addEventListener('keyup', this.onKeyUp);
    this.canvas.addEventListener('pointerdown', this.onPointer);
    this.canvas.addEventListener('pointermove', this.onPointer);

    const camOffset = new THREE.Vector3(0, 12, 7);
    const clock = new THREE.Clock();
    const animate = () => {
      const dt = Math.min(clock.getDelta(), 0.1);
      this.updateMovement(dt);
      this.updateRemotes(dt);
      this.updatePlayerModel(dt);
      this.portal!.rotation.y += dt * 0.8;
      this.bossPortal!.rotation.y -= dt * 0.6;
      if (!this.entering) {
        if (
          this.onEnterArena &&
          Math.hypot(this.player!.position.x - this.portal!.position.x, this.player!.position.z - this.portal!.position.z) < 1.6
        ) {
          this.entering = true;
          this.onEnterArena();
          return;
        }
        if (
          this.onEnterBoss &&
          Math.hypot(this.player!.position.x - this.bossPortal!.position.x, this.player!.position.z - this.bossPortal!.position.z) < 1.6
        ) {
          this.entering = true;
          this.onEnterBoss();
          return;
        }
      }
      camera.position.copy(this.player!.position).add(camOffset);
      camera.lookAt(this.player!.position.x, 0.5, this.player!.position.z);
      this.renderer!.render(scene, camera);
      this.raf = requestAnimationFrame(animate);
    };
    animate();

    this.mountHud();
    this.inventoryPanel = new InventoryPanel(this.root, this.character.id, (slots) => {
      this.slots = slots;
      this.refreshStats();
    });
    this.professionsPanel = new ProfessionsPanel(this.root);
    this.forgePanel = new ForgePanel(
      this.root,
      this.character.id,
      () => this.slots,
      (inventory, profession) => {
        this.slots = inventory;
        this.professions = this.professions.map((p) =>
          p.profession_id === profession.profession_id ? profession : p,
        );
        this.inventoryPanel?.setSlots(inventory);
        this.refreshStats();
      },
    );
    this.loadData();
    this.connectRealtime();
    if (this.initialToast) setTimeout(() => this.toast(this.initialToast!), 300);
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

  // --- Movement & realtime sync ---

  private updateMovement(dt: number) {
    if (!this.player) return;
    const dir = new THREE.Vector3(
      (this.keys.has('d') || this.keys.has('arrowright') ? 1 : 0) -
        (this.keys.has('a') || this.keys.has('arrowleft') ? 1 : 0),
      0,
      (this.keys.has('s') || this.keys.has('arrowdown') ? 1 : 0) -
        (this.keys.has('w') || this.keys.has('arrowup') ? 1 : 0),
    );
    if (dir.lengthSq() > 0) {
      this.mover.clear(); // keyboard overrides click-to-move
      dir.normalize().multiplyScalar(MOVE_SPEED * dt);
      this.player.position.add(dir);
      const flat = new THREE.Vector2(this.player.position.x, this.player.position.z);
      if (flat.length() > WALK_RADIUS) {
        flat.setLength(WALK_RADIUS);
        this.player.position.x = flat.x;
        this.player.position.z = flat.y;
      }
      this.player.rotation.y = Math.atan2(dir.x, dir.z);
    } else {
      this.mover.update(this.player, MOVE_SPEED, dt);
    }

    const now = performance.now();
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

  private updateRemotes(dt: number) {
    const t = Math.min(1, LERP_RATE * dt);
    for (const remote of this.remotes.values()) {
      const before = remote.mesh.position.clone();
      remote.mesh.position.lerp(remote.target, t);
      remote.mesh.rotation.y += (remote.targetOrientation - remote.mesh.rotation.y) * t;
      const model = remote.model;
      if (model) {
        model.root.position.set(remote.mesh.position.x, 0, remote.mesh.position.z);
        model.root.rotation.y = remote.mesh.rotation.y;
        model.update(dt);
        const moving = before.distanceToSquared(remote.mesh.position) > 4e-6;
        if (moving !== remote.moving) {
          remote.moving = moving;
          model.setState(moving ? 'walk' : 'idle');
        }
      }
    }
  }

  private updatePlayerModel(dt: number) {
    const model = this.playerModel;
    if (!model || !this.player) return;
    model.root.position.set(this.player.position.x, 0, this.player.position.z);
    model.root.rotation.y = this.player.rotation.y;
    model.update(dt);
    if (!model.loaded) return;
    const moving = this.player.position.distanceToSquared(this.playerModelLastPos) > 4e-4;
    this.playerModelLastPos.copy(this.player.position);
    if (moving !== this.playerModelMoving) {
      this.playerModelMoving = moving;
      model.setState(moving ? 'run' : 'idle');
    }
  }

  private async connectRealtime() {
    try {
      const others = await this.realtime.connect(
        {
          room: 'hub',
          characterId: this.character.id,
          classIndex: this.character.class_index ?? 0,
          x: this.player!.position.x,
          y: this.player!.position.y,
          z: this.player!.position.z,
          orientation: this.player!.rotation.y,
        },
        {
          onPlayerJoin: (p) => {
            this.addRemote(p);
            this.chatLine(`${p.name} joined`);
            this.refreshParty();
          },
          onPlayerLeave: (id) => {
            const r = this.remotes.get(id);
            if (r) {
              this.chatLine(`${r.player.name} left`);
              this.scene?.remove(r.mesh);
              this.removeRemoteModel(r);
              this.remotes.delete(id);
              this.refreshParty();
            }
          },
          onPlayerMove: (u) => {
            const r = this.remotes.get(u.id);
            if (r) {
              r.target.set(u.x, 1.1, u.z);
              r.targetOrientation = u.orientation;
            }
          },
          onChat: (m) => this.chatLine(`${m.name}: ${m.text}`),
          onDisconnect: () => {
            for (const r of this.remotes.values()) {
              this.scene?.remove(r.mesh);
              this.removeRemoteModel(r);
            }
            this.remotes.clear();
            this.refreshParty();
            this.chatLine('Disconnected from party');
          },
        },
      );
      others.forEach((p) => this.addRemote(p));
      this.refreshParty();
      this.chatLine('Connected to hub');
    } catch (err) {
      // Solo mode — realtime is additive, never blocking.
      this.toast(err instanceof Error ? err.message : 'Realtime unavailable');
    }
  }

  private removeRemoteModel(r: RemoteEntity) {
    if (!r.model) return;
    this.scene?.remove(r.model.root);
    r.model.dispose();
    r.model = undefined;
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
      model: attachModel(this.scene, mesh, p.classIndex),
    });
  }

  // --- Data & HUD ---

  private async loadData() {
    try {
      const [slots, professions] = await Promise.all([
        getInventory(this.character.id),
        getProfessions(this.character.id),
      ]);
      this.slots = slots;
      this.professions = professions;
      this.refreshStats();
    } catch (err) {
      this.toast(err instanceof Error ? err.message : 'Failed to load character data');
    }
  }

  private mountHud() {
    this.hudEl = document.createElement('div');
    this.hudEl.innerHTML = `
      <div class="cw-hud">
        <div class="pill">${this.character?.class_name ?? 'Character'}</div>
        <div class="pill" data-level>Lv ${this.character?.level ?? 1}</div>
        <div class="pill" data-xp></div>
        <div class="pill gold" data-gold>${this.character?.gold ?? 0}g</div>
        <div class="pill stats" data-stats></div>
      </div>
      <div class="cw-party" data-party></div>
      <div class="cw-chat">
        <div class="log" data-chat-log></div>
        <input data-chat-input type="text" maxlength="240" placeholder="Press Enter to chat" />
      </div>
      <div class="cw-actions">
        <button class="cw-icon-btn big" data-bag aria-label="Inventory">🎒</button>
        <button class="cw-icon-btn big" data-forge aria-label="Forge">🔥</button>
        <button class="cw-icon-btn big" data-skills aria-label="Professions">⚒</button>
      </div>
      <div class="cw-toast" data-toast></div>
    `;
    this.root.appendChild(this.hudEl);

    const closeAllPanels = () => {
      this.inventoryPanel!.close();
      this.professionsPanel!.close();
      this.forgePanel!.close();
    };
    this.hudEl.querySelector('[data-bag]')!.addEventListener('click', () => {
      const wasOpen = this.inventoryPanel!.isOpen;
      closeAllPanels();
      if (!wasOpen) this.inventoryPanel!.open(this.slots);
    });
    this.hudEl.querySelector('[data-forge]')!.addEventListener('click', () => {
      const wasOpen = this.forgePanel!.isOpen;
      closeAllPanels();
      if (!wasOpen) this.forgePanel!.open();
    });
    this.hudEl.querySelector('[data-skills]')!.addEventListener('click', () => {
      const wasOpen = this.professionsPanel!.isOpen;
      closeAllPanels();
      if (!wasOpen) this.professionsPanel!.open(this.professions);
    });

    const chatInput = this.hudEl.querySelector<HTMLInputElement>('[data-chat-input]')!;
    chatInput.addEventListener('keydown', (e) => {
      e.stopPropagation();
      if (e.key === 'Enter') {
        const text = chatInput.value.trim();
        if (text && this.realtime.connected) this.realtime.sendChat(text);
        chatInput.value = '';
        chatInput.blur();
      } else if (e.key === 'Escape') {
        chatInput.blur();
      }
    });
    window.addEventListener('keydown', this.focusChatOnEnter);

    this.refreshStats();
    this.refreshParty();
  }

  private focusChatOnEnter = (e: KeyboardEvent) => {
    if (e.key !== 'Enter' || document.activeElement instanceof HTMLInputElement) return;
    this.hudEl?.querySelector<HTMLInputElement>('[data-chat-input]')?.focus();
  };

  private refreshParty() {
    const el = this.hudEl?.querySelector<HTMLDivElement>('[data-party]');
    if (!el) return;
    const members = [
      { name: `${this.character?.class_name ?? 'You'} (you)`, classIndex: this.character?.class_index ?? 0 },
      ...[...this.remotes.values()].map((r) => ({
        name: `${r.player.name} · ${classByIndex(r.player.classIndex).name}`,
        classIndex: r.player.classIndex,
      })),
    ];
    el.innerHTML = Array.from({ length: MAX_PARTY_SIZE })
      .map((_, i) => {
        const m = members[i];
        return m
          ? `<div class="slot filled" style="border-left: 3px solid ${classByIndex(m.classIndex).color}">${m.name}</div>`
          : '<div class="slot">Open slot</div>';
      })
      .join('');
  }

  /** Gold + stat pills read from character base stats and equipped bonuses. */
  private refreshStats() {
    if (!this.hudEl) return;
    const goldEl = this.hudEl.querySelector<HTMLDivElement>('[data-gold]');
    if (goldEl) goldEl.textContent = `${this.character?.gold ?? 0}g`;

    const levelEl = this.hudEl.querySelector<HTMLDivElement>('[data-level]');
    if (levelEl) levelEl.textContent = `Lv ${this.character?.level ?? 1}`;
    const xpEl = this.hudEl.querySelector<HTMLDivElement>('[data-xp]');
    if (xpEl) {
      // XP-to-next = level × 100; `experience` is progress into the current level.
      xpEl.textContent = `XP ${this.character?.experience ?? 0}/${(this.character?.level ?? 1) * 100}`;
    }

    const statsEl = this.hudEl.querySelector<HTMLDivElement>('[data-stats]');
    if (statsEl) {
      const { total, bonus } = computeStats(this.character, this.slots);
      statsEl.innerHTML = STAT_KEYS.map((k) => {
        const plus = bonus[k] > 0 ? `<span class="plus">+${bonus[k]}</span>` : '';
        return `<span class="stat">${STAT_LABELS[k]} ${total[k]}${plus}</span>`;
      }).join('');
    }
  }

  setGold(gold: number) {
    this.character.gold = gold;
    this.refreshStats();
  }

  private chatLine(text: string) {
    const log = this.hudEl?.querySelector<HTMLDivElement>('[data-chat-log]');
    if (!log) return;
    const line = document.createElement('div');
    line.textContent = text;
    log.appendChild(line);
    while (log.children.length > 8) log.removeChild(log.firstChild!);
    log.scrollTop = log.scrollHeight;
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
    this.portal = null;
    this.bossPortal = null;
    this.realtime.disconnect();
    window.removeEventListener('keydown', this.onKeyDown);
    window.removeEventListener('keyup', this.onKeyUp);
    window.removeEventListener('keydown', this.focusChatOnEnter);
    this.canvas.removeEventListener('pointerdown', this.onPointer);
    this.canvas.removeEventListener('pointermove', this.onPointer);
    this.camera = null;
    this.inventoryPanel?.close();
    this.professionsPanel?.close();
    this.forgePanel?.close();
    this.hudEl?.remove();
    this.hudEl = null;
    for (const r of this.remotes.values()) this.removeRemoteModel(r);
    this.remotes.clear();
    this.playerModel?.dispose();
    this.playerModel = null;
    this.scene = null;
    this.player = null;
    this.renderer?.dispose();
    this.renderer = null;
  }
}
