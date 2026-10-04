class_name DmEventFx
extends RefCounted
## The visual + audio + UI-text half of the sim-event router of WorldScene.ts (handleEvent / handleEventNow, foeVoice, fireDeath,
## emberShake, onLegendEvent, onSurge / colossusRises / onSurgeCleared, raiseWall, wadeRipples, zoneAmbience, fxLater, auraFx).
## The telegraph / zone / boss halves live in dm_event_fx_telegraph.gd, dm_event_fx_zones.gd and dm_event_fx_boss.gd.
##
## Gameplay consequences are NOT done here: they go through `hooks` (Callables the host sets, each optional):
##   on_death(ev)  on_hurt(ev)  on_exhumed_refund(ev)  on_exhumed_ok(ev)  on_detonated_refund(ev)  on_heal(ev)  on_new_blood_heal(ev)
##   on_boss_busy(ev) (alias on_boss_bussy)  on_surge_cleared(ev)  on_boss_defeated(ev)  on_node_gone(id)  on_node_back(id)  on_legend(ev)
## Host (DmGame, duck-typed) members used: sim, mirror (optional), p, self_id, now_ms, area_id, world_root, camera, builder, abilities,
## views, depths, telegraphs, emit_game_event(), float_text(), tip(), hitstop(), remote_ids(), remote_position(id), remote_bodies(),
## remote_gesture(ev), codex_discover(kind, id), boss_view_hide(id), empower_pending.

const PARTNER_FX_SCALE := 0.5
const LEGEND_FX_MAX := 6

# The three halves are loaded at runtime (they type their back-reference as DmEventFx, so no preload cycle).
const TELEGRAPH_SCRIPT := "res://game/dm_event_fx_telegraph.gd"
const ZONES_SCRIPT := "res://game/dm_event_fx_zones.gd"
const BOSS_SCRIPT := "res://game/dm_event_fx_boss.gd"

var game
var hooks: Dictionary = {}
var vfx: Node
var audio: Node

var telegraph_fx: RefCounted
var zones_fx: RefCounted
var boss_fx: RefCounted

## Effects that must land after a telegraph (processed in update so stepping stays deterministic): [{at, run}].
var fx_later: Array = []
## Looping auras tied to an entity ("e<enemy id>" censer incense, "c<corpse id>" toxic stink).
var aura_fx: Dictionary = {}
var surge_fx: Variant = null
var rally_mark: Variant = null
var legend_fx_at := 0.0
var legend_fx_n := 0
var announced_processions: Dictionary = {}

var _argc_cache: Dictionary = {}

## Event types this router handles (QA / report).
const HANDLED := ["death", "hurt", "nodeGone", "nodeBack", "telegraph", "melee", "thrallHit", "zone", "zoneGone", "wall", "wallGone", "rend",
	"mantle", "offering", "newBlood", "rally", "seeded", "seedGone", "seedBurst", "corpseGone", "thrall", "contagion", "requiem", "heal",
	"burst", "exhumed", "litanyResult", "legend", "detonated", "bossBusy", "sanctify", "affix", "surge", "surgeCleared", "surgeFailed",
	"wave", "dmg", "boss", "spawn", "corpse"]


func setup(p_game) -> void:
	game = p_game
	DmSimData.ensure()
	var root: Node = (Engine.get_main_loop() as SceneTree).root
	vfx = root.get_node_or_null("Vfx")
	audio = root.get_node_or_null("AudioDirector")
	telegraph_fx = load(TELEGRAPH_SCRIPT).new(self)
	zones_fx = load(ZONES_SCRIPT).new(self)
	boss_fx = load(BOSS_SCRIPT).new(self)


# --- host / helpers (shared with the sub-files) ----------------------------------------------------------------------------

func me() -> String:
	return String(game.self_id)


func now() -> float:
	return float(game.now_ms)


func px() -> float:
	return float(game.p.get("x", 0.0))


func pz() -> float:
	return float(game.p.get("z", 0.0))


func player_alive() -> bool:
	return bool(game.p.get("alive", true))


func dist_player(x: float, z: float) -> float:
	return sqrt((x - px()) * (x - px()) + (z - pz()) * (z - pz()))


func area_id() -> String:
	return String(game.area_id)


func area_info(id: String) -> Dictionary:
	return DmSimData.AREAS.get(id, {})


func boss_def(id: String) -> Dictionary:
	return DmSimData.BOSSES.get(id, {})


## The world that owns zones/corpses: the co-op mirror when the host has one, else the sim.
func world() -> Object:
	var m = game.get("mirror")
	if m != null:
		return m
	return game.get("sim")


func world_time() -> float:
	var w = world()
	return float(w.time) if w != null else 0.0


func enemies_map() -> Dictionary:
	var w = world()
	return w.enemies if w != null else {}


func thralls_map() -> Dictionary:
	var w = world()
	return w.thralls if w != null else {}


func zones_map() -> Dictionary:
	var w = world()
	return w.zones if w != null else {}


func corpses_map() -> Dictionary:
	var w = world()
	return w.corpses if w != null else {}


func boss_state() -> Variant:
	var m = game.get("mirror")
	if m != null:
		return m.bossState
	var s = game.get("sim")
	if s != null and s.boss != null:
		return s.boss.state
	return null


