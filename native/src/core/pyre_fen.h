#pragma once
// The Cinder Pyre's and the Mourning Fen's eight kinds (pyre_fen.cpp), the "pf" family of the old game's enemy kinds: dm_enemy_pf_melee.gd (the Cinder Husk), dm_enemy_pf_flanker.gd
// (the Cinderhound and the Mire Leech), dm_enemy_pf_caster.gd (the Pyre Priest, the Bog Hag, the Fen Wisp), dm_enemy_pf_hazard.gd (the Slag Brute and the Drowned Sexton),
// dm_pf_util.gd and the states dm_state_pf_hook_chase.gd and dm_state_pf_lure_kite.gd. These are the pieces world.h embeds; the brain's walk, swing and kill reach into
// them from world.cpp. Differences from the old game are noted in native/README.md.
#include <cstdint>

namespace dm {

// What a def says (enemies.json): the Husk's last embers, the Slag Brute's burning slam, the Drowned Sexton's chain and the Fen Wisp's retreat to the open water. The casters'
// `attack` ("ember", "hex", "pulse") is the def's blow (BLOW_EMBER, BLOW_HEX, BLOW_PULSE); the Mire Leech's `rotBite` is the plain hit kind toxic; the others are plain.
struct PfDef {
	bool ember_death = false, slam_pool = false, hook = false, lure = false;
};

// What a body carries: the chain in its wind-up (DmEnemyPfHazard.hooking, the `hk` a guest used to be told; bit 5 of the record now) and the chain's own cooldown (hook_cd,
// counted down every tick the body acts, before the base's: DmEnemyPfHazard._physics_process).
struct PfState {
	bool hooking = false;
	double hook_cd = 0;
};

// The numbers of the late areas' effects: enemies.json EMBER_BOLT, EMBER_DEATH and SLAG_POOL; fen.json HAG_HEX, WISP_PULSE, SEXTON_HOOK and FEN_LURE (HAG_HEX's thrallDamageMult is
// LegionTuning's). The defaults repeat the data's values so a core that loads nothing still plays; client/tests/core_kinds.gd asserts they equal what the data says.
struct PfTuning {
	double ember_r = 1.7, ember_pool_s = 4.0, ember_pool_dps = 0.4;          // the Pyre Priest's coal and the pool it leaves
	double death_r = 1.6, death_pool_s = 3.0, death_pool_dps = 0.3;          // the Cinder Husk's last embers
	double slag_pool_s = 4.0, slag_pool_dps = 0.3;                           // the Slag Brute's slam pool (its radius is the slam's)
	double hex_r = 3.1, hex_s = 6.0, hex_blow = 0.55, hex_chill_s = 1.8;     // the Bog Hag's hex (durationS, blowMult, chillMs / 1000)
	double pulse_r = 2.3, pulse_chill_s = 1.8;                               // the Fen Wisp's pulse
	double hook_min = 3.4, hook_range = 8.5, hook_half = 0.95, hook_cooldown = 6.5, hook_pull = 4.5, hook_blow = 0.7, hook_root_s = 0.5;   // the Drowned Sexton's chain
	double lure_x = -44.0, lure_z = -79.0;                                   // the open water the wisp backs off toward (DmSimData.FEN_LURE)
};

// The scripts' own literals: dm_enemy_pf_hazard.gd `_hook_strike` (reach and half width get 0.6 and 0.3 m of the player's body), dm_pf_util.gd `pull` (never closer than 1.6 m, a drag
// under 5 cm is not made), dm_state_pf_lure_kite.gd (the heading is 0.55 away from the target and 0.45 toward the lure, aimed 3 m ahead).
constexpr double HOOK_REACH_PAD = 0.6, HOOK_HALF_PAD = 0.3, PULL_CLOSEST = 1.6, PULL_MIN_STEP = 0.05;
constexpr double LURE_AWAY = 0.55, LURE_TOWARD = 0.45, LURE_AHEAD = 3.0;

// What an enemy does to a hero besides damage (EV_TARGET_EFFECT): a chill, a root, a drag to a place. A thrall takes none of them (the hex curses it instead).
enum TargetEffect : int32_t { TE_CHILL = 0, TE_ROOT, TE_PULL };

} // namespace dm
