#pragma once
// The core's tables and the enemy brain (native/README.md "Design"). Enemies live in spawn order: a slot only moves by stable
// compaction when a dead body is removed, so slot order is spawn order and every scan keeps today's tie-breaks. The brain is a port of
// godot/enemies (DmEnemy, its states and kinds) for the Graves roster; timers count in doubles the way the GDScript did. Thralls
// (thralls.cpp) and corpses (corpses.cpp) live in the same World: heroes are enemies' targets first, then thralls in raise order.
#include <cmath>
#include <cstdint>
#include <limits>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

#include "body.h"
#include "corpse.h"
#include "events.h"
#include "grid.h"
#include "replica.h"
#include "rng.h"
#include "status.h"
#include "thrall.h"

namespace dm {

// Wire ids of today's enemy states (godot/enemies/states/dm_enemy_state.gd): append only.
enum EnemyState : int32_t { RISING = 0, IDLE, CHASE, ATTACK, HURT, RETURN, DEAD, FLEE, BURROW, ERUPT, DIG, EMERGE };
enum Behavior : int32_t { B_MELEE = 0, B_FLANK, B_CASTER, B_HAZARD };
enum Blow : int32_t { BLOW_MELEE = 0, BLOW_CONE, BLOW_DUST, BLOW_SLAM };
// Damage kinds of a hit on a target (the sim's hurt `from`; GDScript maps them back to strings): append only.
enum HitKind : int32_t { HK_MELEE = 0, HK_TOXIC, HK_BURN, HK_EMBER, HK_DUST, HK_CURSE, HK_TOLL };
// Telegraph and cue kinds (DmEnemy.telegraph / cue): append only.
enum Tell : int32_t { TELL_CONE = 0, TELL_SLAM, TELL_DUST, TELL_ERUPT, TELL_TOLL };
enum Cue : int32_t { CUE_SLAM = 0, CUE_ERUPT, CUE_DIG_IN };
enum ZoneKind : int32_t { ZONE_DUST = 0, ZONE_TOXIC };
// Elite affixes in DmSimData.AFFIX_ORDER (bit k of Enemy::affixes) and the one-off beats DmAffixSet.moment sends: append only.
enum Affix : int32_t { AF_BELL_TOLLED = 0, AF_HUNGERING, AF_SHROUDED, AF_VENGEFUL, AF_COUNT };
enum AffixMoment : int32_t { AM_TELL = 0, AM_TOLL, AM_HUNGERING, AM_VENGEFUL, AM_UNVEIL };
constexpr const char *AFFIX_NAMES[AF_COUNT] = { "bellTolled", "hungering", "shrouded", "vengeful" };
constexpr const char *AFFIX_MOMENT_NAMES[] = { "tell", "toll", "hungering", "vengeful", "unveil" };

constexpr double TICK = 1.0 / 60.0;
constexpr double RISE_S = 1.1;
constexpr double BODY_LINGER_S = 4.0;   // the director frees a dead body 4 s later; until then it counts toward the global cap
constexpr double AGGRO_RANGE = 15.0, DROP_MULT = 1.5, LEASH = 30.0, HOME_ARRIVE = 1.0;
constexpr double ATTACK_TRIGGER_PAD = 0.35, STOP_FRAC = 0.8, STRIKE_REACH_MULT = 1.35, STRIKE_REACH_PAD = 0.4;
constexpr double WANDER_SPEED_MULT = 0.3, WANDER_RADIUS = 4.0, STAGGER_ICD = 0.9, RECOVER_S = 0.3, HURT_S = 0.3;
constexpr double REPATH_S = 0.3, REPATH_MOVE_SQ = 1.0, DIRECT_RANGE_SQ = 9.0, SCAN_S = 0.25, TURN_RATE = 14.0;
constexpr double INCENSE_MOVE = 1.3, INCENSE_ATTACK = 1.25, PATH_DESIRED = 0.5;
constexpr double KITE_BACK_OFF = 3.5, KITE_BACK_SPEED = 0.8, CONE_HALF_ANGLE = 30.0 * 3.14159265358979323846 / 180.0, CONE_PAD = 0.4;
constexpr double ZONE_TARGET_PAD = 0.45, ZONE_TICK_S = 1.0, BURROW_STUCK_S = 0.8, DEFAULT_SLAM_R = 1.9;
// Crowd spacing (World::resolve_overlaps): the share of an overlap removed per tick, and the most a body is moved by it in one tick.
constexpr double OVERLAP_EASE = 0.3, OVERLAP_MAX_STEP = 0.15;
// DmAffixSet: the shroud check runs every LOOK_S; a Miasma cover holds 350 ms (today wall-clock, here game time); a hungry body that found
// nothing to eat looks again 0.5 s later; Vengeful's Risen stand on a 1.4 m ring.
constexpr double AFFIX_LOOK_S = 0.1, MIASMA_HOLD_S = 0.35, HUNGER_RETRY_S = 0.5, VENGEFUL_RING = 1.4;

struct Tuning {  // data/content/enemies.json blocks
	double elite_hp = 3.6, elite_damage = 1.5, elite_windup = 0.85, elite_cooldown = 0.8, elite_radius = 1.25;
	double dust_radius = 2.0, dust_cloud_s = 3.5, dust_cloud_dps = 0.35;
	double burrow_speed = 4.2, burrow_surface_r = 2.5, burrow_erupt_r = 1.8, burrow_erupt_mult = 1.25, burrow_erupt_mult_graves = 1.0;
	double burrow_erupt_s_graves = 1.0, burrow_erupt_s = 0.8, burrow_dig_s = 0.8, burrow_dig_at = 0.5, burrow_travel = 8.0;
	int32_t burrow_max_per_target = 3;
	double frenzy_at = 0.5;
	double elite_scale = 1.35;  // ELITE.scale: an elite's node scale, which its corpse carries
	// AFFIX_TUNING (stunMs of bellTolled is data the sim never used; shrouded's damageTakenMult lives in the status rule)
	double bell_interval = 6.0, bell_windup = 0.9, bell_r = 3.0, bell_damage = 0.6;
	double hunger_interval = 4.0, hunger_reach = 5.0, hunger_heal = 0.15;
	int32_t vengeful_risen = 3;
};

// Thralls, corpses and the toxic pool. Numbers come from data (World::load in DmCore): content/{abilities,fen,statuses,gameplay_legendary,
// runes}.json, combat/enemies.json, and the constants of godot/sim/sim_consts.gd, dm_corpse_field.gd and dm_thrall.gd. The defaults are
// today's values so a core that loads nothing still plays; core_thralls.gd asserts they equal what the data says.
struct LegionTuning {
	// DmSimConsts
	double corpse_lifetime = 26.0, toxic_rupture = 5.0, thrall_leash = 13.0, thrall_teleport = 24.0, thrall_rise = 0.9;
	double follow_arrive = 0.12, follow_seat_moving = 0.3, follow_catchup = 5.0;
	int32_t max_corpses = 45;
	// DmCorpseField
	double extra_ring = 1.6, fallback_pick_range = 7.0, toxic_r = 2.4, toxic_s = 5.0, toxic_tick = 0.4, toxic_dmg = 6.0;
	// DmThrall
	double engage_range = 10.0, corpse_s = 1.4, weight_shield = 0.55, weight_other = 1.1;
	// abilities.json RALLY
	double rally_damage = 1.4, rally_attack = 1.3, rally_heal = 0.2, rally_s = 6.0, rally_bonus_s = 2.0;
	// fen.json HAG_HEX
	double hag_thrall_damage = 0.7;
	// statuses.json PLAGUE_BURST
	double plague_radius = 2.6, plague_damage = 2.5, plague_pool_radius = 2.4, plague_pool_s = 5.0, plague_pool_dps = 0.35;
	// gameplay_legendary.json LEGEND
	double death_burst_r = 3.0;
	// runes.json RUNE_TUNING.colossus
	double colossus_cleave_frac = 0.6, colossus_cleave_r = 2.4, colossus_slots = 2.0;
	// combat/enemies.json damage_scale
	double damage_scale_base = 1.0, damage_scale_per_level = 0.15;
};

struct EnemyDef {
	std::string id;
	double hp = 1, damage = 1, speed = 1, radius = 0.45;
	double attack_range = 1.3, windup_s = 0.4, cooldown_s = 1.3, scale = 1, hit_run = 0, flying = 0, slam_r = DEFAULT_SLAM_R;
	int32_t behavior = B_MELEE, blow = BLOW_MELEE, hit_kind = HK_MELEE;
	int32_t corpse = CK_NORMAL, death_corpses = 1;  // def "corpse" kind, "deathCorpses" (extra risen corpses on a ring)
	bool burrow = false, frenzy = false;
};

struct Enemy : Body {
	int32_t def = 0, level = 1, area = 0, state = IDLE, last_source = 0, target = 0, phase = 0;
	bool elite = false, in_graves = true, dug_in = false;
	uint8_t affixes = 0;  // bit per Affix
	double hp_mult = 1, damage_mult = 1;  // the spawn's multipliers (Vengeful's Risen are as strong as the body that fell)
	// DmAffixSet: its own clock (runs only while the body acts), the bell and hunger countdowns (-1 = fresh), the shroud check, the last Miasma cover
	double affix_t = 0, toll_cd = -1, toll_at = -1, hunger_cd = -1, shroud_t = 0, miasma_at = -std::numeric_limits<double>::infinity();
	float toll_x = 0, toll_z = 0;
	float x = 0, z = 0, yaw = 0, home_x = 0, home_z = 0, aim_x = 0, aim_z = 0, last_x = 0, last_z = 0;
	double damage = 1, speed = 1, radius = 0.45, attack_range = 1.3, windup_s = 0.4, cooldown_s = 1.3;
	double attack_cd = 0, state_t = 0, flank_side = 1, scan_t = 0, repath_t = 0, stagger_t = 0, wander_heading = 0;
	double hurt_s = HURT_S, erupt_s = 1.0, incense_t = 0;
	double want_vx = 0, want_vz = 0, ground_speed = 0, burrow_left = std::numeric_limits<double>::infinity(), stuck_t = 0;
	bool has_nav_goal = false;
	float nav_gx = 0, nav_gz = 0;
	int32_t path_len = 0, path_i = 0;
	float path[PATH_POINTS * 2] = {};
	Rng rng;
};

struct External {  // a hero or a boss: GDScript writes it every tick
	int32_t id = 0, kind = 0;  // kind 0 hero, 1 boss. A boss counts as a target for thralls while alive (false while it cannot be hurt)
	float x = 0, z = 0;
	double radius = 0.4, weight = 1.0;
	bool alive = true;
};

// Something an enemy can aim at: a hero, or a living thrall (DmEnemy.TARGET_GROUP "dm_target": heroes first, then thralls in raise order).
struct Tgt {
	int32_t id = 0;
	float x = 0, z = 0;
	double radius = 0.4, weight = 1.0;
};

struct Zone {  // a hostile ground zone (DmHostileZone): pulses dps x period at every target within radius + 0.45
	int32_t id = 0, kind = ZONE_DUST, source = 0, hit_kind = HK_DUST;
	float x = 0, z = 0;
	double radius = 2, lifetime = 1, dps = 1, age = 0, tick = -1, period = ZONE_TICK_S;
};

// Path queries go through this hook (the Godot navigation server in DmCore; straight lines when unset, as in tests).
struct NavHook {
	void *user = nullptr;
	int32_t (*path)(void *user, float fx, float fz, float tx, float tz, float *out_xz, int32_t max_points) = nullptr;
	void (*clamp)(void *user, float &x, float &z) = nullptr;
};

struct World {
	uint64_t seed = 1;
	int32_t next_id = 1;
	double clock = 0;
	bool wander_enabled = true;  // DmEnemy.wander_enabled (tests turn it off)
	Tuning tun;
	LegionTuning legion;
	NavHook nav;
	std::vector<EnemyDef> defs;
	std::vector<StatusRule> status_rules;
	int32_t st_stun = -1, st_frenzy = -1, st_withered = -1, st_chill = -1, st_hex = -1, st_barrier = -1, st_shrouded = -1;
	std::vector<int32_t> st_cleared;  // ids a ghoul's dig-in clears (DmStatusSet.CLEARED)
	std::unordered_map<std::string, int32_t> def_index;
	std::vector<std::string> areas;
	std::unordered_map<std::string, int32_t> area_index;
	std::vector<Enemy> enemies;
	std::unordered_map<int32_t, int32_t> enemy_slot;  // id -> slot
	// Bodies born inside a kill (Vengeful's Risen): id, rolls and EV_ENEMY_SPAWNED happen at the kill in today's order, but the table only
	// grows in flush_spawns(), because a kill can happen while a caller holds an Enemy& (a DoT lump, a swing that kills a bursting thrall).
	std::vector<Enemy> pending_spawns;
	std::vector<External> externals;
	std::vector<Zone> zones;
	Grid grid;
	int32_t grid_count = 0;  // slots the grid was built with; later spawns are scanned directly
	Events events;
	std::vector<int32_t> scratch;
	std::vector<float> gx, gz;  // grid input

