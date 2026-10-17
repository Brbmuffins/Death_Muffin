#include "dm_decals.h"

#include <algorithm>
#include <cmath>
#include <limits>

#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include "dm_crowd.h"

using namespace godot;

// GDScript's minf, maxf and fposmod, as the engine writes them (the order of the operands decides what an equal pair or a NaN gives).
static inline double min_f(double a, double b) { return (a < b) ? a : b; }
static inline double max_f(double a, double b) { return (a > b) ? a : b; }
static inline double fposmod_f(double x, double y) {
	double value = std::fmod(x, y);
	if (((value < 0) && (y > 0)) || ((value > 0) && (y < 0))) {
		value += y;
	}
	value += 0.0;
	return value;
}

// The option names as StringNames, made once and never freed (a static StringName would be destroyed after the engine is gone).
struct DecalKeys {
	StringName layer{"layer"}, ring_layer{"ring_layer"}, tex{"tex"}, serial{"serial"}, color{"color"}, persistent{"persistent"}, via_ring{"via_ring"}, other{"other"}, settles{"settles"},
			has_outline{"has_outline"}, x{"x"}, z{"z"}, y{"y"}, rot{"rot"}, r{"r"}, sx{"sx"}, sz{"sz"}, grow_from{"growFrom"}, spin{"spin"}, pulse{"pulse"}, duration{"duration"},
			delay{"delay"}, base{"base"}, fade_in{"fadeIn"}, fade_out{"fadeOut"}, anchor{"anchor"}, ring_for_disc{"ring_for_disc"}, outline_at{"outline_at"},
			outline_fade{"outline_fade"}, sheet_rate{"sheet_rate"}, follow{"follow"}, follow_body{"follow_body"};
};

static const DecalKeys &keys() {
	static const DecalKeys *k = new DecalKeys();
	return *k;
}

static double num(const Dictionary &o, const StringName &key, double dflt) {
	return double(o.get(key, dflt));
}

void DmDecals::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_crowd", "crowd"), &DmDecals::set_crowd);
	ClassDB::bind_method(D_METHOD("bind_layer", "layer", "multimesh", "capacity"), &DmDecals::bind_layer);
	ClassDB::bind_method(D_METHOD("layer_demand", "layer"), &DmDecals::layer_demand);
	ClassDB::bind_method(D_METHOD("add", "options"), &DmDecals::add);
	ClassDB::bind_method(D_METHOD("alive", "handle"), &DmDecals::alive);
	ClassDB::bind_method(D_METHOD("kill", "handle"), &DmDecals::kill);
	ClassDB::bind_method(D_METHOD("np_count"), &DmDecals::np_count);
	ClassDB::bind_method(D_METHOD("oldest_np_serial"), &DmDecals::oldest_np_serial);
	ClassDB::bind_method(D_METHOD("evict_oldest_np"), &DmDecals::evict_oldest_np);
	ClassDB::bind_method(D_METHOD("step", "dt"), &DmDecals::step);
	ClassDB::bind_method(D_METHOD("clear"), &DmDecals::clear);
	ClassDB::bind_method(D_METHOD("buffer", "layer"), &DmDecals::buffer);
	ClassDB::bind_method(D_METHOD("drawn", "layer"), &DmDecals::drawn);
	ClassDB::bind_method(D_METHOD("item_of", "handle"), &DmDecals::item_of);
}

void DmDecals::set_crowd(Object *p_crowd) {
	crowd = Object::cast_to<DmCrowd>(p_crowd);
	crowd_id = crowd != nullptr ? crowd->get_instance_id() : 0;
}

void DmDecals::bind_layer(int32_t p_layer, const RID &p_multimesh, int32_t p_capacity) {
	if (p_layer < 0) {
		return;
	}
	if (int32_t(layers.size()) <= p_layer) {
		layers.resize(size_t(p_layer) + 1);
	}
	Layer &l = layers[size_t(p_layer)];
	l.rid = p_multimesh;
	l.cap = std::max(1, p_capacity);
	l.buf.resize(int64_t(l.cap) * 20);
	l.buf.fill(0.0f);
	l.shown = false;   // a new MultiMesh starts hidden: the next step draws the layer again if it holds anything
}

