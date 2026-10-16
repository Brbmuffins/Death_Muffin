#pragma once
// The core's tables and the enemy brain (native/README.md "Design"). Enemies live in spawn order: a slot only moves by stable
// compaction when a dead body is removed, so slot order is spawn order and every scan keeps today's tie-breaks. The brain is a port of
// godot/enemies (DmEnemy, its states and kinds) for the Graves roster; timers count in doubles the way the GDScript did.
#include <cmath>
#include <cstdint>
#include <limits>
#include <string>
#include <unordered_map>
#include <vector>

#include "events.h"
#include "grid.h"
#include "rng.h"

namespace dm {

// Wire ids of today's enemy states (godot/enemies/states/dm_enemy_state.gd): append only.
enum EnemyState : int32_t { RISING = 0, IDLE, CHASE, ATTACK, HURT, RETURN, DEAD, FLEE, BURROW, ERUPT, DIG, EMERGE };
enum Behavior : int32_t { B_MELEE = 0, B_FLANK, B_CASTER, B_HAZARD };
enum Blow : int32_t { BLOW_MELEE = 0, BLOW_CONE, BLOW_DUST, BLOW_SLAM };
// Damage kinds of a hit on a target (the sim's hurt `from`; GDScript maps them back to strings): append only.
enum HitKind : int32_t { HK_MELEE = 0, HK_TOXIC, HK_BURN, HK_EMBER, HK_DUST, HK_CURSE, HK_TOLL };
// Telegraph and cue kinds (DmEnemy.telegraph / cue): append only.
enum Tell : int32_t { TELL_CONE = 0, TELL_SLAM, TELL_DUST, TELL_ERUPT };
enum Cue : int32_t { CUE_SLAM = 0, CUE_ERUPT, CUE_DIG_IN };
enum ZoneKind : int32_t { ZONE_DUST = 0 };

constexpr double TICK = 1.0 / 60.0;
constexpr double RISE_S = 1.1;
constexpr double BODY_LINGER_S = 4.0;   // the director frees a dead body 4 s later; until then it counts toward the global cap
constexpr double AGGRO_RANGE = 15.0, DROP_MULT = 1.5, LEASH = 30.0, HOME_ARRIVE = 1.0;
constexpr double ATTACK_TRIGGER_PAD = 0.35, STOP_FRAC = 0.8, STRIKE_REACH_MULT = 1.35, STRIKE_REACH_PAD = 0.4;
constexpr double WANDER_SPEED_MULT = 0.3, WANDER_RADIUS = 4.0, STAGGER_ICD = 0.9, RECOVER_S = 0.3, HURT_S = 0.3;
constexpr double REPATH_S = 0.3, REPATH_MOVE_SQ = 1.0, DIRECT_RANGE_SQ = 9.0, SCAN_S = 0.25, TURN_RATE = 14.0;
constexpr double INCENSE_MOVE = 1.3, INCENSE_ATTACK = 1.25, PATH_DESIRED = 0.5;
constexpr double KITE_BACK_OFF = 3.5, KITE_BACK_SPEED = 0.8, CONE_HALF_ANGLE = 30.0 * 3.14159265358979323846 / 180.0, CONE_PAD = 0.4;
constexpr double ZONE_TARGET_PAD = 0.45, ZONE_TICK_S = 1.0, BURROW_STUCK_S = 0.8, DEFAULT_SLAM_R = 1.9;
constexpr int PATH_MAX = 24;

struct Tuning {  // data/content/enemies.json blocks
	double elite_hp = 3.6, elite_damage = 1.5, elite_windup = 0.85, elite_cooldown = 0.8, elite_radius = 1.25;
	double dust_radius = 2.0, dust_cloud_s = 3.5, dust_cloud_dps = 0.35;
	double burrow_speed = 4.2, burrow_surface_r = 2.5, burrow_erupt_r = 1.8, burrow_erupt_mult = 1.25, burrow_erupt_mult_graves = 1.0;
	double burrow_erupt_s_graves = 1.0, burrow_erupt_s = 0.8, burrow_dig_s = 0.8, burrow_dig_at = 0.5, burrow_travel = 8.0;
	int32_t burrow_max_per_target = 3;
};

struct EnemyDef {
	std::string id;
	double hp = 1, damage = 1, speed = 1, radius = 0.45;
	double attack_range = 1.3, windup_s = 0.4, cooldown_s = 1.3, scale = 1, hit_run = 0, flying = 0, slam_r = DEFAULT_SLAM_R;
	int32_t behavior = B_MELEE, blow = BLOW_MELEE, hit_kind = HK_MELEE;
	bool burrow = false;
};

struct Enemy {
	int32_t id = 0, def = 0, level = 1, area = 0, state = IDLE, last_source = 0, target = 0, phase = 0;
	bool elite = false, in_graves = true, dug_in = false;
	float x = 0, z = 0, yaw = 0, home_x = 0, home_z = 0, aim_x = 0, aim_z = 0, last_x = 0, last_z = 0;
	double hp = 1, max_hp = 1, damage = 1, speed = 1, radius = 0.45, attack_range = 1.3, windup_s = 0.4, cooldown_s = 1.3;
	double attack_cd = 0, state_t = 0, flank_side = 1, scan_t = 0, repath_t = 0, stagger_t = 0, wander_heading = 0;
	double hurt_s = HURT_S, erupt_s = 1.0, speed_mult = 1, attack_rate_mult = 1, incense_t = 0, taken_mult = 1;
	double want_vx = 0, want_vz = 0, ground_speed = 0, burrow_left = std::numeric_limits<double>::infinity(), stuck_t = 0;
	bool has_nav_goal = false;
	float nav_gx = 0, nav_gz = 0;
	int32_t path_len = 0, path_i = 0;
	float path[PATH_MAX * 2] = {};
	Rng rng;
};

struct External {  // a hero or a boss: GDScript writes it every tick
	int32_t id = 0, kind = 0;  // kind 0 hero, 1 boss
	float x = 0, z = 0;
	double radius = 0.4, weight = 1.0;
	bool alive = true;
};

struct Zone {  // a hostile ground zone (DmHostileZone): pulses dps x 1 s at every target within radius + 0.45
	int32_t id = 0, kind = ZONE_DUST, source = 0, hit_kind = HK_DUST;
	float x = 0, z = 0;
	double radius = 2, lifetime = 1, dps = 1, age = 0, tick = -1;
};

// Path queries go through this hook (the Godot navigation server in DmCore; straight lines when unset, as in tests).
struct NavHook {
	void *user = nullptr;
	int32_t (*path)(void *user, float fx, float fz, float tx, float tz, float *out_xz, int32_t max_points) = nullptr;
	void (*clamp)(void *user, float &x, float &z) = nullptr;
};

struct World {
	uint64_t seed = 1;
	int32_t next_id = 1;
	double clock = 0;
	bool wander_enabled = true;  // DmEnemy.wander_enabled (tests turn it off)
	Tuning tun;
	NavHook nav;
	std::vector<EnemyDef> defs;
	std::unordered_map<std::string, int32_t> def_index;
	std::vector<std::string> areas;
	std::unordered_map<std::string, int32_t> area_index;
	std::vector<Enemy> enemies;
	std::unordered_map<int32_t, int32_t> enemy_slot;  // id -> slot
	std::vector<External> externals;
	std::vector<Zone> zones;
	Grid grid;
	int32_t grid_count = 0;  // slots the grid was built with; later spawns are scanned directly
	Events events;
	std::vector<int32_t> scratch;
	std::vector<float> gx, gz;  // grid input