	// Thralls, in raise order (DmThrallHost._list order; dead bodies stay 1.4 s, state DEAD).
	std::vector<Thrall> thralls;
	std::unordered_map<int32_t, int32_t> thrall_slot;  // id -> slot
	std::vector<int32_t> legion_owner;                 // per owner: the Legion of the Unburied burst fraction (DmThrallHost.legend)
	std::vector<double> legion_burst;
	std::vector<int32_t> crumbled_out;                 // thralls the last raise_thrall made room by crumbling
	std::vector<int32_t> room_scratch;
	// Corpses, oldest first (DmCorpseField.corpses in insertion order). Their clock is their own: it ticks in the corpse phase of step().
	std::vector<Corpse> corpses;
	int32_t next_corpse_id = 1;
	double corpse_time = 0, corpse_next_due = std::numeric_limits<double>::infinity(), corpse_life_mult = 1.0;
	std::vector<std::string> reasons;      // corpse reasons by code (CorpseReason first, then interned)
	std::vector<int32_t> area_levels;      // DmCorpseField.area_level per area id; today nothing sets it, so the toxic pool hurts as level 1
	std::vector<int32_t> id_scratch;
	std::vector<int32_t> toll_hits;   // the bell's targets (kept apart from id_scratch, which a burst inside the toll reuses)
	std::vector<double> sep_scratch;  // thrall separation: pushed x, z per thrall
	std::vector<double> overlap_scratch;  // enemy crowd spacing: correction x, z per enemy
	std::vector<int32_t> near_scratch;
	mutable std::vector<std::pair<double, int32_t>> hit_scratch;  // corpse queries: squared distance, id

