#pragma once
// Godot-facing API of the combat core (native/README.md "Design"). Per-creature work stays inside; GDScript calls step() once per
// tick, reads take_events() and the bulk arrays, and calls the query/command methods from casts and bosses.
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/rid.hpp>
#include <godot_cpp/variant/vector2.hpp>

#include <string>
#include <vector>

#include "core/world.h"

class DmCore : public godot::RefCounted {
	GDCLASS(DmCore, godot::RefCounted)

	dm::World world;
	godot::RID nav_map;
	mutable std::vector<int32_t> query_out;
	godot::PackedInt32Array ev_ints;
	godot::PackedFloat32Array ev_floats;
	friend class DmCrowd;        // the presentation reads the tables and the event buffer in place, read only (dm_crowd.h)
	uint64_t event_batches = 0;  // take_events() calls: DmCrowd reads the buffer from where it stopped, and starts over once it was cleared
	std::vector<std::vector<uint8_t>> snap_parts;  // the parts snapshot_parts builds (reused, like wire_buf)
	std::vector<uint8_t> wire_buf;               // the snapshot or batch being built (reused: no allocation once it has grown)
	std::vector<std::string> refused_logged;     // command names already reported once as refused on a puppet
	bool refused(const char *p_command);         // a puppet core refuses what the host owns: counts it, says so once per command, true when refused

protected:
	static void _bind_methods();

public:
	godot::String version() const;
	int64_t checksum(int64_t p_count) const;

	// Setup
	void set_seed(int64_t p_seed);
	void set_wander(bool p_on);
	int64_t load_enemy_defs(const godot::Dictionary &p_enemies);  // the ENEMIES dictionary of data/content/enemies.json
	void load_tuning(const godot::Dictionary &p_content);          // the whole enemies.json: ELITE, DUST, BURROW, FRENZY
	// Thralls and corpses: the parsed data files by name ("abilities" RALLY, "fen" HAG_HEX, "statuses" PLAGUE_BURST, "gameplay_legendary" LEGEND,
	// "runes" RUNE_TUNING.colossus, "combat_enemies" = data/combat/enemies.json damage_scale).
	void load_legion_tuning(const godot::Dictionary &p_files);
	// The constants of DmSimConsts, DmCorpseField and DmThrall by their GDScript names (client/core/dm_gd_consts.gd reads them from the files).
	void load_sim_consts(const godot::Dictionary &p_consts);
	godot::Dictionary tuning() const;  // the legion tuning in force, keyed like load_sim_consts plus the data-file values (drift check in tests)
	// The status rule table, one Dictionary per status IN WIRE ORDER (DmStatusSet.IDS), keys as DmStatusSet._defs plus "name".
	int64_t load_status_defs(const godot::Array &p_rules);
	void set_nav_map(const godot::RID &p_map);                      // the area's navigation map; unset = straight lines (tests)
	void set_area_bounds(const godot::Vector2 &p_min, const godot::Vector2 &p_max);
	// The navmesh for the per-tick "keep to the navmesh" step (NavGrid): each region's vertices (world space) and polygons ([n, i0 .. in-1, ...]); its index.
	// With none, the step asks the navigation map (set_nav_map). nav_closest answers the same query for GDScript (the hero's moves, spawn points).
	int64_t nav_add_region(const godot::PackedVector3Array &p_vertices, const godot::PackedInt32Array &p_polygons, bool p_enabled);
	void nav_set_region_enabled(int64_t p_region, bool p_enabled);
	void nav_clear_regions();
	godot::Vector3 nav_closest(const godot::Vector3 &p_point);
	int64_t nav_triangle_count() const;

