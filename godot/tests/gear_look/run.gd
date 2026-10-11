extends SceneTree
## The hero's gear look (game/dm_avatar.gd, dm_creature.gd attach_held, dm_gear_props.gd HOLDS, dm_gear_fx.gd, dm_creature_mat.gd): the weapon sits in the
## palm and follows the hand through idle / run / cast clips, the cast clips use the weapon hand, worn body gear tints lightly, rarity / element /
## set effects are capped and cost no per-frame script.
## godot --headless --path godot --script res://tests/gear_look/run.gd

const HEROES := ["hero_ossuary", "hero_gravecaller", "hero_mourner", "hero_rotweaver"]
const CLIPS := ["idle", "run", "cast", "flick", "slam", "summon", "channel"]

var passed := 0
var failed := 0


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, what: String) -> void:
	if ok:
		passed += 1
	else:
		failed += 1
		print("FAIL: ", what)


func _avatar(slug: String) -> DmAvatar:   # (a coroutine: call with await, the attachments settle on frames)
	var av := DmAvatar.new()
	av.setup(root, 0xa26bff, false, slug, "necromancer")
	for i in 6:
		av.update(1.0 / 30.0, 0, 0, 0.0, false, 0.0)
		await process_frame
	return av


func _hand_world(av: DmAvatar, bone: String) -> Vector3:
	var sk := av.c.skeleton
	return sk.global_transform * sk.get_bone_global_pose(sk.find_bone(bone)).origin


## World distance (metres, through the skeleton's own scale) of the prop's grip from the hand and the elbow joints.
func _grip_distances(av: DmAvatar, prop: Node3D) -> Dictionary:
	var sk := av.c.skeleton
	var s := sk.global_transform.basis.get_scale().x
	var hand := _hand_world(av, "R_Hand")
	var fore := sk.global_transform * sk.get_bone_global_pose(sk.get_bone_parent(sk.find_bone("R_Hand"))).origin
	return {"hand": prop.global_position.distance_to(hand), "fore": prop.global_position.distance_to(fore), "scale": s}