	World();
	int32_t area_id(const std::string &p_area);
	void rebuild_grid();  // the grid over this tick's positions (step() and a puppet's step_puppet() end with it)
	int32_t spawn_enemy(int32_t p_def, float p_x, float p_z, int32_t p_level, double p_hp_mult, double p_damage_mult, bool p_elite, int32_t p_area, bool p_rising, int32_t p_affixes = 0);
	// Adds the bodies a kill queued. step() calls it last; DmCore calls it before returning from anything that can kill outside the tick.
	void flush_spawns();
	// DmAffixSet.strip_shroud (Last Light, a Warden sweep): the ward is gone for good. False when the body has none.
	bool strip_shroud(int32_t p_slot);
	// Damage from a cast, a thrall, a zone or a boss: a kill resolves at once (combat map section 7). Returns the amount dealt.
	double damage_enemy(int32_t p_slot, double p_amount, int32_t p_source, bool p_allow_stagger, bool &r_killed);
	void stun(int32_t p_slot, double p_seconds);
	int32_t status_id(const std::string &p_name) const;
	// DmStatusSet.apply on an enemy or a thrall. `cap` < 0 = the rule's (stack cap or barrier cap), `duration` < 0 = the rule's.
	void apply_status(Body &b, int32_t p_status, int32_t p_source, double p_stacks, double p_duration, double p_dps, double p_cap, double p_amount);
	bool remove_status(Body &b, int32_t p_status);
	Body *body(int32_t p_id);  // an enemy or a thrall by id, or null
	const Body *body(int32_t p_id) const;
	void step(double p_dt);
	void enemies_in_radius(float p_x, float p_z, float p_r, std::vector<int32_t> &out);
	const External *find_external(int32_t p_id) const;

