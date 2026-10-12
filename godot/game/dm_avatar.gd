class_name DmAvatar
extends Node3D
## The necromancer hero, local or remote (port of NecromancerAvatar in archive/legacy-web:src/graphics/Avatars.ts): one model per discipline (hero_<id>),
## the discipline colours the staff light and robe glow; worn gear shows as a weapon / off-hand prop, a helm and body-region tints;
## gestures (`cast`), gathering tools, the mastery cape. The creature runs in-place (the sim owns position and heading).
##
## Worn gear is real models (`DmGearModels`): weapons and off-hand pieces in the palm (`DmCreature.attach_held`), the tier helm on the head and the set mantle on
## the upper body (`attach_fitted`: seated from the rig's rest pose, sized from the measured head / chest). At 3+ pieces of a legendary set the body itself
## becomes that set's hero model (`_swap_body`, from the `set_look_changed` hook).
##
## Use: var a := DmAvatar.new(); a.setup(world_root, "#a26bff", true, "hero_ossuary"); each frame a.update(dt, x, z, facing, moving, move_speed).
## `settings` = the game settings dictionary (reads hideHelm); call `DmAvatar.refresh_all()` when settings change.

const HERO_TURN_RATE := 12.0
const HERO_TURN_MAX := 13.0
const STAFF_FOLLOW := 0.6   ## (New Blood hero props only)
const TOOL_GRIP := {"woodcutting": -0.3, "mining": -0.15, "fishing": -0.3, "gravedigging": -0.3, "gardening": -0.3}
const TOOL_TINT := [0xb87333, 0x9097a0, 0xdfe4ee, 0x7a98b0, 0xd0452f, 0xaec8ff]
const TOOLS := {
	"woodcutting": {"id": "tool_hatchet", "length": 0.95}, "mining": {"id": "tool_pickaxe", "length": 1.2},
	"fishing": {"id": "tool_fishing_rod", "length": 1.45}, "gravedigging": {"id": "tool_spade", "length": 1.2},
	"gardening": {"id": "tool_spade", "length": 1.2},
}
const NEW_BLOOD := ["hero_hollow_knight", "hero_grave_warden", "hero_bell_monk", "hero_carrion_witch", "hero_veilwalker"]
## rigHeads.ts: what each rig's own head is ('covered' = hood / helmet already there: the helm shows as tint).
const RIG_HEAD := {
	"hero_ossuary": "covered", "hero_gravecaller": "covered", "hero_mourner": "covered", "hero_rotweaver": "covered", "hero_reaper": "covered",
	"hero_hollow_knight": "covered", "hero_grave_warden": "covered", "hero_veilwalker": "covered", "hero_carrion_witch": "covered", "hero_bell_monk": "covered",
	"hero_leg_colossus_mantle": "covered", "hero_leg_legion_unburied": "covered", "hero_leg_plague_choir": "covered", "hero_leg_requiem_wraiths": "covered",
}
## The helm model is this much taller than the measured head (hood and all), and sits this far (metres) above its centre; the mantle is this much wider than the chest.
const HELM_FIT := 1.5
const HELM_OVER := 0.03
const MANTLE_FIT := 1.65
const MANTLE_LIFT := 0.06
const HEAD_BONES := ["Head"]
const CHEST_BONES := ["Spine02", "Spine01", "L_Clavicle", "R_Clavicle"]
const RIG_HEAD_STRENGTH := {"hero_bell_monk": 0.25}   ## (a cap: other heads use the rarity's tint strength)
# castClips.ts
const MIN_SECONDS := {"slam": 0.55, "sweep": 0.42, "flick": 0.26, "channel": 0.9, "summon": 0.7}
## The Reaper's rites -> the hero rig's combat clips (measured on hero_mourner: sweep 1.4 s, slam 2.0 s, flick 1.03 s, channel 1.6 s, summon 1.6 s).
const REAPER_CLIPS := {"scythe_sweep": "sweep", "harvest_spin": "sweep", "reap": "slam", "scythe_throw": "flick", "wraith_walk": "channel", "soul_burst": "summon", "unleash_souls": "summon"}
## Worn set pieces that step the set's aura up (DmGearFx.AURA_MOTES): 2 = level 1, 4 = level 2. From 3 pieces on `set_look` also switches the set's colour scheme on.
const SET_AURA_STEPS := [2, 4]
const SET_SCHEME_PIECES := 3
const MAX_SPEED := 3.2
const MIN_SPEED := 0.7

static var _live: Array = []

## The set look changed (set id "" and 0 pieces = none). The full-set models (mantles, ...) connect here: pieces >= 3 is their cue.
signal set_look_changed(set_id: String, pieces: int)

