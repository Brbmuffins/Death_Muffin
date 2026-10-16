#include "world.h"

#include <algorithm>

// The thrall brain is a port of DmThrall (godot/next/thralls/dm_thrall.gd); the legion bookkeeping (raise with make_room, formation seats,
// separation, rally, sacrifice) ports the simulation parts of DmThrallHost (dm_thrall_host.gd) and DmThralls.make_room (rules/combat/dm_thralls.gd).
// Stats arrive computed (DmThralls.raise_stats stays GDScript). Comments name the GDScript each piece mirrors; differences from today are
// listed in native/README.md.

namespace dm {

namespace {
// Literals inside dm_thrall.gd / dm_thrall_host.gd (not named constants there).
constexpr double SEAT_RADIUS = 1.9;         // _follow: the formation ring around the owner
constexpr double SEAT_CLOSE = 0.5;          // _follow: a seat this close is held without walking
constexpr double SEAT_FAR = 6.0, SEAT_FAR_PACE = 1.35;  // _follow: more than 6 m behind, 1.35x pace
constexpr double SEAT_MIN_PACE = 0.05, SEAT_SPEED_CAP = 12.0;
constexpr double ATTACK_HOLD_S = 0.5;       // _engage: ATTACK relaxes to IDLE after 0.5 s between swings
constexpr double THRALL_PATH_DESIRED = 1.0; // the thrall agent's path_desired_distance (the enemy's is 0.5)
constexpr double SEP_PUSH = 6.0;            // the host's soft separation: push k
constexpr double MIN_STEP_DT = 0.0001;
} // namespace

// ---------------------------------------------------------------------------------------------------------------- raising (DmThrallHost)

// DmThrallHost._next_slot: the lowest formation slot no living thrall of this owner holds.
int32_t World::next_formation_slot(int32_t p_owner) const {
	for (int32_t s = 0;; s++) {
		bool used = false;
		for (const Thrall &t : thralls) {
			if (!t.dead && t.owner == p_owner && t.formation_slot == s) {
				used = true;
				break;
			}
		}
		if (!used) {
			return s;
		}
	}
}

// DmThrallHost._reform: rank by slot among the owner's living, and their count.
void World::reform_thralls(int32_t p_owner) {
	int32_t n = 0;
	for (const Thrall &t : thralls) {
		if (!t.dead && t.owner == p_owner) {
			n++;
		}
	}
	for (Thrall &t : thralls) {
		if (t.dead || t.owner != p_owner) {
			continue;
		}
		int32_t rank = 0;
		for (const Thrall &o : thralls) {
			if (!o.dead && o.owner == p_owner && o.formation_slot < t.formation_slot) {
				rank++;
			}
		}
		t.formation_rank = rank;
		t.formation_count = n;
	}
}

// DmThralls.make_room: crumble the oldest ordinary thrall first, a Colossus last, until `weight` more places fit under `cap`.
void World::make_room(int32_t p_owner, double p_cap, double p_weight) {
	room_scratch.clear();
	for (int32_t i = 0; i < int32_t(thralls.size()); i++) {
		if (!thralls[i].dead && thralls[i].owner == p_owner) {
			room_scratch.push_back(i);
		}
	}
	std::stable_sort(room_scratch.begin(), room_scratch.end(), [this](int32_t a, int32_t b) {
		const Thrall &x = thralls[a], &y = thralls[b];
		const int32_t kx = x.kind == TK_COLOSSUS ? 1 : 0, ky = y.kind == TK_COLOSSUS ? 1 : 0;
		if (kx != ky) {
			return kx < ky;
		}
		if (x.born_at != y.born_at) {
			return x.born_at < y.born_at;
		}
		return a < b;
	});
	double used = 0.0;
	for (int32_t i : room_scratch) {
		used += thrall_weight(thralls[i].kind);
	}
	size_t idx = 0;
	while (idx < room_scratch.size() && used + p_weight > p_cap) {
		const int32_t slot = room_scratch[idx++];
		used -= thrall_weight(thralls[slot].kind);
		crumbled_out.push_back(thralls[slot].id);
		kill_thrall(slot, DR_CRUMBLED, 0);
	}
}

int32_t World::raise_thrall(const ThrallSpec &p_spec, int32_t p_owner, float p_x, float p_z, float p_yaw, double p_cap) {
	const External *own = find_external(p_owner);
	if (!own || !own->alive || p_spec.kind < 0 || p_spec.kind >= TK_COUNT) {  // DmThrallHost._owner_alive
		return 0;
	}
	crumbled_out.clear();
	if (p_spec.kind == TK_COLOSSUS) {  // _raise_colossus: an older Colossus of the owner gives way first
		for (int32_t i = 0; i < int32_t(thralls.size()); i++) {
			if (!thralls[i].dead && thralls[i].owner == p_owner && thralls[i].kind == TK_COLOSSUS) {
				kill_thrall(i, DR_CRUMBLED, 0);
			}
		}
	}
	if (p_cap >= 0.0) {
		make_room(p_owner, p_cap, thrall_weight(p_spec.kind));
	}
	Thrall t;
	t.id = next_id++;
	t.is_thrall = true;
	t.slot = int32_t(thralls.size());
	t.kind = p_spec.kind;
	t.owner = p_owner;
	t.max_hp = p_spec.max_hp;
	t.hp = p_spec.hp;
	t.damage = p_spec.damage;
	t.interval = p_spec.interval;
	t.attack_range = p_spec.range;
	t.speed = p_spec.speed;
	t.empowered = p_spec.empowered;
	t.champion = p_spec.champion;
	t.ally_heal = p_spec.ally_heal;
	t.lifetime_s = p_spec.lifetime_s;
	t.radius = p_spec.kind == TK_COLOSSUS ? 0.8 : 0.4;  // DmThrall._ready
	t.born_at = double(t.id);  // ordering only: the oldest crumbles first
	t.x = p_x;
	t.z = p_z;
	t.yaw = p_yaw;
	t.formation_slot = next_formation_slot(p_owner);
	for (size_t i = 0; i < legion_owner.size(); i++) {
		if (legion_owner[i] == p_owner) {
			t.death_burst_frac = legion_burst[i];
		}
	}
	// DmThrall._ready, then DmStatusSet._ready: the draws come from this thrall's own stream.
	t.rng.seed(seed, uint64_t(t.id));
	t.repath_t = t.rng.next_double() * REPATH_S;
	t.scan_t = t.rng.next_double() * SCAN_S;
	t.st.acc = t.rng.next_double() * STATUS_TICK_S;
	thrall_slot[t.id] = t.slot;
	thralls.push_back(t);
	reform_thralls(p_owner);
	events.push(EV_THRALL_RAISED, t.id, { t.kind, p_owner, t.formation_slot, t.empowered ? 1 : 0, t.champion ? 1 : 0 }, { p_x, p_z, p_yaw, float(t.max_hp) });
	return t.id;
}

// ---------------------------------------------------------------------------------------------------------------- damage and death

// DmThrall.take_damage: damage taken, then the barrier, then health; at 0 it falls ("killed"). Refused only once dead (a rising thrall can be hit).
bool World::damage_thrall(int32_t p_slot, double p_amount, int32_t p_source, bool &r_killed) {
	r_killed = false;
	Thrall &t = thralls[p_slot];
	if (t.dead) {
		return false;
	}
	double amount = p_amount * t.taken_mult;  // DmStatusSet.scale_taken
	amount = absorb(t, amount);                // DmStatusSet.absorb
	t.hp -= amount;
	t.last_source = p_source;
	events.push(EV_THRALL_DAMAGED, t.id, { p_source }, { float(amount), float(t.hp) });
	if (t.hp <= 0.0) {
		kill_thrall(p_slot, DR_KILLED, p_source);
		r_killed = true;
	}
	return true;
}

// DmThrall.stun
void World::stun_thrall(Thrall &t, double p_seconds) {
	if (!t.dead) {
		t.stun_t = std::max(t.stun_t, p_seconds);
	}
}

void World::set_thrall_state(Thrall &t, int32_t p_state) {  // DmThrall._set_state
	if (p_state == t.state) {
		return;
	}
	events.push(EV_THRALL_STATE, t.id, { t.state, p_state }, {});
	t.state = p_state;
	t.state_t = 0.0;
}

// DmThrall.kill: the fall, the host's listener (the legion shrinks, seats are dealt again), the status set's (cleared), then a plague
// bearer's rupture (not when it crumbled) and the Legion of the Unburied burst (only when it was killed).
void World::kill_thrall(int32_t p_slot, int32_t p_reason, int32_t p_source) {
	Thrall &t = thralls[p_slot];
	if (t.dead) {
		return;
	}
	t.dead_reason = p_reason;
	t.dead = true;
	set_thrall_state(t, TS_DEAD);
	events.push(EV_THRALL_DIED, t.id, { p_reason, t.owner, t.kind, p_source }, { t.x, t.z });
	reform_thralls(t.owner);
	body_died_statuses(t);
	if (t.kind == TK_PLAGUEBEARER && p_reason != DR_CRUMBLED) {
		burst_thrall(t, legion.plague_radius, t.damage * legion.plague_damage);
		events.push(EV_THRALL_PLAGUE_POOL, t.id, {}, { t.x, t.z, float(legion.plague_pool_radius), float(legion.plague_pool_s), float(t.damage * legion.plague_pool_dps) });
	}
	if (p_reason == DR_KILLED && t.death_burst_frac > 0.0) {
		burst_thrall(t, legion.death_burst_r, t.death_burst_frac * t.max_hp);  // DmThralls.death_burst_damage
	}
}

// DmThrall._burst: every enemy not yet dead within r (+ its radius) of the thrall takes dmg; a boss comes out as an event.
void World::burst_thrall(Thrall &t, double p_radius, double p_damage) {
	for (int32_t i = 0; i < int32_t(enemies.size()); i++) {
		const Enemy &e = enemies[i];
		if (e.state != DEAD && flat_dist(t.x, t.z, e.x, e.z) <= p_radius + e.radius) {
			bool killed = false;
			damage_enemy(i, p_damage, t.id, true, killed);
		}
	}
	for (const External &x : externals) {
		if (x.kind == 1 && x.alive && flat_dist(t.x, t.z, x.x, x.z) <= p_radius + x.radius) {
			events.push(EV_THRALL_HIT_EXTERNAL, t.id, { x.id, t.kind }, { float(p_damage) });
		}
	}
}

// ---------------------------------------------------------------------------------------------------------------- the legion's commands

void World::rally_thrall(Thrall &t, double p_seconds, int32_t p_focus) {  // DmThrall.rally
	t.rally_t = p_seconds;
	t.hp = std::min(t.max_hp, t.hp + t.max_hp * legion.rally_heal);
	float fx = 0, fz = 0;
	double fr = 0, fe = 0;
	if (p_focus != 0 && locate_enemy(p_focus, fx, fz, fr, fe) && flat_dist(fx, fz, t.x, t.z) < legion.thrall_leash) {
		t.target = p_focus;
	}
}

// DmThrallHost.rally: Rally the Dead for the owner's legion (not the rising), the time capped at RALLY.durationS + gravecallerBonusS.
void World::rally_thralls(int32_t p_owner, double p_seconds, int32_t p_focus) {
	const double s = std::min(legion.rally_s + legion.rally_bonus_s, std::max(legion.rally_s, p_seconds));
	for (Thrall &t : thralls) {
		if (!t.dead && t.owner == p_owner && t.state != TS_RISING) {
			rally_thrall(t, s, p_focus);
		}
	}
}

void World::recall_thralls(int32_t p_owner) {  // DmThrallHost.recall: every thrall to the owner's side
	const External *own = find_external(p_owner);
	if (!own) {
		return;
	}
	for (Thrall &t : thralls) {
		if (!t.dead && t.owner == p_owner) {
			t.x = own->x + float(std::sin(double(t.formation_slot)));
			t.z = own->z + float(std::cos(double(t.formation_slot)));
			t.target = 0;
		}
	}
}

// DmThrallHost.set_legend: the owner's Legion of the Unburied fraction, for the living legion and for thralls raised later.
void World::set_legion_burst(int32_t p_owner, double p_fraction) {
	bool found = false;
	for (size_t i = 0; i < legion_owner.size(); i++) {
		if (legion_owner[i] == p_owner) {
			legion_burst[i] = p_fraction;
			found = true;
		}
	}
	if (!found) {
		legion_owner.push_back(p_owner);
		legion_burst.push_back(p_fraction);
	}
	for (Thrall &t : thralls) {
		if (!t.dead && t.owner == p_owner) {
			t.death_burst_frac = p_fraction;
		}
	}
}

int32_t World::thrall_count(int32_t p_owner) const {
	int32_t n = 0;
	for (const Thrall &t : thralls) {
		if (!t.dead && (p_owner == 0 || t.owner == p_owner)) {
			n++;
		}
	}
	return n;
}

double World::thrall_places(int32_t p_owner) const {  // DmThrallHost.places_used
	double u = 0.0;
	for (const Thrall &t : thralls) {
		if (!t.dead && (p_owner == 0 || t.owner == p_owner)) {
			u += thrall_weight(t.kind);
		}
	}
	return u;
}

// DmThrallHost.near: living thralls within r of a point (Vector2 length, float32), raise order.
void World::thralls_in_radius(float p_x, float p_z, float p_r, int32_t p_owner, std::vector<int32_t> &out) const {
	out.clear();
	for (const Thrall &t : thralls) {
		if (t.dead || (p_owner != 0 && t.owner != p_owner)) {
			continue;
		}
		const float dx = t.x - p_x, dz = t.z - p_z;
		if (std::sqrt(dx * dx + dz * dz) <= p_r) {
			out.push_back(t.id);
		}
	}
}

// ---------------------------------------------------------------------------------------------------------------- the tick

// DmThrallHost._physics_process: the soft separation between one legion's thralls (radius 0.4 each, they yield to each other). It runs with
// the heroes, first in the tick, on the positions and states the last tick left; the push is folded into each thrall's own move.
void World::separate_thralls() {
	const int32_t n = int32_t(thralls.size());
	if (n == 0) {
		return;
	}
	sep_scratch.assign(size_t(n) * 2, 0.0);
	double *vx = sep_scratch.data(), *vz = vx + n;
	for (int32_t i = 0; i < n; i++) {
		const Thrall &a = thralls[i];
		if (!a.alive_target()) {
			continue;
		}
		const double ax = a.x, az = a.z, ar = a.radius;
		for (int32_t j = i + 1; j < n; j++) {
			const Thrall &b = thralls[j];
			if (b.owner != a.owner) {
				continue;
			}
			const double dx = double(b.x) - ax, dz = double(b.z) - az;
			const double mn = ar + b.radius;
			const double d2 = dx * dx + dz * dz;
			if (d2 >= mn * mn || d2 < 1e-8 || !b.alive_target()) {
				continue;
			}
			const double k = (mn - std::sqrt(d2)) * SEP_PUSH / std::sqrt(d2);
			vx[i] -= dx * k;
			vz[i] -= dz * k;
			vx[j] += dx * k;
			vz[j] += dz * k;
		}
	}
	for (int32_t i = 0; i < n; i++) {
		thralls[i].sep_x = float(vx[i]);
		thralls[i].sep_z = float(vz[i]);
	}
}

void World::step_thralls(double p_dt) {
	const int32_t n = int32_t(thralls.size());
	for (int32_t i = 0; i < n; i++) {
		Thrall &t = thralls[i];
		if (t.dead) {  // the brain stops at death (set_physics_process(false)); only the 1.4 s linger runs
			t.state_t += p_dt;
			continue;
		}
		step_thrall(i, p_dt);
		if (!thralls[i].dead) {
			advance_statuses(thralls[i], p_dt);  // its Statuses child runs right after it
		}
	}
	remove_dead_thralls();
}

// DmThrall._physics_process
void World::step_thrall(int32_t p_slot, double p_dt) {
	Thrall &t = thralls[p_slot];
	t.age += p_dt;
	t.state_t += p_dt;
	t.attack_cd -= p_dt * t.attack_rate_mult * (t.rally_t > 0.0 ? legion.rally_attack : 1.0);
	if (t.rally_t > 0.0) {
		t.rally_t = std::max(0.0, t.rally_t - p_dt);
	}
	if (t.cursed_t > 0.0) {
		t.cursed_t = std::max(0.0, t.cursed_t - p_dt);
	}
	const External *own = find_external(t.owner);
	if (t.lifetime_s > 0.0 && t.age >= t.lifetime_s) {
		kill_thrall(p_slot, DR_DECAYED, 0);
	} else if (!own || !own->alive) {
		kill_thrall(p_slot, DR_CRUMBLED, 0);
	} else if (t.stun_t > 0.0) {
		t.stun_t -= p_dt;
		t.want_vx = t.want_vz = 0.0;
		move_thrall(t, p_dt);
	} else {
		think_thrall(t, *own, p_dt);
		move_thrall(t, p_dt);
	}
}

// DmThrall._think
void World::think_thrall(Thrall &t, const External &own, double p_dt) {
	if (t.state == TS_RISING) {
		if (t.state_t >= legion.thrall_rise) {
			set_thrall_state(t, TS_IDLE);
		}
		return;
	}
	const float opx = own.x, opz = own.z;
	if (flat_dist(opx, opz, t.x, t.z) > legion.thrall_teleport) {  // too far from the owner: next to them, no target
		const float rx = float(t.rng.next_double() - 0.5) * 2.0f;
		const float rz = float(t.rng.next_double() - 0.5) * 2.0f;
		t.x = opx + rx;
		t.z = opz + rz;
		t.target = 0;
		t.has_nav_goal = false;
	}
	if (!thrall_target_ok(t, opx, opz)) {
		t.target = 0;
		t.scan_t -= p_dt;
		if (t.scan_t <= 0.0) {
			t.scan_t = SCAN_S;
			t.target = scan_thrall(t, opx, opz);
		}
	}
	if (t.target != 0) {
		engage_thrall(t, p_dt);
	} else {
		follow_thrall(t, opx, opz, p_dt);
	}
}

// An enemy by id, or a boss (an external of kind 1): where it is, its radius, and the edge the boss rule counts from.
bool World::locate_enemy(int32_t p_id, float &r_x, float &r_z, double &r_radius, double &r_edge) const {
	const auto it = enemy_slot.find(p_id);
	if (it != enemy_slot.end()) {
		const Enemy &e = enemies[it->second];
		r_x = e.x;
		r_z = e.z;
		r_radius = e.radius;
		r_edge = 0.0;
		return true;
	}
	const External *x = find_external(p_id);
	if (x && x->kind == 1) {
		r_x = x->x;
		r_z = x->z;
		r_radius = x->radius;
		r_edge = x->radius;
		return true;
	}
	return false;
}

// DmThrall._target_ok: alive, hittable, not burrowed or rising, and within the leash of the OWNER; a boss counts from its edge.
bool World::thrall_target_ok(const Thrall &t, float p_opx, float p_opz) const {
	if (t.target == 0) {
		return false;
	}
	float tx, tz;
	double edge;
	const auto it = enemy_slot.find(t.target);
	if (it != enemy_slot.end()) {
		const Enemy &e = enemies[it->second];
		if (e.state == DEAD || e.state == BURROW || e.state == RISING || !hittable(e)) {
			return false;
		}
		tx = e.x;
		tz = e.z;
		edge = 0.0;
	} else {
		const External *x = find_external(t.target);
		if (!x || x->kind != 1 || !x->alive) {
			return false;
		}
		tx = x->x;
		tz = x->z;
		edge = x->radius;
	}
	return flat_dist(tx, tz, p_opx, p_opz) - edge <= legion.thrall_leash;
}

// DmThrall._scan: the nearest enemy within 10 m of the thrall (edge-counted for a boss) and THRALL_LEASH - 2 of the owner, group order, strict <.
int32_t World::scan_thrall(const Thrall &t, float p_opx, float p_opz) const {
	int32_t best = 0;
	double best_d = legion.engage_range;
	const double lim = legion.thrall_leash - 2.0;
	for (const Enemy &e : enemies) {
		if (e.state == DEAD || e.state == BURROW || e.state == RISING || !hittable(e)) {
			continue;
		}
		if (flat_dist(e.x, e.z, p_opx, p_opz) > lim) {
			continue;
		}
		const double d = flat_dist(e.x, e.z, t.x, t.z);
		if (d < best_d) {
			best_d = d;
			best = e.id;
		}
	}
	for (const External &x : externals) {  // bosses join the enemy group after the director's bodies
		if (x.kind != 1 || !x.alive) {
			continue;
		}
		if (flat_dist(x.x, x.z, p_opx, p_opz) - x.radius > lim) {
			continue;
		}
		const double d = flat_dist(x.x, x.z, t.x, t.z) - x.radius;
		if (d < best_d) {
			best_d = d;
			best = x.id;
		}
	}
	return best;
}

// DmThrall._engage: walk until within attack_range + the target's radius, then stop, face and swing when the cooldown is up.
void World::engage_thrall(Thrall &t, double p_dt) {
	float tx = 0, tz = 0;
	double trad = 0.4, edge = 0.0;
	locate_enemy(t.target, tx, tz, trad, edge);
	const double d = flat_dist(t.x, t.z, tx, tz);
	if (d > t.attack_range + trad) {
		steer_thrall(t, tx, tz, 1.0, p_dt);
		set_thrall_state(t, TS_MOVE);
		return;
	}
	t.want_vx = t.want_vz = 0.0;
	face_thrall(t, tx, tz, p_dt);
	if (t.attack_cd <= 0.0) {
		t.attack_cd = t.interval;
		swing_thrall(t);
	} else if (t.state != TS_ATTACK || t.state_t > ATTACK_HOLD_S) {
		set_thrall_state(t, TS_IDLE);
	}
}

// DmThrall._follow: a seat on a 1.9 m ring around the owner, dealt by rank among the living; the seat's own velocity feeds a catch-up pace.
void World::follow_thrall(Thrall &t, float p_opx, float p_opz, double p_dt) {
	const double ang = double(t.formation_rank) / double(std::max(3, t.formation_count)) * TAU + PI;
	const float sx = float(double(p_opx) + std::sin(ang) * SEAT_RADIUS);
	const float sz = float(double(p_opz) + std::cos(ang) * SEAT_RADIUS);
	const double d = flat_dist(t.x, t.z, sx, sz);
	double seat_v = 0.0;
	if (t.has_seat_prev && p_dt > 1e-5) {
		seat_v = std::min(SEAT_SPEED_CAP, flat_dist(t.seat_px, t.seat_pz, sx, sz) / p_dt);
	}
	t.seat_px = sx;
	t.seat_pz = sz;
	t.has_seat_prev = true;
	const bool following = t.state == TS_MOVE && (d > legion.follow_arrive || seat_v > legion.follow_seat_moving);
	if (d > SEAT_CLOSE || following) {
		double mult = d > SEAT_FAR ? SEAT_FAR_PACE : 1.0;
		if (d <= SEAT_CLOSE) {
			mult = std::max(SEAT_MIN_PACE, std::min(t.speed * mult, seat_v + d * legion.follow_catchup) / t.speed);
		}
		steer_thrall(t, sx, sz, mult, p_dt);
		set_thrall_state(t, TS_MOVE);
	} else if (t.state == TS_MOVE) {
		set_thrall_state(t, TS_IDLE);
	}
}

// DmThrall._steer: straight under 3 m, else along the navmesh path (re-requested at most every 0.3 s, only when the goal moved > 1 m); the
// speed is capped so a step never overshoots the goal.
void World::steer_thrall(Thrall &t, float p_gx, float p_gz, double p_mult, double p_dt) {
	float dx = p_gx - t.x, dz = p_gz - t.z;
	const float d2 = dx * dx + dz * dz;
	if (d2 < 0.0025f) {
		return;
	}
	if (nav.path && d2 > DIRECT_RANGE_SQ) {
		t.repath_t -= p_dt;
		if (t.repath_t <= 0.0) {
			t.repath_t = REPATH_S;
			const float mx = p_gx - t.nav_gx, mz = p_gz - t.nav_gz;
			if (!t.has_nav_goal || double(mx) * mx + double(mz) * mz > REPATH_MOVE_SQ) {
				t.has_nav_goal = true;
				t.nav_gx = p_gx;
				t.nav_gz = p_gz;
				t.path_len = nav.path(nav.user, t.x, t.z, p_gx, p_gz, t.path, PATH_POINTS);
				t.path_i = 0;
			}
		}
		if (t.has_nav_goal && t.path_len > 0) {
			while (t.path_i < t.path_len - 1 && flat_dist(t.x, t.z, t.path[t.path_i * 2], t.path[t.path_i * 2 + 1]) < THRALL_PATH_DESIRED) {
				t.path_i++;
			}
			const float sx = t.path[t.path_i * 2] - t.x, sz = t.path[t.path_i * 2 + 1] - t.z;
			if (sx * sx + sz * sz > 0.0004f) {
				dx = sx;
				dz = sz;
			}
		}
	}
	const float len = std::sqrt(dx * dx + dz * dz);
	if (len == 0.0f) {
		return;
	}
	const double v = t.speed * t.speed_mult * p_mult;
	const float spd = float(std::min(v, std::sqrt(double(d2)) / std::max(p_dt, MIN_STEP_DT)));
	t.want_vx = (dx / len) * spd;
	t.want_vz = (dz / len) * spd;
}

void World::face_thrall(Thrall &t, float p_px, float p_pz, double p_dt) {  // DmThrall._face
	const float dx = p_px - t.x, dz = p_pz - t.z;
	if (double(dx) * dx + double(dz) * dz > 0.0001) {
		t.yaw = float(lerp_angle(t.yaw, std::atan2(double(dx), double(dz)), std::min(1.0, TURN_RATE * p_dt)));
	}
}

// DmThrall._move: the wanted velocity plus the separation push, kept to the navmesh; it turns toward the wanted velocity only.
void World::move_thrall(Thrall &t, double p_dt) {
	const float vx = float(t.want_vx), vz = float(t.want_vz);
	t.ground_speed = std::sqrt(double(vx) * vx + double(vz) * vz);
	const bool wants = vx != 0.0f || vz != 0.0f;
	if (wants || t.sep_x != 0.0f || t.sep_z != 0.0f) {
		const float velx = vx + t.sep_x, velz = vz + t.sep_z;
		t.x += float(double(velx) * p_dt);
		t.z += float(double(velz) * p_dt);
		keep_on_nav(t.x, t.z);
	}
	if (wants) {
		t.yaw = float(lerp_angle(t.yaw, std::atan2(double(vx), double(vz)), std::min(1.0, TURN_RATE * p_dt)));
	}
	t.want_vx = t.want_vz = 0.0;
}

// ---------------------------------------------------------------------------------------------------------------- the blow

// A thrall's blow on an enemy goes through the damage path with the thrall as the source (kill credit); on a boss it is an event.
void World::thrall_hit(Thrall &t, int32_t p_target, double p_damage) {
	const auto it = enemy_slot.find(p_target);
	if (it != enemy_slot.end()) {
		bool killed = false;
		damage_enemy(it->second, p_damage, t.id, true, killed);
		return;
	}
	const External *x = find_external(p_target);
	if (x && x->kind == 1) {
		events.push(EV_THRALL_HIT_EXTERNAL, t.id, { x->id, t.kind }, { float(p_damage) });
	}
}

// DmThrall._swing: instant, melee or ranged alike. damage x Rally x Hag's curse x the Spear mark x the status set's damage dealt.
void World::swing_thrall(Thrall &t) {
	float tx = 0, tz = 0;
	double trad = 0, edge = 0;
	const int32_t target = t.target;
	locate_enemy(target, tx, tz, trad, edge);
	t.aim_x = tx;
	t.aim_z = tz;
	t.swing_n++;
	set_thrall_state(t, TS_ATTACK);
	double dmg = t.damage * (t.rally_t > 0.0 ? legion.rally_damage : 1.0) * (t.cursed_t > 0.0 ? legion.hag_thrall_damage : 1.0) * t.mark_mult;
	dmg *= t.st.dealt;
	thrall_hit(t, target, dmg);
	switch (t.kind) {
		case TK_WRAITH:
			if (st_chill >= 0) {
				if (Body *b = body(target)) {
					apply_status(*b, st_chill, t.id, 1.0, -1.0, 0.0, -1.0, 0.0);
				}
				events.push(EV_THRALL_STATUS, t.id, { target, st_chill }, { float(status_rules[st_chill].dur) });
			}
			if (t.ally_heal > 0.0) {
				events.push(EV_THRALL_BELL_HEAL, t.id, {}, { t.x, t.z, float(t.ally_heal) });
			}
			break;
		case TK_BONEMAGE:
			if (st_hex >= 0) {
				if (Body *b = body(target)) {
					apply_status(*b, st_hex, t.id, 1.0, -1.0, 0.0, -1.0, 0.0);
				}
				events.push(EV_THRALL_STATUS, t.id, { target, st_hex }, { float(status_rules[st_hex].dur) });
			}
			break;
		case TK_COLOSSUS:
			cleave_thrall(t, target, dmg);
			break;
		default:
			break;
	}
	events.push(EV_THRALL_SWING, t.id, { t.swing_n, target }, { t.aim_x, t.aim_z, float(dmg) });
}

// DmThrall._cleave: 0.6x the blow on every other enemy within 2.4 m (+ its radius) of the one struck.
void World::cleave_thrall(Thrall &t, int32_t p_main, double p_damage) {
	const double part = p_damage * legion.colossus_cleave_frac, r = legion.colossus_cleave_r;
	float mx = 0, mz = 0;
	double mr = 0, me = 0;
	if (!locate_enemy(p_main, mx, mz, mr, me)) {
		return;
	}
	for (int32_t i = 0; i < int32_t(enemies.size()); i++) {
		const Enemy &o = enemies[i];
		if (o.id == p_main || o.state == DEAD || flat_dist(o.x, o.z, mx, mz) > r + o.radius) {
			continue;
		}
		bool killed = false;
		damage_enemy(i, part, t.id, true, killed);
	}
	for (const External &x : externals) {
		if (x.kind == 1 && x.alive && x.id != p_main && flat_dist(x.x, x.z, mx, mz) <= r + x.radius) {
			events.push(EV_THRALL_HIT_EXTERNAL, t.id, { x.id, t.kind }, { float(part) });
		}
	}
}

// The body is freed 1.4 s after it fell (DmThrall._on_dead's timer).
void World::remove_dead_thralls() {
	size_t w = 0;
	for (size_t r = 0; r < thralls.size(); r++) {
		const Thrall &t = thralls[r];
		if (t.dead && t.state_t >= legion.corpse_s) {
			events.push(EV_THRALL_REMOVED, t.id, {}, {});
			thrall_slot.erase(t.id);
			continue;
		}
		if (w != r) {  // stable compaction keeps raise order
			thralls[w] = thralls[r];
			thralls[w].slot = int32_t(w);
			thrall_slot[thralls[w].id] = int32_t(w);
		}
		w++;
	}
	thralls.resize(w);
}

} // namespace dm