	// ---- thralls (thralls.cpp): the brain of DmThrall and the host parts of DmThrallHost
	// Raises a thrall for `owner` at (x, z): makes room under `cap` (< 0 = no cap) by crumbling the oldest ordinary one first, a Colossus last,
	// after a new Colossus replaced the old one. Returns the id, or 0 when the owner is missing or dead.
	int32_t raise_thrall(const ThrallSpec &p_spec, int32_t p_owner, float p_x, float p_z, float p_yaw, double p_cap);
	bool damage_thrall(int32_t p_slot, double p_amount, int32_t p_source, bool &r_killed);
	void kill_thrall(int32_t p_slot, int32_t p_reason, int32_t p_source);
	void rally_thralls(int32_t p_owner, double p_seconds, int32_t p_focus);
	void rally_thrall(Thrall &t, double p_seconds, int32_t p_focus);
	void stun_thrall(Thrall &t, double p_seconds);
	void recall_thralls(int32_t p_owner);
	void set_legion_burst(int32_t p_owner, double p_fraction);
	int32_t thrall_count(int32_t p_owner) const;  // living (rising ones too); owner 0 = everyone
	double thrall_places(int32_t p_owner) const;  // legion places used (DmThrallHost.places_used)
	double thrall_weight(int32_t p_kind) const { return p_kind == TK_COLOSSUS ? legion.colossus_slots : 1.0; }  // DmThralls.weight
	double thrall_target_weight(const Thrall &t) const { return t.kind == TK_SHIELDBEARER ? legion.weight_shield : legion.weight_other; }
	void thralls_in_radius(float p_x, float p_z, float p_r, int32_t p_owner, std::vector<int32_t> &out) const;