var c: DmCreature
var lantern: OmniLight3D = null
var slug := "necromancer"           ## the hero's own body (its discipline's); `body_slug` is the one showing now (a legendary set's while it is worn)
var body_slug := "necromancer"
var accent_hex := 0xa26bff
var settings: Dictionary = {}
var cast_lock := 0.0
## Metal tier of the tool each hand model shows (skill -> tier).
var gathering_tool_tier: Dictionary = {}

var _staff: Node3D = null
var _reaper := false                 ## the Reaper: whatever she wields shows as her scythe
var _class_gear: Array = []
var _default_hand: Dictionary = {}   # Node3D -> "main_hand" | "off_hand"
var _worn: Dictionary = {}           # slot -> {obj, key}
var _cape: Variant = null            # {obj, id}
var _sway_t := randf() * 6.0
var _head_tint: Variant = null
var _downed := false
var _cape_fade := 1.0
var _gathering_skill := ""
var _gathering_tools: Dictionary = {}
var _tool_tier := 0
var _disposed := false
var _tip_obj: Node3D = null
var _moving := false
var _has_last := false
var _last_x := 0.0
var _last_z := 0.0
var _ground_speed := 0.0
var _helm_want := ""
var _element := ""                   ## the weapon's element override (socketed runes); "" = the weapon's own tier
var _main_rarity := ""
var set_id := ""                     ## the set whose look is on (see set_look)
var set_pieces := 0
var _mounts: Dictionary = {}         # prop Node3D -> {bone, mode: "held" | "fitted" | "plain" | "dir", arg}: what `_swap_body` re-seats on the new body
var _opts: Dictionary = {}
var _helm_item: Dictionary = {}     # the worn head item (re-fitted on a new body)
var _mantle: Variant = null          # {obj, set}
var _region_tints: Dictionary = {}   # region -> tint (replayed on a new body)
var _aura: CPUParticles3D = null
var _aura_level := 0
var _scheme_glow: Variant = null     ## the set's trim glow colour while its scheme is on


## Rebuild the visibility of default props / worn gear for every live hero (the Hide helms setting reaches own and remote avatars).
static func refresh_all() -> void:
	for a in _live:
		if is_instance_valid(a):
			a.apply_gear_visibility()

static func _hex(v: Variant) -> int:
	if v is String:
		return Color.html(v).to_rgba32() >> 8
	return int(v)

func setup(parent: Node, accent: Variant = 0xa26bff, with_light: bool = false, model_slug: String = "necromancer", family: String = "") -> void:
	slug = model_slug
	body_slug = model_slug
	_reaper = family == "reaper"
	accent_hex = _hex(accent)
	name = "Avatar_" + model_slug
	_opts = {"in_place": true, "gear_tint": true, "emissive": accent_hex, "emissive_intensity": 0.04, "fallback": "necromancer", "locomotion_fade": 0.16}
	c = DmCreature.new(model_slug, _opts)
	add_child(c.root)
	if parent != null:
		parent.add_child(self)
	if NEW_BLOOD.has(model_slug):
		_attach_class_gear(model_slug)
	else:
		_staff = (DmGearProps.scythe_model() if _reaper else null)   # the Reaper carries her scythe, not the skull staff
		if _staff == null:
			_staff = _default_staff(accent_hex)
		_mount(_staff, "R_Hand", "held", DmGearProps.hold_spec("scythe" if _reaper else "default_staff"))
		_default_hand[_staff] = "main_hand"
		_refresh_weapon_fx()
		set_look_changed.connect(_on_set_look)
	_live.append(self)
	if with_light:
		lantern = OmniLight3D.new()
		lantern.light_color = DmGearProps.col(accent_hex)
		lantern.light_energy = 18.0 * 0.12
		lantern.omni_range = 10.0
		lantern.omni_attenuation = 1.4
		lantern.position = Vector3(0, 3.2, 0.6)
		c.root.add_child(lantern)

## The default staff: the bone-tier staff model with the discipline's soul-light at its head (the code-built skull staff when the model is absent).
func _default_staff(accent: int) -> Node3D:
	var g := DmGearModels.weapon("staff", "bone")
	if g != null:
		var glow := DmGearProps.glow_sprite(accent, 0.42, 0.8)
		var tip := g.get_meta("tip") as Node3D
		glow.position = tip.position
		g.add_child(glow)
		g.set_meta("tip", glow)
		return g
	g = Node3D.new()
	g.add_child(DmGearProps._mi(DmGearProps._cyl(0.025, 0.035, 1.9, 6), DmGearProps._mat(0x2b211c, 0.0, 0.85), Vector3(0, 0.35, 0)))
	var skull := DmGearProps._mi(DmGearProps._sph(0.1), DmGearProps._mat(0xd8cfbd, 0.0, 0.7), Vector3(0, 1.35, 0))
	skull.scale = Vector3(1, 1.1, 1.15)
	g.add_child(skull)
	var glow2 := DmGearProps.glow_sprite(accent, 0.55, 1.0)
	glow2.position.y = 1.36
	g.add_child(glow2)
	g.set_meta("tip", glow2)
	return g