## Colour from SPELL_FX[group][key] as an 0xRRGGBB int (Vfx takes int or Color).
func sp(group: String, key: String) -> int:
	var g: Dictionary = DmFxData.data().get("spell_fx", {}).get(group, {})
	return int(g.get(key, 0xffffff))


func spc(group: String, key: String) -> Color:
	return DmFxData.hex(sp(group, key))


func status_fx(group: String, key: String) -> int:
	var t: Dictionary = DmContent.file("statuses").get("STATUS_FX", {})
	return int(t.get(group, {}).get(key, 0xffffff))


func f(d: Dictionary, k: String, dflt: float = 0.0) -> float:
	var v = d.get(k)
	return dflt if v == null else float(v)


func has_val(d: Dictionary, k: String) -> bool:
	return d.get(k) != null


func snd(sfx: String, x: Variant = null, z: Variant = null, intensity: float = 1.0) -> void:
	if audio == null:
		return
	if x == null:
		audio.play_sfx(sfx, null, intensity)
	else:
		audio.play_sfx(sfx, Vector2(float(x), float(z)), intensity)


func toast(text: String, kind: String = "") -> void:
	game.emit_game_event("toast", {"text": text, "kind": kind})


func banner(title: String, sub: String, ms: int) -> void:
	game.emit_game_event("banner", {"title": title, "sub": sub, "ms": ms})


func float_text(x: float, y: float, z: float, text: String, kind: String) -> void:
	game.float_text(x, y, z, text, kind)


func shake(amount: float) -> void:
	if game.camera != null and game.camera.has_method("shake"):
		game.camera.shake(amount)


func hitstop(seconds: float) -> void:
	game.hitstop(seconds)


func light_flash(x: float, y: float, z: float, color: Variant, intensity: float, life: float) -> void:
	vfx.light_flash(Vector3(x, y, z), DmFxData.to_color(color), intensity, life)


## The web's bb(): a Binbun effect layered through its preset (Vfx.play applies the preset and the partner dim).
func bb(id: String, x: float, z: float, o: Dictionary = {}) -> Variant:
	var opts := o.duplicate()
	if opts.has("colors"):
		var cols: Array = []
		for c in opts["colors"]:
			cols.append(DmFxData.to_color(c))
		opts["colors"] = cols
	return vfx.play(id, Vector3(x, 0.0, z), opts)


func decal(o: Dictionary) -> Variant:
	return vfx.decal(o)


func emit(o: Dictionary) -> void:
	vfx.emit(o)


func emit_smoke(o: Dictionary) -> void:
	vfx.emit_smoke(o)


func beam(a: Vector3, b: Vector3, color: Variant, width: float, duration: float) -> Variant:
	return vfx.beam(a, func(): return b, color, width, duration)


func add_ripple(x: float, z: float, size: float) -> void:
	var b = game.get("builder")
	if b != null and b.has_method("add_ripple"):
		b.add_ripple(x, z, size)


func is_wet(x: float, z: float) -> bool:
	var b = game.get("builder")
	if b != null and b.has_method("is_wet"):
		return bool(b.is_wet(x, z))
	return false


func set_candle_group(g: String, on: bool) -> void:
	var b = game.get("builder")
	if b != null and b.has_method("set_candle_group"):
		b.set_candle_group(g, on)


func later(delay_ms: float, run: Callable) -> void:
	fx_later.append({"at": now() + delay_ms, "run": run})


func hook(name: String, arg: Variant = null) -> void:
	var c: Variant = hooks.get(name)
	if c is Callable and (c as Callable).is_valid():
		(c as Callable).call(arg)


## Call `method` on `obj` (a DmSimCaster subclass) with as many of `args` as it takes; missing methods are skipped.
func call_trim(obj: Object, method: String, args: Array) -> Variant:
	if obj == null or not obj.has_method(method):
		return null
	var scr: Object = obj.get_script()
	var key := "%d:%s" % [scr.get_instance_id() if scr != null else 0, method]
	if not _argc_cache.has(key):
		var n := args.size()
		for m in obj.get_method_list():
			if m["name"] == method:
				n = (m["args"] as Array).size()
				break
		_argc_cache[key] = n
	return obj.callv(method, args.slice(0, mini(int(_argc_cache[key]), args.size())))


func abil(method: String, args: Array) -> void:
	call_trim(game.get("abilities"), method, args)


## Another player's body or ours as a follow target: Callable -> Vector3 | null.
func caster_follow(by: String, x: float, z: float) -> Callable:
	if by == me():
		return func() -> Variant:
			return Vector3(px(), 0.0, pz()) if player_alive() else null
	return func() -> Variant: return remote_xz(by)


## A remote player's latest reported position as a Vector3 (y 0), or null: host `remote_position(id)`, else the `remotes` map
## (entries with tx/tz or x/z, as an Object or a Dictionary).
func remote_xz(id: String) -> Variant:
	if game.has_method("remote_position"):
		var v: Variant = game.remote_position(id)
		if v is Vector3:
			return v
		if v is Vector2:
			return Vector3(v.x, 0.0, v.y)
		return null
	var rem = game.get("remotes")
	if not (rem is Dictionary) or not (rem as Dictionary).has(id):
		return null
	var r = rem[id]
	var tx = r.get("tx") if r is Dictionary else r.get("tx")
	var tz = r.get("tz") if r is Dictionary else r.get("tz")
	if tx == null:
		tx = r.get("x")
		tz = r.get("z")
	return Vector3(float(tx), 0.0, float(tz)) if tx != null and tz != null else null


