class_name DmAscensionPanel
extends DmWindow
## The Altar of Ascension (archive/legacy-web:src/ui/AscensionPanel.ts): Vows (draft the curses for the next run), Ascend (burn a finished run for Ashes, asks twice),
## Covenant Boons (bought with Ashes; the strange ones are opened with soul shards first). Opening it never resets anything.
## Numbers come from rules/progression/ascension.gd (DmAscension), never retyped.
##
## Data in:  set_state(local: Dictionary)  -- the Progression `local` shape: {run:{prelateKills, peakWaveTier, kills}, shards, ashes,
##           ascension (best rank), unlocks: Array[String], boons: {id: rank}, vows: {id: steps}}. Call again after any change.
## Signals (and the DmApi call each maps to; the client also applies the same change to its local Progression):
##   vows_swear_requested(vows)   -> DmApi.necro_vows(character_id, vows)
##   ascend_confirmed             -> DmApi.necro_ascend(character_id)
##   boon_buy_requested(id)       -> DmApi.necro_boon(character_id, id)
##   unlock_requested(key)        -> DmApi.necro_unlock(character_id, key)   ("vow:<id>" / "boon:<id>")

signal vows_swear_requested(vows: Dictionary)
signal ascend_confirmed
signal boon_buy_requested(id: String)
signal unlock_requested(key: String)

const HEAT_RED := Color("e0a08a")
const BOON_GREEN := Color("9fd9b8")
const AMBER := Color("d9a441")
const VIOLET := Color("b58cff")

var local: Dictionary = {}
var draft: Dictionary = {}
var drafted := false
var confirming := false
## Filled by render(): handy for tests / the integrator's HUD.
var view: Dictionary = {}


func _init() -> void:
	super._init()
	title = "Altar of Ascension"
	panel_width = 900
	top_gap = 12
	max_height_margin = 110


func set_state(l: Dictionary) -> void:
	local = l
	if not drafted:
		draft = (l.get("vows", {}) as Dictionary).duplicate()
	render()


## Open a fresh session of the altar (resets the draft and the confirm step like the web `open()`).
func open_altar() -> void:
	confirming = false
	drafted = false
	draft = (local.get("vows", {}) as Dictionary).duplicate()
	render()
	open()


func _same(a: Dictionary, b: Dictionary) -> bool:
	for id in DmProgContent.vow_order():
		if DmAscension.vow_steps(a, id) != DmAscension.vow_steps(b, id):
			return false
	return true


var _built_sig := 0
var _built := false


