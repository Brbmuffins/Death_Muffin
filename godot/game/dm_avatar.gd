class_name DmAvatar
extends Node3D
## The necromancer hero, local or remote (port of NecromancerAvatar in src/graphics/Avatars.ts): one model per discipline (hero_<id>),
## the discipline colours the staff light and robe glow; worn gear shows as a weapon / off-hand prop, a helm and body-region tints;
## gestures (`cast`), gathering tools, the mastery cape. The creature runs in-place (the sim owns position and heading).
##
## Use: var a := DmAvatar.new(); a.setup(world_root, "#a26bff", true, "hero_ossuary"); each frame a.update(dt, x, z, facing, moving, move_speed).
## `settings` = the DmGame settings dictionary (reads hideHelm); call `DmAvatar.refresh_all()` when settings change.

const HERO_TURN_RATE := 12.0
const HERO_TURN_MAX := 13.0
const HELM_APEX := 0.19
const HELM_OVER := 0.01
const STAFF_FOLLOW := 0.6
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
	"hero_ossuary": "covered", "hero_gravecaller": "covered", "hero_mourner": "covered", "hero_rotweaver": "covered",
	"hero_hollow_knight": "covered", "hero_grave_warden": "covered", "hero_veilwalker": "covered", "hero_carrion_witch": "covered", "hero_bell_monk": "covered",
}
const RIG_HEAD_STRENGTH := {"hero_bell_monk": 0.25}
# castClips.ts
const MIN_SECONDS := {"slam": 0.55, "sweep": 0.42, "flick": 0.26, "channel": 0.9, "summon": 0.7}
const MAX_SPEED := 3.2
const MIN_SPEED := 0.7

static var _live: Array = []

var c: DmCreature
var lantern: OmniLight3D = null
var slug := "necromancer"
var accent_hex := 0xa26bff
var settings: Dictionary = {}
var cast_lock := 0.0
## Metal tier of the tool each hand model shows (skill -> tier).
var gathering_tool_tier: Dictionary = {}

var _staff: Node3D = null
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


## Rebuild the visibility of default props / worn gear for every live hero (the Hide helms setting reaches own and remote avatars).
static func refresh_all() -> void:
	for a in _live:
		if is_instance_valid(a):
			a.apply_gear_visibility()

static func _hex(v: Variant) -> int:
	if v is String:
		return Color.html(v).to_rgba32() >> 8
	return int(v)

func setup(parent: Node, accent: Variant = 0xa26bff, with_light: bool = false, model_slug: String = "necromancer") -> void:
	slug = model_slug
	accent_hex = _hex(accent)
	name = "Avatar_" + model_slug
	c = DmCreature.new(model_slug, {"in_place": true, "gear_tint": true, "emissive": accent_hex, "emissive_intensity": 0.04,
		"fallback": "necromancer", "locomotion_fade": 0.16})
	add_child(c.root)
	if parent != null:
		parent.add_child(self)
	if NEW_BLOOD.has(model_slug):
		_attach_class_gear(model_slug)
	else:
		_staff = _skull_staff(accent_hex)
		c.attach("R_Hand", _staff, Vector3(0, 1, 0.12), STAFF_FOLLOW)
		_default_hand[_staff] = "main_hand"
	_live.append(self)
	if with_light:
		lantern = OmniLight3D.new()
		lantern.light_color = DmGearProps.col(accent_hex)
		lantern.light_energy = 18.0 * 0.12
		lantern.omni_range = 10.0
		lantern.omni_attenuation = 1.4
		lantern.position = Vector3(0, 3.2, 0.6)
		c.root.add_child(lantern)

