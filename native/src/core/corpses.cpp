#include "world.h"

#include <algorithm>

// Corpses are a port of the host logic of DmCorpseField (godot/next/corpses/dm_corpse_field.gd): lay on death, cap, lifetime, toxic rupture,
// queries, atomic consume. Views, replication and the Veilwalker's echo corpses are not part of it. Differences from today are listed in
// native/README.md.

namespace dm {

World::World() {
	for (const char *n : CORPSE_REASON_NAMES) {
		reasons.push_back(n);
	}
}

int32_t World::reason_id(const std::string &p_reason) {
	for (size_t i = 0; i < reasons.size(); i++) {
		if (reasons[i] == p_reason) {
			return int32_t(i);
		}
	}
	reasons.push_back(p_reason);
	return int32_t(reasons.size()) - 1;
}

int32_t World::corpse_index(int32_t p_id) const {
	for (size_t i = 0; i < corpses.size(); i++) {
		if (corpses[i].id == p_id) {
			return int32_t(i);
		}
	}
	return -1;
}

// DmCorpseField._on_enemy_died: a corpse of the def's kind at the body's feet (none for kind "none"), then the def's extra "risen" corpses on
// a 1.6 m ring. Called from kill(), after the statuses are cleared and before the died event, where the corpse field sits among the listeners.
void World::lay_corpses(const Enemy &e) {
	const EnemyDef &d = defs[e.def];
	if (d.corpse == CK_NONE) {
		return;
	}
	const double scale = double(float(d.scale * (e.elite ? tun.elite_scale : 1.0)));  // the node's scale.x (a float32 vector)
	add_corpse(double(e.x), double(e.z), d.corpse, e.def, e.elite, double(e.yaw), scale, e.area);
	// Echo corpses (a Veilwalker in the area: every corpse also drops a 20 s echo at +0.45 m) come with the Veilwalker.
	const int32_t dc = d.death_corpses;
	if (dc > 1) {
		const auto it = def_index.find("risen");
		const int32_t risen = it != def_index.end() ? it->second : ENEMY_RISEN;
		for (int32_t k = 1; k < dc; k++) {
			const double a = double(e.yaw) + double(k) / double(dc - 1) * TAU;
			const double x = double(e.x) + std::sin(a) * legion.extra_ring;
			const double z = double(e.z) + std::cos(a) * legion.extra_ring;
			add_corpse(x, z, d.corpse, risen, false, a, 1.0, e.area);
		}
	}
}

// DmCorpseField.add_corpse: at the cap the oldest goes first ("expired"); the new one lives CORPSE_LIFETIME x the life multiplier, and a
// toxic one ruptures after TOXIC_RUPTURE. Returns the id, 0 for kind "none".
int32_t World::add_corpse(double p_x, double p_z, int32_t p_kind, int32_t p_def, bool p_elite, double p_facing, double p_scale, int32_t p_area) {
	if (p_kind == CK_NONE) {
		return 0;
	}
	if (int32_t(corpses.size()) >= legion.max_corpses) {
		int32_t oldest = -1;
		for (int32_t i = 0; i < int32_t(corpses.size()); i++) {
			if (oldest < 0 || corpses[i].born_at < corpses[oldest].born_at) {
				oldest = i;
			}
		}
		if (oldest >= 0) {
			remove_corpse(oldest, CR_EXPIRED);
		}
	}
	Corpse c;
	c.id = next_corpse_id++;
	c.kind = p_kind;
	c.def = p_def;
	c.area = p_area;
	c.elite = p_elite;
	c.x = p_x;
	c.z = p_z;
	c.facing = p_facing;
	c.scale = p_scale;
	c.born_at = corpse_time;
	c.expires_at = corpse_time + legion.corpse_lifetime * corpse_life_mult;
	c.rupture_at = p_kind == CK_TOXIC ? corpse_time + legion.toxic_rupture : std::numeric_limits<double>::infinity();
	corpse_next_due = std::min(corpse_next_due, std::min(c.expires_at, c.rupture_at));
	corpses.push_back(c);
	events.push(EV_CORPSE_ADDED, c.id, { c.kind, c.def, c.elite ? 1 : 0, c.area }, { float(c.x), float(c.z), float(c.facing), float(c.scale) });
	return c.id;
}

void World::remove_corpse(int32_t p_index, int32_t p_reason) {  // DmCorpseField._remove
	const int32_t id = corpses[p_index].id;
	corpses.erase(corpses.begin() + p_index);
	events.push(EV_CORPSE_GONE, id, { p_reason }, {});
}

// DmCorpseField.consume: true for exactly one caller; false when it is already gone. The consumed event comes before the gone event.
bool World::consume_corpse(int32_t p_id, int32_t p_by, int32_t p_reason) {
	const int32_t i = corpse_index(p_id);
	if (i < 0) {
		return false;
	}
	events.push(EV_CORPSE_CONSUMED, p_id, { p_by, p_reason }, {});
	remove_corpse(i, p_reason);
	return true;
}

// DmCorpseField.step, in the corpse phase of the tick. The clock is the field's own; nothing is scanned until something is due.
void World::step_corpses(double p_dt) {
	corpse_time += p_dt;
	if (corpse_time < corpse_next_due) {
		return;
	}
	corpse_next_due = std::numeric_limits<double>::infinity();
	id_scratch.clear();  // `corpses.values()` is a copy, so a removal in the loop does not skip anything
	for (const Corpse &c : corpses) {
		id_scratch.push_back(c.id);
	}
	for (int32_t id : id_scratch) {
		const int32_t i = corpse_index(id);
		if (i < 0) {
			continue;
		}
		const Corpse c = corpses[i];
		if (corpse_time >= c.rupture_at) {
			remove_corpse(i, CR_BURST);
			rupture_corpse(c);
		} else if (corpse_time >= c.expires_at) {
			remove_corpse(i, CR_EXPIRED);
		} else {
			corpse_next_due = std::min(corpse_next_due, std::min(c.expires_at, c.rupture_at));
		}
	}
}

// DmCorpseField._rupture: the corpse is gone ("burst") and a hostile toxic pool takes its place: radius TOXIC_R x scale, TOXIC_S seconds,
// a pulse every TOXIC_TICK for TOXIC_DMG x damage_scale(area level) (dps x tick_s, as the zone computes it).
void World::rupture_corpse(const Corpse &c) {
	Zone z;
	z.id = next_id++;
	z.kind = ZONE_TOXIC;
	z.source = 0;
	z.hit_kind = HK_TOXIC;
	z.x = float(c.x);
	z.z = float(c.z);
	z.radius = legion.toxic_r * c.scale;
	z.lifetime = legion.toxic_s;
	z.dps = legion.toxic_dmg * damage_scale(double(area_level(c.area))) / legion.toxic_tick;
	z.period = legion.toxic_tick;
	zones.push_back(z);
	events.push(EV_ZONE, z.id, { z.kind, z.source }, { z.x, z.z, float(z.radius), float(z.lifetime) });
	events.push(EV_CORPSE_RUPTURED, c.id, { z.id }, { z.x, z.z, float(z.radius) });
}

// DmCorpseField.corpses_in_radius: within r of the point, nearest first, the id breaking ties (`hits.sort()` on [d2, id]). area < 0 = any area.
void World::corpses_in_radius(float p_x, float p_z, double p_r, int32_t p_area, std::vector<int32_t> &out) const {
	hit_scratch.clear();
	const double r2 = p_r * p_r;
	for (const Corpse &c : corpses) {
		if (p_area >= 0 && c.area != p_area) {
			continue;
		}
		const double dx = c.x - double(p_x), dz = c.z - double(p_z);
		const double d2 = dx * dx + dz * dz;
		if (d2 <= r2) {
			hit_scratch.emplace_back(d2, c.id);
		}
	}
	std::sort(hit_scratch.begin(), hit_scratch.end());
	out.clear();
	for (const auto &h : hit_scratch) {
		out.push_back(h.second);
	}
}

// DmCorpseField.pick_corpse, the two-stage rule: the nearest to the aim within pick_r AND within max_range of the caster; else the nearest to the
// caster within 7 m. A corpse of another area is skipped (area < 0 = any; a corpse with no area is never skipped). Distances are Vector2 lengths.
int32_t World::pick_corpse(float p_ax, float p_az, double p_pick_r, double p_max_range, float p_fx, float p_fz, int32_t p_area) const {
	const auto no_area = area_index.find("");
	const int32_t blank = no_area != area_index.end() ? no_area->second : -2;
	int32_t best = 0, nearest = 0;
	double best_d = p_pick_r, near_d = legion.fallback_pick_range;
	for (const Corpse &c : corpses) {
		if (p_area >= 0 && c.area != blank && c.area != p_area) {
			continue;
		}
		const float fdx = float(c.x - double(p_fx)), fdz = float(c.z - double(p_fz));
		const float adx = float(c.x - double(p_ax)), adz = float(c.z - double(p_az));
		const double fd = std::sqrt(fdx * fdx + fdz * fdz);
		const double d = std::sqrt(adx * adx + adz * adz);
		if (d < best_d && fd <= p_max_range) {
			best_d = d;
			best = c.id;
		}
		if (fd < near_d) {
			near_d = fd;
			nearest = c.id;
		}
	}
	return best != 0 ? best : nearest;
}

} // namespace dm
