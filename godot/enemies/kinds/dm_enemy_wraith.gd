class_name DmEnemyWraith
extends DmEnemyCaster
## Choir Wraith (Sanctum, def `wraith`, attack "scream"): a hovering spectral singer that holds range (DmStateKite, the caster set) and sings a
## ring of grave-song onto where the target stood when the wind-up began (aim fixed then, so walking out dodges it). SCREAM.radius ring at
## the aim, damage to everything inside. Leaves no corpse (def corpse "none": the body thins to mist, DmEnemyFx wraith dissolve).

const HOVER := 0.45          ## DmEntityViews.HOVER["wraith"]

func _ready() -> void:
	super()
	flying = HOVER


func announce_telegraph(seconds: float) -> void:
	telegraph.emit(&"scream", global_position, aim, float(DmSimData.SCREAM["radius"]), seconds)


func strike() -> void:
	for tg in targets_within(aim, float(DmSimData.SCREAM["radius"])):
		hit_target(tg, damage)
	cue.emit(&"scream", aim, float(DmSimData.SCREAM["radius"]))


## DmEntityViews._enemy_opts: spectral, pale-blue emissive (elites keep the purple), Penitent as the fallback rig.
func look_options() -> Dictionary:
	var o := super()
	o["spectral"] = true
	o["fallback"] = "penitent"
	if not elite:
		o["emissive"] = 0x9fb6d8
		o["emissive_intensity"] = 0.35
	return o