	// ---- corpses (corpses.cpp): DmCorpseField's host logic
	int32_t add_corpse(double p_x, double p_z, int32_t p_kind, int32_t p_def, bool p_elite, double p_facing, double p_scale, int32_t p_area);
	bool consume_corpse(int32_t p_id, int32_t p_by, int32_t p_reason);
	int32_t pick_corpse(float p_ax, float p_az, double p_pick_r, double p_max_range, float p_fx, float p_fz, int32_t p_area) const;  // area < 0 = any
	void corpses_in_radius(float p_x, float p_z, double p_r, int32_t p_area, std::vector<int32_t> &out) const;  // nearest first, id breaks ties
	int32_t corpse_index(int32_t p_id) const;
	int32_t reason_id(const std::string &p_reason);
	int32_t area_level(int32_t p_area) const { return p_area >= 0 && p_area < int32_t(area_levels.size()) ? area_levels[p_area] : 1; }
	double damage_scale(double p_level) const { return legion.damage_scale_base + legion.damage_scale_per_level * (p_level - 1.0); }  // DmEnemyStats.damage_scale

	// ---- co-op (snapshot.cpp, reliable.cpp, puppet.cpp; native/README.md "Co-op"). The host builds the messages; a guest's core is a puppet that applies them.
	bool puppet = false;  // a guest's core: no brains and no rules, the bodies are the host's
	Replica rep;
	uint32_t content_hash() const;  // the defs, status rules, kinds and the numbers a puppet derives events from: two builds with other data refuse each other's messages
	// host
	void set_replication(bool p_on);                           // start or stop collecting reliable events (the cursor starts at the end of the event buffer)
	void write_snapshot(std::vector<uint8_t> &r_out, uint32_t p_tick);
	void pump_reliable();                                      // encode the events since the last pump (take_events calls it before it clears the buffer)
	bool take_reliable(std::vector<uint8_t> &r_out);           // the batch since the last one; false when nothing happened
	void seal_pending();                                       // close the records waiting into a numbered batch that take_reliable() hands out next
	void write_baseline(std::vector<uint8_t> &r_out);          // the whole present as reliable records, for a guest that joins late or lost a batch
	void queue_thrall_max_hp(int32_t p_id);                    // set_thrall_stats changed a maximum: a wire record, not an event
	// guest
	void set_puppet(bool p_on);                                // switches the mode and forgets every body
	bool read_snapshot(const uint8_t *p_data, size_t p_size);  // false: rep.error says why
	bool read_reliable(const uint8_t *p_data, size_t p_size);  // a batch or a baseline
	void step_puppet(double p_dt);
	void clear_bodies();                                       // enemies, thralls, corpses, zones and their lookups
	void puppet_apply_enemy(const SnapRec &p_rec);             // one snapshot record: the body eases toward it, its state edges and hp drops become events
	void puppet_apply_thrall(const SnapRec &p_rec);
	// One reliable record that is an event GDScript reads: it changes the tables and is re-emitted in the guest's event buffer. False: it does not fit the guest's world.
	bool puppet_event(int32_t p_type, int32_t p_id, const int32_t *p_ints, int32_t p_ni, const float *p_floats, int32_t p_nf, const WireTail &p_tail, const uint8_t *p_status_bytes, uint32_t p_status_n);
	void puppet_thrall_max_hp(int32_t p_id, float p_max_hp);

private:
	void change(int32_t p_slot, int32_t p_next);
	void enter(Enemy &e, int32_t p_prev);
	int32_t tick_state(int32_t p_slot, double p_dt);
	int32_t engage(Enemy &e, float p_tx, float p_tz, double p_d, double p_dt);
	void move(Enemy &e, double p_dt);
	void separate();
	void resolve_overlaps();
	bool on_surface(const Enemy &e) const { return e.state != DEAD && e.state != BURROW && e.state != ERUPT; }
	void keep_off_heroes(Enemy &e) const;
	void step_zones(double p_dt);
	void remove_dead_bodies();
	void kill(int32_t p_slot, int32_t p_source);
	Enemy make_enemy(int32_t p_def, float p_x, float p_z, int32_t p_level, double p_hp_mult, double p_damage_mult, bool p_elite, int32_t p_area, bool p_rising, int32_t p_affixes);
	// affixes (affixes.cpp): DmAffixSet's host rules
	void tick_affixes(int32_t p_slot, double p_dt);
	void tick_bell(Enemy &e, double p_dt);
	void tick_hunger(Enemy &e, double p_dt);
	void tick_shroud(Enemy &e);
	void vengeance(Enemy &e);
	void affix_moment(const Enemy &e, int32_t p_kind, float p_ax, float p_az, float p_tx, float p_tz, float p_amount);
	// statuses on any body (DmStatusSet)
	void advance_statuses(Body &b, double p_dt);
	void step_statuses(Body &b, double p_dt);
	void statuses_changed(Body &b);
	void body_died_statuses(Body &b);
	double absorb(Body &b, double p_amount);
	bool deal_dot(Body &b, double p_amount, int32_t p_source, bool &r_killed);
	void stun_body(Body &b, double p_seconds);
	// targets: heroes (kind 0 externals) then living thralls in raise order
	bool target_at(int32_t p_id, Tgt &r_target) const;
	template <class F>
	void each_target(F &&f) const {
		for (const External &x : externals) {
			if (x.alive && x.kind == 0) {
				f(Tgt{ x.id, x.x, x.z, x.radius, x.weight });
			}
		}
		for (const Thrall &t : thralls) {
			if (t.alive_target()) {
				f(Tgt{ t.id, t.x, t.z, t.radius, thrall_target_weight(t) });
			}
		}
	}
	// brain helpers (DmEnemy)
	bool scan_due(Enemy &e, double p_dt);
	int32_t find_target(const Enemy &e, double p_range) const;
	bool target_valid(int32_t p_id) const {
		Tgt t;
		return target_at(p_id, t);
	}
	void stop(Enemy &e);
	void steer_to(Enemy &e, float p_gx, float p_gz, double p_mult, double p_dt);
	void move_straight(Enemy &e, float p_gx, float p_gz, double p_speed);
	void face_point(Enemy &e, float p_px, float p_pz, double p_dt);
	void wander(Enemy &e, double p_dt);
	void begin_attack(Enemy &e);
	void strike(Enemy &e);
	void hit_target(Enemy &e, int32_t p_target, double p_damage, int32_t p_kind);
	void hit_id(int32_t p_source, int32_t p_target, double p_damage, int32_t p_kind);  // a blow on a hero (event) or a thrall (applied here)
	bool hittable(const Enemy &e) const { return e.state != BURROW && e.state != ERUPT; }
	int32_t post_attack_state(const Enemy &e) const;
	static double flat_dist(float ax, float az, float bx, float bz) {
		const float dx = bx - ax, dz = bz - az;
		return std::sqrt(double(dx) * dx + double(dz) * dz);
	}
	// thralls (thralls.cpp)
	void separate_thralls();
	void step_thralls(double p_dt);
	void step_thrall(int32_t p_slot, double p_dt);
	void think_thrall(Thrall &t, const External &own, double p_dt);
	bool thrall_target_ok(const Thrall &t, float p_opx, float p_opz) const;
	int32_t scan_thrall(const Thrall &t, float p_opx, float p_opz) const;
	bool locate_enemy(int32_t p_id, float &r_x, float &r_z, double &r_radius, double &r_edge) const;  // enemy or boss position, radius and boss edge
	void engage_thrall(Thrall &t, double p_dt);
	void follow_thrall(Thrall &t, float p_opx, float p_opz, double p_dt);
	void steer_thrall(Thrall &t, float p_gx, float p_gz, double p_mult, double p_dt);
	void face_thrall(Thrall &t, float p_px, float p_pz, double p_dt);
	void move_thrall(Thrall &t, double p_dt);
	void swing_thrall(Thrall &t);
	void thrall_hit(Thrall &t, int32_t p_target, double p_damage);
	void cleave_thrall(Thrall &t, int32_t p_main, double p_damage);
	void burst_thrall(Thrall &t, double p_radius, double p_damage);
	void set_thrall_state(Thrall &t, int32_t p_state);
	void reform_thralls(int32_t p_owner);
	int32_t next_formation_slot(int32_t p_owner) const;
	void make_room(int32_t p_owner, double p_cap, double p_weight);
	void remove_dead_thralls();
	// corpses (corpses.cpp)
	void lay_corpses(const Enemy &e);
	void step_corpses(double p_dt);
	void remove_corpse(int32_t p_index, int32_t p_reason);
	void rupture_corpse(const Corpse &c);
};

} // namespace dm
