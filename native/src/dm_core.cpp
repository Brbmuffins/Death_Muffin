#include "dm_core.h"

#include <godot_cpp/classes/navigation_server3d.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/vector3.hpp>
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
String str(const Dictionary &p_d, const char *p_key, const char *p_default) {
	const Variant v = p_d.get(String(p_key), Variant());
	return v.get_type() == Variant::STRING ? String(v) : String(p_default);
}
int32_t nav_path(void *p_user, float p_fx, float p_fz, float p_tx, float p_tz, float *r_xz, int32_t p_max) {
	const RID map = *static_cast<RID *>(p_user);
	const PackedVector3Array p = NavigationServer3D::get_singleton()->map_get_path(map, Vector3(p_fx, 0, p_fz), Vector3(p_tx, 0, p_tz), true);
	const int32_t n = std::min(int32_t(p.size()), p_max);
	for (int32_t i = 0; i < n; i++) {
		r_xz[i * 2] = p[i].x;
		r_xz[i * 2 + 1] = p[i].z;
	}
	return n;
}
void nav_clamp(void *p_user, float &r_x, float &r_z) {
	const RID map = *static_cast<RID *>(p_user);
	const Vector3 q = NavigationServer3D::get_singleton()->map_get_closest_point(map, Vector3(r_x, 0, r_z));
	r_x = q.x;
	r_z = q.z;
}
} // namespace

void DmCore::_bind_methods() {
	ClassDB::bind_method(D_METHOD("version"), &DmCore::version);
	ClassDB::bind_method(D_METHOD("checksum", "count"), &DmCore::checksum);
	ClassDB::bind_method(D_METHOD("set_seed", "seed"), &DmCore::set_seed);
	ClassDB::bind_method(D_METHOD("set_wander", "on"), &DmCore::set_wander);
	ClassDB::bind_method(D_METHOD("load_enemy_defs", "enemies"), &DmCore::load_enemy_defs);
	ClassDB::bind_method(D_METHOD("load_tuning", "content"), &DmCore::load_tuning);
	ClassDB::bind_method(D_METHOD("set_nav_map", "map"), &DmCore::set_nav_map);
	ClassDB::bind_method(D_METHOD("set_area_bounds", "min", "max"), &DmCore::set_area_bounds);
	ClassDB::bind_method(D_METHOD("spawn_enemy", "def", "pos", "level", "hp_mult", "damage_mult", "elite", "area", "rising"), &DmCore::spawn_enemy);
	ClassDB::bind_method(D_METHOD("damage", "id", "amount", "source", "allow_stagger"), &DmCore::damage, DEFVAL(true));
	ClassDB::bind_method(D_METHOD("stun", "id", "seconds"), &DmCore::stun);
	ClassDB::bind_method(D_METHOD("enemies_in_radius", "pos", "r"), &DmCore::enemies_in_radius);
	ClassDB::bind_method(D_METHOD("add_external", "kind", "radius", "weight"), &DmCore::add_external);
	ClassDB::bind_method(D_METHOD("set_external", "id", "pos", "alive"), &DmCore::set_external);
	ClassDB::bind_method(D_METHOD("step", "dt"), &DmCore::step);
	ClassDB::bind_method(D_METHOD("take_events"), &DmCore::take_events);
	ClassDB::bind_method(D_METHOD("enemy_count"), &DmCore::enemy_count);
	ClassDB::bind_method(D_METHOD("enemy_ids"), &DmCore::enemy_ids);
	ClassDB::bind_method(D_METHOD("enemy_positions"), &DmCore::enemy_positions);
	ClassDB::bind_method(D_METHOD("enemy_states"), &DmCore::enemy_states);
	ClassDB::bind_method(D_METHOD("enemy_ground_speeds"), &DmCore::enemy_ground_speeds);
	ClassDB::bind_method(D_METHOD("enemy_info", "id"), &DmCore::enemy_info);
	ClassDB::bind_method(D_METHOD("def_name", "def"), &DmCore::def_name);
	ClassDB::bind_method(D_METHOD("area_name", "area"), &DmCore::area_name);
	ClassDB::bind_method(D_METHOD("clock"), &DmCore::clock);
}