func render() -> void:
	var sworn: Dictionary = local.get("vows", {})
	if not drafted:
		draft = sworn.duplicate()
	# Reopening the altar with nothing changed (the usual case) keeps what is drawn.
	var sig := [local, draft, drafted, confirming].hash()
	if _built and sig == _built_sig and body.get_child_count() > 0:
		return
	_built_sig = sig
	_built = true
	DmPa.clear(body)
	if local.is_empty():
		return
	var run: Dictionary = local.get("run", {"prelateKills": 0, "peakWaveTier": 0, "kills": 0})
	var unlocks: Variant = local.get("unlocks", [])
	var shards: int = int(local.get("shards", 0))
	var ashes: int = int(local.get("ashes", 0))
	var best: int = int(local.get("ascension", 0))
	var boons: Dictionary = local.get("boons", {})
	var draft_heat: int = DmAscension.vow_heat(draft)
	var sworn_heat: int = DmAscension.vow_heat(sworn)
	var changed: bool = not _same(draft, sworn)
	var ashes_now: int = DmAscension.ashes_for_run(run, sworn_heat)
	var asc: Dictionary = DmProgContent.ascension()
	var mult: float = 1.0 + float(asc["ashesPerHeat"]) * draft_heat
	var world_heat: int = DmAscension.vow_heat(DmAscension.world_vows(draft))
	var reward: int = int(DmMath.js_round((DmAscension.ascension_reward_mult(world_heat) - 1.0) * 100.0))
	var restart: bool = changed and (int(run.get("kills", 0)) > 0 or int(run.get("prelateKills", 0)) > 0 or int(run.get("peakWaveTier", 0)) > 0)
	view = {"draft_heat": draft_heat, "sworn_heat": sworn_heat, "changed": changed, "ashes_now": ashes_now, "mult": mult, "reward_pct": reward, "restart": restart}

	var root := DmPa.vbox(10)
	body.add_child(root)

	# --- head: best rank / this run's heat / ashes / shards
	var head := DmPa.grid(4, 8, 8)
	for spec in [["Best rank", ("Ascension " + DmAscension.roman(best)) if best > 0 else "None yet", "best"], ["This run's heat", str(sworn_heat), "heat"], ["Ashes", str(ashes), "ashes"], ["Soul shards", str(shards), "shards"]]:
		var c := DmPa.card(DmUi.BORDER, DmUi.INSET, Vector2(8, 6))
		var cb := DmPa.card_body(c)
		cb.add_theme_constant_override("separation", 0)
		cb.add_child(DmPa.kicker(spec[0]))
		var v := DmPa.text(spec[1], 17, DmUi.BONE_100, "display_bold", false)
		v.set_meta("stat", spec[2])
		cb.add_child(v)
		c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		head.add_child(c)
	root.add_child(head)

	# --- vows
	root.add_child(_h3("Vows", "choose how hard the next run is; seals never close again"))
	var vows := DmPa.grid(3, 8, 8)
	for id in DmProgContent.vow_order():
		vows.add_child(_vow_card(id, unlocks, shards))
	root.add_child(vows)

	# --- swear block
	root.add_child(_swear_block(draft_heat, mult, reward, changed, sworn_heat, restart))

	# --- this run
	root.add_child(_h3("This run", ""))
	var runrow := DmPa.flow(14, 4)
	var pays := str(ashes_now) if ashes_now > 0 else "-"
	for spec in [["Prelate slain", str(int(run.get("prelateKills", 0)))], ["Peak Wave Speed", str(int(run.get("peakWaveTier", 0)))], ["Dead laid to rest", str(int(run.get("kills", 0)))], ["Pays", pays + " Ashes"]]:
		var h := DmPa.hbox(4)
		h.add_child(DmPa.kicker(spec[0]))
		h.add_child(DmPa.num(spec[1], 13))
		runrow.add_child(h)
	root.add_child(runrow)
	root.add_child(_ascend_block(ashes_now, changed, sworn_heat, best))

	# --- boons
	root.add_child(_h3("Covenant Boons", "bought with Ashes; soul shards unlock the stranger ones"))
	var bg := DmPa.grid(3, 8, 8)
	for id in DmProgContent.boon_order():
		bg.add_child(_boon_card(id, unlocks, shards, ashes, best, boons))
	root.add_child(bg)


func _h3(t: String, small: String) -> Control:
	var h := DmPa.hbox(8)
	h.add_child(DmPa.text(t, 15, DmUi.BONE_300, "display", false))
	if small != "":
		var s := DmPa.text(small, 12, DmUi.TEXT_MUTED, "body", false)
		s.size_flags_vertical = Control.SIZE_SHRINK_END
		h.add_child(s)
	return DmPa.margin(h, 0, 6, 0, 0)


