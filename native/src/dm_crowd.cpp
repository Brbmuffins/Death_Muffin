#include "dm_crowd.h"

#include <algorithm>
#include <cmath>
#include <cstring>

#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

#include "dm_core.h"

using namespace godot;

namespace {
constexpr int32_t LEGION_SLOTS = 9;      // legion ids -1..7
constexpr double THRALL_SWING_IN = 0.12;  // a thrall's blow lands the instant its swing starts: the clip opens just before its impact (DmEntityViews)

std::string to_std(const String &p_s) {
	const CharString u = p_s.utf8();
	return std::string(u.get_data(), size_t(u.length()));
}
double num(const Dictionary &p_d, const char *p_key, double p_default) {
	const Variant v = p_d.get(String(p_key), Variant());
	return (v.get_type() == Variant::FLOAT || v.get_type() == Variant::INT) ? double(v) : p_default;
}
bool flag(const Dictionary &p_d, const char *p_key) {
	const Variant v = p_d.get(String(p_key), Variant());
	return v.get_type() == Variant::BOOL && bool(v);
}
void tint_of(const Dictionary &p_d, const char *p_key, float *r_out) {
	const Variant v = p_d.get(String(p_key), Variant());
	if (v.get_type() == Variant::COLOR) {
		const Color c = v;
		r_out[0] = c.r;
		r_out[1] = c.g;
		r_out[2] = c.b;
	}
}
// A glow: a Color whose rgb is the linear emissive colour and whose alpha is the strength.
void glow_of(const Dictionary &p_d, const char *p_key, float *r_out) {
	const Variant v = p_d.get(String(p_key), Variant());
	if (v.get_type() == Variant::COLOR) {
		const Color c = v;
		r_out[0] = c.r;
		r_out[1] = c.g;
		r_out[2] = c.b;
		r_out[3] = c.a;
	}
}
} // namespace

void DmCrowd::_bind_methods() {
	ClassDB::bind_method(D_METHOD("add_model", "slug", "data", "lod_rids", "shadow_rids", "lod_distances"), &DmCrowd::add_model);
	ClassDB::bind_method(D_METHOD("set_glows", "elite", "champion_add"), &DmCrowd::set_glows);
	ClassDB::bind_method(D_METHOD("glow_palette"), &DmCrowd::glow_palette);
	ClassDB::bind_method(D_METHOD("glow_version"), &DmCrowd::glow_version);
	ClassDB::bind_method(D_METHOD("take_landings"), &DmCrowd::take_landings);
	ClassDB::bind_method(D_METHOD("shatter", "corpse"), &DmCrowd::shatter);
	ClassDB::bind_method(D_METHOD("ground_at", "id"), &DmCrowd::ground_at);
	ClassDB::bind_method(D_METHOD("set_enemy_look", "def", "look"), &DmCrowd::set_enemy_look);
	ClassDB::bind_method(D_METHOD("set_thrall_look", "kind", "legion", "look"), &DmCrowd::set_thrall_look);
	ClassDB::bind_method(D_METHOD("set_owner_legion", "owner", "legion"), &DmCrowd::set_owner_legion);
	ClassDB::bind_method(D_METHOD("set_focus", "pos"), &DmCrowd::set_focus);
	ClassDB::bind_method(D_METHOD("set_hitstop_scale", "scale"), &DmCrowd::set_hitstop_scale);
	ClassDB::bind_method(D_METHOD("set_champion_scale", "scale"), &DmCrowd::set_champion_scale);
	ClassDB::bind_method(D_METHOD("set_shadow_policy", "casters", "crowded_casters", "thralls_cast"), &DmCrowd::set_shadow_policy);
	ClassDB::bind_method(D_METHOD("set_seed", "seed"), &DmCrowd::set_seed);
	ClassDB::bind_method(D_METHOD("reserve", "rows"), &DmCrowd::reserve);
	ClassDB::bind_method(D_METHOD("clear"), &DmCrowd::clear);
	ClassDB::bind_method(D_METHOD("sync", "core"), &DmCrowd::sync);
	ClassDB::bind_method(D_METHOD("sync_rows", "body_ints", "body_floats", "hits", "corpse_ints", "corpse_floats"), &DmCrowd::sync_rows);
	ClassDB::bind_method(D_METHOD("draw", "dt", "alpha", "camera"), &DmCrowd::draw);
	ClassDB::bind_method(D_METHOD("buffer", "model", "lod", "shadow"), &DmCrowd::buffer, DEFVAL(false));
	ClassDB::bind_method(D_METHOD("instance_count", "model", "lod", "shadow"), &DmCrowd::instance_count, DEFVAL(false));
	ClassDB::bind_method(D_METHOD("stats"), &DmCrowd::stats);
	ClassDB::bind_method(D_METHOD("view_info", "id", "corpse"), &DmCrowd::view_info, DEFVAL(false));
	ClassDB::bind_method(D_METHOD("last_feed"), &DmCrowd::last_feed);
	ClassDB::bind_static_method("DmCrowd", D_METHOD("turn_toward", "cur", "target", "dt", "rate", "max_rate"), &DmCrowd::turn_toward);
	ClassDB::bind_static_method("DmCrowd", D_METHOD("smooth_speed", "prev", "sample", "dt", "tau"), &DmCrowd::smooth_speed);
	ClassDB::bind_static_method("DmCrowd", D_METHOD("knock_impulse", "frac", "mass", "dx", "dz"), &DmCrowd::knock_impulse);
	ClassDB::bind_static_method("DmCrowd", D_METHOD("step_knock", "state", "dt"), &DmCrowd::step_knock);
	ClassDB::bind_static_method("DmCrowd", D_METHOD("settle_depth", "t", "depth", "dur"), &DmCrowd::settle_depth, DEFVAL(0.45));
	ClassDB::bind_static_method("DmCrowd", D_METHOD("strike_timing", "duration", "impact", "impact_in", "follow"), &DmCrowd::strike_timing);
}

