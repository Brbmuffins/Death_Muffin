class_name DmNextMeta
extends Node
## Host-side meta systems of the slice (child "Meta" of DmNextGame): difficulty, the sworn world vows, the week's Omen, Soul Harvest, the Kill Chain's
## presentation, the Bonded Dead boon. It owns no rules (DmContent.difficulty, DmAscension / DmVowsBoons, DmPlayerRules souls, DmKillChain are shared
## rules): it reads the character's progression and pushes the results to the nodes that act on them.
##
##   difficulty  -> director (enemy hp / damage / elite chance), rewards (xp / gold / loot), bosses (brains)
##   world vows  -> director (levels, hp, wave size, deacon weight, elites), bosses (levels, echoes), corpse field (life), rewards (heat -> xp / gold)
##   omen        -> director (wave size, elites), every rewards member (reward / shard multipliers); the HUD chip
##   souls, chain, bonded dead: see below. `event(id, ctx)` is the game_event shape (DmNextUiHost forwards it to DmGameUi).

signal event(id: String, ctx: Dictionary)

const SOUL_HOVER_S := 1.0                ## s a Reaper's soul wisps around its dead enemy before flying to her
const BOND_DELAY := 1.5                 ## s after entering a hunting ground
const CHAIN_COLORS := [0xe6d3a0, 0xf0b25a, 0xf08a3a, 0xee5a2a, 0xff3a3a]

var shell: DmNextGame
var member: DmRewardsMember              ## the host's rewards member (its Kill Chain)
var difficulty := "medium"
var omen: Dictionary = {}                ## the week's Omen (DmContent omens), or opts.omen
var vow_fx: Dictionary = {}              ## DmVowsBoons.vow_effects of the sworn WORLD vows (the player-scope ones reach the hero through DmCharacterBuild)
var heat := 0                            ## the world vows' heat: the run's rank (xp / gold multiplier, kill reports)

var _soul_fx: DmRiteFx = null            ## draws the Reaper's soul wisps (made on the first one)
var _synced := false
var _vow_sig := ""
var _bond_t := 0.0
var _chain_told := false


## The weekly Omen of a clock (ms since the Unix epoch): week 0 starts on a Monday.
static func omen_for(ms: float) -> Dictionary:
	var order: Array = DmContent.get_export("omens", "OMEN_ORDER")
	var week_ms := 7.0 * 24.0 * 3600.0 * 1000.0
	var epoch := 4.0 * 24.0 * 3600.0 * 1000.0
	var w := int(floor((ms - epoch) / week_ms))
	return DmContent.get_export("omens", "OMENS")[order[((w % order.size()) + order.size()) % order.size()]]


## Host, after the rewards exist (before the progression loads: DmNextProgress.apply_progress calls sync()).
func attach(shell_: DmNextGame) -> void:
	shell = shell_
	member = shell.rewards.members.get(int(shell.character.get("id", 0)))
	var o: Variant = shell.opts.get("omen")   # tests pin the week
	omen = o if o is Dictionary else omen_for(Time.get_unix_time_from_system() * 1000.0)
	set_difficulty(String(shell.opts.get("difficulty", "medium")), true)
	shell.rewards.killer_paid.connect(_on_killer_paid)
	shell.rewards.kill_earned.connect(_on_kill_earned)
	shell.rewards.chain_tier_up.connect(_on_chain_tier)
	shell.hero_died.connect(func(_b: DmHeroBody) -> void: member.chain.reset())
	shell.area_changed.connect(func(_id: String) -> void: _bond_t = BOND_DELAY)
	shell.session.player_joined.connect(func(_id: int) -> void: _apply_members.call_deferred())
	_apply_members()
	set_process(true)


## Settings -> difficulty (and `opts.difficulty`): the next enemies to rise feel it. `quiet` = no toast.
func set_difficulty(d: String, quiet: bool = false) -> void:
	if not DmContent.difficulties().has(d) or d == difficulty and _synced:
		return
	var was := difficulty
	difficulty = d
	shell.director.difficulty = d
	shell.rewards.difficulty = d
	shell.bosses.difficulty = d
	if not quiet and was != d:
		event.emit("toast", {"text": "Difficulty: %s — the next dead to rise feel it" % String(DmContent.difficulty(d)["name"]), "kind": "good"})


