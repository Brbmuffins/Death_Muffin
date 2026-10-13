class_name DmLootView
extends Node3D
## Personal loot of one player (port of archive/legacy-web:src/graphics/LootView.ts, reworked 2026-10-12, DECISIONS B15).
## - Gold and soul shards never touch the ground: drop() credits them on the next tick() as "picked" events (no mesh, no magnet).
## - Gear and materials wait under a rarity-coloured light pillar for LOOT_EXPIRE_S (3 min). Walking over them does nothing: the player
##   clicks one (pick() + request_pickup()), walks there, and it is taken once the hero is within ITEM_PICKUP_RADIUS. Loot never flies.
## - Runes: drop() asks `rune_owned` whether the player has it already (then it does not drop at all: owner 2026-10-13) and puts a new
##   one straight into the bag (`rune_found`); a full bag leaves it on the ground like any item. Legendaries landing raise `legendary_dropped` (the chat line).
## - Shared drops (shared_item): gear someone dropped from a bag (ground.cjs). It stays until the session ends, outside the cap, and reaching
##   it raises `claim_requested`: the server hands it over (the first pickup wins), then the owner calls remove_shared().
## Past LOOT_ITEM_CAP items the oldest go early, ordinary before epic/legendary.
##
## Usage:  var lv := DmLootView.new(); add_child(lv)
##         lv.drop({"item_id": "...", "quantity": 1, "instance": {...}}, pos)   # item / rune
##         lv.drop({"kind": "gold", "amount": 12}, pos)  /  {"kind": "shard", "amount": 3}
##         var events := lv.tick(delta, hero_pos)        # [{kind:"gold"|"shard"|"item", amount:int, item?:Dictionary, pos:Vector3}]
## Render budget: beams and ground glows share one material per rarity (the pulse is one write per frame, not per drop).
## Names: the drop under the cursor (hover()), drops near the hero (rare+ from LABEL_NEAR, ordinary from LABEL_NEAR_COMMON), every drop while
## `all_labels` is on (Alt held) or `show_labels` (QA / screenshots).

signal picked(event: Dictionary)          ## gold / shard credited, or an item taken by a pickup request
signal expired(drop: Dictionary, reason: String)  ## reason "ttl" or "cap" (removed without payout)
signal rune_found(drop: Dictionary, pos: Vector3)             ## a rune the player did not own went straight into the bag
signal legendary_dropped(drop: Dictionary, pos: Vector3)      ## a legendary landed on the ground
signal dropped_sound(sound_id: String, pos: Vector3)          ## lootDrop / lootDropRare / lootDropEpic / lootDropLegendary
signal claim_requested(drop: Dictionary)                      ## the hero reached a shared drop (gear a party member dropped): the server decides

## Owner 2026-10-12 (team thread): gear and materials stay 3 minutes (was 60 s).
const LOOT_EXPIRE_S := 180.0
const LOOT_ITEM_CAP := 60
const ITEM_PICKUP_RADIUS := 1.3
const PICK_PX := 40.0            ## a click this close (screen px) to a drop's icon picks it
const LABEL_NEAR := 7.0
const LABEL_NEAR_COMMON := 3.0
const EXPIRY_WARN_S := 8.0       ## the last seconds: the icon blinks (faster in the last 3)
const ITEM_SPACING := 0.65       ## item drops land at least this far apart when there is room

const RARITY_COLORS := {"common": "#b9b2a4", "uncommon": "#8fb98a", "rare": "#8fa6e8", "epic": "#c6a4ff", "legendary": "#ff9a2e"}

## Callable(drop)->bool: put it in the bag; false when full (the item then stays until it expires).
var try_take: Callable = Callable()
## Callable(drop)->bool for a rune drop: true = the player has it already (learned, bag, sockets, Vault) and it does not drop. Empty = it drops.
var rune_owned: Callable = Callable()
## Callable()->float in [0,1) used for scatter (TS Math.random). Empty = randf.
var rand: Callable = Callable()
var show_labels := false   ## always show every name (QA / screenshots)
var all_labels := false    ## Alt held: every name on the ground
var near_labels := true    ## names of the drops near the hero