DmCrowd::DmCrowd() {
	thrall_looks.resize(size_t(dm::TK_COUNT) * LEGION_SLOTS);
}

// ---------------------------------------------------------------------------------------------------------------- setup

int64_t DmCrowd::add_model(const String &p_slug, const Dictionary &p_data, const Array &p_lod_rids, const Array &p_shadow_rids, const PackedFloat32Array &p_lod_distances) {
	dm::CrowdModel m;
	m.slug = to_std(p_slug);
	m.height = num(p_data, "height", 1.0);
	m.stride_walk = p_data.has("stride_walk") && num(p_data, "stride_walk", 0.0) > 0.0 ? num(p_data, "stride_walk", 0.7) : 0.7;  // DmAnimator.DEFAULT_WALK
	m.stride_run = num(p_data, "stride_run", 0.0);
	const PackedStringArray names = p_data.get("clip_names", PackedStringArray());
	const PackedFloat32Array seconds = p_data.get("clip_seconds", PackedFloat32Array());
	const PackedFloat32Array length = p_data.get("clip_length", PackedFloat32Array());
	const PackedFloat32Array impact = p_data.get("clip_impact", PackedFloat32Array());
	const PackedFloat32Array landing = p_data.get("clip_landing", PackedFloat32Array());
	const PackedInt32Array loop = p_data.get("clip_loop", PackedInt32Array());
	const int64_t n = names.size();
	for (int64_t i = 0; i < n; i++) {
		m.clip_names.push_back(to_std(names[i]));
		const double s = i < seconds.size() ? double(seconds[i]) : 0.0;
		m.seconds.push_back(s);
		m.length.push_back(i < length.size() ? double(length[i]) : s);
		m.impact.push_back(i < impact.size() ? double(impact[i]) : -1.0);
		m.landing.push_back(i < landing.size() ? double(landing[i]) : -1.0);
		m.loop.push_back(i < loop.size() && loop[i] != 0 ? 1 : 0);
	}
	const Dictionary roles = p_data.get("roles", Dictionary());
	for (int32_t r = 0; r < dm::RL_COUNT; r++) {
		const Variant pool = roles.get(String(dm::ROLE_NAMES[r]), Variant());
		if (pool.get_type() != Variant::ARRAY && pool.get_type() != Variant::PACKED_STRING_ARRAY) {
			continue;
		}
		const Array a = pool;
		for (int64_t k = 0; k < a.size(); k++) {
			const std::string nm = to_std(String(a[k]));
			for (size_t c = 0; c < m.clip_names.size(); c++) {
				if (m.clip_names[c] == nm) {
					m.pool[r].push_back(int32_t(c));
				}
			}
		}
	}
	m.lods = int32_t(std::max<int64_t>(1, p_lod_rids.size()));
	for (int32_t l = 0; l + 1 < m.lods && l < p_lod_distances.size(); l++) {
		m.lod_dist.push_back(p_lod_distances[l]);
	}
	const int32_t slot = view.add_model(m);
	rids.resize(size_t(view.group_count()));
	const dm::CrowdModel &added = view.model(slot);
	for (int32_t l = 0; l < added.lods; l++) {
		rids[size_t(added.group0 + l * 2)].rid = l < p_lod_rids.size() ? RID(p_lod_rids[l]) : RID();
		rids[size_t(added.group0 + l * 2 + 1)].rid = l < p_shadow_rids.size() ? RID(p_shadow_rids[l]) : RID();
	}
	return slot;
}

