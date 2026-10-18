class_name DmEnemyClstCaster
extends DmEnemyCaster
## Cloister casters whose blow is not a cone or dust (those stay in DmEnemyCaster):
##   "curse"  (Lich Acolyte, Weeping Seraph): a homing curse. Telegraph "curse" (a ring on the target and its sound); at the blow the CURRENT
##            target is hit if within attackRange * 1.35 + 0.4 of the caster (the sim's reach), so walking out of the telegraph does not dodge it,
##            breaking line of range does.
##   "flask"  (Plague Doctor): a lobbed flask. Telegraph "flask" (rot-green ring, arcing orb) on the aim fixed at wind-up start; at the blow
##            everything in PLAGUE_FLASK.radius is hit and a toxic pool (DmHostileZone "toxic") lingers poolS at damage * poolDpsMult dps.
## Movement is DmStateClstKite (silence-aware). A visual-only pool is spawned on puppets when the host's blow would land.

const CLST_FALLBACK := {"acolyte": "deacon", "seraph": "deacon", "plague_doctor": "deacon"}

func _build_states() -> void:
	super()
	sm.add(DmStateClstKite.new(self, DmEnemyState.Id.CHASE).configure(kite_params()))


## [cast_pad, near_pad, back_dist, back_speed]; the support kinds (seraph) override.
func kite_params() -> Array:
	return [0.5, 1.5, 3.5, 0.8]


func look_options() -> Dictionary:
	var o := super()
	if CLST_FALLBACK.has(def_id):
		o["fallback"] = CLST_FALLBACK[def_id]
	return o


func announce_telegraph(seconds: float) -> void:
	if attack_kind == "flask":
		var r := float(DmSimData.PLAGUE_FLASK["radius"])
		telegraph.emit(&"flask", global_position, aim, r, seconds)
		if not is_multiplayer_authority():   # the host's strike spawns the damaging pool; this peer gets the visual copy when the flask lands
			get_tree().create_timer(seconds).timeout.connect(_puppet_pool)
	elif attack_kind == "curse":
		telegraph.emit(&"curse", global_position, aim, 0.0, seconds)
	else:
		super(seconds)


func _puppet_pool() -> void:
	if not is_inside_tree() or sm.id() != DmEnemyState.Id.ATTACK:
		return
	var PF: Dictionary = DmSimData.PLAGUE_FLASK
	DmHostileZone.spawn(get_parent(), aim, &"toxic", float(PF["radius"]), float(PF["poolS"]), 0.0, self).damaging = false


func strike() -> void:
	if attack_kind == "flask":
		var PF: Dictionary = DmSimData.PLAGUE_FLASK
		var r := float(PF["radius"])
		for tg in targets_within(aim, r):
			hit_target(tg, damage, "toxic")
		DmHostileZone.spawn(get_parent(), aim, &"toxic", r, float(PF["poolS"]), damage * float(PF["poolDpsMult"]), self)
		cue.emit(&"flask", aim, r)
	elif attack_kind == "curse":
		var tg := target
		if target_valid(tg) and flat_dist_to(tg) <= attack_range * STRIKE_REACH_MULT + STRIKE_REACH_PAD:
			hit_target(tg, damage, "curse")
	else:
		super()