int32_t DmDecals::layer_demand(int32_t p_layer) const {
	if (p_layer < 0 || p_layer >= int32_t(layers.size())) {
		return 0;
	}
	return int32_t(layers[size_t(p_layer)].items.size()) + layers[size_t(p_layer)].reserved;
}

DmDecals::Decal *DmDecals::resolve(int64_t p_handle) {
	const int32_t slot = int32_t(p_handle & 0xffffffff);
	const uint32_t gen = uint32_t(p_handle >> 32);
	if (slot < 0 || slot >= int32_t(decals.size())) {
		return nullptr;
	}
	Decal &d = decals[size_t(slot)];
	return (d.used && d.gen == gen) ? &d : nullptr;
}

// DecalTr.place: the fixed offset from the followed point (the anchor), then the place itself (a followed body's, or what the callable says).
void DmDecals::place(Decal &d) {
	if (d.anchor != d.off_anchor) {
		d.off_anchor = d.anchor;
		d.off_x = std::sin(d.rot0) * d.anchor * (d.r2 * 0.5);
		d.off_z = std::cos(d.rot0) * d.anchor * (d.r2 * 0.5);
	}
	double x = d.x0;
	double z = d.z0;
	if (d.has_follow) {
		if (d.follow_body > 0 && crowd != nullptr) {
			const Vector3 p = crowd->ground_at(d.follow_body);
			d.hidden = std::isinf(p.x);
			if (!d.hidden) {
				x = p.x;
				z = p.z;
			}
		} else if (d.follow_fn.is_valid()) {
			const Variant f = d.follow_fn.callv(Array());
			d.hidden = f.get_type() == Variant::NIL;
			if (f.get_type() == Variant::VECTOR3) {
				const Vector3 p = f;
				x = p.x;
				z = p.z;
			}
		} else {
			d.hidden = true;
		}
	}
	d.x = x + d.off_x;
	d.y = d.base_y;
	d.z = z + d.off_z;
}

// DecalTr.update(t_, k, dt), statement for statement.
void DmDecals::update(Decal &d, double t_, double k) {
	if (t_ < 0.0) {
		d.opacity = 0.0;
		return;
	}
	d.t_now = t_;
	if (d.ended) {
		return;
	}
	if (d.sheet_rate >= 0.0) {
		d.frame = d.sheet_rate > 0.0 ? fposmod_f(t_ * d.sheet_rate, 1.0) : k;
	}
	if (d.has_follow) {
		place(d);
	}
	double grow = 1.0;
	if (d.has_grow) {
		grow = d.grow_from + (1.0 - d.grow_from) * min_f(1.0, k * 1.2);
	}
	const double s = d.r2 * grow;
	d.sx = s * d.mul_x;
	d.sz = s * d.mul_z;
	const double rs = (d.via_ring && d.other) ? d.ring_for_disc : 1.0;
	if (rs != 1.0) {
		d.sx *= rs;
		d.sz *= rs;
	}
	if (d.spin_k != 0.0) {
		d.rot_y = d.rot0 + d.spin_k * t_;
	}
	const double in_a = d.fade_in > 0.0 ? min_f(1.0, t_ / d.fade_in) : 1.0;
	const double out_a = d.fade_out > 0.0 ? min_f(1.0, (d.duration - t_) / d.fade_out) : 1.0;
	double pulse = 1.0;
	if (d.pulse_k != 0.0) {
		pulse = 0.75 + 0.25 * std::sin(t_ * d.pulse_k);
	}
	double op = d.hidden ? 0.0 : d.base * max_f(0.0, min_f(in_a, out_a)) * pulse;
	if (d.other && d.has_outline) {
		d.rim = 1.0;
	} else if (d.settles) {
		const double rim = max_f(0.0, min_f(1.0, (t_ - d.outline_at) / d.outline_fade));
		d.rim = rim;
		if (d.pulse_k == 0.0 && rim > 0.0) {
			pulse *= 1.0 - 0.18 * rim * (0.5 + 0.5 * std::sin(t_ * 2.2 + d.x0));
		}
		op = d.hidden ? 0.0 : d.base * max_f(0.0, min_f(in_a, out_a)) * pulse;
		if (rim > 0.0 && d.via_ring) {
			if (!d.ring_on) {
				d.ring_on = true;
				if (d.ring_layer >= 0 && d.ring_layer < int32_t(layers.size())) {
					layers[size_t(d.ring_layer)].items.push_back(d.slot | RING_BIT);
					layers[size_t(d.ring_layer)].reserved -= 1;   // the room kept for it is now its place
				}
			}
			d.rx = d.x;
			d.ry = d.y;
			d.rz = d.z;
			d.rsx = d.sx * d.ring_for_disc;
			d.rsz = d.sz * d.ring_for_disc;
			d.ropacity = op * rim;
			d.opacity = op * (1.0 - rim);
			return;
		}
	}
	d.opacity = op;
}