void DmCrowd::set_look(Look &r_look, const Dictionary &p_look) {
	r_look = Look();
	r_look.set = true;
	r_look.model = int32_t(num(p_look, "model", -1));
	r_look.hover = float(num(p_look, "hover", 0.0));
	r_look.scale = float(num(p_look, "scale", 1.0));
	r_look.flags = (flag(p_look, "caster") ? dm::BF_CASTER : 0) | (flag(p_look, "inert") ? dm::BF_INERT : 0) | (flag(p_look, "mist") ? dm::BF_MIST : 0) |
			(flag(p_look, "flyer") ? dm::BF_FLYER : 0);
	tint_of(p_look, "tint", r_look.tint);
	std::memcpy(r_look.tint_fen, r_look.tint, sizeof(r_look.tint));
	glow_of(p_look, "glow", r_look.glow);
	r_look.glow_emp = float(num(p_look, "glow_empowered", 0.0));
	std::memcpy(r_look.glow_fen, r_look.glow, sizeof(r_look.glow));
	if (p_look.has("tint_fen")) {
		tint_of(p_look, "tint_fen", r_look.tint_fen);
		r_look.has_fen = true;
	}
	if (p_look.has("glow_fen")) {
		glow_of(p_look, "glow_fen", r_look.glow_fen);
		r_look.has_fen = true;
	}
}

// The palette slot of a glow (linear rgb + strength): 0 for none, an existing slot for the same glow, else a new one (at most GLOW_SLOTS; past that, none).
int32_t DmCrowd::glow_slot(const float *p_rgbk) {
	if (p_rgbk[3] <= 0.0f) {
		return 0;
	}
	const int32_t n = int32_t(glow_pal.size() / 4);
	for (int32_t i = 1; i < n; i++) {
		const float *q = &glow_pal[size_t(i) * 4];
		if (q[0] == p_rgbk[0] && q[1] == p_rgbk[1] && q[2] == p_rgbk[2] && q[3] == p_rgbk[3]) {
			return i;
		}
	}
	if (n >= GLOW_SLOTS) {
		return 0;
	}
	glow_pal.insert(glow_pal.end(), p_rgbk, p_rgbk + 4);
	glow_ver++;
	return n;
}

void DmCrowd::set_glows(const Color &p_elite, double p_champion_add) {
	elite_glow[0] = p_elite.r;
	elite_glow[1] = p_elite.g;
	elite_glow[2] = p_elite.b;
	elite_glow[3] = p_elite.a;
	elite_slot = -1;
	champion_add = float(p_champion_add);
	for (Look &l : thrall_looks) {
		l.slot_var[0] = l.slot_var[1] = l.slot_var[2] = l.slot_var[3] = -1;
	}
}

int32_t DmCrowd::enemy_glow(const Look &p_look, bool p_elite, bool p_drowned) {
	if (p_elite) {
		if (elite_slot < 0) {
			elite_slot = glow_slot(elite_glow);
		}
		return elite_slot;
	}
	int32_t &slot = p_drowned ? p_look.slot_fen : p_look.slot;
	if (slot < 0) {
		slot = glow_slot(p_drowned ? p_look.glow_fen : p_look.glow);
	}
	return slot;
}

int32_t DmCrowd::thrall_glow(const Look &p_look, bool p_empowered, bool p_champion) {
	const int32_t k = (p_empowered ? 1 : 0) + (p_champion ? 2 : 0);
	int32_t &slot = p_look.slot_var[k];
	if (slot < 0) {
		float g[4] = { p_look.glow[0], p_look.glow[1], p_look.glow[2], p_look.glow[3] };
		if (g[3] > 0.0f) {
			g[3] += (p_empowered ? p_look.glow_emp : 0.0f) + (p_champion ? champion_add : 0.0f);
		}
		slot = glow_slot(g);
	}
	return slot;
}

