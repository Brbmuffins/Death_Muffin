class_name DmNextBelt
extends RefCounted
## The slice's belt on the host's body: Q drinks a healing flask (with the 1.5 s sip cooldown), Z / X drink the elixir / tonic on the belt,
## meals heal over time. The HUD rows are DmGameHud.brews.
## Brew state lives on the body (ward, speed) and its caster (damage, haste, essence): both are fed by `drink_buff`.
## A party guest's belt (`remote_use` set, DmNextUiHost): the guest's own bag pays (its server-backed DmInventory), the HOST applies the effect to the
## guest's hero (DmNextParty.guest_use: heal, brew, meal), and the guest keeps its own copy of its brews (`guest_brews`) for the chips and texts.

var body: DmHeroBody
var inventory: DmInventory
var prog: DmProgression
var belt: Dictionary = {"heal": "", "elixir": "", "tonic": ""}   ## the picked flask / brew per slot ("" = whichever the bag holds)
var flask_cd_until: float = 0.0                      ## body clock ms
var meal_until: float = 0.0
var meal_rate: float = 0.0                           ## hp per second
var say: Callable = Callable()                       ## (text, kind, height) -> a float over the hero
var sfx: Callable = Callable()                       ## (sound name)
var toast: Callable = Callable()                     ## (text)
var remote_use: Callable = Callable()                ## (item id) a party guest: the host applies what was drunk; empty = this body is simulated here
var guest_brews: Dictionary = {}                     ## a guest's own record of its brews (DmBrews.apply_brew shape); the host holds the real ones


func _now() -> float:
	return float(Time.get_ticks_msec()) if remote_use.is_valid() else body.clock_ms()


## The brews in force on the hero: the body's (host), or the guest's own record of them.
func _brews_state() -> Dictionary:
	if remote_use.is_valid():
		return guest_brews
	return body.p["brews"] if body != null and not body.p.is_empty() else {}


func _say(text: String, kind: String, y: float) -> void:
	if say.is_valid():
		say.call(text, kind, y)


func _ready_to_drink() -> bool:
	return body != null and is_instance_valid(body) and body.alive and inventory != null


## UI -> game: which brew a belt slot holds (the UI keeps the pick in its store).
func set_belt(slot: String, id: String) -> void:
	if slot in ["heal", "elixir", "tonic"]:
		belt[slot] = id


func load_pick(raw: Dictionary) -> void:
	var heal: Variant = raw.get("heal")
	belt["heal"] = heal if (heal is String and DmContent.healing_flasks().has(heal)) else ""
	for slot in ["elixir", "tonic"]:
		var id: Variant = raw.get(slot)
		belt[slot] = id if (id is String and DmContent.brews().has(id) and DmContent.brews()[id]["slot"] == slot) else ""


## The flask Q drinks: the pick while the bag holds it, else the best flask the bag holds.
func heal_id() -> String:
	var pick: String = belt["heal"]
	if pick != "" and _count(pick) > 0:
		return pick
	return DmPotionBelt.heal_pick(_count)


## The brew a slot would drink: the pick if the bag holds it, else any brew of the slot the bag holds.
func belt_brew(slot: String) -> String:
	var pick: String = belt[slot]
	if pick != "" and _count(pick) > 0:
		return pick
	var all: Dictionary = DmContent.brews()
	for id in all:
		if all[id]["slot"] == slot and _count(id) > 0:
			return id
	return ""


var _heal_tip := ""   ## the Heal slot sentence, rebuilt only when the flask, the count or the vow changes
var _heal_tip_ok := false
var _tip_hid := ""
var _tip_total := -1
var _tip_dry := false
var _brew_tips := {}   ## "<id>|<active>" -> tip sentence


func _brew_tip(id: String, def: Dictionary, active: bool) -> String:
	var k := id + ("|1" if active else "|0")
	var t: Variant = _brew_tips.get(k)
	if t == null:
		t = "%s: %s · %ds" % [def["label"], "active" if active else "on your belt", int(def["seconds"])]
		_brew_tips[k] = t
	return t


func empty_hint(slot: String) -> String:
	if slot == "heal":
		return "Healing: no potions yet. Brew Moss Tonic from Mourning Moss in the Alchemist's Wing (east door of the Chapterhouse), or loot them from the dead. Press Q to drink one."
	var kind := "elixir" if slot == "elixir" else "tonic"
	return "Empty %s slot. Click it to pick %s %s from your bag, or drag one here from the Reliquary. Press %s to drink it." % [kind, "an" if slot == "elixir" else "a", kind, "Z" if slot == "elixir" else "X"]


## Z / X.
func drink_belt(slot: String) -> void:
	if not _ready_to_drink():
		return
	var id := belt_brew(slot)
	if id == "":
		_say("Empty %s slot" % slot, "info", 2.4)
		if toast.is_valid():
			toast.call(empty_hint(slot))
		return
	drink_buff(id)