func _remote_ids() -> Array:
	return game.remote_ids() if game.has_method("remote_ids") else []


func enemy_def(id: Variant) -> String:
	var e = enemies_map().get(int(id))
	return String(e.def) if e != null else ""


# --- the router ------------------------------------------------------------------------------------------------------------

## Another player's cast plays the same effect with fewer particles; enemy zones and events with no owner are never thinned.
func handle(ev: Dictionary) -> void:
	var who: Variant = null
	if ev.has("by"):
		who = ev["by"]
	elif ev.has("owner"):
		who = ev["owner"]
	elif ev.get("t") == "zone":
		var z = ev.get("zone")
		who = z.owner if z is DmSimZone else (z.get("owner") if z is Dictionary else null)
	if not (who is String) or who == me() or not _remote_ids().has(who):
		handle_now(ev)
		return
	var prev: float = vfx.particle_scale
	var prev_role: String = vfx.role
	vfx.particle_scale = prev * PARTNER_FX_SCALE
	vfx.role = "other"
	if audio != null:
		audio.partner = true
	handle_now(ev)
	vfx.particle_scale = prev
	vfx.role = prev_role
	if audio != null:
		audio.partner = false


func handle_now(ev: Dictionary) -> void:
	var views = game.get("views")
	if views != null and views.has_method("on_event"):
		views.on_event(ev)
	var depths = game.get("depths")
	if depths != null and depths.has_method("on_event"):
		depths.on_event(ev)
	if game.has_method("remote_gesture"):
		game.remote_gesture(ev)
	var t: String = String(ev.get("t", ""))
	match t:
		"death":
			_death(ev)
		"hurt":
			if String(ev.get("player", "")) == me():
				hook("on_hurt", ev)
		"nodeGone":
			hook("on_node_gone", ev["id"])
		"nodeBack":
			hook("on_node_back", ev["id"])
		"telegraph":
			vfx.danger(func(): telegraph_fx.telegraph(ev))
		"melee":
			_melee(ev)
		"thrallHit":
			_thrall_hit(ev)
		"zone":
			var z = ev["zone"]
			if z is Dictionary:
				z = DmSimZone.from_dict(z)
			vfx.danger(func(): zones_fx.zone_visual(z), bool(z.hostile))
		"zoneGone":
			zones_fx.zone_gone(int(ev["id"]))
		"wall":
			zones_fx.raise_wall(ev)
		"wallGone":
			zones_fx.wall_gone(int(ev["id"]))
		"rend":
			_rend(ev)
		"mantle":
			var follow: Callable = caster_follow(String(ev["by"]), f(ev, "x"), f(ev, "z"))
			abil("on_mantle", [ev, String(ev["by"]) == me(), follow])
			if String(ev["by"]) == me():
				shake(0.12)
		"offering":
			abil("on_offering", [ev, String(ev["by"]) == me(), caster_follow(String(ev["by"]), f(ev, "x"), f(ev, "z"))])
			if String(ev["by"]) == me() and not bool(ev.get("ok", false)):
				float_text(px(), 2.4, pz(), "The corpse is gone", "info")
		"newBlood":
			if ev.get("kind") == "heal" and String(ev.get("player", "")) == me() and f(ev, "amount") != 0.0:
				hook("on_new_blood_heal", ev)
			abil("on_new_blood", [ev, String(ev["by"]) == me()])
			if String(ev["by"]) == me() and not bool(ev.get("ok", false)):
				float_text(px(), 2.4, pz(), "The target is gone", "info")
		"rally":
			abil("on_rally", [ev, caster_follow(String(ev["by"]), f(ev, "x"), f(ev, "z"))])
		"seeded":
			abil("on_seeded", [ev])
		"seedGone":
			abil("on_seed_gone", [ev["corpseId"]])
		"seedBurst":
			abil("on_seed_burst", [ev])
		"corpseGone":
			abil("on_seed_gone", [ev["id"]])
			_kill_aura("c%d" % int(ev["id"]))
		"thrall":
			_thrall(ev)
		"contagion":
			_contagion(ev)
		"requiem":
			_requiem(ev)
		"heal":
			_heal(ev)
		"burst":
			_burst(ev)
		"exhumed":
			_exhumed(ev)
		"litanyResult":
			abil("on_litany", [ev, String(ev["by"]) == me()])
		"legend":
			hook("on_legend", ev)
			_legend(ev)
		"detonated":
			if bool(ev.get("ok", false)):
				abil("on_detonated", [ev, String(ev["by"]) == me()])
			elif String(ev["by"]) == me():
				hook("on_detonated_refund", ev)
				float_text(px(), 2.4, pz(), "The corpse is gone", "info")
		"bossBusy":
			_boss_busy(ev)
		"sanctify":
			_sanctify(ev)
		"affix":
			_affix(ev)
		"surge":
			snd("surgeStart")
			_surge(ev)
		"surgeCleared":
			snd("surgeCleared")
			_surge_cleared(ev)
		"surgeFailed":
			snd("surgeFailed")
			if surge_fx != null:
				surge_fx.kill()
			surge_fx = null
			if String(ev.get("area", "")) == area_id():
				banner("The Surge Recedes", "The crypt seals itself — its offering lost", 2600)
		"wave":
			_wave(ev)
		"dmg":
			_dmg(ev)
		"boss":
			vfx.danger(func(): boss_fx.on_boss_event(ev))
		"spawn":
			_spawn(ev)
		"corpse":
			_corpse(ev)


