#pragma once
// The crowd's presentation (native/README.md "Drawing", client/crowd/README.md "Driving the crowd"): everything that makes the core's bodies
// look alive, kept out of the simulation and free of Godot types. A feed of plain rows goes in once per tick (`tick`: the core's tables and hits,
// or later a co-op snapshot), the instance buffer of every (model, level of detail, shadow) group comes out once per rendered frame (`draw`).
// A port of the view layer of godot/game (dm_entity_views.gd, dm_creature.gd, DmAnimator): turn rate, smoothed ground speed, clip choice and
// stride-matched playback, strikes and flinches, blends, hit flash, knockback, rise, death settle and topple, corpses that keep a dying body.
#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>

#include "rng.h"

namespace dm {

// ---- the input: plain rows (nothing here is a pointer into the simulation, so a co-op guest can fill the same rows from snapshots)

enum BodyKind : int32_t { BK_ENEMY = 0, BK_THRALL };
// What a body is dressed with (the producer resolves the look: model slot, scale, tint and these).
enum BodyFlag : int32_t {
	BF_ELITE = 1,
	BF_CASTER = 2,  // swings with the cast clip
	BF_INERT = 4,   // never shoved by a hit
	BF_MIST = 8,    // leaves no body: thins away when it dies (the wraith)
	BF_FLYER = 16,  // hovers by its def's `flying` (bobs by 0.18 m; other hoverers bob by 0.12)
	BF_DIVING = 32,    // the swing in its wind-up is a Gargoyle's dive: it climbs over the mark, then drops onto it (DmEnemyGargoyle._process)
	BF_GROUNDED = 64,  // a dive that has landed: grounded (0.05 m) while it recovers
};

struct CrowdBody {
	int32_t id = 0, kind = BK_ENEMY, model = -1;  // id is unique over enemies and thralls; model is the slot add_model returned (-1: not drawn)
	int32_t state = 0;                            // the core's EnemyState or ThrallState, by kind
	int32_t flags = 0, swing = 0, def = 0;        // BodyFlag bits; a thrall's swing counter (a new number starts a swing); the enemy def (corpse match)
	float x = 0, z = 0, yaw = 0;                  // where the tick left the body
	float speed = 0, state_t = 0;                 // ground speed (m/s) this tick; seconds in the state
	float action_s = 0;                           // seconds the state's one-shot is timed to: the wind-up, the dig, the recovery, a thrall's 0.12 swing
	float scale = 1, hover = 0;                   // drawn size; hover height in metres (0 = on the ground)
	float tint[3] = { 1, 1, 1 };                  // linear colour multiplier
	int32_t glow = 0;                             // the body's glow: a slot of DmCrowd's glow palette (0 = the model's own emission)
};

struct CrowdHit {  // damage a body took this tick (summed), as the core's damaged events say; a guest derives it from hp drops
	int32_t id = 0;
	float amount = 0, hp = 0, max_hp = 1;  // hp after
};

struct CrowdCorpse {  // a corpse the core holds (the dying body is adopted, else one is laid)
	int32_t id = 0, model = -1, def = 0;
	float x = 0, z = 0, facing = 0, scale = 1;
	float tint[3] = { 1, 1, 1 };
	int32_t glow = 0;
};

struct CrowdFeed {
	std::vector<CrowdBody> bodies;
	std::vector<CrowdHit> hits;
	std::vector<CrowdCorpse> corpses;
	void clear() {
		bodies.clear();
		hits.clear();
		corpses.clear();
	}
};

// ---- models: what a baked model (CrowdVatData) tells the view

// The roles DmCreature.FALLBACK resolves a clip for that the crowd plays.
enum Role : int32_t { RL_IDLE = 0, RL_WALK, RL_RUN, RL_ATTACK, RL_CAST, RL_HURT, RL_DEATH, RL_DIG, RL_DIVE, RL_COUNT };
constexpr const char *ROLE_NAMES[RL_COUNT] = { "idle", "walk", "run", "attack", "cast", "hurt", "death", "dig", "dive" };

struct CrowdModel {
	std::string slug;
	double height = 1.0;                       // the model row's height in metres
	double radius = 0.0;                       // metres: a sphere about the feet that holds every baked pose (0 = unknown: 1.2 x the height)
	double stride_walk = 0.7, stride_run = 0.0;  // body heights per second (the row's `stride`; DmAnimator.DEFAULT_WALK when none)
	std::vector<std::string> clip_names;
	std::vector<double> seconds, length, impact, landing;  // per clip: baked seconds, source length, impact second (-1: unmeasured), death landing second (-1: none)
	std::vector<uint8_t> loop;
	std::vector<int32_t> lod_tris;             // triangles of each mesh level (the benchmark's counters; empty = unknown)
	std::vector<int32_t> pool[RL_COUNT];       // clips that play a role, variants included (DmCreature._resolve)
	std::vector<double> lod_dist;              // camera distance where level i + 1 starts (levels - 1 numbers)
	int32_t lods = 1, group0 = 0;
	int32_t c_walk = -1, c_run = -1, c_hurt = -1, c_idle = -1;  // clips literally named walk, run, hurt, idle (DmCreature.has)
};

// One level-of-detail, shadow-or-not MultiMesh worth of instances: 20 floats each (12 transform, 4 colour, 4 custom data, CrowdVatData.BUFFER_STRIDE).
constexpr int32_t STRIDE = 20;
struct CrowdGroup {
	int32_t model = 0, lod = 0;
	bool shadow = false;
	int32_t count = 0, cap = 0;
	std::vector<float> buf;  // cap * STRIDE
};

// ---- the view of one creature

enum ViewMode : int32_t { M_LIVE = 0, M_DYING, M_CORPSE, M_FADE };

struct View {
	int32_t id = 0, kind = BK_ENEMY, model = -1, flags = 0, def = 0, mode = M_LIVE, corpse_id = 0, state = -1, swing = 0, epoch = 0, cseen = 0;
	// the sim, last two ticks (interpolation) and what the tick said
	double px = 0, pz = 0, pyaw = 0, cx = 0, cz = 0, cyaw = 0;
	double raw_speed = 0, state_t = 0, action_s = 0, scale = 1, hover = 0;
	float tint[3] = { 1, 1, 1 };
	int32_t glow = 0;  // glow palette slot (CrowdBody.glow)
	int32_t faded_corpse = 0;  // the corpse it drew before it began to sink (so a late `shatter` still finds it)
	// drawn
	double yaw = 0, gs = 0, flash = 0, flash_v = 0;
	bool has_gs = false;
	double kx = 0, kz = 0, kvx = 0, kvz = 0;  // knockback spring (a drawn offset only)
	double dx = 0, dy = 0, dz = 0, dyaw = 0;  // where it was last drawn, frozen when it dies
	// the creature's clips (DmCreature)
	int32_t cur = -1, prev = -1, one_shot = -1, death_clip = -1, loop_role = RL_IDLE;
	double t = 0, speed = 1, pt = 0, blend_t = 0, blend_d = 0, one_end = -1, loop_speed = 1, idle_k = 1;
	bool loco_run = false;
	// the body layer (DmCreature._fx_step): its timers and the pose they gave (the model node's rotation, squash and forward offset)
	double kick_t = -1, kick_amp = 1, kick_side = 1, lunge_t = -1, lunge_in = 0.5, lunge_len = 0, lunge_pitch = 0, rise_k = 1;
	double pitch = 0, roll = 0, sq = 0, zo = 0;
	// death (DmEntityViews)
	double toppled = 0, die_t = 0, rest_t = 0, sink_t = 0, settle_t = 0, settle_y = 0;
	bool has_settle = false, no_settle = false;
	bool shadow = true, hidden = false, alive = false, row_tied = false, moving = false;
	// crowd cost (client/crowd/README.md "Crowd cost"): the last pose row (everything but where the body stands) and when the pose is next worked out
	double crow_off[3] = { 0, 0, 0 };  // the lunge's offset inside the row's translation, which the placement adds to where the body stands
	double acc = 0, credit = 0;        // seconds since the last pose update; the band's rate credit (a body updates when it has a period's worth)
	float crow[20] = {};               // the pose row as the last pose update wrote it (CrowdGroup layout)
	bool crow_ok = false, force = true, was_culled = false;
	int32_t band = 0;                  // the animation band of the last frame: 0 every frame, 1 the mid rate, 2 the far rate
	int64_t pose_updates = 0;          // pose updates so far (tests)
	Rng rng;
};

struct CrowdStats {
	int32_t bodies = 0, live = 0, dying = 0, corpses = 0, fading = 0, drawn = 0, groups = 0;
	int64_t capacity_floats = 0, regrows = 0, frames = 0;
	// the last frame's crowd cost (client/crowd/README.md "Crowd cost"): deterministic counters, nothing timed
	int32_t culled = 0;                        // bodies outside the camera's view (and their shadows' reach): not written, so the GPU never sees them
	int32_t casting = 0, casting_thralls = 0;  // instances in the shadow groups, and how many of them are thralls
	int32_t groups_used = 0, groups_casting = 0;  // MultiMeshes with an instance this frame (draw calls), and the shadow ones among them (also drawn into the moon's shadow map)
	int64_t triangles = 0, casting_triangles = 0;  // triangles of the drawn instances at their level of detail, and of the casting ones (drawn a second time into the shadow map)
	int32_t band[3] = { 0, 0, 0 };             // live bodies per animation band (drawn or not)
	int32_t pose_updates = 0;                  // live bodies whose pose was worked out this frame (the rest reused their last pose row, placed afresh)
	int64_t pose_updates_total = 0;            // ... since the crowd was made
};

// How much work the crowd does per body, and for which bodies (client/crowd/README.md "Crowd cost").
struct CrowdCost {
	bool anim_lod = false;                 // far bodies work out their pose less often (off here, so a bare DmCrowd draws as it always did; CrowdView turns it on)
	double mid_m = 32.0, far_m = 60.0;     // camera distance where the mid and far bands start (the first two mesh levels' distances)
	double mid_hz = 24.0, far_hz = 10.0;   // pose updates a second in each band (0 = every frame)
	bool cull = true;                      // bodies outside the camera's view are not written
	double shadow_reach = 12.0;            // metres a shadow caster is kept past the view's edge when the light's direction is not known
};

class CrowdView {
public:
	double hitstop_scale = 1.0;  // the picture clock of a struck enemy (Vfx.hitstop_scale)
	double champion_scale = 1.35;
	int32_t shadow_casters = 12, crowded_casters = 8, crowded_at = 32;
	bool thrall_shadows = true;  // thralls always cast, as today (DmCasterBudget: "the hero, thralls and bosses always cast")
	double focus_x = 0, focus_z = 0;  // the hero: the knock pushes away from it, shadows go to the nearest to it
	uint64_t seed = 1;
	int32_t reserve_rows = 0;  // rows every group starts with (and new models' groups): sized at loading so a wave never grows a MultiMesh

