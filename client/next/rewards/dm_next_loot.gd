class_name DmNextLoot
extends Node
## The local player's loot and bag on the rebuilt client (child "Loot" of DmNextGame): the ground drops of this player's rewards
## member and the bag they land in. It stands on its own, not inside the panels' adapter (DmNextUiHost), so value works before the panels
## exist (the panels item's adapter reads `inventory` from here). It does the take, pickup, claim and rune-ownership paths of a drop:
##   - a click on a drop (DmNextInput: loot_click / loot_hover / loot_cancel) walks the hero there; the drop is taken on arrival (loot never flies);
##   - a drop from the member's tape is CLAIMED: the server rolls the same event and puts its own roll in the bag (`api.drops_claim`, DECISIONS B20); a piece a party member
##     dropped on the session's ground is picked up (`api.ground_pickup`: the first pickup wins, the party's other copies go);
##   - gold and shards are credited by the rewards node itself (their floats and sound are here, one per fight, GOT_WINDOW_S);
##   - a rune the character owns (learned, bag, Vault) never drops; a new one goes straight into the bag (its toast);
##   - the bag (DmInventory) is the server's rows; worn gear feeds the stats (DmNextProgress.request_stats) and pays for the belt.
## `event(id, ctx)` is the game_event shape (toast, float, loot, chat, collected, loot_landed); the game scene hands it to the HUD.

signal event(id: String, ctx: Dictionary)
signal inventory_changed
signal learned_runes_changed                ## learned_runes changed (note_learned)

const GOT_WINDOW_S := 1.2

var game: DmNextGame
var api: Variant
var hero_id: int = 0
var inventory: DmInventory
var guest_belt: DmNextBelt                   ## a party guest's belt: its own bag pays, the host applies the drink (DmNextBelt.remote_use); null on a host
## The character's learned runes (rune id -> true; GET /api/runes): never dropped again.
var learned_runes: Dictionary = {}

var _vault_runes: Dictionary = {}            ## rune ids in the account's Vault: a rune drop never repeats one the player owns
var _full_at := -100000
var _bag_full_noticed := false
var _got_gold := 0
var _got_shards := 0
var _got_pending := false
var _loot_tip_sent := false


## Host or guest, after the player's rewards member exists (the host's DmSessionRewards member, or a guest's DmNextJoiner member). Awaited under the
## loading cover: it reads the bag, the learned runes and the Vault's runes from the server.
func setup(game_: DmNextGame) -> void:
	game = game_
	api = game.api
	hero_id = int(game.character.get("id", 0))
	inventory = DmInventory.new(api, hero_id)
	inventory.changed.connect(func(_s: Array) -> void: inventory_changed.emit())
	inventory.save_failed.connect(func(m_: String) -> void: event.emit("toast", {"text": "Your bag could not be saved: %s. Retrying. Your items are safe on screen." % m_, "kind": "err"}))
	inventory.save_recovered.connect(func() -> void: event.emit("toast", {"text": "Bag saved.", "kind": "good"}))
	if game.progress != null:
		game.progress.belt.inventory = inventory
		inventory.changed.connect(func(_s: Array) -> void: game.progress.request_stats())   # worn gear feeds the stats
	elif game.joiner != null:
		_make_guest_belt()
		inventory.changed.connect(_on_guest_inventory)   # the host builds our hero from the server's record: tell it when what we wear changed
	var m: DmRewardsMember = game.my_member()
	if m != null:
		m.take_item = Callable(self, "_take")
		m.owned_legendaries = Callable(self, "_owned_legendaries")
		m.loot_view.picked.connect(_on_picked)
		m.loot_view.rune_found.connect(_on_rune_found)
		m.loot_view.legendary_dropped.connect(_on_legendary_dropped)
		m.loot_view.rune_owned = Callable(self, "_owns_rune")
		m.loot_view.claim_requested.connect(_on_claim)
		m.loot_view.dropped_sound.connect(_on_item_landed)
	await _load_vault_runes()
	await _load_learned_runes()
	await refresh_inventory()
	set_process(true)


func _process(dt: float) -> void:
	inventory.tick(dt)


## The bag's rows as the server holds them (worn gear feeds the build).
func slots() -> Array:
	return inventory.slots


## Send the queued uses now. "" = the server has them; otherwise the reason.
func bag_commit() -> String:
	return await inventory.commit()


func refresh_inventory() -> void:
	var r: DmResult = await api.get_inventory(hero_id)
	if r.ok and r.data is Array:
		inventory.replace(r.data)
	inventory_changed.emit()


