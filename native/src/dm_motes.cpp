#include "dm_motes.h"

#include <algorithm>

#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

using namespace godot;

static const double MOTE_PI = 3.1415926535897932384626433833;  // GDScript's PI and TAU (the engine's Math_PI and Math_TAU)
static const double MOTE_TAU = 6.2831853071795864769252867666;

void DmMotes::_bind_methods() {
	ClassDB::bind_method(D_METHOD("setup", "capacity", "small_cap"), &DmMotes::setup);
	ClassDB::bind_method(D_METHOD("emit", "options"), &DmMotes::emit);
	ClassDB::bind_method(D_METHOD("put", "pos", "vel", "color", "life", "size", "gravity", "drag", "shrink"), &DmMotes::put);
	ClassDB::bind_method(D_METHOD("active"), &DmMotes::active);
	ClassDB::bind_method(D_METHOD("step", "dt", "small"), &DmMotes::step);
	ClassDB::bind_method(D_METHOD("upload", "multimesh", "small"), &DmMotes::upload);
	ClassDB::bind_method(D_METHOD("buffer", "small"), &DmMotes::buffer);
}

void DmMotes::setup(int32_t p_capacity, int32_t p_small_cap) {
	capacity = std::max(1, p_capacity);
	small_cap = std::max(0, p_small_cap);
	cursor = 0;
	live = 0;
	pos.assign(capacity * 3, 0.0f);
	vel.assign(capacity * 3, 0.0f);
	col.assign(capacity * 3, 0.0f);
	life.assign(capacity, 0.0f);
	inv_life.assign(capacity, 0.0f);
	base_size.assign(capacity, 0.0f);
	grav.assign(capacity, 0.0f);
	drag.assign(capacity, 0.0f);
	shrink.assign(capacity, 0.0f);
	list.clear();
	list.reserve(capacity);
	buf_full.resize(capacity * 16);
	buf_full.fill(0.0f);
	buf_small.resize(small_cap * 16);
	buf_small.fill(0.0f);
}

// DmFxData.to_color: a Color as it is, an int (0xRRGGBB) as sRGB, an array of three or four numbers, else white.
static Color mote_color(const Variant &p_v) {
	switch (p_v.get_type()) {
		case Variant::COLOR:
			return Color(p_v);
		case Variant::INT:
		case Variant::FLOAT: {
			const int64_t c = int64_t(p_v);
			return Color(float(double((c >> 16) & 255) / 255.0), float(double((c >> 8) & 255) / 255.0), float(double(c & 255) / 255.0), 1.0f);
		}
		case Variant::ARRAY: {
			const Array a = p_v;
			if (a.size() >= 3) {
				return Color(float(double(a[0])), float(double(a[1])), float(double(a[2])), a.size() > 3 ? float(double(a[3])) : 1.0f);
			}
			break;
		}
		default:
			break;
	}
	return Color(1.0f, 1.0f, 1.0f, 1.0f);
}

// The option names as StringNames, made once: a Dictionary lookup with a String built from a literal hashes and compares text every time.
struct MoteKeys {
	StringName count{"count"}, color{"color"}, spread{"spread"}, speed{"speed"}, up{"up"}, life{"life"}, size{"size"}, gravity{"gravity"}, drag{"drag"}, shrink{"shrink"}, inward{"inward"}, x{"x"}, y{"y"}, z{"z"};
};

static const MoteKeys &mote_keys() {
	static const MoteKeys *keys = new MoteKeys();   // (never freed: a static StringName would be destroyed after the engine is gone)
	return *keys;
}

static double mote_num(const Dictionary &p_o, const StringName &p_key, double p_default) {
	return double(p_o.get(p_key, p_default));
}

// DmFxRing.emit (today's godot/fx/dm_fx_ring.gd, Effects.ts EmitOptions): o has x y z count color spread speed up life size gravity drag shrink inward, each with today's default. The
// randf calls come in the order the GDScript made them (a, radius, height, speed, [heading], climb, life, size), each its own statement: the arguments of a call are not evaluated in a fixed order here.
int64_t DmMotes::emit(const Dictionary &p_o) {
	const MoteKeys &k = mote_keys();
	const int64_t count = int64_t(mote_num(p_o, k.count, 0.0));
	if (count <= 0) {
		return 0;
	}
	const Color c = mote_color(p_o.get(k.color, Color(1.0f, 1.0f, 1.0f, 1.0f)));
	const double spread = mote_num(p_o, k.spread, 0.2);
	const double speed = mote_num(p_o, k.speed, 1.0);
	const double up = mote_num(p_o, k.up, 0.5);
	const double life_s = mote_num(p_o, k.life, 0.8);
	const double size = mote_num(p_o, k.size, 0.3);
	const double gravity = mote_num(p_o, k.gravity, 0.0);
	const double drag_k = mote_num(p_o, k.drag, 1.5);
	const double shrink_k = mote_num(p_o, k.shrink, 1.0);
	const bool inward = bool(p_o.get(k.inward, false));
	const double ox = mote_num(p_o, k.x, 0.0);
	const double oy = mote_num(p_o, k.y, 0.0);
	const double oz = mote_num(p_o, k.z, 0.0);
	for (int64_t n = 0; n < count; n++) {
		const double a = UtilityFunctions::randf() * MOTE_TAU;
		const double r = spread * std::sqrt(UtilityFunctions::randf());
		const double px = ox + std::cos(a) * r;
		const double py = oy + (UtilityFunctions::randf() - 0.5) * spread * 0.5;
		const double pz = oz + std::sin(a) * r;
		const double sp = speed * (0.4 + UtilityFunctions::randf() * 0.8);
		double va;
		if (inward) {
			va = a + MOTE_PI;
		} else {
			va = UtilityFunctions::randf() * MOTE_TAU;
		}
		const double vy = up * (0.5 + UtilityFunctions::randf());
		const double l = life_s * (0.7 + UtilityFunctions::randf() * 0.6);
		const double sz = size * (0.7 + UtilityFunctions::randf() * 0.6);
		put(Vector3(float(px), float(py), float(pz)), Vector3(float(std::cos(va) * sp), float(vy), float(std::sin(va) * sp)), c, l, sz, gravity, drag_k, shrink_k);
	}
	return count;
}

