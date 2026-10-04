import { canUseAutoCombat, isTouchFirst, settings, updateSettings, type Quality } from '../app/settings';
import { LOOT_TIERS, actionsFor, type LootAction } from '../gameplay/lootFilter';
import { AREAS, type AreaId } from '../content/areas';
import { DIFFICULTIES, DIFFICULTY_ORDER, isDifficulty } from '../content/difficulty';
import { ACTION_LABEL, LOADOUT_ACTIONS, checkBind, label as keyLabel, type ActionId, type Binds } from '../gameplay/keybinds';
import { saveLootRuleToAccount } from '../net/accountPrefs';
import { BugReportView, type BugReportContext } from './BugReportView';
import { wrapPanelBody } from './panelBody';

export abstract class SimplePanel {
  protected el: HTMLDivElement | null = null;
  constructor(protected root: HTMLElement) {}
  get isOpen() {
    return this.el !== null;
  }
  protected mount(title: string, body: string) {
    this.el = document.createElement('div');
    this.el.className = 'cw-plate cw-panel-float';
    this.el.setAttribute('role', 'dialog');
    // 'Name|Menu name · key' puts the menu button's plain name beside the lore name, so the button and the panel read as one thing.
    const [name, aka] = title.split('|');
    this.el.setAttribute('aria-label', name);
    this.el.innerHTML = `
      <div class="cw-panel-head"><h2 class="cw-title">${name}${aka ? `<span class="aka">${aka}</span>` : ''}</h2><button class="cw-icon-btn" data-close aria-label="Close">✕</button></div>
      ${body}`;
    wrapPanelBody(this.el);
    this.el.querySelector('[data-close]')!.addEventListener('click', () => this.close());
    this.root.appendChild(this.el);
  }
  close() {
    this.el?.remove();
    this.el = null;
  }
}

/** Graphics / motion / feedback options + key reference. */
export class SettingsPanel extends SimplePanel {
  constructor(
    root: HTMLElement,
    private onLeave: () => void,
    private instanceCode: () => string | null,
    private onResetTips?: () => void,
    private onChangeClass?: () => void,
    /** Only for dev accounts: the dev-access overlay toggle (per character, never saved to the server). */
    private dev?: { get(): boolean; set(on: boolean): void },
    private kitHelp: { primary: string; rites: string[]; corpseAction: string; legion?: boolean } = {
      primary: 'Bone Needle', rites: ['Marrow Spear', 'Exhume', 'Miasma', 'Black Litany'], corpseAction: 'Corpse Explosion', legion: true,
    },
    /** Settings → Report a bug: what the report attaches on its own. */
    private bugContext?: () => BugReportContext,
    /** Settings -> Play together: make, join or leave a party. Absent = no co-op section. */
    private party?: { create(): void; join(code: string): void; leave(): void },
    /** Rebindable hotkeys (loadouts, necromancers): the current keys, and a setter that answers a readable refusal or null. */
    private keybinds?: { get(): Binds; set(action: ActionId, key: string | null): string | null },
  ) {
    super(root);
  }