## The character's vows / boons changed (loaded, bought, sworn, an ascension): the world follows. Called by DmNextProgress.apply_progress.
func sync() -> void:
	var prog: DmProgression = shell.progress.prog
	var world := DmAscension.world_vows(prog.vows())
	var sig := JSON.stringify(world)
	vow_fx = DmVowsBoons.vow_effects(world)
	heat = DmVowsBoons.vow_heat(world)
	var d := shell.director
	d.vow_fx = vow_fx
	d.size_extra = float(omen.get("waveSizeMult", 1.0)) * float(vow_fx["waveSizeMult"])
	d.omen = omen
	d.set_wave_tier(d.wave_tier)   # the wave size follows the multipliers
	shell.bosses.vow_fx = vow_fx
	shell.rewards.ascension = float(heat)
	shell.rewards.vow_levels = float(vow_fx["levels"])
	shell.corpses.life_mult = float(prog.boons()["corpseLifeMult"]) * float(vow_fx["corpseLifeMult"])
	_apply_members()
	if _synced and sig != _vow_sig:
		d.clear()   # new vows: the hunting grounds start over (every area is cleared)
	_vow_sig = sig
	_synced = true


func _apply_members() -> void:
	for m: DmRewardsMember in shell.rewards.members.values():
		m.omen_reward = float(omen.get("rewardMult", 1.0))
		m.omen_shard = float(omen.get("shardMult", 1.0))


func _process(_dt: float) -> void:
	var b := shell.local_body()
	if b == null:
		return
	var broke := member.chain.tick(shell.rewards.clock_ms())
	if broke >= int(DmProgContent.get_data()["chain"]["reportAt"]):
		shell.progress.sfx("chainBreak")
		_float(b, 2.6, "Chain broken: %d" % broke, "info")
	if _bond_t > 0.0:
		_bond_t -= _dt
		if _bond_t <= 0.0:
			_bonded_dead(b)


# ---- Kill Chain -----------------------------------------------------------------------------------------------------------------------

func _on_chain_tier(cid: int, tier: Dictionary) -> void:
	var b := shell.local_body()
	if cid != member.character_id or b == null:
		return
	var tiers: Array = DmProgContent.get_data()["chain"]["tiers"]
	var idx := maxi(0, tiers.find(tier))
	shell.progress.sfx("chainTier")
	_float(b, 3.0, "%s  +%d%%" % [String(tier["name"]).to_upper(), DmMath.js_round(float(tier["bonus"]) * 100.0)], "big")
	var vfx := get_node_or_null("/root/Vfx")
	if vfx != null and shell._visual:
		var col: int = CHAIN_COLORS[idx]
		vfx.emit({"x": b.position.x, "y": 1.0, "z": b.position.z, "count": 20 + idx * 8, "color": col, "spread": 0.5, "speed": 3.0 + idx * 0.6, "up": 2.4, "life": 0.8, "size": 0.16, "gravity": 3.0})
		vfx.decal({"tex": "ring", "color": col, "x": b.position.x, "z": b.position.z, "r": 2.0 + idx * 0.5, "duration": 0.5, "opacity": 0.9, "growFrom": 0.3})
	if idx >= 2:
		shell.camera.shake(0.08 + idx * 0.02)
	if not _chain_told:
		_chain_told = true
		event.emit("chain_started", {})


# ---- Soul Harvest ---------------------------------------------------------------------------------------------------------------------

