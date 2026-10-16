#pragma once
// The ordered per-tick event buffer GDScript reads once per tick (native/README.md "Design"). Each event is a header
// [type, entity id, int count, float count] in `ints`, then its ints, while its floats go to `floats` in the same order.
// Type numbers are part of the GDScript contract (client/core/dm_core_events.gd): append only.
#include <cstdint>
#include <initializer_list>
#include <vector>

namespace dm {

enum EventType : int32_t {
	EV_ENEMY_SPAWNED = 1,  // ints: def, level, elite, area        floats: x, z, max_hp
	EV_ENEMY_STATE = 2,    // ints: prev, next                     floats: (none)
	EV_ENEMY_DAMAGED = 3,  // ints: source                         floats: amount, hp
	EV_ENEMY_DIED = 4,     // ints: def, level, elite, area, source floats: x, z
	EV_ENEMY_REMOVED = 5,  // ints: (none)                         floats: (none)  the body is gone (4 s after death)
	EV_ENEMY_ATTACK = 6,   // ints: blow                           floats: aim x, aim z, windup s   (a swing began: the aim is fixed)
	EV_TELEGRAPH = 7,      // ints: tell                           floats: from x, from z, aim x, aim z, radius, seconds
	EV_CUE = 8,            // ints: cue                            floats: x, z, radius
	EV_TARGET_HIT = 9,     // id = the enemy; ints: target, hit kind  floats: damage   (GDScript applies it to the hero)
	EV_ZONE = 10,          // id = the zone; ints: zone kind, source  floats: x, z, radius, seconds
	EV_ZONE_PULSE = 11,    // id = the zone
	EV_ZONE_GONE = 12,     // id = the zone
	EV_STATUSES_CLEARED = 13,  // id = the enemy (a ghoul dug in: bleed, withered, root, slow, chill drop)
};

struct Events {
	std::vector<int32_t> ints;
	std::vector<float> floats;
	int32_t count = 0;

	void clear() {
		ints.clear();
		floats.clear();
		count = 0;
	}
	void push(EventType p_type, int32_t p_id, std::initializer_list<int32_t> p_ints, std::initializer_list<float> p_floats) {
		ints.push_back(int32_t(p_type));
		ints.push_back(p_id);
		ints.push_back(int32_t(p_ints.size()));
		ints.push_back(int32_t(p_floats.size()));
		ints.insert(ints.end(), p_ints);
		floats.insert(floats.end(), p_floats);
		count++;
	}
};

} // namespace dm