	CrowdCost cost;
	void set_thrall_shadows(bool p_on);
	// The camera's view for the next draw: its view-projection matrix, column-major (16 floats; clip = M * (x, y, z, 1), OpenGL clip space as
	// Camera3D.get_camera_projection() gives it), or null for no culling in that draw.
	void set_view(const float *p_view_projection);
	// The direction the moon's light travels (any length; all zero = unknown): a shadow caster outside the view stays while its shadow reaches in.
	void set_light(double p_x, double p_y, double p_z);
	// True when a body of bounding radius `p_r` (a sphere about its feet) at (x, y, z) is inside the view `set_view` set, or a caster's shadow reaches in.
	bool in_view(double p_x, double p_y, double p_z, double p_r, bool p_caster) const;
	bool has_light_dir() const { return has_light; }
	bool shatter(int32_t p_corpse);  // Corpse Explosion blew the corpse apart: its body goes at once instead of sinking (DmEntityViews: opacity 0)
	// Where dying bodies came to rest since the last take (DmEntityViews._landing_dust): x, z, drawn scale per landing; at most LANDINGS_MAX kept.
	std::vector<float> landings;
	static constexpr size_t LANDINGS_MAX = 64;  // the thralls' casting, for the thralls already drawn too (a preset change mid-game)
	int32_t add_model(const CrowdModel &p_model);
	int32_t model_count() const { return int32_t(models.size()); }
	const CrowdModel &model(int32_t p_slot) const { return models[p_slot]; }
	void clear_views();
	void reserve(int32_t p_rows);

