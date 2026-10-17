#pragma once
// DmDecals: the ground decals of the effects layer in C++ (client/fx/dm_fx_prims.gd's DecalTr and the DECAL half of client/fx/dm_fx_layer.gd, ported from godot/fx).
// A decal is a record here, not two GDScript objects: `step` ages every decal, works out what it looks like now (size, turn, opacity, outline, where it follows) with the
// arithmetic of DecalTr.update, operation for operation in doubles, and writes each layer's instance buffer (20 floats an instance: transform, tint, opacity / outline /
// flipbook frame) and hands it to the RenderingServer. The effects layer (GDScript) still decides what a decal is made of, owns the layers' MultiMeshes and their nodes,
// and keeps every other transient (flashes, beams, orbits, spikes); client/tests/fx_decals.gd compares the buffers with today's GDScript frame by frame.
#include <cstdint>
#include <deque>
#include <string>
#include <unordered_map>
#include <vector>

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/callable.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/rid.hpp>

class DmCrowd;

class DmDecals : public godot::RefCounted {
	GDCLASS(DmDecals, godot::RefCounted)

	struct Decal {
		bool used = false;
		uint32_t gen = 0;
		int32_t slot = 0;
		int64_t serial = 0;           // creation order across every kind of transient (the cap evicts the oldest)
		int32_t layer = -1, ring_layer = -1, tex = 0;
		bool persistent = false, via_ring = false, other = false, settles = false, has_outline = false, has_grow = false, ended = false, hidden = false;
		bool has_follow = false, ring_on = false, in_entries = false;
		double t = 0, duration = 1, t_now = 0;
		double grow_from = 0, r2 = 0, mul_x = 1, mul_z = 1, spin_k = 0, rot0 = 0, pulse_k = 0, x0 = 0, z0 = 0, base_y = 0.04;
		double anchor = 0, off_anchor = 0, off_x = 0, off_z = 0;
		double base = 1, fade_in = 0.12, fade_out = 0.25, outline_at = 0.6, outline_fade = 0.7, ring_for_disc = 1.32, sheet_rate = -1;
		double entry_r = 0, entry_x = 0, entry_z = 0; // a settling decal's radius and where it was made, for the overlap rule
		godot::Callable follow_fn;
		int64_t follow_body = 0;                      // > 0: follows the crowd's body with this id (DmCrowd.ground_at) instead of calling follow_fn
		// The decal's item as DmFxLayer.Item held it: place, size, turn, tint, opacity, outline, flipbook frame.
		double x = 0, y = 0, z = 0, rot_y = 0, sx = 0, sz = 0, opacity = 0, rim = 0, frame = 0;
		float cr = 1, cg = 1, cb = 1;
		double rot_seen = 0;
		bool rot_known = false;
		double rot_s = 0, rot_c = 1;
		// The second item of a settling decal (its ring, drawn in `ring_layer`).
		double rx = 0, ry = 0, rz = 0, rsx = 0, rsz = 0, ropacity = 0;
	};

	struct Layer {
		godot::RID rid;
		int32_t cap = 0;
		godot::PackedFloat32Array buf;       // cap * 20
		std::vector<int32_t> items;          // the layer's items in the order they came: a decal slot, or slot | RING_BIT for a settling decal's ring
		int32_t reserved = 0;                // rings that may still appear in this layer (settling decals aimed at it): room is kept for them
		bool shown = false;
		int32_t drawn = 0;                   // instances the last step wrote
	};

	static constexpr int32_t RING_BIT = 1 << 30;

	std::deque<Decal> decals;   // (a deque: a record stays where it is when another is made, e.g. by a follow callable that spawns one)
	std::vector<int32_t> free_slots;
	std::vector<int32_t> order;                // the live decals' slots in the order they were made (a step goes through them backwards, as the effects layer went through its transients)
	std::vector<Layer> layers;
	std::unordered_map<std::string, int32_t> tex_ids;
	DmCrowd *crowd = nullptr;
	uint64_t crowd_id = 0;                   // (checked each step: a crowd that is freed is let go)
	int32_t live_np = 0;                     // decals alive that count toward the combat cap (not persistent)
	godot::PackedInt32Array out;

	static int64_t make_handle(int32_t p_slot, uint32_t p_gen) { return (int64_t(p_gen) << 32) | int64_t(uint32_t(p_slot)); }
	Decal *resolve(int64_t p_handle);
	void place(Decal &d);
	void update(Decal &d, double t_, double k);
	void release(int32_t p_slot);
	int32_t fill(Layer &l);

protected:
	static void _bind_methods();

public:
	void set_crowd(godot::Object *p_crowd);
	void bind_layer(int32_t p_layer, const godot::RID &p_multimesh, int32_t p_capacity);
	int32_t layer_demand(int32_t p_layer) const;                       // items now plus the rings that may still come: the layer needs this many instances
	int64_t add(const godot::Dictionary &p_o);
	bool alive(int64_t p_handle);
	void kill(int64_t p_handle);
	int32_t np_count() const { return live_np; }
	int64_t oldest_np_serial() const;                                    // the creation serial of the oldest decal that counts toward the cap, -1 when there is none
	void evict_oldest_np();
	godot::PackedInt32Array step(double p_dt);                           // layer, drawn count pairs for the layers drawn this step or emptied by it (count 0)
	void clear();
	godot::PackedFloat32Array buffer(int32_t p_layer) const;
	int32_t drawn(int32_t p_layer) const;                                // the instances the last step wrote into the layer's buffer
	godot::Dictionary item_of(int64_t p_handle);                         // a decal's item as the last step left it (tests)
};