// DecalTr.release: the decal leaves its layer (and its ring leaves the ring layer) and its slot is free again.
void DmDecals::release(int32_t p_slot) {
	Decal &d = decals[size_t(p_slot)];
	if (!d.used) {
		return;
	}
	d.ended = true;
	order.erase(std::remove(order.begin(), order.end(), p_slot), order.end());
	if (d.layer >= 0 && d.layer < int32_t(layers.size())) {
		std::vector<int32_t> &it = layers[size_t(d.layer)].items;
		it.erase(std::remove(it.begin(), it.end(), p_slot), it.end());
	}
	if (d.ring_on) {
		if (d.ring_layer >= 0 && d.ring_layer < int32_t(layers.size())) {
			std::vector<int32_t> &it = layers[size_t(d.ring_layer)].items;
			it.erase(std::remove(it.begin(), it.end(), p_slot | RING_BIT), it.end());
		}
	} else if (d.via_ring && d.settles && d.ring_layer >= 0 && d.ring_layer < int32_t(layers.size())) {
		layers[size_t(d.ring_layer)].reserved -= 1;   // the ring never came
	}
	if (!d.persistent) {
		live_np -= 1;
	}
	d.used = false;
	d.follow_fn = Callable();
	free_slots.push_back(p_slot);
}