var _drops: Array[Dictionary] = []
var _credit: Array[Dictionary] = []     ## gold / shard events waiting for the next tick()
var _target: Dictionary = {}            ## the drop the player clicked: taken when the hero reaches it
var _hover: Dictionary = {}             ## the drop under the cursor (its name shows)
var _icon_cache: Dictionary = {}
static var _glow_tex: Texture2D
static var _beam_mats: Dictionary = {}   ## rarity -> the shared beam material (its pulse is written once per frame, not per drop)
static var _glow_mats: Dictionary = {}   ## rarity -> the shared ground-glow material
var _pulse_t := 0.0


func _r() -> float:
	return randf() if rand.is_null() else float(rand.call())


func _scatter(p: Vector3, r: float = 0.9) -> Vector2:
	var a := _r() * TAU
	var d := 0.3 + _r() * r
	return Vector2(p.x + cos(a) * d, p.z + sin(a) * d)


## Like _scatter, but a few tries to land clear of the items already lying around so a pile of drops stays readable.
func _scatter_apart(p: Vector3, r: float) -> Vector2:
	if not rand.is_null():   # a scripted rand (the TS fixtures) replays its exact sequence
		return _scatter(p, r)
	var best := _scatter(p, r)
	var best_gap := -1.0
	for attempt in 8:
		var c := _scatter(p, r + attempt * 0.25)
		var gap := 99.0
		for d in _drops:
			gap = minf(gap, Vector2(c.x - d["x"], c.y - d["z"]).length())
		if gap >= ITEM_SPACING:
			return c
		if gap > best_gap:
			best_gap = gap
			best = c
	return best


# ---------------------------------------------------------------- dropping

## Land a drop. Item drop dict = {item_id, quantity, instance?}; gold = {kind:"gold", amount}; shard = {kind:"shard", amount}.
## `exact` skips the scatter (tests / replaying a recorded position). Returns "auto" (credited / into the bag), "owned" (a rune the player
## has already: nothing drops) or "ground".
func drop(d: Dictionary, pos: Vector3, exact: bool = false) -> String:
	var kind: String = str(d.get("kind", "item"))
	if kind == "gold":
		gold(pos, int(d["amount"]), exact)
		return "auto"
	if kind == "shard":
		shard(pos, int(d["amount"]), exact)
		return "auto"
	if DmRunes.is_rune_id(d.get("item_id")):
		return _rune(d, pos, exact)
	item(pos, d, exact)
	return "ground"


func _rune(d: Dictionary, pos: Vector3, exact: bool) -> String:
	if rune_owned.is_valid() and bool(rune_owned.call(d)):
		return "owned"
	if try_take.is_valid() and bool(try_take.call(d)):
		rune_found.emit(d, pos)
		return "auto"
	item(pos, d, exact)   # the bag is full: it waits on the ground like any item
	return "ground"


## Gold goes straight to the purse: credited (a "picked" event) on the next tick().
func gold(pos: Vector3, amount: int, _exact: bool = false) -> void:
	if amount > 0:
		_credit.append({"kind": "gold", "amount": amount, "pos": pos})


## Soul shards go straight to the purse, like gold.
func shard(pos: Vector3, amount: int, _exact: bool = false) -> void:
	if amount > 0:
		_credit.append({"kind": "shard", "amount": amount, "pos": pos})


## Gear a party member (or you) dropped from a bag: entry {drop_id, item, x, z}. Lies where it was dropped until remove_shared().
func shared_item(entry: Dictionary) -> void:
	for d in _drops:
		if d.get("drop_id") == entry["drop_id"]:
			return
	item(Vector3(float(entry["x"]), 0, float(entry["z"])), entry["item"], true, String(entry["drop_id"]))


## A shared drop was picked up (by anyone) or is gone: off the ground.
func remove_shared(drop_id: String) -> void:
	for i in _drops.size():
		if _drops[i].get("drop_id") == drop_id:
			_remove(i, "")
			return