# --- cases -----------------------------------------------------------------------------------------------------------------

func _kill_aura(key: String) -> void:
	var h = aura_fx.get(key)
	if h != null:
		h.kill()
	aura_fx.erase(key)


## An enemy's own voice (attack grunt, death cry): only the ones near the hero, by the map's family table.
func foe_voice(table: String, def: String, x: float, z: float, rng: float) -> void:
	if def == "":
		return
	var fam: String = DmAudioMap.enemy_voice(def)
	if fam == "" or dist_player(x, z) > rng:
		return
	snd(DmAudioMap.voice_death(fam) if table == "death" else DmAudioMap.voice_attack(fam), x, z)


func _death(ev: Dictionary) -> void:
	_kill_aura("e%d" % int(ev["id"]))
	var x := f(ev, "x")
	var z := f(ev, "z")
	var elite := bool(ev.get("elite", false))
	snd("eliteDeath" if elite else "enemyDeath", x, z)
	foe_voice("death", String(ev.get("def", "")), x, z, 26.0)
	if elite and dist_player(x, z) < 16.0:
		hitstop(0.8)
	add_ripple(x, z, 2.0 if elite else 1.4)
	_fire_death(ev)
	hook("on_death", ev)


## A camera jolt for a fire burst, fading with distance from the hero (so far-off pools never shake the screen).
func ember_shake(x: float, z: float, amount: float) -> void:
	var d := dist_player(x, z)
	if d < 14.0:
		shake(amount * (1.0 - d / 14.0))


## The Cinder Pyre's dead go out in fire: a flare, sparks and soot (the Husk's pool burst is its own event).
func _fire_death(ev: Dictionary) -> void:
	var def := String(ev.get("def", ""))
	if def != "cinder_husk" and def != "pyre_priest" and def != "cinderhound" and def != "slag_brute":
		return
	var x := f(ev, "x")
	var z := f(ev, "z")
	var big := def == "slag_brute"
	var ember := sp("enemy", "ember")
	var core := sp("enemy", "emberCore")
	var deep := sp("enemy", "emberDeep")
	emit({"x": x, "y": 0.9, "z": z, "count": 40 if big else 18, "color": core, "spread": 0.9 if big else 0.4, "speed": 4.5 if big else 3.0, "up": 3.4 if big else 2.4, "life": 0.9, "size": 0.13, "gravity": 7})
	emit_smoke({"x": x, "y": 0.8, "z": z, "count": 6 if big else 3, "color": deep, "spread": 0.8 if big else 0.4, "speed": 0.9, "up": 0.9, "life": 1.3, "size": 1.6 if big else 1.0, "shrink": -0.6})
	if big:
		bb("surge_eruption", x, z, {"scale": 0.9, "colors": [ember, core, deep]})
		decal({"tex": "ring", "color": ember, "x": x, "z": z, "r": 3.2, "duration": 0.6, "opacity": 0.9, "growFrom": 0.2})
		ember_shake(x, z, 0.14)


func _melee(ev: Dictionary) -> void:
	var def := enemy_def(ev["id"])
	foe_voice("attack", def, f(ev, "x"), f(ev, "z"), 18.0)
	var tx := f(ev, "tx")
	var tz := f(ev, "tz")
	emit_smoke({"x": tx, "y": 0.3, "z": tz, "count": 2, "color": 0x3a3340, "spread": 0.3, "speed": 0.8, "up": 0.3, "life": 0.5, "size": 0.6})
	# The Pyre's dead strike in a shower of sparks.
	if def == "cinder_husk" or def == "cinderhound" or def == "slag_brute":
		emit({"x": tx, "y": 0.9, "z": tz, "count": 12 if def == "slag_brute" else 7, "color": sp("enemy", "emberCore"), "spread": 0.3, "speed": 3, "up": 1.6, "life": 0.4, "size": 0.1, "gravity": 8})


func _thrall_hit(ev: Dictionary) -> void:
	var kind := String(ev.get("kind", ""))
	var x := f(ev, "x")
	var z := f(ev, "z")
	var tx := f(ev, "tx")
	var tz := f(ev, "tz")
	snd("thrallShot" if kind == "archer" else ("thrallMagic" if kind == "wraith" or kind == "bonemage" else "thrallMelee"), tx, tz)
	var color: int = 0x8f9ed1 if kind == "wraith" else (status_fx("hex", "amber") if kind == "bonemage" else 0xd8cfbd)
	var to := func() -> Variant: return Vector3(tx, 1.0, tz)
	if kind == "wraith" or kind == "bonemage":
		vfx.projectile({"from": Vector3(x, 1.3, z), "to": to, "kind": "orb", "color": color, "speed": 14.0 if kind == "bonemage" else 20.0})
	elif kind == "archer":
		vfx.projectile({"from": Vector3(x, 1.3, z), "to": to, "kind": "needle", "color": color, "speed": 26.0, "arc": 0.6})
	else:
		emit({"x": tx, "y": 1, "z": tz, "count": 3, "color": color, "spread": 0.2, "speed": 2, "up": 0.8, "life": 0.3, "size": 0.15, "gravity": 5})
	if kind == "archer":
		bb("archer_flash", x, z)
	if f(ev, "dmg") > 0.0:
		float_text(tx, 1.4, tz, str(int(f(ev, "dmg"))), "thrall")