## Coffin-oak staff with a skull finial and a violet soul-light.
func _skull_staff(accent: int) -> Node3D:
	var g := Node3D.new()
	g.add_child(DmGearProps._mi(DmGearProps._cyl(0.025, 0.035, 1.9, 6), DmGearProps._mat(0x2b211c, 0.0, 0.85), Vector3(0, 0.35, 0)))
	var skull := DmGearProps._mi(DmGearProps._sph(0.1), DmGearProps._mat(0xd8cfbd, 0.0, 0.7), Vector3(0, 1.35, 0))
	skull.scale = Vector3(1, 1.1, 1.15)
	g.add_child(skull)
	g.add_child(DmGearProps._mi(DmGearProps._torus(0.16, 0.012), DmGearProps._mat(0x5a4a3a, 0.6, 0.4), Vector3(0, 1.36, 0)))
	var glow := DmGearProps.glow_sprite(accent, 0.55, 1.0)
	glow.position.y = 1.36
	g.add_child(glow)
	g.set_meta("tip", glow)
	return g

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
	var path := DmModels.BASE + "models/props/%s.glb" % id
	if not ResourceLoader.exists(path):
		return null
	var ps: PackedScene = load(path)
	var inst: Node3D = ps.instantiate()
	var bb := AABB()
	var first := true
	for m in inst.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		if mi.mesh == null:
			continue
		var box := mi.mesh.get_aabb()
		bb = box if first else bb.merge(box)
		first = false
	var size := bb.size
	var denom := maxf(0.001, maxf(size.x, maxf(size.y, size.z))) if by_longest else maxf(0.0001, size.y)
	var holder := Node3D.new()
	holder.add_child(inst)
	inst.scale = Vector3.ONE * (height / denom)
	inst.position = -bb.get_center() * (height / denom) + Vector3(0, bb.size.y * 0.5 * (height / denom), 0)
	return holder

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
	c.attach("R_Hand", obj, Vector3(0, 1, 0.1))
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
	if _cape != null:
		(_cape.obj as Node3D).visible = idle and _cape_fade > 0.01

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
		if cur != null and cur.key == key:
			continue
		if slot == "head":
			_head_tint = null   # only when the helm changes: any later inventory change calls this again and must keep the worn helm's tint
		if cur != null:
			c.detach(cur.obj)
			DmGearProps.dispose_prop(cur.obj)
			_worn.erase(slot)
		if item == null:
			continue
		if slot == "head":
			_helm_want = String(item.item_id)
			var it: Dictionary = item
			c.after_load(func(): _mount_helm(it))
			continue
		var rarity := String(item.get("rarity", ""))
		var obj: Node3D = DmGearProps.build_offhand(item.item_id, rarity) if slot == "off_hand" else DmGearProps.build_weapon(item.item_id, rarity)
		var grip := DmGearProps.grip_for(slot, String(item.item_id), obj.has_meta("tip"))
		c.attach(bone, obj, grip.dir, grip.follow, grip.fit)
		_worn[slot] = {"obj": obj, "key": item.item_id}
	# Body slots have no prop: they recolour their region of the body by material tier.
	var aura: Variant = _legendary_aura(items)
	for pair in [["chest", "chest"], ["legs", "legs"], ["hands", "hands"], ["feet", "feet"]]:
		var it2: Variant = items.get(pair[1])
		if it2 == null:
			c.set_region_tint(pair[0], null)
		else:
			var t := DmGearProps.tier(String(it2.item_id), String(it2.get("rarity", "")))
			var glow: Variant = aura if aura != null else (t.glow if int(t.glow) >= 0 else null)
			c.set_region_tint(pair[0], {"color": t.color, "glow": glow})
	apply_gear_visibility()

## legendaryAura: the glow colour of a worn legendary set (4+ pieces of one), or null.
func _legendary_aura(items: Dictionary) -> Variant:
	var count: Dictionary = {}
	for it in items.values():
		if it == null:
			continue
		var p := DmGearProps.armor_by_id(String(it.item_id))
		if not p.is_empty() and int(p.collection) == 3:
			count[p.setId] = int(count.get(p.setId, 0)) + 1
	for set_id in count:
		if count[set_id] >= 4:
			for p in DmContent.get_export("armorSets", "ARMOR_PIECES"):
				if p.setId == set_id:
					return DmGearProps._dim(int(p.accent), 0.5)
	return null

