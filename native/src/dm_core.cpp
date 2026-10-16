#include "dm_core.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

using namespace godot;

namespace {
std::string to_std(const String &p_s) {
	const CharString u = p_s.utf8();
	return std::string(u.get_data(), size_t(u.length()));
}
double num(const Dictionary &p_d, const char *p_key, double p_default) {
	const Variant v = p_d.get(String(p_key), Variant());
	return (v.get_type() == Variant::FLOAT || v.get_type() == Variant::INT) ? double(v) : p_default;
}
} // namespace

void DmCore::_bind_methods() {
	ClassDB::bind_method(D_METHOD("version"), &DmCore::version);
	ClassDB::bind_method(D_METHOD("checksum", "count"), &DmCore::checksum);
	ClassDB::bind_method(D_METHOD("set_seed", "seed"), &DmCore::set_seed);
	ClassDB::bind_method(D_METHOD("load_enemy_defs", "enemies"), &DmCore::load_enemy_defs);
	ClassDB::bind_method(D_METHOD("set_area_bounds", "min", "max"), &DmCore::set_area_bounds);
	ClassDB::bind_method(D_METHOD("spawn_enemy", "def", "pos", "level", "hp_mult", "damage_mult", "elite", "area", "rising"), &DmCore::spawn_enemy);
	ClassDB::bind_method(D_METHOD("damage", "id", "amount", "source"), &DmCore::damage);
	ClassDB::bind_method(D_METHOD("enemies_in_radius", "pos", "r"), &DmCore::enemies_in_radius);
	ClassDB::bind_method(D_METHOD("add_external", "kind", "radius", "weight"), &DmCore::add_external);
	ClassDB::bind_method(D_METHOD("set_external", "id", "pos", "alive"), &DmCore::set_external);
	ClassDB::bind_method(D_METHOD("step", "dt"), &DmCore::step);
	ClassDB::bind_method(D_METHOD("take_events"), &DmCore::take_events);
	ClassDB::bind_method(D_METHOD("enemy_count"), &DmCore::enemy_count);
	ClassDB::bind_method(D_METHOD("enemy_ids"), &DmCore::enemy_ids);
	ClassDB::bind_method(D_METHOD("enemy_positions"), &DmCore::enemy_positions);
	ClassDB::bind_method(D_METHOD("enemy_states"), &DmCore::enemy_states);
	ClassDB::bind_method(D_METHOD("enemy_info", "id"), &DmCore::enemy_info);
	ClassDB::bind_method(D_METHOD("def_name", "def"), &DmCore::def_name);
	ClassDB::bind_method(D_METHOD("area_name", "area"), &DmCore::area_name);
	ClassDB::bind_method(D_METHOD("clock"), &DmCore::clock);
}

String DmCore::version() const {
	return "dmcore 0.2";
}

int64_t DmCore::checksum(int64_t p_count) const {
	int64_t total = 0;
	for (int64_t i = 0; i < p_count; i++) {
		total += i;
	}
	return total;
}

void DmCore::set_seed(int64_t p_seed) {
	world.seed = uint64_t(p_seed);
}

int64_t DmCore::load_enemy_defs(const Dictionary &p_enemies) {
	const Array keys = p_enemies.keys();
	for (int64_t i = 0; i < keys.size(); i++) {
		const Dictionary d = p_enemies[keys[i]];
		dm::EnemyDef def;
		def.id = to_std(String(keys[i]));
		def.hp = num(d, "hp", 1);
		def.damage = num(d, "damage", 1);
		def.speed = num(d, "speed", 1);
		def.radius = num(d, "radius", 0.45);
		def.attack_range = num(d, "attackRange", 1.3);
		def.windup_s = num(d, "windupMs", 400) / 1000.0;
		def.cooldown_s = num(d, "cooldownMs", 1300) / 1000.0;
		def.scale = num(d, "scale", 1);
		auto it = world.def_index.find(def.id);
		if (it != world.def_index.end()) {
			world.defs[it->second] = def;
		} else {
			world.def_index.emplace(def.id, int32_t(world.defs.size()));
			world.defs.push_back(def);
		}
	}
	return int64_t(world.defs.size());
}

void DmCore::set_area_bounds(const Vector2 &p_min, const Vector2 &p_max) {
	world.grid.set_bounds(p_min.x, p_min.y, p_max.x, p_max.y, 4.0f);
}

int64_t DmCore::spawn_enemy(const String &p_def, const Vector2 &p_pos, int64_t p_level, double p_hp_mult, double p_damage_mult, bool p_elite, const String &p_area, bool p_rising) {
	auto it = world.def_index.find(to_std(p_def));
	if (it == world.def_index.end()) {
		UtilityFunctions::push_error("DmCore.spawn_enemy: unknown enemy def ", p_def);
		return 0;
	}
	return world.spawn_enemy(it->second, p_pos.x, p_pos.y, int32_t(p_level), p_hp_mult, p_damage_mult, p_elite, world.area_id(to_std(p_area)), p_rising);
}

