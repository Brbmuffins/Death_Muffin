class_name DmLootView
extends Node3D
## Port of src/graphics/LootView.ts: personal loot lying on the ground. Gear/materials wait under a rarity-coloured light pillar until you
## WALK OVER them (loot never flies to the hero); gold and shards still pull in from a few steps away. EVERYTHING expires after
## LOOT_EXPIRE_S (60 s, every rarity incl. prize items); past LOOT_ITEM_CAP items the oldest go early, ordinary before epic/legendary.
## Plus the Settings -> Loot rules (rules/loot/loot_filter.gd): per rarity 'ground' / 'auto' (straight to the bag) / 'gold' (sell value paid).
##
## Usage:  var lv := DmLootView.new(); add_child(lv)
##         lv.drop({"item_id": "...", "quantity": 1, "instance": {...}}, pos)   # item (rules applied)
##         lv.drop({"kind": "gold", "amount": 12}, pos)  /  {"kind": "shard", "amount": 3}
##         var events := lv.tick(delta, hero_pos)        # [{kind:"gold"|"shard"|"item", amount:int, item?:Dictionary, pos:Vector3}]
## The web has no hover/click pickup and no ground labels; `show_labels` (default off) is an optional extra for QA / screenshots.
## NOT ported: the Binbun ground markers / soul orbs, the lightFlash on shards (effects layer) -> the `fx` signal tells the scene when
## to play the pickup puff; warmTasks (a GPU-upload warm-up is a three.js concern).

signal picked(event: Dictionary)          ## gold / shard / item collected by tick()
signal expired(drop: Dictionary, reason: String)  ## reason "ttl" or "cap" (removed without payout)
signal auto_sold(gold: int, drop: Dictionary, pos: Vector3)   ## rule 'gold': sell value paid at once (add it, float "+Ng")
signal auto_looted(drop: Dictionary, pos: Vector3)            ## rule 'auto': went straight into the bag
signal dropped_sound(sound_id: String, pos: Vector3)          ## lootDrop / lootDropRare / lootDropEpic / lootDropLegendary
signal pickup_fx(pos: Vector3, color: Color)                  ## the little particle puff on a gold/shard collect

## Owner 2026-10-04: "if you don't grab it within 1 minute, it goes away".
const LOOT_EXPIRE_S := {"gold": 60.0, "shard": 60.0, "item": 60.0, "prizeItem": 60.0}
const LOOT_ITEM_CAP := 60
const ITEM_PICKUP_RADIUS := 1.3
const ITEM_PICKUP_MIN_AGE := 0.35
const MAGNET_RADIUS := 3.8
const MAGNET_MIN_AGE := 0.45
const COLLECT_RADIUS := 0.5
const LABEL_NEAR := 7.0
const LABEL_NEAR_COMMON := 3.0
const EXPIRY_WARN_S := 8.0       ## the last seconds: the icon blinks (faster in the last 3)
const ITEM_SPACING := 0.65       ## item drops land at least this far apart when there is room

const RARITY_COLORS := {"common": "#b9b2a4", "uncommon": "#8fb98a", "rare": "#8fa6e8", "epic": "#c6a4ff", "legendary": "#ff9a2e"}
const GOLD_COLOR := Color("e2c98f")
const SHARD_COLOR := Color("b58cff")

## Settings -> Loot rules; defaults to every tier 'ground'.
var rules: Dictionary = DmLootFilter.default_rules()
## Optional Callable(slot)->bool: gear worth wearing for you (keepsForYou) so a 'gold' rule leaves it on the ground.
var keep: Callable = Callable()
## Callable(drop)->bool: put it in the bag; false when full (the item then stays until it expires). Used for walk-over pickup and 'auto' rule.
var try_take: Callable = Callable()
## Callable()->float in [0,1) used for scatter (TS Math.random). Empty = randf.
var rand: Callable = Callable()
var show_labels := false   ## always show every name (QA / screenshots)
## Names of the drops near you (rare+ from LABEL_NEAR, ordinary from LABEL_NEAR_COMMON): built the first time you come close, hidden again when you leave.
var near_labels := true

