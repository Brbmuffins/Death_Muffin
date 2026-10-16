#pragma once
// The core's tables (native/README.md "Design"). Enemies live in spawn order: slots only move by stable compaction when a dead body
// is removed, so slot order is spawn order and every scan keeps today's tie-breaks.
#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>

#include "events.h"
#include "grid.h"
#include "rng.h"

namespace dm {

// Wire ids of today's enemy states (godot/enemies/states/dm_enemy_state.gd): append only.
enum EnemyState : int32_t { RISING = 0, IDLE, CHASE, ATTACK, HURT, RETURN, DEAD, FLEE, BURROW, ERUPT, DIG, EMERGE };

constexpr double TICK = 1.0 / 60.0;
constexpr double RISE_S = 1.1;          // RISING: inert and unhittable
constexpr double BODY_LINGER_S = 4.0;   // a dead body stays (and counts toward the global cap) this long
constexpr double ELITE_HP = 3.6, ELITE_DAMAGE = 1.5, ELITE_RADIUS = 1.25;

struct EnemyDef {
	std::string id;
	double hp = 1, damage = 1, speed = 1, radius = 0.45;
	double attack_range = 1.3, windup_s = 0.4, cooldown_s = 1.3, scale = 1;
};

struct Enemies {
	// One entry per slot; all vectors have the same length.
	std::vector<int32_t> id, def, level, area, state, last_source;
	std::vector<uint8_t> elite;
	std::vector<float> x, z, yaw;
	std::vector<double> hp, max_hp, damage, speed, radius, attack_cd, state_t, flank_side;
	std::vector<Rng> rng;
	size_t size() const { return id.size(); }
};

struct External {  // a hero or a boss: GDScript writes it every tick
	int32_t id = 0, kind = 0;  // kind 0 hero, 1 boss
	float x = 0, z = 0;
	double radius = 0.4, weight = 1.0;
	bool alive = true;
};

struct World {
	uint64_t seed = 1;
	int32_t next_id = 1;
	double clock = 0;  // seconds of simulated time (tick sum, like today's world.t)
	std::vector<EnemyDef> defs;
	std::unordered_map<std::string, int32_t> def_index;
	std::vector<std::string> areas;
	std::unordered_map<std::string, int32_t> area_index;
	Enemies enemies;
	std::unordered_map<int32_t, int32_t> enemy_slot;  // id -> slot
	std::vector<External> externals;
	Grid grid;
	int32_t grid_count = 0;  // slots the grid was built with; later spawns are scanned directly
	Events events;
	std::vector<int32_t> scratch;

	int32_t area_id(const std::string &p_area);
	int32_t spawn_enemy(int32_t p_def, float p_x, float p_z, int32_t p_level, double p_hp_mult, double p_damage_mult, bool p_elite, int32_t p_area, bool p_rising);
	// Damage from a cast, a boss or a zone: resolves a kill at once (combat map section 7). Returns the amount dealt.
	double damage_enemy(int32_t p_slot, double p_amount, int32_t p_source, bool &r_killed);
	void set_state(int32_t p_slot, int32_t p_state);
	void step(double p_dt);
	// Enemy slots whose edge is within r of (x, z): centre distance minus radius <= r, in spawn order (today's enemies_in_radius).
	void enemies_in_radius(float p_x, float p_z, float p_r, std::vector<int32_t> &out);

private:
	void kill(int32_t p_slot, int32_t p_source);
	void remove_dead_bodies();
};

} // namespace dm
