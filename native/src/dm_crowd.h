#pragma once
// Godot-facing API of the crowd's presentation (native/README.md "Drawing", client/crowd/README.md "Driving the crowd"): DmCrowd reads the
// combat core's tables once per tick (`sync`), and writes the instance buffer of every creature model's MultiMeshes once per rendered frame
// (`draw`). All the view logic is in core/crowd_view.*; this class resolves looks, turns the core's tables into the feed and talks to the
// RenderingServer.
#include <unordered_map>
#include <vector>

#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/rid.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <godot_cpp/variant/vector4.hpp>

#include "core/crowd_view.h"
#include "core/world.h"

class DmCore;

class DmCrowd : public godot::RefCounted {
	GDCLASS(DmCrowd, godot::RefCounted)

	// What an enemy def or a thrall kind is drawn as (CrowdView builds these from client/crowd/crowd_looks.json).
	struct Look {
		int32_t model = -1, flags = 0;
		float hover = 0, scale = 1;
		float tint[3] = { 1, 1, 1 }, tint_fen[3] = { 1, 1, 1 };
		bool has_fen = false, set = false;
	};
	struct GroupRid {
		godot::RID rid;
		int32_t cap = 0, last = -1;
		godot::PackedFloat32Array packed;
	};

	dm::CrowdView view;
	dm::CrowdFeed feed;
	std::unordered_map<std::string, Look> enemy_looks;
	std::vector<Look> def_looks;  // by the core's def index, rebuilt when looks or defs change
	Look risen_look;
	bool looks_dirty = true;
	std::vector<Look> thrall_looks;  // [kind * LEGION_SLOTS + legion + 1]
	std::unordered_map<int32_t, int32_t> owner_legion;
	std::vector<GroupRid> rids;  // parallel to the view's groups
	// the event buffer is read from where the last sync stopped (take_events clears it behind our back)
	size_t ev_i = 0, ev_f = 0;
	uint64_t ev_batches = 0;

	void rebuild_looks(const dm::World &p_world);
	const Look *thrall_look(int32_t p_kind, int32_t p_legion) const;
	void set_look(Look &r_look, const godot::Dictionary &p_look);
	godot::Dictionary info_of(const dm::View *p_view) const;

protected:
	static void _bind_methods();

public:
	DmCrowd();

	// Setup. A model's `data` (CrowdVatData.crowd_data()): slug, height, stride_walk, stride_run, clip_names, clip_seconds, clip_length, clip_impact,
	// clip_landing, clip_loop, roles. `lod_rids[i]` / `shadow_rids[i]`: the MultiMesh RIDs of level i without and with shadows; `lod_distances`:
	// the camera distances where levels 1.. start. Returns the model slot.
	int64_t add_model(const godot::String &p_slug, const godot::Dictionary &p_data, const godot::Array &p_lod_rids, const godot::Array &p_shadow_rids, const godot::PackedFloat32Array &p_lod_distances);
	// A look: model (slot), hover (m), scale, tint (linear Color), tint_fen (risen in the Fen), flyer, caster, inert, mist (bool flags).
	void set_enemy_look(const godot::String &p_def, const godot::Dictionary &p_look);
	void set_thrall_look(const godot::String &p_kind, int64_t p_legion, const godot::Dictionary &p_look);
	void set_owner_legion(int64_t p_owner, int64_t p_legion);  // a core hero id -> the legion id the thrall looks are keyed by (-1: none)
	void set_focus(const godot::Vector2 &p_pos);                // the hero's ground position
	void set_hitstop_scale(double p_scale);
	void set_champion_scale(double p_scale);
	void set_shadow_policy(int64_t p_casters, int64_t p_crowded_casters, bool p_thralls_cast);
	void set_seed(int64_t p_seed);
	void reserve(int64_t p_rows);  // every group starts with room for this many instances (the MultiMeshes are sized when the first frame draws)
	void clear();  // forget every creature (a new core, a new area)

	// The tick: read the core (its tables and the damage in its event buffer, which stays for take_events), or take the same rows from elsewhere.
	void sync(const godot::Ref<DmCore> &p_core);
	void sync_rows(const godot::PackedInt32Array &p_body_ints, const godot::PackedFloat32Array &p_body_floats, const godot::PackedFloat32Array &p_hits,
			const godot::PackedInt32Array &p_corpse_ints, const godot::PackedFloat32Array &p_corpse_floats);
	// The frame: interpolate by `alpha` (Engine.get_physics_interpolation_fraction()), advance the views by `dt`, write the MultiMeshes.
	void draw(double p_dt, double p_alpha, const godot::Vector3 &p_camera);

	// Reads (tests, the HUD's counters).
	godot::PackedFloat32Array buffer(int64_t p_model, int64_t p_lod, bool p_shadow = false) const;  // exactly what was uploaded: count * 20 floats
	int64_t instance_count(int64_t p_model, int64_t p_lod, bool p_shadow = false) const;
	godot::Dictionary stats() const;
	godot::Dictionary view_info(int64_t p_id, bool p_corpse = false) const;
	godot::Dictionary last_feed() const;  // the rows the last sync or sync_rows took, in sync_rows' layout (a co-op guest builds the same)

	// Today's pure helpers, for the tests to hold against the GDScript (dm_entity_views.gd, dm_animator.gd).
	static double turn_toward(double p_cur, double p_target, double p_dt, double p_rate, double p_max_rate);
	static double smooth_speed(double p_prev, double p_sample, double p_dt, double p_tau);
	static godot::Vector2 knock_impulse(double p_frac, double p_mass, double p_dx, double p_dz);
	static godot::PackedFloat64Array step_knock(const godot::PackedFloat64Array &p_state, double p_dt);  // (x, z, vx, vz)
	static double settle_depth(double p_t, double p_depth, double p_dur = 0.45);
	static godot::Dictionary strike_timing(double p_duration, double p_impact, double p_impact_in, double p_follow);
};
