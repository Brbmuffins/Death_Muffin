#pragma once
// The ordered per-tick event buffer GDScript reads once per tick (native/README.md "Design"). Each event is a header
// [type, entity id, int count, float count] in `ints`, then its ints, while its floats go to `floats` in the same order.
// Type numbers are part of the GDScript contract (client/core/dm_core_events.gd): append only.
#include <cstdint>
#include <initializer_list>
#include <vector>

namespace dm {

enum EventType : int32_t {
	EV_ENEMY_SPAWNED = 1,  // ints: def, level, elite, area, affixes (bit per Affix)  floats: x, z, max_hp
	EV_ENEMY_STATE = 2,    // ints: prev, next                     floats: (none)
	EV_ENEMY_DAMAGED = 3,  // ints: source                         floats: amount, hp
	EV_ENEMY_DIED = 4,     // ints: def, level, elite, area, source floats: x, z
	EV_ENEMY_REMOVED = 5,  // ints: (none), or 1                   floats: (none)  the body is gone (4 s after death); 1 = it was alive (DmCore.remove_enemy)
	EV_ENEMY_ATTACK = 6,   // ints: blow                           floats: aim x, aim z, windup s   (a swing began: the aim is fixed)
	EV_TELEGRAPH = 7,      // ints: tell                           floats: from x, from z, aim x, aim z, radius, seconds
	EV_CUE = 8,            // ints: cue                            floats: x, z, radius
	EV_TARGET_HIT = 9,     // id = the enemy; ints: target, hit kind  floats: damage   (GDScript applies it to the hero)
	EV_ZONE = 10,          // id = the zone; ints: zone kind, source  floats: x, z, radius, seconds
	EV_ZONE_PULSE = 11,    // id = the zone
	EV_ZONE_GONE = 12,     // id = the zone
	EV_STATUSES_CLEARED = 13,  // id = the enemy (a ghoul dug in: bleed, withered, root, slow, chill drop)
	EV_STATUS_CHANGED = 14,    // id = the body; its statuses or stacks changed (HUD chips, motes, replication)
	EV_STATUS_DOT = 15,        // id = the body; ints: status, source, killed  floats: amount (after damage taken)
	EV_STATUS_EXPIRED = 16,    // id = the body; ints: status
	EV_WITHERED_DIED = 17,     // id = the body that died carrying Withered; ints: source  floats: stacks, dps (Contagion, Plague Choir)
	// Corpses (DmCorpseField signals). The id is the corpse's own number, not an entity id.
	EV_CORPSE_ADDED = 18,      // id = the corpse; ints: kind, enemy def (-1 = risen), elite, area   floats: x, z, facing, scale
	EV_CORPSE_CONSUMED = 19,   // id = the corpse; ints: by (peer), reason   (fired before the gone event)
	EV_CORPSE_GONE = 20,       // id = the corpse; ints: reason (expired, burst, consumed, litany, raised, devoured, or an interned one)
	EV_CORPSE_RUPTURED = 21,   // id = the corpse; ints: zone id   floats: x, z, radius   (a toxic corpse burst into a pool; its EV_ZONE came just before)
	// Thralls (DmThrall and DmThrallHost signals). id = the thrall.
	EV_THRALL_RAISED = 22,     // ints: kind, owner, formation slot, empowered, champion   floats: x, z, yaw, max hp
	EV_THRALL_STATE = 23,      // ints: prev, next  (ThrallState)
	EV_THRALL_SWING = 24,      // ints: swing counter, target   floats: aim x, aim z, damage dealt (hit_dealt)
	EV_THRALL_DAMAGED = 25,    // ints: source   floats: amount (after damage taken and barrier), hp
	EV_THRALL_DIED = 26,       // ints: reason (DeathReason), owner, kind, source   floats: x, z
	EV_THRALL_REMOVED = 27,    // the body is gone (1.4 s after death)
	EV_THRALL_STATUS = 28,     // ints: target, status   floats: seconds   (status_applied: wraith chill, bone mage hex)
	EV_THRALL_BELL_HEAL = 29,  // floats: x, z, fraction   (bell_heal: a Mourning Bell wraith hit heals allies near the point)
	EV_THRALL_PLAGUE_POOL = 30,  // floats: x, z, radius, seconds, dps   (plague_pool: a plague bearer fell; today only a signal)
	EV_THRALL_HIT_EXTERNAL = 31, // ints: target (a boss), thrall kind   floats: damage   (a thrall blow on a boss: GDScript routes it to the brain)
	// Affixes (DmAffixSet)
	EV_AFFIX_MOMENT = 32,  // id = the enemy; ints: AffixMoment   floats: at x, at z, to x, to z, amount
	                       //   tell: the bell's ring starts (amount = windup s, with an EV_TELEGRAPH toll); toll: it sounds (amount = radius);
	                       //   hungering: a corpse eaten at `to` (amount = health healed); vengeful: the body burst (amount = 1.8); unveil
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
	// The same event from arrays (a co-op guest re-emits what the wire carried).
	void push_raw(int32_t p_type, int32_t p_id, const int32_t *p_ints, int32_t p_ni, const float *p_floats, int32_t p_nf) {
		ints.push_back(p_type);
		ints.push_back(p_id);
		ints.push_back(p_ni);
		ints.push_back(p_nf);
		ints.insert(ints.end(), p_ints, p_ints + p_ni);
		floats.insert(floats.end(), p_floats, p_floats + p_nf);
		count++;
	}
};

} // namespace dm