PackedColorArray DmCrowd::glow_palette() const {
	PackedColorArray out;
	for (size_t i = 0; i + 3 < glow_pal.size(); i += 4) {
		out.push_back(Color(glow_pal[i], glow_pal[i + 1], glow_pal[i + 2], glow_pal[i + 3]));
	}
	return out;
}

Vector3 DmCrowd::ground_at(int64_t p_id) const {
	const dm::View *v = view.find(int32_t(p_id));
	if (v == nullptr || v->mode != dm::M_LIVE) {
		return Vector3(INFINITY, INFINITY, INFINITY);
	}
	return Vector3(float(v->dx), 0.0f, float(v->dz));
}

bool DmCrowd::shatter(int64_t p_corpse) {
	return view.shatter(int32_t(p_corpse));
}

PackedFloat32Array DmCrowd::take_landings() {
	PackedFloat32Array out;
	if (view.landings.empty()) {
		return out;
	}
	out.resize(int64_t(view.landings.size()));
	std::memcpy(out.ptrw(), view.landings.data(), view.landings.size() * sizeof(float));
	view.landings.clear();
	return out;
}

int64_t DmCrowd::glow_version() const {
	return glow_ver;
}

void DmCrowd::set_enemy_look(const String &p_def, const Dictionary &p_look) {
	Look l;
	set_look(l, p_look);
	enemy_looks[to_std(p_def)] = l;
	looks_dirty = true;
}

void DmCrowd::set_thrall_look(const String &p_kind, int64_t p_legion, const Dictionary &p_look) {
	const std::string kind = to_std(p_kind);
	for (int32_t k = 0; k < dm::TK_COUNT; k++) {
		if (kind == dm::THRALL_KIND_NAMES[k] && p_legion >= -1 && p_legion + 1 < LEGION_SLOTS) {
			set_look(thrall_looks[size_t(k) * LEGION_SLOTS + size_t(p_legion + 1)], p_look);
		}
	}
}

void DmCrowd::set_owner_legion(int64_t p_owner, int64_t p_legion) {
	owner_legion[int32_t(p_owner)] = int32_t(p_legion);
}

void DmCrowd::set_focus(const Vector2 &p_pos) {
	view.focus_x = p_pos.x;
	view.focus_z = p_pos.y;
}

void DmCrowd::set_hitstop_scale(double p_scale) {
	view.hitstop_scale = p_scale;
}

void DmCrowd::set_champion_scale(double p_scale) {
	view.champion_scale = p_scale;
}

void DmCrowd::set_shadow_policy(int64_t p_casters, int64_t p_crowded_casters, bool p_thralls_cast) {
	view.shadow_casters = int32_t(p_casters);
	view.crowded_casters = int32_t(p_crowded_casters);
	view.set_thrall_shadows(p_thralls_cast);
}

void DmCrowd::set_seed(int64_t p_seed) {
	view.seed = uint64_t(p_seed);
}

void DmCrowd::reserve(int64_t p_rows) {
	view.reserve(int32_t(p_rows));
}

void DmCrowd::clear() {
	view.clear_views();
	owner_legion.clear();
	ev_i = ev_f = 0;
}

// ---------------------------------------------------------------------------------------------------------------- the tick

void DmCrowd::rebuild_looks(const dm::World &p_world) {
	def_looks.assign(p_world.defs.size(), Look());
	for (size_t i = 0; i < p_world.defs.size(); i++) {
		const auto it = enemy_looks.find(p_world.defs[i].id);
		if (it != enemy_looks.end()) {
			def_looks[i] = it->second;
		}
	}
	const auto r = enemy_looks.find("risen");
	risen_look = r != enemy_looks.end() ? r->second : Look();
	looks_dirty = false;
}

const DmCrowd::Look *DmCrowd::thrall_look(int32_t p_kind, int32_t p_legion) const {
	const Look *l = &thrall_looks[size_t(p_kind) * LEGION_SLOTS + size_t(p_legion + 1)];
	if (!l->set) {
		l = &thrall_looks[size_t(p_kind) * LEGION_SLOTS];
	}
	return l->set ? l : nullptr;
}