func _mount_helm(item: Dictionary) -> void:
	if _disposed or _helm_want != String(item.item_id):
		return
	var cur: Variant = _worn.get("head")
	if cur != null and cur.key == item.item_id:
		return
	if RIG_HEAD.get(slug, "bare") == "covered":
		# The rig already has a hood, cowl or helmet: no dome. The helm shows as trim on that head region.
		var t := DmGearProps.tier(String(item.item_id), String(item.get("rarity", "")))
		var set := DmGearProps.armor_by_id(String(item.item_id))
		_head_tint = {"color": int(set.accent) if not set.is_empty() else t.color, "glow": t.glow if int(t.glow) >= 0 else null, "strength": RIG_HEAD_STRENGTH.get(slug, 0.55)}
		_worn["head"] = {"obj": Node3D.new(), "key": item.item_id}
		apply_gear_visibility()
		return
	mount_dome(item)

## The helm dome on a bare-headed rig. (The web seats it on a measured head fit; head_fit is not ported, no shipped hero is bare-headed.)
func mount_dome(item: Dictionary) -> void:
	var old: Variant = _worn.get("head")
	if old != null:
		c.detach(old.obj)
		DmGearProps.dispose_prop(old.obj)
		_worn.erase("head")
	_head_tint = null
	var obj := DmGearProps.build_helm(String(item.item_id), String(item.get("rarity", "")), 1.0)
	c.attach("Head", obj, Vector3(0, 1, 0))
	_worn["head"] = {"obj": obj, "key": item.item_id}
	apply_gear_visibility()

## Put a cape on (or take it off with ""). Hidden while a gathering tool is out, like the rest of the worn gear.
func set_cape(id: String) -> void:
	if _disposed or (_cape.id if _cape != null else "") == id:
		return
	if _cape != null:
		c.detach(_cape.obj)
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
	c.attach("Spine02", obj)
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
func cast(kind: String, speed := 2.0, facing: Variant = null, duration_s := 0.0, ability := "") -> void:
	if facing != null:
		c.root.rotation.y = float(facing)
	var choice: Variant = _cast_clip_for(weapon_gesture(), ability) if (ability != "" and duration_s > 0.0) else null
	var clip := c.clip_duration(choice.clip) if choice != null else 0.0
	if choice != null and clip > 0.0:
		var plan := _plan_gesture(choice, duration_s, clip)
		c.play_once(choice.clip, plan.speed, 0.0, plan.startAt)
		return
	c.play_once(kind, speed, duration_s)

func play_once(anim: String, speed := 1.0, duration_s := 0.0, start_at := 0.0) -> bool:
	return c.play_once(anim, speed, duration_s, start_at)

func set_loop(anim: String, speed := 1.0) -> void:
	c.set_loop(anim, speed)

func loop_phase() -> float:
	return c.loop_phase()

func release_gesture() -> void:
	c.release_gesture()

## The weapon kind steering the gesture: the equipped main hand, or 'none' (the default skull staff).
func weapon_gesture() -> String:
	var mh: Variant = _worn.get("main_hand")
	if mh == null:
		return "none"
	var necro := DmGearProps.necro_by_id(String(mh.key))
	return String(necro.kind) if not necro.is_empty() and necro.kind in ["staff", "scythe", "wand", "sickle"] else DmGearProps.weapon_kind(String(mh.key))

func _cast_clip_for(weapon: String, ability: String) -> Variant:
	var cc := DmContent.file("castClips")
	var role: Variant = (cc.ABILITY_ROLE as Dictionary).get(ability)
	if role == null:
		return null
	var clip: Variant = ((cc.WEAPON_CLIPS as Dictionary).get(weapon, {}) as Dictionary).get(role)
	if clip == null:
		return null
	return {"clip": clip, "releaseAt": float(cc.CLIP_RELEASE[clip]), "minSeconds": float(MIN_SECONDS[clip])}

func _plan_gesture(choice: Dictionary, seconds: float, clip_duration: float) -> Dictionary:
	var lead: float = float(DmContent.file("castClips").RELEASE_LEAD_S)
	var total := maxf(seconds, choice.minSeconds)
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
	if c != null:
		c.dispose()
	if is_inside_tree():
		get_parent().remove_child(self)
	queue_free()