// One mote at the ring's cursor (the oldest is overwritten when the ring is full), as DmFxRing.emit wrote it: the caller made its random start.
void DmMotes::put(const Vector3 &p_pos, const Vector3 &p_vel, const Color &p_color, double p_life, double p_size, double p_gravity, double p_drag, double p_shrink) {
	if (capacity <= 0) {
		return;
	}
	const int32_t i = cursor;
	cursor = (cursor + 1) % capacity;
	if (life[i] <= 0.0f) {
		live += 1;
		list.push_back(i);
	}
	pos[i * 3] = p_pos.x;
	pos[i * 3 + 1] = p_pos.y;
	pos[i * 3 + 2] = p_pos.z;
	vel[i * 3] = p_vel.x;
	vel[i * 3 + 1] = p_vel.y;
	vel[i * 3 + 2] = p_vel.z;
	life[i] = float(p_life);
	inv_life[i] = float(1.0 / p_life);
	base_size[i] = float(p_size);
	grav[i] = float(p_gravity);
	drag[i] = float(p_drag);
	shrink[i] = float(p_shrink);
	col[i * 3] = p_color.r;
	col[i * 3 + 1] = p_color.g;
	col[i * 3 + 2] = p_color.b;
}

// DmFxRing.update's loop: GDScript computed in doubles and stored floats; the same here, operation for operation, so the buffers match exactly.
int32_t DmMotes::step(double p_dt, bool p_small) {
	PackedFloat32Array &buf = p_small ? buf_small : buf_full;
	float *b = buf.ptrw();
	const int32_t cap_n = p_small ? small_cap : capacity;
	int32_t n = 0;
	int32_t kept = 0;
	const int32_t count = int32_t(list.size());
	for (int32_t idx = 0; idx < count; idx++) {
		const int32_t i = list[idx];
		const double l = double(life[i]) - p_dt;
		life[i] = float(l);
		if (l <= 0.0) {
			live -= 1;
			continue;
		}
		list[kept] = i;
		kept += 1;
		const double t = 1.0 - l * double(inv_life[i]);
		const double k = std::max(0.0, 1.0 - double(drag[i]) * p_dt);
		const int32_t p3 = i * 3;
		const double vx = double(vel[p3]) * k;
		const double vy = double(vel[p3 + 1]) * k - double(grav[i]) * p_dt;
		const double vz = double(vel[p3 + 2]) * k;
		vel[p3] = float(vx);
		vel[p3 + 1] = float(vy);
		vel[p3 + 2] = float(vz);
		const double px = double(pos[p3]) + vx * p_dt;
		const double py = double(pos[p3 + 1]) + vy * p_dt;
		const double pz = double(pos[p3 + 2]) + vz * p_dt;
		pos[p3] = float(px);
		pos[p3 + 1] = float(py);
		pos[p3 + 2] = float(pz);
		const double alpha = t < 0.15 ? t / 0.15 : 1.0 - (t - 0.15) / 0.85;
		const double sh = double(shrink[i]);
		const double size = double(base_size[i]) * (sh >= 0.0 ? (1.0 - sh * t * 0.7) : (1.0 + -sh * t));
		if (alpha < 0.004 || n >= cap_n) {
			continue;
		}
		float *o = b + n * 16;
		o[0] = float(size);
		o[3] = float(px);
		o[5] = float(size);
		o[7] = float(py);
		o[10] = float(size);
		o[11] = float(pz);
		o[12] = col[p3];
		o[13] = col[p3 + 1];
		o[14] = col[p3 + 2];
		o[15] = float(alpha);
		n += 1;
	}
	list.resize(kept);
	return n;
}

void DmMotes::upload(const RID &p_multimesh, bool p_small) {
	RenderingServer::get_singleton()->multimesh_set_buffer(p_multimesh, p_small ? buf_small : buf_full);
}