	void tick(const CrowdFeed &p_feed);
	void draw(double p_dt, double p_alpha, float p_cam_x, float p_cam_y, float p_cam_z);

	int32_t group_count() const { return int32_t(groups.size()); }
	const CrowdGroup &group(int32_t p_index) const { return groups[p_index]; }
	int32_t group_of(int32_t p_model, int32_t p_lod, bool p_shadow) const;
	const View *find(int32_t p_id) const;
	const View *find_corpse(int32_t p_corpse) const;
	CrowdStats stats() const;
	int32_t view_count() const { return int32_t(views.size()) - int32_t(free_list.size()); }
	const std::vector<View> &all_views() const { return views; }

	// Today's pure helpers (dm_entity_views.gd, dm_animator.gd), public so the tests hold them against the GDScript.
	static double turn_toward(double p_cur, double p_target, double p_dt, double p_rate, double p_max_rate);
	static double smooth_speed(double p_prev, double p_sample, double p_dt, double p_tau);
	static void knock_impulse(double p_frac, double p_mass, double p_dx, double p_dz, double &r_x, double &r_z);
	static void step_knock(double &x, double &z, double &vx, double &vz, double p_dt);
	static double settle_depth(double p_t, double p_depth, double p_dur = 0.45);
	static double walk_cap(double p_h);
	static void plan_loco(const CrowdModel &p_m, double p_h, double p_ground, bool p_was_run, int32_t &r_role, double &r_scale);
	static void strike_timing(double p_duration, double p_impact, double p_impact_in, double p_follow, double &r_speed, double &r_start, double &r_end);

private:
	std::vector<CrowdModel> models;
	std::vector<CrowdGroup> groups;
	std::vector<View> views;
	std::vector<int32_t> free_list;
	std::unordered_map<int32_t, int32_t> by_id, by_corpse;
	std::vector<std::pair<double, int32_t>> rank_scratch;
	std::vector<int32_t> gone_scratch;
	int32_t epoch = 0;
	int64_t frames = 0, regrows = 0, pose_total = 0;
	double clock_ms = 0;
	float planes[6][4] = {};  // the view's planes, unit normals pointing in: n . p + d >= 0 is inside
	bool has_view = false;
	double light[3] = { 0, 0, 0 };  // unit, the direction the light travels
	bool has_light = false;
	CrowdStats last;  // the last draw's counters (stats() adds the rest)