## Any consumable by id (the Reliquary's Drink, the HUD): a meal, a brew or a flask.
func use(id: String) -> void:
	if DmBrews.meal(id) != null:
		eat_meal(id)
	elif DmContent.brews().has(id):
		drink_buff(id)
	else:
		drink_flask(id)


func drink_buff(id: String) -> void:
	var b: Variant = DmContent.brews().get(id)
	if b == null or not _ready_to_drink() or inventory.count(id) <= 0:
		return
	var before: Variant = _brews_state().get(b["slot"])
	var prev: Variant = DmContent.brews().get(before["id"]) if (before != null and _now() < float(before["until"])) else null
	if not inventory.consume(id):
		return
	var r: Dictionary
	if remote_use.is_valid():
		r = DmBrews.apply_brew(guest_brews, id, _now())
		remote_use.call(id)
	else:
		r = body.apply_brew(id)
		var rites := body.get_node_or_null("Rites") as DmRiteCaster
		if rites != null and not rites.shares_vitals():   # a caster on the body's vitals already sees the brew
			rites.apply_brew(id)
	var text: String
	if r["replaced"] and prev != null:
		text = "%s replaces %s" % [b["label"], prev["label"]]
	elif r["extended"]:
		text = "%s extended · %ds" % [b["label"], DmMath.js_round((float(r["until"]) - _now()) / 1000.0)]
	else:
		text = "%s · %ds" % [b["label"], int(b["seconds"])]
	_say(text, "gold", 2.2)
	if sfx.is_valid():
		sfx.call("drinkElixir")


func eat_meal(id: String) -> void:
	var meal: Variant = DmBrews.meal(id)
	if meal == null or not _ready_to_drink():
		return
	if _now() < meal_until:
		_say("Still eating", "info", 2.4)
		return
	if not inventory.consume(id):
		return
	meal_until = _now() + float(meal["seconds"]) * 1000.0
	meal_rate = (body.max_hp * float(meal["healFrac"])) / float(meal["seconds"])
	if remote_use.is_valid():
		remote_use.call(id)   # the host heals the hero over the meal's seconds
	_say("Well fed · +%d%% over %ds" % [DmMath.js_round(float(meal["healFrac"]) * 100.0), int(meal["seconds"])], "gold", 2.2)
	if sfx.is_valid():
		sfx.call("eatMeal")


## Q (or a named flask). The sip cooldown is silent, like the old game.
func drink_flask(prefer: String = "") -> void:
	if not _ready_to_drink() or _now() < flask_cd_until:
		return
	if prog != null and bool(prog.vow_fx().get("noFlasks", false)):
		_say("Dry Cellar", "info", 2.4)
		if toast.is_valid():
			toast.call("Your Dry Cellar vow forbids healing flasks. Brews and meals still work.")
		return
	var flasks: Dictionary = DmContent.healing_flasks()
	var id := prefer if (prefer != "" and flasks.has(prefer)) else heal_id()
	if id == "" or not inventory.consume(id):
		_say("No healing potions", "info", 2.4)
		if toast.is_valid():
			toast.call(empty_hint("heal"))
		return
	flask_cd_until = _now() + DmBrews.heal_cooldown_ms()
	var amount: float = body.max_hp * float(flasks[id])
	if remote_use.is_valid():
		remote_use.call(id)
	else:
		body.heal(amount)
	_say("+%d" % DmMath.js_round(amount), "heal", 2.2)
	if sfx.is_valid():
		sfx.call("drinkFlask")


## Host, every physics frame (cheap: one compare while no meal runs).
func tick(dt: float) -> void:
	if meal_until > 0.0 and body != null and body.alive and not remote_use.is_valid():
		if _now() < meal_until:
			body.heal(meal_rate * dt)
		else:
			meal_until = 0.0


var _cnt := {}   ## the bag's counts of the flasks and brews, made in ONE pass (every `inventory.count` is a pass of its own, and a refresh made about thirty)
var _counting := false
var _d_slots: Array = []      ## the bag that the numbers below were made from: compared by identity (the bag is replaced, never edited, when it changes) ...
var _d_picks: Array = []      ## ... and the picks they were made with
var _d_hid := ""              ## the flask Q would drink, how many flasks are carried, the brew each slot would drink and how many of it
var _d_total := 0
var _d_brew: Array[String] = ["", ""]
var _d_n: Array[int] = [0, 0]
var _vows_seen: Dictionary = {}   ## the vows the Dry Cellar answer below was read for (a copy)
var _dry_ok := false
var _dry := false
var _empty_hints := {}


