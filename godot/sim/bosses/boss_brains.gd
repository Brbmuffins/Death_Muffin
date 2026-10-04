class_name DmBossBrains
extends RefCounted
## Factory: one brain per boss id (BossBrain.ts makeBossBrains).

const BOSS_IDS := ["gravedigger", "abbess", "congregation", "prelate", "saint", "regent", "mire"]

const _PATHS := {
	"prelate": "res://sim/bosses/prelate_brain.gd",
	"gravedigger": "res://sim/bosses/gravedigger_brain.gd",
	"abbess": "res://sim/bosses/abbess_brain.gd",
	"congregation": "res://sim/bosses/congregation_brain.gd",
	"saint": "res://sim/bosses/saint_brain.gd",
	"regent": "res://sim/bosses/regent_brain.gd",
	"mire": "res://sim/bosses/mire_brain.gd",
}


static func make(world: RefCounted, boss_id: String) -> RefCounted:
	return load(_PATHS[boss_id]).new(world)


## { boss_id: brain } for all seven.
static func make_all(world: RefCounted) -> Dictionary:
	var out := {}
	for id in _PATHS:
		out[id] = make(world, id)
	return out