## Your own kill banks a soul; the kill that fills the meter charges the next Marrow Spear / Miasma / Black Litany (free, 1.5x), see DmRiteCaster.
## Every member's hero banks on the host (a joiner's meter reaches its HUD through its caster's state); the announcement is the host hero's.
func _on_killer_paid(cid: int, _def: String, enemy: Node) -> void:
	var m: DmRewardsMember = shell.rewards.members.get(cid)
	if m == null or not is_instance_valid(m.body):
		return
	var b := m.body as DmHeroBody
	if b == null or b.p.is_empty() or b.family == "reaper":   # the Reaper's souls come from every kill she is paid for (_on_kill_earned)
		return
	var souls := 1.0
	var caster := b.get_node_or_null("Rites") as DmRiteCaster
	if caster != null and enemy != null:   # the Scythe's reap window: a kill of a victim of its arc banks one more soul
		souls += (DmRiteRegistry.module("bone_needle") as DmRiteModule).call(&"reaped_souls", caster, enemy)
	if not DmPlayerRules.add_souls(b.p, souls) or b != shell.local_body():
		return
	event.emit("souls_charged", {})
	_float(b, 2.6, "Soul Harvest", "info")
	event.emit("toast", {"text": "Soul Harvest — your next Marrow Spear, Miasma or Black Litany is free and 50% larger", "kind": "good"})
	shell.progress.sfx("shard")
	var vfx := get_node_or_null("/root/Vfx")
	if vfx != null and shell._visual:
		var jade: int = int(DmContent.spell_fx()["souls"]["jade"])
		vfx.emit({"x": b.position.x, "y": 0.3, "z": b.position.z, "count": 50, "color": jade, "spread": 1.2, "speed": 1.4, "up": 3.0, "life": 1.0, "size": 0.3, "inward": true})
		vfx.light_flash(Vector3(b.position.x, 1.5, b.position.z), Color.hex(jade * 256 + 255), 30.0, 0.6)


## Every enemy that dies for a Reaper (her blow, a friend's, a curse: anything that pays her the kill) gives her one soul.
func _on_kill_earned(cid: int, _def: String, at: Vector3) -> void:
	var m: DmRewardsMember = shell.rewards.members.get(cid)
	var b := m.body as DmHeroBody if m != null else null
	if b != null and b.family == "reaper":
		_bank_reaper_soul(b, at)


## The Reaper's soul bag: the soul is banked at once (until the bag is full); its wisp loops round the dead enemy for a second, then flies to her.
func _bank_reaper_soul(b: DmHeroBody, at: Vector3) -> void:
	if b.p.is_empty() or not b.alive or DmPlayerRules.bag_add(b.p, 1) == 0:
		return
	var vfx := get_node_or_null("/root/Vfx")
	if vfx == null or not shell._visual:
		return
	if _soul_fx == null:
		_soul_fx = DmRiteFx.with_autoloads()
	var bw: WeakRef = weakref(b)   # a WeakRef, not the body: a lambda capturing a freed Object logs an engine error on every call
	var from := Vector3(at.x, 0.9, at.z)
	_soul_fx.emit(at.x, 0.9, at.z, 8, DmReaperRites.GREEN, 0.5, 1.2, 1.6, 0.7, 0.2, {"gravity": -0.4})   # the soul slips out of the body
	_soul_fx.shot(from, func() -> Variant:
		var hero: Node3D = bw.get_ref() as Node3D
		return Vector3(hero.global_position.x, 1.2, hero.global_position.z) if hero != null else null,
		9.0, 0.0, "sprite", DmReaperRites.GREEN, {"tex": "skull", "size": 0.7, "hover": SOUL_HOVER_S, "hover_r": 1.0,
			"on_arrive": func(pos: Vector3) -> void: _soul_fx.emit(pos.x, pos.y, pos.z, 6, DmReaperRites.GREEN, 0.25, 1.4, 0.8, 0.4, 0.18)})


# ---- Bonded Dead ----------------------------------------------------------------------------------------------------------------------

## A thrall rises beside you whenever you enter a hunting ground with none (the boon; necromancers only).
func _bonded_dead(b: DmHeroBody) -> void:
	var th := b.get_node_or_null("Thralls") as DmThrallHost
	var def := DmContent.area(shell.area_id)
	if th == null or not b.alive or b.family != "necromancer" or th.count() > 0 or bool(def["safe"]) or shell.area_id == "depths" \
			or not bool(shell.progress.prog.boons()["bondedDead"]):
		return
	var m := b.mods
	var r := th.raise_bonded({"kind": m["thrallKind"], "cap": m["thrallCap"], "hp": b.p["stats"]["thrallHp"], "damage": b.p["stats"]["thrallDamage"],
		"attackSpeedMult": m["thrallAttackSpeedMult"]})
	if bool(r["ok"]):
		event.emit("toast", {"text": "Your bonded dead rises beside you", "kind": "good"})


func _float(b: Node3D, y: float, text: String, kind: String) -> void:
	event.emit("float", {"world": b.position + Vector3(0.0, y, 0.0), "text": text, "kind": kind})
