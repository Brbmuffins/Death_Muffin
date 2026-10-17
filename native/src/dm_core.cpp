#include "dm_core.h"

#include <algorithm>
#include <cmath>
#include <cstring>

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

bool DmCore::refused(const char *p_command) {
	if (!world.puppet) {
		return false;
	}
	world.rep.commands_refused++;
	const std::string name(p_command);
	if (std::find(refused_logged.begin(), refused_logged.end(), name) == refused_logged.end()) {  // once per command, so a loop that keeps calling it does not flood the log
		refused_logged.push_back(name);
		UtilityFunctions::push_error("DmCore.", p_command, ": refused on a puppet core (the host owns the simulation; a guest only shows it)");
	}
	return true;
}

void DmCore::_bind_methods() {
	ClassDB::bind_method(D_METHOD("version"), &DmCore::version);
	ClassDB::bind_method(D_METHOD("checksum", "count"), &DmCore::checksum);
	ClassDB::bind_method(D_METHOD("set_seed", "seed"), &DmCore::set_seed);
	ClassDB::bind_method(D_METHOD("set_wander", "on"), &DmCore::set_wander);
	ClassDB::bind_method(D_METHOD("load_enemy_defs", "enemies"), &DmCore::load_enemy_defs);
	ClassDB::bind_method(D_METHOD("load_tuning", "content"), &DmCore::load_tuning);
	ClassDB::bind_method(D_METHOD("load_status_defs", "rules"), &DmCore::load_status_defs);
	ClassDB::bind_method(D_METHOD("load_legion_tuning", "files"), &DmCore::load_legion_tuning);
	ClassDB::bind_method(D_METHOD("load_sim_consts", "consts"), &DmCore::load_sim_consts);
	ClassDB::bind_method(D_METHOD("tuning"), &DmCore::tuning);
	ClassDB::bind_method(D_METHOD("set_nav_map", "map"), &DmCore::set_nav_map);
	ClassDB::bind_method(D_METHOD("set_area_bounds", "min", "max"), &DmCore::set_area_bounds);
	ClassDB::bind_method(D_METHOD("nav_add_region", "vertices", "polygons", "enabled"), &DmCore::nav_add_region);
	ClassDB::bind_method(D_METHOD("nav_set_region_enabled", "region", "enabled"), &DmCore::nav_set_region_enabled);
	ClassDB::bind_method(D_METHOD("nav_replace_region", "region", "vertices", "polygons", "enabled"), &DmCore::nav_replace_region);
	ClassDB::bind_method(D_METHOD("nav_clear_regions"), &DmCore::nav_clear_regions);
	ClassDB::bind_method(D_METHOD("nav_closest", "point"), &DmCore::nav_closest);
	ClassDB::bind_method(D_METHOD("nav_triangle_count"), &DmCore::nav_triangle_count);
	ClassDB::bind_method(D_METHOD("spawn_enemy", "def", "pos", "level", "hp_mult", "damage_mult", "elite", "area", "rising", "affixes"), &DmCore::spawn_enemy, DEFVAL(PackedStringArray()));
	ClassDB::bind_method(D_METHOD("strip_shroud", "id"), &DmCore::strip_shroud);
	ClassDB::bind_method(D_METHOD("cover_miasma", "id"), &DmCore::cover_miasma);
	ClassDB::bind_method(D_METHOD("add_obstacle", "a", "b", "thickness"), &DmCore::add_obstacle);
	ClassDB::bind_method(D_METHOD("remove_obstacle", "id"), &DmCore::remove_obstacle);
	ClassDB::bind_method(D_METHOD("damage", "id", "amount", "source", "allow_stagger"), &DmCore::damage, DEFVAL(true));
	ClassDB::bind_method(D_METHOD("set_enemy_aggro", "id", "aggro", "leash"), &DmCore::set_enemy_aggro);
	ClassDB::bind_method(D_METHOD("remove_enemy", "id"), &DmCore::remove_enemy);
	ClassDB::bind_method(D_METHOD("set_enemy_hp", "id", "hp", "max_hp"), &DmCore::set_enemy_hp);
	ClassDB::bind_method(D_METHOD("add_zone", "kind", "pos", "radius", "seconds", "dps", "source"), &DmCore::add_zone);
	ClassDB::bind_method(D_METHOD("zones", "kind"), &DmCore::zones);
	ClassDB::bind_method(D_METHOD("stun", "id", "seconds"), &DmCore::stun);
	ClassDB::bind_method(D_METHOD("apply_status", "id", "status", "source", "stacks", "duration", "params"), &DmCore::apply_status, DEFVAL(1.0), DEFVAL(-1.0), DEFVAL(Dictionary()));
	ClassDB::bind_method(D_METHOD("remove_status", "id", "status"), &DmCore::remove_status);
	ClassDB::bind_method(D_METHOD("statuses", "id"), &DmCore::statuses);
	ClassDB::bind_method(D_METHOD("status_stacks", "id", "status"), &DmCore::status_stacks);
	ClassDB::bind_method(D_METHOD("damage_dealt_mult", "id"), &DmCore::damage_dealt_mult);
	ClassDB::bind_method(D_METHOD("enemies_in_radius", "pos", "r"), &DmCore::enemies_in_radius);
	ClassDB::bind_method(D_METHOD("add_external", "kind", "radius", "weight"), &DmCore::add_external);
	ClassDB::bind_method(D_METHOD("set_external", "id", "pos", "alive"), &DmCore::set_external);
	ClassDB::bind_method(D_METHOD("remove_external", "id"), &DmCore::remove_external);
	ClassDB::bind_method(D_METHOD("raise_thrall", "stats", "owner", "pos", "yaw", "cap"), &DmCore::raise_thrall, DEFVAL(-1.0));
	ClassDB::bind_method(D_METHOD("last_crumbled"), &DmCore::last_crumbled);
	ClassDB::bind_method(D_METHOD("kill_thrall", "id", "reason"), &DmCore::kill_thrall);
	ClassDB::bind_method(D_METHOD("sacrifice_thralls", "owner", "n"), &DmCore::sacrifice_thralls, DEFVAL(-1));
	ClassDB::bind_method(D_METHOD("rally_thralls", "owner", "seconds", "focus"), &DmCore::rally_thralls, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("recall_thralls", "owner"), &DmCore::recall_thralls);
	ClassDB::bind_method(D_METHOD("set_legion_burst", "owner", "fraction"), &DmCore::set_legion_burst);
	ClassDB::bind_method(D_METHOD("set_thrall_target", "id", "target"), &DmCore::set_thrall_target);
	ClassDB::bind_method(D_METHOD("set_thrall_mark", "id", "mult"), &DmCore::set_thrall_mark);
	ClassDB::bind_method(D_METHOD("curse_thrall", "id", "seconds"), &DmCore::curse_thrall);
	ClassDB::bind_method(D_METHOD("set_thrall_pos", "id", "pos"), &DmCore::set_thrall_pos);
	ClassDB::bind_method(D_METHOD("set_thrall_stats", "id", "stats"), &DmCore::set_thrall_stats);
	ClassDB::bind_method(D_METHOD("thralls_in_radius", "pos", "r", "owner"), &DmCore::thralls_in_radius, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("thrall_count", "owner"), &DmCore::thrall_count, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("thrall_places", "owner"), &DmCore::thrall_places, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("set_corpse_life_mult", "mult"), &DmCore::set_corpse_life_mult);
	ClassDB::bind_method(D_METHOD("set_area_level", "area", "level"), &DmCore::set_area_level);
	ClassDB::bind_method(D_METHOD("corpse_add", "pos", "kind", "enemy", "elite", "facing", "scale", "area"), &DmCore::corpse_add);
	ClassDB::bind_method(D_METHOD("corpses_in_radius", "pos", "r", "area"), &DmCore::corpses_in_radius, DEFVAL(String()));
	ClassDB::bind_method(D_METHOD("corpse_pick", "aim", "pick_r", "max_range", "from", "area"), &DmCore::corpse_pick, DEFVAL(String()));
	ClassDB::bind_method(D_METHOD("corpse_consume", "id", "by", "reason"), &DmCore::corpse_consume, DEFVAL("consumed"));
	ClassDB::bind_method(D_METHOD("corpse_count"), &DmCore::corpse_count);
	ClassDB::bind_method(D_METHOD("corpse_ids"), &DmCore::corpse_ids);
	ClassDB::bind_method(D_METHOD("corpse_positions"), &DmCore::corpse_positions);
	ClassDB::bind_method(D_METHOD("corpse_info", "id"), &DmCore::corpse_info);
	ClassDB::bind_method(D_METHOD("reason_name", "reason"), &DmCore::reason_name);
	ClassDB::bind_method(D_METHOD("set_puppet", "on"), &DmCore::set_puppet);
	ClassDB::bind_method(D_METHOD("is_puppet"), &DmCore::is_puppet);
	ClassDB::bind_method(D_METHOD("set_replication", "on"), &DmCore::set_replication);
	ClassDB::bind_method(D_METHOD("snapshot", "tick"), &DmCore::snapshot);
	ClassDB::bind_method(D_METHOD("snapshot_parts", "tick", "max_bytes"), &DmCore::snapshot_parts);
	ClassDB::bind_method(D_METHOD("take_reliable"), &DmCore::take_reliable);
	ClassDB::bind_method(D_METHOD("baseline"), &DmCore::baseline);
	ClassDB::bind_method(D_METHOD("apply_snapshot", "bytes"), &DmCore::apply_snapshot);
	ClassDB::bind_method(D_METHOD("apply_reliable", "bytes"), &DmCore::apply_reliable);
	ClassDB::bind_method(D_METHOD("replication_error"), &DmCore::replication_error);
	ClassDB::bind_method(D_METHOD("replication_stats"), &DmCore::replication_stats);
	ClassDB::bind_static_method("DmCore", D_METHOD("wire_version"), &DmCore::wire_version);
	ClassDB::bind_method(D_METHOD("step", "dt"), &DmCore::step);
	ClassDB::bind_method(D_METHOD("take_events"), &DmCore::take_events);
	ClassDB::bind_method(D_METHOD("enemy_count"), &DmCore::enemy_count);
	ClassDB::bind_method(D_METHOD("enemy_ids"), &DmCore::enemy_ids);
	ClassDB::bind_method(D_METHOD("enemy_rows"), &DmCore::enemy_rows);
	ClassDB::bind_method(D_METHOD("enemy_positions"), &DmCore::enemy_positions);
	ClassDB::bind_method(D_METHOD("enemy_states"), &DmCore::enemy_states);
	ClassDB::bind_method(D_METHOD("enemy_ground_speeds"), &DmCore::enemy_ground_speeds);
	ClassDB::bind_method(D_METHOD("enemy_info", "id"), &DmCore::enemy_info);
	ClassDB::bind_method(D_METHOD("unbind_info", "id"), &DmCore::unbind_info);
	ClassDB::bind_method(D_METHOD("thrall_total"), &DmCore::thrall_total);
	ClassDB::bind_method(D_METHOD("thrall_ids"), &DmCore::thrall_ids);
	ClassDB::bind_method(D_METHOD("thrall_positions"), &DmCore::thrall_positions);
	ClassDB::bind_method(D_METHOD("thrall_states"), &DmCore::thrall_states);
	ClassDB::bind_method(D_METHOD("thrall_kinds"), &DmCore::thrall_kinds);
	ClassDB::bind_method(D_METHOD("thrall_swings"), &DmCore::thrall_swings);
	ClassDB::bind_method(D_METHOD("thrall_owners"), &DmCore::thrall_owners);
	ClassDB::bind_method(D_METHOD("thrall_hp"), &DmCore::thrall_hp);
	ClassDB::bind_method(D_METHOD("thrall_ground_speeds"), &DmCore::thrall_ground_speeds);
	ClassDB::bind_method(D_METHOD("thrall_info", "id"), &DmCore::thrall_info);
	ClassDB::bind_method(D_METHOD("thrall_kind_name", "kind"), &DmCore::thrall_kind_name);
	ClassDB::bind_method(D_METHOD("death_reason_name", "reason"), &DmCore::death_reason_name);
	ClassDB::bind_method(D_METHOD("affix_moment_name", "kind"), &DmCore::affix_moment_name);
	ClassDB::bind_method(D_METHOD("def_name", "def"), &DmCore::def_name);
	ClassDB::bind_method(D_METHOD("area_name", "area"), &DmCore::area_name);
	ClassDB::bind_method(D_METHOD("clock"), &DmCore::clock);
}