## Seat a prop on the body and remember how, so a body swap can move it. mode: "held" (hand grip spec), "fitted" (rest-pose spec), "plain", "dir" (aimed, arg = direction).
func _mount(obj: Node3D, bone: String, mode: String, arg: Variant = null) -> void:
	_mounts[obj] = {"bone": bone, "mode": mode, "arg": arg}
	_seat(c, obj, _mounts[obj])

func _seat(body: DmCreature, obj: Node3D, m: Dictionary) -> void:
	match m.mode:
		"held": body.attach_held(m.bone, obj, m.arg)
		"fitted": body.attach_fitted(m.bone, obj, m.arg)
		"dir": body.attach(m.bone, obj, m.arg)
		_: body.attach(m.bone, obj)

func _unmount(obj: Node3D) -> void:
	c.detach(obj)
	_mounts.erase(obj)

## New Blood heroes use their authored gear or bare hands (class gear models: props/gear_*.glb, absent from the slice assets => none).
func _attach_class_gear(model_slug: String) -> void:
	if model_slug == "hero_veilwalker":
		for bone in ["R_Hand", "L_Hand"]:
			var glow := DmGearProps.glow_sprite(0x85efff, 0.28, 0.72)
			c.attach(bone, glow)
			_class_gear.append(glow)
			_default_hand[glow] = "main_hand" if bone == "R_Hand" else "off_hand"
			if bone == "R_Hand":
				_tip_obj = glow
		return
	var gear: Array = []
	match model_slug:
		"hero_hollow_knight":
			gear = [["R_Hand", "gear_knight_sword", 1.05, true, 0.6], ["L_Hand", "gear_knight_shield", 0.62, false, 0.5]]
		"hero_grave_warden":
			gear = [["R_Hand", "gear_warden_flail", 1.1, true, 0.6], ["L_Hand", "gear_warden_lantern", 0.7, false, 0.5]]
		"hero_bell_monk":
			gear = [["R_Hand", "gear_monk_bell_staff", 1.65, true, STAFF_FOLLOW]]
		"hero_carrion_witch":
			gear = [["R_Hand", "gear_witch_hook", 0.9, true, 0.6]]
	for g in gear:
		var obj := _load_prop(String(g[1]), float(g[2]))
		if obj == null:
			continue
		c.attach(g[0], obj, Vector3(0, 1, 0.1), g[4])
		_class_gear.append(obj)
		_default_hand[obj] = "main_hand" if g[0] == "R_Hand" else "off_hand"
		if g[3]:
			_tip_obj = obj
	apply_gear_visibility()

## A prop GLB (models/props/<id>.glb) scaled to `height`, or null when the asset is absent.
func _load_prop(id: String, height: float, by_longest := false) -> Node3D:
	return DmGearProps.load_prop(id, height, by_longest)

func _hide_helm() -> bool:
	return bool(settings.get("hide_helm", false))

## Show the matching hand tool while gathering, then restore class gear.
func set_gathering_tool(skill: String, tier := 0) -> void:
	if _disposed:
		return
	_tool_tier = tier
	if skill != "" and _gathering_tools.has(skill) and gathering_tool_tier.get(skill, -1) != tier:
		_tint_tool(skill, _gathering_tools[skill], tier)
	if _gathering_skill == skill:
		return
	_gathering_skill = skill
	apply_gear_visibility()
	for id in _gathering_tools:
		(_gathering_tools[id] as Node3D).visible = id == skill
	if skill == "" or _gathering_tools.has(skill):
		return
	var tool: Dictionary = TOOLS[skill]
	var obj := _load_prop(String(tool.id), float(tool.length), true)
	if obj == null:
		return   # tools/*.glb are not in the slice assets: nothing to show (the web shows nothing while its model loads / fails)
	var inner: Node3D = obj.get_child(0)
	var grip: float = TOOL_GRIP[skill]
	inner.position.y += -grip * float(tool.length)
	obj.visible = _gathering_skill == skill
	_mount(obj, "R_Hand", "dir", Vector3(0, 1, 0.1))
	_gathering_tools[skill] = obj
	_tint_tool(skill, obj, _tool_tier)