func _rend(ev: Dictionary) -> void:
	var jade := sp("rend", "jade")
	var bone := sp("rend", "bone")
	var pale := sp("rend", "pale")
	var mine := String(ev["by"]) == me()
	var own := "player" if mine else "thrall"
	for leap in ev.get("leaps", []):
		var fx0 := float(leap[0])
		var fz0 := float(leap[1])
		var tx := float(leap[2])
		var tz := float(leap[3])
		beam(Vector3(fx0, 0.8, fz0), Vector3(tx, 0.8, tz), jade, 0.06, 0.35)
		emit({"x": tx, "y": 0.6, "z": tz, "count": 10, "color": bone, "spread": 0.5, "speed": 3, "up": 1.5, "life": 0.5, "size": 0.14, "gravity": 8})
		# The thrall's claw: a spectral slash across the target, and bone chips where it bites.
		vfx.motifs.bone_splinters(tx, 0.8, tz, {"n": 4, "color": bone, "origin": own})
		vfx.motifs.slash_mark(tx, tz, pale, {"rot": atan2(tx - fx0, tz - fz0), "r": 1.0, "origin": own})
		bb("rend_impact", tx, tz)
	var x := f(ev, "x")
	var z := f(ev, "z")
	decal({"tex": "ring", "color": jade, "x": x, "z": z, "r": 3, "duration": 0.5, "opacity": 1, "growFrom": 0.3})
	light_flash(x, 1.5, z, jade, 40, 0.4)
	snd("boneHit", x, z)
	if mine:
		shake(0.2)


func _thrall(ev: Dictionary) -> void:
	var x := f(ev, "x")
	var z := f(ev, "z")
	var colossus: bool = ev.get("kind") == "colossus"
	if dist_player(x, z) < 40.0:
		bb("thrall_rise", x, z, {"scale": 2.4} if colossus else {})
	if colossus:
		_colossus_rises(x, z, String(ev.get("owner", "")) == me())


## Bone Colossus rune: the ground heaves as the giant stands up (the cast already drew the pull of the bones).
func _colossus_rises(x: float, z: float, mine: bool) -> void:
	decal({"tex": "ring", "color": sp("exhume", "beam"), "x": x, "z": z, "r": 4.2, "duration": 0.8, "opacity": 0.9, "growFrom": 0.2})
	decal({"tex": "cracks", "color": sp("exhume", "deep"), "x": x, "z": z, "r": 3.2, "duration": 2.2, "opacity": 0.8, "growFrom": 0.5, "fadeOut": 0.8})
	emit({"x": x, "y": 0.3, "z": z, "count": 60, "color": sp("exhume", "spirit"), "spread": 1.6, "speed": 1.4, "up": 5, "life": 1.2, "size": 0.4, "gravity": -0.4})
	emit_smoke({"x": x, "y": 0.3, "z": z, "count": 10, "color": 0x2a2f2c, "spread": 1.6, "speed": 1.2, "up": 0.9, "life": 1.5, "size": 2.2, "shrink": -0.8})
	vfx.motifs.grave_dirt(x, z, {"r": 1.6, "n": 16, "up": 4.5, "origin": "thrall"})
	vfx.motifs.bone_splinters(x, 0.8, z, {"n": 12, "color": sp("needle", "core"), "speed": 5})
	light_flash(x, 2, z, sp("exhume", "spirit"), 40, 1.0)
	snd("litany", x, z, 0.8)
	if mine or dist_player(x, z) < 20.0:
		shake(0.24 if mine else 0.14)


## Contagion rune: a thread of rot from the dying body to the next, and spores where it lands.
func _contagion(ev: Dictionary) -> void:
	var rot := sp("lance", "rot")
	var x := f(ev, "x")
	var z := f(ev, "z")
	var tx := f(ev, "tx")
	var tz := f(ev, "tz")
	beam(Vector3(x, 0.9, z), Vector3(tx, 1.0, tz), rot, 0.05, 0.45)
	emit({"x": tx, "y": 0.9, "z": tz, "count": 10, "color": rot, "spread": 0.3, "speed": 1.4, "up": 1, "life": 0.6, "size": 0.2})
	vfx.motifs.rot_spores(tx, tz, rot, {"r": 0.6, "n": 5})
	if dist_player(x, z) < 24.0:
		snd("miasma", tx, tz)


## Requiem rune: the ground is marked; a ring of skulls closes in over the warning and the burst follows.
func _requiem(ev: Dictionary) -> void:
	var core := sp("litany", "core")
	var hot := sp("litany", "hot")
	var x := f(ev, "x")
	var z := f(ev, "z")
	var r := f(ev, "r")
	var sec := f(ev, "ms") / 1000.0
	decal({"tex": "sigil", "color": core, "x": x, "z": z, "r": r, "duration": sec, "opacity": 0.55, "growFrom": 0.6, "spin": 0.5, "fadeOut": 0.3})
	decal({"tex": "ring", "color": hot, "x": x, "z": z, "r": r, "duration": sec, "opacity": 0.9, "growFrom": 1.0, "pulse": 4})
	decal({"tex": "ring", "color": core, "x": x, "z": z, "r": r * 0.45, "duration": sec, "opacity": 0.5, "growFrom": 1.6})
	vfx.motifs.skull_ring(x, z, minf(r * 0.7, 9.0), hot, {"n": 8, "origin": "player" if String(ev["by"]) == me() else "thrall"})
	snd("toll", x, z)
	later(f(ev, "ms") * 0.5, func(): snd("tollSmall", x, z))


