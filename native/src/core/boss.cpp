// What the bosses' GDScript brains call on the core beyond damage and queries (client/next/bosses/CORE-INTEGRATION.md):
//   - a hostile ground zone for a boss (the Plague Saint's rot pools, the Cinder Regent's coals, firebreak and embers): DmHostileZone.spawn with the boss as the source. It is the
//     same record as a dust cloud or a corpse's toxic pool (step_zones pulses it), so guests, the effects and the Saint's "am I standing in rot" query all see it;
//   - a body's health (the Abbess gives each niche a share of her own maximum when it spawns), with the wire record that tells a guest the new maximum.
#include "world.h"

#include <algorithm>

namespace dm {

int32_t World::add_zone(int32_t p_kind, float p_x, float p_z, double p_radius, double p_seconds, double p_dps, int32_t p_source) {
	Zone z;
	z.id = next_id++;
	z.kind = p_kind;
	z.source = p_source;
	z.hit_kind = p_kind == ZONE_EMBER ? HK_BURN : (p_kind == ZONE_TOXIC ? HK_TOXIC : HK_DUST);  // DmHostileZone.damage_kind: burning ground is "burn", the others their own name
	z.x = p_x;
	z.z = p_z;
	z.radius = p_radius;
	z.lifetime = p_seconds;
	z.dps = p_dps;
	zones.push_back(z);
	events.push(EV_ZONE, z.id, { z.kind, z.source }, { z.x, z.z, float(z.radius), float(z.lifetime) });
	return z.id;
}

void World::zones_of(int32_t p_kind, std::vector<float> &out) const {
	out.clear();
	for (const Zone &z : zones) {
		if (z.kind == p_kind && z.age < z.lifetime) {
			out.push_back(z.x);
			out.push_back(z.z);
			out.push_back(float(z.radius));
		}
	}
}

int32_t World::remove_zones_of(int32_t p_source) {
	if (p_source == 0) {
		return 0;  // 0 is "no source" (a burst corpse's pool): never a body to clear
	}
	size_t w = 0;
	int32_t n = 0;
	for (size_t i = 0; i < zones.size(); i++) {
		if (zones[i].source == p_source) {
			events.push(EV_ZONE_GONE, zones[i].id, {}, {});
			n++;
			continue;
		}
		zones[w++] = zones[i];
	}
	zones.resize(w);
	return n;
}

bool World::set_enemy_hp(int32_t p_id, double p_hp, double p_max_hp) {
	const auto it = enemy_slot.find(p_id);
	if (it == enemy_slot.end() || enemies[size_t(it->second)].state == DEAD || !(p_max_hp > 0.0)) {
		return false;
	}
	Enemy &e = enemies[size_t(it->second)];
	e.max_hp = p_max_hp;
	e.hp = std::min(std::max(p_hp, 0.0), p_max_hp);
	queue_enemy_max_hp(p_id);
	return true;
}

// A guest knows an enemy's health as a fraction of the maximum its spawn event named: a changed maximum travels as a record of its own, after the events before it.
void World::queue_enemy_max_hp(int32_t p_id) {
	if (!rep.replicating) {
		return;
	}
	pump_reliable();
	const auto it = enemy_slot.find(p_id);
	if (it == enemy_slot.end()) {
		return;
	}
	ByteWriter w(rep.rel);
	w.u8(WR_ENEMY_MAX_HP);
	w.uvar(uint32_t(p_id));
	w.f32(float(enemies[size_t(it->second)].max_hp));
	rep.rel_count++;
}

void World::puppet_enemy_max_hp(int32_t p_id, float p_max_hp) {
	const auto it = enemy_slot.find(p_id);
	if (it != enemy_slot.end() && p_max_hp > 0.0f) {
		Enemy &e = enemies[size_t(it->second)];
		e.max_hp = p_max_hp;
		if (e.state != DEAD) {
			e.hp = (e.net_hpq == 0 ? 0.0 : double(e.net_hpq) / double(HP_ONE)) * e.max_hp;
		}
	}
}

} // namespace dm
