class_name DmAreaFlow
extends Node
## What happens around the areas of the rebuild (child "Areas" of DmNextGame): the entry banner and Codex discovery on entering an area (the
## current game's DmGame._enter_area), the "wave procession" banner, and Grave Surge presentation + reward (DmEventFx._surge / _surge_cleared).
## Event driven: it does nothing between area changes, processions and surges.

signal entered(id: String, first: bool)

const FIRST_ENTRY_COUNSEL := ["cloister", "pyre", "fen", "warren", "alchemist_wing", "coliseum", "acre"]   ## DmGame._enter_area

var game: DmNextGame
var announced: Dictionary = {}          ## area id -> true once its banner was shown this session
var announced_processions: Dictionary = {}   ## area id -> true: a procession is introduced once per area (repeats would cover combat with the banner)
var surge_fx: Variant = null
var _vfx: Node
var _audio: Node


func setup(game_: DmNextGame) -> void:
	game = game_
	var visual: bool = bool(game.opts.get("visual", true)) and DisplayServer.get_name() != "headless"
	_vfx = get_node_or_null("/root/Vfx") if visual else null
	_audio = get_node_or_null("/root/AudioDirector") if visual else null
	game.area_changed.connect(enter)
	game.director.procession.connect(_on_procession)
	game.director.surge_event.connect(_on_surge)
	enter(game.area_id)


## The area the hero stands in: banner (first time), counsel + Codex events, the rewards' fallback area.
func enter(id: String) -> void:
	if game.rewards != null:
		game.rewards.area_id = id
	var def: Dictionary = DmContent.area(id)
	var first := not announced.has(id)
	if first:
		announced[id] = true
		if id != "depths":
			_event("banner", {"title": def["name"], "sub": def["subtitle"], "ms": 3000})
		if FIRST_ENTRY_COUNSEL.has(id):
			_event("area_first_entered", {"area": id})
	_event("codex", {"kind": "area", "id": id})
	entered.emit(id, first)


func _on_procession(theme: Dictionary) -> void:
	var area := game.director.area_id
	if announced_processions.has(area):
		return
	announced_processions[area] = true
	_event("banner", {"title": theme["name"], "sub": theme["blurb"], "ms": 2600})
	_sfx("tollSmall")


func _on_surge(ev: Dictionary) -> void:
	var x := float(ev["x"])
	var z := float(ev["z"])
	match String(ev["t"]):
		"surge":
			_sfx("surgeStart")
			_surge_open(ev)
			_event("banner", {"title": "Grave Surge", "sub": "A crypt cracks open in %s — hold it back for its offering" % String(DmContent.area(String(ev["area"]))["name"]), "ms": 3400})
			_event("surge_opened", {})
			game.camera.shake(0.35)
		"surgeCleared":
			_surge_close()
			_sfx("surgeCleared")
			_event("banner", {"title": "Surge Quelled", "sub": "The crypt yields its offering", "ms": 3200})
			_sfx("levelUp")
			if game.rewards != null and game.session.is_host():
				game.rewards.on_surge_cleared(ev)
			if _vfx != null:
				var glow: int = int(DmContent.spell_fx()["surge"]["glow"])
				_vfx.emit({"x": x, "y": 0.4, "z": z, "count": 70, "color": glow, "spread": 1.0, "speed": 1.2, "up": 4.0, "life": 1.4, "size": 0.34})
				_vfx.light_flash(Vector3(x, 2.0, z), Color.hex(glow * 256 + 255), 70.0, 1.2)
		"surgeFailed":
			_surge_close()
			_sfx("surgeFailed")
			if game.area_id == String(ev["area"]):
				_event("banner", {"title": "The Surge Recedes", "sub": "The crypt seals itself — its offering lost", "ms": 2600})


func _surge_open(ev: Dictionary) -> void:
	_surge_close()
	if _vfx == null:
		return
	var x := float(ev["x"])
	var z := float(ev["z"])
	var fx: Dictionary = DmContent.spell_fx()["surge"]
	var ms := float(ev["durationMs"]) / 1000.0
	surge_fx = _vfx.decal({"tex": "cracks", "color": int(fx["crack"]), "x": x, "z": z, "r": 3.6, "duration": ms, "opacity": 0.85, "growFrom": 0.2, "pulse": 2})   # marked for the surge's whole life
	_vfx.decal({"tex": "ring", "color": int(fx["glow"]), "x": x, "z": z, "r": 5, "duration": 1.2, "opacity": 1, "growFrom": 0.1})
	_vfx.emit({"x": x, "y": 0.5, "z": z, "count": 60, "color": int(fx["glow"]), "spread": 1.2, "speed": 3, "up": 3, "life": 1.2, "size": 0.32})
	_vfx.play("surge_eruption", Vector3(x, 0, z), {})
	_sfx("gate", x, z)


func _surge_close() -> void:
	if surge_fx != null and surge_fx.has_method("kill"):
		surge_fx.kill()
	surge_fx = null


func _event(id: String, ctx: Dictionary = {}) -> void:
	if game.ui_host != null:
		game.ui_host.game_event.emit(id, ctx)


func _sfx(id: String, x: float = NAN, z: float = NAN) -> void:
	if _audio != null:
		_audio.play_sfx(id, null if is_nan(x) else Vector2(x, z), 1.0)