func _max_hp() -> float:
	var st: Dictionary = game.p.get("stats", {})
	return float(st.get("maxHp", 0.0))


func _heal(ev: Dictionary) -> void:
	if String(ev.get("player", "")) == me() and player_alive():
		var amount := _max_hp() * f(ev, "frac") if f(ev, "frac") != 0.0 else f(ev, "amount")
		var e2 := ev.duplicate()
		e2["resolved"] = amount
		hook("on_heal", e2)
		float_text(px(), 2.2, pz(), "+%d" % DmMath.js_round(amount), "heal")


func _burst(ev: Dictionary) -> void:
	var x := f(ev, "x")
	var z := f(ev, "z")
	var r := f(ev, "r")
	var kind := String(ev.get("kind", ""))
	if kind != "ember":
		snd("burst", x, z)
	if kind == "ember":
		# A Cinder Husk's last embers (enemy fire, never the player's Miasma green or Corpse Explosion violet).
		var ember := sp("enemy", "ember")
		var core := sp("enemy", "emberCore")
		var deep := sp("enemy", "emberDeep")
		snd("emberBurst", x, z)
		bb("vengeful_burst", x, z, {"scale": r / 1.4, "colors": [ember, core, deep]})
		ember_shake(x, z, 0.05)
		decal({"tex": "ring", "color": ember, "x": x, "z": z, "r": r, "duration": 0.5, "growFrom": 0.2, "opacity": 1})
		emit({"x": x, "y": 0.5, "z": z, "count": 26, "color": core, "spread": r * 0.5, "speed": 3.2, "up": 2.4, "life": 0.9, "size": 0.2, "gravity": 5})
		emit_smoke({"x": x, "y": 0.4, "z": z, "count": 6, "color": deep, "spread": r * 0.4, "speed": 1.2, "up": 0.9, "life": 1.4, "size": 1.5, "shrink": -1})
		return
	var toxic := kind == "toxic"
	decal({"tex": "ring", "color": 0x8fa05a if toxic else 0xb58cff, "x": x, "z": z, "r": r, "duration": 0.5, "growFrom": 0.2, "opacity": 1})
	emit({"x": x, "y": 0.6, "z": z, "count": 30, "color": 0x8fa05a if toxic else 0xb58cff, "spread": r * 0.5, "speed": 3, "up": 1.5, "life": 0.8, "size": 0.35})
	emit_smoke({"x": x, "y": 0.4, "z": z, "count": 8, "color": 0x3d4a22 if toxic else 0x3a2d55, "spread": r * 0.4, "speed": 1.2, "up": 0.8, "life": 1.4, "size": 1.6, "shrink": -1})
	if toxic or kind == "bloom":
		vfx.motifs.rot_spores(x, z, 0x8fa05a if toxic else sp("bloom", "petal"), {"r": r * 0.6, "n": 8})


func _exhumed(ev: Dictionary) -> void:
	if String(ev["by"]) != me():
		return
	if not bool(ev.get("ok", false)):
		# Someone else claimed it first: refund.
		hook("on_exhumed_refund", ev)
		float_text(px(), 2.4, pz(), "Too few corpses for a Colossus" if ev.get("why") == "few" else "The corpse is gone", "info")
	else:
		abil("on_corpse_consumed", [])
		hook("on_exhumed_ok", ev)


func _boss_busy(ev: Dictionary) -> void:
	# The host refused our summon (another boss woke first): the host refunds the shards, or the Seal and gold.
	if String(ev["by"]) != me():
		return
	var boss_id := String(ev.get("boss", ""))
	var empowered: bool = boss_id != "prelate" and game.get("empower_pending") == boss_id
	var hk: Variant = hooks.get("on_boss_busy", hooks.get("on_boss_bussy"))
	if hk is Callable and (hk as Callable).is_valid():
		var e2 := ev.duplicate()
		e2["empowered"] = empowered
		(hk as Callable).call(e2)
	var awake := String(ev.get("awake", ""))
	var bd := boss_def(awake)
	toast("%s already stirs in %s. %s" % [bd.get("name", awake), area_info(String(bd.get("area", ""))).get("name", ""), "Your Seal and gold are returned." if empowered else "Your shards are returned."], "err")


func _sanctify(ev: Dictionary) -> void:
	var tx := f(ev, "tx")
	var tz := f(ev, "tz")
	game.emit_game_event("sanctify_near", {"dist": dist_player(tx, tz)})
	# Pale gold thread from the Deacon; a halo settles on the blessed.
	var gold := status_fx("sanctified", "gold")
	var pale := status_fx("sanctified", "pale")
	beam(Vector3(f(ev, "x"), 1.9, f(ev, "z")), Vector3(tx, 1.6, tz), gold, 0.04, 0.5)
	decal({"tex": "ring", "color": gold, "x": tx, "z": tz, "r": 1.1, "duration": 0.8, "opacity": 0.8, "growFrom": 1.8})
	emit({"x": tx, "y": 1.8, "z": tz, "count": 10, "color": pale, "spread": 0.4, "speed": 0.6, "up": 0.8, "life": 0.6, "size": 0.18})


