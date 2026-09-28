import { ABILITIES, SPELL_FX, type AbilityId, type NewBloodId } from '../content/abilities';
import { CAST_FLOW } from '../content/combatFlow';
import { fx } from '../graphics/fxTextures';
import { fxImage } from '../graphics/fxImages';
import type { AbilityContext, CastResult, CastTarget } from './AbilitySystem';
import type { Corpse, Enemy, Intent, SimEvent } from './sim/types';

/** The four Release 0.3 families. Corpse spends and persistent statuses resolve on the host. */
export class NewBloodSystem {
  private choirUntil = 0;
  private nextChoirBeat = 0;
  private crowsUntil = 0;
  private nextCrowPeck = 0;
  private murderUntil = 0;
  private nextMurderTick = 0;

  constructor(private ctx: AbilityContext) {}

  private get color() {
    return this.ctx.discipline.family === 'warden' ? SPELL_FX.warden.gold
      : this.ctx.discipline.family === 'monk' ? SPELL_FX.monk.sound
        : this.ctx.discipline.family === 'witch' ? SPELL_FX.witch.blood : SPELL_FX.veilwalker.cyan;
  }

  private get power() {
    const p = this.ctx.player;
    return p.stats.spellPower * (p.veilForm && this.ctx.now() >= p.betweenUntil ? 0.7 : 1);
  }

  private gesture(id: AbilityId, t: CastTarget, attack = false) {
    const p = this.ctx.player;
    if (Math.hypot(t.x - p.x, t.z - p.z) > 0.1) p.face(t.x, t.z);
    this.ctx.avatar.cast(attack ? 'attack' : 'cast', attack ? 2.8 : 2, p.facing, CAST_FLOW[id].gestureSeconds);
  }

  private ring(x: number, z: number, r: number, duration = 0.5) {
    this.ctx.effects.decal({ tex: this.ctx.discipline.family === 'monk' ? fxImage('soundRing') : fx.ring(),
      color: this.color, x, z, r, duration, opacity: 0.85, growFrom: 0.3, fadeOut: 0.3 });
    this.ctx.effects.emit({ x, y: 0.7, z, count: 10, color: this.color, spread: Math.min(r, 2), speed: 1.5, up: 1.4, life: 0.5, size: 0.14 });
  }

  private target(t: CastTarget, reach: number): Enemy | null {
    const p = this.ctx.player;
    const e = t.enemyId == null ? [...this.ctx.enemies().values()].find((v) => v.state !== 'dead' && Math.hypot(v.x - t.x, v.z - t.z) <= v.radius + 0.8)
      : this.ctx.enemies().get(t.enemyId);
    return e && e.state !== 'dead' && Math.hypot(e.x - p.x, e.z - p.z) <= reach + e.radius ? e : null;
  }

  private corpse(t: CastTarget, reach: number, echo = false): Corpse | null {
    const p = this.ctx.player;
    let best: Corpse | null = null;
    let dist = Infinity;
    for (const c of this.ctx.corpses().values()) {
      if (p.area && c.area !== p.area) continue;
      if (echo && c.echoOwner !== '*' && c.echoOwner !== this.ctx.selfId) continue;
      if (!echo && c.echoOwner) continue;
      const d = Math.hypot(c.x - t.x, c.z - t.z);
      if (d <= 1.25 && d < dist && Math.hypot(c.x - p.x, c.z - p.z) <= reach) (best = c), (dist = d);
    }
    return best;
  }

  private sendSig(sig: Extract<Intent, { t: 'signature' }>['sig'], x: number, z: number, sp = this.power, dur?: number) {
    const p = this.ctx.player;
    this.ctx.send({ t: 'signature', by: this.ctx.selfId, sig, x, z, dx: x - p.x, dz: z - p.z, sp, ...(dur == null ? {} : { dur }) });
  }

  private sendHits(ids: number[], damage: number, extra: Partial<Extract<Intent, { t: 'hit' }>> = {}, boss = false) {
    if (ids.length || boss) this.ctx.send({ t: 'hit', by: this.ctx.selfId, ids, dmg: damage, ...extra, ...(boss ? { boss: true } : {}) });
  }

  private arc(t: CastTarget, reach: number, halfAngle: number, damage: number) {
    const p = this.ctx.player;
    const dx = t.x - p.x;
    const dz = t.z - p.z;
    const len = Math.hypot(dx, dz) || 1;
    const ids: number[] = [];
    for (const e of this.ctx.enemies().values()) {
      if (e.state === 'dead') continue;
      const ex = e.x - p.x;
      const ez = e.z - p.z;
      const d = Math.hypot(ex, ez);
      if (d > reach + e.radius || (ex * dx + ez * dz) / (Math.max(d, 0.01) * len) < Math.cos(halfAngle * Math.PI / 180)) continue;
      ids.push(e.id);
      if (ids.length >= 64) break;
    }
    this.sendHits(ids, damage);
    this.ring(p.x + dx / len * reach * 0.5, p.z + dz / len * reach * 0.5, reach);
    return ids.length;
  }