  open() {
    if (this.el) return;
    const code = this.instanceCode();
    this.mount(
      'Settings',
      `<div class="cw-settings">
        <div class="cw-settings-top"><span>Done for now?</span><button class="cw-button" data-leave>Leave the world</button></div>
        <section class="cw-settings-section"><h3>Play</h3>
        <label class="row">Difficulty
          <select data-diff>${DIFFICULTY_ORDER.map((d) => `<option value="${d}">${DIFFICULTIES[d].name}</option>`).join('')}</select></label>
        <p class="cw-settings-note" data-diffnote></p>
        ${canUseAutoCombat() ? '<label class="row">Auto combat (Easy only, G)<input type="checkbox" data-auto aria-label="Auto combat" /></label>' : ''}
        <label class="row">Auto gathering<input type="checkbox" data-autogather aria-label="Auto gathering: move on to the next node of the same kind" /></label>
        <h4 class="cw-settings-sub">Loot</h4>
        ${LOOT_TIERS.map((t) => `<label class="row">${t.label} gear<select data-lootrule="${t.id}">${actionsFor(t.id).map((o) => `<option value="${o.id}">${o.label}</option>`).join('')}</select></label>`).join('')}
        <p class="cw-settings-note">On the ground: walk over it. Auto-loot: straight into your bag as it drops (if the bag is full it lands instead). Sell for gold: you get its sell value and it never drops. Set pieces, legendaries, necromancer affixes and upgrades for you are never sold.</p>
        ${canUseAutoCombat() ? '<p class="cw-settings-note">On Easy, Auto engages enemies in your current area, uses equipped rites and may cast your signature when a fight calls for it. Click or use WASD to take control; hold 1–5 to repeat a rite.</p>' : ''}
        </section>
        <section class="cw-settings-section"><h3>Display and sound</h3>
        <label class="row">Graphics
          <select data-q><option value="high">High (bloom, shadows)</option><option value="low">Low (fast)</option></select></label>
        <label class="row">Frame rate
          <select data-fps><option value="0">Max — your screen's refresh rate</option><option value="60">60 — smooth</option><option value="30">30 — battery saver</option></select></label>
        <label class="row">Auto resolution<input type="checkbox" data-autores aria-label="Auto resolution: lower the render resolution if the frame rate can't hold" /></label>
        <p class="cw-settings-note">Auto resolution only steps in after several seconds of sustained slow frames. Turn it off to keep a constant sharp picture.</p>
        <p class="cw-settings-note">${isTouchFirst() && !settings.graphicsChosen ? 'Set for phones automatically — Low + 30 fps saves battery. Change it any time.' : 'On a phone: Graphics Low + 30 fps uses far less battery.'}</p>
        ${import.meta.env.BASE_URL.includes('/death-muffin/mobile/') ? '<p class="cw-settings-note"><a href="/death-muffin/play/?pc=1">Play the PC version</a> (the full desktop build; same account and progress)</p>' : ''}
        <label class="row">Volume<input type="range" min="0" max="1" step="0.05" data-vol aria-label="Master volume" /></label>
        <label class="row">Combat<input type="range" min="0" max="1" step="0.05" data-vol-combat aria-label="Combat volume: spells, hits, thralls and enemies" /></label>
        <label class="row">Ambience<input type="range" min="0" max="1" step="0.05" data-vol-amb aria-label="Ambience volume: wind, drones, footsteps and gathering" /></label>
        <label class="row">Music<input type="range" min="0" max="1" step="0.05" data-vol-music aria-label="Music volume" /></label>
        <label class="row">Interface<input type="range" min="0" max="1" step="0.05" data-vol-ui aria-label="Interface volume: clicks, coins and level-up chimes" /></label>
        <label class="row">Reduce motion (no camera shake)<input type="checkbox" data-rm /></label>
        <label class="row">Damage numbers<input type="checkbox" data-dn /></label>
        <label class="row">Hide helms<input type="checkbox" data-hidehelm /></label>
        <label class="row">Don't show tips<input type="checkbox" data-tips /></label>
        <label class="row">Show the “Next” suggestion under the minimap<input type="checkbox" data-guidance aria-label="Show the Next suggestion under the minimap" /></label>
        <label class="row">Point to it on the minimap<input type="checkbox" data-guideping aria-label="Point the Next suggestion out on the minimap" /></label>
        </section>
        <section class="cw-settings-section"><h3>Character and help</h3>
        ${this.dev ? '<label class="row">Dev access (preview as a normal player when off)<input type="checkbox" data-dev aria-label="Dev access" /></label>' : ''}
        ${this.bugContext ? '<label class="row">Found a bug or something odd?<button type="button" class="cw-button" data-bugreport>Report a bug</button></label>' : ''}
        ${this.onResetTips ? '<label class="row">New to the Covenant?<button type="button" class="cw-button" data-resettips>Show tips again</button></label>' : ''}
        ${this.onChangeClass ? '<label class="row">Class<button type="button" class="cw-button" aria-label="Change class" data-changeclass>Change class</button></label>' : ''}
        </section>
        ${this.party ? `<section class="cw-settings-section"><h3>Play together</h3>
        ${code
          ? `<label class="row">Your party code<b data-partycode style="font-family:var(--cw-font-numeric)">${code}</b></label>
             <p class="cw-settings-note">Friends enter this code under Play together (or type /party ${code}) to join you. You choose who plays with you: being online at the same time never makes a party.</p>
             <label class="row">Done playing together?<button type="button" class="cw-button" data-partyleave>Leave party (play solo)</button></label>`
          : `<p class="cw-settings-note">You are playing solo. Make a party and share its code, or enter a friend's code. In a party you share one world and its enemies; the Catacomb Depths stay a solo descent (you step out, then rejoin).</p>
             <label class="row">Start a party<button type="button" class="cw-button" data-partymake>Make a party</button></label>
             <label class="row">Join a friend<span><input type="text" maxlength="12" size="10" data-partycode-in placeholder="code" aria-label="Party code" autocomplete="off" /> <button type="button" class="cw-button" data-partyjoin>Join</button></span></label>`}
        </section>` : ''}
        <section class="cw-settings-section"><h3>Controls</h3>
        ${this.keybinds ? `<h4 class="cw-keys-h">Loadout hotkeys <small>unbound until you pick a key</small></h4>
        <div class="cw-keybinds" data-keybinds>${LOADOUT_ACTIONS.map((a) => `<span>${ACTION_LABEL[a]}</span><button type="button" class="cw-button small" data-bind="${a}"></button>`).join('')}</div>
        <p class="cw-settings-note" data-bindnote role="status" aria-live="polite">Click an action, then press a key. Esc clears it. Keys the game already uses are refused.</p>` : ''}
        <div class="cw-keys">
          ${this.keybinds ? '<kbd>Loadout keys</kbd><span>Next loadout and Loadout 1-6: unbound until you assign them above (necromancers). They apply a saved Grimoire loadout</span>' : ''}
          <kbd>WASD</kbd><span>Walk freely; holding a direction takes over from click-to-move</span>
          <kbd>Click</kbd><span>Move · attack target (${this.kitHelp.primary}) · use</span>
          <kbd>Minimap</kbd><span>Click a walkable spot to travel there</span>
          <kbd>Hover / focus</kbd><span>Spell icon: cost, targeting, effects and combat counsel</span>
          <kbd>Shift+Click</kbd><span>Cast ${this.kitHelp.primary} without moving</span>
          <kbd>1–5 (hold)</kbd><span>Cast your equipped rites at the cursor</span>
          <kbd>L</kbd><span>Grimoire (with the Legion beside it for necromancers) · click the swap arrows below a hotbar spell (they appear once you learn a second rite) to choose any unlocked class rite</span>
          <kbd>RMB · 5</kbd><span>Cast your fifth equipped rite (starts as ${this.kitHelp.corpseAction})</span>
          <kbd>R · 6</kbd><span>Signature rite (unlocks at level 10)</span>
          <kbd>Q</kbd><span>Drink a healing flask</span>
          <kbd>Z · X</kbd><span>Drink the elixir · tonic on your belt (right-click a brew in the Reliquary to belt it)</span>
          <kbd>T</kbd><span>Return to the Chapterhouse</span>
          <kbd>Click a node</kbd><span>Gather: chop a tree, mine a seam, fish a pool, dig a grave (it keeps working until the node is spent)</span>
          <kbd>I C M</kbd><span>Reliquary · Workbench · Waystones</span>
          <kbd>P</kbd><span>Acre ledger: Skills, then tabs for Garden, Laborers and Contracts (the Acre button appears once you start gathering)</span>
          <kbd>U H O</kbd><span>The Acre ledger's Garden · Laborers · Contracts tabs (old keys, they open the right tab)</span>
          <kbd>J N</kbd><span>Character window: your stats and where each number comes from, and a Capes &amp; Pets tab (N opens it)</span>
          ${this.kitHelp.legion ? '<kbd>Y</kbd><span>Legion tab beside the Grimoire: spare weapon and armour for your thralls, and Reinforce (necromancers)</span>' : ''}
          <kbd>.</kbd><span>Gear Atlas: where every piece drops and how often, how to craft it, and what suits your discipline</span>
          <kbd>K</kbd><span>Codex</span>
          <kbd>E</kbd><span>Talk to the Prior, the Sexton or the Apothecary when you stand close (or click them)</span>
          <kbd>V</kbd><span>Ossuary Vault: a shared stash (in the Chapterhouse or the Acre)</span>
          ${canUseAutoCombat() ? '<kbd>G</kbd><span>Toggle auto combat on Easy · engage nearby enemies</span>' : ''}
          <kbd>Counsel header</kbd><span>Drag to move · arrow keys while focused · remembers its position</span>
          <kbd>Settings</kbd><span>Change class · keeps your character and progress</span>
          <kbd>Wheel</kbd><span>Zoom</span>
          <kbd>Enter</kbd><span>Chat</span>
          <kbd>Altar</kbd><span>Click the Altar in the Chapterhouse to Ascend and buy Boons</span>
        </div>
        </section>
      </div>`,
    );
    const diff = this.el!.querySelector<HTMLSelectElement>('[data-diff]')!;
    const note = this.el!.querySelector<HTMLElement>('[data-diffnote]')!;
    const auto = this.el!.querySelector<HTMLInputElement>('[data-auto]');
    const syncAuto = () => {
      if (!auto) return;
      auto.checked = settings.autoCombat;
      auto.disabled = settings.difficulty !== 'easy';
    };
    const showNote = () => (note.textContent = `${DIFFICULTIES[settings.difficulty].blurb}${canUseAutoCombat() ? ` ${settings.difficulty === 'easy' ? 'Auto combat turns on with Easy.' : 'Auto combat turns off with Medium and Hard.'}` : ''} In co-op, the world keeper sets enemy difficulty.`);
    diff.value = settings.difficulty;
    showNote();
    syncAuto();
    diff.addEventListener('change', () => {
      if (isDifficulty(diff.value)) updateSettings({ difficulty: diff.value });
      showNote();
      syncAuto();
    });
    const q = this.el!.querySelector<HTMLSelectElement>('[data-q]')!;
    q.value = settings.quality;
    q.addEventListener('change', () => updateSettings({ quality: q.value as Quality }));
    const fps = this.el!.querySelector<HTMLSelectElement>('[data-fps]')!;
    fps.value = String(settings.fps);
    fps.addEventListener('change', () => updateSettings({ fps: Number(fps.value) === 30 ? 30 : Number(fps.value) === 60 ? 60 : 0 }));
    const autoRes = this.el!.querySelector<HTMLInputElement>('[data-autores]')!;
    autoRes.checked = settings.autoResolution;
    autoRes.addEventListener('change', () => updateSettings({ autoResolution: autoRes.checked }));
    const vol = this.el!.querySelector<HTMLInputElement>('[data-vol]')!;
    vol.value = String(settings.volume);
    vol.addEventListener('input', () => updateSettings({ volume: Number(vol.value) }));
    const mixer: [string, 'combatVolume' | 'ambienceVolume' | 'musicVolume' | 'interfaceVolume'][] = [['[data-vol-combat]', 'combatVolume'], ['[data-vol-amb]', 'ambienceVolume'], ['[data-vol-music]', 'musicVolume'], ['[data-vol-ui]', 'interfaceVolume']];
    for (const [sel, key] of mixer) {
      const slider = this.el!.querySelector<HTMLInputElement>(sel)!;
      slider.value = String(settings[key]);
      slider.addEventListener('input', () => updateSettings({ [key]: Number(slider.value) }));
    }
    const rm = this.el!.querySelector<HTMLInputElement>('[data-rm]')!;
    rm.checked = settings.reducedMotion;
    rm.addEventListener('change', () => updateSettings({ reducedMotion: rm.checked }));
    const hh = this.el!.querySelector<HTMLInputElement>('[data-hidehelm]')!;
    hh.checked = settings.hideHelm;
    hh.addEventListener('change', () => updateSettings({ hideHelm: hh.checked }));
    const dn = this.el!.querySelector<HTMLInputElement>('[data-dn]')!;
    dn.checked = settings.damageNumbers;
    dn.addEventListener('change', () => updateSettings({ damageNumbers: dn.checked }));
    const tips = this.el!.querySelector<HTMLInputElement>('[data-tips]')!;
    tips.checked = !settings.tips;
    tips.addEventListener('change', () => updateSettings({ tips: !tips.checked }));
    const guide = this.el!.querySelector<HTMLInputElement>('[data-guidance]')!;
    const ping = this.el!.querySelector<HTMLInputElement>('[data-guideping]')!;
    guide.checked = settings.guidance;
    ping.checked = settings.guidancePing;
    ping.disabled = !settings.guidance;
    guide.addEventListener('change', () => { updateSettings({ guidance: guide.checked }); ping.disabled = !guide.checked; });
    ping.addEventListener('change', () => updateSettings({ guidancePing: ping.checked }));
    const dev = this.el!.querySelector<HTMLInputElement>('[data-dev]');
    if (dev && this.dev) {
      dev.checked = this.dev.get();
      dev.addEventListener('change', () => this.dev?.set(dev.checked));
    }
    auto?.addEventListener('change', () => updateSettings({ autoCombat: auto.checked }));
    const autoGather = this.el!.querySelector<HTMLInputElement>('[data-autogather]')!;
    autoGather.checked = settings.autoGather;
    autoGather.addEventListener('change', () => updateSettings({ autoGather: autoGather.checked }));
    this.el!.querySelectorAll<HTMLSelectElement>('[data-lootrule]').forEach((sel) => {
      const tier = sel.dataset.lootrule as keyof typeof settings.lootRules;
      sel.value = settings.lootRules[tier];
      sel.addEventListener('change', () => {
        updateSettings({ lootRules: { ...settings.lootRules, [tier]: sel.value as LootAction } });
        void saveLootRuleToAccount(tier, sel.value as LootAction);
      });
    });
    this.el!.querySelector<HTMLButtonElement>('[data-resettips]')?.addEventListener('click', () => {
      updateSettings({ tips: true });
      tips.checked = false;
      this.onResetTips?.();
    });
    const partyDo = (fn: () => void) => () => { fn(); this.close(); };
    this.el!.querySelector('[data-partymake]')?.addEventListener('click', partyDo(() => this.party?.create()));
    this.el!.querySelector('[data-partyleave]')?.addEventListener('click', partyDo(() => this.party?.leave()));
    const codeIn = this.el!.querySelector<HTMLInputElement>('[data-partycode-in]');
    const doJoin = () => { if (codeIn?.value.trim()) { this.party?.join(codeIn.value); this.close(); } };
    this.el!.querySelector('[data-partyjoin]')?.addEventListener('click', doJoin);
    codeIn?.addEventListener('keydown', (e) => { e.stopPropagation(); if (e.key === 'Enter') doJoin(); });
    if (this.keybinds) this.bindKeybinds(this.keybinds);
    this.el!.querySelector('[data-leave]')!.addEventListener('click', () => this.onLeave());
    this.el!.querySelector('[data-changeclass]')?.addEventListener('click', () => this.onChangeClass?.());
    this.el!.querySelector('[data-bugreport]')?.addEventListener('click', () => this.openBugReport());
  }