// DmFxPrims.decal: one decal from the options the effects layer worked out (client/fx/dm_fx_prims.gd), placed and updated once as `_add` did.
int64_t DmDecals::add(const Dictionary &p_o) {
	const DecalKeys &k = keys();
	int32_t slot;
	if (!free_slots.empty()) {
		slot = free_slots.back();
		free_slots.pop_back();
	} else {
		slot = int32_t(decals.size());
		decals.emplace_back();
	}
	Decal &d = decals[size_t(slot)];
	const uint32_t gen = d.gen + 1;
	d = Decal();
	d.gen = gen;
	d.slot = slot;
	d.used = true;
	d.serial = int64_t(num(p_o, k.serial, 0.0));
	d.layer = int32_t(num(p_o, k.layer, -1.0));
	d.ring_layer = int32_t(num(p_o, k.ring_layer, -1.0));
	const std::string tname = String(p_o.get(k.tex, String("disc"))).utf8().get_data();
	auto it = tex_ids.find(tname);
	if (it == tex_ids.end()) {
		it = tex_ids.emplace(tname, int32_t(tex_ids.size())).first;
	}
	d.tex = it->second;
	d.persistent = bool(p_o.get(k.persistent, false));
	d.via_ring = bool(p_o.get(k.via_ring, false));
	d.other = bool(p_o.get(k.other, false));
	d.settles = bool(p_o.get(k.settles, false));
	d.has_outline = bool(p_o.get(k.has_outline, false));
	const Color col = p_o.get(k.color, Color(1, 1, 1, 1));
	d.cr = col.r;
	d.cg = col.g;
	d.cb = col.b;
	// DecalTr.setup
	d.has_grow = p_o.has(k.grow_from);
	d.grow_from = d.has_grow ? num(p_o, k.grow_from, 0.0) : 0.0;
	d.r2 = num(p_o, k.r, 0.0) * 2.0;
	d.mul_x = num(p_o, k.sx, 1.0);
	d.mul_z = num(p_o, k.sz, 1.0);
	d.spin_k = num(p_o, k.spin, 0.0);
	d.rot0 = num(p_o, k.rot, 0.0);
	d.pulse_k = num(p_o, k.pulse, 0.0);
	d.x0 = num(p_o, k.x, 0.0);
	d.z0 = num(p_o, k.z, 0.0);
	d.base_y = num(p_o, k.y, 0.04);
	d.rot_y = d.rot0;
	d.duration = num(p_o, k.duration, 1.0);
	d.base = num(p_o, k.base, 1.0);
	d.fade_in = num(p_o, k.fade_in, 0.12);
	d.fade_out = num(p_o, k.fade_out, 0.25);
	d.anchor = num(p_o, k.anchor, 0.0);
	d.ring_for_disc = num(p_o, k.ring_for_disc, 1.32);
	d.outline_at = num(p_o, k.outline_at, 0.6);
	d.outline_fade = num(p_o, k.outline_fade, 0.7);
	d.sheet_rate = num(p_o, k.sheet_rate, -1.0);
	d.entry_r = d.r2 * 0.5;
	d.follow_body = int64_t(num(p_o, k.follow_body, 0.0));
	if (d.follow_body > 0) {
		d.has_follow = true;
	} else if (p_o.has(k.follow)) {
		const Variant f = p_o.get(k.follow, Variant());
		if (f.get_type() == Variant::CALLABLE) {
			d.follow_fn = f;
			d.has_follow = true;
		}
	}
	d.t = -num(p_o, k.delay, 0.0);
	order.push_back(slot);
	place(d);   // (the entry of a settling decal is where it stands now)
	d.entry_x = d.x;
	d.entry_z = d.z;
	// Settling decals shape each other's outline: a new one near an older one of the same texture brings the older one's rim forward (DmFxPrims.decal's _own_areas).
	if (d.settles) {
		const double r = d.entry_r;
		for (Decal &a : decals) {
			if (a.slot == slot || !a.used || !a.in_entries || a.tex != d.tex) {
				continue;
			}
			const float dx = float(a.entry_x - d.x);   // Vector2(a.x - x, a.z - z).length(): floats all the way
			const float dz = float(a.entry_z - d.z);
			if (double(std::sqrt(dx * dx + dz * dz)) < max_f(a.entry_r, r)) {
				a.outline_at = min_f(a.outline_at, a.t_now);
				a.outline_fade = min_f(a.outline_fade, 0.4);
			}
		}
		d.in_entries = true;
	}
	if (d.layer >= 0 && d.layer < int32_t(layers.size())) {
		layers[size_t(d.layer)].items.push_back(slot);
	}
	if (d.via_ring && d.settles && d.ring_layer >= 0 && d.ring_layer < int32_t(layers.size())) {
		layers[size_t(d.ring_layer)].reserved += 1;
	}
	if (!d.persistent) {
		live_np += 1;
	}
	update(d, d.t, d.t / d.duration);
	return make_handle(slot, gen);
}

bool DmDecals::alive(int64_t p_handle) {
	const Decal *d = resolve(p_handle);
	return d != nullptr && d->t < d->duration;
}

void DmDecals::kill(int64_t p_handle) {
	Decal *d = resolve(p_handle);
	if (d != nullptr) {
		d->t = d->duration;
	}
}

int64_t DmDecals::oldest_np_serial() const {
	int64_t best = -1;
	for (const Decal &d : decals) {
		if (d.used && !d.persistent && (best < 0 || d.serial < best)) {
			best = d.serial;
		}
	}
	return best;
}

// The cap's eviction (DmFxPrims._add): the oldest decal that counts leaves now.
void DmDecals::evict_oldest_np() {
	int32_t pick = -1;
	for (int32_t s = 0; s < int32_t(decals.size()); s++) {
		const Decal &d = decals[size_t(s)];
		if (d.used && !d.persistent && (pick < 0 || d.serial < decals[size_t(pick)].serial)) {
			pick = s;
		}
	}
	if (pick >= 0) {
		decals[size_t(pick)].t = decals[size_t(pick)].duration;
		release(pick);
	}
}