  /** Returns `null` for abilities owned by the older AbilitySystem. */
  cast(id: AbilityId, t: CastTarget, now: number): CastResult | null {
    const def = ABILITIES[id];
    const p = this.ctx.player;
    const local = (kind: 'attack' | 'cast' = 'cast') => { this.gesture(id, t, kind === 'attack'); return 'ok' as const; };
    const host = (sig: Extract<Intent, { t: 'signature' }>['sig'], at: CastTarget = t, power = this.power, dur?: number) => {
      this.sendSig(sig, at.x, at.z, power, dur);
      this.gesture(id, at);
      return 'ok' as const;
    };
    const corpse = () => this.corpse(t, def.range);
    const enemy = () => this.target(t, def.range);
    const newId = id as NewBloodId;
    switch (newId) {
      case 'flail_swing': this.gesture(id, t, true); this.arc(t, 3, 70, this.power * def.power); return 'ok';
      case 'lantern_cone': {
        const dx = t.x - p.x, dz = t.z - p.z, l = Math.hypot(dx, dz) || 1;
        const ids = [...this.ctx.enemies().values()].filter((e) => e.state !== 'dead' && Math.hypot(e.x - p.x, e.z - p.z) <= 7 + e.radius
          && ((e.x - p.x) * dx + (e.z - p.z) * dz) / (Math.max(0.01, Math.hypot(e.x - p.x, e.z - p.z)) * l) >= Math.cos(Math.PI / 5)).map((e) => e.id).slice(0, 64);
        this.sendHits(ids, this.power * def.power);
        this.ctx.effects.decal({ tex: fxImage('lanternCone'), color: SPELL_FX.warden.gold,
          x: p.x + dx / l * 3.5, z: p.z + dz / l * 3.5, r: 3.5,
          rot: Math.atan2(dx, dz) + Math.PI, duration: 0.65, opacity: 0.75, fadeOut: 0.4 });
        this.ring(p.x + dx / l * 3, p.z + dz / l * 3, 3.5);
        return host('lantern_cone', { x: p.x + dx / l * 7, z: p.z + dz / l * 7 });
      }
      case 'chain_pull': case 'hook_pull': {
        const e = enemy(); if (!e) return 'no_target';
        if (newId === 'hook_pull') this.ctx.effects.beam({ x: p.x, y: 1.4, z: p.z },
          () => ({ x: e.x, y: 1.1, z: e.z }), SPELL_FX.witch.blood, 0.07, 0.35);
        return host(newId, { x: e.x, z: e.z });
      }
      case 'burn_the_dead':
        if (Math.hypot(t.x - p.x, t.z - p.z) > def.range) return 'range';
        if (![...this.ctx.corpses().values()].some((c) => !c.echoOwner && c.area === p.area && Math.hypot(c.x - t.x, c.z - t.z) <= 4)) return 'no_corpse';
        return host(newId);
      case 'watchmans_ward': case 'crow_swarm': case 'veil_tear':
        if (Math.hypot(t.x - p.x, t.z - p.z) > def.range) return 'range';
        if (newId === 'crow_swarm') this.ctx.effects.orbit({ tex: fxImage('crow'), color: SPELL_FX.witch.blood,
          count: 4, radius: 2, y: 1.2, size: 0.65, duration: 5, speed: 3,
          follow: () => ({ x: t.x, z: t.z }) });
        if (newId === 'veil_tear') this.ctx.effects.decal({ tex: fxImage('veilRift'), color: SPELL_FX.veilwalker.cyan,
          x: t.x, z: t.z, r: 3, duration: 2, opacity: 0.75, pulse: 5, fadeOut: 0.5 });
        return host(newId);
      case 'cremate': case 'harvest': case 'sound_the_corpse': case 'butcher': case 'lay_to_rest': {
        const c = corpse(); if (!c) return 'no_corpse';
        return host(newId, { x: c.x, z: c.z });
      }
      case 'last_light': case 'toll': case 'great_toll': {
        const spend = id === 'toll' && p.resource.value >= 25 ? 25 : id === 'great_toll' ? p.resource.value : 0;
        p.addResource(-spend);
        this.ring(p.x, p.z, def.radius);
        return host(newId, { x: p.x, z: p.z }, this.power * (1 + spend / 100), id === 'toll' && spend ? 0.6 : undefined);
      }
      case 'palm_strike': {
        const e = enemy(); if (!e && !t.boss) return 'no_target';
        const phase = ((now % 1200) + 1200) % 1200;
        const beat = phase <= 150 || phase >= 1050;
        const damage = this.power * def.power * (beat ? 1.4 : 1);
        this.sendHits(e ? [e.id] : [], damage, {}, !!t.boss);
        p.addResource(beat ? 12 : 8);
        this.ring(t.x, t.z, 1);
        return local('attack');
      }
      case 'resonant_step': {
        let dx = t.x - p.x, dz = t.z - p.z;
        const d = Math.hypot(dx, dz); if (d < 0.3) return 'no_target';
        dx /= d; dz /= d;
        const to = this.ctx.dash?.(p.x + dx * 5, p.z + dz * 5) ?? { x: p.x + dx * 5, z: p.z + dz * 5 };
        if (Math.hypot(to.x - p.x, to.z - p.z) < 0.3) return 'no_target';
        this.sendSig(newId, to.x, to.z);
        p.teleport(to.x, to.z); this.ring(to.x, to.z, 1.5);
        return local('attack');
      }
      case 'knell': case 'hex_charm': {
        const e = enemy(); if (!e) return 'no_target';
        return host(newId, { x: e.x, z: e.z });
      }
      case 'choir_of_one':
        this.choirUntil = now + 6000; this.nextChoirBeat = now + 1200;
        this.ring(p.x, p.z, 2.5, 1);
        return local();
      case 'hook_throw': {
        const e = enemy(); if (!e && !t.boss) return 'no_target';
        this.sendHits(e ? [e.id] : [], this.power * def.power, { bleed: this.power * 0.14 }, !!t.boss);
        this.ctx.effects.beam({ x: p.x, y: 1.4, z: p.z }, () => ({ x: t.x, y: 1.1, z: t.z }),
          SPELL_FX.witch.blood, 0.05, 0.25);
        this.ctx.effects.flash({ x: t.x, y: 1.1, z: t.z, color: SPELL_FX.witch.blood,
          size: 0.85, duration: 0.45, tex: fxImage('hookChain') });
        this.ring(t.x, t.z, 0.8);
        return local('attack');
      }
      case 'murder_of_crows':
        if (Math.hypot(t.x - p.x, t.z - p.z) > def.range) return 'range';
        this.murderUntil = now + 8000; this.nextMurderTick = now;
        this.ctx.effects.orbit({ tex: fxImage('crow'), color: SPELL_FX.witch.blood,
          count: 6, radius: 2.5, y: 1.5, size: 0.75, duration: 8, speed: 3.8,
          follow: () => this.ctx.aim?.() ?? { x: t.x, z: t.z } });
        return host(newId);
      case 'spirit_bolt': {
        const e = enemy(); if (!e && !t.boss) return 'no_target';
        this.sendHits(e ? [e.id] : [], this.power * def.power, {}, !!t.boss);
        this.ring(t.x, t.z, 0.8);
        return local();
      }
      case 'veil_form':
        if (!p.veilForm && p.resource.value <= 0) return 'essence';
        p.veilForm = !p.veilForm;
        this.ring(p.x, p.z, 1.2);
        return local();
      case 'echo': case 'crossing': {
        const c = this.corpse(t, def.range, true);
        if (!c) return 'no_corpse';
        return host(newId, { x: c.x, z: c.z });
      }
      case 'between_worlds':
        p.betweenUntil = now + 5000;
        this.ring(p.x, p.z, 2, 1);
        return local();
      default: return null;
    }
  }