## The hand model is one mesh per kind; the carried metal tints it (copper, iron, silver, steel, hellsteel, moonsilver).
func _tint_tool(skill: String, obj: Node3D, tier: int) -> void:
	gathering_tool_tier[skill] = tier
	if tier < 1 or tier > TOOL_TINT.size():
		return
	var metal := DmGearProps.col(TOOL_TINT[tier - 1])
	for m in obj.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		for s in mi.mesh.get_surface_count():
			var src := mi.mesh.surface_get_material(s)
			if src is BaseMaterial3D:
				var mat := (src as BaseMaterial3D).duplicate() as BaseMaterial3D
				if not mat.has_meta("base_color"):
					mat.set_meta("base_color", mat.albedo_color)
				mat.albedo_color = (mat.get_meta("base_color") as Color).lerp(metal, 0.4)
				mi.set_surface_override_material(s, mat)

## Default props show unless a gathering tool is out or an equipped item took their hand; worn gear hides while gathering.
func apply_gear_visibility() -> void:
	var idle := _gathering_skill == ""
	var defaults: Array = ([_staff] if _staff != null else []) + _class_gear
	for obj in defaults:
		if not is_instance_valid(obj):
			continue
		var hand: Variant = _default_hand.get(obj)
		(obj as Node3D).visible = idle and not _downed and not (hand != null and _worn.has(hand))
	for slot in _worn:
		var w: Dictionary = _worn[slot]
		(w.obj as Node3D).visible = idle and not (_hide_helm() if slot == "head" else _downed)
	c.set_head_tint(_head_tint if (idle and not _hide_helm()) else null)
	if _aura != null:
		_aura.visible = idle and not _downed
	if _cape != null:
		(_cape.obj as Node3D).visible = idle and _cape_fade > 0.01
	if _mantle != null:
		(_mantle.obj as Node3D).visible = idle and not _downed

## Show equipped gear on the model: weapon in the right hand, off-hand piece in the left, helm on the head, body slots as tints.
## `items`: slot id -> {item_id, rarity?}. Only changed slots are rebuilt.
func set_equipment(items: Dictionary) -> void:
	if _disposed:
		return
	for want in [["main_hand", "R_Hand"], ["off_hand", "L_Hand"], ["head", "Head"]]:
		var slot: String = want[0]
		var bone: String = want[1]
		var item: Variant = items.get(slot)
		var cur: Variant = _worn.get(slot)
		if slot == "head" and item == null:
			_helm_want = ""
		var key: Variant = item.get("item_id") if item is Dictionary else null
		if cur != null and cur.key == key and (slot != "main_hand" or String(cur.get("rarity", "")) == String(item.get("rarity", "") if item is Dictionary else "")):
			continue
		if slot == "head":
			_head_tint = null   # only when the helm changes: any later inventory change calls this again and must keep the worn helm's tint
		if cur != null:
			_unmount(cur.obj)
			DmGearProps.dispose_prop(cur.obj)
			_worn.erase(slot)
			if slot == "main_hand":
				_main_rarity = ""
		if item == null:
			if slot == "main_hand":
				_refresh_weapon_fx()
			continue
		if slot == "head":
			_helm_want = String(item.item_id)
			var it: Dictionary = item
			c.after_load(func(): _mount_helm(it))
			continue
		var rarity := String(item.get("rarity", ""))
		var obj: Node3D = DmGearProps.build_offhand(item.item_id, rarity) if slot == "off_hand" else DmGearProps.build_weapon(item.item_id, rarity)
		var kind := DmGearProps.hold_kind(slot, String(item.item_id))
		if _reaper and slot == "main_hand":
			var scythe := DmGearProps.scythe_model()   # her weapon is always the scythe, whatever the bag row says
			if scythe != null:
				DmGearProps.dispose_prop(obj)
				obj = scythe
				kind = "scythe"
		_mount(obj, bone, "held", DmGearProps.hold_spec(kind, slot == "off_hand"))
		_worn[slot] = {"obj": obj, "key": item.item_id, "rarity": rarity}
		if slot == "main_hand":
			_main_rarity = rarity
			_refresh_weapon_fx()
	# Body slots have no prop: they tint their region of the body lightly by material tier (the texture keeps its detail; trim and rim carry the glow).
	var best := _best_set(items)
	set_look(best[0], best[1])
	var chest: Variant = items.get("chest")
	_set_mantle(DmGearModels.mantle_set_of(String(chest.item_id)) if chest is Dictionary else "")
	for pair in [["chest", "chest"], ["legs", "legs"], ["hands", "hands"], ["feet", "feet"]]:
		var it2: Variant = items.get(pair[1])
		if it2 == null:
			_region_tints.erase(pair[0])
			c.set_region_tint(pair[0], null)
		else:
			var rarity2 := String(it2.get("rarity", ""))
			var t := DmGearProps.tier(String(it2.item_id), rarity2)
			var glow: Variant = _scheme_glow if _scheme_glow != null else (t.glow if int(t.glow) >= 0 else DmGearProps._dim(int(t.color), 0.3))
			_region_tints[pair[0]] = {"color": t.color, "glow": glow, "strength": float(DmGearFx.look_of(rarity2).tint)}
			c.set_region_tint(pair[0], _region_tints[pair[0]])
	apply_gear_visibility()

