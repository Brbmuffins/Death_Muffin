class_name DmRiteGestures
extends RefCounted
## The hero's cast / attack gesture per rite: the exact `_gesture(kind, seconds, flow_id, ability_id)` calls of the current client's
## DmAbilitySystem, as data. DmRiteCaster plays one per accepted cast on every peer (`avatar.cast`), once, through a separate RPC (never an
## event: events_played stays the rites' own).

## rite -> [clip kind, clip speed seconds, cast-flow id (gestureSeconds), ability id for the weapon's combat clip ("" = none)]
const TABLE := {
	"bone_needle": ["cast", 3.2, "bone_needle", "bone_needle"],
	"marrow_spear": ["cast", 2.4, "marrow_spear", "marrow_spear"],
	"exhume": ["dig", 2.6, "exhume", "exhume"],
	"miasma": ["cast", 2.2, "miasma", "miasma"],
	"wailing_skull": ["cast", 2.8, "wailing_skull", "wailing_skull"],
	"grave_step": ["cast", 3.0, "grave_step", "grave_step"],
	"grave_frost": ["cast", 2.4, "grave_frost", "grave_frost"],
	"soul_siphon": ["cast", 2.4, "soul_siphon", "soul_siphon"],
	"bone_prison": ["cast", 2.3, "bone_prison", "bone_prison"],
	"grave_hands": ["dig", 2.2, "grave_hands", "grave_hands"],
	"bone_storm": ["cast", 2.0, "bone_storm", "bone_storm"],
	"bone_mantle": ["cast", 1.8, "bone_mantle", "bone_mantle"],
	"bone_fan": ["cast", 3.2, "bone_fan", "bone_fan"],
	"rot_lance": ["cast", 2.8, "rot_lance", "rot_lance"],
	"grave_offering": ["cast", 2.4, "grave_offering", "grave_offering"],
	"ivory_cleave": ["cast", 3.0, "ivory_cleave", "ivory_cleave"],
	"veil_step": ["cast", 3.4, "veil_step", ""],
	"rally_dead": ["cast", 2.0, "rally_dead", "rally_dead"],
	"carrion_seed": ["cast", 2.4, "carrion_seed", "carrion_seed"],
	"black_litany": ["cast", 1.6, "black_litany", "black_litany"],
	"corpse_explosion": ["cast", 3.0, "corpse_explosion", "corpse_explosion"],
	"ossuary_wall": ["cast", 1.8, "ossuary_wall", "ossuary_wall"],
	"command_rend": ["cast", 1.8, "command_rend", "command_rend"],
	"dirge": ["cast", 1.8, "dirge", "dirge"],
	"plague_bloom": ["cast", 1.8, "plague_bloom", "plague_bloom"],
}


static func has(rite: String) -> bool:
	return TABLE.has(rite)


## Play `rite`'s gesture on a hero avatar facing `yaw` (the avatar's own cast(), the same call the current client makes).
static func play(avatar: Object, rite: String, yaw: float) -> bool:
	if avatar == null or not TABLE.has(rite) or not avatar.has_method("cast"):
		return false
	var g: Array = TABLE[rite]
	avatar.cast(String(g[0]), float(g[1]), yaw, float(DmAbilities.cast_flow(String(g[2]))["gestureSeconds"]), String(g[3]))
	return true