func _affix(ev: Dictionary) -> void:
	var x := f(ev, "x")
	var z := f(ev, "z")
	snd("affixTell", x, z)
	var affix := String(ev.get("affix", ""))
	if affix == "hungering" and f(ev, "amount") != 0.0:
		float_text(x, 2.4, z, "+%d" % int(f(ev, "amount")), "dot")
	elif affix == "bellTolled":
		bb("bell_toll_ring", x, z, {"scale": f(ev, "r", 3.0) / 3.0})
	elif affix == "vengeful":
		bb("vengeful_burst", x, z)


## Grave Surges.
func _surge(ev: Dictionary) -> void:
	var x := f(ev, "x")
	var z := f(ev, "z")
	var ms := f(ev, "durationMs") / 1000.0
	if surge_fx != null:
		surge_fx.kill()
	# The cracked crypt stays marked for the surge's whole life.
	surge_fx = decal({"tex": "cracks", "color": sp("surge", "crack"), "x": x, "z": z, "r": 3.6, "duration": ms, "opacity": 0.85, "growFrom": 0.2, "pulse": 2})
	var glow := sp("surge", "glow")
	decal({"tex": "ring", "color": glow, "x": x, "z": z, "r": 5, "duration": 1.2, "opacity": 1, "growFrom": 0.1})
	emit({"x": x, "y": 0.5, "z": z, "count": 60, "color": glow, "spread": 1.2, "speed": 3, "up": 3, "life": 1.2, "size": 0.32})
	light_flash(x, 2, z, glow, 60, 1.2)
	bb("surge_eruption", x, z)
	bb("crypt_mist", x, z, {"duration": minf(ms, 20.0)})
	if bool(ev.get("crypt", false)):
		# The tomb's seal gives: grave-dust billows and bone chips scatter from its door.
		emit_smoke({"x": x, "y": 0.6, "z": z, "count": 18, "color": 0x4a4250, "spread": 1.4, "speed": 1.2, "up": 1.4, "life": 2.2, "size": 2.2, "shrink": -0.8})
		emit({"x": x, "y": 1, "z": z, "count": 30, "color": sp("detonate", "bone"), "spread": 0.8, "speed": 4, "up": 3, "life": 0.9, "size": 0.14, "gravity": 9})
	snd("gate", x, z)
	var area := String(ev.get("area", ""))
	var aname := String(area_info(area).get("name", area))
	if area == area_id():
		banner("Grave Surge", "A crypt cracks open in %s — hold it back for its offering" % aname, 3400)
		game.emit_game_event("surge_opened", {})
		shake(0.35)
	else:
		toast("A Grave Surge erupts in %s" % aname, "err")


func _surge_cleared(ev: Dictionary) -> void:
	if surge_fx != null:
		surge_fx.kill()
	surge_fx = null
	var x := f(ev, "x")
	var z := f(ev, "z")
	var near: bool = area_id() == String(ev.get("area", "")) or dist_player(x, z) < 38.0
	if not player_alive() or not near:
		return
	banner("Surge Quelled", "The crypt yields its offering", 3200)
	snd("levelUp")
	# Personal reward: a guaranteed item from the area's table plus bonus gold (host).
	hook("on_surge_cleared", ev)
	emit({"x": x, "y": 0.4, "z": z, "count": 70, "color": sp("surge", "glow"), "spread": 1, "speed": 1.2, "up": 4, "life": 1.4, "size": 0.34})
	light_flash(x, 2, z, sp("surge", "glow"), 70, 1.2)


func _wave(ev: Dictionary) -> void:
	var area := String(ev.get("area", ""))
	if area != area_id():
		return
	var x := f(ev, "x")
	var z := f(ev, "z")
	snd("wave", x, z)
	decal({"tex": "cracks", "color": 0x9b5cff, "x": x, "z": z, "r": 3, "duration": 1.8, "opacity": 0.9, "growFrom": 0.3})
	light_flash(x, 1, z, 0x7c3aed, 30, 0.8)
	bb("enemy_breach_rim", x, z)
	# Introduce a themed wave once per area: at high Wave Speed, repeated processions otherwise cover combat with the same banner.
	var theme_id: Variant = ev.get("theme")
	if theme_id != null and not announced_processions.has(area):
		for th in DmSimData.WAVE_THEMES.get(area, []):
			if th["id"] == theme_id:
				announced_processions[area] = true
				banner(String(th["name"]), String(th["blurb"]), 2600)
				snd("tollSmall", x, z)
				break


func _dmg(ev: Dictionary) -> void:
	var kind := String(ev.get("kind", ""))
	if kind == "dot":
		float_text(f(ev, "x"), 1.2, f(ev, "z"), str(int(f(ev, "amount"))), "dot")
	elif kind == "litany" and String(ev.get("by", "")) == me():
		float_text(f(ev, "x"), 2.6, f(ev, "z"), _group_digits(int(f(ev, "amount"))), "big")


static func _group_digits(n: int) -> String:
	var s := str(absi(n))
	var out := ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return ("-" if n < 0 else "") + s + out


