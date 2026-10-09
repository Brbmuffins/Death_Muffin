class_name DmHeroLook
extends Node
## What every hero wears, on every peer: worn gear (DmAvatar.set_equipment: weapon, off-hand, helm, body tints, legendary aura), the cape, the
## pet (DmPetView) and, for the local hero, the hero ring / halo decals. Child "Look" of DmNextGame (same path on every peer).
##
## A look is a compact descriptor {"g": {slot: [item_id, rarity]}, "c": cape_id, "p": pet_id}, ~100 B. Its owner builds it (the host from the
## bag in memory + the Capes & Pets panel's selection; a joiner from its own backend), applies it locally and sends it reliably through the
## host, which relays it and replays every known look to a joiner. Receivers apply it to the puppet's avatar; a body whose avatar is not built yet
## is dressed when it is (`dress`). Only what changed is rebuilt: set_equipment diffs per slot, and an unchanged part is not even passed on.

const PET_FAR := 35.0           ## a remote pet this far from the local hero animates at FAR_HZ (nobody can see it move)
const FAR_HZ := 8.0
const REPLAY_DELAY := 0.8       ## as DmNextGame.CASTER_DELAY: a joiner's spawner must have made the bodies before we talk about them
const BODY_SLOTS := ["main_hand", "off_hand", "head", "chest", "legs", "hands", "feet"]

var game: Node                  ## DmNextGame
var looks: Dictionary = {}      ## peer id -> descriptor (every peer, as far as it has heard)
var sent: int = 0               ## look RPCs sent (tests: an unchanged look must send nothing)
var applied: int = 0            ## looks applied to an avatar (tests: only changes count)

var _pets: Dictionary = {}      ## peer id -> DmPetView
var _far_acc: Dictionary = {}   ## peer id -> accumulated dt of a far pet
var _ring: Array = []           ## the local hero's decal handles
var _ring_done := false
var _gear: Dictionary = {}      ## the local look's parts (kept so each source updates its own)
var _cape := ""
var _pet := ""
var _applied_gear: Dictionary = {}   ## peer id -> the gear last given to its avatar


func attach(g: Node) -> void:
	game = g
	game.session.player_left.connect(_on_left)
	game.session.player_joined.connect(_replay_to)       # the host tells a joiner what the others wear
	multiplayer.connected_to_server.connect(_publish)    # a joiner tells the host what it wears, once connected
	set_process(false)


func _exit_tree() -> void:
	for pv: DmPetView in _pets.values():
		pv.dispose.call_deferred()   # the tree is busy removing children right now
	_pets.clear()
	for h in _ring:
		if h != null:
			h.kill()
	_ring.clear()


# ---- the local look's sources ---------------------------------------------------------------------------------------------------

## The bag changed (or loaded): the worn pieces. `slots` = the inventory rows.
func set_gear_from_slots(slots: Array) -> void:
	var worn := DmGear.equipped_by_slot(slots)
	var g := {}
	for slot in worn:
		if slot in BODY_SLOTS:
			g[slot] = [String(worn[slot]["item_id"]), String(worn[slot].get("rarity", ""))]
	if g != _gear:
		_gear = g
		_publish()


## The Capes & Pets selection ({cape, pet}, null/"" = none).
func set_cosmetics(sel: Dictionary) -> void:
	var c := String(sel["cape"]) if sel.get("cape") != null else ""
	var p := String(sel["pet"]) if sel.get("pet") != null else ""
	if c != _cape or p != _pet:
		_cape = c
		_pet = p
		_publish()


## A peer with no UI (a joiner, a headless host) reads its own bag and cosmetics from its backend.
func load_from_api() -> void:
	var api: Variant = game.api
	var cid := int(game.character.get("id", 0))
	var inv: DmResult = await api.get_inventory(cid)
	if inv.ok and inv.data is Array:
		var worn := DmGear.equipped_by_slot(inv.data)
		_gear = {}
		for slot in worn:
			if slot in BODY_SLOTS:
				_gear[slot] = [String(worn[slot]["item_id"]), String(worn[slot].get("rarity", ""))]
	var cos: DmResult = await api.get_cosmetics(cid)
	if cos.ok and cos.data is Dictionary and cos.data.get("selected") is Dictionary:
		var sel: Dictionary = cos.data["selected"]
		_cape = String(sel["cape"]) if sel.get("cape") != null else ""
		_pet = String(sel["pet"]) if sel.get("pet") != null else ""
	_publish()