	// Commands (casts, bosses, the director)
	// `affixes`: the director's DmAffixSet.roll (bellTolled, hungering, shrouded, vengeful); the core runs their rules.
	int64_t spawn_enemy(const godot::String &p_def, const godot::Vector2 &p_pos, int64_t p_level, double p_hp_mult, double p_damage_mult, bool p_elite, const godot::String &p_area, bool p_rising, const godot::PackedStringArray &p_affixes = godot::PackedStringArray());
	bool strip_shroud(int64_t p_id);   // Last Light, a Warden sweep (DmSimSignatures.strip_shroud): the shroud is gone for good
	void cover_miasma(int64_t p_id);   // a friendly Miasma covers this body now: its shroud lifts for 0.35 s of game time
	// A solid box from a to b, `thickness` thick, that enemies cannot enter (Ossuary Wall); thralls and heroes pass. Returns its id.
	int64_t add_obstacle(const godot::Vector2 &p_a, const godot::Vector2 &p_b, double p_thickness);
	bool remove_obstacle(int64_t p_id);
	godot::Dictionary damage(int64_t p_id, double p_amount, int64_t p_source, bool p_allow_stagger = true);
	bool remove_enemy(int64_t p_id);  // a living enemy leaves without dying (a boss's adds): no death, corpse or credit; EV_ENEMY_REMOVED with 1. False for a dead or unknown id
	void stun(int64_t p_id, double p_seconds);
	// DmStatusSet.apply: params dps (bleed, withered), cap (withered stack cap / barrier cap), amount (barrier).
	void apply_status(int64_t p_id, const godot::String &p_status, int64_t p_source, double p_stacks = 1.0, double p_duration = -1.0, const godot::Dictionary &p_params = godot::Dictionary());
	bool remove_status(int64_t p_id, const godot::String &p_status);
	godot::PackedByteArray statuses(int64_t p_id) const;  // DmStatusSet.encode(): 4 bytes per status (wire id, stacks, tenths of s left)
	double status_stacks(int64_t p_id, const godot::String &p_status) const;
	double damage_dealt_mult(int64_t p_id) const;
	godot::PackedInt32Array enemies_in_radius(const godot::Vector2 &p_pos, double p_r);
	// A hero (kind 0) or a boss (kind 1). A boss is a target for thralls while `alive` (false when dead or it cannot be hurt).
	int64_t add_external(int64_t p_kind, double p_radius, double p_weight);
	void set_external(int64_t p_id, const godot::Vector2 &p_pos, bool p_alive);
	void remove_external(int64_t p_id);  // the body is gone: its thralls crumble on the next tick

	// Thralls (DmThrallHost + DmThrall). `stats` = DmThralls.raise_stats / colossus_stats plus kind: kind, hp, maxHp, damage, attackInterval, range,
	// speed, empowered, champion, allyHeal, and lifetimeS (> 0: decays after it; the Veilwalker's echo). cap < 0 = no legion cap (Bonded Dead).
	// Returns the thrall id, 0 when the owner is missing or dead; crumbled ones are in last_crumbled() and in the event buffer.
	int64_t raise_thrall(const godot::Dictionary &p_stats, int64_t p_owner, const godot::Vector2 &p_pos, double p_yaw, double p_cap = -1.0);
	godot::PackedInt32Array last_crumbled() const;
	bool kill_thrall(int64_t p_id, const godot::String &p_reason);  // "killed", "crumbled", "sacrificed", "decayed"
	// Black Litany / sacrifice: kills n (-1 = all) of the owner's thralls "sacrificed"; returns [{kind, maxHp, damage, pos}] of each.
	godot::Array sacrifice_thralls(int64_t p_owner, int64_t p_n = -1);
	void rally_thralls(int64_t p_owner, double p_seconds, int64_t p_focus = 0);
	void recall_thralls(int64_t p_owner);
	void set_legion_burst(int64_t p_owner, double p_fraction);
	void set_thrall_target(int64_t p_id, int64_t p_target);  // 0 clears (the Spear rally turns the legion on its mark)
	void set_thrall_mark(int64_t p_id, double p_mult);       // the Spear rally's damage multiplier on the marked target
	void curse_thrall(int64_t p_id, double p_seconds);       // Bog Hag's hex: cursed_t
	void set_thrall_pos(int64_t p_id, const godot::Vector2 &p_pos);
	void set_thrall_stats(int64_t p_id, const godot::Dictionary &p_stats);  // hp, maxHp, damage, attackInterval, attackCd (a purchase refresh, Rend)
	godot::PackedInt32Array thralls_in_radius(const godot::Vector2 &p_pos, double p_r, int64_t p_owner = 0) const;
	int64_t thrall_count(int64_t p_owner = 0) const;
	double thrall_places(int64_t p_owner = 0) const;