  /** Settings → Controls: click an action, press a key (Esc clears). Capture phase, so the press never reaches the game's own key handler. */
  private bindKeybinds(kb: { get(): Binds; set(action: ActionId, key: string | null): string | null }) {
    const root = this.el!;
    const note = root.querySelector<HTMLElement>('[data-bindnote]')!;
    const buttons = [...root.querySelectorAll<HTMLButtonElement>('[data-bind]')];
    let listening: { action: ActionId; off: () => void } | null = null;
    const paint = () => {
      const binds = kb.get();
      for (const b of buttons) {
        const a = b.dataset.bind as ActionId;
        const on = listening?.action === a;
        b.textContent = on ? 'Press a key…' : binds[a] ? keyLabel(binds[a]!) : 'Unbound';
        b.setAttribute('aria-pressed', String(on));
        b.setAttribute('aria-label', `${ACTION_LABEL[a]}: ${binds[a] ? keyLabel(binds[a]!) : 'unbound'}. Click, then press a key.`);
      }
    };
    const stop = () => { listening?.off(); listening = null; paint(); };
    for (const b of buttons) {
      b.addEventListener('click', () => {
        const action = b.dataset.bind as ActionId;
        const was = listening?.action;
        stop();
        if (was === action) return;
        note.textContent = `Press a key for ${ACTION_LABEL[action]} (Esc clears it).`;
        const onKey = (e: KeyboardEvent) => {
          if (['Shift', 'Control', 'Alt', 'Meta'].includes(e.key)) return;
          e.preventDefault();
          e.stopImmediatePropagation();
          if (e.key === 'Escape') {
            kb.set(action, null);
            note.textContent = `${ACTION_LABEL[action]} is unbound.`;
            return stop();
          }
          const err = checkBind(kb.get(), action, e.key) as { ok: boolean; error?: string };
          const refused = err.ok ? kb.set(action, e.key.toLowerCase()) : err.error!;
          note.textContent = refused ?? `${ACTION_LABEL[action]} is now ${keyLabel(e.key.toLowerCase())}.`;
          stop();
        };
        window.addEventListener('keydown', onKey, true);
        listening = { action, off: () => window.removeEventListener('keydown', onKey, true) };
        paint();
      });
    }
    this.stopBindCapture = stop;
    paint();
  }
  private stopBindCapture: (() => void) | null = null;
  close() {
    this.stopBindCapture?.();
    this.stopBindCapture = null;
    super.close();
  }