## The bag's count of `id`: from the one pass while it runs, else asked of the bag.
func _count(id: String) -> int:
	if _counting:
		var c: Variant = _cnt.get(id)
		if c != null:
			return c
	return inventory.count(id)


func _count_once() -> void:
	_cnt.clear()
	for id in DmContent.healing_flasks():
		_cnt[id] = 0
	for id in DmContent.brews():
		_cnt[id] = 0
	for s in inventory.slots:
		var id: String = s["item_id"]
		if _cnt.has(id):
			_cnt[id] += int(s["quantity"])
	_counting = true


## What the bag and the picks decide (the flask, the brews, how many of each), made again only when the bag was replaced or a pick changed: the chips are asked
## about twenty times a second and the bag changes a few times a minute.
func _derive() -> void:
	var picks := [belt["heal"], belt["elixir"], belt["tonic"]]
	if is_same(inventory.slots, _d_slots) and picks == _d_picks:
		return
	_count_once()
	_d_hid = heal_id()
	_d_total = 0
	for f in DmContent.healing_flasks():
		_d_total += _count(f)
	for i in 2:
		var id := belt_brew("elixir" if i == 0 else "tonic")
		_d_brew[i] = id
		_d_n[i] = _count(id) if id != "" else 0
	_counting = false
	_d_slots = inventory.slots
	_d_picks = picks


## Whether the Dry Cellar vow forbids flasks, read again only when the vows change.
func _dry_cellar() -> bool:
	if prog == null:
		return false
	var v: Dictionary = prog.vows()
	if not _dry_ok or v != _vows_seen:
		_vows_seen = v.duplicate(true)
		_dry = bool(prog.vow_fx().get("noFlasks", false))
		_dry_ok = true
	return _dry


func _empty(slot: String) -> String:
	var t: Variant = _empty_hints.get(slot)
	if t == null:
		t = empty_hint(slot)
		_empty_hints[slot] = t
	return t


## The HUD's three chips (DmGameHud.brews).
func rows() -> Array:
	_derive()
	var now := _now()
	var flasks: Dictionary = DmContent.healing_flasks()
	var hid := _d_hid
	var total := _d_total
	var cd_left := maxf(0.0, flask_cd_until - now)
	var cd_total := DmBrews.heal_cooldown_ms()
	var dry := _dry_cellar()
	var tip := ""
	if _heal_tip_ok and hid == _tip_hid and total == _tip_total and dry == _tip_dry:
		tip = _heal_tip   # the sentence changes with the pick, the count or the vow, not per refresh
	elif dry:
		tip = "Dry Cellar: your vow forbids healing flasks. Break it at the Altar of Ascension."
	elif hid != "":
		tip = "Healing: %s restores %d%% of your health (%d carried). Press Q to drink; sips are %ds apart." % [DmContent.item(hid)["name"], DmMath.js_round(float(flasks[hid]) * 100.0), total, int(cd_total / 1000.0)]
	else:
		tip = _empty("heal")
	if tip != _heal_tip:
		_heal_tip = tip
		_heal_tip_ok = true
		_tip_hid = hid
		_tip_total = total
		_tip_dry = dry
	var out: Array = [{"slot": "heal", "key": "Q", "label": "Heal", "glyph": "✚", "item_id": hid, "color": 0xe0709c, "active": false, "left": 0,
		"frac": (cd_left / cd_total) if (cd_left > 0.0 and hid != "") else 0.0, "count": total, "empty": hid == "", "tip": tip}]
	var brews: Dictionary = DmContent.brews()
	var keys: Dictionary = DmContent.get_export("brews", "BREW_KEYS")
	for bi in 2:
		var slot := "elixir" if bi == 0 else "tonic"
		var act: Variant = _brews_state().get(slot)
		var live: Variant = act if (act != null and now < float(act["until"])) else null
		var belt_id := _d_brew[bi]
		var shown: String = String(live["id"]) if live != null else belt_id
		var key := String(keys[slot]).to_upper()
		if shown == "":
			out.append({"slot": slot, "key": key, "label": "Elixir" if slot == "elixir" else "Tonic", "glyph": "⚗" if slot == "elixir" else "✧", "color": 0x8a8aa0,
				"active": false, "left": 0, "frac": 0.0, "count": 0, "empty": true, "tip": _empty(slot)})
			continue
		var def: Dictionary = brews[shown]
		out.append({"slot": slot, "key": key, "label": def["label"], "glyph": def["glyph"], "item_id": shown, "color": def["color"], "active": live != null,
			"left": int(ceil((float(live["until"]) - now) / 1000.0)) if live != null else 0, "empty": false,
			"frac": minf(1.0, (float(live["until"]) - now) / (float(def["seconds"]) * 1000.0)) if live != null else 0.0,
			"count": _d_n[bi], "tip": _brew_tip(shown, def, live != null)})
	return out