## A party guest's belt (DmNextBelt.remote_use): the same rules and chips as the host's, on the guest's own bag and progression.
func _make_guest_belt() -> void:
	guest_belt = DmNextBelt.new()
	guest_belt.body = game.local_body()
	guest_belt.inventory = inventory
	guest_belt.prog = game.joiner.prog
	guest_belt.remote_use = game.party.guest_use
	guest_belt.say = func(text: String, kind: String, y: float) -> void:
		var b := game.local_body()
		if b != null:
			event.emit("float", {"world": b.position + Vector3(0, y, 0), "text": text, "kind": kind})
	guest_belt.sfx = func(sound: String) -> void: _sfx(sound)
	guest_belt.toast = func(text: String) -> void: event.emit("toast", {"text": text, "kind": ""})


var _worn_key := ""

## A guest's bag changed: when what it wears changed (rows at slot 100 and up), the host reads its build from the server again.
func _on_guest_inventory(_s: Array) -> void:
	var parts := PackedStringArray()
	for row in inventory.all():
		if int(row.get("slot_index", 0)) >= 100:
			parts.append("%s:%s:%s" % [row.get("slot_index", ""), row.get("item_id", ""), row.get("instance_id", "")])
	var key := ",".join(parts)
	if key != _worn_key:
		_worn_key = key
		if game.party != null:
			game.party.build_changed()


# ---- the drops: click, hover, take ------------------------------------------------------------------------------------------------------

## A left click on a drop (DmNextInput): the hero walks there and takes it on arrival. False = no drop under the cursor.
func loot_click(screen: Vector2) -> bool:
	var m: DmRewardsMember = game.my_member()
	var b := game.local_body()
	if m == null or b == null or not b.alive:
		return false
	var d := m.loot_view.pick(screen, game.camera)
	if d.is_empty():
		return false
	m.loot_view.request_pickup(d)
	game.input.click_move(Vector3(float(d["x"]), 0.0, float(d["z"])))
	return true


## Any other click or a WASD step: the hero no longer heads for a drop.
func loot_cancel() -> void:
	var m: DmRewardsMember = game.my_member()
	if m != null:
		m.loot_view.cancel_pickup()


## The 10 Hz hover pick (DmNextInput): the drop under the cursor shows its name; Alt shows every name.
func loot_hover(screen: Vector2, enemy_hovered: bool, alt: bool) -> void:
	var m: DmRewardsMember = game.my_member()
	if m == null:
		return
	m.loot_view.all_labels = alt
	m.loot_view.hover({} if enemy_hovered and not alt else m.loot_view.pick(screen, game.camera))


## DmLootView.try_take: the bag, or false (the drop stays on the ground) with a "Reliquary full" float now and then and, once, what to do about it.
func _take(d: Dictionary) -> bool:
	if inventory.add(d):
		_bag_full_noticed = false   # room again: the next time something does not fit, say so once more
		return true
	var now := Time.get_ticks_msec()
	if now - _full_at > 8000:
		_full_at = now
		var b := game.local_body()
		if b != null:
			event.emit("float", {"world": b.position + Vector3(0, 2.4, 0), "text": "Reliquary full", "kind": "info"})
	if not _bag_full_noticed:
		_bag_full_noticed = true
		event.emit("toast", {"text": "Your Reliquary is full. Sell spare gear (Sell all junk) or, back in the Chapterhouse or the Acre, store materials in the Vault (V). What you cannot carry stays on the ground for a minute.", "kind": "err"})
	return false


## The hero reached a drop the server hands over itself: a piece a member dropped on the party's ground (the first pickup wins; everyone else's copy goes away),
## or a drop rolled from the tape (the server's own roll goes in the bag).
func _on_claim(d: Dictionary) -> void:
	if d.get("claiming", false):
		return
	d["claiming"] = true
	if not d.has("drop_id"):
		await _claim_from_tape(d)
		return
	var id := String(d["drop_id"])
	var err := await bag_commit()
	var r: DmResult = await api.ground_pickup(hero_id, id) if err == "" else null
	d["claiming"] = false
	var m: DmRewardsMember = game.my_member()
	if r != null and r.ok:
		inventory.replace(r.data["bag"])
		inventory_changed.emit()
		if m != null:
			m.loot_view.remove_shared(id)
		if game.party != null:
			game.party.share_taken(id)
		var meta := DmContent.item(String(d["item"]["item_id"]))
		_loot_toast(d["item"], meta)
		_item_collected(d["item"], meta)
		return
	var why := err if r == null else (r.error if r.error != "" else "You could not pick that up.")
	event.emit("toast", {"text": why, "kind": "err"})
	if why.begins_with("It is gone") and m != null:
		m.loot_view.remove_shared(id)


