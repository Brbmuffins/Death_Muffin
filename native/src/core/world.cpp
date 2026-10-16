#include "world.h"

#include <cmath>

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

int32_t World::spawn_enemy(int32_t p_def, float p_x, float p_z, int32_t p_level, double p_hp_mult, double p_damage_mult, bool p_elite, int32_t p_area, bool p_rising) {
	const EnemyDef &d = defs[p_def];
	const int32_t id = next_id++;
	Rng rng;
	rng.seed(seed, uint64_t(id));
	Enemies &e = enemies;
	const int32_t slot = int32_t(e.size());
	e.id.push_back(id);
	e.def.push_back(p_def);
	e.level.push_back(p_level);
	e.area.push_back(p_area);
	e.state.push_back(p_rising ? RISING : IDLE);
	e.last_source.push_back(0);
	e.elite.push_back(p_elite ? 1 : 0);
	e.x.push_back(p_x);
	e.z.push_back(p_z);
	e.yaw.push_back(0.0f);
	// Per-body stats as dm_enemy.gd builds them (combat map section 2).
	const double max_hp = d.hp * p_hp_mult * (p_elite ? ELITE_HP : 1.0);
	e.hp.push_back(max_hp);
	e.max_hp.push_back(max_hp);
	e.damage.push_back(d.damage * p_damage_mult * (p_elite ? ELITE_DAMAGE : 1.0));
	e.speed.push_back(d.speed * (0.92 + rng.next_double() * 0.16));
	e.radius.push_back(d.radius * (p_elite ? ELITE_RADIUS : 1.0));
	e.attack_cd.push_back(0.5 + rng.next_double());
	e.flank_side.push_back(rng.next_double() < 0.5 ? -1.0 : 1.0);
	e.state_t.push_back(0.0);
	e.rng.push_back(rng);
	enemy_slot[id] = slot;
	events.push(EV_ENEMY_SPAWNED, id, { p_def, p_level, p_elite ? 1 : 0, p_area }, { p_x, p_z, float(max_hp) });
	return id;
}

void World::set_state(int32_t p_slot, int32_t p_state) {
	const int32_t prev = enemies.state[p_slot];
	if (prev == p_state) {
		return;
	}
	enemies.state[p_slot] = p_state;
	enemies.state_t[p_slot] = 0.0;
	events.push(EV_ENEMY_STATE, enemies.id[p_slot], { prev, p_state }, {});
}

double World::damage_enemy(int32_t p_slot, double p_amount, int32_t p_source, bool &r_killed) {
	r_killed = false;
	Enemies &e = enemies;
	const int32_t st = e.state[p_slot];
	if (st == DEAD || st == RISING || p_amount <= 0.0) {  // refused like today's take_damage (burrow and erupt join with the ghoul)
		return 0.0;
	}
	e.hp[p_slot] -= p_amount;
	e.last_source[p_slot] = p_source;
	events.push(EV_ENEMY_DAMAGED, e.id[p_slot], { p_source }, { float(p_amount), float(std::max(0.0, e.hp[p_slot])) });
	if (e.hp[p_slot] <= 0.0) {
		kill(p_slot, p_source);
		r_killed = true;
	}
	return p_amount;
}

void World::kill(int32_t p_slot, int32_t p_source) {
	Enemies &e = enemies;
	e.hp[p_slot] = 0.0;
	set_state(p_slot, DEAD);
	events.push(EV_ENEMY_DIED, e.id[p_slot], { e.def[p_slot], e.level[p_slot], int32_t(e.elite[p_slot]), e.area[p_slot], p_source }, { e.x[p_slot], e.z[p_slot] });
}

void World::step(double p_dt) {
	clock += p_dt;
	Enemies &e = enemies;
	const int32_t n = int32_t(e.size());
	for (int32_t i = 0; i < n; i++) {
		e.state_t[i] += p_dt;  // accumulate in doubles like today's timers (combat map section 12)
		if (e.state[i] == RISING && e.state_t[i] >= RISE_S) {
			set_state(i, IDLE);
		}
	}
	remove_dead_bodies();
	grid_count = int32_t(e.size());
	grid.rebuild(e.x.data(), e.z.data(), grid_count);
}

void World::remove_dead_bodies() {
	Enemies &e = enemies;
	const int32_t n = int32_t(e.size());
	int32_t w = 0;
	for (int32_t r = 0; r < n; r++) {
		if (e.state[r] == DEAD && e.state_t[r] >= BODY_LINGER_S) {
			events.push(EV_ENEMY_REMOVED, e.id[r], {}, {});
			enemy_slot.erase(e.id[r]);
			continue;
		}
		if (w != r) {  // stable compaction keeps spawn order
			e.id[w] = e.id[r];
			e.def[w] = e.def[r];
			e.level[w] = e.level[r];
			e.area[w] = e.area[r];
			e.state[w] = e.state[r];
			e.last_source[w] = e.last_source[r];
			e.elite[w] = e.elite[r];
			e.x[w] = e.x[r];
			e.z[w] = e.z[r];
			e.yaw[w] = e.yaw[r];
			e.hp[w] = e.hp[r];
			e.max_hp[w] = e.max_hp[r];
			e.damage[w] = e.damage[r];
			e.speed[w] = e.speed[r];
			e.radius[w] = e.radius[r];
			e.attack_cd[w] = e.attack_cd[r];
			e.state_t[w] = e.state_t[r];
			e.flank_side[w] = e.flank_side[r];
			e.rng[w] = e.rng[r];
			enemy_slot[e.id[w]] = w;
		}
		w++;
	}
	if (w != n) {
		e.id.resize(w); e.def.resize(w); e.level.resize(w); e.area.resize(w); e.state.resize(w); e.last_source.resize(w);
		e.elite.resize(w); e.x.resize(w); e.z.resize(w); e.yaw.resize(w); e.hp.resize(w); e.max_hp.resize(w); e.damage.resize(w);
		e.speed.resize(w); e.radius.resize(w); e.attack_cd.resize(w); e.state_t.resize(w); e.flank_side.resize(w); e.rng.resize(w);
	}
}

void World::enemies_in_radius(float p_x, float p_z, float p_r, std::vector<int32_t> &out) {
	// The grid holds positions from the last step; candidates are padded by the largest radius, then tested exactly.
	double pad = 0.0;
	for (double r : enemies.radius) {
		pad = r > pad ? r : pad;
	}
	grid.query(p_x, p_z, float(p_r + pad), scratch);
	for (int32_t s = grid_count; s < int32_t(enemies.size()); s++) {  // spawned since the last step: not in the grid yet
		scratch.push_back(s);
	}
	out.clear();
	for (int32_t s : scratch) {
		if (s >= int32_t(enemies.size()) || enemies.hp[s] <= 0.0) {  // alive = hp > 0, so RISING bodies count (today's alive_enemy)
			continue;
		}
		const double dx = double(enemies.x[s]) - p_x, dz = double(enemies.z[s]) - p_z;
		if (std::sqrt(dx * dx + dz * dz) - enemies.radius[s] <= p_r) {
			out.push_back(s);
		}
	}
}

} // namespace dm