void DmCrowd::sync(const Ref<DmCore> &p_core) {
	if (p_core.is_null()) {
		return;
	}
	const dm::World &w = p_core->world;
	if (looks_dirty || def_looks.size() != w.defs.size()) {
		rebuild_looks(w);
	}
	feed.clear();
	int32_t fen = -1;
	for (size_t i = 0; i < w.areas.size(); i++) {
		if (w.areas[i] == "fen") {
			fen = int32_t(i);
		}
	}
	for (const dm::Enemy &e : w.enemies) {
		const Look &look = def_looks[size_t(e.def)];
		if (look.model < 0) {
			continue;
		}
		dm::CrowdBody b;
		b.id = e.id;
		b.kind = dm::BK_ENEMY;
		b.model = look.model;
		b.state = e.state;
		b.flags = look.flags | (e.elite ? dm::BF_ELITE : 0);
		b.def = e.def;
		b.x = e.x;
		b.z = e.z;
		b.yaw = e.yaw;
		b.speed = float(e.ground_speed);
		b.state_t = float(e.state_t);
		b.action_s = float(e.state == dm::ATTACK ? e.windup_s : (e.state == dm::DIG ? w.tun.burrow_dig_s : (e.state == dm::EMERGE ? dm::RECOVER_S : 0.0)));
		b.scale = float(w.defs[size_t(e.def)].scale * (e.elite ? w.tun.elite_scale : 1.0));
		b.hover = look.hover;
		const bool drowned = look.has_fen && e.area == fen;
		const float *tint = drowned ? look.tint_fen : look.tint;  // a drowned risen
		b.tint[0] = tint[0];
		b.tint[1] = tint[1];
		b.tint[2] = tint[2];
		b.glow = enemy_glow(look, e.elite, drowned);
		feed.bodies.push_back(b);
	}
	for (const dm::Thrall &t : w.thralls) {
		const auto ol = owner_legion.find(t.owner);
		const Look *look = thrall_look(t.kind, ol != owner_legion.end() ? ol->second : -1);
		if (look == nullptr || look->model < 0) {
			continue;
		}
		dm::CrowdBody b;
		b.id = t.id;
		b.kind = dm::BK_THRALL;
		b.model = look->model;
		b.state = t.state;
		b.flags = look->flags;
		b.swing = t.swing_n;
		b.def = -2 - t.kind;
		b.x = t.x;
		b.z = t.z;
		b.yaw = t.yaw;
		b.speed = float(t.ground_speed);
		b.state_t = float(t.state_t);
		b.action_s = float(THRALL_SWING_IN);
		b.scale = float(look->scale * (t.champion ? view.champion_scale : 1.0));
		b.hover = look->hover;
		b.tint[0] = look->tint[0];
		b.tint[1] = look->tint[1];
		b.tint[2] = look->tint[2];
		b.glow = thrall_glow(*look, t.empowered, t.champion);
		feed.bodies.push_back(b);
	}
	// Damage, from the events: the buffer is read from where the last sync stopped, and left for take_events.
	const dm::Events &ev = w.events;
	if (p_core->event_batches != ev_batches || ev.ints.size() < ev_i || ev.floats.size() < ev_f) {
		ev_i = ev_f = 0;
		ev_batches = p_core->event_batches;
	}
	size_t i = ev_i, f = ev_f;
	while (i + 4 <= ev.ints.size()) {
		const int32_t type = ev.ints[i], id = ev.ints[i + 1], ni = ev.ints[i + 2], nf = ev.ints[i + 3];
		if ((type == dm::EV_ENEMY_DAMAGED || type == dm::EV_THRALL_DAMAGED) && nf >= 2) {
			const dm::Body *body = w.body(id);
			size_t k = 0;
			for (; k < feed.hits.size(); k++) {
				if (feed.hits[k].id == id) {
					break;
				}
			}
			if (k == feed.hits.size()) {
				dm::CrowdHit h;
				h.id = id;
				h.max_hp = body != nullptr ? float(body->max_hp) : 1.0f;
				feed.hits.push_back(h);
			}
			feed.hits[k].amount += ev.floats[f];
			feed.hits[k].hp = ev.floats[f + 1];
		}
		i += 4 + size_t(ni);
		f += size_t(nf);
	}
	ev_i = i;
	ev_f = f;
	for (const dm::Corpse &c : w.corpses) {
		const Look &look = (c.def >= 0 && size_t(c.def) < def_looks.size()) ? def_looks[size_t(c.def)] : risen_look;
		if (look.model < 0) {
			continue;
		}
		dm::CrowdCorpse r;
		r.id = c.id;
		r.model = look.model;
		r.def = c.def;
		r.x = float(c.x);
		r.z = float(c.z);
		r.facing = float(c.facing);
		r.scale = float(c.scale);
		r.tint[0] = look.tint[0];
		r.tint[1] = look.tint[1];
		r.tint[2] = look.tint[2];
		r.glow = enemy_glow(look, c.elite, look.has_fen && c.area == fen);  // the corpse keeps the body's glow, as today's body did
		feed.corpses.push_back(r);
	}
	view.tick(feed);
}

