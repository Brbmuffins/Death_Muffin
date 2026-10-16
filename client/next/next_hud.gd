class_name DmNextHud
extends CanvasLayer
## The HUD of the game scene on the combat core (client/code.list "Ported"): today's HUD (`DmHud`: orbs, hotbar with cooldowns and the cast state, target frame,
## minimap, thrall pips, XP and level, area line, banners and toasts, floating numbers, the death veil), fed by `DmNextHudVm` from the core's bulk arrays and
## listening to the core host's signals. Nothing here runs per creature per frame: the view-model is built on a 20 Hz timer (a core tick counts the time, as DmGameUi's
## HUD_INTERVAL_MS), the floating numbers come from signals, and the HUD's own widgets animate themselves.
##
## What it needs besides the game scene: the character (level, XP, gold), its progression (`prog`: this player's rewards member's, which the server's accepted
## reports and saves keep current; a guest's, the record it started with), and the kit's rites for the hotbar. The upgrades box buys Empower / Quicken and turns the
## wave dial through the progression (DmNextProgress.buy, DmProgression.set_active_wave_tier); it and the dial show by today's rules (DmHudReveal.veteran_reveals, without
## the onboarding's NEW cues). The belt (Q the flask, Z / X the brews), the Kill Chain, the Omen and the save chip are today's; game moments (toasts, banners, floats,
## pickup lines) arrive through `game_event`.
## The menu row shows the Social button only: it opens the Social window (`social`, DmNextSocial: Friends and Party, O and F), the way into a party. Not in this step, each until its
## ROADMAP item: the other panels (the rest of the menu row, chat and the report button are hidden: they open nothing yet), party frames of other players and the Depths
## readout. The game scene wires the HUD with opts `hud: true`; opts `hud_scale` (0.75 to 1.3) and `hud_layout` (DmHud.set_layout) place and size its pieces.
##
##   var h := DmNextHud.new(); h.game = game_scene; game_scene.add_child(h)    # DmNextGame._start_hud

const INTERVAL := 0.05                      ## DmGameUi.HUD_INTERVAL_MS
const TARGET_HOLD_S := 4.0                  ## the target frame keeps the enemy a cast was aimed at this long after the cursor leaves it
const HERO_STATUS_TEXT := {&"chill": "Chilled", &"root": "Rooted", &"stun": "Stunned"}   ## the floats over the hero when one lands (DmGameCombat.on_hurt / drag_player)
const REJECT_TEXT := {"essence": "Not enough Grave Essence", "souls": "Not enough souls (%d needed)", "cooldown": "%s is not ready", "locked": "%s unlocks at level %d"}
const FEEDBACK_GAP_MS := 600
const HIT_KINDS := ["hit", "crit", "dot", "thrall", "hurt"]   ## the floats the "damage numbers" setting turns off
## The menu row's gated buttons (Acre, Atlas) wait for the panels item, with the rest of the row but Social; the upgrades box and the wave dial follow `_reveal`.
const SAVE_CHIP := {"saved": ["Saved ✓", false], "dirty": ["Unsaved changes", false], "saving": ["Saving…", false], "retrying": ["Save failed, retrying…", true]}
const SAVE_RANK := ["saved", "dirty", "saving", "retrying"]

signal refreshed                            ## after each view-model apply (tests)

var game: DmNextGame
var hud: DmHud
var social: DmNextSocial                    ## the Social window (when the game scene has a party: every real game does)
var vm: DmNextHudVm
var character: Dictionary = {}
var prog: DmProgression
var progress: Dictionary:                   ## the progression record (damage and wave tiers, shards, ...)
	get: return prog.local
var primary := ""                           ## the rite on LMB, keys 1-4 and RMB, and the signature on R: the kit's mapping (DmRiteHotbar)
var keys: Array = []
var signature := ""
var dev_access := false
var damage_numbers := true
var floats := DmFloatBudget.new()           ## on-screen cap of the combat numbers (hit / crit / dot / thrall)
var refreshes := 0
var refresh_us := 0                         ## microseconds spent in all refreshes so far (the F3 overlay and the HUD measurement read it)
var feeds: Dictionary = {}                  ## view-model keys the systems that are not in the scene yet feed (belt rows, Kill Chain, Omen, prompt, Depths, party list), merged over the core-built ones

var _t := 0.0
var _vm: Dictionary = {}
var _elite := {}                            ## core id -> true for every living elite (the minimap draws them larger; the core's bulk arrays do not carry it)
var _thrall := {}                           ## core id -> true for every living thrall (a thrall's blow gets a number)
var _kills := {}                            ## area id -> enemies that died there
var _target_id := 0
var _target_until := 0.0
var _last_feedback := 0
var _announced := {}
var _hero_status := {}
var _bound := false
var _reveal := {"hud.upgrades": false, "hud.dial": false, "menu.skills": false, "menu.atlas": false}
var _reveal_sig := []
var _save_vm := {"text": "Saved ✓", "warn": false}