func _run() -> void:
	# ---- the grip: measured palm, rigid follow, no per-frame prop work
	for slug in HEROES:
		var av := await _avatar(slug)
		var staff := av._staff
		var palm := av.c.palm_of("R_Hand")
		check(palm.y > 0.02 and palm.y < 0.11 and absf(palm.x) < 0.05 and absf(palm.z) < 0.05, "%s: the measured palm is inside the hand (%s)" % [slug, palm])
		check(av.c._attached.is_empty(), "%s: a held staff is not in the per-frame prop list (no world-up lock to fight the clip)" % slug)
		var slipped := false
		var local0: Transform3D = staff.transform
		var worst_hand := 0.0
		var closer_to_hand := true
		var moved := 0.0
		var last := Vector3.ZERO
		for clip in CLIPS:
			if not av.c.has(clip):
				continue
			av.c.play_once(clip, 1.0, 0.0, 0.0, 0.0)
			for k in 24:
				av.c.update(0.05)
				await process_frame   # the bone attachments follow the skeleton on the frame
				var d := _grip_distances(av, staff)
				worst_hand = maxf(worst_hand, d.hand)
				closer_to_hand = closer_to_hand and d.hand < d.fore
				slipped = slipped or staff.transform != local0
				moved = maxf(moved, staff.global_position.distance_to(last)) if last != Vector3.ZERO else moved
				last = staff.global_position
		check(worst_hand < 0.13, "%s: the staff's grip stays within a hand's length of the hand joint over idle/run/cast clips (worst %.3f m)" % [slug, worst_hand])
		check(closer_to_hand, "%s: the grip is always nearer the hand than the forearm joint (not hinged at the elbow)" % slug)
		check(not slipped, "%s: the staff never moves relative to the hand (fully follows it)" % slug)
		check(moved > 0.02, "%s: ...and the hand carries it through the clips (%.2f m between samples)" % [slug, moved])
		av.dispose()

	# ---- every kind has a grip row; a kind without one gets the default; left hand mirrors the knuckle axis
	for kind in ["staff", "scythe", "wand", "sickle", "skull_focus", "mourning_bell", "grimoire", "tome", "sword", "dagger", "mace", "bow", "shield", "default_staff"]:
		check(DmGearProps.HOLDS.has(kind), "grip table has %s" % kind)
	var rs := DmGearProps.hold_spec("staff")
	var ls := DmGearProps.hold_spec("staff", true)
	check(rs.side == 1.0 and ls.side == -1.0 and rs.lean == ls.lean, "left hand mirrors the shaft axis, not the lean")
	check(DmGearProps.hold_spec("kind_that_does_not_exist").lean == deg_to_rad(DmGearProps.HOLD_DEFAULT.lean), "an unknown kind (a later model) gets the default grip")
	check(DmGearProps.hold_kind("main_hand", "staff_gold") == "staff" and DmGearProps.hold_kind("main_hand", "sword_copper") == "sword" and DmGearProps.hold_kind("off_hand", "mourning_bell_iron") == "mourning_bell", "grip kind comes from the item")

	# ---- a worn weapon and off-hand sit in their palms too; swapping rebuilds nothing else
	var av2 := await _avatar("hero_ossuary")
	av2.set_equipment({"main_hand": {"item_id": "scythe_iron", "rarity": "rare"}, "off_hand": {"item_id": "grimoire_gold", "rarity": "rare"}})
	for i in 4:
		av2.c.update(0.05)
		await process_frame
	var scythe: Node3D = av2._worn.main_hand.obj
	var tome: Node3D = av2._worn.off_hand.obj
	check(_grip_distances(av2, scythe).hand < 0.12, "worn scythe: grip in the right palm")
	var lh := av2.c.skeleton.global_transform * av2.c.skeleton.get_bone_global_pose(av2.c.skeleton.find_bone("L_Hand")).origin
	check(tome.global_position.distance_to(lh) < 0.2, "worn tome: held at the left hand")
	check(av2.c._attached.is_empty(), "worn props add nothing to the per-frame list")

	# ---- cast clips: the staff's bolts and the scythe's strikes use clips that move the weapon hand
	var cc := DmContent.file("castClips")
	check(cc.WEAPON_CLIPS["staff"]["bolt"] == "flick" and cc.WEAPON_CLIPS["none"]["bolt"] == "flick", "staff bolts use the flick (the staff hand throws the cast)")
	var ch: Variant = av2._cast_clip_for("staff", "marrow_spear")
	check(ch != null and ch.clip == "flick" and absf(ch.releaseAt - 0.619) < 0.01, "marrow_spear with a staff plays the flick, released at 0.619")
	var rpath := {}
	for clip in ["flick", "slam", "summon", "cast", "sweep", "channel"]:
		rpath[clip] = _hand_path(av2, clip, "R_Hand")
	check(rpath["flick"] > 1.0 and rpath["slam"] > 1.0 and rpath["summon"] > 1.0, "the staff's bolt / big / summon clips move the weapon hand a lot (%s)" % [rpath])
	av2.dispose()

	# ---- tint: light, the base texture keeps its detail, trim carries the tier signal
	var av3 := await _avatar("hero_gravecaller")
	av3.set_equipment({"chest": {"item_id": "set_gravecaller_chest", "rarity": "rare"}, "legs": {"item_id": "set_gravecaller_legs", "rarity": "common"},
		"head": {"item_id": "helm_copper", "rarity": "epic"}})
	for i in 4:
		av3.c.update(0.05)
	var chest_t: Vector4 = av3.c._gear_tint[0]
	var legs_t: Vector4 = av3.c._gear_tint[1]
	check(chest_t.w > 0.0 and chest_t.w <= 0.45 and legs_t.w > 0.0 and legs_t.w <= 0.45, "body tints are light (chest %.2f, legs %.2f; they were 0.7)" % [chest_t.w, legs_t.w])
	check(chest_t.w > legs_t.w, "a rarer piece tints a little more")
	check(av3.c._head_tint.w > 0.0 and av3.c._head_tint.w <= 0.2, "a covered head only takes a faint tint (%.2f)" % av3.c._head_tint.w)
	check(av3.c._gear_glow[0] != Vector3.ZERO and av3.c._gear_glow[1] != Vector3.ZERO, "every worn piece keeps a trim glow (the tier signal)")
	check(av3.c._gear_tint[2].w == 0.0 and av3.c._gear_tint[3].w == 0.0, "regions without a worn piece stay clear")
	check(DmCreatureMat.shader(false, false, true).code.contains("0.2 + 0.8 * trim"), "the glow is limited to trim and rim")
	av3.dispose()

	# ---- rarity / element glow on the weapon
	var halo := []
	var motes := []
	for rarity in DmGearFx.RARITIES:
		var w := DmGearProps.build_weapon("staff_bone", rarity)
		var fx := DmGearFx.dress_weapon(w, rarity, "")
		var tip := w.get_meta("tip") as Sprite3D
		halo.append(tip.pixel_size)
		motes.append(_count(fx, "Motes", "amount"))
		w.free()
	check(halo[0] == halo[1] and halo[2] > halo[1] and halo[3] > halo[2] and halo[4] > halo[3], "tip halo grows from rare to legendary (%s)" % [halo])
	check(motes == [0, 0, 5, 10, 16], "motes escalate rare 5, epic 10, legendary 16 and none below (%s)" % [motes])
	check(DmGearFx.MAX_MOTES == 16 and motes.max() <= DmGearFx.MAX_MOTES, "motes are capped")
	var plain := DmGearProps.build_weapon("staff_iron", "common")
	check(DmGearFx.dress_weapon(plain, "common", "") == null and plain.get_node_or_null("GearFx") == null, "a plain common weapon gets nothing")
	var el := DmGearFx.dress_weapon(plain, "common", "rot")
	check(el != null and _count(el, "Motes", "amount") == 4, "an element always shows, even on a plain weapon")
	var again := DmGearFx.dress_weapon(plain, "epic", "frost")
	check((plain.get_meta("tip") as Node3D).get_children().filter(func(n: Node) -> bool: return n.name.begins_with("GearFx")).size() == 1 and again != null, "dressing again replaces the earlier dressing")
	plain.free()
	for e in DmGearFx.ELEMENTS:
		check(DmGearFx.element_color(e) != Color.WHITE, "element %s has a spell colour" % e)
	check(DmGearFx.element_for("staff_hell") == "fire" and DmGearFx.element_for("staff_moon") == "frost" and DmGearFx.element_for("staff_iron") == "" and DmGearFx.element_for("staff_hell", "rot") == "rot", "element: rune first, else the metal tier")
	check(DmGearFx.element_of_runes({"bone_needle": "rune_creeping_rot"}) == "rot" and DmGearFx.element_of_runes({}) == "", "element of socketed runes")
	for rid in DmContent.get_export("runes", "RUNE_IDS"):
		check(DmGearFx.RUNE_ELEMENT.has(rid) and DmGearFx.valid_element(DmGearFx.RUNE_ELEMENT[rid]), "rune %s maps to an element" % rid)

	var av4 := await _avatar("hero_ossuary")
	av4.set_equipment({"main_hand": {"item_id": "staff_hell", "rarity": "epic"}})
	var mh: Node3D = av4._worn.main_hand.obj
	check((mh.get_meta("tip") as Node3D).get_node_or_null("GearFx") != null and _count((mh.get_meta("tip") as Node3D).get_node("GearFx"), "Motes", "amount") == 10, "a worn epic hell staff shows halo and 10 fire motes")
	av4.set_weapon_element("not_an_element")
	av4.set_weapon_element("frost")
	check(av4._element == "frost" and _count((mh.get_meta("tip") as Node3D).get_node("GearFx"), "Motes", "amount") == 10, "a rune element replaces the tier's, rarity unchanged; bad names are refused")
	av4.set_equipment({"main_hand": {"item_id": "staff_hell", "rarity": "legendary"}})
	check(_count((av4._worn.main_hand.obj.get_meta("tip") as Node3D).get_node("GearFx"), "Motes", "amount") == 16, "the same staff at a new rarity is redressed")
	av4.set_equipment({})
	check(av4._staff.visible and av4._staff.get_meta("tip").get_node_or_null("GearFx") != null, "the default staff shows the rune element too")

	# ---- the set look: aura steps at 2 and 4 pieces, the scheme from 3, the hook for the full-set models
	var av5 := await _avatar("hero_rotweaver")
	var seen := []
	av5.set_look_changed.connect(func(id: String, n: int) -> void: seen.append([id, n]))
	var gc := ["set_gravecaller_head", "set_gravecaller_chest", "set_gravecaller_hands", "set_gravecaller_legs", "set_gravecaller_feet"]
	var slots := ["head", "chest", "hands", "legs", "feet"]
	var items := {}
	var levels := []
	var schemes := []
	for i in 5:
		items[slots[i]] = {"item_id": gc[i], "rarity": "uncommon"}
		av5.set_equipment(items)
		levels.append(av5._aura_level)
		schemes.append(av5._scheme_glow != null)
	check(levels == [0, 1, 1, 2, 2], "aura level steps up at 2 and 4 pieces (%s)" % [levels])
	check(schemes == [false, false, true, true, true], "the set's colour scheme comes on from 3 pieces (%s)" % [schemes])
	check(av5.set_id == "gravecaller" and av5.set_pieces == 5 and seen.size() == 4 and seen[0] == ["gravecaller", 2] and seen[-1] == ["gravecaller", 5], "set_look_changed fires once per change (%s)" % [seen])
	var auras := av5.c.root.get_children().filter(func(n: Node) -> bool: return n is CPUParticles3D)
	check(auras.size() == 1 and (auras[0] as CPUParticles3D).amount == DmGearFx.AURA_MOTES[2], "one aura emitter, 14 motes at 4+ pieces")
	check(av5.c._gear_glow[0] != Vector3.ZERO, "worn pieces glow in the scheme colour")
	av5.set_look("gravecaller", 5)
	check(seen.size() == 4, "the same look again changes nothing")
	av5.set_look("", 0)
	check(av5._aura == null and av5.c.root.get_children().filter(func(n: Node) -> bool: return n is CPUParticles3D).is_empty() and av5.set_id == "", "no set: the aura is gone")
	av5.set_look("legion_unburied", 1)
	check(av5.set_id == "" and av5._aura == null, "one piece is not a set look")
	av5.set_equipment({"head": {"item_id": "set_gravecaller_head"}, "chest": {"item_id": "set_mourner_chest"}, "legs": {"item_id": "set_gravecaller_legs"}})
	check(av5.set_id == "gravecaller" and av5.set_pieces == 2, "pieces of one set count, other sets do not")

	# ---- the replicated descriptor carries an optional element, shape-checked
	var d := {"g": {}, "c": "", "p": ""}
	check(DmHeroLook._valid(d) and DmHeroLook._valid({"g": {}, "c": "", "p": "", "e": "rot"}) and not DmHeroLook._valid({"g": {}, "c": "", "p": "", "e": "banana"}) and not DmHeroLook._valid({"g": {}, "c": "", "p": "", "e": 3}), "descriptor: e is optional and must be a known element")

	# ---- no per-frame cost: the object count does not move while a fully dressed hero animates
	av4.set_equipment({"main_hand": {"item_id": "staff_moon", "rarity": "legendary"}, "chest": {"item_id": "leg_legion_unburied_chest", "rarity": "legendary"},
		"legs": {"item_id": "leg_legion_unburied_legs", "rarity": "legendary"}, "hands": {"item_id": "leg_legion_unburied_hands", "rarity": "legendary"},
		"feet": {"item_id": "leg_legion_unburied_feet", "rarity": "legendary"}, "head": {"item_id": "leg_legion_unburied_head", "rarity": "legendary"}})
	for i in 10:
		av4.update(1.0 / 60.0, float(i) * 0.05, 0, 0.0, true, 3.0)
	await process_frame
	var objs0 := Performance.get_monitor(Performance.OBJECT_COUNT)
	var nodes0 := Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	var t0 := Time.get_ticks_usec()
	for i in 240:
		av4.update(1.0 / 60.0, 1.0 + float(i) * 0.05, 0, 0.0, true, 3.0)
	var dressed_ms := (Time.get_ticks_usec() - t0) / 240000.0
	check(Performance.get_monitor(Performance.OBJECT_COUNT) <= objs0 + 2 and Performance.get_monitor(Performance.OBJECT_NODE_COUNT) == nodes0, "240 frames of a fully dressed legendary hero allocate nothing that stays (objects %d -> %d)" % [objs0, Performance.get_monitor(Performance.OBJECT_COUNT)])
	check(av4.c._attached.is_empty(), "no props in the per-frame calibration list")
	var gpu := av4.find_children("*", "CPUParticles3D", true, false)
	var total := 0
	for p in gpu:
		total += (p as CPUParticles3D).amount
	check(total <= DmGearFx.MAX_MOTES + DmGearFx.AURA_MOTES[2], "a dressed hero's particles are capped (%d)" % total)
	var bare := await _avatar("hero_ossuary")
	var t1 := Time.get_ticks_usec()
	for i in 240:
		bare.update(1.0 / 60.0, 1.0 + float(i) * 0.05, 0, 0.0, true, 3.0)
	print("INFO perf: avatar update with full legendary dressing %.3f ms, bare %.3f ms (headless, per frame)" % [dressed_ms, (Time.get_ticks_usec() - t1) / 240000.0])
	bare.dispose()
	av4.dispose()
	av5.dispose()

	print("--- gear_look: %d passed, %d failed ---" % [passed, failed])
	quit(0 if failed == 0 else 1)


## Summed world-space travel of a hand bone over a clip (metres), sampled every 1/30 s.
func _hand_path(av: DmAvatar, clip: String, bone: String) -> float:
	av.c.play_once(clip, 1.0, 0.0, 0.0, 0.0)
	var sk := av.c.skeleton
	var hip := sk.find_bone("Hip")
	var prev := Vector3.ZERO
	var total := 0.0
	var n := int(av.c.clip_duration(clip) * 30.0)
	for i in n:
		av.c.update(1.0 / 30.0)
		var p: Vector3 = sk.get_bone_global_pose(hip).affine_inverse() * sk.get_bone_global_pose(sk.find_bone(bone)).origin
		if i > 0:
			total += p.distance_to(prev)
		prev = p
	return total


## Reads `prop` of the first child called `name` under `fx` (0 when absent).
func _count(fx: Node, name: String, prop: String) -> int:
	if fx == null:
		return 0
	var n := fx.get_node_or_null(name)
	return int(n.get(prop)) if n != null else 0