func _vow_card(id: String, unlocks: Variant, shards: int) -> Control:
	var def: Dictionary = DmProgContent.vows()[id]
	var key := DmAscension.vow_key(id)
	var opened := DmAscension.is_unlocked(unlocks, key)
	var n: int = DmAscension.vow_steps(draft, id)
	var max_rank: int = int(def["maxRank"])
	var heat: int = int(def["heat"])
	var step_word := " per step" if max_rank > 1 else ""
	var is_sworn := opened and n > 0
	var c := DmPa.card(VIOLET if is_sworn else DmUi.BORDER, DmUi.INSET.lerp(VIOLET, 0.10) if is_sworn else DmUi.INSET, Vector2(8, 6))
	c.set_meta("vow", id)
	c.set_meta("sworn", is_sworn)
	c.set_meta("locked", not opened)
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if not opened:
		c.modulate = Color(1, 1, 1, 0.85)
	var cb := DmPa.card_body(c)
	cb.add_theme_constant_override("separation", 4)
	var top := DmPa.hbox(6)
	top.add_child(_grow(DmPa.text(String(def["name"]), 14, DmUi.BONE_100, "body_bold", false)))
	var heat_txt := "+%d heat%s" % [heat * n, ""] if n > 0 and opened else "+%d heat%s" % [heat, step_word]
	var hl := DmPa.text(DmUi.upper(heat_txt), 11, HEAT_RED, "body", false)
	hl.set_meta("role", "heat")
	top.add_child(hl)
	cb.add_child(top)
	var blurb: String = String(def["blurb"])
	if opened and String(def.get("scope", "")) == "self":
		blurb += " (only you)"
	var bl := DmPa.text(blurb, 12, DmUi.TEXT_MUTED)
	bl.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cb.add_child(bl)
	if not opened:
		var unlock_shards: int = int(def["unlockShards"])
		var can := shards >= unlock_shards
		var b := DmPa.button("Unlock · %d shards" % unlock_shards, "small", not can, "unlock", key)
		b.tooltip_text = "Spend soul shards to open this" if can else "You have %d soul shards" % shards
		b.pressed.connect(func() -> void: unlock_requested.emit(key))
		cb.add_child(b)
	elif max_rank == 1:
		var b := DmPa.button("Sworn" if n > 0 else "Swear", "small_primary" if n > 0 else "small", false, "vow", id)
		b.set_meta("to", 0 if n > 0 else 1)
		b.pressed.connect(_set_vow.bind(id, 0 if n > 0 else 1))
		cb.add_child(b)
	else:
		var st := DmPa.hbox(8)
		var minus := DmPa.button("−", "small", n <= 0, "vow", id)
		minus.text = "−"
		minus.set_meta("to", n - 1)
		minus.tooltip_text = "Fewer steps of %s" % def["name"]
		minus.pressed.connect(_set_vow.bind(id, n - 1))
		st.add_child(minus)
		var lab := DmPa.text("%d / %d" % [n, max_rank], 13, DmUi.BONE_100, "numeric", false)
		lab.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lab.custom_minimum_size.x = 54
		lab.set_meta("role", "steps")
		st.add_child(lab)
		var plus := DmPa.button("+", "small", n >= max_rank, "vow", id)
		plus.text = "+"
		plus.set_meta("to", n + 1)
		plus.tooltip_text = "More steps of %s" % def["name"]
		plus.pressed.connect(_set_vow.bind(id, n + 1))
		st.add_child(plus)
		cb.add_child(st)
	return c


func _grow(c: Control) -> Control:
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return c


func _set_vow(id: String, to: int) -> void:
	var max_rank: int = int(DmProgContent.vows()[id]["maxRank"])
	var t: int = clampi(to, 0, max_rank)
	var next := draft.duplicate()
	if t > 0:
		next[id] = t
	else:
		next.erase(id)
	draft = next
	drafted = true
	render()


func _swear_block(draft_heat: int, mult: float, reward: int, changed: bool, sworn_heat: int, restart: bool) -> Control:
	var c := DmPa.card(VIOLET, DmUi.PANEL.lerp(VIOLET, 0.14), Vector2(10, 8))
	var cb := DmPa.card_body(c)
	cb.add_theme_constant_override("separation", 8)
	var sum := DmPa.flow(14, 2)
	for spec in [["Heat", str(draft_heat), "draft_heat"], ["Ashes", "×%.1f" % mult, "mult"], ["Gold & XP", "+%d%%" % reward, "reward"]]:
		var h := DmPa.hbox(6)
		h.add_child(DmPa.kicker(spec[0]))
		var v := DmPa.text(spec[1], 18, DmUi.BONE_100, "display_bold", false)
		v.set_meta("stat", spec[2])
		h.add_child(v)
		sum.add_child(h)
	cb.add_child(sum)
	var row := DmPa.hbox(8)
	var label := "Swear these vows" if changed else ("Vows sworn" if sworn_heat > 0 else "No vows sworn")
	var sw := DmPa.button(label, "primary", not changed, "swear")
	sw.pressed.connect(func() -> void:
		drafted = false
		var out := draft.duplicate()
		vows_swear_requested.emit(out)
		render())
	row.add_child(sw)
	var clr := DmPa.button("Clear all", "", draft_heat <= 0, "clear")
	clr.pressed.connect(func() -> void:
		draft = {}
		drafted = true
		render())
	row.add_child(clr)
	cb.add_child(row)
	if restart:
		var w := DmPa.text("This run already has kills on the tally. Changing vows restarts the run's tally (kills and any Prelate kill), so its Ashes match the heat it was fought at. Tiers, seals and shards stay.", 13, HEAT_RED)
		w.set_meta("role", "restart_warning")
		cb.add_child(w)
	return c