Dictionary DmCore::damage(int64_t p_id, double p_amount, int64_t p_source) {
	Dictionary out;
	auto it = world.enemy_slot.find(int32_t(p_id));
	bool killed = false;
	double dealt = 0.0;
	if (it != world.enemy_slot.end()) {
		dealt = world.damage_enemy(it->second, p_amount, int32_t(p_source), killed);
	}
	out["dealt"] = dealt;
	out["killed"] = killed;
	return out;
}

PackedInt32Array DmCore::enemies_in_radius(const Vector2 &p_pos, double p_r) {
	world.enemies_in_radius(p_pos.x, p_pos.y, float(p_r), query_out);
	PackedInt32Array ids;
	ids.resize(int64_t(query_out.size()));
	for (size_t i = 0; i < query_out.size(); i++) {
		ids.set(int64_t(i), world.enemies.id[query_out[i]]);
	}
	return ids;
}

int64_t DmCore::add_external(int64_t p_kind, double p_radius, double p_weight) {
	dm::External x;
	x.id = world.next_id++;
	x.kind = int32_t(p_kind);
	x.radius = p_radius;
	x.weight = p_weight;
	world.externals.push_back(x);
	return x.id;
}

void DmCore::set_external(int64_t p_id, const Vector2 &p_pos, bool p_alive) {
	for (dm::External &x : world.externals) {
		if (x.id == int32_t(p_id)) {
			x.x = p_pos.x;
			x.z = p_pos.y;
			x.alive = p_alive;
			return;
		}
	}
}

void DmCore::step(double p_dt) {
	world.step(p_dt);
}

Array DmCore::take_events() {
	const dm::Events &ev = world.events;
	ev_ints.resize(int64_t(ev.ints.size()));
	if (!ev.ints.empty()) {
		memcpy(ev_ints.ptrw(), ev.ints.data(), ev.ints.size() * sizeof(int32_t));
	}
	ev_floats.resize(int64_t(ev.floats.size()));
	if (!ev.floats.empty()) {
		memcpy(ev_floats.ptrw(), ev.floats.data(), ev.floats.size() * sizeof(float));
	}
	world.events.clear();
	Array out;
	out.push_back(ev_ints);
	out.push_back(ev_floats);
	return out;
}

int64_t DmCore::enemy_count() const {
	return int64_t(world.enemies.size());
}

PackedInt32Array DmCore::enemy_ids() const {
	PackedInt32Array a;
	a.resize(int64_t(world.enemies.size()));
	for (size_t i = 0; i < world.enemies.size(); i++) {
		a.set(int64_t(i), world.enemies.id[i]);
	}
	return a;
}

PackedFloat32Array DmCore::enemy_positions() const {
	const dm::Enemies &e = world.enemies;
	PackedFloat32Array a;
	a.resize(int64_t(e.size()) * 3);
	float *w = a.ptrw();
	for (size_t i = 0; i < e.size(); i++) {
		w[i * 3] = e.x[i];
		w[i * 3 + 1] = e.z[i];
		w[i * 3 + 2] = e.yaw[i];
	}
	return a;
}

PackedInt32Array DmCore::enemy_states() const {
	PackedInt32Array a;
	a.resize(int64_t(world.enemies.size()));
	for (size_t i = 0; i < world.enemies.size(); i++) {
		a.set(int64_t(i), world.enemies.state[i]);
	}
	return a;
}

Dictionary DmCore::enemy_info(int64_t p_id) const {
	Dictionary d;
	auto it = world.enemy_slot.find(int32_t(p_id));
	if (it == world.enemy_slot.end()) {
		return d;
	}
	const dm::Enemies &e = world.enemies;
	const int32_t s = it->second;
	d["id"] = e.id[s];
	d["def"] = String(world.defs[e.def[s]].id.c_str());
	d["level"] = e.level[s];
	d["elite"] = bool(e.elite[s]);
	d["area"] = String(world.areas[e.area[s]].c_str());
	d["state"] = e.state[s];
	d["hp"] = e.hp[s];
	d["max_hp"] = e.max_hp[s];
	d["damage"] = e.damage[s];
	d["speed"] = e.speed[s];
	d["radius"] = e.radius[s];
	d["pos"] = Vector2(e.x[s], e.z[s]);
	return d;
}

String DmCore::def_name(int64_t p_def) const {
	return (p_def >= 0 && p_def < int64_t(world.defs.size())) ? String(world.defs[p_def].id.c_str()) : String();
}

String DmCore::area_name(int64_t p_area) const {
	return (p_area >= 0 && p_area < int64_t(world.areas.size())) ? String(world.areas[p_area].c_str()) : String();
}

double DmCore::clock() const {
	return world.clock;
}
