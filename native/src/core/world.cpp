#include "world.h"

#include <algorithm>

// The enemy brain is a port of godot/enemies: DmEnemy (dm_enemy.gd), its states (states/*.gd) and the Graves kinds (flanker, caster,
// hazard, burrower). Comments name the GDScript it mirrors. Differences from today are listed in native/README.md.

namespace dm {

namespace {
constexpr double PI = 3.14159265358979323846;
constexpr double TAU = 2.0 * PI;

double lerp_angle(double p_from, double p_to, double p_w) {  // Godot's lerp_angle
	const double diff = std::fmod(p_to - p_from, TAU);
	const double dist = std::fmod(2.0 * diff, TAU) - diff;
	return p_from + dist * p_w;
}
} // namespace

int32_t World::area_id(const std::string &p_area) {
	auto it = area_index.find(p_area);
	if (it != area_index.end()) {
		return it->second;
	}
	const int32_t id = int32_t(areas.size());
	areas.push_back(p_area);
	area_index.emplace(p_area, id);
	return id;
}

int32_t World::spawn_enemy(int32_t p_def, float p_x, float p_z, int32_t p_level, double p_hp_mult, double p_damage_mult, bool p_elite, int32_t p_area, bool p_rising) {
	const EnemyDef &d = defs[p_def];
	Enemy e;
	e.id = next_id++;
	e.rng.seed(seed, uint64_t(e.id));
	e.def = p_def;
	e.level = p_level;
	e.area = p_area;
	e.elite = p_elite;
	e.in_graves = areas[p_area] == "graves";
	e.x = e.home_x = e.last_x = p_x;
	e.z = e.home_z = e.last_z = p_z;
	// Per-body stats in dm_enemy.gd _ready order (the rolls come from this body's stream).
	e.max_hp = e.hp = d.hp * p_hp_mult * (p_elite ? tun.elite_hp : 1.0);
	e.damage = d.damage * p_damage_mult * (p_elite ? tun.elite_damage : 1.0);
	e.speed = d.speed * (0.92 + e.rng.next_double() * 0.16);
	e.radius = d.radius * (p_elite ? tun.elite_radius : 1.0);
	e.attack_range = d.attack_range;
	e.windup_s = d.windup_s * (p_elite ? tun.elite_windup : 1.0);
	e.cooldown_s = d.cooldown_s * (p_elite ? tun.elite_cooldown : 1.0);
	e.flank_side = e.rng.next_double() < 0.5 ? -1.0 : 1.0;
	e.attack_cd = 0.5 + e.rng.next_double();
	e.repath_t = e.rng.next_double() * REPATH_S;
	e.scan_t = e.rng.next_double() * SCAN_S;
	e.wander_heading = e.rng.next_double() * TAU;
	e.st.acc = e.rng.next_double() * STATUS_TICK_S;  // DmStatusSet spreads a crowd's 0.1 s steps across ticks
	// initial_state(): rising bodies rise (a burrower starts underground), others start idle.
	e.state = p_rising ? (d.burrow ? BURROW : RISING) : IDLE;
	const int32_t slot = int32_t(enemies.size());
	enemies.push_back(e);
	enemy_slot[e.id] = slot;
	events.push(EV_ENEMY_SPAWNED, e.id, { p_def, p_level, p_elite ? 1 : 0, p_area }, { p_x, p_z, float(e.max_hp) });
	enter(enemies[slot], -1);
	return e.id;
}

// ---------------------------------------------------------------------------------------------------------------- state machine

void World::change(int32_t p_slot, int32_t p_next) {
	Enemy &e = enemies[p_slot];
	const int32_t prev = e.state;
	e.state = p_next;
	e.state_t = 0.0;
	events.push(EV_ENEMY_STATE, e.id, { prev, p_next }, {});
	enter(e, prev);
}

// The states' enter() (states/*.gd).
void World::enter(Enemy &e, int32_t p_prev) {
	const EnemyDef &d = defs[e.def];
	switch (e.state) {
		case IDLE:
			e.target = 0;
			stop(e);
			break;
		case ATTACK:
			e.phase = 0;
			stop(e);
			begin_attack(e);
			break;
		case HURT:
		case DIG:
		case EMERGE:
			stop(e);
			if (e.state == DIG) {
				events.push(EV_CUE, e.id, { CUE_DIG_IN }, { e.x, e.z, 0.0f });
			}
			break;
		case RETURN:
			e.target = 0;
			break;
		case DEAD:
			stop(e);
			break;
		case BURROW:
			stop(e);
			e.last_x = e.x;
			e.last_z = e.z;
			e.stuck_t = 0.0;
			break;
		case ERUPT: {
			stop(e);
			const External *t = target_ext(e.target);
			e.aim_x = t ? t->x : e.x;
			e.aim_z = t ? t->z : e.z;
			e.erupt_s = (e.in_graves ? tun.burrow_erupt_s_graves : tun.burrow_erupt_s) * (e.elite ? tun.elite_windup : 1.0);
			events.push(EV_TELEGRAPH, e.id, { TELL_ERUPT }, { e.x, e.z, e.aim_x, e.aim_z, float(tun.burrow_erupt_r), float(e.erupt_s) });
			break;
		}
		default:
			break;
	}
	(void)d;
	(void)p_prev;
}

// The states' tick() (states/*.gd). Returns the next state or -1.
int32_t World::tick_state(int32_t p_slot, double p_dt) {
	Enemy &e = enemies[p_slot];
	const double t = e.state_t;
	switch (e.state) {
		case RISING:  // dm_state_rising
			return t >= RISE_S ? IDLE : -1;
		case IDLE: {  // dm_state_idle
			if (scan_due(e, p_dt)) {
				const int32_t tg = find_target(e, AGGRO_RANGE);
				if (tg != 0) {
					e.target = tg;
					return CHASE;
				}
			}
			wander(e, p_dt);
			return -1;
		}
		case CHASE: {  // dm_state_chase
			const External *tg = target_ext(e.target);
			if (!tg) {
				return flat_dist(e.x, e.z, e.home_x, e.home_z) > HOME_ARRIVE ? RETURN : IDLE;
			}
			double d = flat_dist(e.x, e.z, tg->x, tg->z);
			if (d > AGGRO_RANGE * DROP_MULT || flat_dist(e.x, e.z, e.home_x, e.home_z) > LEASH) {
				e.target = 0;
				return RETURN;
			}
			if (scan_due(e, p_dt)) {
				const int32_t nearer = find_target(e, AGGRO_RANGE);
				if (nearer != 0 && nearer != e.target) {
					e.target = nearer;
					tg = target_ext(nearer);
					d = flat_dist(e.x, e.z, tg->x, tg->z);
				}
			}
			return engage(e, tg->x, tg->z, d, p_dt);
		}
		case ATTACK:  // dm_state_attack: wind-up, impact, 0.3 s recovery
			if (e.phase == 0) {
				if (t >= e.windup_s) {
					e.attack_cd = e.cooldown_s;
					strike(e);
					e.phase = 1;
					e.state_t = 0.0;
				}
				return -1;
			}
			return t >= RECOVER_S ? post_attack_state(e) : -1;
		case HURT:  // dm_state_hurt
			return t >= e.hurt_s ? (target_valid(e.target) ? CHASE : IDLE) : -1;
		case RETURN:  // dm_state_return
			if (flat_dist(e.x, e.z, e.home_x, e.home_z) <= HOME_ARRIVE) {
				return IDLE;
			}
			steer_to(e, e.home_x, e.home_z, 1.0, p_dt);
			return -1;
		case FLEE: {  // dm_state_flee: run from the target for hit_run s, bent by the flank side
			const External *tg = target_ext(e.target);
			if (!tg) {
				return IDLE;
			}
			if (t >= defs[e.def].hit_run) {
				return CHASE;
			}
			const double d = std::max(0.001, flat_dist(e.x, e.z, tg->x, tg->z));
			const float px = float(-(tg->z - e.z) / d), pz = float((tg->x - e.x) / d);
			steer_to(e, e.x * 2.0f - tg->x + px * 2.0f * float(e.flank_side), e.z * 2.0f - tg->z + pz * 2.0f * float(e.flank_side), 1.0, p_dt);
			return -1;
		}
		case BURROW: {  // dm_state_burrow
			const External *tg = target_ext(e.target);
			if (!tg || scan_due(e, p_dt)) {
				e.target = find_target(e, AGGRO_RANGE);
				tg = target_ext(e.target);
			}
			if (!tg) {
				return -1;
			}
			const double d = flat_dist(e.x, e.z, tg->x, tg->z);
			if (d <= tun.burrow_surface_r || e.burrow_left <= 0.0) {
				int32_t busy = 0;
				for (const Enemy &o : enemies) {
					if (o.id != e.id && o.state == ERUPT && o.target == e.target) {
						busy++;
					}
				}
				return busy >= tun.burrow_max_per_target ? -1 : ERUPT;
			}
			const double moved = flat_dist(e.x, e.z, e.last_x, e.last_z);
			e.last_x = e.x;
			e.last_z = e.z;
			e.stuck_t = (t > 0.3 && moved < tun.burrow_speed * p_dt * 0.25) ? e.stuck_t + p_dt : 0.0;
			if (e.stuck_t > BURROW_STUCK_S) {
				return ERUPT;
			}
			move_straight(e, tg->x, tg->z, tun.burrow_speed);
			e.burrow_left -= tun.burrow_speed * p_dt;
			face_point(e, tg->x, tg->z, p_dt);
			return -1;
		}
		case ERUPT: {  // dm_state_erupt
			if (t < e.erupt_s) {
				return -1;
			}
			const double dmg = e.damage * (e.in_graves ? tun.burrow_erupt_mult_graves : tun.burrow_erupt_mult);
			e.x = e.aim_x;
			e.z = e.aim_z;
			e.attack_cd = e.cooldown_s;
			for (const External &x : externals) {
				if (x.alive && x.kind == 0 && flat_dist(e.aim_x, e.aim_z, x.x, x.z) <= tun.burrow_erupt_r) {
					hit_target(e, x.id, dmg, defs[e.def].hit_kind);
				}
			}
			events.push(EV_CUE, e.id, { CUE_ERUPT }, { e.aim_x, e.aim_z, float(tun.burrow_erupt_r) });
			return EMERGE;
		}
		case DIG:  // dm_state_dig
			if (t < tun.burrow_dig_s) {
				return -1;
			}
			events.push(EV_STATUSES_CLEARED, e.id, {}, {});
			{
				bool any = false;
				for (int32_t sid : st_cleared) {
					any = e.st.erase(sid) || any;
				}
				if (any) {
					statuses_changed(e);
				}
			}
			e.burrow_left = tun.burrow_travel;
			return BURROW;
		case EMERGE:  // dm_state_emerge
			return t < RECOVER_S ? -1 : (target_valid(e.target) ? CHASE : IDLE);
		default:
			return -1;
	}
}

// CHASE's engage() per kind: dm_state_chase (melee, hazard), dm_state_flank_chase, dm_state_kite (casters).
int32_t World::engage(Enemy &e, float p_tx, float p_tz, double p_d, double p_dt) {
	const EnemyDef &d = defs[e.def];
	if (d.behavior == B_CASTER) {
		if (p_d <= e.attack_range - 0.5 && e.attack_cd <= 0.0) {
			return ATTACK;
		}
		if (p_d > e.attack_range - 1.5) {
			steer_to(e, p_tx, p_tz, 1.0, p_dt);
		} else if (p_d < KITE_BACK_OFF) {
			steer_to(e, e.x * 2.0f - p_tx, e.z * 2.0f - p_tz, KITE_BACK_SPEED, p_dt);
			face_point(e, p_tx, p_tz, p_dt);
		} else {
			stop(e);
			face_point(e, p_tx, p_tz, p_dt);
		}
		return -1;
	}
	if (p_d <= e.attack_range + ATTACK_TRIGGER_PAD && e.attack_cd <= 0.0) {
		return ATTACK;
	}
	if (p_d > e.attack_range * STOP_FRAC) {
		float gx = p_tx, gz = p_tz;
		if (d.behavior == B_FLANK && p_d > 2.5) {
			const float px = float(-(p_tz - e.z) / p_d), pz = float((p_tx - e.x) / p_d);
			const float off = float(std::min(3.0, p_d * 0.45) * e.flank_side);
			gx += px * off;
			gz += pz * off;
		}
		steer_to(e, gx, gz, 1.0, p_dt);
	} else {
		stop(e);
		face_point(e, p_tx, p_tz, p_dt);
	}
	return -1;
}

int32_t World::post_attack_state(const Enemy &e) const {
	if (defs[e.def].hit_run > 0.0 && target_valid(e.target)) {
		return FLEE;
	}
	return target_valid(e.target) ? CHASE : IDLE;
}

// ---------------------------------------------------------------------------------------------------------------- brain helpers

bool World::scan_due(Enemy &e, double p_dt) {
	e.scan_t -= p_dt;
	if (e.scan_t > 0.0) {
		return false;
	}
	e.scan_t = SCAN_S;
	return true;
}

// DmEnemy.find_target: nearest alive target, squared flat distance times weight squared, strict <, heroes before thralls on ties.
int32_t World::find_target(const Enemy &e, double p_range) const {
	int32_t best = 0;
	double best_d = p_range * p_range;
	for (const External &x : externals) {
		if (!x.alive || x.kind != 0) {
			continue;
		}
		const float dx = x.x - e.x, dz = x.z - e.z;
		const double d = (double(dx) * dx + double(dz) * dz) * x.weight * x.weight;
		if (d < best_d) {
			best_d = d;
			best = x.id;
		}
	}
	return best;
}

const External *World::target_ext(int32_t p_id) const {
	if (p_id == 0) {
		return nullptr;
	}
	for (const External &x : externals) {
		if (x.id == p_id) {
			return (x.alive && x.kind == 0) ? &x : nullptr;
		}
	}
	return nullptr;
}

void World::stop(Enemy &e) {
	e.want_vx = e.want_vz = 0.0;
	e.has_nav_goal = false;
	e.repath_t = std::min(e.repath_t, e.rng.next_double() * REPATH_S);
}

// DmEnemy.steer_to: straight under 3 m, else the navmesh path, re-requested at most every 0.3 s and only when the goal moved > 1 m.
void World::steer_to(Enemy &e, float p_gx, float p_gz, double p_mult, double p_dt) {
	float dx = p_gx - e.x, dz = p_gz - e.z;
	const double d2 = double(dx) * dx + double(dz) * dz;
	if (d2 < 0.0025) {
		return;
	}
	if (nav.path && d2 > DIRECT_RANGE_SQ) {
		e.repath_t -= p_dt;
		if (e.repath_t <= 0.0) {
			e.repath_t = REPATH_S;
			const float mx = p_gx - e.nav_gx, mz = p_gz - e.nav_gz;
			if (!e.has_nav_goal || double(mx) * mx + double(mz) * mz > REPATH_MOVE_SQ) {
				e.has_nav_goal = true;
				e.nav_gx = p_gx;
				e.nav_gz = p_gz;
				e.path_len = nav.path(nav.user, e.x, e.z, p_gx, p_gz, e.path, PATH_MAX);
				e.path_i = 0;
			}
		}
		if (e.has_nav_goal && e.path_len > 0) {
			// NavigationAgent3D.get_next_path_position with path_desired_distance 0.5.
			while (e.path_i < e.path_len - 1 && flat_dist(e.x, e.z, e.path[e.path_i * 2], e.path[e.path_i * 2 + 1]) < PATH_DESIRED) {
				e.path_i++;
			}
			const float sx = e.path[e.path_i * 2] - e.x, sz = e.path[e.path_i * 2 + 1] - e.z;
			if (double(sx) * sx + double(sz) * sz > 0.0004) {
				dx = sx;
				dz = sz;
			}
		}
	}
	const double len = std::sqrt(double(dx) * dx + double(dz) * dz);
	const double v = e.speed * e.speed_mult * (e.incense_t > 0.0 ? INCENSE_MOVE : 1.0) * p_mult;
	e.want_vx = dx / len * v;
	e.want_vz = dz / len * v;
}

void World::move_straight(Enemy &e, float p_gx, float p_gz, double p_speed) {
	const float dx = p_gx - e.x, dz = p_gz - e.z;
	const double d2 = double(dx) * dx + double(dz) * dz;
	if (d2 > 0.0025) {
		const double len = std::sqrt(d2);
		e.want_vx = dx / len * p_speed;
		e.want_vz = dz / len * p_speed;
	}
}

void World::face_point(Enemy &e, float p_px, float p_pz, double p_dt) {
	const float dx = p_px - e.x, dz = p_pz - e.z;
	if (double(dx) * dx + double(dz) * dz > 0.0001) {
		e.yaw = float(lerp_angle(e.yaw, std::atan2(double(dx), double(dz)), std::min(1.0, TURN_RATE * p_dt)));
	}
}

void World::wander(Enemy &e, double p_dt) {  // DmEnemy.wander
	if (!wander_enabled) {
		return;
	}
	if (e.rng.next_double() < p_dt * 0.3) {
		e.wander_heading += (e.rng.next_double() - 0.5) * 2.0;
	}
	const float ax = e.x - e.home_x, az = e.z - e.home_z;
	if (double(ax) * ax + double(az) * az > WANDER_RADIUS * WANDER_RADIUS) {
		e.wander_heading = std::atan2(-double(ax), -double(az));
	}
	const double v = e.speed * e.speed_mult * (e.incense_t > 0.0 ? INCENSE_MOVE : 1.0) * WANDER_SPEED_MULT;
	e.want_vx = std::sin(e.wander_heading) * v;
	e.want_vz = std::cos(e.wander_heading) * v;
}

// DmEnemy.begin_attack + announce_telegraph per kind.
void World::begin_attack(Enemy &e) {
	const EnemyDef &d = defs[e.def];
	const External *tg = target_ext(e.target);
	if (tg) {
		e.aim_x = tg->x;
		e.aim_z = tg->z;
		face_point(e, e.aim_x, e.aim_z, 1.0);
	} else {
		e.aim_x = e.x + float(std::sin(double(e.yaw)));
		e.aim_z = e.z + float(std::cos(double(e.yaw)));
	}
	events.push(EV_ENEMY_ATTACK, e.id, { d.blow }, { e.aim_x, e.aim_z, float(e.windup_s) });
	switch (d.blow) {
		case BLOW_CONE:
			events.push(EV_TELEGRAPH, e.id, { TELL_CONE }, { e.x, e.z, e.aim_x, e.aim_z, 0.0f, float(e.windup_s) });
			break;
		case BLOW_DUST:
			events.push(EV_TELEGRAPH, e.id, { TELL_DUST }, { e.x, e.z, e.aim_x, e.aim_z, float(tun.dust_radius), float(e.windup_s) });
			break;
		case BLOW_SLAM:
			events.push(EV_TELEGRAPH, e.id, { TELL_SLAM }, { e.x, e.z, e.aim_x, e.aim_z, float(d.slam_r), float(e.windup_s) });
			break;
		default:
			break;
	}
}

// DmEnemy.strike per kind: the blow lands at the end of the wind-up, measured from the body (melee, cone) or the fixed aim (dust, slam).
void World::strike(Enemy &e) {
	const EnemyDef &d = defs[e.def];
	switch (d.blow) {
		case BLOW_MELEE: {
			const External *tg = target_ext(e.target);
			if (tg && flat_dist(e.x, e.z, tg->x, tg->z) <= e.attack_range * STRIKE_REACH_MULT + STRIKE_REACH_PAD) {
				hit_target(e, tg->id, e.damage, d.hit_kind);
			}
			break;
		}
		case BLOW_CONE: {
			float dx = e.aim_x - e.x, dz = e.aim_z - e.z;
			double ln = std::sqrt(double(dx) * dx + double(dz) * dz);
			if (ln < 0.001) {
				dx = float(std::sin(double(e.yaw)));
				dz = float(std::cos(double(e.yaw)));
				ln = 1.0;
			}
			const double reach = e.attack_range + CONE_PAD, cos_lim = std::cos(CONE_HALF_ANGLE);
			for (const External &x : externals) {
				if (!x.alive || x.kind != 0) {
					continue;
				}
				const float vx = x.x - e.x, vz = x.z - e.z;
				const double dd = std::sqrt(double(vx) * vx + double(vz) * vz);
				if (dd > reach) {
					continue;
				}
				if (dd < 0.001 || (double(vx) * dx + double(vz) * dz) / (dd * ln) > cos_lim) {
					hit_target(e, x.id, e.damage, d.hit_kind);
				}
			}
			break;
		}
		case BLOW_DUST: {
			for (const External &x : externals) {
				if (x.alive && x.kind == 0 && flat_dist(e.aim_x, e.aim_z, x.x, x.z) <= tun.dust_radius) {
					hit_target(e, x.id, e.damage, HK_DUST);
				}
			}
			Zone z;
			z.id = next_id++;
			z.kind = ZONE_DUST;
			z.source = e.id;
			z.hit_kind = HK_DUST;
			z.x = e.aim_x;
			z.z = e.aim_z;
			z.radius = tun.dust_radius;
			z.lifetime = tun.dust_cloud_s;
			z.dps = e.damage * tun.dust_cloud_dps;
			zones.push_back(z);
			events.push(EV_ZONE, z.id, { z.kind, z.source }, { z.x, z.z, float(z.radius), float(z.lifetime) });
			break;
		}
		case BLOW_SLAM: {
			for (const External &x : externals) {
				if (x.alive && x.kind == 0 && flat_dist(e.aim_x, e.aim_z, x.x, x.z) <= d.slam_r) {
					hit_target(e, x.id, e.damage, d.hit_kind);
				}
			}
			events.push(EV_CUE, e.id, { CUE_SLAM }, { e.aim_x, e.aim_z, float(d.slam_r) });
			break;
		}
		default:
			break;
	}
}

void World::hit_target(Enemy &e, int32_t p_target, double p_damage, int32_t p_kind) {
	events.push(EV_TARGET_HIT, e.id, { p_target, p_kind }, { float(p_damage) });
}

// ---------------------------------------------------------------------------------------------------------------- damage

double World::damage_enemy(int32_t p_slot, double p_amount, int32_t p_source, bool p_allow_stagger, bool &r_killed) {
	r_killed = false;
	Enemy &e = enemies[p_slot];
	if (e.state == DEAD || e.state == RISING || !hittable(e) || p_amount <= 0.0) {  // DmEnemy.take_damage refusals
		return 0.0;
	}
	const double amount = p_amount * e.taken_mult;  // DmStatusSet.scale_taken (statuses join with their item)
	e.hp -= amount;
	e.last_source = p_source;
	events.push(EV_ENEMY_DAMAGED, e.id, { p_source }, { float(amount), float(std::max(0.0, e.hp)) });
	if (e.hp <= 0.0) {
		kill(p_slot, p_source);
		r_killed = true;
		return amount;
	}
	if (e.target == 0 && target_valid(p_source)) {  // a hit aggroes the attacker when nothing is targeted
		e.target = p_source;
	}
	if (p_allow_stagger && e.stagger_t <= 0.0 && (e.state == IDLE || e.state == CHASE || e.state == RETURN)) {
		e.stagger_t = STAGGER_ICD;
		e.hurt_s = HURT_S;
		change(p_slot, HURT);
	} else if (e.state == IDLE && e.target != 0) {
		change(p_slot, CHASE);
	}
	// DmEnemyBurrower.take_damage: the first fall below digAtFrac digs back in.
	Enemy &b = enemies[p_slot];
	if (defs[b.def].burrow && !b.dug_in && b.hp > 0.0 && b.hp < b.max_hp * tun.burrow_dig_at) {
		b.dug_in = true;
		change(p_slot, DIG);
	}
	return amount;
}

void World::stun(int32_t p_slot, double p_seconds) {  // DmEnemy.stun: a hard interrupt, cancels a swing too
	Enemy &e = enemies[p_slot];
	if (e.state == DEAD || !hittable(e)) {
		return;
	}
	e.hurt_s = p_seconds;
	change(p_slot, HURT);
}

void World::kill(int32_t p_slot, int32_t p_source) {
	Enemy &e = enemies[p_slot];
	e.hp = 0.0;
	change(p_slot, DEAD);
	Enemy &k = enemies[p_slot];
	// DmStatusSet._on_died: report Withered (Contagion, Plague Choir spread), then clear.
	const int32_t w = st_withered >= 0 ? k.st.find(st_withered) : -1;
	if (w >= 0) {
		events.push(EV_WITHERED_DIED, k.id, { k.st.rec[w].src }, { float(k.st.rec[w].stk), float(k.st.rec[w].val) });
	}
	if (k.st.n > 0) {
		k.st.n = 0;
		statuses_changed(k);
	}
	events.push(EV_ENEMY_DIED, k.id, { k.def, k.level, k.elite ? 1 : 0, k.area, p_source }, { k.x, k.z });
}

// ---------------------------------------------------------------------------------------------------------------- statuses

int32_t World::status_id(const std::string &p_name) const {
	for (size_t i = 0; i < status_rules.size(); i++) {
		if (status_rules[i].name == p_name) {
			return int32_t(i);
		}
	}
	return -1;
}

void World::statuses_changed(Enemy &e) {
	e.st.recompute(status_rules);
	e.speed_mult = e.st.move;  // DmStatusSet owns these multipliers on its body
	e.attack_rate_mult = e.st.atk;
	e.taken_mult = e.st.taken;
	events.push(EV_STATUS_CHANGED, e.id, {}, {});
}

void World::apply_status(int32_t p_slot, int32_t p_status, int32_t p_source, double p_stacks, double p_duration, double p_dps, double p_cap, double p_amount) {
	Enemy &e = enemies[p_slot];
	if (e.state == DEAD || p_status < 0 || p_status >= int32_t(status_rules.size())) {
		return;
	}
	const StatusRule &d = status_rules[p_status];
	const double dur = p_duration >= 0.0 ? p_duration : d.dur;
	int32_t i = e.st.find(p_status);
	const bool fresh = i < 0;
	if (fresh) {
		if (e.st.n >= STATUS_MAX) {
			return;
		}
		i = e.st.n++;
		e.st.rec[i] = StatusRec();
		e.st.rec[i].id = p_status;
	}
	StatusRec &r = e.st.rec[i];
	const double old_rem = r.rem, old_stk = r.stk;
	if (d.stack) {
		r.stk = std::min(p_cap >= 0.0 ? p_cap : d.max, old_stk + p_stacks);
		r.rem = dur;
		if (d.dot) {
			r.val = std::max(r.val, p_dps);
			r.src = p_source;  // the last stacker owns the kill
		}
	} else if (d.bleed) {
		r.stk = 1.0;
		r.rem = dur;
		if (fresh || p_dps >= r.val) {
			r.val = p_dps;
			r.src = p_source;
		}
	} else if (d.barrier) {
		r.stk = 1.0;
		r.rem = std::max(old_rem, dur);
		r.val = std::min(p_cap >= 0.0 ? p_cap : 1.0e9, r.val + p_amount);
	} else {
		r.stk = 1.0;
		r.rem = std::max(old_rem, dur);
		if (fresh) {
			r.src = p_source;
		}
	}
	const double new_rem = r.rem;
	if (fresh || r.stk != old_stk) {
		statuses_changed(e);
	}
	if (p_status == st_stun && new_rem > old_rem) {
		stun(p_slot, dur);
	}
}

bool World::remove_status(int32_t p_slot, int32_t p_status) {
	Enemy &e = enemies[p_slot];
	if (!e.st.erase(p_status)) {
		return false;
	}
	statuses_changed(e);
	return true;
}

// DmStatusSet.advance: one step per 0.1 s of accumulated time, the step's dt being the whole accumulator.
void World::advance_statuses(int32_t p_slot, double p_dt) {
	Enemy &e = enemies[p_slot];
	if (e.st.n == 0 && !defs[e.def].frenzy) {
		return;
	}
	e.st.acc += p_dt;
	if (e.st.acc >= STATUS_TICK_S) {
		const double dt = e.st.acc;
		e.st.acc = 0.0;
		step_statuses(p_slot, dt);
	}
}

// DmStatusSet._step
void World::step_statuses(int32_t p_slot, double p_dt) {
	StatusSet &s = enemies[p_slot].st;
	s.flush_t += p_dt;
	const bool flush = s.flush_t >= STATUS_FLUSH_S;
	if (flush) {
		s.flush_t = 0.0;
	}
	int32_t dots[STATUS_MAX], gone[STATUS_MAX];
	int32_t nd = 0, ng = 0;
	for (int32_t i = 0; i < s.n; i++) {
		StatusRec &r = s.rec[i];
		const StatusRule &d = status_rules[r.id];
		const double rem = r.rem - p_dt;
		if (d.dot) {
			r.acc += r.stk * r.val * std::min(p_dt, r.rem);
			if (flush || rem <= 0.0) {
				dots[nd++] = r.id;
			}
		}
		r.rem = rem;
		if (rem <= 0.0) {
			gone[ng++] = r.id;
		}
	}
	bool dirty = false;
	for (int32_t k = 0; k < nd; k++) {
		const int32_t i = enemies[p_slot].st.find(dots[k]);
		if (i < 0) {
			continue;  // the body died during an earlier lump and cleared the set
		}
		StatusRec &r = enemies[p_slot].st.rec[i];
		const double amt = r.acc;
		const int32_t src = r.src;
		r.acc = 0.0;
		if (amt > 0.0 && enemies[p_slot].state != DEAD) {
			bool killed = false;
			if (damage_enemy(p_slot, amt, src, false, killed) > 0.0) {  // no stagger from a DoT; damage taken applies inside
				events.push(EV_STATUS_DOT, enemies[p_slot].id, { dots[k], src, killed ? 1 : 0 }, { float(amt * enemies[p_slot].st.taken) });
			}
		}
	}
	Enemy &e = enemies[p_slot];
	for (int32_t k = 0; k < ng; k++) {
		if (e.st.erase(gone[k])) {
			dirty = true;
			events.push(EV_STATUS_EXPIRED, e.id, { gone[k] }, {});
		}
	}
	if (defs[e.def].frenzy && st_frenzy >= 0 && e.state != DEAD) {  // Frenzy below FRENZY.atFrac of max health
		const bool on = e.hp < e.max_hp * tun.frenzy_at;
		if (on != (e.st.find(st_frenzy) >= 0)) {
			if (on && e.st.n < STATUS_MAX) {
				StatusRec fr;
				fr.id = st_frenzy;
				fr.stk = 1.0;
				fr.rem = STATUS_FOREVER;
				e.st.rec[e.st.n++] = fr;
			} else {
				e.st.erase(st_frenzy);
			}
			dirty = true;
		}
	}
	if (dirty && e.state != DEAD) {
		statuses_changed(e);
	}
}

// ---------------------------------------------------------------------------------------------------------------- the tick

void World::step(double p_dt) {
	clock += p_dt;
	const int32_t n = int32_t(enemies.size());
	for (int32_t i = 0; i < n; i++) {
		Enemy &e = enemies[i];
		if (e.state == DEAD) {  // the brain stops at death (set_physics_process(false)); only the linger runs
			e.state_t += p_dt;
			continue;
		}
		// DmEnemy._physics_process order: attack cooldown, incense, stagger, the state machine, then movement.
		if (e.state != HURT && e.state != RISING) {
			e.attack_cd -= p_dt * e.attack_rate_mult * (e.incense_t > 0.0 ? INCENSE_ATTACK : 1.0);
		}
		if (e.incense_t > 0.0) {
			e.incense_t -= p_dt;
		}
		e.stagger_t -= p_dt;
		e.state_t += p_dt;
		const int32_t nxt = tick_state(i, p_dt);
		if (nxt >= 0 && nxt != enemies[i].state) {
			change(i, nxt);
		}
		if (enemies[i].state != DEAD) {
			advance_statuses(i, p_dt);
		}
	}
	separate();
	for (int32_t i = 0; i < n; i++) {
		if (enemies[i].state != DEAD) {
			move(enemies[i], p_dt);
		}
	}
	step_zones(p_dt);
	remove_dead_bodies();
	grid_count = int32_t(enemies.size());
	gx.resize(grid_count);
	gz.resize(grid_count);
	for (int32_t i = 0; i < grid_count; i++) {
		gx[i] = enemies[i].x;
		gz[i] = enemies[i].z;
	}
	grid.rebuild(gx.data(), gz.data(), grid_count);
}

// Replaces Godot's RVO avoidance (B42): bodies that overlap push each other apart through their wanted velocity. Surface bodies only.
void World::separate() {
	const int32_t n = int32_t(enemies.size());
	for (int32_t i = 0; i < n; i++) {
		Enemy &a = enemies[i];
		if (a.state == DEAD || a.state == BURROW || a.state == ERUPT || (a.want_vx == 0.0 && a.want_vz == 0.0)) {
			continue;
		}
		double px = 0.0, pz = 0.0;
		for (int32_t j = 0; j < n; j++) {
			const Enemy &b = enemies[j];
			if (j == i || b.state == DEAD || b.state == BURROW || b.state == ERUPT) {
				continue;
			}
			const float dx = a.x - b.x, dz = a.z - b.z;
			const double d = std::sqrt(double(dx) * dx + double(dz) * dz);
			const double want = a.radius + b.radius + 0.1;
			if (d < want && d > 1e-4) {
				const double push = (want - d) / want;
				px += dx / d * push;
				pz += dz / d * push;
			}
		}
		if (px != 0.0 || pz != 0.0) {
			const double sp = std::sqrt(a.want_vx * a.want_vx + a.want_vz * a.want_vz);
			a.want_vx += px * sp;
			a.want_vz += pz * sp;
		}
	}
}

// DmEnemy._move: apply the wanted velocity, turn toward it, keep to the navmesh and outside heroes' bodies.
void World::move(Enemy &e, double p_dt) {
	const double vx = e.want_vx, vz = e.want_vz;
	e.ground_speed = std::sqrt(vx * vx + vz * vz);
	if (vx != 0.0 || vz != 0.0) {
		e.x += float(vx * p_dt);
		e.z += float(vz * p_dt);
		if (e.state != BURROW && e.state != ERUPT) {
			for (const External &x : externals) {  // the hero capsule blocks enemies (layer PLAYER)
				if (!x.alive || x.kind != 0) {
					continue;
				}
				const float dx = e.x - x.x, dz = e.z - x.z;
				const double d = std::sqrt(double(dx) * dx + double(dz) * dz), min_d = e.radius + x.radius;
				if (d < min_d && d > 1e-4) {
					e.x = x.x + float(dx / d * min_d);
					e.z = x.z + float(dz / d * min_d);
				}
			}
		}
		if (nav.clamp) {
			nav.clamp(nav.user, e.x, e.z);
		}
		e.yaw = float(lerp_angle(e.yaw, std::atan2(vx, vz), std::min(1.0, TURN_RATE * p_dt)));
	}
	e.want_vx = e.want_vz = 0.0;
}

void World::step_zones(double p_dt) {  // DmHostileZone._physics_process
	size_t w = 0;
	for (size_t i = 0; i < zones.size(); i++) {
		Zone &z = zones[i];
		z.age += p_dt;
		if (z.age >= z.lifetime) {
			events.push(EV_ZONE_GONE, z.id, {}, {});
			continue;
		}
		if (z.tick < 0.0) {
			z.tick = ZONE_TICK_S;
		}
		z.tick -= p_dt;
		if (z.tick <= 0.0) {
			z.tick = ZONE_TICK_S;
			const double r = z.radius + ZONE_TARGET_PAD;
			for (const External &x : externals) {
				if (x.alive && x.kind == 0 && flat_dist(z.x, z.z, x.x, x.z) <= r) {
					events.push(EV_TARGET_HIT, z.source, { x.id, z.hit_kind }, { float(z.dps * ZONE_TICK_S) });
				}
			}
			events.push(EV_ZONE_PULSE, z.id, {}, {});
		}
		zones[w++] = z;
	}
	zones.resize(w);
}

void World::remove_dead_bodies() {
	size_t w = 0;
	for (size_t r = 0; r < enemies.size(); r++) {
		const Enemy &e = enemies[r];
		if (e.state == DEAD && e.state_t >= BODY_LINGER_S) {
			events.push(EV_ENEMY_REMOVED, e.id, {}, {});
			enemy_slot.erase(e.id);
			continue;
		}
		if (w != r) {  // stable compaction keeps spawn order
			enemies[w] = enemies[r];
			enemy_slot[enemies[w].id] = int32_t(w);
		}
		w++;
	}
	enemies.resize(w);
}

void World::enemies_in_radius(float p_x, float p_z, float p_r, std::vector<int32_t> &out) {
	double pad = 0.0;
	for (const Enemy &e : enemies) {
		pad = e.radius > pad ? e.radius : pad;
	}
	grid.query(p_x, p_z, float(p_r + pad), scratch);
	for (int32_t s = grid_count; s < int32_t(enemies.size()); s++) {  // spawned since the last step: not in the grid yet
		scratch.push_back(s);
	}
	out.clear();
	for (int32_t s : scratch) {
		if (s >= int32_t(enemies.size()) || enemies[s].hp <= 0.0) {  // alive = hp > 0, so RISING and underground bodies count
			continue;
		}
		const Enemy &e = enemies[s];
		if (flat_dist(p_x, p_z, e.x, e.z) - e.radius <= p_r) {
			out.push_back(s);
		}
	}
}

} // namespace dm