String DmCore::version() const {
	return "dmcore 0.3";
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

void DmCore::set_wander(bool p_on) {
	world.wander_enabled = p_on;
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
		def.hit_run = num(d, "hitRun", 0);
		def.flying = num(d, "flying", 0);
		def.slam_r = num(d, "slamRadius", dm::DEFAULT_SLAM_R);
		def.burrow = bool(d.get("burrow", false));
		def.hit_kind = bool(d.get("rotBite", false)) ? dm::HK_TOXIC : dm::HK_MELEE;
		const String behavior = str(d, "behavior", "melee");
		const String attack = str(d, "attack", "cone");
		if (behavior == "flank") {
			def.behavior = dm::B_FLANK;
		} else if (behavior == "caster") {
			def.behavior = dm::B_CASTER;
			def.blow = attack == "dust" ? dm::BLOW_DUST : dm::BLOW_CONE;
		} else if (behavior == "hazard") {
			def.behavior = dm::B_HAZARD;
			def.blow = dm::BLOW_SLAM;
		}
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

void DmCore::load_tuning(const Dictionary &p_content) {
	dm::Tuning &u = world.tun;
	const Dictionary el = p_content.get("ELITE", Dictionary());
	u.elite_hp = num(el, "hpMult", u.elite_hp);
	u.elite_damage = num(el, "damageMult", u.elite_damage);
	const Dictionary du = p_content.get("DUST", Dictionary());
	u.dust_radius = num(du, "radius", u.dust_radius);
	u.dust_cloud_s = num(du, "cloudS", u.dust_cloud_s);
	u.dust_cloud_dps = num(du, "cloudDpsMult", u.dust_cloud_dps);
	const Dictionary b = p_content.get("BURROW", Dictionary());
	u.burrow_speed = num(b, "speed", u.burrow_speed);
	u.burrow_surface_r = num(b, "surfaceR", u.burrow_surface_r);
	u.burrow_erupt_r = num(b, "eruptR", u.burrow_erupt_r);
	u.burrow_erupt_mult = num(b, "eruptMult", u.burrow_erupt_mult);
	u.burrow_erupt_mult_graves = num(b, "eruptMultGraves", u.burrow_erupt_mult_graves);
	u.burrow_erupt_s_graves = num(b, "eruptMsGraves", u.burrow_erupt_s_graves * 1000.0) / 1000.0;
	u.burrow_erupt_s = num(b, "eruptMs", u.burrow_erupt_s * 1000.0) / 1000.0;
	u.burrow_dig_s = num(b, "digS", u.burrow_dig_s);
	u.burrow_dig_at = num(b, "digAtFrac", u.burrow_dig_at);
	u.burrow_travel = num(b, "travelM", u.burrow_travel);
	u.burrow_max_per_target = int32_t(num(b, "maxPerTarget", u.burrow_max_per_target));
}

void DmCore::set_nav_map(const RID &p_map) {
	nav_map = p_map;
	world.nav.user = &nav_map;
	world.nav.path = p_map.is_valid() ? nav_path : nullptr;
	world.nav.clamp = p_map.is_valid() ? nav_clamp : nullptr;
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

Dictionary DmCore::damage(int64_t p_id, double p_amount, int64_t p_source, bool p_allow_stagger) {
	Dictionary out;
	auto it = world.enemy_slot.find(int32_t(p_id));
	bool killed = false;
	double dealt = 0.0;
	if (it != world.enemy_slot.end()) {
		dealt = world.damage_enemy(it->second, p_amount, int32_t(p_source), p_allow_stagger, killed);
	}
	out["dealt"] = dealt;
	out["killed"] = killed;
	return out;
}

void DmCore::stun(int64_t p_id, double p_seconds) {
	auto it = world.enemy_slot.find(int32_t(p_id));
	if (it != world.enemy_slot.end()) {
		world.stun(it->second, p_seconds);
	}
}

PackedInt32Array DmCore::enemies_in_radius(const Vector2 &p_pos, double p_r) {
	world.enemies_in_radius(p_pos.x, p_pos.y, float(p_r), query_out);
	PackedInt32Array ids;
	ids.resize(int64_t(query_out.size()));
	for (size_t i = 0; i < query_out.size(); i++) {
		ids.set(int64_t(i), world.enemies[query_out[i]].id);
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
		a.set(int64_t(i), world.enemies[i].id);
	}
	return a;
}

PackedFloat32Array DmCore::enemy_positions() const {
	const std::vector<dm::Enemy> &e = world.enemies;
	PackedFloat32Array a;
	a.resize(int64_t(e.size()) * 3);
	float *w = a.ptrw();
	for (size_t i = 0; i < e.size(); i++) {
		w[i * 3] = e[i].x;
		w[i * 3 + 1] = e[i].z;
		w[i * 3 + 2] = e[i].yaw;
	}
	return a;
}

PackedInt32Array DmCore::enemy_states() const {
	PackedInt32Array a;
	a.resize(int64_t(world.enemies.size()));
	for (size_t i = 0; i < world.enemies.size(); i++) {
		a.set(int64_t(i), world.enemies[i].state);
	}
	return a;
}

PackedFloat32Array DmCore::enemy_ground_speeds() const {
	PackedFloat32Array a;
	a.resize(int64_t(world.enemies.size()));
	for (size_t i = 0; i < world.enemies.size(); i++) {
		a.set(int64_t(i), float(world.enemies[i].ground_speed));
	}
	return a;
}

Dictionary DmCore::enemy_info(int64_t p_id) const {
	Dictionary d;
	auto it = world.enemy_slot.find(int32_t(p_id));
	if (it == world.enemy_slot.end()) {
		return d;
	}
	const dm::Enemy &e = world.enemies[it->second];
	d["id"] = e.id;
	d["def"] = String(world.defs[e.def].id.c_str());
	d["level"] = e.level;
	d["elite"] = e.elite;
	d["area"] = String(world.areas[e.area].c_str());
	d["state"] = e.state;
	d["target"] = e.target;
	d["hp"] = e.hp;
	d["max_hp"] = e.max_hp;
	d["damage"] = e.damage;
	d["speed"] = e.speed;
	d["radius"] = e.radius;
	d["attack_cd"] = e.attack_cd;
	d["windup_s"] = e.windup_s;
	d["pos"] = Vector2(e.x, e.z);
	d["aim"] = Vector2(e.aim_x, e.aim_z);
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