func _ready() -> void:
	layer = 5
	character = game.character
	var m := game.my_member()
	prog = m.prog if m != null else DmProgression.new(character, game.server_local)   # the host's progression: credited XP and gold land in `character`
	hud = DmHud.new()
	add_child(hud)
	for id in hud.menu_btns:                 # the panels open from here: only the Social window is in this step
		hud.menu_btns[id].visible = id == "friends"
	hud.chat_col.visible = false
	hud.set_hud_scale(float(game.opts.get("hud_scale", 1.0)))    # the HUD scale setting, anchors kept
	var saved: Variant = game.opts.get("hud_layout", {})
	if saved is Dictionary and not saved.is_empty():
		hud.set_layout(saved)                                    # a saved layout: {piece id: {offset: Vector2, scale: float}}
	hud.cast.connect(_on_cast)
	hud.navigate.connect(_on_navigate)
	hud.buy_damage.connect(_buy.bind("damage"))
	hud.buy_wave.connect(_buy.bind("wave"))
	hud.dial_wave.connect(_dial_wave)
	hud.belt_clicked.connect(game.use_belt)
	if game.party != null and game.friends != null:
		social = DmNextSocial.new()
		add_child(social)
		social.setup(game.party, game.friends, hud)
		social.toast = func(text: String, kind: String) -> void: hud.toast(text, kind)
	bind()


## Connects the HUD to the game: the kit's mapping, the core host's signals, the hero's caster and body. Called once, when the hero exists.
func bind() -> void:
	var b := game.local_body()
	if _bound or b == null:
		return
	_bound = true
	primary = game.rite_for_slot(0)
	keys = []
	for slot in range(1, 6):
		keys.append(game.rite_for_slot(slot))
	signature = game.rite_for_slot(6)
	vm = DmNextHudVm.new(self)
	var ch := game.core_host
	ch.ticked.connect(_on_ticked)
	ch.enemy_spawned.connect(_on_enemy_spawned)
	ch.enemy_removed.connect(func(id: int) -> void: _elite.erase(id))
	ch.enemy_died.connect(_on_enemy_died)
	ch.thrall_raised.connect(func(id: int, _k: String, _o: int, _s: int, _e: bool, _c: bool, _x: float, _z: float, _y: float, _h: float) -> void: _thrall[id] = true)
	ch.thrall_removed.connect(func(id: int) -> void: _thrall.erase(id))
	ch.enemy_damaged.connect(_on_enemy_damaged)
	ch.status_dot.connect(_on_status_dot)
	game.input.hotbar.connect(_on_hotbar)
	game.area_changed.connect(_on_area_changed)
	game.director.procession.connect(_on_procession)
	b.hurt.connect(_on_hurt)
	b.enemy_effect.connect(_on_hero_effect)
	var caster := b.get_node_or_null("Rites") as DmRiteCaster
	if caster != null:
		caster.hit_number.connect(_on_hit_number)
		caster.cast_rejected.connect(_on_rejected)
	var hs := DmStatusSet.of(b)
	if hs != null:
		hs.changed.connect(_on_hero_statuses.bind(hs))
	_on_area_changed(game.area_id)
	refresh()


# ---- the view-model ------------------------------------------------------------------------------------------------------------------

func _on_ticked(dt: float) -> void:
	_t -= dt
	if _t <= 0.0:
		_t = INTERVAL
		refresh()


## Builds the view-model from the core and applies it (20 Hz; tests call it directly).
func refresh() -> void:
	if vm == null:
		return
	var t0 := Time.get_ticks_usec()
	_vm = vm.build()
	if _vm.is_empty():
		return
	_vm["reveal"] = _reveals()
	if not feeds.is_empty():
		_vm.merge(feeds, true)
	hud.apply(_vm)
	refreshes += 1
	refresh_us += Time.get_ticks_usec() - t0
	refreshed.emit()


## The view-model of the last refresh (tests read it).
func last_vm() -> Dictionary:
	return _vm


## The save chip: the worst state of the progression's saves and the bag's.
func save_chip() -> Dictionary:
	var st := "saved"
	for s_: String in [game.progress.psync.state if game.progress != null else "saved", game.loot.inventory.state if game.loot != null and game.loot.inventory != null else "saved"]:
		if SAVE_RANK.find(s_) > SAVE_RANK.find(st):
			st = s_
	var c: Array = SAVE_CHIP[st]
	_save_vm["text"] = c[0]
	_save_vm["warn"] = c[1]
	return _save_vm


