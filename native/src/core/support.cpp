// The Crypt Deacon (the old game's dm_enemy_deacon.gd): a robed caster that keeps its distance (the state is World::engage) and, whenever its cooldown
// is up and it is not silenced, does the first of these, with or without a target: RAISE a corpse within 8 m (a wind-up channel, then the corpse is
// consumed "raised" and a Risen stands on it), SANCTIFY the most wounded other ally in range, CURSE its target in range (the plain blow, World::begin_attack
// and strike). The scan runs at the target-scan rate. Differences from the old game are noted in native/README.md.
#include "world.h"

namespace dm {

// DmEnemyDeacon._physics_process after the base's: the scan timer runs every tick (it goes negative while the cooldown runs, so the first scan after it
// is up comes at once), then every SCAN_S; a scan that finds the body busy or silenced still spends its turn.
void World::tick_support(int32_t p_slot, double p_dt) {
	Enemy &e = enemies[p_slot];
	e.support_t -= p_dt;
	if (e.support_t > 0.0 || e.attack_cd > 0.0) {
		return;
	}
	e.support_t = SCAN_S;
	if (e.state != IDLE && e.state != CHASE && e.state != RETURN) {
		return;
	}
	if (silenced(e)) {
		return;
	}
	// 1. RAISE: the nearest corpse within 8 m (any area, as the field's unfiltered query), id breaking ties.
	if (!corpses.empty()) {
		corpses_in_radius(e.x, e.z, SUPPORT_CORPSE_RANGE, -1, id_scratch);
		if (!id_scratch.empty()) {
			const Corpse &c = corpses[size_t(corpse_index(id_scratch[0]))];
			e.raise_pending = c.id;
			e.aim_x = float(c.x);
			e.aim_z = float(c.z);
			change(p_slot, ATTACK);  // begin_attack adopts the pending corpse
			return;
		}
	}
	// 2. SANCTIFY: the status, the cooldown x SANCTIFIED.cooldownMult (of the def's cooldown: an elite's 0.8 does not apply), and the cue at the ally.
	const int32_t ally = sanctify_target(e);
	if (ally >= 0) {
		Enemy &a = enemies[ally];
		apply_status(a, st_sanctified, e.id, 1.0, tun.sanct_s, 0.0, -1.0, 0.0);
		e.attack_cd = defs[e.def].cooldown_s * tun.sanct_cooldown_mult;
		events.push(EV_CUE, e.id, { CUE_SANCTIFY }, { a.x, a.z, 0.0f });
	}
}

// DmEnemyDeacon.sanctify_target: the most wounded (the lowest health fraction below 0.999, the first in spawn order on a tie) living body of another kind within
// range, not already blessed. Rising, underground and fallen bodies are skipped.
int32_t World::sanctify_target(const Enemy &e) const {
	int32_t best = -1;
	double best_frac = 0.999;
	const double r2 = tun.sanct_range * tun.sanct_range;
	for (const Enemy &o : enemies) {
		if (o.id == e.id || o.def == e.def || o.hp <= 0.0 || o.state == DEAD || o.state == RISING || o.state == BURROW) {
			continue;
		}
		const float dx = o.x - e.x, dz = o.z - e.z;
		if (double(dx) * dx + double(dz) * dz > r2) {
			continue;
		}
		const double frac = o.hp / o.max_hp;
		if (frac >= best_frac) {
			continue;
		}
		if (st_sanctified >= 0 && o.st.find(st_sanctified) >= 0) {
			continue;
		}
		best_frac = frac;
		best = o.slot;
	}
	return best;
}

// DmEnemyDeacon.strike for a raise, at the end of the wind-up: the corpse is consumed atomically ("raised"); only if this body got it does a Risen stand
// on the place where the corpse lay when the trigger chose it, at this body's level and multipliers (the wave director's `_risen_for`), as rising as a
// wave's. A corpse gone in the meantime (expired, spent by a rite or eaten) raises nothing; the cooldown was set by the attack state before the strike.
void World::raise_corpse(Enemy &e) {
	e.swing_raise = false;
	const int32_t cid = e.raise_id;
	e.raise_id = -1;
	if (cid < 0 || !consume_corpse(cid, 1, CR_RAISED)) {
		return;
	}
	const auto it = def_index.find("risen");
	if (it == def_index.end()) {
		return;
	}
	pending_spawns.push_back(make_enemy(it->second, e.aim_x, e.aim_z, e.level, e.hp_mult, e.damage_mult, false, e.area, true, 0));
	enter(pending_spawns.back(), -1);
}

} // namespace dm
