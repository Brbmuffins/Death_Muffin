// The crowd's presentation, a port of the view layer of godot/game (native/README.md "Drawing"). Sections: today's pure helpers, the creature
// (DmCreature: clips, blends, strikes, flinch, the body layer), the views (DmEntityViews: death, corpses, shadows), then tick and draw.
#include "crowd_view.h"

#include <algorithm>
#include <cmath>
#include <cstring>

#include "world.h"

namespace dm {

namespace {
constexpr double PI_ = 3.14159265358979323846, TAU_ = 2.0 * PI_;
// DmCreature
constexpr double FADE_LOCOMOTION = 0.28, FADE_RETURN = 0.2, IDLE_STAND_IN = 0.2, FLINCH_SECONDS = 0.5, FLINCH_SPEED = 1.35;
constexpr double FADE_STRIKE_MAX = 0.14, FADE_STRIKE_MIN = 0.06, FADE_HURT = 0.09, FADE_DEATH = 0.12, FADE_ONCE = 0.1;
constexpr double KICK_S = 0.3, LUNGE_SETTLE_S = 0.3, STRIKE_FOLLOW = 0.3, FLASH_LEVELS = 8.0;
// DmAnimator
constexpr double DEFAULT_WALK = 0.7, LOCO_MIN = 0.4, WALK_MAX = 3.0, WALK_HARD_MAX = 4.5, RUN_MAX = 2.4, RUN_UP = 2.0, RUN_DOWN = 1.6;
// DmEntityViews
constexpr double TURN_GAIN = 10.0, ENEMY_TURN_RATE = 9.0, SPEED_TAU = 0.18, SETTLE_DEPTH = 0.06, CORPSE_ANIM_S = 6.0, CORPSE_REST_S = 0.35;
constexpr double KNOCK_K = 140.0, KNOCK_MAX = 0.6, NEAR_X = 24.0, NEAR_Z = 20.0, DYING_CRUMBLE_S = 1.4, SINK_SPEED = 1.3, SINK_S = 0.9;
constexpr double TOPPLE_RATE = 3.0, TOPPLE_Y = 0.2, MAX_STEP = 3.0, MOVING_SPEED = 0.2;
// Rise: the sim's times (RISE_S in world.h, thrall_rise 0.9) and how far down the body starts (dm_enemy.gd, dm_thrall.gd).
constexpr double ENEMY_RISE_S = 1.1, THRALL_RISE_S = 0.9, ENEMY_SINK = 0.9, THRALL_SINK = 1.8;
constexpr double FLASH_DECAY_ENEMY = 6.0, FLASH_DECAY_THRALL = 5.0;
constexpr int32_t RERANK_EVERY = 10;
// Crowd cost: a body's bounding sphere is taken this much bigger (the lunge, the squash, a knock), and a shadow is followed this far along the light.
constexpr double CULL_SLACK = 0.75, SHADOW_RUN_MAX = 40.0;

// 0..1, from the body's id alone (no dice are thrown, so nothing else a body does changes): where in its band's period a body's pose updates fall.
double phase_of(int32_t p_id) {
	const double x = double(p_id) * 0.6180339887498949;
	return x - std::floor(x);
}

double wrap_pi(double d) {
	while (d > PI_) {
		d -= TAU_;
	}
	while (d < -PI_) {
		d += TAU_;
	}
	return d;
}

double lerp_ang(double a, double b, double w) {  // Godot's lerp_angle
	const double diff = std::fmod(b - a, TAU_);
	const double dist = std::fmod(2.0 * diff, TAU_) - diff;
	return a + dist * w;
}

double smooth01(double x) {  // DmCreature._smooth
	x = std::min(1.0, std::max(0.0, x));
	return x * x * (3.0 - 2.0 * x);
}

struct M3 {
	double m[3][3];
};
M3 mul(const M3 &a, const M3 &b) {
	M3 r;
	for (int i = 0; i < 3; i++) {
		for (int j = 0; j < 3; j++) {
			r.m[i][j] = a.m[i][0] * b.m[0][j] + a.m[i][1] * b.m[1][j] + a.m[i][2] * b.m[2][j];
		}
	}
	return r;
}
M3 rot_x(double a) {
	const double c = std::cos(a), s = std::sin(a);
	return M3{ { { 1, 0, 0 }, { 0, c, -s }, { 0, s, c } } };
}
M3 rot_y(double a) {
	const double c = std::cos(a), s = std::sin(a);
	return M3{ { { c, 0, s }, { 0, 1, 0 }, { -s, 0, c } } };
}
M3 rot_z(double a) {
	const double c = std::cos(a), s = std::sin(a);
	return M3{ { { c, -s, 0 }, { s, c, 0 }, { 0, 0, 1 } } };
}
} // namespace

// ---------------------------------------------------------------------------------------------------------------- today's pure helpers

double CrowdView::turn_toward(double p_cur, double p_target, double p_dt, double p_rate, double p_max_rate) {  // DmEntityViews.turn_toward
	const double d = wrap_pi(p_target - p_cur);
	const double lim = p_max_rate * p_dt;
	return p_cur + std::max(-lim, std::min(lim, d * std::min(1.0, p_dt * p_rate)));
}

double CrowdView::smooth_speed(double p_prev, double p_sample, double p_dt, double p_tau) {  // DmEntityViews.smooth_speed
	return p_prev + (p_sample - p_prev) * (1.0 - std::exp(-std::max(0.0, p_dt) / p_tau));
}

void CrowdView::knock_impulse(double p_frac, double p_mass, double p_dx, double p_dz, double &r_x, double &r_z) {  // DmEntityViews.knock_impulse
	double l = std::sqrt(p_dx * p_dx + p_dz * p_dz);
	if (l == 0.0) {
		l = 1.0;
	}
	const double push = std::pow(std::min(1.0, std::max(0.0, p_frac)), 0.6) * 16.0 / std::max(0.6, p_mass);
	const double v = std::min(push, 20.0);
	r_x = p_dx / l * v;
	r_z = p_dz / l * v;
}

void CrowdView::step_knock(double &x, double &z, double &vx, double &vz, double p_dt) {  // DmEntityViews.step_knock
	const int n = std::max(1, int(std::ceil(p_dt / (1.0 / 120.0))));
	const double h = p_dt / n;
	const double c = 2.0 * std::sqrt(KNOCK_K);
	for (int i = 0; i < n; i++) {
		vx += (-KNOCK_K * x - c * vx) * h;
		vz += (-KNOCK_K * z - c * vz) * h;
		x += vx * h;
		z += vz * h;
	}
	const double d = std::sqrt(x * x + z * z);
	if (d > KNOCK_MAX) {
		x *= KNOCK_MAX / d;
		z *= KNOCK_MAX / d;
	}
	if (d < 1e-3 && std::sqrt(vx * vx + vz * vz) < 0.02) {
		x = z = vx = vz = 0.0;
	}
}

double CrowdView::settle_depth(double p_t, double p_depth, double p_dur) {  // DmEntityViews.settle_depth
	const double k = std::min(1.0, std::max(0.0, p_t / p_dur));
	return p_depth * k * k * (3.0 - 2.0 * k);
}

double CrowdView::walk_cap(double p_h) {  // DmAnimator.walk_cap
	return std::min(WALK_HARD_MAX, std::max(1.6, WALK_MAX * std::sqrt(2.0 / std::max(0.1, p_h))));
}

// DmAnimator.plan_loco: which loop and how fast so the planted feet match `ground` (m/s) at body height `h`.
void CrowdView::plan_loco(const CrowdModel &p_m, double p_h, double p_ground, bool p_was_run, int32_t &r_role, double &r_scale) {
	const double walk_u = p_m.stride_walk * p_h;
	const double run_u = p_m.c_run >= 0 ? p_m.stride_run * p_h : 0.0;
	const bool run = run_u > 0.0 && p_ground > walk_u * (p_was_run ? RUN_DOWN : RUN_UP);
	const double st = run ? run_u : walk_u;
	const double mx = run ? RUN_MAX : walk_cap(p_h);
	r_role = run ? RL_RUN : RL_WALK;
	r_scale = st > 0.0 ? std::min(mx, std::max(LOCO_MIN, p_ground / st)) : 1.0;
}

// DmAnimator.strike_timing: the clip's impact frame (`impact` < 0 = unmeasured, 35% of the clip) lands `impact_in` seconds from now.
void CrowdView::strike_timing(double p_duration, double p_impact, double p_impact_in, double p_follow, double &r_speed, double &r_start, double &r_end) {
	const double peak = std::min(p_duration, p_impact >= 0.0 ? p_impact : p_duration * 0.35);
	const double lead = std::max(0.08, p_impact_in);
	r_speed = std::min(2.2, std::max(0.7, peak / lead));
	r_start = std::max(0.0, peak - lead * r_speed);
	r_end = std::min(p_duration, peak + p_follow * r_speed);
}

// ---------------------------------------------------------------------------------------------------------------- models and groups

int32_t CrowdView::add_model(const CrowdModel &p_model) {
	CrowdModel m = p_model;
	m.lods = std::max<int32_t>(1, m.lods);
	m.group0 = int32_t(groups.size());
	for (int32_t l = 0; l < m.lods; l++) {
		for (int32_t s = 0; s < 2; s++) {
			CrowdGroup g;
			g.model = int32_t(models.size());
			g.lod = l;
			g.shadow = s == 1;
			g.cap = reserve_rows;
			g.buf.resize(size_t(g.cap) * STRIDE);
			groups.push_back(g);
		}
	}
	for (size_t i = 0; i < m.clip_names.size(); i++) {
		const std::string &n = m.clip_names[i];
		if (n == "walk") {
			m.c_walk = int32_t(i);
		} else if (n == "run") {
			m.c_run = int32_t(i);
		} else if (n == "hurt") {
			m.c_hurt = int32_t(i);
		} else if (n == "idle") {
			m.c_idle = int32_t(i);
		}
	}
	models.push_back(m);
	return int32_t(models.size()) - 1;
}

int32_t CrowdView::group_of(int32_t p_model, int32_t p_lod, bool p_shadow) const {
	if (p_model < 0 || p_model >= int32_t(models.size()) || p_lod < 0 || p_lod >= models[p_model].lods) {
		return -1;
	}
	return models[p_model].group0 + p_lod * 2 + (p_shadow ? 1 : 0);
}

CrowdGroup &CrowdView::group_for(int32_t p_model, int32_t p_lod, bool p_shadow) {
	return groups[models[p_model].group0 + p_lod * 2 + (p_shadow ? 1 : 0)];
}

void CrowdView::reserve(int32_t p_rows) {
	reserve_rows = p_rows;
	for (CrowdGroup &g : groups) {
		if (g.cap < p_rows) {
			g.cap = p_rows;
			g.buf.resize(size_t(g.cap) * STRIDE);
		}
	}
}

void CrowdView::grow(CrowdGroup &g) {
	g.cap = std::max<int32_t>(16, g.cap * 2);
	g.buf.resize(size_t(g.cap) * STRIDE);
	regrows++;
}

const View *CrowdView::find(int32_t p_id) const {
	const auto it = by_id.find(p_id);
	return it == by_id.end() ? nullptr : &views[it->second];
}

const View *CrowdView::find_corpse(int32_t p_corpse) const {
	const auto it = by_corpse.find(p_corpse);
	return it == by_corpse.end() ? nullptr : &views[it->second];
}

CrowdStats CrowdView::stats() const {
	CrowdStats s;
	for (const View &v : views) {
		if (!v.alive) {
			continue;
		}
		s.bodies++;
		s.live += v.mode == M_LIVE;
		s.dying += v.mode == M_DYING;
		s.corpses += v.mode == M_CORPSE;
		s.fading += v.mode == M_FADE;
	}
	for (const CrowdGroup &g : groups) {
		s.drawn += g.count;
		s.capacity_floats += int64_t(g.buf.size());
	}
	s.groups = int32_t(groups.size());
	s.regrows = regrows;
	s.frames = frames;
	s.culled = last.culled;
	s.casting = last.casting;
	s.casting_thralls = last.casting_thralls;
	s.groups_used = last.groups_used;
	s.groups_casting = last.groups_casting;
	s.triangles = last.triangles;
	s.casting_triangles = last.casting_triangles;
	for (int i = 0; i < 3; i++) {
		s.band[i] = last.band[i];
	}
	s.pose_updates = last.pose_updates;
	s.pose_updates_total = pose_total;
	return s;
}

void CrowdView::clear_views() {
	views.clear();
	free_list.clear();
	by_id.clear();
	by_corpse.clear();
	for (CrowdGroup &g : groups) {
		g.count = 0;
	}
	last = CrowdStats();
}

View &CrowdView::make_view(int32_t p_id, int32_t p_kind, int32_t p_model) {
	int32_t idx;
	if (!free_list.empty()) {
		idx = free_list.back();
		free_list.pop_back();
		views[idx] = View();
	} else {
		idx = int32_t(views.size());
		views.emplace_back();
	}
	View &v = views[idx];
	v.alive = true;
	v.id = p_id;
	v.kind = p_kind;
	v.model = p_model;
	v.rng.seed(seed, uint64_t(p_id) * 2u + uint64_t(p_kind));
	v.idle_k = 0.92 + v.rng.next_double() * 0.16;  // each body idles at its own rate (+-8%) and starts at its own point of the loop
	return v;
}

void CrowdView::drop_view(int32_t p_index) {
	View &v = views[p_index];
	if (v.row_tied) {
		by_id.erase(v.id);
	}
	if (v.corpse_id != 0) {
		by_corpse.erase(v.corpse_id);
	}
	v.alive = false;
	free_list.push_back(p_index);
}

// ---------------------------------------------------------------------------------------------------------------- the creature: clips

int32_t CrowdView::resolve(const CrowdModel &m, View &v, int32_t p_role) {  // DmCreature._resolve: the role's clip, a variant picked at random
	const std::vector<int32_t> &pool = m.pool[p_role];
	if (pool.empty()) {
		return -1;
	}
	return pool.size() == 1 ? pool[0] : pool[v.rng.next_u32() % pool.size()];
}

bool CrowdView::playing(const CrowdModel &m, const View &v) const {  // AnimationPlayer.is_playing: a one-shot stops at its end
	return v.cur >= 0 && (m.loop[v.cur] || v.t < m.seconds[v.cur]);
}

double CrowdView::base_height(const CrowdModel &m, const View &v) const {  // DmCreature.base_height: the model row's height x the creature's `scale` option (thralls)
	return m.height * (v.kind == BK_THRALL ? v.scale : 1.0);
}

double CrowdView::loop_sp(const CrowdModel &m, const View &v, int32_t p_clip, double p_speed) const {  // DmCreature._loop_sp
	if (v.loop_role == RL_IDLE && p_clip >= 0 && p_clip != m.c_idle) {  // a walk-only rig idles as a slow shuffle
		return IDLE_STAND_IN;
	}
	return p_clip == m.c_idle ? p_speed * v.idle_k : p_speed;
}

// AnimationPlayer.play(clip, fade): the old clip keeps playing while it blends out over `fade` seconds.
void CrowdView::begin(View &v, int32_t p_clip, double p_fade) {
	if (p_fade > 0.0 && v.cur >= 0) {
		v.prev = v.cur;
		v.pt = v.t;
		v.blend_t = 0.0;
		v.blend_d = p_fade;
	} else {
		v.prev = -1;
	}
	v.cur = p_clip;
	v.t = 0.0;
}

void CrowdView::start_loop(const CrowdModel &m, View &v, bool p_fade, double p_fade_s) {  // DmCreature._start_loop
	if (p_fade_s < 0.0) {
		p_fade_s = FADE_LOCOMOTION;
	}
	const int32_t nxt = resolve(m, v, v.loop_role);
	if (nxt < 0) {
		return;
	}
	const double sp = loop_sp(m, v, nxt, v.loop_speed);
	if (nxt == v.cur && v.one_shot < 0 && playing(m, v)) {
		v.speed = sp;
		return;
	}
	double phase = -1.0;
	const bool stride_from = v.cur >= 0 && (v.cur == m.c_walk || v.cur == m.c_run);
	const bool stride_to = nxt == m.c_walk || nxt == m.c_run;
	if (p_fade && v.cur >= 0 && v.cur != nxt && stride_from && stride_to && m.seconds[v.cur] > 0.0) {  // walk and run share a step cycle
		phase = v.t / m.seconds[v.cur];
	}
	v.speed = sp;
	begin(v, nxt, p_fade && v.cur >= 0 ? p_fade_s : 0.0);
	if (phase >= 0.0) {
		v.t = phase * m.seconds[nxt];
	}
}

void CrowdView::set_loop(const CrowdModel &m, View &v, int32_t p_role, double p_speed) {  // DmCreature.set_loop
	v.loop_speed = p_speed;
	if (v.cur >= 0 && v.loop_role == p_role) {
		if (v.one_shot < 0) {
			v.speed = loop_sp(m, v, v.cur, p_speed);
		}
		return;
	}
	v.loop_role = p_role;
	if (v.one_shot < 0) {
		start_loop(m, v, true, -1.0);
	}
}

void CrowdView::set_ground_speed(const CrowdModel &m, View &v, double p_ground) {  // DmCreature.set_ground_speed
	int32_t role;
	double ts;
	plan_loco(m, m.height * v.scale, p_ground, v.loco_run, role, ts);
	v.loco_run = role == RL_RUN;
	set_loop(m, v, role, ts);
}

bool CrowdView::play_once(const CrowdModel &m, View &v, int32_t p_role, double p_speed, double p_duration, double p_fade) {  // DmCreature.play_once
	if (p_role == RL_HURT && m.c_hurt >= 0) {
		return flinch(m, v, 0.85);
	}
	const int32_t nm = resolve(m, v, p_role);
	if (nm < 0) {
		return false;
	}
	if (v.one_shot >= 0 && p_role == RL_HURT) {
		return true;
	}
	if (v.death_clip >= 0) {
		return true;
	}
	v.speed = p_duration > 0.0 ? m.length[nm] / std::max(0.12, p_duration) : p_speed;
	begin(v, nm, v.cur >= 0 ? p_fade : 0.0);
	v.one_shot = nm;
	v.one_end = -1.0;
	return true;
}

// DmCreature.play_strike: the clip's measured impact frame lands `impact_in` seconds from now, and the body lunges with it.
bool CrowdView::play_strike(const CrowdModel &m, View &v, int32_t p_role, double p_impact_in) {
	const bool played = play_once(m, v, p_role, 1.0, 0.0, std::min(FADE_STRIKE_MAX, std::max(FADE_STRIKE_MIN, p_impact_in * 0.3)));
	start_lunge(m, v, p_role == RL_CAST, p_impact_in, played);
	if (!played) {
		return false;
	}
	const int32_t nm = v.one_shot;
	if (nm < 0 || nm == v.death_clip) {
		return true;
	}
	double speed, start, end;
	strike_timing(m.length[nm], m.impact[nm], p_impact_in, STRIKE_FOLLOW, speed, start, end);
	v.speed = speed;
	v.t = start;
	v.one_end = end;
	return true;
}

bool CrowdView::flinch(const CrowdModel &m, View &v, double p_strength) {  // DmCreature.flinch: the first half-second of the hurt clip
	react(m, v, p_strength);
	if (m.c_hurt < 0) {
		return false;
	}
	if (v.one_shot >= 0) {
		return true;
	}
	const int32_t nm = resolve(m, v, RL_HURT);
	v.speed = FLINCH_SPEED;
	begin(v, nm, v.cur >= 0 ? FADE_HURT : 0.0);
	v.one_shot = nm;
	v.one_end = std::min(m.length[nm], FLINCH_SECONDS * FLINCH_SPEED);
	return true;
}

bool CrowdView::play_death(const CrowdModel &m, View &v) {  // DmCreature.play_death: held on its last frame
	const int32_t nm = resolve(m, v, RL_DEATH);
	if (nm < 0) {
		return false;
	}
	v.speed = 1.0;
	begin(v, nm, v.cur >= 0 ? FADE_DEATH : 0.0);
	v.one_shot = nm;
	v.one_end = -1.0;
	v.death_clip = nm;
	v.kick_t = -1.0;
	v.lunge_t = -1.0;
	return true;
}

// ---------------------------------------------------------------------------------------------------------------- the creature: body layer

// A hit recoil: the body kicks back, squashes and rolls a touch, then settles (0.3 s). Heavy bodies move less. Ignored while one is playing.
void CrowdView::react(const CrowdModel &m, View &v, double p_strength) {
	if (v.kick_t >= 0.0 || v.death_clip >= 0 || v.toppled > 0.0) {
		return;
	}
	v.kick_t = 0.0;
	v.kick_amp = p_strength * std::min(1.0, std::max(0.35, 2.0 / std::max(base_height(m, v), 0.5)));
	v.kick_side = v.rng.next_double() < 0.5 ? 1.0 : -1.0;
}

// A strike's body language, timed to the clip's impact: rock back through the wind-up, drive forward on the hit, settle. Rigs with no attack
// clip (the hounds) lunge and bite with the body alone; a cast only leans.
void CrowdView::start_lunge(const CrowdModel &m, View &v, bool p_cast, double p_impact_in, bool p_has_clip) {
	if (v.death_clip >= 0 || v.toppled > 0.0) {
		return;
	}
	v.lunge_t = 0.0;
	v.lunge_in = std::max(0.12, p_impact_in);
	v.lunge_len = p_cast ? 0.0 : base_height(m, v) * (p_has_clip ? 0.07 : 0.22);
	v.lunge_pitch = p_cast ? 0.05 : (p_has_clip ? 0.07 : 0.2);
}

// DmCreature._fx_step: folds the live body effects into the model node's pose.
void CrowdView::fx_step(const CrowdModel &m, View &v, double p_dt) {
	(void)m;
	double pitch = 0.0, roll = 0.0, sq = 0.0, zo = 0.0;
	if (v.kick_t >= 0.0) {
		v.kick_t += p_dt;
		if (v.kick_t >= KICK_S) {
			v.kick_t = -1.0;
		} else {
			const double u = v.kick_t / KICK_S;
			const double f = u < 0.16 ? smooth01(u / 0.16) : smooth01(1.0 - (u - 0.16) / 0.84);
			pitch -= 0.11 * v.kick_amp * f;
			roll += 0.04 * v.kick_amp * v.kick_side * f;
			sq += 0.05 * v.kick_amp * f;
		}
	}
	if (v.lunge_t >= 0.0) {
		v.lunge_t += p_dt;
		const double lead = v.lunge_in;
		if (v.lunge_t >= lead + LUNGE_SETTLE_S) {
			v.lunge_t = -1.0;
		} else {
			double k;
			if (v.lunge_t < lead * 0.65) {
				k = -0.4 * smooth01(v.lunge_t / (lead * 0.65));
			} else if (v.lunge_t < lead) {
				k = -0.4 + 1.4 * smooth01((v.lunge_t - lead * 0.65) / (lead * 0.35));
			} else {
				k = 1.0 - smooth01((v.lunge_t - lead) / LUNGE_SETTLE_S);
			}
			zo += v.lunge_len * k;
			pitch += v.lunge_pitch * k;
		}
	}
	if (v.rise_k < 1.0) {  // the climb out of the ground: the body leans into it
		const double r = 1.0 - v.rise_k;
		pitch += 0.5 * r * r;
	}
	v.pitch = pitch;
	v.roll = roll;
	v.sq = sq;
	v.zo = zo;
}

double CrowdView::landing_time(const CrowdModel &m, int32_t p_clip) const {  // DmCreature.landing_time (baked), 70% of the clip when it has no Hip track
	return m.landing[p_clip] >= 0.0 ? m.landing[p_clip] : m.length[p_clip] * 0.7;
}

// DmCreature.has_landed: a dying body has come to rest (its death clip's landing moment, or the tip-over for models without one).
bool CrowdView::has_landed(const CrowdModel &m, const View &v) const {
	if (v.toppled > 0.0) {
		return v.toppled >= 0.8;
	}
	if (v.death_clip < 0) {
		return false;
	}
	if (!playing(m, v)) {
		return true;
	}
	return v.t >= landing_time(m, v.death_clip);
}

// DmCreature.update: the clock (clips and blends), the body layer, then a one-shot that ended hands back to the loop.
void CrowdView::update_clips(const CrowdModel &m, View &v, double p_dt) {
	if (v.cur >= 0) {
		v.t += p_dt * v.speed;
		const double len = m.seconds[v.cur];
		if (m.loop[v.cur]) {
			if (len > 0.0 && v.t >= len) {
				v.t = std::fmod(v.t, len);
			}
		} else if (v.t > len) {
			v.t = len;
		}
	}
	if (v.prev >= 0) {
		v.pt += p_dt * v.speed;
		const double len = m.seconds[v.prev];
		if (m.loop[v.prev]) {
			if (len > 0.0 && v.pt >= len) {
				v.pt = std::fmod(v.pt, len);
			}
		} else if (v.pt > len) {
			v.pt = len;
		}
		v.blend_t += p_dt;
		if (v.blend_t >= v.blend_d) {
			v.prev = -1;
		}
	}
	fx_step(m, v, p_dt);
	if (v.one_shot >= 0 && v.death_clip < 0) {
		if (v.one_end >= 0.0 && v.t >= v.one_end) {
			v.one_shot = -1;
			v.one_end = -1.0;
			start_loop(m, v, true, FADE_RETURN);
		} else if (!playing(m, v)) {
			v.one_shot = -1;
			v.one_end = -1.0;
			v.cur = -1;
			start_loop(m, v, false, -1.0);
		}
	}
}

// ---------------------------------------------------------------------------------------------------------------- the views: tick

void CrowdView::edge(View &v, int32_t p_prev, int32_t p_state) {
	(void)p_prev;
	if (v.model < 0) {
		return;
	}
	const CrowdModel &m = models[v.model];
	if (v.kind == BK_THRALL) {
		if (p_state == TS_DEAD) {
			die(v);
		}
		return;
	}
	const int32_t swing = (v.flags & BF_CASTER) ? RL_CAST : RL_ATTACK;
	switch (p_state) {
		case ATTACK:  // dm_state_attack: the swing's impact frame lands when the wind-up ends
			if (v.flags & (BF_DIVING | BF_GROUNDED)) {  // DmEnemyGargoyle.play_attack: a dive plays its clip over the wind-up and a fifth more, no lunge
				play_once(m, v, RL_DIVE, 1.0, v.action_s * 1.2, FADE_ONCE);
				break;
			}
			play_strike(m, v, swing, v.action_s);
			break;
		case EMERGE:  // dm_state_emerge: 0.3 s of recovery after a surfacing, swung like an attack
			play_strike(m, v, swing, v.action_s);
			break;
		case HURT:
			flinch(m, v, 0.85);
			break;
		case DIG:
			play_once(m, v, RL_DIG, 1.0, v.action_s, FADE_ONCE);
			break;
		case DEAD:
			die(v);
			break;
		default:
			break;
	}
}

void CrowdView::start_fade(View &v) {
	v.mode = M_FADE;
	v.sink_t = 0.0;
	if (v.corpse_id != 0) {
		by_corpse.erase(v.corpse_id);
		v.faded_corpse = v.corpse_id;
		v.corpse_id = 0;
	}
}

bool CrowdView::shatter(int32_t p_corpse) {
	const auto it = by_corpse.find(p_corpse);
	View *v = it != by_corpse.end() ? &views[it->second] : nullptr;
	if (v == nullptr) {
		for (View &w : views) {
			if (w.alive && w.mode == M_FADE && w.faded_corpse == p_corpse) {
				v = &w;
				break;
			}
		}
	}
	if (v == nullptr) {
		return false;
	}
	if (v->mode != M_FADE) {
		start_fade(*v);
	}
	v->sink_t = SINK_S + 1.0;  // over: the next frame removes it
	return true;
}

// DmEntityViews._on_death: the body keeps where it fell and plays its death clip (or tips over); a corpse may adopt it within a moment.
void CrowdView::die(View &v) {
	v.flash = 0.0;
	v.flash_v = 0.0;
	v.moving = false;
	v.hidden = false;
	if (v.flags & BF_MIST) {  // a wraith leaves no body: it thins to mist and sinks away
		start_fade(v);
		return;
	}
	if (v.flags & BF_INERT) {  // a Skull Niche crumbles: hidden at once, not toppled (DmEnemyNiche.on_death); the nicheBreak effect is the burst
		start_fade(v);
		v.sink_t = SINK_S + 1.0;
		return;
	}
	const CrowdModel &m = models[v.model];
	v.mode = M_DYING;
	v.die_t = 0.0;
	if (!play_death(m, v)) {
		v.toppled = 0.0001;
	}
}

// A body that works its pose out less often is brought up to the present before a tick changes what drives it (a hit, a new state, a new look): the change then starts from
// where the body is now, not from where its last pose update left it, and the flash a hit sets is not worn down by the time before the hit.
void CrowdView::catch_up(const CrowdModel &m, View &v) {
	if (v.mode != M_LIVE || v.acc <= 0.0) {
		return;
	}
	advance_live(m, v, v.acc, 1.0);
	v.acc = 0.0;
}

void CrowdView::apply_body(const CrowdBody &b) {
	if (b.model < 0 || b.model >= int32_t(models.size())) {
		return;
	}
	int32_t idx;
	bool first = false;
	auto it = by_id.find(b.id);
	if (it != by_id.end() && (views[it->second].kind != b.kind || views[it->second].def != b.def)) {  // an id from another world
		drop_view(it->second);
		it = by_id.end();
	}
	if (it == by_id.end()) {
		View &nv = make_view(b.id, b.kind, b.model);
		idx = int32_t(&nv - views.data());
		nv.row_tied = true;
		by_id[b.id] = idx;
		first = true;
	} else {
		idx = it->second;
	}
	View &v = views[idx];
	v.epoch = epoch;
	if (v.mode != M_LIVE) {  // dying, a corpse or fading: the row no longer drives it
		return;
	}
	const CrowdModel &m = models[v.model];
	const bool look = b.flags != v.flags || b.scale != v.scale || b.hover != v.hover || b.glow != v.glow || b.tint[0] != v.tint[0] || b.tint[1] != v.tint[1] || b.tint[2] != v.tint[2];
	if (!first && (look || b.state != v.state || (b.kind == BK_THRALL && b.swing != v.swing))) {
		catch_up(m, v);
		v.force = true;  // a new look, state or swing: the pose row is written anew on the next frame, whatever the body's pose rate
	}
	v.def = b.def;
	v.flags = b.flags;
	v.scale = b.scale;
	v.hover = b.hover;
	v.action_s = b.action_s;
	v.raw_speed = b.speed;
	v.state_t = b.state_t;
	v.tint[0] = b.tint[0];
	v.tint[1] = b.tint[1];
	v.tint[2] = b.tint[2];
	v.glow = b.glow;
	if (first) {
		v.px = v.cx = b.x;
		v.pz = v.cz = b.z;
		v.pyaw = v.cyaw = b.yaw;
		v.yaw = b.yaw;
		v.swing = b.swing;
		v.shadow = b.kind == BK_THRALL ? thrall_shadows : !(b.flags & BF_MIST);
		start_loop(m, v, false, -1.0);  // DmCreature._init: the loop, then the idle desync
		if (v.cur >= 0 && v.cur == m.c_idle) {
			v.t = v.rng.next_double() * m.seconds[v.cur];
		}
		v.state = b.state;
		edge(v, -1, b.state);
		if (v.mode == M_DYING && v.death_clip >= 0) {  // seen already dead (a late joiner): the death clip is over
			v.t = m.seconds[v.death_clip];
		}
		v.dx = b.x;
		v.dz = b.z;
		v.dyaw = b.yaw;
		return;
	}
	// interpolation: the last two ticks; a jump over 3 m (a teleport, a surfacing) is not glided
	const double jx = double(b.x) - v.cx, jz = double(b.z) - v.cz;
	const bool surfaced = v.kind == BK_ENEMY && (v.state == BURROW || v.state == ERUPT) && b.state != BURROW && b.state != ERUPT;
	if (surfaced || std::sqrt(jx * jx + jz * jz) > MAX_STEP) {
		v.px = b.x;
		v.pz = b.z;
		v.pyaw = b.yaw;
	} else {
		v.px = v.cx;
		v.pz = v.cz;
		v.pyaw = v.cyaw;
	}
	v.cx = b.x;
	v.cz = b.z;
	v.cyaw = b.yaw;
	if (b.state != v.state) {
		const int32_t old = v.state;
		v.state = b.state;
		edge(v, old, b.state);
		if (v.mode != M_LIVE) {
			return;
		}
	}
	if (b.kind == BK_THRALL && b.swing != v.swing) {  // a thrall's blow lands the instant its swing starts: open the clip just before its impact
		v.swing = b.swing;
		play_strike(m, v, RL_ATTACK, b.action_s);
	}
}

void CrowdView::apply_hit(const CrowdHit &h) {
	const auto it = by_id.find(h.id);
	if (it == by_id.end()) {
		return;
	}
	View &v = views[it->second];
	if (v.mode != M_LIVE) {
		return;
	}
	const CrowdModel &m = models[v.model];
	catch_up(m, v);
	v.force = true;  // the flash and the recoil show on the next frame whatever the body's pose rate
	v.flash = 1.0;
	if (v.flash_v < 0.5) {  // every fresh hit recoils the body, whoever flashed it (DmCreature.set_flash)
		react(m, v, 1.0);
	}
	v.flash_v = 1.0;
	// DmEntityViews._on_hit: a visual shove away from the hero, bigger for harder hits, smaller for heavy bodies and an enemy mid-swing
	const bool under = v.state == BURROW || v.state == ERUPT;
	if (v.kind != BK_ENEMY || (v.flags & BF_INERT) || under || h.hp <= 0.0f) {
		return;
	}
	if (std::fabs(v.cx - focus_x) >= NEAR_X || std::fabs(v.cz - focus_z) >= NEAR_Z) {
		return;
	}
	const double frac = double(h.amount) / std::max(1.0, double(h.max_hp));
	const bool committed = v.state == ATTACK && v.state_t < v.action_s;
	double ix, iz;
	knock_impulse(frac * (committed ? 0.4 : 1.0), v.scale * v.scale, v.cx - focus_x, v.cz - focus_z, ix, iz);
	v.kvx += ix;
	v.kvz += iz;
}

// DmEntityViews._on_corpse: the dying body of the same kind within 1.2 m becomes the corpse; else one is laid down at the final pose.
void CrowdView::apply_corpse(const CrowdCorpse &c) {
	auto it = by_corpse.find(c.id);
	if (it != by_corpse.end()) {
		views[it->second].cseen = epoch;
		return;
	}
	int32_t best = -1;
	double best_d = 1.2;
	for (int32_t i = 0; i < int32_t(views.size()); i++) {
		const View &v = views[i];
		if (!v.alive || v.mode != M_DYING || v.kind != BK_ENEMY || v.def != c.def) {
			continue;
		}
		const double d = std::sqrt((v.cx - c.x) * (v.cx - c.x) + (v.cz - c.z) * (v.cz - c.z));
		if (d < best_d) {
			best_d = d;
			best = i;
		}
	}
	if (best < 0) {
		if (c.model < 0 || c.model >= int32_t(models.size())) {
			return;
		}
		View &nv = make_view(-c.id, BK_ENEMY, c.model);   // a laid body has no row: its own id, so its own dice
		best = int32_t(&nv - views.data());
		View &v = views[best];
		const CrowdModel &m = models[c.model];
		v.def = c.def;
		v.scale = c.scale;
		v.tint[0] = c.tint[0];
		v.tint[1] = c.tint[1];
		v.tint[2] = c.tint[2];
		v.glow = c.glow;
		v.px = v.cx = v.dx = c.x;
		v.pz = v.cz = v.dz = c.z;
		v.pyaw = v.cyaw = v.yaw = v.dyaw = c.facing;
		v.die_t = 5.0;
		v.has_settle = v.no_settle = true;
		if (resolve(m, v, RL_DEATH) >= 0 && play_death(m, v)) {  // hold_last_frame("death")
			v.t = m.seconds[v.death_clip];
		} else {
			v.toppled = 1.0;
		}
	}
	View &v = views[best];
	v.mode = M_CORPSE;
	v.shadow = false;
	v.corpse_id = c.id;
	v.cseen = epoch;
	by_corpse[c.id] = best;
}

void CrowdView::tick(const CrowdFeed &f) {
	epoch++;
	for (const CrowdBody &b : f.bodies) {
		apply_body(b);
	}
	for (int32_t i = 0; i < int32_t(views.size()); i++) {  // rows that are gone: a live body vanished without dying, a dead one is on its own
		View &v = views[i];
		if (v.alive && v.row_tied && v.epoch != epoch) {
			by_id.erase(v.id);
			v.row_tied = false;
			if (v.mode == M_LIVE) {
				start_fade(v);
			}
		}
	}
	for (const CrowdHit &h : f.hits) {
		apply_hit(h);
	}
	for (const CrowdCorpse &c : f.corpses) {
		apply_corpse(c);
	}
	for (int32_t i = 0; i < int32_t(views.size()); i++) {  // corpses the core no longer holds sink away
		View &v = views[i];
		if (v.alive && v.mode == M_CORPSE && v.cseen != epoch) {
			start_fade(v);
		}
	}
}

// ---------------------------------------------------------------------------------------------------------------- the views: advance

void CrowdView::set_thrall_shadows(bool p_on) {
	thrall_shadows = p_on;
	for (View &v : views) {
		if (v.kind == BK_THRALL) {
			v.shadow = p_on;  // as a new thrall gets it (every thrall casts, as today)
		}
	}
}

// DmEntityViews._shadow_lod: the nearest living enemies cast into the moon's shadow map, more of them while the field is not crowded.
void CrowdView::rank_shadows() {
	rank_scratch.clear();
	for (int32_t i = 0; i < int32_t(views.size()); i++) {
		const View &v = views[i];
		if (v.alive && v.mode == M_LIVE && v.kind == BK_ENEMY) {
			rank_scratch.emplace_back((v.cx - focus_x) * (v.cx - focus_x) + (v.cz - focus_z) * (v.cz - focus_z), i);
		}
	}
	std::sort(rank_scratch.begin(), rank_scratch.end());
	const size_t budget = size_t(int32_t(rank_scratch.size()) >= crowded_at ? crowded_casters : shadow_casters);
	for (size_t k = 0; k < rank_scratch.size(); k++) {
		View &v = views[rank_scratch[k].second];
		v.shadow = k < budget && !(v.flags & BF_MIST);  // a spectral body never casts
	}
}

// Returns false once the view is gone (it has finished sinking). A living body is `advance_live`'s.
bool CrowdView::advance(View &v, double p_dt, double p_alpha) {
	(void)p_alpha;
	const CrowdModel &m = models[v.model];
	const bool enemy = v.kind == BK_ENEMY;
	const double dt_eff = enemy ? p_dt * hitstop_scale : p_dt;  // the picture clock of a struck enemy honours the hitstop
	if (v.mode == M_FADE) {
		v.sink_t += p_dt;
		v.dy -= p_dt * SINK_SPEED;
		return v.sink_t <= SINK_S;
	}
	// dying and corpses: still where they fell
	v.die_t += p_dt;
	if (v.mode == M_DYING) {
		update_clips(m, v, dt_eff);
	} else if (v.die_t < CORPSE_ANIM_S && v.rest_t < CORPSE_REST_S) {  // a corpse's mixer stops shortly after its death clip has landed
		update_clips(m, v, dt_eff);
		if (has_landed(m, v)) {
			v.rest_t += p_dt;
		}
	}
	if (v.toppled > 0.0) {  // DmEntityViews._topple
		v.toppled = std::min(1.0, v.toppled + p_dt * TOPPLE_RATE);
		v.dy = TOPPLE_Y * v.toppled;
	}
	if (!(v.has_settle && v.no_settle)) {  // DmEntityViews._settle: once the fall has mostly played the body lands and eases a little way into the ground
		if (!v.has_settle && has_landed(m, v)) {
			v.has_settle = true;
			v.settle_t = 0.0;
			v.settle_y = v.toppled > 0.0 ? 0.0 : v.dy;
			if (landings.size() < LANDINGS_MAX * 3) {  // the dust where it lands (DmEnemyFx reads them each frame)
				landings.insert(landings.end(), { float(v.dx), float(v.dz), float(v.scale) });
			}
		}
		if (v.has_settle) {
			v.settle_t += p_dt;
			const double base = v.toppled > 0.0 ? v.dy : v.settle_y;
			v.dy = base - settle_depth(v.settle_t, SETTLE_DEPTH * v.scale);
		}
	}
	if (v.mode == M_DYING && v.die_t > DYING_CRUMBLE_S) {  // no corpse arrived (corpse kind "none"): crumble away
		start_fade(v);
	}
	return true;
}

// A living body's pose: the turn, the legs, the clip, the flash, the knock, the rise and the hover, over `p_dt` seconds (a frame, or every frame since the last
// pose update when the body works its pose out less often) and where it stands at the interpolation `p_alpha`.
void CrowdView::advance_live(const CrowdModel &m, View &v, double p_dt, double p_alpha) {
	const bool enemy = v.kind == BK_ENEMY;
	const double dt_eff = enemy ? p_dt * hitstop_scale : p_dt;  // the picture clock of a struck enemy honours the hitstop
	v.hidden = enemy && (v.state == BURROW || v.state == ERUPT);
	v.yaw = turn_toward(v.yaw, lerp_ang(v.pyaw, v.cyaw, p_alpha), p_dt, TURN_GAIN, ENEMY_TURN_RATE);
	// the legs: the core's ground speed, smoothed (DmEntityViews._measure_speed); walking starts at the pace the sim moves the body
	const bool moving = v.raw_speed > MOVING_SPEED;
	if (moving && !v.moving) {
		v.gs = v.raw_speed;
		v.has_gs = true;
	}
	v.moving = moving;
	v.gs = smooth_speed(v.has_gs ? v.gs : v.raw_speed, v.raw_speed, p_dt, SPEED_TAU);
	v.has_gs = true;
	// DmEnemy._loco / DmThrall: a swing, a flinch, a death or a dig-in keeps its clip
	const bool free = enemy ? !(v.state == ATTACK || v.state == HURT || v.state == DEAD || v.state == ERUPT || v.state == DIG || v.state == BURROW)
							: !(v.state == TS_ATTACK || v.state == TS_DEAD);
	if (free) {
		if (moving) {
			set_ground_speed(m, v, v.gs);
		} else {
			set_loop(m, v, RL_IDLE, 1.0);
		}
	}
	if (v.flash > 0.0) {
		v.flash = std::max(0.0, v.flash - p_dt * (enemy ? FLASH_DECAY_ENEMY : FLASH_DECAY_THRALL));
	}
	if (std::fabs(v.flash - v.flash_v) >= 0.02) {  // DmCreature.set_flash ignores smaller changes
		v.flash_v = v.flash;
	}
	if (enemy && (v.kx != 0.0 || v.kz != 0.0 || v.kvx != 0.0 || v.kvz != 0.0)) {
		step_knock(v.kx, v.kz, v.kvx, v.kvz, dt_eff);
	}
	const bool rising = v.state == (enemy ? int32_t(RISING) : int32_t(TS_RISING));
	const double rise = rising ? std::min(1.0, (v.state_t + p_alpha * TICK) / (enemy ? ENEMY_RISE_S : THRALL_RISE_S)) : 1.0;
	v.rise_k = rise;
	update_clips(m, v, dt_eff);
	v.dx = v.px + (v.cx - v.px) * p_alpha + v.kx;
	v.dz = v.pz + (v.cz - v.pz) * p_alpha + v.kz;
	v.dyaw = v.yaw;
	double lift = 0.0;
	if (v.hover > 0.0) {  // the hover bob (DmEntityViews.sync)
		lift = enemy ? v.hover + std::sin(clock_ms / 520.0 + v.id) * ((v.flags & BF_FLYER) ? 0.18 : 0.12) : v.hover + std::sin(clock_ms / 400.0 + v.id) * 0.1;
	}
	if (enemy && v.state == ATTACK && (v.flags & (BF_DIVING | BF_GROUNDED))) {  // DmEnemyGargoyle._process: climb over the mark for the first half of the wind-up, drop onto it, then sit grounded
		const double kk = (v.flags & BF_GROUNDED) || v.action_s <= 0.0 ? 1.0 : (v.state_t + p_alpha * TICK) / v.action_s;
		lift = 0.05;
		if (kk < 1.0) {
			lift = kk < 0.5 ? v.hover + kk * 3.0 : (v.hover + 1.5) * std::pow(1.0 - (kk - 0.5) * 2.0, 2.0);
		}
	}
	const double sink = enemy ? (v.flags & BF_FLYER ? 0.0 : ENEMY_SINK * m.height) : THRALL_SINK;
	v.dy = -sink * (1.0 - rise) * (1.0 - rise) + lift;
}

// ---------------------------------------------------------------------------------------------------------------- the views: the camera's view

void CrowdView::set_view(const float *p_view_projection) {
	has_view = false;
	if (p_view_projection == nullptr) {
		return;
	}
	const float *m = p_view_projection;  // column-major: row r, column c is m[c * 4 + r]
	for (int k = 0; k < 6; k++) {  // left, right, bottom, top, near, far: row 3 plus or minus row 0, 1 or 2 (Gribb and Hartmann)
		const int row = k / 2;
		const float sign = (k % 2 == 0) ? 1.0f : -1.0f;
		float p[4];
		for (int c = 0; c < 4; c++) {
			p[c] = m[c * 4 + 3] + sign * m[c * 4 + row];
		}
		const float len = std::sqrt(p[0] * p[0] + p[1] * p[1] + p[2] * p[2]);
		if (!(len > 1e-9f)) {  // not a camera (all zero, a NaN): no culling
			return;
		}
		for (int c = 0; c < 4; c++) {
			planes[k][c] = p[c] / len;
		}
	}
	has_view = true;
}

void CrowdView::set_light(double p_x, double p_y, double p_z) {
	const double len = std::sqrt(p_x * p_x + p_y * p_y + p_z * p_z);
	has_light = len > 1e-9;
	light[0] = has_light ? p_x / len : 0.0;
	light[1] = has_light ? p_y / len : 0.0;
	light[2] = has_light ? p_z / len : 0.0;
}

// A body is drawn when its bounding sphere touches the view. A shadow caster outside the view is kept while its shadow can fall into it: with the light's
// direction known, the shadow is the sphere swept from the body to where the light's ray through it meets the ground (at most SHADOW_RUN_MAX metres on),
// and the body goes only when that whole run lies outside one plane; unknown, the sphere is `cost.shadow_reach` metres bigger.
bool CrowdView::in_view(double p_x, double p_y, double p_z, double p_r, bool p_caster) const {
	if (!has_view) {
		return true;
	}
	double r = p_r, ex = p_x, ey = p_y, ez = p_z;
	bool run = false;
	if (p_caster) {
		if (has_light) {
			run = true;
			const double s = light[1] < -0.05 ? std::min(SHADOW_RUN_MAX, std::max(0.0, (p_y + p_r) / -light[1])) : SHADOW_RUN_MAX;
			ex += light[0] * s;
			ey += light[1] * s;
			ez += light[2] * s;
		} else {
			r += cost.shadow_reach;
		}
	}
	for (int k = 0; k < 6; k++) {
		const float *q = planes[k];
		if (q[0] * p_x + q[1] * p_y + q[2] * p_z + q[3] >= -r) {
			continue;
		}
		if (run && q[0] * ex + q[1] * ey + q[2] * ez + q[3] >= -r) {
			continue;
		}
		return false;
	}
	return true;
}

// A body's bounding radius: its model's sphere about the feet, at the body's size, and a little over for the body layer's lunge and squash.
double CrowdView::view_radius(const View &v) const {
	const CrowdModel &m = models[v.model];
	return (m.radius > 0.0 ? m.radius : m.height * 1.2) * v.scale + CULL_SLACK;
}

// ---------------------------------------------------------------------------------------------------------------- the views: draw

// The next free instance of the group a body belongs in: its level of detail by the distance to the camera, and the shadow setting.
float *CrowdView::slot_for(const View &v, float p_cam_x, float p_cam_y, float p_cam_z) {
	const CrowdModel &m = models[v.model];
	const double cdx = v.dx - p_cam_x, cdz = v.dz - p_cam_z;
	const double dist = std::sqrt(cdx * cdx + double(p_cam_y) * p_cam_y + cdz * cdz);
	int32_t lod = 0;
	for (int32_t l = 0; l + 1 < m.lods && l < int32_t(m.lod_dist.size()); l++) {
		if (dist >= m.lod_dist[l]) {
			lod = l + 1;
		}
	}
	CrowdGroup &g = group_for(v.model, lod, v.shadow);
	if (g.count >= g.cap) {
		grow(g);
	}
	const int32_t tris = lod < int32_t(m.lod_tris.size()) ? m.lod_tris[lod] : 0;
	last.triangles += tris;
	if (v.shadow) {
		last.casting++;
		last.casting_thralls += v.kind == BK_THRALL ? 1 : 0;
		last.casting_triangles += tris;
	}
	return &g.buf[size_t(g.count++) * STRIDE];
}

// One instance row (CrowdVatData's packers): 12 transform, 4 colour, 4 custom data. `r_off` (optional) gets the lunge's share of the translation, so a body
// that is placed again without working its pose out anew (the cached row) can follow where it stands.
void CrowdView::pose_row(const CrowdModel &m, const View &v, float *w, double *r_off) const {
	(void)m;
	// root: yaw, then the tip-over about Z, then the scale; the model node under it: the lunge forward, the recoil's pitch and roll, the squash
	const M3 root = mul(rot_y(v.dyaw), rot_z(PI_ * 0.5 * v.toppled));
	const M3 model = mul(mul(rot_x(v.pitch), rot_z(v.roll)), M3{ { { 1.0 + v.sq * 0.6, 0, 0 }, { 0, 1.0 - v.sq, 0 }, { 0, 0, 1.0 + v.sq * 0.6 } } });
	M3 b = mul(root, model);
	for (int i = 0; i < 3; i++) {
		for (int j = 0; j < 3; j++) {
			b.m[i][j] *= v.scale;
		}
	}
	const double fx = root.m[0][2] * v.scale * v.zo, fy = root.m[1][2] * v.scale * v.zo, fz = root.m[2][2] * v.scale * v.zo;
	if (r_off != nullptr) {
		r_off[0] = fx;
		r_off[1] = fy;
		r_off[2] = fz;
	}
	for (int i = 0; i < 3; i++) {
		w[i * 4] = float(b.m[i][0]);
		w[i * 4 + 1] = float(b.m[i][1]);
		w[i * 4 + 2] = float(b.m[i][2]);
	}
	w[3] = float(v.dx + fx);
	w[7] = float(v.dy + fy);
	w[11] = float(v.dz + fz);
	w[12] = v.tint[0];
	w[13] = v.tint[1];
	w[14] = v.tint[2];
	// The game's emissive lerp in 8 steps, above twice the glow slot: COLOR.a = slot * 2 + flash (the shader splits them; exact in a half float up to slot 63).
	w[15] = float(v.glow * 2) + float(std::round(std::min(1.0, std::max(0.0, v.flash_v)) * FLASH_LEVELS) / FLASH_LEVELS);
	const int32_t clip = v.cur >= 0 ? v.cur : 0;
	w[16] = float(clip);
	w[17] = float(v.cur >= 0 ? v.t : 0.0);
	if (v.prev >= 0 && v.blend_d > 0.0) {  // CrowdVatData.pack_custom: previous clip + the weight of its pose below 1
		const double weight = std::min(0.999, std::max(0.0, 1.0 - v.blend_t / v.blend_d));
		w[18] = float(double(v.prev) + weight);
		w[19] = float(v.pt);
	} else {
		w[18] = 0.0f;
		w[19] = 0.0f;
	}
}

// A body that is not alive any more (dying, a corpse, sinking): outside the view it is not written, else its row goes into its group.
void CrowdView::emit(View &v, float p_cam_x, float p_cam_y, float p_cam_z) {
	if (v.hidden || v.model < 0) {
		return;
	}
	if (cost.cull && has_view && !in_view(v.dx, v.dy, v.dz, view_radius(v), v.shadow)) {
		last.culled++;
		return;
	}
	pose_row(models[v.model], v, slot_for(v, p_cam_x, p_cam_y, p_cam_z), nullptr);
}

// A living body, once a frame. It is placed every frame (the interpolation between the last two ticks), but works its pose out (turn, legs, clip time,
// flash, knock, hover and the instance row) at its band's rate: every frame near the camera, `cost.mid_hz` beyond `cost.mid_m`, `cost.far_hz` beyond `cost.far_m`
// (client/crowd/README.md "Crowd cost"). Between updates the last pose row is written again with the body's new place in it. A body outside the view is not written
// and keeps the far rate; one coming back into view, or whose state, hit or look changed on a tick (`force`), works its pose out at once.
void CrowdView::draw_live(View &v, double p_dt, double p_alpha, float p_cam_x, float p_cam_y, float p_cam_z, bool p_full_rate) {
	const CrowdModel &m = models[v.model];
	const bool enemy = v.kind == BK_ENEMY;
	const double nx = v.px + (v.cx - v.px) * p_alpha + v.kx;  // where it stands this frame (advance_live computes the same)
	const double nz = v.pz + (v.cz - v.pz) * p_alpha + v.kz;
	const double bx = nx - p_cam_x, bz = nz - p_cam_z, d2 = bx * bx + double(p_cam_y) * p_cam_y + bz * bz;
	int32_t band = 0;
	double hz = 0.0;
	if (!p_full_rate) {
		if (d2 >= cost.far_m * cost.far_m) {
			band = 2;
			hz = cost.far_hz;
		} else if (d2 >= cost.mid_m * cost.mid_m) {
			band = 1;
			hz = cost.mid_hz;
		}
	}
	const bool under = enemy && (v.state == BURROW || v.state == ERUPT);
	const bool culled = !under && cost.cull && has_view && !in_view(nx, v.dy, nz, view_radius(v), v.shadow);
	if (culled && !p_full_rate) {  // nobody sees it: the far rate
		hz = cost.far_hz;
	} else if (hz > 0.0 && (v.one_shot >= 0 || v.kick_t >= 0.0 || v.lunge_t >= 0.0 || v.rise_k < 1.0)) {  // a swing, a flinch, a recoil, a rise: always every frame (DmCreature.busy)
		hz = 0.0;
	}
	last.band[band]++;
	last.culled += culled ? 1 : 0;
	v.band = band;
	if (!culled && v.was_culled) {  // coming back into view: its pose is brought up to date before it is drawn
		v.force = true;
	}
	v.was_culled = culled;
	v.acc += p_dt;
	bool due = true;
	if (hz > 0.0) {
		const double period = 1.0 / hz;
		if (v.force || !v.crow_ok) {
			v.credit = period * phase_of(v.id);  // joins its band spread over the period, not all on the same frame
		} else {
			v.credit += p_dt;
			due = v.credit >= period - 1e-9;
			if (due) {
				v.credit = std::min(period, v.credit - period);
			}
		}
	}
	if (due) {
		const double step = v.acc;
		v.acc = 0.0;
		advance_live(m, v, step, p_alpha);
		v.force = false;
		v.pose_updates++;
		pose_total++;
		last.pose_updates++;
		if (hz > 0.0) {
			pose_row(m, v, v.crow, v.crow_off);
			v.crow_ok = true;
		} else {
			v.crow_ok = false;
		}
		if (culled || v.hidden) {
			return;
		}
		float *w = slot_for(v, p_cam_x, p_cam_y, p_cam_z);
		if (hz > 0.0) {
			std::memcpy(w, v.crow, sizeof(v.crow));
		} else {
			pose_row(m, v, w, nullptr);
		}
		return;
	}
	v.dx = nx;
	v.dz = nz;
	if (culled || v.hidden) {
		return;
	}
	float *w = slot_for(v, p_cam_x, p_cam_y, p_cam_z);
	std::memcpy(w, v.crow, sizeof(v.crow));
	w[3] = float(v.dx + v.crow_off[0]);
	w[7] = float(v.dy + v.crow_off[1]);
	w[11] = float(v.dz + v.crow_off[2]);
}

void CrowdView::draw(double p_dt, double p_alpha, float p_cam_x, float p_cam_y, float p_cam_z) {
	frames++;
	clock_ms += p_dt * 1000.0;
	for (CrowdGroup &g : groups) {
		g.count = 0;
	}
	last = CrowdStats();
	if (frames % RERANK_EVERY == 0) {
		rank_shadows();
	}
	const bool full_rate = !cost.anim_lod || hitstop_scale != 1.0;  // a hit stop freezes the struck bodies' picture clock: every body keeps up with it meanwhile
	for (int32_t i = 0; i < int32_t(views.size()); i++) {
		View &v = views[i];
		if (!v.alive) {
			continue;
		}
		if (v.mode == M_LIVE) {
			draw_live(v, p_dt, p_alpha, p_cam_x, p_cam_y, p_cam_z, full_rate);
			continue;
		}
		if (!advance(v, p_dt, p_alpha)) {  // finished sinking
			drop_view(i);
			continue;
		}
		emit(v, p_cam_x, p_cam_y, p_cam_z);
	}
	for (const CrowdGroup &g : groups) {
		if (g.count > 0) {
			last.groups_used++;
			last.groups_casting += g.shadow ? 1 : 0;
		}
	}
}

} // namespace dm