void DmCrowd::sync_rows(const PackedInt32Array &p_body_ints, const PackedFloat32Array &p_body_floats, const PackedFloat32Array &p_hits, const PackedInt32Array &p_corpse_ints,
		const PackedFloat32Array &p_corpse_floats) {
	constexpr int64_t BI = 8, BF = 11, HF = 4, CI = 4, CF = 7;
	feed.clear();
	const int64_t nb = std::min(p_body_ints.size() / BI, p_body_floats.size() / BF);
	for (int64_t i = 0; i < nb; i++) {
		dm::CrowdBody b;
		b.id = p_body_ints[i * BI];
		b.kind = p_body_ints[i * BI + 1];
		b.model = p_body_ints[i * BI + 2];
		b.state = p_body_ints[i * BI + 3];
		b.flags = p_body_ints[i * BI + 4];
		b.swing = p_body_ints[i * BI + 5];
		b.def = p_body_ints[i * BI + 6];
		b.glow = p_body_ints[i * BI + 7];
		const float *f = p_body_floats.ptr() + i * BF;
		b.x = f[0];
		b.z = f[1];
		b.yaw = f[2];
		b.speed = f[3];
		b.state_t = f[4];
		b.action_s = f[5];
		b.scale = f[6];
		b.hover = f[7];
		b.tint[0] = f[8];
		b.tint[1] = f[9];
		b.tint[2] = f[10];
		feed.bodies.push_back(b);
	}
	for (int64_t i = 0; i + HF <= p_hits.size(); i += HF) {
		dm::CrowdHit h;
		h.id = int32_t(p_hits[i]);
		h.amount = p_hits[i + 1];
		h.hp = p_hits[i + 2];
		h.max_hp = p_hits[i + 3];
		feed.hits.push_back(h);
	}
	const int64_t nc = std::min(p_corpse_ints.size() / CI, p_corpse_floats.size() / CF);
	for (int64_t i = 0; i < nc; i++) {
		dm::CrowdCorpse c;
		c.id = p_corpse_ints[i * CI];
		c.model = p_corpse_ints[i * CI + 1];
		c.def = p_corpse_ints[i * CI + 2];
		c.glow = p_corpse_ints[i * CI + 3];
		const float *f = p_corpse_floats.ptr() + i * CF;
		c.x = f[0];
		c.z = f[1];
		c.facing = f[2];
		c.scale = f[3];
		c.tint[0] = f[4];
		c.tint[1] = f[5];
		c.tint[2] = f[6];
		feed.corpses.push_back(c);
	}
	view.tick(feed);
}

// ---------------------------------------------------------------------------------------------------------------- the frame

void DmCrowd::draw(double p_dt, double p_alpha, const Vector3 &p_camera) {
	view.draw(p_dt, p_alpha, p_camera.x, p_camera.y, p_camera.z);
	RenderingServer *rs = RenderingServer::get_singleton();
	if (rs == nullptr) {
		return;
	}
	for (int32_t gi = 0; gi < view.group_count(); gi++) {
		const dm::CrowdGroup &g = view.group(gi);
		GroupRid &r = rids[size_t(gi)];
		if (!r.rid.is_valid() || g.cap == 0) {
			continue;
		}
		if (g.cap != r.cap) {  // a larger crowd than ever before: the MultiMesh grows (rare; the buffer must match its size exactly)
			rs->multimesh_allocate_data(r.rid, g.cap, RenderingServer::MULTIMESH_TRANSFORM_3D, true, true);
			r.packed.resize(int64_t(g.cap) * dm::STRIDE);
			r.cap = g.cap;
			r.last = -1;
		}
		if (g.count == 0 && r.last == 0) {
			continue;
		}
		if (g.count > 0) {
			std::memcpy(r.packed.ptrw(), g.buf.data(), size_t(g.count) * dm::STRIDE * sizeof(float));
			rs->multimesh_set_buffer(r.rid, r.packed);
		}
		rs->multimesh_set_visible_instances(r.rid, g.count);
		r.last = g.count;
	}
}

