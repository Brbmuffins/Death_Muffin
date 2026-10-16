class_name DmCoreEvents
extends RefCounted
## The combat core's event buffer, as GDScript names (native/src/core/events.h; type numbers are append only) and the small enums its events
## carry (native/src/core/world.h, corpse.h, thrall.h). DmCoreHost reads the buffer once per tick and emits one typed signal per event kind.

# ---- event types
const ENEMY_SPAWNED := 1
const ENEMY_STATE := 2
const ENEMY_DAMAGED := 3
const ENEMY_DIED := 4
const ENEMY_REMOVED := 5
const ENEMY_ATTACK := 6
const TELEGRAPH := 7
const CUE := 8
const TARGET_HIT := 9
const ZONE := 10
const ZONE_PULSE := 11
const ZONE_GONE := 12
const STATUSES_CLEARED := 13
const STATUS_CHANGED := 14
const STATUS_DOT := 15
const STATUS_EXPIRED := 16
const WITHERED_DIED := 17
const CORPSE_ADDED := 18
const CORPSE_CONSUMED := 19
const CORPSE_GONE := 20
const CORPSE_RUPTURED := 21
const THRALL_RAISED := 22
const THRALL_STATE := 23
const THRALL_SWING := 24
const THRALL_DAMAGED := 25
const THRALL_DIED := 26
const THRALL_REMOVED := 27
const THRALL_STATUS := 28
const THRALL_BELL_HEAL := 29
const THRALL_PLAGUE_POOL := 30
const THRALL_HIT_EXTERNAL := 31
const AFFIX_MOMENT := 32

# ---- an enemy's state (EnemyState)
enum State { RISING, IDLE, CHASE, ATTACK, HURT, RETURN, DEAD, FLEE, BURROW, ERUPT, DIG, EMERGE }

# ---- a thrall's state (ThrallState)
enum ThrallState { RISING, IDLE, MOVE, ATTACK, DEAD }

# ---- names by number (the core decodes defs, areas, thrall kinds, death reasons and corpse reasons itself; these are the fixed small enums)
const TELLS: Array[StringName] = [&"cone", &"slam", &"dust", &"erupt", &"toll"]                       ## Tell
const CUES: Array[StringName] = [&"slam", &"erupt", &"dig_in"]                                         ## Cue
const ZONE_KINDS: Array[StringName] = [&"dust", &"toxic"]                                              ## ZoneKind
const HIT_KINDS: Array[String] = ["melee", "toxic", "burn", "ember", "dust", "curse", "toll"]          ## HitKind: the sim's hurt `from`
const BLOWS: Array[StringName] = [&"melee", &"cone", &"dust", &"slam"]                                 ## Blow
const CORPSE_KINDS: Array[String] = ["normal", "swift", "resonant", "toxic", "none"]                   ## CorpseKind
const AFFIXES: Array[String] = ["bellTolled", "hungering", "shrouded", "vengeful"]                     ## Affix: the bit order of EV_ENEMY_SPAWNED's mask
const AFFIX_MOMENTS: Array[StringName] = [&"tell", &"toll", &"hungering", &"vengeful", &"unveil"]      ## AffixMoment


## The affixes in an EV_ENEMY_SPAWNED mask, as the director's roll names them.
static func affix_list(mask: int) -> PackedStringArray:
	var out := PackedStringArray()
	for k in AFFIXES.size():
		if mask & (1 << k) != 0:
			out.append(AFFIXES[k])
	return out