func _ascend_block(ashes_now: int, changed: bool, sworn_heat: int, best: int) -> Control:
	if confirming:
		var c := DmPa.card(AMBER, DmUi.PANEL.lerp(AMBER, 0.08), Vector2(10, 8))
		var cb := DmPa.card_body(c)
		var msg := "<b>Burn this run?</b> You gain <b>%d Ashes</b> for %d heat" % [ashes_now, sworn_heat]
		if sworn_heat > best:
			msg += " and a new best rank, <b>Ascension %s</b>" % DmAscension.roman(sworn_heat)
		msg += "."
		cb.add_child(DmPa.rich(msg, 14, DmUi.TEXT))
		var lose := DmPa.text("•  Resets: Damage, Wave Speed and Legion tiers, and this run's tally.", 13, Color("e0a08a"))
		var keep := DmPa.text("•  Keeps: opened seals and kill counts, soul shards, level, experience, gold, relics, your Ashes, Boons and sworn vows.", 13, BOON_GREEN)
		cb.add_child(lose)
		cb.add_child(keep)
		var row := DmPa.hbox(8)
		var ok := DmPa.button("Ascend", "primary", false, "confirm")
		ok.pressed.connect(func() -> void:
			confirming = false
			ascend_confirmed.emit())
		row.add_child(ok)
		var no := DmPa.button("Not yet", "", false, "cancel")
		no.pressed.connect(func() -> void:
			confirming = false
			render())
		row.add_child(no)
		cb.add_child(row)
		return c
	var label: String
	if ashes_now <= 0:
		label = "Slay the Prelate this run to Ascend"
	elif changed:
		label = "Swear or undo your vow changes first"
	else:
		label = "Ascend: %d Ashes" % ashes_now
	var b := DmPa.button(label, "primary", not (ashes_now > 0 and not changed), "ascend")
	b.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	b.pressed.connect(func() -> void:
		confirming = true
		render())
	return b


## The boon button label: "Mastered", a reason (e.g. "Ascension III"), or "<cost> Ashes" (Progression.boonProblem).
static func boon_problem(id: String, boons: Dictionary, best: int, unlocks: Variant, ashes: int) -> String:
	var blocked := DmAscension.boon_blocked(id, boons, best, unlocks)
	if blocked != "":
		return blocked
	var cost := DmAscension.boon_cost(id, boons)
	return "Needs %d Ashes" % cost if ashes < cost else ""


func _boon_card(id: String, unlocks: Variant, shards: int, ashes: int, best: int, boons: Dictionary) -> Control:
	var def: Dictionary = DmProgContent.boons()[id]
	var owned: int = int(boons.get(id, 0))
	var key := DmAscension.boon_key(id)
	var opened := DmAscension.is_unlocked(unlocks, key)
	var max_rank: int = int(def["maxRank"])
	var c := DmPa.card(AMBER if (owned > 0 and opened) else DmUi.BORDER, DmUi.INSET, Vector2(8, 6))
	c.set_meta("boon", id)
	c.set_meta("owned", owned)
	c.set_meta("locked", not opened)
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if not opened:
		c.modulate = Color(1, 1, 1, 0.85)
	var cb := DmPa.card_body(c)
	cb.add_theme_constant_override("separation", 4)
	var top := DmPa.hbox(6)
	top.add_child(_grow(DmPa.text(String(def["name"]), 14, DmUi.BONE_100, "body_bold", false)))
	if not opened or bool(def.get("shape", false)):
		top.add_child(DmPa.text(DmUi.upper("changes how you play"), 11, BOON_GREEN, "body", false))
	if opened:
		var pips := DmPa.hbox(5)
		pips.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		for i in max_rank:
			var p := DmPaPip.new()
			p.on = i < owned
			pips.add_child(p)
		top.add_child(pips)
	cb.add_child(top)
	var bl := DmPa.text(String(def["blurb"]), 12, DmUi.TEXT_MUTED)
	bl.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cb.add_child(bl)
	if not opened:
		var us: int = int(def["unlockShards"])
		var can := shards >= us
		var b := DmPa.button("Unlock · %d shards" % us, "small", not can, "unlock", key)
		b.tooltip_text = "Spend soul shards to open this" if can else "You have %d soul shards" % shards
		b.pressed.connect(func() -> void: unlock_requested.emit(key))
		cb.add_child(b)
		return c
	var problem := boon_problem(id, boons, best, unlocks, ashes)
	var cost := DmAscension.boon_cost(id, boons)
	var label: String
	if cost < 0:
		label = "Mastered"
	elif problem != "" and not problem.begins_with("Needs"):
		label = problem
	else:
		label = "%d Ashes" % cost
	var bb := DmPa.button(label, "small", problem != "", "boon", id)
	bb.pressed.connect(func() -> void: boon_buy_requested.emit(id))
	cb.add_child(bb)
	return c