## The weapon in hand shows its rarity glow and element (the socketed runes' if set, else its metal tier's); the default staff only the element.
func _refresh_weapon_fx() -> void:
	var mh: Variant = _worn.get("main_hand")
	if mh != null:
		DmGearFx.dress_weapon(mh.obj, _main_rarity, DmGearFx.element_for(String(mh.key), _element))
	if _staff != null:
		DmGearFx.dress_weapon(_staff, "", "" if mh != null else _element)   # the staff under a worn weapon shows nothing

## The element the socketed runes give the weapon ("" = its own tier's); `DmGearFx.ELEMENTS` keys.
func set_weapon_element(element: String) -> void:
	if _disposed or element == _element or (element != "" and not DmGearFx.valid_element(element)):
		return
	_element = element
	_refresh_weapon_fx()

## The set with the most worn pieces (ties: the first found) -> [set_id, pieces] (["", 0] when nothing is worn).
func _best_set(items: Dictionary) -> Array:
	var count: Dictionary = {}
	for it in items.values():
		if it == null:
			continue
		var p := DmGearProps.armor_by_id(String(it.item_id))
		if not p.is_empty():
			count[p.setId] = int(count.get(p.setId, 0)) + 1
	var best := ["", 0]
	for id in count:
		if count[id] > best[1]:
			best = [id, count[id]]
	return best

## Dress the hero in a worn set: `pieces` of set `id_` (0 / "" = none). 2 pieces light a faint aura, 4 a full one; from SET_SCHEME_PIECES (3) the
## set's colour scheme (its accent as the trim glow of every worn piece) is on too. The full-set models plug in through `set_look_changed`.
func set_look(id_: String, pieces: int) -> void:
	if _disposed:
		return
	if id_ == "" or pieces < SET_AURA_STEPS[0]:
		id_ = ""
		pieces = 0
	if id_ == set_id and pieces == set_pieces:
		return
	var rebuild_aura := id_ != set_id or _aura_level != _aura_level_for(pieces)
	set_id = id_
	set_pieces = pieces
	var accent := 0
	var legendary := false
	for p in DmContent.get_export("armorSets", "ARMOR_PIECES"):
		if p.setId == id_:
			accent = int(p.accent)
			legendary = int(p.collection) == 3
			break
	if legendary and pieces >= SET_AURA_STEPS[0]:
		DmGearModels.prefetch(DmGearModels.legendary_slug(id_))   # the body swap at 3 pieces then finds the model loaded
	_aura_level = _aura_level_for(pieces) if id_ != "" else 0
	_scheme_glow = DmGearProps._dim(accent, 0.5 if legendary else 0.3) if (id_ != "" and pieces >= SET_SCHEME_PIECES) else null
	if rebuild_aura:
		if _aura != null:
			c.root.remove_child(_aura)
			_aura.queue_free()
			_aura = null
		if _aura_level > 0:
			_aura = DmGearFx.build_aura(DmGearProps.col(accent), _aura_level)
			c.root.add_child(_aura)
			_aura.visible = _gathering_skill == "" and not _downed
	set_look_changed.emit(set_id, set_pieces)

## The legendary hero body of the worn set look ("" = the hero's own).
func _look_body() -> String:
	if set_id == "" or set_pieces < SET_SCHEME_PIECES or NEW_BLOOD.has(slug) or _reaper:   # (the Reaper keeps her own body: aura and colours only)
		return slug
	var legendary := DmGearModels.legendary_slug(set_id)
	return legendary if legendary != "" else slug

func _on_set_look(_id: String, _pieces: int) -> void:
	var want := _look_body()
	if want != body_slug and not _disposed:
		_swap_body(want)