func descriptor() -> Dictionary:
	return {"g": _gear, "c": _cape, "p": _pet}


func _publish() -> void:
	var peer := multiplayer.multiplayer_peer
	if peer == null or peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return   # a joiner not connected yet: connected_to_server publishes
	var me: int = game.session.get_my_id()
	var d := descriptor()
	if looks.get(me) == d:
		return
	looks[me] = d.duplicate(true)
	_apply(me)
	if multiplayer.get_peers().is_empty():
		return
	sent += 1
	if multiplayer.is_server():
		_rpc_look.rpc(me, d)
	else:
		_rpc_submit.rpc_id(1, d)


## A client's own look to the host, which stores and relays it (the sender id is the host's, not the client's say-so).
@rpc("any_peer", "call_remote", "reliable")
func _rpc_submit(d: Dictionary) -> void:
	var from := multiplayer.get_remote_sender_id()
	if not _valid(d):
		return
	looks[from] = d
	_apply(from)
	sent += 1
	for peer in multiplayer.get_peers():
		if peer != from:
			_rpc_look.rpc_id(peer, from, d)


@rpc("authority", "call_remote", "reliable")
func _rpc_look(id: int, d: Dictionary) -> void:
	if id == game.session.get_my_id() or not _valid(d):
		return
	looks[id] = d
	_apply(id)


func _replay_to(id: int) -> void:
	if not multiplayer.is_server() or id == game.session.get_my_id():
		return
	await get_tree().create_timer(REPLAY_DELAY).timeout
	if not is_inside_tree() or not multiplayer.get_peers().has(id):
		return
	for peer in looks:
		if peer != id:
			_rpc_look.rpc_id(id, peer, looks[peer])


## Untrusted input: the right shape and small, nothing else is checked here (unknown ids simply show nothing).
static func _valid(d: Dictionary) -> bool:
	if not (d.get("g") is Dictionary and d.get("c") is String and d.get("p") is String):
		return false
	var g: Dictionary = d["g"]
	if g.size() > BODY_SLOTS.size():
		return false
	for slot in g:
		if not (slot is String and slot in BODY_SLOTS and g[slot] is Array and g[slot].size() == 2):
			return false
	return true


# ---- applying -------------------------------------------------------------------------------------------------------------------

## Dress a body from its stored look (its avatar was just built, or the look just arrived).
func dress(b: DmHeroBody) -> void:
	if b != null and looks.has(b.owner_peer):
		_apply(b.owner_peer)
	if b != null and b.owner_peer == game.session.get_my_id():
		_dress_ring(b)


func _apply(id: int) -> void:
	var b := game.body_of(id) as DmHeroBody
	var d: Dictionary = looks.get(id, {})
	if b == null or b.avatar == null or d.is_empty():
		return
	if _applied_gear.get(id) != d["g"]:
		_applied_gear[id] = (d["g"] as Dictionary).duplicate(true)
		var items := {}
		for slot in d["g"]:
			items[slot] = {"item_id": d["g"][slot][0], "rarity": d["g"][slot][1]}
		b.avatar.set_equipment(items)
		applied += 1
	b.avatar.set_cape(String(d["c"]))
	var pet := String(d["p"])
	var cur: DmPetView = _pets.get(id)
	if (cur.id() if cur != null else "") == pet:
		return
	_drop_pet(id)
	var def: Variant = _pet_def(pet)
	if def != null and game.get("_visual") != false:
		_pets[id] = DmPetView.new(game, def, b.position.x, b.position.z)
		set_process(true)
	applied += 1


static func _pet_def(id: String) -> Variant:
	if id == "":
		return null
	for p in DmContent.get_export("cosmetics", "PETS"):
		if p["id"] == id:
			return p
	return null


func pet_of(id: int) -> DmPetView:
	return _pets.get(id)


func _drop_pet(id: int) -> void:
	var pv: DmPetView = _pets.get(id)
	if pv != null:
		pv.dispose()
	_pets.erase(id)
	_far_acc.erase(id)
	if _pets.is_empty():
		set_process(false)


func _on_left(id: int) -> void:
	_drop_pet(id)
	looks.erase(id)
	_applied_gear.erase(id)


