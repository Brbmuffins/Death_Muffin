class_name DmRiteLegends
extends RefCounted
## Requiem Wraiths (legendary set), HOST, one per caster, made only when the worn set has `corpseWisp` or `wraithNova` (DmRiteCaster._set_mods).
## 2 - `corpseWisp`: a corpse of yours consumed (Exhume, Litany, Offering, Mantle, Explosion...) raises a healing wisp for that many seconds (cap 3, a fourth
##     refreshes the soonest to expire); each heals 2 % max hp a second. 5 - `wraithNova`: a Soul Harvest cast makes every wisp and wraith thrall release a
##     nova (r 3, spell power x the mod, at most 8 sources). Numbers: DmSimData.LEGEND. Ports sim_caster.on_corpse_consumed / _tick_wisps / _wraith_nova.

const ID := "black_litany"   ## its events are played by the litany module (the caster routes by rite id)

var c: DmRiteCaster
var wisps: Array = []        ## {born, until, next_heal, speed, radius} in host-clock ms
var _field: Object = null


func _init(caster: DmRiteCaster) -> void:
	c = caster


## (Re)hook the corpse field once; the field outlives the caster's mods.
func attach() -> void:
	var f := c.corpses()
	if f != null and f != _field and f.has_signal(&"corpse_consumed"):
		_field = f
		f.corpse_consumed.connect(_on_consumed)


func _on_consumed(_corpse: Variant, by_peer: int, _reason: String) -> void:
	var secs := float(c.mods.get("corpseWisp", 0.0))
	if by_peer != c.peer_id or secs <= 0.0 or not bool(c.p["alive"]):
		return
	var L: Dictionary = DmSimData.LEGEND
	var now := c.now_ms
	var until := now + secs * 1000.0
	if wisps.size() >= int(L["wispCap"]):
		var w: Dictionary = wisps[0]
		for i in range(1, wisps.size()):
			if float(wisps[i]["until"]) < float(w["until"]):
				w = wisps[i]
		w["until"] = until
		return
	var n := wisps.size()
	var w2 := {"born": now, "until": until, "next_heal": now + 1000.0, "speed": 2.1 + n * 0.45, "radius": 1.15 + n * 0.28}
	wisps.append(w2)
	c.broadcast({"t": "wisp", "rite": ID, "by": c.peer_id, "secs": secs, "speed": float(w2["speed"]), "radius": float(w2["radius"])})


## Per host step, only while wisps exist.
func tick() -> void:
	var now := c.now_ms
	var heal := 0.0
	var i := wisps.size() - 1
	while i >= 0:
		var w: Dictionary = wisps[i]
		if not bool(c.p["alive"]) or now >= float(w["until"]):
			wisps.remove_at(i)
		else:
			while now >= float(w["next_heal"]) and float(w["next_heal"]) < float(w["until"]):
				heal += c.max_hp() * float(DmSimData.LEGEND["wispHealFrac"])
				w["next_heal"] = float(w["next_heal"]) + 1000.0
		i -= 1
	if heal > 0.0 and bool(c.p["alive"]):
		c.heal(heal)


## Soul Harvest empowered a rite: every wisp and wraith thrall of yours releases a nova.
func nova() -> void:
	var k := float(c.mods.get("wraithNova", 0.0))
	if k <= 0.0 or not bool(c.p["alive"]):
		return
	var L: Dictionary = DmSimData.LEGEND
	var now := c.now_ms
	var src: Array = []
	var me := c.pos()
	for w: Dictionary in wisps:
		var t := maxf(0.0, (now - float(w["born"])) / 1000.0)
		var a := t * float(w["speed"])
		var r := float(w["radius"]) * minf(1.0, 0.25 + t * 3.0)
		src.append([me.x + cos(a) * r, me.z + sin(a) * r])
	var th := c.thralls()
	if th != null:
		for t in th.list():
			if t.kind == "wraith" and t.state != DmThrall.S.DEAD and t.state != DmThrall.S.RISING:
				src.append([t.global_position.x, t.global_position.z])
	if src.is_empty():
		return
	var dmg := DmAbilities.sp(c.p, now) * k
	var shown: Array = []
	for s: Array in src.slice(0, int(L["novaMax"])):
		for e in DmRiteModule.enemies_in_circle(c, s[0], s[1], float(L["novaR"])):
			DmStatusSet.hit(e, dmg, c.body)
			c.hit_resolved.emit(ID, int(c.world.enemy_id(e)), dmg, false, float(e.get("hp")) <= 0.0)
		shown.append(s)
	c.broadcast({"t": "nova", "rite": ID, "by": c.peer_id, "pts": shown, "r": float(L["novaR"]), "amount": dmg})