PackedFloat32Array DmCrowd::buffer(int64_t p_model, int64_t p_lod, bool p_shadow) const {
	PackedFloat32Array out;
	const int32_t gi = view.group_of(int32_t(p_model), int32_t(p_lod), p_shadow);
	if (gi < 0) {
		return out;
	}
	const dm::CrowdGroup &g = view.group(gi);
	out.resize(int64_t(g.count) * dm::STRIDE);
	if (g.count > 0) {
		std::memcpy(out.ptrw(), g.buf.data(), size_t(g.count) * dm::STRIDE * sizeof(float));
	}
	return out;
}

int64_t DmCrowd::instance_count(int64_t p_model, int64_t p_lod, bool p_shadow) const {
	const int32_t gi = view.group_of(int32_t(p_model), int32_t(p_lod), p_shadow);
	return gi < 0 ? 0 : view.group(gi).count;
}

Dictionary DmCrowd::stats() const {
	const dm::CrowdStats s = view.stats();
	Dictionary d;
	d["bodies"] = s.bodies;
	d["live"] = s.live;
	d["dying"] = s.dying;
	d["corpses"] = s.corpses;
	d["fading"] = s.fading;
	d["drawn"] = s.drawn;
	d["groups"] = s.groups;
	d["capacity_floats"] = s.capacity_floats;
	d["regrows"] = s.regrows;
	d["frames"] = s.frames;
	return d;
}

Dictionary DmCrowd::info_of(const dm::View *p_view) const {
	Dictionary d;
	if (p_view == nullptr) {
		return d;
	}
	const dm::View &v = *p_view;
	static const char *const MODES[4] = { "live", "dying", "corpse", "fading" };
	const dm::CrowdModel &m = view.model(v.model);
	d["id"] = v.id;
	d["kind"] = v.kind;
	d["mode"] = String(MODES[v.mode]);
	d["model"] = v.model;
	d["state"] = v.state;
	d["pos"] = Vector3(float(v.dx), float(v.dy), float(v.dz));
	d["sim_pos"] = Vector2(float(v.cx), float(v.cz));
	d["prev_pos"] = Vector2(float(v.px), float(v.pz));
	d["yaw"] = v.yaw;
	d["gs"] = v.gs;
	d["flash"] = v.flash;
	d["flash_v"] = v.flash_v;
	d["knock"] = Vector4(float(v.kx), float(v.kz), float(v.kvx), float(v.kvz));
	d["clip"] = v.cur >= 0 ? String(m.clip_names[size_t(v.cur)].c_str()) : String();
	d["clip_index"] = v.cur;
	d["time"] = v.t;
	d["speed"] = v.speed;
	d["prev_clip"] = v.prev >= 0 ? String(m.clip_names[size_t(v.prev)].c_str()) : String();
	d["prev_time"] = v.pt;
	d["blend"] = v.prev >= 0 && v.blend_d > 0.0 ? std::max(0.0, 1.0 - v.blend_t / v.blend_d) : 0.0;
	d["one_shot"] = v.one_shot >= 0 ? String(m.clip_names[size_t(v.one_shot)].c_str()) : String();
	d["one_end"] = v.one_end;
	d["loop"] = String(dm::ROLE_NAMES[v.loop_role]);
	d["toppled"] = v.toppled;
	d["die_t"] = v.die_t;
	d["rest_t"] = v.rest_t;
	d["sink_t"] = v.sink_t;
	d["settle_t"] = v.settle_t;
	d["has_settle"] = v.has_settle;
	d["shadow"] = v.shadow;
	d["hidden"] = v.hidden;
	d["scale"] = v.scale;
	d["rise_k"] = v.rise_k;
	d["pose"] = Vector4(float(v.pitch), float(v.roll), float(v.sq), float(v.zo));
	d["kick_t"] = v.kick_t;
	d["lunge_t"] = v.lunge_t;
	d["idle_k"] = v.idle_k;
	d["kick_amp"] = v.kick_amp;
	d["kick_side"] = v.kick_side;
	d["lunge_in"] = v.lunge_in;
	d["lunge_len"] = v.lunge_len;
	d["lunge_pitch"] = v.lunge_pitch;
	d["death_clip"] = v.death_clip >= 0 ? String(m.clip_names[size_t(v.death_clip)].c_str()) : String();
	return d;
}

