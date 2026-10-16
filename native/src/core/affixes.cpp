// Elite affixes: the host rules of DmAffixSet (godot/next/affixes/dm_affix_set.gd), line for line. The look (rings, motes, the one-off bursts)
// stays with the client, driven by EV_AFFIX_MOMENT and EV_TELEGRAPH. Rolling stays with the director (DmAffixSet.roll); spawn_enemy takes the list.
#include "world.h"

namespace dm {

// DmAffixSet._physics_process: the shroud check every LOOK_S from the first tick (even while rising), the rest only while the body acts.
void World::tick_affixes(int32_t p_slot, double p_dt) {
	Enemy &e = enemies[p_slot];
	if (e.state == DEAD) {
		return;
	}
	if (e.affixes & (1 << AF_SHROUDED)) {
		e.shroud_t -= p_dt;
		if (e.shroud_t <= 0.0) {
			e.shroud_t = AFFIX_LOOK_S;
			tick_shroud(e);
		}
	}
	if (e.state == RISING || e.state == HURT || e.state == BURROW) {
		return;
	}
	e.affix_t += p_dt;
	if (e.affixes & (1 << AF_BELL_TOLLED)) {
		tick_bell(e, p_dt);
	}
	// The toll can kill a bursting thrall whose burst kills this body. Today the hunger check still runs then and can feed the dead body;
	// the core stops at death (native/README.md "Differences").
	if ((e.affixes & (1 << AF_HUNGERING)) && e.state != DEAD) {
		tick_hunger(e, p_dt);
	}
}

// Every intervalS a ring of r telegraphs for windupS where the body stood, then every target inside takes damage x damageMult (kind toll).
void World::tick_bell(Enemy &e, double p_dt) {
	if (e.toll_at >= 0.0) {
		if (e.affix_t >= e.toll_at) {
			e.toll_at = -1.0;
			// DmEnemy.targets_within: every valid target (heroes, then living thralls) within r, flat, in doubles; then each is hit.
			// Its own list: a thrall's death burst runs queries that reuse the shared scratch. The table never moves inside the tick
			// (flush_spawns), so `e` holds even when that burst kills this body; the toll still sounds, as today.
			const double r2 = tun.bell_r * tun.bell_r;
			toll_hits.clear();
			each_target([&](const Tgt &t) {
				const double dx = double(t.x) - double(e.toll_x), dz = double(t.z) - double(e.toll_z);
				if (dx * dx + dz * dz <= r2) {
					toll_hits.push_back(t.id);
				}
			});
			const double dmg = e.damage * tun.bell_damage;
			for (size_t i = 0; i < toll_hits.size(); i++) {
				hit_id(e.id, toll_hits[i], dmg, HK_TOLL);
			}
			affix_moment(e, AM_TOLL, e.toll_x, e.toll_z, 0.0f, 0.0f, float(tun.bell_r));
		}
		return;
	}
	e.toll_cd = (e.toll_cd < 0.0 ? tun.bell_interval : e.toll_cd) - p_dt;
	if (e.toll_cd > 0.0) {
		return;
	}
	e.toll_cd = tun.bell_interval;
	e.toll_at = e.affix_t + tun.bell_windup;
	e.toll_x = e.x;
	e.toll_z = e.z;
	events.push(EV_TELEGRAPH, e.id, { TELL_TOLL }, { e.x, e.z, e.x, e.z, float(tun.bell_r), float(tun.bell_windup) });
	affix_moment(e, AM_TELL, e.x, e.z, e.x, e.z, float(tun.bell_windup));
}

// While hurt, every intervalS: eat the nearest corpse within reach in the body's area (the field's atomic consume, reason devoured) and heal
// healFrac of max health, capped at what is missing. Nothing to eat: look again in 0.5 s.
void World::tick_hunger(Enemy &e, double p_dt) {
	e.hunger_cd = (e.hunger_cd < 0.0 ? tun.hunger_interval : e.hunger_cd) - p_dt;
	if (e.hunger_cd > 0.0) {
		return;
	}
	int32_t cid = 0;
	if (e.hp < e.max_hp) {
		corpses_in_radius(e.x, e.z, tun.hunger_reach, e.area, id_scratch);
		if (!id_scratch.empty()) {
			cid = id_scratch[0];
		}
	}
	if (cid == 0) {
		e.hunger_cd = HUNGER_RETRY_S;
		return;
	}
	const Corpse &c = corpses[corpse_index(cid)];
	const float cx = float(c.x), cz = float(c.z);
	if (!consume_corpse(cid, 1, reason_id("devoured"))) {
		e.hunger_cd = HUNGER_RETRY_S;
		return;
	}
	e.hunger_cd = tun.hunger_interval;
	const double heal = std::min(e.max_hp - e.hp, e.max_hp * tun.hunger_heal);
	e.hp += heal;
	affix_moment(e, AM_HUNGERING, e.x, e.z, cx, cz, float(heal));
}

// The ward holds unless a friendly Miasma covered the body in the last 350 ms (DmCore.cover_miasma, the rite's 10 Hz scan).
void World::tick_shroud(Enemy &e) {
	if (st_shrouded < 0) {
		return;
	}
	const bool in_cloud = clock - e.miasma_at < MIASMA_HOLD_S;
	if (in_cloud == (e.st.find(st_shrouded) >= 0)) {
		if (in_cloud) {
			remove_status(e, st_shrouded);
		} else {
			apply_status(e, st_shrouded, 0, 1.0, -1.0, 0.0, -1.0, 0.0);
		}
	}
}

bool World::strip_shroud(int32_t p_slot) {
	Enemy &e = enemies[p_slot];
	if (!(e.affixes & (1 << AF_SHROUDED))) {
		return false;
	}
	e.affixes &= uint8_t(~(1 << AF_SHROUDED));
	if (st_shrouded >= 0) {
		remove_status(e, st_shrouded);
	}
	affix_moment(e, AM_UNVEIL, e.x, e.z, 0.0f, 0.0f, 0.0f);
	return true;
}

// Vengeful, inside the kill: the burst, then `risen` Risen on a 1.4 m ring at a random turn (the body's own stream; today an unseeded randf),
// snapped to the navmesh, at the body's level and hp/damage multipliers, in its area, rising. They join the table in flush_spawns().
void World::vengeance(Enemy &e) {
	affix_moment(e, AM_VENGEFUL, e.x, e.z, 0.0f, 0.0f, 1.8f);
	const auto it = def_index.find("risen");
	if (it == def_index.end()) {
		return;
	}
	const int32_t n = tun.vengeful_risen;
	const double spin = e.rng.next_double() * TAU;
	const float at_x = e.x, at_z = e.z;
	const int32_t level = e.level, area = e.area;
	const double hp_mult = e.hp_mult, damage_mult = e.damage_mult;
	for (int32_t i = 0; i < n; i++) {
		const double a = spin + double(i) / double(n) * TAU;
		float px = at_x + float(std::cos(a)) * float(VENGEFUL_RING);
		float pz = at_z + float(std::sin(a)) * float(VENGEFUL_RING);
		if (nav.clamp) {
			nav.clamp(nav.user, px, pz);
		}
		pending_spawns.push_back(make_enemy(it->second, px, pz, level, hp_mult, damage_mult, false, area, true, 0));
		enter(pending_spawns.back(), -1);
	}
}

void World::affix_moment(const Enemy &e, int32_t p_kind, float p_ax, float p_az, float p_tx, float p_tz, float p_amount) {
	events.push(EV_AFFIX_MOMENT, e.id, { p_kind }, { p_ax, p_az, p_tx, p_tz, p_amount });
}

} // namespace dm
