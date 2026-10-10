class_name DmNextBelt
extends RefCounted
## The slice's belt on the host's body: Q drinks a healing flask (with the 1.5 s sip cooldown), Z / X drink the elixir / tonic on the belt,
## meals heal over time. The HUD rows are DmGameHud.brews.
## Brew state lives on the body (ward, speed) and its caster (damage, haste, essence): both are fed by `drink_buff`.

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


func _now() -> float:
	return body.clock_ms()


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
	if pick != "" and inventory.count(pick) > 0:
		return pick
	return DmPotionBelt.heal_pick(func(f: String) -> int: return inventory.count(f))


## The brew a slot would drink: the pick if the bag holds it, else any brew of the slot the bag holds.
func belt_brew(slot: String) -> String:
	var pick: String = belt[slot]
	if pick != "" and inventory.count(pick) > 0:
		return pick
	for id in DmContent.brews():
		if DmContent.brews()[id]["slot"] == slot and inventory.count(id) > 0:
			return id
	return ""


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
	var before: Variant = body.p["brews"].get(b["slot"])
	var prev: Variant = DmContent.brews().get(before["id"]) if (before != null and _now() < float(before["until"])) else null
	if not inventory.consume(id):
		return
	var r: Dictionary = body.apply_brew(id)
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
	body.heal(amount)
	_say("+%d" % DmMath.js_round(amount), "heal", 2.2)
	if sfx.is_valid():
		sfx.call("drinkFlask")


## Host, every physics frame (cheap: one compare while no meal runs).
func tick(dt: float) -> void:
	if meal_until > 0.0 and body != null and body.alive:
		if _now() < meal_until:
			body.heal(meal_rate * dt)
		else:
			meal_until = 0.0


## The HUD's three chips (DmGameHud.brews).
func rows() -> Array:
	var now := _now()
	var flasks: Dictionary = DmContent.healing_flasks()
	var hid := heal_id()
	var total := 0
	for f in flasks:
		total += inventory.count(f)
	var cd_left := maxf(0.0, flask_cd_until - now)
	var cd_total := DmBrews.heal_cooldown_ms()
	var dry := prog != null and bool(prog.vow_fx().get("noFlasks", false))
	var tip := ""
	if dry:
		tip = "Dry Cellar: your vow forbids healing flasks. Break it at the Altar of Ascension."
	elif hid != "":
		tip = "Healing: %s restores %d%% of your health (%d carried). Press Q to drink; sips are %ds apart." % [DmContent.item(hid)["name"], DmMath.js_round(float(flasks[hid]) * 100.0), total, int(cd_total / 1000.0)]
	else:
		tip = empty_hint("heal")
	var out: Array = [{"slot": "heal", "key": "Q", "label": "Heal", "glyph": "✚", "color": 0xe0709c, "active": false, "left": 0,
		"frac": (cd_left / cd_total) if (cd_left > 0.0 and hid != "") else 0.0, "count": total, "empty": hid == "", "tip": tip}]
	for slot in ["elixir", "tonic"]:
		var act: Variant = body.p["brews"].get(slot) if body != null and not body.p.is_empty() else null
		var live: Variant = act if (act != null and now < float(act["until"])) else null
		var belt_id := belt_brew(slot)
		var shown: String = String(live["id"]) if live != null else belt_id
		var key := String(DmContent.get_export("brews", "BREW_KEYS")[slot]).to_upper()
		if shown == "":
			out.append({"slot": slot, "key": key, "label": "Elixir" if slot == "elixir" else "Tonic", "glyph": "⚗" if slot == "elixir" else "✧", "color": 0x8a8aa0,
				"active": false, "left": 0, "frac": 0.0, "count": 0, "empty": true, "tip": empty_hint(slot)})
			continue
		var def: Dictionary = DmContent.brews()[shown]
		out.append({"slot": slot, "key": key, "label": def["label"], "glyph": def["glyph"], "color": def["color"], "active": live != null,
			"left": int(ceil((float(live["until"]) - now) / 1000.0)) if live != null else 0, "empty": false,
			"frac": minf(1.0, (float(live["until"]) - now) / (float(def["seconds"]) * 1000.0)) if live != null else 0.0,
			"count": inventory.count(belt_id) if belt_id != "" else 0, "tip": "%s: %s · %ds" % [def["label"], "active" if live != null else "on your belt", int(def["seconds"])]})
	return out