	int32_t area_id(const std::string &p_area);
	int32_t spawn_enemy(int32_t p_def, float p_x, float p_z, int32_t p_level, double p_hp_mult, double p_damage_mult, bool p_elite, int32_t p_area, bool p_rising);
	// Damage from a cast, a thrall, a zone or a boss: a kill resolves at once (combat map section 7). Returns the amount dealt.
	double damage_enemy(int32_t p_slot, double p_amount, int32_t p_source, bool p_allow_stagger, bool &r_killed);
	void stun(int32_t p_slot, double p_seconds);
	void step(double p_dt);
	void enemies_in_radius(float p_x, float p_z, float p_r, std::vector<int32_t> &out);

private:
	void change(int32_t p_slot, int32_t p_next);
	void enter(Enemy &e, int32_t p_prev);
	int32_t tick_state(int32_t p_slot, double p_dt);
	int32_t engage(Enemy &e, float p_tx, float p_tz, double p_d, double p_dt);
	void move(Enemy &e, double p_dt);
	void separate();
	void step_zones(double p_dt);
	void remove_dead_bodies();
	void kill(int32_t p_slot, int32_t p_source);
	// brain helpers (DmEnemy)
	bool scan_due(Enemy &e, double p_dt);
	int32_t find_target(const Enemy &e, double p_range) const;
	const External *target_ext(int32_t p_id) const;
	bool target_valid(int32_t p_id) const { return target_ext(p_id) != nullptr; }
	void stop(Enemy &e);
	void steer_to(Enemy &e, float p_gx, float p_gz, double p_mult, double p_dt);
	void move_straight(Enemy &e, float p_gx, float p_gz, double p_speed);
	void face_point(Enemy &e, float p_px, float p_pz, double p_dt);
	void wander(Enemy &e, double p_dt);
	void begin_attack(Enemy &e);
	void strike(Enemy &e);
	void hit_target(Enemy &e, int32_t p_target, double p_damage, int32_t p_kind);
	bool hittable(const Enemy &e) const { return e.state != BURROW && e.state != ERUPT; }
	int32_t post_attack_state(const Enemy &e) const;
	static double flat_dist(float ax, float az, float bx, float bz) {
		const float dx = bx - ax, dz = bz - az;
		return std::sqrt(double(dx) * dx + double(dz) * dz);
	}
};

} // namespace dm