var _drops: Array[Dictionary] = []
var _icon_cache: Dictionary = {}
static var _pile_meshes: Dictionary = {}
static var _shard_mesh: ArrayMesh
static var _glow_tex: Texture2D
static var _placeholder_tex: Texture2D


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
			if d["kind"] == "item":
				gap = minf(gap, Vector2(c.x - d["x"], c.y - d["z"]).length())
		if gap >= ITEM_SPACING:
			return c
		if gap > best_gap:
			best_gap = gap
			best = c
	return best


# ---------------------------------------------------------------- dropping

## Land a drop. Item drop dict = {item_id, quantity, instance?}; gold = {kind:"gold", amount}; shard = {kind:"shard", amount}.
## Items go through the loot rules (gear only) first. `exact` skips the scatter (tests / replaying a recorded position).
## Returns "ground" / "auto" / "gold" (what happened).
func drop(d: Dictionary, pos: Vector3, exact: bool = false) -> String:
	var kind: String = str(d.get("kind", "item"))
	if kind == "gold":
		gold(pos, int(d["amount"]), exact)
		return "ground"
	if kind == "shard":
		shard(pos, int(d["amount"]), exact)
		return "ground"
	var act := item_action(d)
	if act == "gold":
		var slot := _slot_of(d)
		var g := int(slot.get("sell_value", 0)) * int(d.get("quantity", 1))
		auto_sold.emit(g, d, pos)
		return "gold"
	if act == "auto" and try_take.is_valid() and bool(try_take.call(d)):
		auto_looted.emit(d, pos)
		return "auto"
	item(pos, d, exact)  # 'ground', or the bag is full
	return "ground"


## What the rules say for this item drop (non-gear is always 'ground').
func item_action(d: Dictionary) -> String:
	var slot := _slot_of(d)
	if slot.is_empty():
		return "ground"
	return DmLootFilter.loot_action(slot, rules, keep)


func _slot_of(d: Dictionary) -> Dictionary:
	var s: Variant = DmLoot.add_to_slots([], d)
	if s == null or (s as Array).is_empty():
		return {}
	var slot: Dictionary = (s as Array)[0]
	if d.has("instance"):
		slot["inst"] = d["instance"]
	return slot


func gold(pos: Vector3, amount: int, exact: bool = false) -> void:
	if amount <= 0:
		return
	var p := Vector2(pos.x, pos.z) if exact else _scatter(pos)
	var mi := MeshInstance3D.new()
	mi.mesh = _pile_mesh(mini(9, 2 + int(floor(amount / 4.0))))
	mi.material_override = _gold_material()
	mi.rotation.y = _r() * TAU
	mi.position = Vector3(p.x, 0, p.y)
	add_child(mi)
	_drops.append({"kind": "gold", "node": mi, "x": p.x, "z": p.y, "amount": amount, "t": 0.0, "flying": false, "ttl": LOOT_EXPIRE_S["gold"], "prize": false})


func shard(pos: Vector3, amount: int, exact: bool = false) -> void:
	for i in amount:
		var p := Vector2(pos.x, pos.z) if exact else _scatter(pos, 0.6)
		var mi := MeshInstance3D.new()
		mi.mesh = _get_shard_mesh()
		mi.material_override = _shard_material()
		mi.position = Vector3(p.x, 0.5, p.y)
		add_child(mi)
		var light := OmniLight3D.new()
		light.light_color = Color("a26bff")
		light.light_energy = 0.6
		light.omni_range = 2.2
		mi.add_child(light)
		_drops.append({"kind": "shard", "node": mi, "x": p.x, "z": p.y, "amount": 1, "t": 0.0, "flying": false, "ttl": LOOT_EXPIRE_S["shard"], "prize": false})