String DmCore::version() const {
	return "dmcore 0.14";
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
		def.frenzy = bool(d.get("frenzy", false));
		def.hit_kind = bool(d.get("rotBite", false)) ? dm::HK_TOXIC : dm::HK_MELEE;
		def.death_corpses = int32_t(num(d, "deathCorpses", 1));
		const String corpse = str(d, "corpse", "normal");
		for (int32_t k = 0; k < 5; k++) {
			if (corpse == String(dm::CORPSE_KIND_NAMES[k])) {
				def.corpse = k;
			}
		}
		const String behavior = str(d, "behavior", "melee");
		const String attack = str(d, "attack", "cone");
		if (behavior == "flank") {
			def.behavior = dm::B_FLANK;
		} else if (behavior == "caster") {
			def.behavior = dm::B_CASTER;
			def.blow = attack == "dust" ? dm::BLOW_DUST : (attack == "curse" ? dm::BLOW_CURSE : (attack == "scream" ? dm::BLOW_SCREAM : (attack == "flask" ? dm::BLOW_FLASK : dm::BLOW_CONE)));
			def.silence_aware = attack == "curse" || attack == "flask";  // the cloister casters (DmEnemyClstCaster) walk with dm_state_clst_kite: a silenced one never starts a cast
		} else if (behavior == "hazard") {
			def.behavior = dm::B_HAZARD;
			def.blow = dm::BLOW_SLAM;
		} else if (behavior == "support" && !bool(d.get("inert", false))) {
			def.behavior = dm::B_SUPPORT;  // the Crypt Deacon: its curse is the plain blow (melee), its raise and Sanctify are the support scan. The Niche (inert) never reaches the brain (niche.cpp).
			def.ward = bool(d.get("ward", false));  // the Weeping Seraph keeps the Deacon's distance (dm_state_clst_kite.gd [0, 0.5, 4, 0.7] = dm_state_cath_support.gd), casts the curse and blesses allies (its ward, cloister.cpp)
			if (def.ward) {
				def.blow = dm::BLOW_CURSE;
			}
		}
		def.inert = bool(d.get("inert", false));    // the Skull Niche
		def.aura = bool(d.get("aura", false));      // the Censer Bearer's incense
		def.shield = bool(d.get("shield", false));  // the Bell-Sworn Templar's shield
		def.unbind = bool(d.get("unbind", false));  // the Lich Acolyte's Unbind
		if (d.has("dive")) {                        // the Belfry Gargoyle's dive
			const Dictionary dv = d["dive"];
			def.has_dive = true;
			def.dive_min = num(dv, "minRange", def.dive_min);
			def.dive_range = num(dv, "range", def.dive_range);
			def.dive_r = num(dv, "radius", def.dive_r);
			def.dive_grounded_s = num(dv, "groundedS", def.dive_grounded_s);
		}
		def.pf.ember_death = bool(d.get("emberDeath", false));  // the Cinder Pyre's and the Mourning Fen's kinds: the Husk's last embers,
		def.pf.slam_pool = bool(d.get("slamPool", false));      // the Slag Brute's burning slam, the Drowned Sexton's chain and the Fen Wisp's retreat to the water
		def.pf.hook = bool(d.get("hook", false));
		def.pf.lure = bool(d.get("lure", false));
		if (def.behavior == dm::B_CASTER) {                     // the Pyre Priest's coal, the Bog Hag's hex and the Fen Wisp's pulse are the caster's `attack`
			def.blow = attack == "ember" ? dm::BLOW_EMBER : (attack == "hex" ? dm::BLOW_HEX : (attack == "pulse" ? dm::BLOW_PULSE : def.blow));
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
	u.elite_scale = num(el, "scale", u.elite_scale);
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
	const Dictionary fr = p_content.get("FRENZY", Dictionary());
	u.frenzy_at = num(fr, "atFrac", u.frenzy_at);
	const Dictionary ce = p_content.get("CENSER", Dictionary());
	u.censer_r = num(ce, "radius", u.censer_r);
	u.censer_haste_s = num(ce, "hasteS", u.censer_haste_s);
	u.scream_r = num(Dictionary(p_content.get("SCREAM", Dictionary())), "radius", u.scream_r);
	const Dictionary ts = p_content.get("TEMPLAR_SHIELD", Dictionary());
	u.shield_arc_deg = num(ts, "halfArcDeg", u.shield_arc_deg);
	u.shield_cos = std::cos(u.shield_arc_deg * dm::PI / 180.0);  // _ready: cos(deg_to_rad(halfArcDeg))
	u.shield_pass = num(ts, "passThrough", u.shield_pass);
	const Dictionary ub = p_content.get("UNBIND", Dictionary());
	u.unbind_range = num(ub, "range", u.unbind_range);
	u.unbind_delay_s = num(ub, "delayS", u.unbind_delay_s);
	u.unbind_cooldown_s = num(ub, "cooldownS", u.unbind_cooldown_s);
	u.unbind_max = int32_t(num(ub, "maxAlive", u.unbind_max));
	const Dictionary wd = p_content.get("WARD", Dictionary());
	u.ward_range = num(wd, "range", u.ward_range);
	u.ward_max = int32_t(num(wd, "maxTargets", u.ward_max));
	const Dictionary pfl = p_content.get("PLAGUE_FLASK", Dictionary());
	u.flask_r = num(pfl, "radius", u.flask_r);
	u.flask_pool_s = num(pfl, "poolS", u.flask_pool_s);
	u.flask_pool_dps = num(pfl, "poolDpsMult", u.flask_pool_dps);
	dm::PfTuning &pf = u.pf;  // EMBER_BOLT, EMBER_DEATH, SLAG_POOL: the Pyre's burning ground
	const Dictionary eb = p_content.get("EMBER_BOLT", Dictionary());
	pf.ember_r = num(eb, "radius", pf.ember_r);
	pf.ember_pool_s = num(eb, "poolS", pf.ember_pool_s);
	pf.ember_pool_dps = num(eb, "poolDpsMult", pf.ember_pool_dps);
	const Dictionary ed = p_content.get("EMBER_DEATH", Dictionary());
	pf.death_r = num(ed, "radius", pf.death_r);
	pf.death_pool_s = num(ed, "poolS", pf.death_pool_s);
	pf.death_pool_dps = num(ed, "poolDpsMult", pf.death_pool_dps);
	const Dictionary sp = p_content.get("SLAG_POOL", Dictionary());
	pf.slag_pool_s = num(sp, "poolS", pf.slag_pool_s);
	pf.slag_pool_dps = num(sp, "poolDpsMult", pf.slag_pool_dps);
	const Dictionary af = p_content.get("AFFIX_TUNING", Dictionary());
	const Dictionary bell = af.get("bellTolled", Dictionary());
	u.bell_interval = num(bell, "intervalS", u.bell_interval);
	u.bell_windup = num(bell, "windupS", u.bell_windup);
	u.bell_r = num(bell, "r", u.bell_r);
	u.bell_damage = num(bell, "damageMult", u.bell_damage);
	const Dictionary hun = af.get("hungering", Dictionary());
	u.hunger_interval = num(hun, "intervalS", u.hunger_interval);
	u.hunger_reach = num(hun, "reach", u.hunger_reach);
	u.hunger_heal = num(hun, "healFrac", u.hunger_heal);
	const Dictionary ven = af.get("vengeful", Dictionary());
	u.vengeful_risen = int32_t(num(ven, "risen", u.vengeful_risen));
	const Array order = p_content.get("AFFIX_ORDER", Array());  // the bits of Enemy::affixes follow it
	for (int32_t k = 0; k < order.size() && k < dm::AF_COUNT; k++) {
		if (String(order[k]) != String(dm::AFFIX_NAMES[k])) {
			UtilityFunctions::push_error("DmCore.load_tuning: AFFIX_ORDER changed: ", order[k], " at ", k);
		}
	}
}

int64_t DmCore::load_status_defs(const Array &p_rules) {
	world.status_rules.clear();
	for (int64_t i = 0; i < p_rules.size(); i++) {
		const Dictionary d = p_rules[i];
		dm::StatusRule r;
		r.name = to_std(str(d, "name", ""));
		r.dur = num(d, "dur", 0);
		r.move = num(d, "move", 1);
		r.atk = num(d, "atk", 1);
		r.taken = num(d, "taken", 1);
		r.dealt = num(d, "dealt", 1);
		r.tps = num(d, "tps", 0);
		r.max = num(d, "max", 1.0e6);
		r.slow = d.has("slow");
		r.root = d.has("root");
		r.dot = d.has("dot");
		r.stack = d.has("stack");
		r.bleed = d.has("bleed");
		r.barrier = d.has("barrier");
		world.status_rules.push_back(r);
	}
	world.st_stun = world.status_id("stun");
	world.st_frenzy = world.status_id("frenzy");
	world.st_withered = world.status_id("withered");
	world.st_chill = world.status_id("chill");
	world.st_hex = world.status_id("hex");
	world.st_barrier = world.status_id("barrier");
	world.st_shrouded = world.status_id("shrouded");
	world.st_silence = world.status_id("silence");
	world.st_sanctified = world.status_id("sanctified");
	world.st_incensed = world.status_id("incensed");
	world.st_fracture = world.status_id("fracture");
	world.st_cleared.clear();
	for (const char *n : { "bleed", "wraithfire", "withered", "root", "slow", "chill" }) {  // DmStatusSet.CLEARED
		const int32_t id = world.status_id(n);
		if (id >= 0) {
			world.st_cleared.push_back(id);
		}
	}
	return int64_t(world.status_rules.size());
}

// DmThralls / DmThrall / DmCorpseField read these from content files and GDScript constants; the files arrive parsed, by file name.
void DmCore::load_legion_tuning(const Dictionary &p_files) {
	dm::LegionTuning &l = world.legion;
	const Dictionary ab = p_files.get("abilities", Dictionary());
	const Dictionary rl = ab.get("RALLY", Dictionary());
	l.rally_s = num(rl, "durationS", l.rally_s);
	l.rally_bonus_s = num(rl, "gravecallerBonusS", l.rally_bonus_s);
	l.rally_damage = num(rl, "damageMult", l.rally_damage);
	l.rally_attack = num(rl, "attackSpeedMult", l.rally_attack);
	l.rally_heal = num(rl, "healFrac", l.rally_heal);
	const Dictionary fen = p_files.get("fen", Dictionary());
	l.hag_thrall_damage = num(fen.get("HAG_HEX", Dictionary()), "thrallDamageMult", l.hag_thrall_damage);
	dm::PfTuning &pf = world.tun.pf;  // HAG_HEX, WISP_PULSE, SEXTON_HOOK, FEN_LURE: the Fen's effects
	const Dictionary hx = fen.get("HAG_HEX", Dictionary());
	pf.hex_r = num(hx, "radius", pf.hex_r);
	pf.hex_s = num(hx, "durationS", pf.hex_s);
	pf.hex_blow = num(hx, "blowMult", pf.hex_blow);
	pf.hex_chill_s = num(hx, "chillMs", pf.hex_chill_s * 1000.0) / 1000.0;
	const Dictionary wp = fen.get("WISP_PULSE", Dictionary());
	pf.pulse_r = num(wp, "radius", pf.pulse_r);
	pf.pulse_chill_s = num(wp, "chillMs", pf.pulse_chill_s * 1000.0) / 1000.0;
	const Dictionary sh = fen.get("SEXTON_HOOK", Dictionary());
	pf.hook_min = num(sh, "minRange", pf.hook_min);
	pf.hook_range = num(sh, "range", pf.hook_range);
	pf.hook_half = num(sh, "halfWidth", pf.hook_half);
	pf.hook_cooldown = num(sh, "cooldownS", pf.hook_cooldown);
	pf.hook_pull = num(sh, "pullM", pf.hook_pull);
	pf.hook_blow = num(sh, "blowMult", pf.hook_blow);
	pf.hook_root_s = num(sh, "rootMs", pf.hook_root_s * 1000.0) / 1000.0;
	const Dictionary fl = fen.get("FEN_LURE", Dictionary());
	pf.lure_x = num(fl, "x", pf.lure_x);
	pf.lure_z = num(fl, "z", pf.lure_z);
	const Dictionary st = p_files.get("statuses", Dictionary());
	const Dictionary sa = st.get("SANCTIFIED", Dictionary());
	world.tun.sanct_range = num(sa, "range", world.tun.sanct_range);
	world.tun.sanct_s = num(sa, "durationS", world.tun.sanct_s);
	world.tun.sanct_cooldown_mult = num(sa, "cooldownMult", world.tun.sanct_cooldown_mult);
	const Dictionary pb = st.get("PLAGUE_BURST", Dictionary());
	l.plague_radius = num(pb, "radius", l.plague_radius);
	l.plague_damage = num(pb, "damageMult", l.plague_damage);
	l.plague_pool_radius = num(pb, "poolRadius", l.plague_pool_radius);
	l.plague_pool_s = num(pb, "poolMs", l.plague_pool_s * 1000.0) / 1000.0;
	l.plague_pool_dps = num(pb, "poolDpsShare", l.plague_pool_dps);
	const Dictionary lg = p_files.get("gameplay_legendary", Dictionary());
	l.death_burst_r = num(lg.get("LEGEND", Dictionary()), "deathBurstR", l.death_burst_r);
	const Dictionary rt = p_files.get("runes", Dictionary());
	const Dictionary col = Dictionary(rt.get("RUNE_TUNING", Dictionary())).get("colossus", Dictionary());
	l.colossus_cleave_frac = num(col, "cleaveFrac", l.colossus_cleave_frac);
	l.colossus_cleave_r = num(col, "cleaveRadius", l.colossus_cleave_r);
	l.colossus_slots = num(col, "slots", l.colossus_slots);
	const Dictionary ce = p_files.get("combat_enemies", Dictionary());
	const Dictionary ds = ce.get("damage_scale", Dictionary());
	l.damage_scale_base = num(ds, "base", l.damage_scale_base);
	l.damage_scale_per_level = num(ds, "per_level", l.damage_scale_per_level);
}

void DmCore::load_sim_consts(const Dictionary &p_consts) {
	dm::LegionTuning &l = world.legion;
	l.corpse_lifetime = num(p_consts, "CORPSE_LIFETIME", l.corpse_lifetime);
	l.toxic_rupture = num(p_consts, "TOXIC_RUPTURE", l.toxic_rupture);
	l.max_corpses = int32_t(num(p_consts, "MAX_CORPSES", l.max_corpses));
	l.thrall_leash = num(p_consts, "THRALL_LEASH", l.thrall_leash);
	l.thrall_teleport = num(p_consts, "THRALL_TELEPORT", l.thrall_teleport);
	l.thrall_rise = num(p_consts, "THRALL_RISE_TIME", l.thrall_rise);
	l.follow_arrive = num(p_consts, "FOLLOW_ARRIVE", l.follow_arrive);
	l.follow_seat_moving = num(p_consts, "FOLLOW_SEAT_MOVING", l.follow_seat_moving);
	l.follow_catchup = num(p_consts, "FOLLOW_CATCHUP", l.follow_catchup);
	l.extra_ring = num(p_consts, "EXTRA_RING", l.extra_ring);
	l.fallback_pick_range = num(p_consts, "FALLBACK_PICK_RANGE", l.fallback_pick_range);
	l.toxic_r = num(p_consts, "TOXIC_R", l.toxic_r);
	l.toxic_s = num(p_consts, "TOXIC_S", l.toxic_s);
	l.toxic_tick = num(p_consts, "TOXIC_TICK", l.toxic_tick);
	l.toxic_dmg = num(p_consts, "TOXIC_DMG", l.toxic_dmg);
	l.engage_range = num(p_consts, "ENGAGE_RANGE", l.engage_range);
	l.corpse_s = num(p_consts, "CORPSE_S", l.corpse_s);
	l.weight_shield = num(p_consts, "WEIGHT_SHIELD", l.weight_shield);
	l.weight_other = num(p_consts, "WEIGHT_OTHER", l.weight_other);
}

Dictionary DmCore::tuning() const {
	const dm::LegionTuning &l = world.legion;
	Dictionary d;
	d["CORPSE_LIFETIME"] = l.corpse_lifetime;
	d["TOXIC_RUPTURE"] = l.toxic_rupture;
	d["MAX_CORPSES"] = l.max_corpses;
	d["THRALL_LEASH"] = l.thrall_leash;
	d["THRALL_TELEPORT"] = l.thrall_teleport;
	d["THRALL_RISE_TIME"] = l.thrall_rise;
	d["FOLLOW_ARRIVE"] = l.follow_arrive;
	d["FOLLOW_SEAT_MOVING"] = l.follow_seat_moving;
	d["FOLLOW_CATCHUP"] = l.follow_catchup;
	d["EXTRA_RING"] = l.extra_ring;
	d["FALLBACK_PICK_RANGE"] = l.fallback_pick_range;
	d["TOXIC_R"] = l.toxic_r;
	d["TOXIC_S"] = l.toxic_s;
	d["TOXIC_TICK"] = l.toxic_tick;
	d["TOXIC_DMG"] = l.toxic_dmg;
	d["ENGAGE_RANGE"] = l.engage_range;
	d["CORPSE_S"] = l.corpse_s;
	d["WEIGHT_SHIELD"] = l.weight_shield;
	d["WEIGHT_OTHER"] = l.weight_other;
	d["RALLY.durationS"] = l.rally_s;
	d["RALLY.gravecallerBonusS"] = l.rally_bonus_s;
	d["RALLY.damageMult"] = l.rally_damage;
	d["RALLY.attackSpeedMult"] = l.rally_attack;
	d["RALLY.healFrac"] = l.rally_heal;
	d["HAG_HEX.thrallDamageMult"] = l.hag_thrall_damage;
	d["PLAGUE_BURST.radius"] = l.plague_radius;
	d["PLAGUE_BURST.damageMult"] = l.plague_damage;
	d["PLAGUE_BURST.poolRadius"] = l.plague_pool_radius;
	d["PLAGUE_BURST.poolS"] = l.plague_pool_s;
	d["PLAGUE_BURST.poolDpsShare"] = l.plague_pool_dps;
	d["LEGEND.deathBurstR"] = l.death_burst_r;
	d["colossus.cleaveFrac"] = l.colossus_cleave_frac;
	d["colossus.cleaveRadius"] = l.colossus_cleave_r;
	d["colossus.slots"] = l.colossus_slots;
	d["damage_scale.base"] = l.damage_scale_base;
	d["damage_scale.per_level"] = l.damage_scale_per_level;
	d["ELITE.scale"] = world.tun.elite_scale;
	d["SANCTIFIED.range"] = world.tun.sanct_range;
	d["SANCTIFIED.durationS"] = world.tun.sanct_s;
	d["SANCTIFIED.cooldownMult"] = world.tun.sanct_cooldown_mult;
	d["CENSER.radius"] = world.tun.censer_r;
	d["CENSER.hasteS"] = world.tun.censer_haste_s;
	d["SCREAM.radius"] = world.tun.scream_r;
	d["TEMPLAR_SHIELD.halfArcDeg"] = world.tun.shield_arc_deg;
	d["TEMPLAR_SHIELD.passThrough"] = world.tun.shield_pass;
	d["UNBIND.range"] = world.tun.unbind_range;
	d["UNBIND.delayS"] = world.tun.unbind_delay_s;
	d["UNBIND.cooldownS"] = world.tun.unbind_cooldown_s;
	d["UNBIND.maxAlive"] = world.tun.unbind_max;
	d["WARD.range"] = world.tun.ward_range;
	d["WARD.maxTargets"] = world.tun.ward_max;
	d["PLAGUE_FLASK.radius"] = world.tun.flask_r;
	d["PLAGUE_FLASK.poolS"] = world.tun.flask_pool_s;
	d["PLAGUE_FLASK.poolDpsMult"] = world.tun.flask_pool_dps;
	const dm::PfTuning &pf = world.tun.pf;
	d["EMBER_BOLT.radius"] = pf.ember_r;
	d["EMBER_BOLT.poolS"] = pf.ember_pool_s;
	d["EMBER_BOLT.poolDpsMult"] = pf.ember_pool_dps;
	d["EMBER_DEATH.radius"] = pf.death_r;
	d["EMBER_DEATH.poolS"] = pf.death_pool_s;
	d["EMBER_DEATH.poolDpsMult"] = pf.death_pool_dps;
	d["SLAG_POOL.poolS"] = pf.slag_pool_s;
	d["SLAG_POOL.poolDpsMult"] = pf.slag_pool_dps;
	d["HAG_HEX.radius"] = pf.hex_r;
	d["HAG_HEX.durationS"] = pf.hex_s;
	d["HAG_HEX.blowMult"] = pf.hex_blow;
	d["HAG_HEX.chillS"] = pf.hex_chill_s;
	d["WISP_PULSE.radius"] = pf.pulse_r;
	d["WISP_PULSE.chillS"] = pf.pulse_chill_s;
	d["SEXTON_HOOK.minRange"] = pf.hook_min;
	d["SEXTON_HOOK.range"] = pf.hook_range;
	d["SEXTON_HOOK.halfWidth"] = pf.hook_half;
	d["SEXTON_HOOK.cooldownS"] = pf.hook_cooldown;
	d["SEXTON_HOOK.pullM"] = pf.hook_pull;
	d["SEXTON_HOOK.blowMult"] = pf.hook_blow;
	d["SEXTON_HOOK.rootS"] = pf.hook_root_s;
	d["FEN_LURE.x"] = pf.lure_x;
	d["FEN_LURE.z"] = pf.lure_z;
	return d;
}

void DmCore::set_nav_map(const RID &p_map) {
	nav_map = p_map;
	world.nav.user = &nav_map;
	world.nav.path = p_map.is_valid() ? nav_path : nullptr;
	world.nav.clamp = p_map.is_valid() ? nav_clamp : nullptr;
}

int64_t DmCore::nav_add_region(const PackedVector3Array &p_vertices, const PackedInt32Array &p_polygons, bool p_enabled) {
	std::vector<float> xz(size_t(p_vertices.size()) * 2);
	for (int64_t i = 0; i < p_vertices.size(); i++) {
		xz[size_t(i) * 2] = p_vertices[i].x;
		xz[size_t(i) * 2 + 1] = p_vertices[i].z;
	}
	return world.navgrid.add_region(xz.data(), int32_t(p_vertices.size()), p_polygons.ptr(), int32_t(p_polygons.size()), p_enabled);
}

void DmCore::nav_set_region_enabled(int64_t p_region, bool p_enabled) {
	world.navgrid.set_enabled(int32_t(p_region), p_enabled);
}

bool DmCore::nav_replace_region(int64_t p_region, const PackedVector3Array &p_vertices, const PackedInt32Array &p_polygons, bool p_enabled) {
	std::vector<float> xz(size_t(p_vertices.size()) * 2);
	for (int64_t i = 0; i < p_vertices.size(); i++) {
		xz[size_t(i) * 2] = p_vertices[i].x;
		xz[size_t(i) * 2 + 1] = p_vertices[i].z;
	}
	return world.navgrid.replace_region(int32_t(p_region), xz.data(), int32_t(p_vertices.size()), p_polygons.ptr(), int32_t(p_polygons.size()), p_enabled);
}

void DmCore::nav_clear_regions() {
	world.navgrid.clear();
}

Vector3 DmCore::nav_closest(const Vector3 &p_point) {
	float x = p_point.x, z = p_point.z;
	world.keep_on_nav(x, z);
	return Vector3(x, 0.0f, z);
}

int64_t DmCore::nav_triangle_count() const {
	return world.navgrid.triangle_count();
}

void DmCore::set_area_bounds(const Vector2 &p_min, const Vector2 &p_max) {
	world.grid.set_bounds(p_min.x, p_min.y, p_max.x, p_max.y, 4.0f);
}

int64_t DmCore::spawn_enemy(const String &p_def, const Vector2 &p_pos, int64_t p_level, double p_hp_mult, double p_damage_mult, bool p_elite, const String &p_area, bool p_rising, const PackedStringArray &p_affixes) {
	if (refused("spawn_enemy")) {
		return 0;
	}
	auto it = world.def_index.find(to_std(p_def));
	if (it == world.def_index.end()) {
		UtilityFunctions::push_error("DmCore.spawn_enemy: unknown enemy def ", p_def);
		return 0;
	}
	int32_t mask = 0;
	for (int64_t i = 0; i < p_affixes.size(); i++) {
		int32_t k = 0;
		while (k < dm::AF_COUNT && p_affixes[i] != String(dm::AFFIX_NAMES[k])) {
			k++;
		}
		if (k == dm::AF_COUNT) {
			UtilityFunctions::push_error("DmCore.spawn_enemy: unknown affix ", p_affixes[i]);
			continue;
		}
		mask |= 1 << k;
	}
	return world.spawn_enemy(it->second, p_pos.x, p_pos.y, int32_t(p_level), p_hp_mult, p_damage_mult, p_elite, world.area_id(to_std(p_area)), p_rising, mask);
}

bool DmCore::strip_shroud(int64_t p_id) {
	if (refused("strip_shroud")) {
		return false;
	}
	const auto it = world.enemy_slot.find(int32_t(p_id));
	return it != world.enemy_slot.end() && world.enemies[it->second].state != dm::DEAD && world.strip_shroud(it->second);
}

int64_t DmCore::add_obstacle(const Vector2 &p_a, const Vector2 &p_b, double p_thickness) {
	return world.add_obstacle(p_a.x, p_a.y, p_b.x, p_b.y, p_thickness);
}

bool DmCore::remove_obstacle(int64_t p_id) {
	return world.remove_obstacle(int32_t(p_id));
}

void DmCore::cover_miasma(int64_t p_id) {
	if (refused("cover_miasma")) {
		return;
	}
	const auto it = world.enemy_slot.find(int32_t(p_id));
	if (it != world.enemy_slot.end()) {
		world.enemies[it->second].miasma_at = world.clock;
	}
}

Dictionary DmCore::damage(int64_t p_id, double p_amount, int64_t p_source, bool p_allow_stagger) {
	Dictionary out;
	if (refused("damage")) {
		out["dealt"] = 0.0;
		out["killed"] = false;
		out["refused"] = true;
		return out;
	}
	dm::Body *b = world.body(int32_t(p_id));
	bool killed = false;
	double dealt = 0.0;
	if (b && b->is_thrall) {  // a boss or an enemy blow on a thrall: the health lost after damage taken and the barrier
		const double before = b->hp;
		if (world.damage_thrall(b->slot, p_amount, int32_t(p_source), killed)) {
			dealt = before - b->hp;
		}
	} else if (b) {
		dealt = world.damage_enemy(b->slot, p_amount, int32_t(p_source), p_allow_stagger, killed);
	}
	world.flush_spawns();  // a kill may have queued Vengeful's Risen
	out["dealt"] = dealt;
	out["killed"] = killed;
	return out;
}

bool DmCore::set_enemy_aggro(int64_t p_id, double p_aggro, double p_leash) {
	if (refused("set_enemy_aggro")) {
		return false;
	}
	const auto it = world.enemy_slot.find(int32_t(p_id));
	if (it == world.enemy_slot.end() || world.enemies[size_t(it->second)].state == dm::DEAD) {
		return false;
	}
	dm::Enemy &e = world.enemies[size_t(it->second)];
	e.aggro = p_aggro;
	e.leash = p_leash;
	return true;
}

bool DmCore::remove_enemy(int64_t p_id) {
	if (refused("remove_enemy")) {
		return false;
	}
	return world.remove_enemy(int32_t(p_id));
}

// DmBossNodeWorld.set_enemy_hp: a boss gives a body its health (the Abbess's niches). False for a dead or unknown id or a maximum of zero or less.
bool DmCore::set_enemy_hp(int64_t p_id, double p_hp, double p_max_hp) {
	if (refused("set_enemy_hp")) {
		return false;
	}
	return world.set_enemy_hp(int32_t(p_id), p_hp, p_max_hp);
}

// DmHostileZone.spawn for a boss: `kind` "toxic" (a rot pool), "ember" (burning ground) or "dust"; it pulses dps x one second at the heroes and thralls in it, with `source` (the boss's id)
// as the hurt's source. Returns the zone's id, 0 for an unknown kind.
int64_t DmCore::add_zone(const String &p_kind, const Vector2 &p_pos, double p_radius, double p_seconds, double p_dps, int64_t p_source) {
	if (refused("add_zone")) {
		return 0;
	}
	int32_t k = -1;
	if (p_kind == "dust") {
		k = dm::ZONE_DUST;
	} else if (p_kind == "toxic") {
		k = dm::ZONE_TOXIC;
	} else if (p_kind == "ember") {
		k = dm::ZONE_EMBER;
	}
	if (k < 0) {
		UtilityFunctions::push_error("DmCore.add_zone: unknown zone kind ", p_kind);
		return 0;
	}
	return world.add_zone(k, p_pos.x, p_pos.y, p_radius, p_seconds, p_dps, int32_t(p_source));
}

// The live zones of one kind, x, z, radius each (the Plague Saint's "am I standing in rot"). Empty on a puppet (a guest's zones are the host's events).
PackedFloat32Array DmCore::zones(const String &p_kind) const {
	PackedFloat32Array out;
	const int32_t k = p_kind == "dust" ? dm::ZONE_DUST : (p_kind == "toxic" ? dm::ZONE_TOXIC : (p_kind == "ember" ? dm::ZONE_EMBER : -1));
	if (k < 0) {
		return out;
	}
	zone_scratch.clear();
	world.zones_of(k, zone_scratch);
	out.resize(int64_t(zone_scratch.size()));
	for (size_t i = 0; i < zone_scratch.size(); i++) {
		out.set(int64_t(i), zone_scratch[i]);
	}
	return out;
}

void DmCore::stun(int64_t p_id, double p_seconds) {
	if (refused("stun")) {
		return;
	}
	dm::Body *b = world.body(int32_t(p_id));
	if (b && b->is_thrall) {
		world.stun_thrall(world.thralls[b->slot], p_seconds);
	} else if (b) {
		world.stun(b->slot, p_seconds);
	}
}

void DmCore::apply_status(int64_t p_id, const String &p_status, int64_t p_source, double p_stacks, double p_duration, const Dictionary &p_params) {
	if (refused("apply_status")) {
		return;
	}
	dm::Body *b = world.body(int32_t(p_id));
	const int32_t sid = world.status_id(to_std(p_status));
	if (!b) {
		return;
	}
	if (sid < 0) {
		UtilityFunctions::push_error("DmCore.apply_status: unknown status ", p_status);
		return;
	}
	world.apply_status(*b, sid, int32_t(p_source), p_stacks, p_duration, num(p_params, "dps", 0.0), num(p_params, "cap", -1.0), num(p_params, "amount", 0.0));
}

bool DmCore::remove_status(int64_t p_id, const String &p_status) {
	if (refused("remove_status")) {
		return false;
	}
	dm::Body *b = world.body(int32_t(p_id));
	const int32_t sid = world.status_id(to_std(p_status));
	return b && sid >= 0 && world.remove_status(*b, sid);
}

PackedByteArray DmCore::statuses(int64_t p_id) const {
	PackedByteArray out;
	const dm::Body *body = world.body(int32_t(p_id));
	if (!body) {
		return out;
	}
	const dm::StatusSet &s = body->st;
	out.resize(int64_t(s.n) * 4);
	for (int32_t i = 0; i < s.n; i++) {
		const dm::StatusRec &r = s.rec[i];
		const int32_t deci = r.rem >= 6.0e4 ? 65535 : std::clamp(int32_t(std::ceil(r.rem * 10.0)), 0, 65534);
		out.set(i * 4, uint8_t(r.id));
		out.set(i * 4 + 1, uint8_t(std::clamp(int32_t(r.stk), 0, 255)));
		out.set(i * 4 + 2, uint8_t(deci & 255));
		out.set(i * 4 + 3, uint8_t(deci >> 8));
	}
	return out;
}

double DmCore::status_stacks(int64_t p_id, const String &p_status) const {
	const dm::Body *b = world.body(int32_t(p_id));
	const int32_t sid = world.status_id(to_std(p_status));
	if (!b || sid < 0) {
		return 0.0;
	}
	const int32_t i = b->st.find(sid);
	return i >= 0 ? b->st.rec[i].stk : 0.0;
}

double DmCore::damage_dealt_mult(int64_t p_id) const {
	const dm::Body *b = world.body(int32_t(p_id));
	return b ? b->st.dealt : 1.0;
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
	if (world.puppet) {  // heroes and bosses are brain input; a puppet has no brains, so shared host/guest code may call these quietly
		return 0;
	}
	dm::External x;
	x.id = world.next_id++;
	x.kind = int32_t(p_kind);
	x.radius = p_radius;
	x.weight = p_weight;
	world.externals.push_back(x);
	return x.id;
}

void DmCore::set_external(int64_t p_id, const Vector2 &p_pos, bool p_alive) {
	if (world.puppet) {
		return;
	}
	for (dm::External &x : world.externals) {
		if (x.id == int32_t(p_id)) {
			x.x = p_pos.x;
			x.z = p_pos.y;
			x.alive = p_alive;
			return;
		}
	}
}

void DmCore::remove_external(int64_t p_id) {
	if (world.puppet) {
		return;
	}
	for (size_t i = 0; i < world.externals.size(); i++) {
		if (world.externals[i].id == int32_t(p_id)) {
			world.externals.erase(world.externals.begin() + int64_t(i));
			return;
		}
	}
}

void DmCore::step(double p_dt) {
	if (world.puppet) {
		world.step_puppet(p_dt);
	} else {
		world.step(p_dt);
	}
}

Array DmCore::take_events() {
	world.pump_reliable();  // a guest's batch is made from the same buffer: encode what it has not seen before this call clears it (nothing unless replicating)
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
	world.rep.ev_i = world.rep.ev_f = 0;
	event_batches++;
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

// Seven numbers per body in spawn order (id, def, x, z, hp, max hp, state): what a boss's brain reads of the table each tick (the Plague Saint looks for her doctors)
// without a Dictionary per body.
PackedFloat32Array DmCore::enemy_rows() const {
	PackedFloat32Array a;
	a.resize(int64_t(world.enemies.size()) * 7);
	float *w = a.ptrw();
	for (size_t i = 0; i < world.enemies.size(); i++) {
		const dm::Enemy &e = world.enemies[i];
		float *r = w + i * 7;
		r[0] = float(e.id);
		r[1] = float(e.def);
		r[2] = e.x;
		r[3] = e.z;
		r[4] = float(e.hp);
		r[5] = float(e.max_hp);
		r[6] = float(e.state);
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
	d["aggro"] = e.aggro;
	d["leash"] = e.leash;
	d["attack_cd"] = e.attack_cd;
	d["windup_s"] = e.windup_s;
	d["speed_mult"] = e.speed_mult;
	d["attack_rate_mult"] = e.attack_rate_mult;
	d["taken_mult"] = e.taken_mult;
	d["pos"] = Vector2(e.x, e.z);
	d["aim"] = Vector2(e.aim_x, e.aim_z);
	d["yaw"] = e.yaw;
	d["diving"] = e.diving;
	d["ward_t"] = e.ward_t;
	d["hooking"] = e.pf.hooking;
	d["hook_cd"] = e.pf.hook_cd;
	PackedStringArray af;
	for (int32_t k = 0; k < dm::AF_COUNT; k++) {
		if (e.affixes & (1 << k)) {
			af.push_back(dm::AFFIX_NAMES[k]);
		}
	}
	d["affixes"] = af;
	if (world.puppet) {  // where the last snapshot put it (the body eases toward this)
		d["net_pos"] = Vector2(e.net_x, e.net_z);
	}
	return d;
}

Dictionary DmCore::unbind_info(int64_t p_id) const {
	Dictionary d;
	for (const dm::Unbind &u : world.unbinds) {
		if (u.id != p_id) {
			continue;
		}
		d["cooldown"] = u.cd;
		d["watch"] = u.watch_t;
		Array pending;
		for (const dm::Unbind::Claim &c : u.pending) {
			Array one;
			one.push_back(c.left);
			one.push_back(c.x);
			one.push_back(c.z);
			pending.push_back(one);
		}
		d["pending"] = pending;
		PackedInt32Array unbound, seen;
		for (const int32_t id : u.unbound) {
			unbound.push_back(id);
		}
		for (const dm::Unbind::Seen &s : u.seen) {
			seen.push_back(s.thrall);
		}
		d["unbound"] = unbound;
		d["seen"] = seen;
	}
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

// ---------------------------------------------------------------------------------------------------------------- co-op

void DmCore::set_puppet(bool p_on) {
	world.set_puppet(p_on);
	refused_logged.clear();
}

bool DmCore::is_puppet() const {
	return world.puppet;
}

void DmCore::set_replication(bool p_on) {
	if (refused("set_replication")) {
		return;
	}
	world.set_replication(p_on);
}

PackedByteArray DmCore::snapshot(int64_t p_tick) {
	PackedByteArray out;
	if (refused("snapshot")) {
		return out;
	}
	world.write_snapshot(wire_buf, uint32_t(p_tick));
	out.resize(int64_t(wire_buf.size()));
	std::memcpy(out.ptrw(), wire_buf.data(), wire_buf.size());
	return out;
}

Array DmCore::snapshot_parts(int64_t p_tick, int64_t p_max_bytes) {
	Array out;
	if (refused("snapshot_parts")) {
		return out;
	}
	const size_t n = world.write_snapshot_parts(snap_parts, uint32_t(p_tick), size_t(p_max_bytes > 0 ? p_max_bytes : 0));
	for (size_t i = 0; i < n; i++) {
		PackedByteArray b;
		b.resize(int64_t(snap_parts[i].size()));
		std::memcpy(b.ptrw(), snap_parts[i].data(), snap_parts[i].size());
		out.push_back(b);
	}
	return out;
}

PackedByteArray DmCore::take_reliable() {
	PackedByteArray out;
	if (refused("take_reliable")) {
		return out;
	}
	if (world.take_reliable(wire_buf)) {
		out.resize(int64_t(wire_buf.size()));
		std::memcpy(out.ptrw(), wire_buf.data(), wire_buf.size());
	}
	return out;
}

PackedByteArray DmCore::baseline() {
	PackedByteArray out;
	if (refused("baseline")) {
		return out;
	}
	world.write_baseline(wire_buf);
	out.resize(int64_t(wire_buf.size()));
	std::memcpy(out.ptrw(), wire_buf.data(), wire_buf.size());
	return out;
}

bool DmCore::apply_snapshot(const PackedByteArray &p_bytes) {
	return world.read_snapshot(p_bytes.ptr(), size_t(p_bytes.size()));
}

bool DmCore::apply_reliable(const PackedByteArray &p_bytes) {
	return world.read_reliable(p_bytes.ptr(), size_t(p_bytes.size()));
}

String DmCore::replication_error() const {
	return String::utf8(world.rep.error.c_str());
}

int64_t DmCore::wire_version() {
	return dm::WIRE_VERSION;
}

Dictionary DmCore::replication_stats() const {
	const dm::Replica &r = world.rep;
	Dictionary d;
	d["puppet"] = world.puppet;
	d["replicating"] = r.replicating;
	d["snapshots_built"] = int64_t(r.snapshots_built);
	d["snapshot_frames"] = int64_t(r.snapshot_frames);
	d["batches_built"] = int64_t(r.batches_built);
	d["records_built"] = int64_t(r.records_built);
	d["reliable_bytes"] = int64_t(r.reliable_bytes);
	d["positions_clamped"] = int64_t(r.positions_clamped);
	d["overflows"] = int64_t(r.overflows);
	d["seq"] = int64_t(r.seq);
	d["snapshots_applied"] = int64_t(r.snapshots_applied);
	d["snapshots_stale"] = int64_t(r.snapshots_stale);
	d["snapshots_refused"] = int64_t(r.snapshots_refused);
	d["records_unknown"] = int64_t(r.records_unknown);
	d["records_dead"] = int64_t(r.records_dead);
	d["desync"] = int64_t(r.desync);
	d["batches_applied"] = int64_t(r.batches_applied);
	d["batches_duplicate"] = int64_t(r.batches_duplicate);
	d["batches_refused"] = int64_t(r.batches_refused);
	d["baselines_applied"] = int64_t(r.baselines_applied);
	d["events_derived"] = int64_t(r.events_derived);
	d["commands_refused"] = int64_t(r.commands_refused);
	// What the buffers on the per-tick path hold, by part (the test compares the total over a steady fight: no growth means no allocation).
	const size_t parts[] = { wire_buf.capacity(), r.rel.capacity(), r.base.capacity(), world.events.ints.capacity() * 4, world.events.floats.capacity() * 4,
		(world.gx.capacity() + world.gz.capacity()) * 4, world.enemies.capacity() * sizeof(dm::Enemy), world.thralls.capacity() * sizeof(dm::Thrall),
		world.corpses.capacity() * sizeof(dm::Corpse), world.scratch.capacity() * 4 };
	size_t held = 0;
	Array held_parts;
	for (const size_t v : parts) {
		held += v;
		held_parts.push_back(int64_t(v));
	}
	d["buffer_bytes"] = int64_t(held);
	d["buffer_parts"] = held_parts;
	d["need_baseline"] = r.need_baseline;
	d["last_tick"] = int64_t(r.last_tick);
	d["last_seq"] = int64_t(r.last_seq);
	return d;
}

// ---------------------------------------------------------------------------------------------------------------- thralls

int64_t DmCore::raise_thrall(const Dictionary &p_stats, int64_t p_owner, const Vector2 &p_pos, double p_yaw, double p_cap) {
	if (refused("raise_thrall")) {
		return 0;
	}
	dm::ThrallSpec sp;
	const String kind = str(p_stats, "kind", "warrior");
	sp.kind = -1;
	for (int32_t k = 0; k < dm::TK_COUNT; k++) {
		if (kind == String(dm::THRALL_KIND_NAMES[k])) {
			sp.kind = k;
		}
	}
	if (sp.kind < 0) {
		UtilityFunctions::push_error("DmCore.raise_thrall: unknown thrall kind ", kind);
		return 0;
	}
	sp.max_hp = num(p_stats, "maxHp", 1.0);
	sp.hp = num(p_stats, "hp", sp.max_hp);
	sp.damage = num(p_stats, "damage", 1.0);
	sp.interval = num(p_stats, "attackInterval", 1.0);
	sp.range = num(p_stats, "range", 1.3);
	sp.speed = num(p_stats, "speed", 5.0);
	sp.ally_heal = num(p_stats, "allyHeal", 0.0);
	sp.lifetime_s = num(p_stats, "lifetimeS", 0.0);
	sp.empowered = bool(p_stats.get("empowered", false));
	sp.champion = bool(p_stats.get("champion", false));
	const int32_t id = world.raise_thrall(sp, int32_t(p_owner), p_pos.x, p_pos.y, float(p_yaw), p_cap);
	world.flush_spawns();  // making room can crumble a thrall whose burst kills a Vengeful elite
	return id;
}

PackedInt32Array DmCore::last_crumbled() const {
	PackedInt32Array a;
	a.resize(int64_t(world.crumbled_out.size()));
	for (size_t i = 0; i < world.crumbled_out.size(); i++) {
		a.set(int64_t(i), world.crumbled_out[i]);
	}
	return a;
}

bool DmCore::kill_thrall(int64_t p_id, const String &p_reason) {
	if (refused("kill_thrall")) {
		return false;
	}
	const auto it = world.thrall_slot.find(int32_t(p_id));
	if (it == world.thrall_slot.end() || world.thralls[it->second].dead) {
		return false;
	}
	int32_t reason = -1;
	for (int32_t r = 0; r < 4; r++) {
		if (p_reason == String(dm::DEATH_REASON_NAMES[r])) {
			reason = r;
		}
	}
	if (reason < 0) {
		UtilityFunctions::push_error("DmCore.kill_thrall: unknown reason ", p_reason);
		return false;
	}
	world.kill_thrall(it->second, reason, 0);
	world.flush_spawns();
	return true;
}

Array DmCore::sacrifice_thralls(int64_t p_owner, int64_t p_n) {
	Array out;
	if (refused("sacrifice_thralls")) {
		return out;
	}
	for (int32_t i = 0; i < int32_t(world.thralls.size()); i++) {
		const dm::Thrall &t = world.thralls[i];
		if (t.dead || t.owner != int32_t(p_owner)) {
			continue;
		}
		if (p_n >= 0 && out.size() >= p_n) {
			break;
		}
		Dictionary d;
		d["kind"] = String(dm::THRALL_KIND_NAMES[t.kind]);
		d["maxHp"] = t.max_hp;
		d["damage"] = t.damage;
		d["pos"] = Vector2(t.x, t.z);
		d["yaw"] = t.yaw;
		out.push_back(d);
		world.kill_thrall(i, dm::DR_SACRIFICED, 0);
	}
	world.flush_spawns();
	return out;
}

void DmCore::rally_thralls(int64_t p_owner, double p_seconds, int64_t p_focus) {
	if (refused("rally_thralls")) {
		return;
	}
	world.rally_thralls(int32_t(p_owner), p_seconds, int32_t(p_focus));
}

void DmCore::recall_thralls(int64_t p_owner) {
	if (refused("recall_thralls")) {
		return;
	}
	world.recall_thralls(int32_t(p_owner));
}

void DmCore::set_legion_burst(int64_t p_owner, double p_fraction) {
	if (refused("set_legion_burst")) {
		return;
	}
	world.set_legion_burst(int32_t(p_owner), p_fraction);
}

namespace {
dm::Thrall *live_thrall(dm::World &p_world, int64_t p_id) {
	const auto it = p_world.thrall_slot.find(int32_t(p_id));
	return it != p_world.thrall_slot.end() && !p_world.thralls[it->second].dead ? &p_world.thralls[it->second] : nullptr;
}
} // namespace

void DmCore::set_thrall_target(int64_t p_id, int64_t p_target) {
	if (refused("set_thrall_target")) {
		return;
	}
	if (dm::Thrall *t = live_thrall(world, p_id)) {
		t->target = int32_t(p_target);
	}
}

void DmCore::set_thrall_mark(int64_t p_id, double p_mult) {
	if (refused("set_thrall_mark")) {
		return;
	}
	if (dm::Thrall *t = live_thrall(world, p_id)) {
		t->mark_mult = p_mult;
	}
}

void DmCore::curse_thrall(int64_t p_id, double p_seconds) {
	if (refused("curse_thrall")) {
		return;
	}
	if (dm::Thrall *t = live_thrall(world, p_id)) {
		t->cursed_t = p_seconds;
	}
}

void DmCore::set_thrall_pos(int64_t p_id, const Vector2 &p_pos) {
	if (refused("set_thrall_pos")) {
		return;
	}
	if (dm::Thrall *t = live_thrall(world, p_id)) {
		t->x = p_pos.x;
		t->z = p_pos.y;
		t->has_nav_goal = false;
	}
}

void DmCore::set_thrall_stats(int64_t p_id, const Dictionary &p_stats) {
	if (refused("set_thrall_stats")) {
		return;
	}
	if (dm::Thrall *t = live_thrall(world, p_id)) {
		t->hp = num(p_stats, "hp", t->hp);
		t->max_hp = num(p_stats, "maxHp", t->max_hp);
		t->damage = num(p_stats, "damage", t->damage);
		t->interval = num(p_stats, "attackInterval", t->interval);
		t->attack_cd = num(p_stats, "attackCd", t->attack_cd);
		if (p_stats.has("maxHp")) {
			world.queue_thrall_max_hp(int32_t(p_id));  // guests know health as a fraction of the maximum
		}
	}
}

PackedInt32Array DmCore::thralls_in_radius(const Vector2 &p_pos, double p_r, int64_t p_owner) const {
	world.thralls_in_radius(p_pos.x, p_pos.y, float(p_r), int32_t(p_owner), query_out);
	PackedInt32Array a;
	a.resize(int64_t(query_out.size()));
	for (size_t i = 0; i < query_out.size(); i++) {
		a.set(int64_t(i), query_out[i]);
	}
	return a;
}

int64_t DmCore::thrall_count(int64_t p_owner) const {
	return world.thrall_count(int32_t(p_owner));
}

double DmCore::thrall_places(int64_t p_owner) const {
	return world.thrall_places(int32_t(p_owner));
}

int64_t DmCore::thrall_total() const {
	return int64_t(world.thralls.size());
}

PackedInt32Array DmCore::thrall_ids() const {
	PackedInt32Array a;
	a.resize(int64_t(world.thralls.size()));
	for (size_t i = 0; i < world.thralls.size(); i++) {
		a.set(int64_t(i), world.thralls[i].id);
	}
	return a;
}

PackedFloat32Array DmCore::thrall_positions() const {
	PackedFloat32Array a;
	a.resize(int64_t(world.thralls.size()) * 3);
	float *w = a.ptrw();
	for (size_t i = 0; i < world.thralls.size(); i++) {
		w[i * 3] = world.thralls[i].x;
		w[i * 3 + 1] = world.thralls[i].z;
		w[i * 3 + 2] = world.thralls[i].yaw;
	}
	return a;
}

PackedInt32Array DmCore::thrall_states() const {
	PackedInt32Array a;
	a.resize(int64_t(world.thralls.size()));
	for (size_t i = 0; i < world.thralls.size(); i++) {
		a.set(int64_t(i), world.thralls[i].state);
	}
	return a;
}

PackedInt32Array DmCore::thrall_kinds() const {
	PackedInt32Array a;
	a.resize(int64_t(world.thralls.size()));
	for (size_t i = 0; i < world.thralls.size(); i++) {
		a.set(int64_t(i), world.thralls[i].kind);
	}
	return a;
}

PackedInt32Array DmCore::thrall_swings() const {
	PackedInt32Array a;
	a.resize(int64_t(world.thralls.size()));
	for (size_t i = 0; i < world.thralls.size(); i++) {
		a.set(int64_t(i), world.thralls[i].swing_n);
	}
	return a;
}

PackedInt32Array DmCore::thrall_owners() const {
	PackedInt32Array a;
	a.resize(int64_t(world.thralls.size()));
	for (size_t i = 0; i < world.thralls.size(); i++) {
		a.set(int64_t(i), world.thralls[i].owner);
	}
	return a;
}

PackedFloat32Array DmCore::thrall_hp() const {
	PackedFloat32Array a;
	a.resize(int64_t(world.thralls.size()) * 2);
	float *w = a.ptrw();
	for (size_t i = 0; i < world.thralls.size(); i++) {
		w[i * 2] = float(world.thralls[i].hp);
		w[i * 2 + 1] = float(world.thralls[i].max_hp);
	}
	return a;
}

PackedFloat32Array DmCore::thrall_ground_speeds() const {
	PackedFloat32Array a;
	a.resize(int64_t(world.thralls.size()));
	for (size_t i = 0; i < world.thralls.size(); i++) {
		a.set(int64_t(i), float(world.thralls[i].ground_speed));
	}
	return a;
}

Dictionary DmCore::thrall_info(int64_t p_id) const {
	Dictionary d;
	const auto it = world.thrall_slot.find(int32_t(p_id));
	if (it == world.thrall_slot.end()) {
		return d;
	}
	const dm::Thrall &t = world.thralls[it->second];
	d["id"] = t.id;
	d["kind"] = String(dm::THRALL_KIND_NAMES[t.kind]);
	d["kind_id"] = t.kind;
	d["owner"] = t.owner;
	d["state"] = t.state;
	d["alive"] = !t.dead;
	d["hp"] = t.hp;
	d["max_hp"] = t.max_hp;
	d["damage"] = t.damage;
	d["interval"] = t.interval;
	d["range"] = t.attack_range;
	d["speed"] = t.speed;
	d["radius"] = t.radius;
	d["target"] = t.target;
	d["swing_n"] = t.swing_n;
	d["attack_cd"] = t.attack_cd;
	d["state_t"] = t.state_t;
	d["rally_t"] = t.rally_t;
	d["stun_t"] = t.stun_t;
	d["cursed_t"] = t.cursed_t;
	d["age"] = t.age;
	d["lifetime_s"] = t.lifetime_s;
	d["mark_mult"] = t.mark_mult;
	d["death_burst_frac"] = t.death_burst_frac;
	d["formation_slot"] = t.formation_slot;
	d["formation_rank"] = t.formation_rank;
	d["formation_count"] = t.formation_count;
	d["empowered"] = t.empowered;
	d["champion"] = t.champion;
	d["ally_heal"] = t.ally_heal;
	d["speed_mult"] = t.speed_mult;
	d["attack_rate_mult"] = t.attack_rate_mult;
	d["taken_mult"] = t.taken_mult;
	d["dead_reason"] = t.dead_reason >= 0 ? String(dm::DEATH_REASON_NAMES[t.dead_reason]) : String();
	d["pos"] = Vector2(t.x, t.z);
	d["aim"] = Vector2(t.aim_x, t.aim_z);
	d["yaw"] = t.yaw;
	if (world.puppet) {
		d["net_pos"] = Vector2(t.net_x, t.net_z);
	}
	return d;
}

String DmCore::thrall_kind_name(int64_t p_kind) const {
	return (p_kind >= 0 && p_kind < dm::TK_COUNT) ? String(dm::THRALL_KIND_NAMES[p_kind]) : String();
}

String DmCore::death_reason_name(int64_t p_reason) const {
	return (p_reason >= 0 && p_reason < 4) ? String(dm::DEATH_REASON_NAMES[p_reason]) : String();
}

String DmCore::affix_moment_name(int64_t p_kind) const {
	return (p_kind >= 0 && p_kind <= dm::AM_UNVEIL) ? String(dm::AFFIX_MOMENT_NAMES[p_kind]) : String();
}

// ---------------------------------------------------------------------------------------------------------------- corpses

void DmCore::set_corpse_life_mult(double p_mult) {
	world.corpse_life_mult = p_mult;
}

void DmCore::set_area_level(const String &p_area, int64_t p_level) {
	const int32_t a = world.area_id(to_std(p_area));
	if (int32_t(world.area_levels.size()) <= a) {
		world.area_levels.resize(size_t(a) + 1, 1);
	}
	world.area_levels[a] = int32_t(p_level);
}

int64_t DmCore::corpse_add(const Vector2 &p_pos, const String &p_kind, const String &p_enemy, bool p_elite, double p_facing, double p_scale, const String &p_area) {
	if (refused("corpse_add")) {
		return 0;
	}
	int32_t kind = -1;
	for (int32_t k = 0; k < 5; k++) {
		if (p_kind == String(dm::CORPSE_KIND_NAMES[k])) {
			kind = k;
		}
	}
	if (kind < 0) {
		UtilityFunctions::push_error("DmCore.corpse_add: unknown corpse kind ", p_kind);
		return 0;
	}
	int32_t def = dm::ENEMY_RISEN;
	const auto it = world.def_index.find(to_std(p_enemy));
	if (it != world.def_index.end()) {
		def = it->second;
	} else if (p_enemy != String("risen")) {
		UtilityFunctions::push_error("DmCore.corpse_add: unknown enemy def ", p_enemy);
		return 0;
	}
	return world.add_corpse(double(p_pos.x), double(p_pos.y), kind, def, p_elite, p_facing, p_scale, world.area_id(to_std(p_area)));
}

PackedInt32Array DmCore::corpses_in_radius(const Vector2 &p_pos, double p_r, const String &p_area) const {
	PackedInt32Array a;
	int32_t area = -1;
	if (!p_area.is_empty()) {
		const auto it = world.area_index.find(to_std(p_area));
		if (it == world.area_index.end()) {
			return a;  // no corpse lies in an area nobody has named
		}
		area = it->second;
	}
	world.corpses_in_radius(p_pos.x, p_pos.y, p_r, area, query_out);
	a.resize(int64_t(query_out.size()));
	for (size_t i = 0; i < query_out.size(); i++) {
		a.set(int64_t(i), query_out[i]);
	}
	return a;
}

int64_t DmCore::corpse_pick(const Vector2 &p_aim, double p_pick_r, double p_max_range, const Vector2 &p_from, const String &p_area) const {
	int32_t area = -1;
	if (!p_area.is_empty()) {
		const auto it = world.area_index.find(to_std(p_area));
		area = it != world.area_index.end() ? it->second : -3;  // an unnamed area: only corpses with no area (none) can match
	}
	return world.pick_corpse(p_aim.x, p_aim.y, p_pick_r, p_max_range, p_from.x, p_from.y, area);
}

bool DmCore::corpse_consume(int64_t p_id, int64_t p_by, const String &p_reason) {
	if (refused("corpse_consume")) {
		return false;
	}
	return world.consume_corpse(int32_t(p_id), int32_t(p_by), world.reason_id(to_std(p_reason)));
}

int64_t DmCore::corpse_count() const {
	return int64_t(world.corpses.size());
}

PackedInt32Array DmCore::corpse_ids() const {
	PackedInt32Array a;
	a.resize(int64_t(world.corpses.size()));
	for (size_t i = 0; i < world.corpses.size(); i++) {
		a.set(int64_t(i), world.corpses[i].id);
	}
	return a;
}

PackedFloat32Array DmCore::corpse_positions() const {
	PackedFloat32Array a;
	a.resize(int64_t(world.corpses.size()) * 4);
	float *w = a.ptrw();
	for (size_t i = 0; i < world.corpses.size(); i++) {
		const dm::Corpse &c = world.corpses[i];
		w[i * 4] = float(c.x);
		w[i * 4 + 1] = float(c.z);
		w[i * 4 + 2] = float(c.facing);
		w[i * 4 + 3] = float(c.scale);
	}
	return a;
}

Dictionary DmCore::corpse_info(int64_t p_id) const {
	Dictionary d;
	const int32_t i = world.corpse_index(int32_t(p_id));
	if (i < 0) {
		return d;
	}
	const dm::Corpse &c = world.corpses[i];
	d["id"] = c.id;
	d["kind"] = String(dm::CORPSE_KIND_NAMES[c.kind]);
	d["enemy"] = c.def >= 0 ? String(world.defs[c.def].id.c_str()) : String("risen");
	d["elite"] = c.elite;
	d["area"] = String(world.areas[c.area].c_str());
	d["x"] = c.x;
	d["z"] = c.z;
	d["facing"] = c.facing;
	d["scale"] = c.scale;
	d["bornAt"] = c.born_at;
	d["expiresAt"] = c.expires_at;
	d["ruptureAt"] = c.rupture_at;
	return d;
}

String DmCore::reason_name(int64_t p_reason) const {
	return (p_reason >= 0 && p_reason < int64_t(world.reasons.size())) ? String(world.reasons[p_reason].c_str()) : String();
}