  /** Swap the Settings body for the report form; Back restores Settings. The panel stays open, so hotkeys stay blocked. */
  openBugReport() {
    if (!this.bugContext) return;
    if (!this.el) this.open();
    const body = this.el!.querySelector<HTMLElement>('.cw-settings');
    if (!body) return;
    const host = document.createElement('div');
    body.replaceWith(host);
    new BugReportView(host, this.bugContext, () => {
      this.close();
      this.open();
    }).render();
  }
}

/** Fast travel between unlocked waystones. */
export class WaystonePanel extends SimplePanel {
  constructor(
    root: HTMLElement,
    private unlocked: () => AreaId[],
    private travel: (area: AreaId) => void,
  ) {
    super(root);
  }

  open() {
    if (this.el) return;
    const areas = this.unlocked();
    this.mount(
      'Waystones|Map · M',
      `<div class="cw-waystones">${areas
        .map((a) => `<button class="cw-button small" data-go="${a}"><span>${AREAS[a].name}</span><span class="cw-hint-text">Lv ${AREAS[a].level}</span></button>`)
        .join('')}</div>
      <p class="cw-hint-text" style="margin-top:10px">Waystones answer only in the Chapterhouse or beside another waystone.</p>`,
    );
    this.el!.querySelectorAll<HTMLButtonElement>('[data-go]').forEach((b) =>
      b.addEventListener('click', () => {
        this.close();
        this.travel(b.dataset.go as AreaId);
      }),
    );
  }
}