func item(pos: Vector3, d: Dictionary, exact: bool = false) -> void:
	var p := Vector2(pos.x, pos.z) if exact else _scatter_apart(pos, 0.7)
	var meta := DmContent.item(str(d["item_id"]))
	var rarity := rarity_of(d)
	var color := Color(RARITY_COLORS[rarity])
	var prize := is_prize(rarity)
	dropped_sound.emit("lootDropLegendary" if rarity == "legendary" else "lootDropEpic" if rarity == "epic" else "lootDropRare" if rarity == "rare" else "lootDrop", Vector3(p.x, 0, p.y))
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
		var bm := _additive_material(color, 0.5 if rarity == "legendary" else 0.35)
		bm.albedo_texture = _glow()
		beam.material_override = bm
		root.add_child(beam)
	# ground glow decal (r 0.9, additive)
	var glow := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(1.8, 1.8)
	q.orientation = PlaneMesh.FACE_Y
	glow.mesh = q
	glow.position.y = 0.03
	var gm := _additive_material(color, 0.7)
	gm.albedo_texture = _glow()
	glow.material_override = gm
	root.add_child(glow)
	var lab: Label3D = _make_label(root, d, meta, color) if show_labels else null
	_drops.append({"kind": "item", "node": root, "icon": icon, "beam": beam, "label": lab, "meta": meta, "color": color, "common": rarity == "common", "x": p.x, "z": p.y, "amount": int(d.get("quantity", 1)), "item": d, "t": 0.0, "flying": false,
		"ttl": LOOT_EXPIRE_S["prizeItem"] if prize else LOOT_EXPIRE_S["item"], "prize": prize, "beam_alpha": 0.5 if rarity == "legendary" else 0.35})


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


# ---------------------------------------------------------------- per frame

## Advance drops; returns what the hero collected this frame (events in the order picked). hero_pos uses x/z.
func tick(dt: float, hero_pos: Vector3) -> Array[Dictionary]:
	var events: Array[Dictionary] = []
	var px := hero_pos.x
	var pz := hero_pos.z
	# Too many items: the oldest expire now (array is in drop order), ordinary ones before epic/legendary.
	var surplus := -LOOT_ITEM_CAP
	for d in _drops:
		if d["kind"] == "item":
			surplus += 1
	for prize_too in [false, true]:
		var i := 0
		while i < _drops.size() and surplus > 0:
			var d: Dictionary = _drops[i]
			if d["kind"] == "item" and (prize_too or not d["prize"]):
				_remove(i, "cap")
				surplus -= 1
			else:
				i += 1
	var i := _drops.size() - 1
	while i >= 0:
		var d: Dictionary = _drops[i]
		i -= 1
		d["t"] += dt
		if d["t"] > d["ttl"] and not d["flying"]:
			_remove(i + 1, "ttl")
			continue
		var dist := Vector2(px - d["x"], pz - d["z"]).length()
		var node: Node3D = d["node"]
		if d["kind"] == "item":
			(d["icon"] as Node3D).position.y = 0.7 + sin(d["t"] * 2.5) * 0.08
			var left: float = d["ttl"] - d["t"]
			(d["icon"] as Node3D).visible = left > EXPIRY_WARN_S or fmod(left, 0.5 if left > 3.0 else 0.25) > 0.12
			if near_labels:
				var near := dist < (LABEL_NEAR_COMMON if d["common"] else LABEL_NEAR)
				var lb: Label3D = d["label"]
				if lb == null and near:
					d["label"] = _make_label(node, d["item"], d["meta"], d["color"])
				elif lb != null and lb.visible != (near or show_labels):
					lb.visible = near or show_labels
			if d["beam"] != null:
				((d["beam"] as MeshInstance3D).material_override as StandardMaterial3D).albedo_color.a = 0.28 + sin(d["t"] * 3.0) * 0.06
			if dist < ITEM_PICKUP_RADIUS and d["t"] > ITEM_PICKUP_MIN_AGE and (try_take.is_null() or bool(try_take.call(d["item"]))):
				var ev := {"kind": "item", "amount": d["amount"], "item": d["item"], "pos": node.position}
				events.append(ev)
				picked.emit(ev)
				_remove(i + 1, "")
			continue
		if d["kind"] == "shard":
			node.rotation.y += dt * 2.0
			if not d["flying"]:
				node.position.y = 0.5 + sin(d["t"] * 3.0) * 0.1
		if not d["flying"] and dist < MAGNET_RADIUS and d["t"] > MAGNET_MIN_AGE:
			d["flying"] = true
		if d["flying"]:
			var k := minf(1.0, dt * (8.0 + d["t"] * 4.0))
			d["x"] += (px - d["x"]) * k
			d["z"] += (pz - d["z"]) * k
			node.position.x = d["x"]
			node.position.z = d["z"]
			node.position.y += (1.0 - node.position.y) * k
			if dist < COLLECT_RADIUS:
				var ev2 := {"kind": d["kind"], "amount": d["amount"], "pos": Vector3(px, 1.0, pz)}
				events.append(ev2)
				picked.emit(ev2)
				pickup_fx.emit(Vector3(px, 1.0, pz), GOLD_COLOR if d["kind"] == "gold" else SHARD_COLOR)
				_remove(i + 1, "")
	return events


