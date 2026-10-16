class_name DmWaveMilestones
extends Node
## Wave-milestone presentation of the rebuild (child "Milestones" of DmNextGame, host): the banner when the Wave Speed tier crosses a milestone
## (Elite Vanguard 3, Restless Crypts 6, Nightfall 8), the "fades" toast when it drops back, and the Nightfall light dimming (the original game's
## DmGameRewards.tick_milestones). The VARIANTS themselves (the vanguard elite, shrouded commons, sooner surges) are the director's
## (`DmWaveDirector.milestone`). Event driven: `on_tier` is called when the tier changes (DmNextProgress.apply_progress), and `_process` only runs
## while the light is easing toward its target (about 4 s per change), never otherwise.

signal announced(kind: String, id: String)         ## banner | fades (tests, HUD)

const MOON_DIM := 0.6                              ## moon energy x (1 - 0.6 night)
const AMBIENT_DIM := 0.3                           ## hemisphere energy x (1 - 0.3 night)
const EASE := 0.8                                  ## night_k follows its target at this rate per second

var game: Node
var seen_tier: float = -1.0                        ## -1 = no tier seen yet (the first one is the loaded state: no banner)
var night_k: float = 0.0                           ## 0 = day, 1 = full Nightfall
var target: float = 0.0
var _applied_moon: float = 1.0                     ## the factors now applied to the lights (the lights are scaled by ratio, so other writers compose)
var _applied_ambient: float = 1.0


func setup(game_: Node) -> void:
	game = game_
	game.area_changed.connect(func(_id: String) -> void: _retarget())
	set_process(false)


func on_tier(tier: float) -> void:
	if tier != seen_tier:
		if seen_tier >= 0.0:
			for m in DmContent.get_export("upgrades", "WAVE_MILESTONES"):
				if tier >= float(m["tier"]) and seen_tier < float(m["tier"]):
					_say("banner", {"title": m["name"], "sub": m["blurb"], "ms": 3200})
					announced.emit("banner", String(m["id"]))
				elif tier < float(m["tier"]) and seen_tier >= float(m["tier"]):
					_say("toast", {"text": "%s fades" % m["name"], "kind": ""})
					announced.emit("fades", String(m["id"]))
		seen_tier = tier
	_retarget()


## The Acre's lights stay (the orchard is never dark).
func _retarget() -> void:
	var acre := String(game.area_id) in ["acre", "alchemist_wing"]
	target = 1.0 if (seen_tier >= 0.0 and DmWaveUpgrades.milestone_active("nightfall", seen_tier) and not acre) else 0.0
	set_process(not is_equal_approx(night_k, target))


func _process(dt: float) -> void:
	night_k += (target - night_k) * minf(1.0, dt * EASE)
	if absf(target - night_k) < 0.002:
		night_k = target
		set_process(false)
	var b: DmWorldBuilder = game.builder
	if b == null or b.moon == null or b.env == null:
		return
	var moon := 1.0 - MOON_DIM * night_k
	var amb := 1.0 - AMBIENT_DIM * night_k
	b.moon.light_energy *= moon / _applied_moon
	b.env.ambient_light_energy *= amb / _applied_ambient
	_applied_moon = moon
	_applied_ambient = amb


func _say(id: String, ctx: Dictionary) -> void:
	var ui: Node = game.get("ui_host")
	if ui != null:
		ui.game_event.emit(id, ctx)
