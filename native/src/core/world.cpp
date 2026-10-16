#include "world.h"

#include <algorithm>

// The enemy brain is a port of godot/enemies: DmEnemy (dm_enemy.gd), its states (states/*.gd) and the Graves kinds (flanker, caster,
// hazard, burrower). Comments name the GDScript it mirrors. Differences from today are listed in native/README.md.

namespace dm {

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

int32_t World::spawn_enemy(int32_t p_def, float p_x, float p_z, int32_t p_level, double p_hp_mult, double p_damage_mult, bool p_elite, int32_t p_area, bool p_rising, int32_t p_affixes) {
	const int32_t slot = int32_t(enemies.size());
	enemies.push_back(make_enemy(p_def, p_x, p_z, p_level, p_hp_mult, p_damage_mult, p_elite, p_area, p_rising, p_affixes));
	Enemy &e = enemies[slot];
	e.slot = slot;
	enemy_slot[e.id] = slot;
	enter(e, -1);
	return e.id;
}

void World::flush_spawns() {
	for (Enemy &p : pending_spawns) {
		p.slot = int32_t(enemies.size());
		enemy_slot[p.id] = p.slot;
		enemies.push_back(p);
	}
	pending_spawns.clear();
}

// A new body (DmEnemy._ready): its id, its rolls and EV_ENEMY_SPAWNED. The caller puts it in the table and runs its first enter().
Enemy World::make_enemy(int32_t p_def, float p_x, float p_z, int32_t p_level, double p_hp_mult, double p_damage_mult, bool p_elite, int32_t p_area, bool p_rising, int32_t p_affixes) {
	const EnemyDef &d = defs[p_def];
	Enemy e;
	e.id = next_id++;
	e.frenzy = d.frenzy;
	e.rng.seed(seed, uint64_t(e.id));
	e.def = p_def;
	e.level = p_level;
	e.area = p_area;
	e.elite = p_elite;
	e.affixes = uint8_t(p_affixes);
	e.hp_mult = p_hp_mult;
	e.damage_mult = p_damage_mult;
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
	events.push(EV_ENEMY_SPAWNED, e.id, { p_def, p_level, p_elite ? 1 : 0, p_area, p_affixes }, { p_x, p_z, float(e.max_hp) });
	return e;
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
			Tgt t;
			const bool have = target_at(e.target, t);
			e.aim_x = have ? t.x : e.x;
			e.aim_z = have ? t.z : e.z;
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
			Tgt tg;
			if (!target_at(e.target, tg)) {
				return flat_dist(e.x, e.z, e.home_x, e.home_z) > HOME_ARRIVE ? RETURN : IDLE;
			}
			double d = flat_dist(e.x, e.z, tg.x, tg.z);
			if (d > AGGRO_RANGE * DROP_MULT || flat_dist(e.x, e.z, e.home_x, e.home_z) > LEASH) {
				e.target = 0;
				return RETURN;
			}
			if (scan_due(e, p_dt)) {
				const int32_t nearer = find_target(e, AGGRO_RANGE);
				if (nearer != 0 && nearer != e.target) {
					e.target = nearer;
					target_at(nearer, tg);
					d = flat_dist(e.x, e.z, tg.x, tg.z);
				}
			}
			return engage(e, tg.x, tg.z, d, p_dt);
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
			Tgt tg;
			if (!target_at(e.target, tg)) {
				return IDLE;
			}
			if (t >= defs[e.def].hit_run) {
				return CHASE;
			}
			const double d = std::max(0.001, flat_dist(e.x, e.z, tg.x, tg.z));
			const float px = float(-(tg.z - e.z) / d), pz = float((tg.x - e.x) / d);
			steer_to(e, e.x * 2.0f - tg.x + px * 2.0f * float(e.flank_side), e.z * 2.0f - tg.z + pz * 2.0f * float(e.flank_side), 1.0, p_dt);
			return -1;
		}
		case BURROW: {  // dm_state_burrow
			Tgt tg;
			bool have = target_at(e.target, tg);
			if (!have || scan_due(e, p_dt)) {
				e.target = find_target(e, AGGRO_RANGE);
				have = target_at(e.target, tg);
			}
			if (!have) {
				return -1;
			}
			const double d = flat_dist(e.x, e.z, tg.x, tg.z);
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
			move_straight(e, tg.x, tg.z, tun.burrow_speed);
			e.burrow_left -= tun.burrow_speed * p_dt;
			face_point(e, tg.x, tg.z, p_dt);
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
			each_target([&](const Tgt &x) {  // DmEnemy.targets_within: heroes, then thralls
				if (flat_dist(e.aim_x, e.aim_z, x.x, x.z) <= tun.burrow_erupt_r) {
					hit_target(e, x.id, dmg, defs[e.def].hit_kind);
				}
			});
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

// DmEnemy.find_target: nearest alive target, squared flat distance times weight squared (thrall 1.1, shieldbearer 0.55, hero 1.0),
// strict <, heroes before thralls in raise order on ties.
int32_t World::find_target(const Enemy &e, double p_range) const {
	int32_t best = 0;
	double best_d = p_range * p_range;
	each_target([&](const Tgt &x) {
		const float dx = x.x - e.x, dz = x.z - e.z;
		double d = double(dx) * dx + double(dz) * dz;
		d *= x.weight * x.weight;  // `d *= w * w`
		if (d < best_d) {
			best_d = d;
			best = x.id;
		}
	});
	return best;
}

// DmEnemy.target_valid for a target id: a hero in the externals, or a thrall that is neither rising nor dead.
bool World::target_at(int32_t p_id, Tgt &r_target) const {
	if (p_id == 0) {
		return false;
	}
	for (const External &x : externals) {
		if (x.id == p_id) {
			if (!x.alive || x.kind != 0) {
				return false;
			}
			r_target = Tgt{ x.id, x.x, x.z, x.radius, x.weight };
			return true;
		}
	}
	const auto it = thrall_slot.find(p_id);
	if (it == thrall_slot.end()) {
		return false;
	}
	const Thrall &t = thralls[it->second];
	if (!t.alive_target()) {
		return false;
	}
	r_target = Tgt{ t.id, t.x, t.z, t.radius, thrall_target_weight(t) };
	return true;
}

const External *World::find_external(int32_t p_id) const {
	for (const External &x : externals) {
		if (x.id == p_id) {
			return &x;
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
				e.path_len = nav.path(nav.user, e.x, e.z, p_gx, p_gz, e.path, PATH_POINTS);
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
	Tgt tg;
	if (target_at(e.target, tg)) {
		e.aim_x = tg.x;
		e.aim_z = tg.z;
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
			Tgt tg;
			if (target_at(e.target, tg) && flat_dist(e.x, e.z, tg.x, tg.z) <= e.attack_range * STRIKE_REACH_MULT + STRIKE_REACH_PAD) {
				hit_target(e, tg.id, e.damage, d.hit_kind);
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
			each_target([&](const Tgt &x) {  // DmEnemy.targets_within(reach), then the angle
				const float vx = x.x - e.x, vz = x.z - e.z;
				const double dd = std::sqrt(double(vx) * vx + double(vz) * vz);
				if (dd > reach) {
					return;
				}
				if (dd < 0.001 || (double(vx) * dx + double(vz) * dz) / (dd * ln) > cos_lim) {
					hit_target(e, x.id, e.damage, d.hit_kind);
				}
			});
			break;
		}
		case BLOW_DUST: {
			each_target([&](const Tgt &x) {
				if (flat_dist(e.aim_x, e.aim_z, x.x, x.z) <= tun.dust_radius) {
					hit_target(e, x.id, e.damage, HK_DUST);
				}
			});
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
			each_target([&](const Tgt &x) {
				if (flat_dist(e.aim_x, e.aim_z, x.x, x.z) <= d.slam_r) {
					hit_target(e, x.id, e.damage, d.hit_kind);
				}
			});
			events.push(EV_CUE, e.id, { CUE_SLAM }, { e.aim_x, e.aim_z, float(d.slam_r) });
			break;
		}
		default:
			break;
	}
}

void World::hit_target(Enemy &e, int32_t p_target, double p_damage, int32_t p_kind) {
	hit_id(e.id, p_target, p_damage, p_kind);
}

// DmEnemy.deliver: a hero's blow is an event for GDScript to apply; a thrall takes it here (dm_take_enemy_hit -> take_damage).
void World::hit_id(int32_t p_source, int32_t p_target, double p_damage, int32_t p_kind) {
	const auto it = thrall_slot.find(p_target);
	if (it != thrall_slot.end()) {
		bool killed = false;
		damage_thrall(it->second, p_damage, p_source, killed);
		return;
	}
	events.push(EV_TARGET_HIT, p_source, { p_target, p_kind }, { float(p_damage) });
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

// DmEnemy.take_damage -> sm.change(DEAD), then the listeners of `died` in today's order: director, affixes (Vengeful), status set, corpse field,
// rewards. The director's bookkeeping and the rewards are GDScript's, from the events.
void World::kill(int32_t p_slot, int32_t p_source) {
	Enemy &e = enemies[p_slot];
	e.hp = 0.0;
	e.dead = true;
	change(p_slot, DEAD);
	if (enemies[p_slot].affixes & (1 << AF_VENGEFUL)) {
		vengeance(enemies[p_slot]);
	}
	Enemy &k = enemies[p_slot];
	body_died_statuses(k);
	lay_corpses(k);
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

Body *World::body(int32_t p_id) {
	const auto it = enemy_slot.find(p_id);
	if (it != enemy_slot.end()) {
		return &enemies[it->second];
	}
	const auto tt = thrall_slot.find(p_id);
	return tt != thrall_slot.end() ? &thralls[tt->second] : nullptr;
}

const Body *World::body(int32_t p_id) const {
	return const_cast<World *>(this)->body(p_id);
}

void World::statuses_changed(Body &b) {
	b.st.recompute(status_rules);
	b.speed_mult = b.st.move;  // DmStatusSet owns these multipliers on its body
	b.attack_rate_mult = b.st.atk;
	b.taken_mult = b.st.taken;
	events.push(EV_STATUS_CHANGED, b.id, {}, {});
}

// DmStatusSet._on_died: report Withered (Contagion, Plague Choir spread), then clear.
void World::body_died_statuses(Body &b) {
	const int32_t w = st_withered >= 0 ? b.st.find(st_withered) : -1;
	if (w >= 0) {
		events.push(EV_WITHERED_DIED, b.id, { b.st.rec[w].src }, { float(b.st.rec[w].stk), float(b.st.rec[w].val) });
	}
	if (b.st.n > 0) {
		b.st.n = 0;
		statuses_changed(b);
	}
}

// DmStatusSet.absorb: a barrier soaks damage before health (thralls and heroes; DmEnemy.take_damage does not call it).
double World::absorb(Body &b, double p_amount) {
	const int32_t i = st_barrier >= 0 ? b.st.find(st_barrier) : -1;
	if (i < 0) {
		return p_amount;
	}
	StatusRec &r = b.st.rec[i];
	const double a = std::min(r.val, p_amount);
	r.val -= a;
	if (r.val <= 0.0) {
		remove_status(b, st_barrier);
	}
	return p_amount - a;
}

// The owner's stun(): an enemy flinches into HURT for the time, a thrall stops thinking for it.
void World::stun_body(Body &b, double p_seconds) {
	if (b.is_thrall) {
		stun_thrall(thralls[b.slot], p_seconds);
	} else {
		stun(b.slot, p_seconds);
	}
}

// DmStatusSet._deal(..., "dot"): the owner's take_damage(amount, source, false). True when it was applied.
bool World::deal_dot(Body &b, double p_amount, int32_t p_source, bool &r_killed) {
	r_killed = false;
	if (b.is_thrall) {
		return damage_thrall(b.slot, p_amount, p_source, r_killed);
	}
	return damage_enemy(b.slot, p_amount, p_source, false, r_killed) > 0.0;
}

void World::apply_status(Body &b, int32_t p_status, int32_t p_source, double p_stacks, double p_duration, double p_dps, double p_cap, double p_amount) {
	if (b.dead || p_status < 0 || p_status >= int32_t(status_rules.size())) {
		return;
	}
	const StatusRule &d = status_rules[p_status];
	const double dur = p_duration >= 0.0 ? p_duration : d.dur;
	int32_t i = b.st.find(p_status);
	const bool fresh = i < 0;
	if (fresh) {
		if (b.st.n >= STATUS_MAX) {
			return;
		}
		i = b.st.n++;
		b.st.rec[i] = StatusRec();
		b.st.rec[i].id = p_status;
	}
	StatusRec &r = b.st.rec[i];
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
		statuses_changed(b);
	}
	if (p_status == st_stun && new_rem > old_rem) {
		stun_body(b, dur);
	}
}

bool World::remove_status(Body &b, int32_t p_status) {
	if (!b.st.erase(p_status)) {
		return false;
	}
	statuses_changed(b);
	return true;
}

// DmStatusSet.advance: one step per 0.1 s of accumulated time, the step's dt being the whole accumulator.
void World::advance_statuses(Body &b, double p_dt) {
	if (b.st.n == 0 && !b.frenzy) {
		return;
	}
	b.st.acc += p_dt;
	if (b.st.acc >= STATUS_TICK_S) {
		const double dt = b.st.acc;
		b.st.acc = 0.0;
		step_statuses(b, dt);
	}
}

// DmStatusSet._step
void World::step_statuses(Body &b, double p_dt) {
	StatusSet &s = b.st;
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
		const int32_t i = b.st.find(dots[k]);
		if (i < 0) {
			continue;  // the body died during an earlier lump and cleared the set
		}
		StatusRec &r = b.st.rec[i];
		const double amt = r.acc;
		const int32_t src = r.src;
		r.acc = 0.0;
		if (amt > 0.0 && !b.dead) {
			bool killed = false;
			if (deal_dot(b, amt, src, killed)) {  // no stagger from a DoT; damage taken applies inside
				events.push(EV_STATUS_DOT, b.id, { dots[k], src, killed ? 1 : 0 }, { float(amt * b.st.taken) });
			}
		}
	}
	for (int32_t k = 0; k < ng; k++) {
		if (b.st.erase(gone[k])) {
			dirty = true;
			events.push(EV_STATUS_EXPIRED, b.id, { gone[k] }, {});
		}
	}
	if (b.frenzy && st_frenzy >= 0 && !b.dead) {  // Frenzy below FRENZY.atFrac of max health
		const bool on = b.hp < b.max_hp * tun.frenzy_at;
		if (on != (b.st.find(st_frenzy) >= 0)) {
			if (on && b.st.n < STATUS_MAX) {
				StatusRec fr;
				fr.id = st_frenzy;
				fr.stk = 1.0;
				fr.rem = STATUS_FOREVER;
				b.st.rec[b.st.n++] = fr;
			} else {
				b.st.erase(st_frenzy);
			}
			dirty = true;
		}
	}
	if (dirty && !b.dead) {
		statuses_changed(b);
	}
}

// ---------------------------------------------------------------------------------------------------------------- the tick

// One 60 Hz tick in today's order (combat map section 1): the thrall host's separation (it runs with the heroes, first), the enemies in spawn
// order (each followed by its statuses), the hostile zones, the corpses, then every thrall in raise order. Enemies therefore see the
// positions thralls ended the last tick with, and a thrall can kill an enemy that already acted this tick.
void World::step(double p_dt) {
	clock += p_dt;
	separate_thralls();
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
			advance_statuses(enemies[i], p_dt);
		}
	}
	separate();
	for (int32_t i = 0; i < n; i++) {
		if (enemies[i].state != DEAD) {
			move(enemies[i], p_dt);
		}
	}
	resolve_overlaps();
	for (int32_t i = 0; i < n; i++) {
		if (enemies[i].state != DEAD && enemies[i].affixes) {  // the "Affixes" child runs after its body moved (and after the status set)
			tick_affixes(i, p_dt);
		}
	}
	step_zones(p_dt);
	step_corpses(p_dt);
	step_thralls(p_dt);
	remove_dead_bodies();
	flush_spawns();
	grid_count = int32_t(enemies.size());
	gx.resize(grid_count);
	gz.resize(grid_count);
	for (int32_t i = 0; i < grid_count; i++) {
		gx[i] = enemies[i].x;
		gz[i] = enemies[i].z;
	}
	grid.rebuild(gx.data(), gz.data(), grid_count);
}

// Replaces Godot's RVO avoidance (B42), with resolve_overlaps() after the moves. A moving body near another (closer than their radii + 0.1)
// does not drive into it: the part of its wanted velocity that points at that neighbour is dropped, so a crowd queues and slides around
// instead of piling into the bodies in front; and it is pushed away in proportion to the closeness. Surface bodies only, slot order.
void World::separate() {
	const int32_t n = int32_t(enemies.size());
	for (int32_t i = 0; i < n; i++) {
		Enemy &a = enemies[i];
		if (!on_surface(a) || (a.want_vx == 0.0 && a.want_vz == 0.0)) {
			continue;
		}
		const double sp = std::sqrt(a.want_vx * a.want_vx + a.want_vz * a.want_vz);
		double vx = a.want_vx, vz = a.want_vz, px = 0.0, pz = 0.0;
		for (int32_t j = 0; j < n; j++) {
			const Enemy &b = enemies[j];
			if (j == i || !on_surface(b)) {
				continue;
			}
			const float dx = a.x - b.x, dz = a.z - b.z;
			const double d = std::sqrt(double(dx) * dx + double(dz) * dz);
			const double want = a.radius + b.radius + 0.1;
			if (d < want && d > 1e-4) {
				const double ux = dx / d, uz = dz / d;  // away from b
				const double push = (want - d) / want;
				px += ux * push;
				pz += uz * push;
				const double into = -(vx * ux + vz * uz);  // speed toward b
				if (into > 0.0) {
					vx += ux * into;
					vz += uz * into;
				}
			}
		}
		if (px != 0.0 || pz != 0.0) {
			a.want_vx = vx + px * sp;
			a.want_vz = vz + pz * sp;
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
			keep_off_heroes(e);
		}
		if (nav.clamp) {
			nav.clamp(nav.user, e.x, e.z);
		}
		e.yaw = float(lerp_angle(e.yaw, std::atan2(vx, vz), std::min(1.0, TURN_RATE * p_dt)));
	}
	e.want_vx = e.want_vz = 0.0;
}

void World::keep_off_heroes(Enemy &e) const {  // the hero capsule blocks enemies (layer PLAYER)
	for (const External &x : externals) {
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

// Crowd spacing, the rest of what Godot's RVO did for today's bodies (B42; native/README.md "Differences"): separate() only steers bodies that
// want to move, so a crowd standing around its target (attacking, idle) would pile up. After everyone moved, every overlapping pair of surface
// bodies, moving or standing, eases apart by OVERLAP_EASE of its overlap, split by size (the bigger body gives way less), each body by at most
// OVERLAP_MAX_STEP per tick. Corrections are summed from the same positions before any is applied, so the result does not depend on slot order.
// Neighbours come from the grid (built at the end of the last tick, so its query is padded by the most a body moves in a tick) and a scan of
// the slots spawned since.
void World::resolve_overlaps() {
	const int32_t n = int32_t(enemies.size());
	double max_r = 0.0;
	for (const Enemy &e : enemies) {
		max_r = std::max(max_r, e.radius);
	}
	overlap_scratch.assign(size_t(n) * 2, 0.0);
	double *ox = overlap_scratch.data(), *oz = ox + n;
	bool any = false;
	auto pair = [&](int32_t i, int32_t j) {
		const Enemy &a = enemies[i], &b = enemies[j];
		const double dx = double(a.x) - double(b.x), dz = double(a.z) - double(b.z);
		const double want = a.radius + b.radius, d2 = dx * dx + dz * dz;
		if (d2 >= want * want) {
			return;
		}
		const double d = std::sqrt(d2);
		double ux, uz;
		if (d > 1e-4) {
			ux = dx / d;
			uz = dz / d;
		} else {  // exactly on top of each other: part along a fixed direction from the pair's ids, so it is the same on every run
			const double ang = double((a.id * 7919 + b.id * 104729) % 360) * PI / 180.0;
			ux = std::cos(ang);
			uz = std::sin(ang);
		}
		const double pen = (want - d) * OVERLAP_EASE, wa = b.radius / want, wb = a.radius / want;
		ox[i] += ux * pen * wa;
		oz[i] += uz * pen * wa;
		ox[j] -= ux * pen * wb;
		oz[j] -= uz * pen * wb;
		any = true;
	};
	const int32_t gc = std::min(grid_count, n);
	for (int32_t i = 0; i < n; i++) {
		const Enemy &a = enemies[i];
		if (!on_surface(a)) {
			continue;
		}
		if (i < gc) {
			grid.query(a.x, a.z, float(a.radius + max_r + 0.5), near_scratch);
			for (const int32_t j : near_scratch) {
				if (j > i && j < gc && on_surface(enemies[j])) {
					pair(i, j);
				}
			}
		}
		for (int32_t j = std::max(gc, i + 1); j < n; j++) {  // the slots spawned since the grid was built, against every body
			if (on_surface(enemies[j])) {
				pair(i, j);
			}
		}
	}
	if (!any) {
		return;
	}
	for (int32_t i = 0; i < n; i++) {
		double cx = ox[i], cz = oz[i];
		if (cx == 0.0 && cz == 0.0) {
			continue;
		}
		const double len = std::sqrt(cx * cx + cz * cz);
		if (len > OVERLAP_MAX_STEP) {
			cx *= OVERLAP_MAX_STEP / len;
			cz *= OVERLAP_MAX_STEP / len;
		}
		Enemy &e = enemies[i];
		e.x += float(cx);
		e.z += float(cz);
		keep_off_heroes(e);
		if (nav.clamp) {
			nav.clamp(nav.user, e.x, e.z);
		}
	}
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
			z.tick = z.period;
		}
		z.tick -= p_dt;
		if (z.tick <= 0.0) {
			z.tick = z.period;
			const double r = z.radius + ZONE_TARGET_PAD;
			const double dmg = z.dps * z.period;
			const int32_t zs = z.source, zk = z.hit_kind;
			const float zx = z.x, zz = z.z;
			each_target([&](const Tgt &x) {  // every dm_target in the zone: heroes, then thralls
				if (flat_dist(zx, zz, x.x, x.z) <= r) {
					hit_id(zs, x.id, dmg, zk);
				}
			});
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
			enemies[w].slot = int32_t(w);
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