func item(pos: Vector3, d: Dictionary, exact: bool = false, drop_id: String = "") -> void:
	var p := Vector2(pos.x, pos.z) if exact else _scatter_apart(pos, 0.7)
	var meta := DmContent.item(str(d["item_id"]))
	var rarity := rarity_of(d)
	var color := Color(RARITY_COLORS[rarity])
	var prize := is_prize(rarity)
	dropped_sound.emit("lootDropLegendary" if rarity == "legendary" else "lootDropEpic" if rarity == "epic" else "lootDropRare" if rarity == "rare" else "lootDrop", Vector3(p.x, 0, p.y))
	if rarity == "legendary" and drop_id == "":
		legendary_dropped.emit(d, Vector3(p.x, 0, p.y))
	var root := Node3D.new()
	root.position = Vector3(p.x, 0, p.y)
	add_child(root)
	var icon := Sprite3D.new()
	icon.texture = _icon_for(str(d["item_id"]), color)
	icon.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	icon.pixel_size = 0.62 / maxf(1.0, float(icon.texture.get_width()))
	icon.shaded = false
	icon.alpha_cut = SpriteBase3D.ALPHA_CUT_DISABLED
	icon.transparent = true
	icon.position.y = 0.7
	root.add_child(icon)
	var beam: MeshInstance3D = null
	if rarity != "common":
		beam = MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.22
		cm.bottom_radius = 0.34
		cm.height = 6.0
		cm.radial_segments = 10
		cm.rings = 1
		cm.cap_top = false
		cm.cap_bottom = false
		beam.mesh = cm
		beam.position.y = 3.0
		beam.material_override = _beam_material(rarity, color)
		root.add_child(beam)
	# ground glow decal (r 0.9, additive)
	var glow := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(1.8, 1.8)
	q.orientation = PlaneMesh.FACE_Y
	glow.mesh = q
	glow.position.y = 0.03
	glow.material_override = _glow_material(rarity, color)
	root.add_child(glow)
	var lab: Label3D = _make_label(root, d, meta, color) if show_labels else null
	var drop := {"kind": "item", "node": root, "icon": icon, "beam": beam, "label": lab, "meta": meta, "color": color, "common": rarity == "common", "x": p.x, "z": p.y, "amount": int(d.get("quantity", 1)), "item": d, "t": 0.0,
		"ttl": LOOT_EXPIRE_S if drop_id == "" else INF, "prize": prize, "beam_alpha": 0.5 if rarity == "legendary" else 0.35}
	if drop_id != "":
		drop["drop_id"] = drop_id
	_drops.append(drop)


func _make_label(root: Node3D, d: Dictionary, meta: Dictionary, color: Color) -> Label3D:
	var lab := Label3D.new()
	lab.text = _label_text(d, meta)
	lab.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	lab.modulate = color
	lab.font_size = 28
	lab.pixel_size = 0.008
	lab.outline_size = 8
	lab.no_depth_test = true
	lab.position.y = 1.25
	root.add_child(lab)
	return lab


func _label_text(d: Dictionary, meta: Dictionary) -> String:
	var nm := str(meta.get("name", d["item_id"]))
	if d.has("instance"):
		nm = DmAffixRules.affixed_name(nm, d["instance"]["affixes"])
	var q := int(d.get("quantity", 1))
	return nm if q <= 1 else "%s x%d" % [nm, q]


## Rarity colour key: the item's rarity, raised by its affix count (green/blue/purple).
static func rarity_of(d: Dictionary) -> String:
	var base := str(DmContent.item(str(d["item_id"])).get("rarity", "common"))
	if d.has("instance") and d["instance"] != null:
		base = DmAffixRules.effective_rarity(base, (d["instance"]["affixes"] as Array).size())
	return base if RARITY_COLORS.has(base) else "legendary" if base == "relic" else "common"


static func is_prize(rarity: String) -> bool:
	return rarity == "epic" or rarity == "legendary"