  update(now: number) {
    const p = this.ctx.player;
    if (!p.alive) return;
    if (now < this.choirUntil && now >= this.nextChoirBeat) {
      this.nextChoirBeat += 1200;
      this.sendSig('toll', p.x, p.z, this.power * 0.5);
      this.ring(p.x, p.z, 2.5);
    }
    if (now < this.crowsUntil && now >= this.nextCrowPeck) {
      this.nextCrowPeck = now + 500;
      const e = [...this.ctx.enemies().values()].find((v) => v.state !== 'dead' && Math.hypot(v.x - p.x, v.z - p.z) <= 3);
      if (e) { this.sendHits([e.id], this.power * 0.35); this.ring(e.x, e.z, 0.6, 0.25); }
    }
    if (now < this.murderUntil && now >= this.nextMurderTick) {
      this.nextMurderTick = now + 500;
      const at = this.ctx.aim?.() ?? { x: p.x, z: p.z };
      this.sendSig('murder_of_crows', at.x, at.z, this.power);
    }
  }

  onEvent(ev: Extract<SimEvent, { t: 'newBlood' }>, mine: boolean) {
    if (!ev.ok) return;
    this.ring(ev.x, ev.z, ev.kind === 'last_light' || ev.kind === 'great_toll' ? 6 : 1.5);
    if (!mine) return;
    const p = this.ctx.player;
    if (ev.kind === 'burn_the_dead' || ev.kind === 'cremate' || ev.kind === 'harvest') p.addResource(ev.amount ?? 0);
    if (ev.kind === 'harvest') {
      this.crowsUntil = this.ctx.now() + 6000;
      this.nextCrowPeck = this.ctx.now();
      this.ctx.effects.orbit({ tex: fxImage('crow'), color: SPELL_FX.witch.blood,
        count: 3, radius: 1.1, y: 1.8, size: 0.55, duration: 6, speed: 2.7,
        follow: () => p.alive ? { x: p.x, z: p.z } : null });
    }
    if (ev.kind === 'crossing' && ev.tx != null && ev.tz != null) p.teleport(ev.tx, ev.tz);
    if (ev.kind === 'lay_to_rest') p.heal(p.stats.maxHp * 0.06);
  }
}