## Rebuild the hero's body from another model (a legendary set's hero, or back), keeping what it carries: held props, helm, mantle, cape, aura, lantern, tints,
## position / heading and the walk / idle. A one-shot in progress (a cast) is dropped, the body returns to its loop.
func _swap_body(new_slug: String) -> void:
	var nc := DmCreature.new(new_slug, _opts)
	if nc.skeleton == null or nc.rig_slug != new_slug:
		nc.dispose()   # model absent: the hero keeps the body it has
		return
	var old := c
	add_child(nc.root)
	move_child(nc.root, old.root.get_index())
	nc.root.transform = old.root.transform
	var refit: Array = []   # the helm and the mantle are sized from the head / chest: made again for the new body
	if _worn.has("head") and _mounts.has(_worn.head.obj):
		refit.append(_worn.head.obj)
	if _mantle != null:
		refit.append(_mantle.obj)
	for obj: Node3D in _mounts.keys():
		old.detach(obj)
		if refit.has(obj):
			continue
		obj.scale = Vector3.ONE   # (the seat scales a prop by the bone chain's scale: from a clean 1)
		_seat(nc, obj, _mounts[obj])
	for n: Node in [lantern, _aura]:
		if n != null:
			old.root.remove_child(n)
			nc.root.add_child(n)
	c = nc
	body_slug = new_slug
	for obj: Node3D in refit:
		_mounts.erase(obj)
		DmGearProps.dispose_prop(obj)
	if refit.has(_worn.get("head", {}).get("obj")):
		_worn.erase("head")
		_mount_helm(_helm_item)
	if _mantle != null and refit.has(_mantle.obj):
		var ms: String = _mantle.set
		_mantle = null
		_set_mantle(ms)
	for region in _region_tints:
		c.set_region_tint(region, _region_tints[region])
	if _head_tint != null:
		c.set_head_tint(_head_tint)
	old.dispose()
	if _moving:
		c.set_ground_speed(_ground_speed)
	_downed = false
	apply_gear_visibility()

func _aura_level_for(pieces: int) -> int:
	return 0 if pieces < SET_AURA_STEPS[0] else (2 if pieces >= SET_AURA_STEPS[1] else 1)

func _mount_helm(item: Dictionary) -> void:
	if _disposed or _helm_want != String(item.item_id):
		return
	var cur: Variant = _worn.get("head")
	if cur != null and cur.key == item.item_id:
		return
	if RIG_HEAD.get(body_slug, "bare") == "covered":
		# The rig already has a hood, cowl or helmet: the helm model sits over it, and the head region keeps a faint trim tint.
		var t := DmGearProps.tier(String(item.item_id), String(item.get("rarity", "")))
		var set := DmGearProps.armor_by_id(String(item.item_id))
		_head_tint = {"color": int(set.accent) if not set.is_empty() else t.color, "glow": t.glow if int(t.glow) >= 0 else null, "strength": minf(float(RIG_HEAD_STRENGTH.get(body_slug, 1.0)), float(DmGearFx.look_of(String(item.get("rarity", ""))).tint) * 0.4)}
		var obj := _helm_model(DmGearModels.helm_tier_of(String(item.item_id), String(item.get("rarity", ""))))
		_helm_item = item
		_worn["head"] = {"obj": obj if obj != null else Node3D.new(), "key": item.item_id}
		if obj != null:
			_mount(obj, "Head", "fitted", _head_spec(obj.get_meta("height")))
		apply_gear_visibility()
		return
	mount_dome(item)

## The helm model of a tier, `HELM_FIT` times the measured head's height.
func _helm_model(tier: String) -> Node3D:
	var fit := c.region_fit("Head", HEAD_BONES)
	var row: Dictionary = DmGearModels.table().get("helm_by_tier", {}).get(tier, {})
	var h := (fit.size.y * HELM_FIT) if fit.size.y > 0.0 else float(row.get("height_m", 0.27))
	var g := DmGearModels.helm(tier, h)
	if g != null:
		g.set_meta("height", h)
	return g

func _head_spec(h: float) -> Dictionary:
	var fit := c.region_fit("Head", HEAD_BONES)
	var centre := fit.get_center() if fit.size.y > 0.0 else Vector3(0, 0.14, 0)
	return {"offset": Vector3(centre.x, fit.end.y + HELM_OVER - h * 0.5, centre.z) if fit.size.y > 0.0 else centre}