## A drop rolled from the tape (DECISIONS B20): the server rolls the same event again and puts its own roll in the bag. The ground copy goes once the
## server answers; it stays (and can be clicked again) only when the bag is full or the server could not be reached.
func _claim_from_tape(d: Dictionary) -> void:
	var m: DmRewardsMember = game.my_member()
	var err := await bag_commit()
	var r: DmResult = await api.drops_claim(hero_id, d["item"]["claim"], game.party_session_id()) if err == "" else null
	d["claiming"] = false
	if r != null and r.ok:
		inventory.replace(r.data["bag"])
		inventory_changed.emit()
		if m != null:
			m.loot_view.take_claimed(d)
			m.stats["items_picked"] += 1
		var g: Dictionary = r.data["item"]
		var got := {"item_id": String(g["item_id"]), "quantity": int(g.get("quantity", 1))}
		if g.has("ilvl"):
			got["instance"] = {"id": g.get("instance_id"), "ilvl": int(g["ilvl"]), "affixes": g.get("affixes", [])}
		var meta := DmContent.item(String(got["item_id"]))
		if DmRunes.is_rune_id(got["item_id"]) and m != null:
			m.loot_view.rune_found.emit(got, Vector3(float(d["x"]), 0, float(d["z"])))
		else:
			_loot_toast(got, meta)
		_item_collected(got, meta)
		return
	var why := err if r == null else (r.error if r.error != "" else "You could not pick that up.")
	event.emit("toast", {"text": why, "kind": "err"})
	if r != null and r.data is Dictionary and r.data.get("resync") is Dictionary and m != null and m.tape != null:
		var rs: Dictionary = r.data["resync"]
		m.tape.rewind(String(rs.get("kind", "")), int(rs.get("spent", 0)))   # the tape ran ahead of the kills the server believed
	var keep := r == null or r.status == 0 or r.status >= 500 or why.begins_with("Your bag is full")
	if not keep and m != null:
		m.loot_view.take_claimed(d)


# ---- what the player sees and hears of it ---------------------------------------------------------------------------------------------

func _on_picked(ev: Dictionary) -> void:
	match String(ev["kind"]):
		"gold":
			_got_gold += int(ev["amount"])
			_schedule_got()
		"shard":
			_got_shards += int(ev["amount"])
			_schedule_got()
		"item":
			var it: Dictionary = ev["item"]
			var meta := DmContent.item(String(it["item_id"]))
			_loot_toast(it, meta)
			_item_collected(it, meta)


## Gold and shards credited within GOT_WINDOW_S are one float + one sound: a fight pays out once, not per pile.
func _schedule_got() -> void:
	if not _got_pending:
		_got_pending = true
		get_tree().create_timer(GOT_WINDOW_S).timeout.connect(_flush_got)


func _flush_got() -> void:
	_got_pending = false
	var b := game.local_body()
	var at: Vector3 = b.position if b != null else Vector3.ZERO
	if _got_gold > 0:
		event.emit("float", {"world": at + Vector3(0, 2.1, 0), "text": "+%dg" % _got_gold, "kind": "gold"})
		_sfx("coin")
	if _got_shards > 0:
		event.emit("float", {"world": at + Vector3(0, 2.3, 0), "text": "+%d soul shard%s" % [_got_shards, "s" if _got_shards > 1 else ""], "kind": "shard"})
		_sfx("shard")
	_got_gold = 0
	_got_shards = 0


## The pickup toast: the name in the colour the beam had on the ground (affixes raise it), and "(upgrade)" on a piece that beats what you wear.
func _loot_toast(it: Dictionary, meta: Dictionary) -> void:
	var nm := _loot_name(it, meta)
	if DmAffixRules.is_affix_gear(String(meta.get("type", ""))):
		var slot: Variant = DmLoot.add_to_slots([], it)
		if slot != null and not (slot as Array).is_empty():
			var sl: Dictionary = (slot as Array)[0]
			if it.get("instance") != null:
				sl["inst"] = it["instance"]
			if DmItemText.badge(_stat_context(), sl) == "up":
				nm += " (upgrade)"
	event.emit("loot", {"name": nm, "qty": int(it.get("quantity", 1)), "rarity": DmLootView.rarity_of(it)})


## What DmItemText compares a new piece against: the character, the bag and the build's discipline and legion.
func _stat_context() -> Dictionary:
	var b := game.build_for(game.session.get_my_id())
	var local: Dictionary = game.progress.prog.local if game.progress != null else game.server_local
	return {"character": game.character, "slots": inventory.slots, "discipline": b["discipline"], "damageTier": float(local.get("damageTier", 0)), "legion": b["legion"]}


## The loot name as the player knows it: affixed gear reads "Cruel Bone Wand of X".
func _loot_name(it: Dictionary, meta: Dictionary) -> String:
	var nm := String(meta.get("name", it["item_id"]))
	if it.get("instance") != null:
		nm = DmAffixRules.affixed_name(nm, it["instance"]["affixes"])
	return nm