func _remove(idx: int, reason: String) -> void:
	var d: Dictionary = _drops[idx]
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


func count() -> int:
	return _drops.size()


func clear_all() -> void:
	while not _drops.is_empty():
		_remove(_drops.size() - 1, "")


## QA: where every drop lies (TS debugDrops).
func debug_drops() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for d in _drops:
		var it: Variant = d.get("item")
		out.append({"kind": d["kind"], "id": null if it == null else it["item_id"], "x": d["x"], "z": d["z"], "ttl": d["ttl"], "prize": d["prize"]})
	return out


# ---------------------------------------------------------------- visuals

func _icon_for(id: String, color: Color) -> Texture2D:
	if _icon_cache.has(id):
		return _icon_cache[id]
	var path := "res://assets/slice/art/items/%s.webp" % id
	var tex: Texture2D = load(path) if ResourceLoader.exists(path) else _placeholder(color)
	_icon_cache[id] = tex
	return tex


## Stand-in icon (no item art is synced to godot/assets yet): a rounded rarity-tinted tile.
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


static var _gold_mat: StandardMaterial3D
static func _gold_material() -> StandardMaterial3D:
	if _gold_mat == null:
		_gold_mat = StandardMaterial3D.new()
		_gold_mat.albedo_color = Color("c9a24a")
		_gold_mat.metallic = 0.85
		_gold_mat.roughness = 0.35
		_gold_mat.emission_enabled = true
		_gold_mat.emission = Color("3a2808")
		_gold_mat.emission_energy_multiplier = 0.4
	return _gold_mat


static var _shard_mat: StandardMaterial3D
static func _shard_material() -> StandardMaterial3D:
	if _shard_mat == null:
		_shard_mat = StandardMaterial3D.new()
		_shard_mat.albedo_color = Color("b58cff")
		_shard_mat.emission_enabled = true
		_shard_mat.emission = Color("7c3aed")
		_shard_mat.emission_energy_multiplier = 2.2
		_shard_mat.roughness = 0.2
		_shard_mat.metallic = 0.1
	return _shard_mat


## A pile of n coins (cylinder r 0.09, h 0.025) as one merged mesh, built once per size.
static func _pile_mesh(n: int) -> ArrayMesh:
	if _pile_meshes.has(n):
		return _pile_meshes[n]
	var coin := CylinderMesh.new()
	coin.top_radius = 0.09
	coin.bottom_radius = 0.09
	coin.height = 0.025
	coin.radial_segments = 10
	coin.rings = 1
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in n:
		var b := Basis.from_euler(Vector3((randf() - 0.5) * 0.4, randf() * 3.0, (randf() - 0.5) * 0.4))
		st.append_from(coin, 0, Transform3D(b, Vector3((randf() - 0.5) * 0.35, 0.02 + i * 0.02, (randf() - 0.5) * 0.35)))
	var m := st.commit()
	_pile_meshes[n] = m
	return m


## Octahedron r 0.18 stretched (0.6, 1.4, 0.6).
static func _get_shard_mesh() -> ArrayMesh:
	if _shard_mesh == null:
		var r := 0.18
		var v := [Vector3(r * 0.6, 0, 0), Vector3(-r * 0.6, 0, 0), Vector3(0, r * 1.4, 0), Vector3(0, -r * 1.4, 0), Vector3(0, 0, r * 0.6), Vector3(0, 0, -r * 0.6)]
		var faces := [[2, 0, 4], [2, 4, 1], [2, 1, 5], [2, 5, 0], [3, 4, 0], [3, 1, 4], [3, 5, 1], [3, 0, 5]]
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for f in faces:
			for k in 3:
				st.add_vertex(v[f[k]])
		st.generate_normals()
		_shard_mesh = st.commit()
	return _shard_mesh