// The rows of the last tick in sync_rows' layout: bodies as 8 ints (id, kind, model, state, flags, swing, def, glow) and 11 floats (x, z, yaw, speed,
// state_t, action_s, scale, hover, tint r, g, b); hits as 4 floats (id, amount, hp, max_hp); corpses as 4 ints (id, model, def, glow) and 7 floats
// (x, z, facing, scale, tint r, g, b). `glow` is a slot of this crowd's glow palette.
Dictionary DmCrowd::last_feed() const {
	PackedInt32Array bi, ci;
	PackedFloat32Array bf, hf, cf;
	for (const dm::CrowdBody &b : feed.bodies) {
		for (const int32_t v : { b.id, b.kind, b.model, b.state, b.flags, b.swing, b.def, b.glow }) {
			bi.push_back(v);
		}
		for (const float v : { b.x, b.z, b.yaw, b.speed, b.state_t, b.action_s, b.scale, b.hover, b.tint[0], b.tint[1], b.tint[2] }) {
			bf.push_back(v);
		}
	}
	for (const dm::CrowdHit &h : feed.hits) {
		for (const float v : { float(h.id), h.amount, h.hp, h.max_hp }) {
			hf.push_back(v);
		}
	}
	for (const dm::CrowdCorpse &c : feed.corpses) {
		for (const int32_t v : { c.id, c.model, c.def, c.glow }) {
			ci.push_back(v);
		}
		for (const float v : { c.x, c.z, c.facing, c.scale, c.tint[0], c.tint[1], c.tint[2] }) {
			cf.push_back(v);
		}
	}
	Dictionary d;
	d["body_ints"] = bi;
	d["body_floats"] = bf;
	d["hits"] = hf;
	d["corpse_ints"] = ci;
	d["corpse_floats"] = cf;
	return d;
}

Dictionary DmCrowd::view_info(int64_t p_id, bool p_corpse) const {
	return info_of(p_corpse ? view.find_corpse(int32_t(p_id)) : view.find(int32_t(p_id)));
}

// ---------------------------------------------------------------------------------------------------------------- today's pure helpers

double DmCrowd::turn_toward(double p_cur, double p_target, double p_dt, double p_rate, double p_max_rate) {
	return dm::CrowdView::turn_toward(p_cur, p_target, p_dt, p_rate, p_max_rate);
}

double DmCrowd::smooth_speed(double p_prev, double p_sample, double p_dt, double p_tau) {
	return dm::CrowdView::smooth_speed(p_prev, p_sample, p_dt, p_tau);
}

Vector2 DmCrowd::knock_impulse(double p_frac, double p_mass, double p_dx, double p_dz) {
	double x, z;
	dm::CrowdView::knock_impulse(p_frac, p_mass, p_dx, p_dz, x, z);
	return Vector2(float(x), float(z));
}

PackedFloat64Array DmCrowd::step_knock(const PackedFloat64Array &p_state, double p_dt) {
	PackedFloat64Array out = p_state;
	if (out.size() < 4) {
		out.resize(4);
	}
	double *w = out.ptrw();
	dm::CrowdView::step_knock(w[0], w[1], w[2], w[3], p_dt);
	return out;
}

double DmCrowd::settle_depth(double p_t, double p_depth, double p_dur) {
	return dm::CrowdView::settle_depth(p_t, p_depth, p_dur);
}

Dictionary DmCrowd::strike_timing(double p_duration, double p_impact, double p_impact_in, double p_follow) {
	double speed, start, end;
	dm::CrowdView::strike_timing(p_duration, p_impact, p_impact_in, p_follow, speed, start, end);
	Dictionary d;
	d["speed"] = speed;
	d["startAt"] = start;
	d["endAt"] = end;
	return d;
}