# ---------------------------------------------------------------- picking up

## The drop whose icon is nearest the screen point within PICK_PX, or {} (`cam` = the game camera).
func pick(screen: Vector2, cam: Camera3D) -> Dictionary:
	var best: Dictionary = {}
	var best_d := PICK_PX
	for d in _drops:
		var v := (d["node"] as Node3D).global_position + Vector3(0, 0.7, 0)
		if cam.is_position_behind(v):
			continue
		var px := cam.unproject_position(v).distance_to(screen)
		if px < best_d:
			best_d = px
			best = d
	return best


## The player clicked this drop: it is taken when the hero reaches it (tick). The caller walks the hero there.
func request_pickup(d: Dictionary) -> void:
	_target = d


func cancel_pickup() -> void:
	_target = {}


## The drop waiting to be taken, or {}.
func pickup_target() -> Dictionary:
	return _target


## The drop under the cursor shows its name ({} = none).
func hover(d: Dictionary) -> void:
	_hover = d


# ---------------------------------------------------------------- per frame

## Credit gold/shards, age the drops, take the clicked one when the hero reaches it. Returns the events of this tick in order. hero_pos uses x/z.
func tick(dt: float, hero_pos: Vector3) -> Array[Dictionary]:
	var events: Array[Dictionary] = []
	for ev in _credit:
		events.append(ev)
		picked.emit(ev)
	_credit.clear()
	if _drops.is_empty():
		return events
	_pulse_t += dt
	if not _beam_mats.is_empty():
		var pa := 0.28 + sin(_pulse_t * 3.0) * 0.06   # the beams' slow pulse: one write per rarity instead of one per drop
		for m: StandardMaterial3D in _beam_mats.values():
			m.albedo_color.a = pa
	# Too many items: the oldest expire now (array is in drop order), ordinary ones before epic/legendary.
	if _drops.size() > LOOT_ITEM_CAP:
		var surplus := -LOOT_ITEM_CAP
		for d in _drops:
			if not d.has("drop_id"):
				surplus += 1
		for pass_ in 2:
			var prize_too := pass_ == 1
			var i := 0
			while i < _drops.size() and surplus > 0:
				var d: Dictionary = _drops[i]
				if not d.has("drop_id") and (prize_too or not d["prize"]):
					_remove(i, "cap")
					surplus -= 1
				else:
					i += 1
	var px := hero_pos.x
	var pz := hero_pos.z
	var i := _drops.size() - 1
	while i >= 0:
		var d: Dictionary = _drops[i]
		i -= 1
		d["t"] += dt
		if d["t"] > d["ttl"]:
			_remove(i + 1, "ttl")
			continue
		var ddx: float = px - d["x"]
		var ddz: float = pz - d["z"]
		var dist := sqrt(ddx * ddx + ddz * ddz)
		var node: Node3D = d["node"]
		(d["icon"] as Node3D).position.y = 0.7 + sin(d["t"] * 2.5) * 0.08
		var left: float = d["ttl"] - d["t"]
		(d["icon"] as Node3D).visible = left > EXPIRY_WARN_S or fmod(left, 0.5 if left > 3.0 else 0.25) > 0.12
		var show := show_labels or all_labels or is_same(d, _hover) or (near_labels and dist < (LABEL_NEAR_COMMON if d["common"] else LABEL_NEAR))
		var lb: Label3D = d["label"]
		if lb == null and show:
			d["label"] = _make_label(node, d["item"], d["meta"], d["color"])
		elif lb != null and lb.visible != show:
			lb.visible = show
		if is_same(d, _target) and dist < ITEM_PICKUP_RADIUS:
			_target = {}
			if d.has("drop_id"):
				claim_requested.emit(d)   # the server decides; the owner removes it once it is handed over
				continue
			if try_take.is_null() or bool(try_take.call(d["item"])):
				var ev := {"kind": "item", "amount": d["amount"], "item": d["item"], "pos": node.position}
				events.append(ev)
				picked.emit(ev)
				_remove(i + 1, "")
	return events


