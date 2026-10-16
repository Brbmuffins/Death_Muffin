#pragma once
// A corpse: DmSimCorpse (godot/sim/sim_corpse.gd) with the fields the host logic of DmCorpseField (godot/next/corpses) uses.
#include <cstdint>
#include <limits>

namespace dm {

// The def's "corpse" kind (enemies.json): append only. CK_NONE leaves no corpse.
enum CorpseKind : int32_t { CK_NORMAL = 0, CK_SWIFT, CK_RESONANT, CK_TOXIC, CK_NONE };
// Why a corpse went (corpse_gone / corpse_consumed reasons): append only; other strings are interned after these.
enum CorpseReason : int32_t { CR_EXPIRED = 0, CR_BURST, CR_CONSUMED, CR_LITANY, CR_RAISED, CR_DEVOURED };
constexpr const char *CORPSE_KIND_NAMES[5] = { "normal", "swift", "resonant", "toxic", "none" };
constexpr const char *CORPSE_REASON_NAMES[6] = { "expired", "burst", "consumed", "litany", "raised", "devoured" };
constexpr int32_t ENEMY_RISEN = -1;  // a corpse of the "risen" def when the loaded defs do not have one

struct Corpse {
	int32_t id = 0, kind = CK_NORMAL, def = 0, area = 0;
	bool elite = false;
	// GDScript floats are doubles: the extra deathCorpses lie at unrounded positions, so the record keeps doubles too.
	double x = 0, z = 0, facing = 0, scale = 1;
	double born_at = 0, expires_at = 0, rupture_at = std::numeric_limits<double>::infinity();
};

} // namespace dm