## Wear the set's mantle on the upper body ("" = none): a model sized to the measured chest, seated from the rig's rest pose on Spine02.
func _set_mantle(set: String) -> void:
	if (_mantle.set if _mantle != null else "") == set:
		return
	if _mantle != null:
		_unmount(_mantle.obj)
		DmGearProps.dispose_prop(_mantle.obj)
		_mantle = null
	if set == "":
		return
	var fit := c.region_fit("Spine02", CHEST_BONES)
	var row: Dictionary = DmGearModels.table().get("mantle_by_set_id", {}).get(set, {})
	var width := (fit.size.z * MANTLE_FIT) if fit.size.z > 0.0 else float(row.get("width_m", 0.42))
	var obj := DmGearModels.mantle(set, width)
	if obj == null:
		return
	var centre := fit.get_center() if fit.size.z > 0.0 else Vector3.ZERO
	_mount(obj, "Spine02", "fitted", {"offset": centre + Vector3(0, MANTLE_LIFT, 0)})
	_mantle = {"obj": obj, "set": set}
	obj.visible = _gathering_skill == "" and not _downed

## The helm dome on a bare-headed rig. (The web seats it on a measured head fit; head_fit is not ported, no shipped hero is bare-headed.)
func mount_dome(item: Dictionary) -> void:
	var old: Variant = _worn.get("head")
	if old != null:
		_unmount(old.obj)
		DmGearProps.dispose_prop(old.obj)
		_worn.erase("head")
	_head_tint = null
	var obj := DmGearProps.build_helm(String(item.item_id), String(item.get("rarity", "")), 1.0)
	_mount(obj, "Head", "plain")
	_worn["head"] = {"obj": obj, "key": item.item_id}
	apply_gear_visibility()

## Put a cape on (or take it off with ""). Hidden while a gathering tool is out, like the rest of the worn gear.
func set_cape(id: String) -> void:
	if _disposed or (_cape.id if _cape != null else "") == id:
		return
	if _cape != null:
		_unmount(_cape.obj)
		DmGearProps.dispose_prop(_cape.obj)
		_cape = null
	if id == "":
		return
	var def: Dictionary = {}
	for cp in DmContent.get_export("cosmetics", "CAPES"):
		if cp.id == id:
			def = cp
	if def.is_empty():
		return
	var obj := DmGearProps.build_cape(int(def.color), int(def.trim))
	_mount(obj, "Spine02", "plain")
	_cape = {"obj": obj, "id": id}
	_cape_fade = 0.0 if _downed else 1.0
	obj.visible = _gathering_skill == "" and _cape_fade > 0.01

## World position of the staff tip (spell origin).
func tip() -> Vector3:
	var t: Variant = null
	var mh: Variant = _worn.get("main_hand")
	if mh != null and mh.obj.has_meta("tip"):
		t = mh.obj.get_meta("tip")
	elif _staff != null and _staff.has_meta("tip"):
		t = _staff.get_meta("tip")
	else:
		t = _tip_obj
	if t != null and is_instance_valid(t) and (t as Node3D).is_inside_tree():
		return (t as Node3D).global_position
	return Vector3(c.root.position.x, 1.6, c.root.position.z)

func update(dt: float, x: float, z: float, facing: float, moving: bool, speed: float) -> void:
	c.root.position = Vector3(x, 0, z)
	c.root.rotation.y = DmEntityViews.turn_toward(c.root.rotation.y, facing, dt, HERO_TURN_RATE, HERO_TURN_MAX)
	# Real ground speed from the frame's displacement (a teleport reads as standing still); the walk / run clip is played at the pace
	# that matches it, so the feet stay planted whatever the hero's move-speed stats are.
	var inst := speed if not _has_last else DmEntityViews.step_speed(x - _last_x, z - _last_z, dt)
	_has_last = true
	_last_x = x
	_last_z = z
	_ground_speed = DmEntityViews.smooth_speed(_ground_speed if _ground_speed != 0.0 else inst, inst, dt, 0.12) if moving else 0.0
	if moving != _moving:
		_moving = moving
		if moving:
			_ground_speed = speed
			c.set_ground_speed(speed)
			c.release_gesture()
		else:
			c.set_loop("idle")
	elif moving:
		c.set_ground_speed(_ground_speed)
	cast_lock = maxf(0.0, cast_lock - dt)
	c.update(dt)
	var clip := c.one_shot_name()
	var down := clip != "" and clip.rstrip("0123456789") in ["death", "hurt"]
	if down != _downed:
		_downed = down
		apply_gear_visibility()
	if _cape != null and _cape_fade != (0.0 if down else 1.0):
		_cape_fade = maxf(0.0, _cape_fade - dt / 0.12) if down else minf(1.0, _cape_fade + dt / 0.25)
		(_cape.obj as Node3D).visible = _gathering_skill == "" and _cape_fade > 0.01
	if _cape != null:
		# The cloth trails a little behind a moving hero and breathes when still.
		_sway_t += dt * (5.0 if moving else 1.6)
		(_cape.obj as Node3D).rotation.x = (0.17 if moving else 0.05) + sin(_sway_t) * (0.05 if moving else 0.02)