// DmFxLayer.flush for a decal layer: the items in order, those with opacity above zero written 20 floats each.
int32_t DmDecals::fill(Layer &l) {
	float *b = l.buf.ptrw();
	int32_t n = 0;
	for (const int32_t ref : l.items) {
		if (n >= l.cap) {
			break;
		}
		const bool ring = (ref & RING_BIT) != 0;
		Decal &d = decals[size_t(ref & ~RING_BIT)];
		double x, y, z, sx, sz, opacity, rim, frame, s, c;
		if (ring) {
			if (d.ropacity <= 0.0) {
				continue;
			}
			x = d.rx;
			y = d.ry;
			z = d.rz;
			sx = d.rsx;
			sz = d.rsz;
			opacity = d.ropacity;
			rim = 0.0;
			frame = 0.0;
			s = 0.0;
			c = 1.0;
		} else {
			if (d.opacity <= 0.0) {
				continue;
			}
			if (!d.rot_known || d.rot_y != d.rot_seen) {   // most decals never spin: sin / cos once, not every frame
				d.rot_known = true;
				d.rot_seen = d.rot_y;
				d.rot_s = std::sin(d.rot_y);
				d.rot_c = std::cos(d.rot_y);
			}
			x = d.x;
			y = d.y;
			z = d.z;
			sx = d.sx;
			sz = d.sz;
			opacity = d.opacity;
			rim = d.rim;
			frame = d.frame;
			s = d.rot_s;
			c = d.rot_c;
		}
		float *o = b + int64_t(n) * 20;
		o[0] = float(c * sx);
		o[2] = float(s * sz);
		o[3] = float(x);
		o[5] = 1.0f;
		o[7] = float(y);
		o[8] = float(-s * sx);
		o[10] = float(c * sz);
		o[11] = float(z);
		o[12] = d.cr;
		o[13] = d.cg;
		o[14] = d.cb;
		o[15] = 1.0f;
		o[16] = float(opacity);
		o[17] = float(rim);
		o[18] = float(frame);
		n += 1;
	}
	return n;
}

PackedInt32Array DmDecals::step(double p_dt) {
	if (crowd != nullptr && UtilityFunctions::instance_from_id(int64_t(crowd_id)) == nullptr) {
		crowd = nullptr;   // the game that owned it is gone: its decals follow nothing now
	}
	for (int32_t i = int32_t(order.size()) - 1; i >= 0; i--) {   // newest first: the order the effects layer went through its transients (a ring joins its layer in that order)
		if (i >= int32_t(order.size())) {
			continue;   // (a follow callable made or ended decals)
		}
		const int32_t s = order[size_t(i)];
		Decal &d = decals[size_t(s)];
		d.t += p_dt;
		if (d.t >= d.duration) {
			release(s);   // takes it out of `order`: the next one down is at i - 1 still
			continue;
		}
		update(d, d.t, d.t / d.duration);
	}
	out.clear();
	RenderingServer *rs = RenderingServer::get_singleton();
	for (int32_t li = 0; li < int32_t(layers.size()); li++) {
		Layer &l = layers[size_t(li)];
		if (l.items.empty() && !l.shown) {
			continue;
		}
		const int32_t n = l.items.empty() ? 0 : fill(l);
		l.drawn = n;
		if (n > 0) {
			rs->multimesh_set_buffer(l.rid, l.buf);   // (the layer sets the MultiMesh's visible count itself: the resource keeps its own copy of it)
			l.shown = true;
			out.push_back(li);
			out.push_back(n);
		} else if (l.shown) {
			l.shown = false;
			out.push_back(li);
			out.push_back(0);
		}
	}
	return out;
}

void DmDecals::clear() {
	for (int32_t s = 0; s < int32_t(decals.size()); s++) {
		if (decals[size_t(s)].used) {
			release(s);
		}
	}
}

PackedFloat32Array DmDecals::buffer(int32_t p_layer) const {
	if (p_layer < 0 || p_layer >= int32_t(layers.size())) {
		return PackedFloat32Array();
	}
	return layers[size_t(p_layer)].buf;
}

int32_t DmDecals::drawn(int32_t p_layer) const {
	if (p_layer < 0 || p_layer >= int32_t(layers.size())) {
		return 0;
	}
	return layers[size_t(p_layer)].drawn;
}

Dictionary DmDecals::item_of(int64_t p_handle) {
	Dictionary r;
	const Decal *d = resolve(p_handle);
	if (d == nullptr) {
		return r;
	}
	r["x"] = d->x;
	r["y"] = d->y;
	r["z"] = d->z;
	r["rot_y"] = d->rot_y;
	r["sx"] = d->sx;
	r["sz"] = d->sz;
	r["opacity"] = d->opacity;
	r["rim"] = d->rim;
	r["frame"] = d->frame;
	r["outline_at"] = d->outline_at;
	r["outline_fade"] = d->outline_fade;
	r["ring_on"] = d->ring_on;
	return r;
}