	View &make_view(int32_t p_id, int32_t p_kind, int32_t p_model);
	void drop_view(int32_t p_index);
	void apply_body(const CrowdBody &p_body);
	void apply_hit(const CrowdHit &p_hit);
	void apply_corpse(const CrowdCorpse &p_corpse);
	void edge(View &v, int32_t p_prev, int32_t p_state);
	void die(View &v);
	void start_fade(View &v);
	bool advance(View &v, double p_dt, double p_alpha);
	void advance_live(const CrowdModel &m, View &v, double p_dt, double p_alpha);
	void catch_up(const CrowdModel &m, View &v);
	void rank_shadows();
	void draw_live(View &v, double p_dt, double p_alpha, float p_cam_x, float p_cam_y, float p_cam_z, bool p_full_rate);
	void emit(View &v, float p_cam_x, float p_cam_y, float p_cam_z);
	void pose_row(const CrowdModel &m, const View &v, float *w, double *r_off) const;
	float *slot_for(const View &v, float p_cam_x, float p_cam_y, float p_cam_z);
	double view_radius(const View &v) const;
	CrowdGroup &group_for(int32_t p_model, int32_t p_lod, bool p_shadow);
	void grow(CrowdGroup &g);

	// the creature (DmCreature / DmAnimator): clips
	int32_t resolve(const CrowdModel &m, View &v, int32_t p_role);
	bool playing(const CrowdModel &m, const View &v) const;
	double loop_sp(const CrowdModel &m, const View &v, int32_t p_clip, double p_speed) const;
	void start_loop(const CrowdModel &m, View &v, bool p_fade, double p_fade_s);
	void set_loop(const CrowdModel &m, View &v, int32_t p_role, double p_speed);
	void set_ground_speed(const CrowdModel &m, View &v, double p_ground);
	bool play_once(const CrowdModel &m, View &v, int32_t p_role, double p_speed, double p_duration, double p_fade);
	bool play_strike(const CrowdModel &m, View &v, int32_t p_role, double p_impact_in);
	bool flinch(const CrowdModel &m, View &v, double p_strength);
	bool play_death(const CrowdModel &m, View &v);
	void begin(View &v, int32_t p_clip, double p_fade);
	void update_clips(const CrowdModel &m, View &v, double p_dt);
	void fx_step(const CrowdModel &m, View &v, double p_dt);
	void react(const CrowdModel &m, View &v, double p_strength);
	void start_lunge(const CrowdModel &m, View &v, bool p_cast, double p_impact_in, bool p_has_clip);
	double landing_time(const CrowdModel &m, int32_t p_clip) const;
	bool has_landed(const CrowdModel &m, const View &v) const;
	double base_height(const CrowdModel &m, const View &v) const;
};

} // namespace dm
