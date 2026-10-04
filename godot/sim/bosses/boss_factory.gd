class_name DmBossFactory
extends RefCounted
## The hook the sim loads (godot/sim/BOSS_HOOK.md): id -> DmBossController for all seven bosses, each running the real brain.

const Adapter := preload("res://sim/bosses/boss_adapter.gd")
const IDS := ["prelate", "gravedigger", "abbess", "congregation", "saint", "regent", "mire"]


static func make_all(sim) -> Dictionary:
	var out := {}
	for id in IDS:
		var c = Adapter.new()
		c.setup(sim, id)
		out[id] = c
	return out
