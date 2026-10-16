#pragma once
// What DmStatusSet needs from the body that owns it, shared by enemies and thrall so the status logic exists once (native/README.md
// "Design"): the id, health, the multipliers the set writes to its owner (speed_mult, attack_rate_mult) and reads for damage taken, and the set.
#include <cmath>
#include <cstdint>

#include "status.h"

namespace dm {

constexpr double PI = 3.14159265358979323846;
constexpr double TAU = 2.0 * PI;

inline double lerp_angle(double p_from, double p_to, double p_w) {  // Godot's lerp_angle
	const double diff = std::fmod(p_to - p_from, TAU);
	const double dist = std::fmod(2.0 * diff, TAU) - diff;
	return p_from + dist * p_w;
}

constexpr int PATH_MAX = 24;  // waypoints kept per body (a NavigationAgent3D path, cut to what the body walks)

struct Body {
	int32_t id = 0;
	int32_t slot = 0;  // index in its table (enemies or thralls); kept current by stable compaction
	bool is_thrall = false, dead = false, frenzy = false;  // frenzy: the def carries Frenzy (DmStatusSet._frenzy)
	double hp = 1, max_hp = 1, speed_mult = 1, attack_rate_mult = 1, taken_mult = 1;
	StatusSet st;
};

} // namespace dm