func _spawn(ev: Dictionary) -> void:
	var x := f(ev, "x")
	var z := f(ev, "z")
	var elite := bool(ev.get("elite", false))
	var def := String(ev.get("def", ""))
	var near := dist_player(x, z) < 40.0
	if elite and near:
		snd("eliteAggro", x, z)
	if def == "censer":
		var id := int(ev["id"])
		var follow := func() -> Variant:
			var e = enemies_map().get(id)
			return Vector3(e.x, 0.0, e.z) if e != null and e.state != "dead" else null
		aura_fx["e%d" % id] = bb("censer_incense", x, z, {"follow": follow})
	if near:
		# Codex + counsel: only what this player actually encounters.
		if game.has_method("codex_discover"):
			game.codex_discover("dead", def)
		game.emit_game_event("enemy_spawned", {"def": def, "elite": elite, "near": true, "area_safe": bool(area_info(area_id()).get("safe", false))})


func _corpse(ev: Dictionary) -> void:
	var c = ev["corpse"]
	if c is Dictionary:
		c = DmSimCorpse.from_dict(c)
	game.emit_game_event("corpse_near", {"area_safe": bool(area_info(area_id()).get("safe", false)), "dist": dist_player(c.x, c.z)})
	if c.kind == "toxic":
		aura_fx["c%d" % c.id] = bb("toxic_stink", c.x, c.z)


## Legendary set VFX from the sim (death burst, rally mark, Contagion, Chain Plague): at most LEGEND_FX_MAX per half second, near the camera.
func _legend(ev: Dictionary) -> void:
	if not ev.has("kind"):
		return
	var x := f(ev, "x")
	var z := f(ev, "z")
	if dist_player(x, z) > 28.0:
		return
	if ev["kind"] == "rally":
		if rally_mark != null:
			rally_mark.kill()
		var id := int(ev["id"]) if ev.get("id") != null else -1
		var follow := func() -> Variant:
			if id < 0:
				var b = boss_state()
				return Vector3(b.x, 0.0, b.z) if b != null and b.active else null
			var e = enemies_map().get(id)
			return Vector3(e.x, 0.0, e.z) if e != null else null
		rally_mark = decal({"tex": "sigil", "color": 0xd9a441, "x": x, "z": z, "r": 0.95, "duration": float(DmSimData.LEGEND["rallyS"]), "opacity": 0.85, "pulse": 2.5, "spin": 0.8, "follow": follow})
		float_text(x, 2.2, z, "Rally", "info")
		return
	if now() - legend_fx_at > 500.0:
		legend_fx_at = now()
		legend_fx_n = 0
	legend_fx_n += 1
	if legend_fx_n > LEGEND_FX_MAX:
		return
	var r := f(ev, "r", 3.0)
	var rot := sp("miasma", "rot")
	match String(ev["kind"]):
		"deathBurst":
			decal({"tex": "ring", "color": 0xe8dcc0, "x": x, "z": z, "r": r, "duration": 0.4, "opacity": 0.9, "growFrom": 0.2})
			vfx.motifs.bone_splinters(x, 0.9, z, {"n": 10, "color": 0xe8dcc0, "speed": 5.5})
			emit({"x": x, "y": 0.7, "z": z, "count": 12, "color": 0xe8dcc0, "spread": r * 0.3, "speed": 4, "up": 1.4, "life": 0.45, "size": 0.18, "gravity": 6})
			if legend_fx_n == 1:
				snd("boneHit", x, z, 1.0)
		"spread":
			decal({"tex": "ring", "color": rot, "x": x, "z": z, "r": r * 0.7, "duration": 0.35, "opacity": 0.7, "growFrom": 0.2})
			vfx.motifs.rot_spores(x, z, rot, {"r": r * 0.5, "n": 6})
		"plague":
			decal({"tex": "ring", "color": rot, "x": x, "z": z, "r": r, "duration": 0.5, "opacity": 0.9, "growFrom": 0.15})
			vfx.motifs.rot_spores(x, z, rot, {"r": r * 0.6, "n": 10})
			emit({"x": x, "y": 0.5, "z": z, "count": 14, "color": rot, "spread": r * 0.4, "speed": 2.6, "up": 1.2, "life": 0.55, "size": 0.22})
			if legend_fx_n == 1:
				snd("miasma", x, z, 0.7)


# --- frame -----------------------------------------------------------------------------------------------------------------

## Per frame (after the sim step): fxLater timers on the scene clock, zone ambience, wading ripples, echo marks, aura cleanup.
func update(dt: float) -> void:
	var t := now()
	if not fx_later.is_empty():
		var due: Array = []
		var keep: Array = []
		for item in fx_later:
			if float(item["at"]) <= t:
				due.append(item)
			else:
				keep.append(item)
		fx_later = keep
		for item in due:
			(item["run"] as Callable).call()
	zones_fx.zone_ambience(dt)
	zones_fx.wade_ripples(dt)
	zones_fx.sync_echo_visuals()
	for k in aura_fx.keys():
		var h = aura_fx[k]
		if h == null or not h.alive:
			aura_fx.erase(k)


## Area change / teardown: drop every tracked handle and queued effect.
func clear() -> void:
	fx_later.clear()
	for k in aura_fx:
		aura_fx[k].kill()
	aura_fx.clear()
	zones_fx.clear()
	boss_fx.clear()
	if surge_fx != null:
		surge_fx.kill()
	surge_fx = null
	if rally_mark != null:
		rally_mark.kill()
	rally_mark = null