## The pets trail their owners every frame (as the original game: dt-driven, no allocation); one far from the local hero steps at FAR_HZ.
func _process(dt: float) -> void:
	var me := game.local_body() as DmHeroBody
	for id in _pets:
		var b := game.body_of(id) as DmHeroBody
		if b == null:
			continue
		var step := dt
		if me != null and b != me and b.position.distance_squared_to(me.position) > PET_FAR * PET_FAR:
			step = float(_far_acc.get(id, 0.0)) + dt
			if step < 1.0 / FAR_HZ:
				_far_acc[id] = step
				continue
			_far_acc[id] = 0.0
		(_pets[id] as DmPetView).update(step, b.position.x, b.position.z, b.rotation.y)


# ---- the hero ring -------------------------------------------------------------------------------------------

## The hero stays findable: contact shadow + pale ring, the discipline glow + bone ring, the cursor reticle, the soul halo, the hover ring.
func _dress_ring(b: DmHeroBody) -> void:
	var vfx := get_node_or_null("/root/Vfx")
	if _ring_done or vfx == null or game.get("_visual") == false:
		return
	_ring_done = true
	var wb: WeakRef = weakref(b)    # the decals outlive the body for a frame when the game closes: capture nothing that can be freed
	var wg: WeakRef = weakref(game)
	var at := func() -> Variant:
		var hb: Variant = wb.get_ref()
		return Vector3(hb.position.x, 0, hb.position.z) if hb != null else null
	var dd: Dictionary = DmContent.discipline(b.discipline_id)
	var col: int = int(Color.html(String(dd.get("color", "#a26bff"))).to_rgba32() >> 8)
	_ring = [
		vfx.decal({"hero": true, "persistent": true, "tex": "glow", "blending": "mix", "color": 0x07040d, "x": 0.0, "z": 0.0, "r": 1.25, "y": 0.045, "duration": 1e9, "opacity": 0.5, "fadeIn": 0.5, "follow": at}),
		vfx.decal({"hero": true, "persistent": true, "tex": "ring", "color": 0xf0e8ff, "x": 0.0, "z": 0.0, "r": 0.8, "y": 0.05, "duration": 1e9, "opacity": 0.6, "fadeIn": 0.5, "follow": at}),
		vfx.decal({"tex": "glow", "color": col, "x": 0.0, "z": 0.0, "r": 2.2, "duration": 1e9, "opacity": 0.13, "fadeIn": 0.01, "follow": at}),
		vfx.decal({"tex": "ring", "color": 0xc8bea8, "x": 0.0, "z": 0.0, "r": 0.85, "duration": 1e9, "opacity": 0.46, "fadeIn": 0.01, "follow": at}),
		vfx.decal({"tex": "ring", "color": 0xb6a9c8, "x": 0.0, "z": 0.0, "r": 0.35, "duration": 1e9, "opacity": 0.36, "fadeIn": 0.01,
			"follow": func() -> Variant:
				var gm: Variant = wg.get_ref()
				if gm == null:
					return null
				var a: Vector3 = gm.aim_point()
				return Vector3(a.x, 0, a.z)}),
		vfx.decal({"tex": "ring", "color": int(DmContent.spell_fx()["souls"]["jade"]), "x": 0.0, "z": 0.0, "r": 1.25, "duration": 1e9, "opacity": 0.75, "fadeIn": 0.01, "pulse": 5.0,
			"follow": func() -> Variant:
				var hb: Variant = wb.get_ref()
				return Vector3(hb.position.x, 0, hb.position.z) if (hb != null and not hb.p.is_empty() and hb.alive and DmPlayerRules.souls_charged(hb.p)) else null}),
		vfx.decal({"tex": "ring", "color": 0xf0e9dc, "x": 0.0, "z": 0.0, "r": 1.0, "duration": 1e9, "opacity": 0.85, "fadeIn": 0.01, "pulse": 6.0,
			"follow": func() -> Variant:
				var gm: Variant = wg.get_ref()
				var id: int = int(gm.aim_target_id()) if gm != null else 0
				var e: DmEnemy = (gm.enemy_by_id(id) as DmEnemy) if id > 0 else null
				return Vector3(e.global_position.x, 0, e.global_position.z) if e != null and e.is_inside_tree() else null}),
	]
