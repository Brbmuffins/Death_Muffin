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

#include "core/world.h"

class DmCore : public godot::RefCounted {
	GDCLASS(DmCore, godot::RefCounted)

	dm::World world;
	godot::RID nav_map;
	mutable std::vector<int32_t> query_out;
	godot::PackedInt32Array ev_ints;
	godot::PackedFloat32Array ev_floats;

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

	// Commands (casts, bosses, the director)
	// `affixes`: the director's DmAffixSet.roll (bellTolled, hungering, shrouded, vengeful); the core runs their rules.
	int64_t spawn_enemy(const godot::String &p_def, const godot::Vector2 &p_pos, int64_t p_level, double p_hp_mult, double p_damage_mult, bool p_elite, const godot::String &p_area, bool p_rising, const godot::PackedStringArray &p_affixes = godot::PackedStringArray());
	bool strip_shroud(int64_t p_id);   // Last Light, a Warden sweep (DmSimSignatures.strip_shroud): the shroud is gone for good
	void cover_miasma(int64_t p_id);   // a friendly Miasma covers this body now: its shroud lifts for 0.35 s of game time
	godot::Dictionary damage(int64_t p_id, double p_amount, int64_t p_source, bool p_allow_stagger = true);
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
