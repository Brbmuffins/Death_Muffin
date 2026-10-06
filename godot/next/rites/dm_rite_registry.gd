class_name DmRiteRegistry
extends RefCounted
## THE list of rites the DmRiteCaster can cast: one line per rite. Adding a rite = a new rite_<id>.gd + one line here.

const MODULES := {
	"bone_needle": preload("res://next/rites/rite_bone_needle.gd"),
	"miasma": preload("res://next/rites/rite_miasma.gd"),
	"exhume": preload("res://next/rites/rite_exhume.gd"),
	"corpse_explosion": preload("res://next/rites/rite_corpse_explosion.gd"),
	"black_litany": preload("res://next/rites/rite_black_litany.gd"),
	"grave_offering": preload("res://next/rites/rite_grave_offering.gd"),
	"bone_mantle": preload("res://next/rites/rite_bone_mantle.gd"),
	"carrion_seed": preload("res://next/rites/rite_carrion_seed.gd"),
	"bone_fan": preload("res://next/rites/rite_bone_fan.gd"),
	"rot_lance": preload("res://next/rites/rite_rot_lance.gd"),
	"marrow_spear": preload("res://next/rites/rite_marrow_spear.gd"),
	"wailing_skull": preload("res://next/rites/rite_wailing_skull.gd"),
	"ivory_cleave": preload("res://next/rites/rite_ivory_cleave.gd"),
	"bone_storm": preload("res://next/rites/rite_bone_storm.gd"),
	"soul_siphon": preload("res://next/rites/rite_soul_siphon.gd"),
}

static var _inst: Dictionary = {}
static var _steppers: Array = []


static func has(rite: String) -> bool:
	return MODULES.has(rite)


## The shared module instance of a rite (null when unknown).
static func module(rite: String) -> DmRiteModule:
	if not MODULES.has(rite):
		return null
	if _inst.is_empty():
		for k in MODULES:
			var m: DmRiteModule = MODULES[k].new()
			m.id = k
			_inst[k] = m
			if m.steps:
				_steppers.append(m)
	return _inst[rite]


static func ids() -> Array:
	return MODULES.keys()


## The modules that tick (host).
static func steppers() -> Array:
	module("bone_needle")   # builds the instances
	return _steppers