func _remove(idx: int, reason: String) -> void:
	var d: Dictionary = _drops[idx]
	if is_same(d, _target):
		_target = {}
	if is_same(d, _hover):
		_hover = {}
	(d["node"] as Node).queue_free()
	_drops.remove_at(idx)
	if reason != "":
		expired.emit(d, reason)


## Drop whatever lies inside the rect without paying out (Depths arrive/leave). rect = Rect2(x0, z0, w, h) in x/z. Returns the count.
func clear_within(r: Rect2) -> int:
	var n := 0
	var i := _drops.size() - 1
	while i >= 0:
		var d: Dictionary = _drops[i]
		if d["x"] >= r.position.x and d["x"] <= r.end.x and d["z"] >= r.position.y and d["z"] <= r.end.y:
			_remove(i, "")
			n += 1
		i -= 1
	return n


## Items on the ground (gold and shards never lie there).
func count() -> int:
	return _drops.size()


func clear_all() -> void:
	while not _drops.is_empty():
		_remove(_drops.size() - 1, "")


## QA: where every drop lies (TS debugDrops).
func debug_drops() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for d in _drops:
		out.append({"kind": d["kind"], "id": d["item"]["item_id"], "x": d["x"], "z": d["z"], "ttl": d["ttl"], "prize": d["prize"], "drop_id": d.get("drop_id", "")})
	return out


# ---------------------------------------------------------------- visuals

func _icon_for(id: String, color: Color) -> Texture2D:
	if _icon_cache.has(id):
		return _icon_cache[id]
	var tex: Texture2D = DmUiArt.item(id)   # the inventory's own icon lookup (meta.icon or art/items/<id>.webp)
	if tex == null:
		tex = _placeholder(color)
	_icon_cache[id] = tex
	return tex


## Stand-in icon for an item without art: a rounded rarity-tinted tile.
static func _placeholder(color: Color) -> Texture2D:
	var size := 48
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	for y in size:
		for x in size:
			var dx := absf(x - size / 2.0 + 0.5) / (size / 2.0)
			var dy := absf(y - size / 2.0 + 0.5) / (size / 2.0)
			var edge := maxf(dx, dy)
			if edge > 0.9:
				img.set_pixel(x, y, Color(0, 0, 0, 0))
			elif edge > 0.78:
				img.set_pixel(x, y, Color(color.r, color.g, color.b, 1.0))
			else:
				img.set_pixel(x, y, Color(color.r * 0.35, color.g * 0.35, color.b * 0.35, 0.92))
	return ImageTexture.create_from_image(img)


static func _glow() -> Texture2D:
	if _glow_tex == null:
		var g := Gradient.new()
		g.set_color(0, Color(1, 1, 1, 1))
		g.set_color(1, Color(1, 1, 1, 0))
		var t := GradientTexture2D.new()
		t.gradient = g
		t.fill = GradientTexture2D.FILL_RADIAL
		t.fill_from = Vector2(0.5, 0.5)
		t.fill_to = Vector2(1.0, 0.5)
		t.width = 128
		t.height = 128
		_glow_tex = t
	return _glow_tex


## One beam material per rarity, shared by every beam of that rarity (they batch, and the pulse is one write per frame in tick()).
static func _beam_material(rarity: String, color: Color) -> StandardMaterial3D:
	if not _beam_mats.has(rarity):
		var m := _additive_material(color, 0.5 if rarity == "legendary" else 0.35)
		m.albedo_texture = _glow()
		_beam_mats[rarity] = m
	return _beam_mats[rarity]


static func _glow_material(rarity: String, color: Color) -> StandardMaterial3D:
	if not _glow_mats.has(rarity):
		var m := _additive_material(color, 0.7)
		m.albedo_texture = _glow()
		_glow_mats[rarity] = m
	return _glow_mats[rarity]


static func _additive_material(color: Color, alpha: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.disable_receive_shadows = true
	m.no_depth_test = false
	m.albedo_color = Color(color.r, color.g, color.b, alpha)
	return m