## What the HUD shows of the upgrades: the box once the character has earned (level 2, gold or a tier), the wave dial once a Wave Speed tier is owned
## (DmHudReveal.veteran_reveals on the current record; today's NEW cue toasts come with the onboarding item).
func _reveals() -> Dictionary:
	var loc := progress
	var sig := [character.get("level"), character.get("gold"), loc.get("damageTier"), loc.get("waveTierOwned")]
	if sig != _reveal_sig:
		_reveal_sig = sig
		var on := DmHudReveal.veteran_reveals({"level": int(character.get("level", 1)), "gold": int(character.get("gold", 0)), "damage_tier": int(loc.get("damageTier", 0)),
			"wave_owned": int(loc.get("waveTierOwned", 0))})
		_reveal["hud.upgrades"] = on.has("hud.upgrades")
		_reveal["hud.dial"] = on.has("hud.dial")
	return _reveal


## The upgrades box's buttons: the progression buys (the backend prices and takes the gold); the new tier shows at once.
func _buy(kind: String) -> void:
	if game.progress != null and game.progress.buy(kind):
		refresh()


## The upgrades box's wave dial: the active Wave Speed tier, 0..owned; the director and the rewards follow (today's DmNextUiHost.dial_wave).
func _dial_wave(delta: int) -> void:
	if game.progress == null:
		return
	prog.set_active_wave_tier(float(prog.local["waveTierActive"]) + delta)
	game.progress.apply_progress()
	refresh()


## Q drinks the flask, Z / X the belt's brews (DmContent brews BREW_KEYS).
func _unhandled_key_input(event: InputEvent) -> void:
	var e := event as InputEventKey
	if e == null or not e.pressed or e.echo or get_viewport().gui_get_focus_owner() is LineEdit:
		return
	if e.keycode == KEY_Q:
		game.use_belt("heal")
	else:
		for slot in ["elixir", "tonic"]:   # Z / X (BREW_KEYS)
			if e.keycode == OS.find_keycode_from_string(String(DmContent.get_export("brews", "BREW_KEYS")[slot])):
				game.use_belt(slot)


func kills_in(area: String) -> int:
	return int(_kills.get(area, 0))


func is_elite(id: int) -> bool:
	return _elite.has(id)


## The enemy the target frame shows: the one under the cursor, else the last one a cast was aimed at for a few seconds; 0 = none.
func target_id() -> int:
	var tid := game.input.hovered_enemy_id()
	if tid == 0 and Time.get_ticks_msec() < _target_until:
		tid = _target_id
	return tid


# ---- the core's events ---------------------------------------------------------------------------------------------------------------

func _on_enemy_spawned(id: int, _def: String, _level: int, elite: bool, _area: String, _affixes: int, _x: float, _z: float, _hp: float) -> void:
	if elite:
		_elite[id] = true


func _on_enemy_died(id: int, _def: String, _level: int, _elite_: bool, area: String, _source: int, _x: float, _z: float) -> void:
	_elite.erase(id)
	_kills[area] = int(_kills.get(area, 0)) + 1


## A thrall's blow on an enemy gets a number over the enemy (the old DmEventFx); the hero's own come from his caster's `hit_number`.
func _on_enemy_damaged(id: int, source: int, amount: float, _hp: float) -> void:
	if not _thrall.has(source) or not _may("thrall"):
		return
	var p := game.core_host.enemy_position(id)
	if p != Vector3.INF:
		_float(p + Vector3(0, 1.4, 0), str(int(amount)), "thrall")


## A Withered or other DoT lump: a small number over the burning enemy.
func _on_status_dot(id: int, _status: int, _source: int, _killed: bool, amount: float) -> void:
	if not _may("dot"):
		return
	var p := game.core_host.enemy_position(id)
	if p != Vector3.INF:
		_float(p + Vector3(0, 1.2, 0), str(int(amount)), "dot")


# ---- the hero ------------------------------------------------------------------------------------------------------------------------

func _on_hit_number(pos: Vector3, amount: float, crit: bool) -> void:
	float_text(Vector3(pos.x, 1.6, pos.z), str(DmMath.js_round(amount)), "crit" if crit else "hit")


func _on_hurt(amount: float, _source: Variant) -> void:
	var b := game.local_body()
	if b == null:
		return
	float_text(b.position + Vector3(0, 2.0, 0), "-%d" % DmMath.js_round(amount), "hurt")
	hud.hit_flash()


func _on_hero_effect(kind: StringName) -> void:
	var b := game.local_body()
	if kind == &"pull" and b != null:
		float_text(b.position + Vector3(0, 2.5, 0), "Dragged!", "info")