## Play a one-shot gesture. `attack` is the weapon swing every shipped hero rig carries; the necromancer rites gesture with `cast` or `dig`.
## With an `ability` id and a `duration_s`, the weapon in hand picks a combat clip (castClips.ts) timed so its release frame lands on the rite.
## `tempo` < 1 (haste) shortens the Reaper's swing, including its minimum length.
func cast(kind: String, speed := 2.0, facing: Variant = null, duration_s := 0.0, ability := "", tempo := 1.0) -> void:
	if facing != null:
		c.root.rotation.y = float(facing)
	var choice: Variant = _cast_clip_for(weapon_gesture(), ability) if (ability != "" and duration_s > 0.0) else null
	var clip := c.clip_duration(choice.clip) if choice != null else 0.0
	if choice != null and clip > 0.0:
		var plan := _plan_gesture(choice, duration_s, clip, tempo if _reaper else 1.0)
		c.play_once(choice.clip, plan.speed, 0.0, plan.startAt)
		return
	if kind == "attack" and duration_s > 0.0 and c.clip_duration("attack") > 2.0:
		# The 6.6 s weapon swing squeezed into a rite's window played ~20x; time its measured impact frame to the window instead.
		c.play_strike("attack", duration_s * 0.45)
		return
	c.play_once(kind, speed, duration_s)

func play_once(anim: String, speed := 1.0, duration_s := 0.0, start_at := 0.0) -> bool:
	return c.play_once(anim, speed, duration_s, start_at)

func set_loop(anim: String, speed := 1.0) -> void:
	c.set_loop(anim, speed)

func loop_phase() -> float:
	return c.loop_phase()

## Stand up out of the death pose (respawn).
func revive() -> void:
	c.revive()

func release_gesture() -> void:
	c.release_gesture()

## The weapon kind steering the gesture: the equipped main hand, or 'none' (the default skull staff).
func weapon_gesture() -> String:
	if _reaper:
		return "scythe"
	var mh: Variant = _worn.get("main_hand")
	if mh == null:
		return "none"
	var necro := DmGearProps.necro_by_id(String(mh.key))
	return String(necro.kind) if not necro.is_empty() and necro.kind in ["staff", "scythe", "wand", "sickle"] else DmGearProps.weapon_kind(String(mh.key))

func _cast_clip_for(weapon: String, ability: String) -> Variant:
	if _reaper and REAPER_CLIPS.has(ability):
		var rc: String = REAPER_CLIPS[ability]
		return {"clip": rc, "releaseAt": float(DmContent.file("castClips").CLIP_RELEASE[rc]), "minSeconds": float(MIN_SECONDS[rc])}
	var cc := DmContent.file("castClips")
	var role: Variant = (cc.ABILITY_ROLE as Dictionary).get(ability)
	if role == null:
		return null
	var clip: Variant = ((cc.WEAPON_CLIPS as Dictionary).get(weapon, {}) as Dictionary).get(role)
	if clip == null:
		return null
	return {"clip": clip, "releaseAt": float(cc.CLIP_RELEASE[clip]), "minSeconds": float(MIN_SECONDS[clip])}

func _plan_gesture(choice: Dictionary, seconds: float, clip_duration: float, tempo := 1.0) -> Dictionary:
	var lead: float = float(DmContent.file("castClips").RELEASE_LEAD_S)
	var total := maxf(seconds, choice.minSeconds * tempo)
	var release_t: float = choice.releaseAt * clip_duration
	var tail := maxf(0.05, total - lead)
	var speed := minf(MAX_SPEED, maxf(MIN_SPEED, (clip_duration - release_t) / tail))
	var start_at := maxf(0.0, release_t - lead * speed)
	return {"startAt": start_at, "speed": speed, "releaseDelayS": (release_t - start_at) / speed}

func dispose() -> void:
	_disposed = true
	_live.erase(self)
	for w in _worn.values():
		DmGearProps.dispose_prop(w.obj)
	_worn.clear()
	if _cape != null:
		DmGearProps.dispose_prop(_cape.obj)
	_cape = null
	if _mantle != null:
		DmGearProps.dispose_prop(_mantle.obj)
	_mantle = null
	_mounts.clear()
	if c != null:
		c.dispose()
	if is_inside_tree():
		get_parent().remove_child(self)
	queue_free()