## An item landed on the ground: its drop sound (by rarity, positioned) and, once per session, the counsel's "click to pick up" event.
func _on_item_landed(sound_id: String, pos: Vector3) -> void:
	_sfx(sound_id, pos)
	if not _loot_tip_sent:
		_loot_tip_sent = true
		event.emit("loot_landed", {})


## A rune the player did not own went straight into the bag: the pickup's sound, toast and counsel facts, and a line in chat (the party sees it too).
func _on_rune_found(drop: Dictionary, _pos: Vector3) -> void:
	var meta := DmContent.item(String(drop["item_id"]))
	_loot_toast(drop, meta)
	_item_collected(drop, meta)
	var rune: Dictionary = DmContent.get_export("runes", "RUNES").get(String(drop["item_id"]), {})
	var nm := String(meta.get("name", drop["item_id"]))
	var short := String(rune.get("short", ""))
	var reaper := game.local_body() != null and game.local_body().family != "necromancer"
	_loot_chat("You found the %s%s%s. Select it in your Reliquary (I) and click Learn." % [nm, (": " + short.substr(0, 1).to_lower() + short.substr(1)) if short != "" else "",
		" (a necromancer rune)" if reaper else ""], "{who} found the %s." % nm)


func _on_legendary_dropped(drop: Dictionary, _pos: Vector3) -> void:
	var nm := _loot_name(drop, DmContent.item(String(drop["item_id"])))
	_loot_chat("You found %s (legendary)." % nm, "{who} found %s (legendary)." % nm)


## A find worth telling: in a party every member reads `party_line` ("{who}" = the finder's roster name) in chat, solo you read `own_line`.
func _loot_chat(own_line: String, party_line: String) -> void:
	if game.party != null and game.party.announce(party_line):
		return
	event.emit("chat", {"text": own_line})


func _item_collected(it: Dictionary, meta: Dictionary) -> void:
	var rarity := String(meta.get("rarity", "common"))
	var a := get_node_or_null("/root/AudioDirector")
	if a != null and _audio():
		a.play_loot([rarity])
	var item_id := String(it["item_id"])
	var legendary := rarity == "legendary"
	event.emit("collected", {"gear": DmAffixRules.is_affix_gear(String(meta.get("type", ""))), "legendary": legendary, "armor": DmContent.armor_sets().has(item_id) and not legendary,
		"reagent": DmContent.reagents().has(item_id), "affixed": it.get("instance") != null and not (it["instance"]["affixes"] as Array).is_empty()})
	if legendary:
		event.emit("toast", {"text": "Legendary: %s" % String(meta.get("name", item_id)), "kind": "good"})


# ---- ownership: what never drops twice ---------------------------------------------------------------------------------------------------

## Legendary pieces worn or in the bag: what a legendary roll avoids repeating (the server reads the same from its rows).
func _owned_legendaries() -> Array:
	var out: Array = []
	for row in inventory.all():
		var id := String(row.get("item_id", ""))
		if id.begins_with("leg_") and not out.has(id):
			out.append(id)
	return out


## DmLootView.rune_owned: a rune the character has learned, holds (bag, sockets) or keeps in the Vault does not drop again.
func _owns_rune(drop: Dictionary) -> bool:
	var id := String(drop["item_id"])
	if learned_runes.has(id) or _vault_runes.has(id):
		return true
	for r: Dictionary in inventory.slots:
		if r.get("item_id") == id:
			return true
	return false


## The Vault's rows (every {bag, vault} answer, and once at setup): which runes the account keeps there.
func note_vault(data: Dictionary) -> void:
	if not (data.get("vault") is Array):
		return
	_vault_runes.clear()
	for r: Dictionary in data["vault"]:
		if DmRunes.is_rune_id(r.get("item_id")):
			_vault_runes[String(r["item_id"])] = true


## The learned runes from a server answer ([rune ids]).
func note_learned(ids: Variant) -> void:
	if not (ids is Array):
		return
	learned_runes.clear()
	for id in ids:
		if DmRunes.is_rune_id(id):
			learned_runes[String(id)] = true
	learned_runes_changed.emit()


func _load_learned_runes() -> void:
	if api == null or not api.has_method("runes_learned"):
		return
	var r: DmResult = await api.runes_learned(hero_id)
	if r.ok and r.data is Dictionary:
		note_learned(r.data.get("learned"))


func _load_vault_runes() -> void:
	if api == null or not api.has_method("get_vault"):
		return
	var r: DmResult = await api.get_vault(hero_id)
	if r.ok and r.data is Dictionary:
		note_vault(r.data)


func _audio() -> bool:
	return bool(game.opts.get("audio", DisplayServer.get_name() != "headless"))


func _sfx(id: String, pos: Variant = null) -> void:
	var a := get_node_or_null("/root/AudioDirector")
	if a != null and _audio():
		a.play_sfx(id, Vector2(pos.x, pos.z) if pos is Vector3 else null, 1.0)
