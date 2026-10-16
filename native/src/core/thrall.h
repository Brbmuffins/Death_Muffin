#pragma once
// A raised thrall: a port of DmThrall (godot/next/thralls/dm_thrall.gd), its brain and the host's bookkeeping (dm_thrall_host.gd).
#include <cstdint>
#include <limits>

#include "body.h"
#include "rng.h"

namespace dm {

// DmThralls.KINDS order (wire ids of the kind): append only.
enum ThrallKind : int32_t { TK_WARRIOR = 0, TK_SHIELDBEARER, TK_HOUND, TK_WRAITH, TK_ARCHER, TK_BONEMAGE, TK_PLAGUEBEARER, TK_COLOSSUS, TK_COUNT };
// DmThrall.S wire ids: append only.
enum ThrallState : int32_t { TS_RISING = 0, TS_IDLE, TS_MOVE, TS_ATTACK, TS_DEAD };
// DmThrall.kill() reasons: append only.
enum DeathReason : int32_t { DR_KILLED = 0, DR_CRUMBLED, DR_SACRIFICED, DR_DECAYED };

constexpr const char *THRALL_KIND_NAMES[TK_COUNT] = { "warrior", "shieldbearer", "hound", "wraith", "archer", "bonemage", "plaguebearer", "colossus" };
constexpr const char *DEATH_REASON_NAMES[4] = { "killed", "crumbled", "sacrificed", "decayed" };

// The stats DmThralls.raise_stats / colossus_stats compute in GDScript (today's DmThrall.configure() keys).
struct ThrallSpec {
	int32_t kind = TK_WARRIOR;
	double hp = 1, max_hp = 1, damage = 1, interval = 1, range = 1.3, speed = 5, ally_heal = 0, lifetime_s = 0;
	bool empowered = false, champion = false;
};

struct Thrall : Body {
	int32_t kind = TK_WARRIOR, owner = 0, formation_slot = 0, formation_rank = 0, formation_count = 3;
	int32_t state = TS_RISING, target = 0, swing_n = 0, dead_reason = -1, last_source = 0;
	bool empowered = false, champion = false, has_nav_goal = false, has_seat_prev = false;
	float x = 0, z = 0, yaw = 0, aim_x = 0, aim_z = 0, sep_x = 0, sep_z = 0, nav_gx = 0, nav_gz = 0, seat_px = 0, seat_pz = 0;
	double damage = 1, interval = 1, attack_range = 1.3, speed = 5, radius = 0.4, ally_heal = 0, lifetime_s = 0;
	double death_burst_frac = 0, mark_mult = 1, born_at = 0;
	double rally_t = 0, stun_t = 0, cursed_t = 0, state_t = 0, attack_cd = 0.4, age = 0, repath_t = 0, scan_t = 0;
	double want_vx = 0, want_vz = 0, ground_speed = 0;
	int32_t path_len = 0, path_i = 0;
	float path[PATH_POINTS * 2] = {};
	Rng rng;

	bool alive_target() const { return !dead && state != TS_RISING; }  // DmThrall.dm_alive()
};

} // namespace dm
