#pragma once
// Godot-facing API of the crowd's presentation (native/README.md "Drawing", client/crowd/README.md "Driving the crowd"): DmCrowd reads the
// combat core's tables once per tick (`sync`), and writes the instance buffer of every creature model's MultiMeshes once per rendered frame
// (`draw`). All the view logic is in core/crowd_view.*; this class resolves looks, turns the core's tables into the feed and talks to the
// RenderingServer.
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/projection.hpp>
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
		float glow[4] = { 0, 0, 0, 0 }, glow_fen[4] = { 0, 0, 0, 0 };  // linear rgb + strength (DmCreature's emissive and emissive_intensity); strength 0 = none
		float glow_emp = 0;                                               // what an empowered thrall adds to the strength (0.22; the wraith none, as today)
		mutable int32_t slot = -1, slot_fen = -1, slot_var[8] = { -1, -1, -1, -1, -1, -1, -1, -1 };  // palette slots, found on first use (slot_var: a thrall's [plain, empowered, champion, both] x [own, an ally's])
		bool has_fen = false, set = false;
	};
	struct GroupRid {
		godot::RID rid;
		int32_t cap = 0, last = -1;
		godot::PackedFloat32Array packed;
		uint64_t node = 0;       // the MultiMeshInstance3D drawing this group (its object id), 0 = none: the crowd shows it while it holds instances (set_group_nodes)
		bool shown = false;      // what the node's `visible` was last set to by the crowd
		float idle_s = 0.0f;     // seconds the group has been empty while shown
	};

	dm::CrowdView view;
	dm::CrowdFeed feed;
	godot::PackedFloat32Array lod_cfg;  // the level-of-detail distances the models were added with (settings())
	std::unordered_map<std::string, Look> enemy_looks;
	std::vector<Look> def_looks;  // by the core's def index, rebuilt when looks or defs change
	Look risen_look;
	bool looks_dirty = true;
	std::vector<Look> thrall_looks;  // [kind * LEGION_SLOTS + legion + 1]
	std::unordered_map<int32_t, int32_t> owner_legion;
	std::unordered_set<int32_t> owner_ally;  // owners that are not this player: their thralls' rim is weaker (DmEntityViews THRALL_RIM_ALLY)
	std::vector<GroupRid> rids;  // parallel to the view's groups
	// The palette (the crowd shader's `glow_palette` and `rim_palette`): 8 floats a slot, the glow's linear rgb + strength (DmCreature's emissive and emissive_intensity)
	// then the friend rim's (DmCreatureMat's `rim`); slot 0 = none (the model's own emission, no rim). Slots are added on first use and never removed, at most
	// GLOW_SLOTS (COLOR.a = slot * 2 + flash stays exact in a half float up to slot 127); `glow_version` counts additions so CrowdView pushes the palette to the
	// materials only when it grew. A thrall's slot is its look's glow with the empowered and champion boosts and its rim: whose it is and whether it is a champion.
	static constexpr int32_t GLOW_SLOTS = 128;
	std::vector<float> glow_pal = { 0, 0, 0, 0, 0, 0, 0, 0 };
	int64_t glow_ver = 0;
	float elite_glow[4] = { 0, 0, 0, 0 };
	int32_t elite_slot = -1;
	float champion_add = 0.0f;
	float rim_spirit[3] = { 0, 0, 0 }, rim_champion[3] = { 0, 0, 0 };  // linear: a thrall's rim colour, and a champion's
	float rim_own = 0.0f, rim_ally = 0.0f, rim_champion_k = 0.0f;       // the rim's strength: a thrall of this player, of another's, a champion
	int32_t glow_slot(const float *p_rgbk, const float *p_rim = nullptr);
	int32_t enemy_glow(const Look &p_look, bool p_elite, bool p_drowned);                          // an elite's glow over its look's (DmEntityViews._enemy_opts)
	int32_t thrall_glow(const Look &p_look, bool p_empowered, bool p_champion, bool p_ally);      // the look's glow, stronger when empowered or a champion, and the rim (_make_thrall)
	// the event buffer is read from where the last sync stopped (take_events clears it behind our back)
	size_t ev_i = 0, ev_f = 0;
	uint64_t ev_batches = 0;

	void set_node_visible(GroupRid &r_group, bool p_visible);
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
	// `fade_rids[i]` (optional): the MultiMesh of level i's fade group, drawn with the alpha shader: a body that is not solid (it sinks away, or the Shrouded ward has it) is written there for
	// as long as it is not, and casts no shadow; without it such a body stays opaque in its plain group. A spectral model (`data.spectral`, see-through already) needs none.
	int64_t add_model(const godot::String &p_slug, const godot::Dictionary &p_data, const godot::Array &p_lod_rids, const godot::Array &p_shadow_rids, const godot::PackedFloat32Array &p_lod_distances,
			const godot::Array &p_fade_rids = godot::Array());
	// The nodes that draw a model's groups (`plain_nodes[i]` / `shadow_nodes[i]`: the MultiMeshInstance3D of level i without and with shadows). The renderer draws a MultiMesh with no
	// instance all the same (one draw call, and one more for each shadow cascade a caster meets), so a group is shown (`visible`) the frame it gets its first instance and hidden
	// once it has had none for HIDE_AFTER_S seconds; the nodes start hidden. Without this call a group's node is never touched.
	void set_group_nodes(int64_t p_model, const godot::Array &p_plain_nodes, const godot::Array &p_shadow_nodes, const godot::Array &p_fade_nodes = godot::Array());
	// Today's glows that are not a look's own: `elite` (Color, linear, alpha = strength) for every elite enemy and its corpse, and what a champion thrall adds
	// to its look's strength (DmEntityViews: 0.35).
	void set_glows(const godot::Color &p_elite, double p_champion_add);
	godot::PackedColorArray glow_palette() const;  // the slots' glows, linear rgb + strength in alpha
	godot::PackedColorArray rim_palette() const;   // the slots' rims, the same layout (a body's slot picks both)
	// A thrall's rim (DmEntityViews._make_thrall): `spirit` and `champion` are linear colours; the strengths are what a thrall of this player, of another's and a champion get.
	void set_thrall_rim(const godot::Color &p_spirit, const godot::Color &p_champion, double p_own, double p_ally, double p_champion_k);
	void set_owner_ally(int64_t p_owner, bool p_ally);  // a core hero id whose thralls belong to another player (default: this player's)
	godot::PackedFloat32Array take_landings();
	bool shatter(int64_t p_corpse);
	godot::Vector3 ground_at(int64_t p_id) const;     // where a living body is drawn on the ground (y 0), Vector3.INF when it is not (dying, gone): the cheap read for decals that follow it                  // Corpse Explosion: the corpse's body goes at once (false when the crowd has no body for it)      // where dying bodies came to rest since the last call: x, z, scale per landing (empty when none)
	int64_t glow_version() const;
	// A look: model (slot), hover (m), scale, tint (linear Color), tint_fen (risen in the Fen), flyer, caster, inert, mist (bool flags).
	void set_enemy_look(const godot::String &p_def, const godot::Dictionary &p_look);
	void set_thrall_look(const godot::String &p_kind, int64_t p_legion, const godot::Dictionary &p_look);
	void set_owner_legion(int64_t p_owner, int64_t p_legion);  // a core hero id -> the legion id the thrall looks are keyed by (-1: none)
	void set_focus(const godot::Vector2 &p_pos);                // the hero's ground position
	void set_hitstop_scale(double p_scale);
	void set_champion_scale(double p_scale);
	void set_shadow_policy(int64_t p_casters, int64_t p_crowded_casters, bool p_thralls_cast);
	void set_seed(int64_t p_seed);
	// Crowd cost (client/crowd/README.md "Crowd cost"). `set_culling`: bodies outside the camera's view are not written (needs the view-projection matrix in `draw`).
	// `set_anim_lod`: far bodies work out their pose less often; bodies beyond `mid_m` metres from the camera at `mid_hz` times a second, beyond `far_m` at `far_hz`
	// (a rate of 0 = every frame). `set_shadow_light`: the direction the moon's light travels, so a shadow caster just outside the view stays while its shadow falls in.
	void set_culling(bool p_on);
	void set_anim_lod(bool p_on, double p_mid_m, double p_mid_hz, double p_far_m, double p_far_hz);
	void set_shadow_light(const godot::Vector3 &p_direction);
	godot::Dictionary settings() const;  // what is in force: culling, the animation bands, the shadow policy, whether the light is known, the reserve and the levels of detail the models were given
	void reserve(int64_t p_rows);  // every group starts with room for this many instances (the MultiMeshes are sized when the first frame draws)
	void clear();  // forget every creature (a new core, a new area)

	// The tick: read the core (its tables and the damage in its event buffer, which stays for take_events), or take the same rows from elsewhere.
	void sync(const godot::Ref<DmCore> &p_core);
	void sync_rows(const godot::PackedInt32Array &p_body_ints, const godot::PackedFloat32Array &p_body_floats, const godot::PackedFloat32Array &p_hits,
			const godot::PackedInt32Array &p_corpse_ints, const godot::PackedFloat32Array &p_corpse_floats);
	// The frame: interpolate by `alpha` (Engine.get_physics_interpolation_fraction()), advance the views by `dt`, write the MultiMeshes.
	// `view_projection`: the camera's projection times the inverse of its transform (Camera3D.get_camera_projection() * Projection(get_camera_transform().affine_inverse())),
	// for the culling; all zeros (the default) draws everything.
	void draw(double p_dt, double p_alpha, const godot::Vector3 &p_camera, const godot::Projection &p_view_projection = godot::Projection(godot::Vector4(), godot::Vector4(), godot::Vector4(), godot::Vector4()));

	// Reads (tests, the HUD's counters).
	godot::PackedFloat32Array buffer(int64_t p_model, int64_t p_lod, bool p_shadow = false, bool p_fade = false) const;  // exactly what was uploaded: count * 20 floats
	int64_t instance_count(int64_t p_model, int64_t p_lod, bool p_shadow = false, bool p_fade = false) const;
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