	// Corpses (DmCorpseField, host logic). Ids are the corpse's own numbers.
	void set_corpse_life_mult(double p_mult);  // corpseLifeMult x the vow multiplier
	void set_area_level(const godot::String &p_area, int64_t p_level);  // the toxic pool's damage level; unset = 1, as today
	int64_t corpse_add(const godot::Vector2 &p_pos, const godot::String &p_kind, const godot::String &p_enemy, bool p_elite, double p_facing, double p_scale, const godot::String &p_area);
	godot::PackedInt32Array corpses_in_radius(const godot::Vector2 &p_pos, double p_r, const godot::String &p_area = godot::String()) const;
	int64_t corpse_pick(const godot::Vector2 &p_aim, double p_pick_r, double p_max_range, const godot::Vector2 &p_from, const godot::String &p_area = godot::String()) const;
	bool corpse_consume(int64_t p_id, int64_t p_by, const godot::String &p_reason = "consumed");
	int64_t corpse_count() const;
	godot::PackedInt32Array corpse_ids() const;
	godot::PackedFloat32Array corpse_positions() const;  // x, z, facing, scale per corpse, oldest first
	godot::Dictionary corpse_info(int64_t p_id) const;
	godot::String reason_name(int64_t p_reason) const;

	// Co-op (native/README.md "Co-op"). The host builds the messages; a guest's core is a puppet that applies them. Messages carry a magic, a format
	// version and a hash of the data tables; apply_* says false and replication_error() why when they do not match this build.
	void set_puppet(bool p_on);                     // a guest's core: no brains, no rules; switching clears every body. Commands the host owns are refused with an error.
	bool is_puppet() const;
	void set_replication(bool p_on);                // host: collect reliable events for guests (and restart their numbering); off for solo play
	godot::PackedByteArray snapshot(int64_t p_tick);  // host, 20 Hz: every live body's changing fields, quantized (empty on a puppet)
	godot::Array snapshot_parts(int64_t p_tick, int64_t p_max_bytes);  // host, 20 Hz: the snapshot as messages of at most p_max_bytes (each a snapshot of its bodies; ticks p_tick, +1 ...; the caller adds the length)
	godot::PackedByteArray take_reliable();         // host, every tick: the discrete events since the last call, empty when none. Leaves the buffer take_events() reads alone
	godot::PackedByteArray baseline();              // host: the whole present as reliable records, for a guest that joins late or asks after a gap
	bool apply_snapshot(const godot::PackedByteArray &p_bytes);  // puppet: false = refused (see replication_error()); a late or repeated one is ignored (true)
	bool apply_reliable(const godot::PackedByteArray &p_bytes);  // puppet: a batch or a baseline; a gap in the numbering is refused until a baseline arrives
	godot::String replication_error() const;        // why the last apply_* said false ("" after a success)
	godot::Dictionary replication_stats() const;    // counters of both roles
	static int64_t wire_version();

	// The tick and its outputs
	void step(double p_dt);
	godot::Array take_events();  // [PackedInt32Array ints, PackedFloat32Array floats], see core/events.h; clears the buffer
	int64_t enemy_count() const;
	godot::PackedInt32Array enemy_ids() const;
	godot::PackedFloat32Array enemy_positions() const;  // x, z, yaw per enemy, spawn order
	godot::PackedInt32Array enemy_states() const;
	godot::PackedFloat32Array enemy_ground_speeds() const;  // m/s each enemy walked this tick (walk/run clips)
	godot::Dictionary enemy_info(int64_t p_id) const;  // one enemy (HUD target frame, tests); empty when gone
	// Thralls in raise order (dead bodies stay 1.4 s, state DEAD).
	int64_t thrall_total() const;
	godot::PackedInt32Array thrall_ids() const;
	godot::PackedFloat32Array thrall_positions() const;  // x, z, yaw per thrall
	godot::PackedInt32Array thrall_states() const;       // ThrallState
	godot::PackedInt32Array thrall_kinds() const;        // ThrallKind
	godot::PackedInt32Array thrall_swings() const;       // swing counter per thrall (the attack visual fires when it changes)
	godot::PackedInt32Array thrall_owners() const;
	godot::PackedFloat32Array thrall_hp() const;         // hp, max hp per thrall (the low-hp ring, the party list)
	godot::PackedFloat32Array thrall_ground_speeds() const;
	godot::Dictionary thrall_info(int64_t p_id) const;
	godot::String thrall_kind_name(int64_t p_kind) const;
	godot::String death_reason_name(int64_t p_reason) const;
	godot::String affix_moment_name(int64_t p_kind) const;  // EV_AFFIX_MOMENT: tell, toll, hungering, vengeful, unveil
	godot::String def_name(int64_t p_def) const;
	godot::String area_name(int64_t p_area) const;
	double clock() const;
};