## The local hero got chilled / rooted / stunned: the old game's float, once per status as it appears.
func _on_hero_statuses(hs: DmStatusSet) -> void:
	var b := game.local_body()
	for id: StringName in HERO_STATUS_TEXT:
		var on := hs.has(id)
		if on and not _hero_status.has(id) and b != null:
			float_text(b.position + Vector3(0, 2.5, 0), String(HERO_STATUS_TEXT[id]), "info")
		if on:
			_hero_status[id] = true
		else:
			_hero_status.erase(id)


func _on_rejected(rite: String, reason: String) -> void:
	var def := DmAbilities.def(rite)
	match reason:
		"essence":
			_feedback(REJECT_TEXT["essence"])
		"souls":
			_feedback(REJECT_TEXT["souls"] % int(def.get("soulCost", 0)))
		"cooldown":
			_feedback(REJECT_TEXT["cooldown"] % def["name"])
		"locked":
			_feedback(REJECT_TEXT["locked"] % [def["name"], int(DmAbilities.unlock_level(rite))])


## The old game's cast feedback: one "info" float over the hero, at most every 600 ms.
func _feedback(text: String) -> void:
	var now := Time.get_ticks_msec()
	if now - _last_feedback < FEEDBACK_GAP_MS:
		return
	_last_feedback = now
	var b := game.local_body()
	if b != null:
		float_text(b.position + Vector3(0, 2.4, 0), text, "info")


## A moment the game announces: toasts and banners (the boss fx's, the level-ups, milestones, the summon refusals), floats over a world point (gold, Soul Harvest, the
## Kill Chain) and the pickup lines; chat lines and the counsel's events wait for the panels and the counsel.
func game_event(id: String, ctx: Dictionary) -> void:
	match id:
		"toast":
			hud.toast(String(ctx.get("text", "")), String(ctx.get("kind", "")))
		"banner":
			hud.banner(String(ctx.get("title", "")), String(ctx.get("sub", "")), int(ctx.get("ms", 3200)))
		"loot":
			hud.loot_toast(String(ctx.get("name", "")), int(ctx.get("qty", 1)), String(ctx.get("rarity", "common")))
		"float":
			if ctx.get("world") is Vector3:
				float_text(ctx["world"], String(ctx.get("text", "")), String(ctx.get("kind", "info")), ctx.get("color"))


## A hotbar press (a key or a click): the slot flashes, and the enemy it was aimed at is the target frame's for a few seconds.
func _on_hotbar(slot: int, _aim: Vector3, enemy_id: int) -> void:
	if enemy_id != 0:
		_target_id = enemy_id
		_target_until = Time.get_ticks_msec() + TARGET_HOLD_S * 1000.0
	hud.slot_flash(slot)


## A click on a hotbar slot: aims at the cursor like the key does.
func _on_cast(slot: int) -> void:
	var tid := game.input.hovered_enemy_id()
	var aim := game.enemy_position(tid) if tid != 0 else Vector3.INF
	_on_hotbar(slot, aim if aim != Vector3.INF else game.input.aim_point(), tid)
	DmRiteHotbar.cast(game, slot, aim if aim != Vector3.INF else game.input.aim_point(), tid)


func _on_navigate(x: float, z: float) -> void:
	game.input.click_move(Vector3(x, 0.0, z))


# ---- banners, toasts, floating numbers -------------------------------------------------------------------------------------------------

## The first time the hero enters an area: its banner (DmAreaFlow.enter).
func _on_area_changed(id: String) -> void:
	if _announced.has(id) or id == "depths":
		return
	_announced[id] = true
	var def: Dictionary = DmContent.area(id)
	hud.banner(String(def["name"]), String(def["subtitle"]), 3000)


## A themed wave is introduced once per area (repeats would cover combat with the banner).
func _on_procession(theme: Dictionary) -> void:
	var key := "procession:" + game.director.area_id
	if _announced.has(key):
		return
	_announced[key] = true
	hud.banner(String(theme["name"]), String(theme["blurb"]), 2600)


## True when a number of this kind may be shown now (the cap of DmFloatBudget); the budget counts it.
func _may(kind: String, now_ms: float = -1.0) -> bool:
	if not damage_numbers and kind in HIT_KINDS:
		return false
	return floats.allow(kind, now_ms if now_ms >= 0.0 else float(Time.get_ticks_msec()))


## A number or word over a world point, within the caps (14 hit / 5 dot / 6 thrall / 22 total live). `now_ms` is the clock the caps count in (tests pass theirs).
func float_text(pos: Vector3, text: String, kind: String = "info", color: Variant = null, now_ms: float = -1.0) -> void:
	if _may(kind, now_ms):
		_float(pos, text, kind, color)


func _float(pos: Vector3, text: String, kind: String, color: Variant = null) -> void:
	if game.camera == null or game.camera.is_position_behind(pos):
		return
	hud.float_text(game.camera.unproject_position(pos), text, kind, color if color is Color else Color(0, 0, 0, 0))
