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
		var sprite: Variant = null
		if fx != null:
			for fch in fx.get_children():
				if fch is Sprite3D:
					sprite = fch
		halo.append((sprite as Sprite3D).pixel_size if sprite != null else 0.0)
		motes.append(_count(fx, "Motes", "amount"))
		w.free()
	check(halo[0] == 0.0 and halo[1] == 0.0 and halo[2] > 0.0 and halo[3] > halo[2] and halo[4] > halo[3], "outer halo grows from rare to legendary (%s)" % [halo])
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

	await _models()

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


## The prop's mesh box in `ref`'s space (metres through every scale on the way).
func _box_in(ref: Node3D, prop: Node3D) -> AABB:
	var inv := ref.global_transform.affine_inverse()
	var out := AABB()
	var first := true
	for m in prop.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		var b: AABB = (inv * mi.global_transform) * mi.mesh.get_aabb()
		out = b if first else out.merge(b)
		first = false
	return out


func _settle(av: DmAvatar, n := 6) -> void:
	for i in n:
		av.update(1.0 / 30.0, 0, 0, 0.0, false, 0.0)
		await process_frame


func _models() -> void:
	var tbl := DmGearModels.table()
	# ---- every weapon kind shows the real model, at its length, gripped at its grip point; tiers share one material each
	var kinds := {"staff": "staff_iron", "scythe": "scythe_gold", "wand": "wand_moon", "sickle": "sickle_hell", "skull_focus": "skull_focus_gold", "mourning_bell": "mourning_bell_iron", "grimoire": "grimoire_bone"}
	var scene := Node3D.new()
	root.add_child(scene)
	for kind in kinds:
		var row: Dictionary = tbl["weapon_kind_prop"][kind]
		var item := String(kinds[kind])
		var off := String(row.slot) == "off_hand"
		var w: Node3D = DmGearProps.build_offhand(item, "rare") if off else DmGearProps.build_weapon(item, "rare")
		scene.add_child(w)
		check(w.get_meta("model_kind", "") == kind and w.find_children("*", "MeshInstance3D", true, false).size() == 1, "%s: the real model, one mesh (one draw call)" % kind)
		var b := _box_in(w, w)
		check(absf(b.size.y - float(row.length_m)) < 0.02, "%s: %.2f m long (table %.2f)" % [kind, b.size.y, float(row.length_m)])
		check(b.position.y < 0.0 and b.end.y > 0.0 and absf(-b.position.y - float(row.grip_t) * b.size.y) < 0.02, "%s: the grip point sits at the origin, %.0f%% up the model" % [kind, float(row.grip_t) * 100.0])
		check(DmGearProps.HOLDS.has(kind) and DmGearProps.hold_kind(String(row.slot), item) == kind, "%s: has its own grip row" % kind)
		w.queue_free()
	var a1 := DmGearModels.weapon("staff", "iron")
	var a2 := DmGearModels.weapon("staff", "iron")
	var a3 := DmGearModels.weapon("staff", "hell")
	var a4 := DmGearModels.weapon("staff", "bone")
	var mat_of := func(n: Node3D) -> Material: return (n.find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D).material_override
	check(mat_of.call(a1) != null and mat_of.call(a1) == mat_of.call(a2), "a metal tier's material is shared by every instance")
	check(mat_of.call(a3) != mat_of.call(a1) and (mat_of.call(a3) as StandardMaterial3D).emission_enabled, "hell is its own material with a glow")
	check(mat_of.call(a4) == null, "bone is the model's own material")
	for n: Node3D in [a1, a2, a3, a4]:
		n.free()

	# ---- helm tiers
	check(DmGearModels.helm_tier_of("set_gravecaller_head") == "iron" and DmGearModels.helm_tier_of("set_rotweaver_ascended_head") == "silver" and DmGearModels.helm_tier_of("leg_plague_choir_head") == "hellsteel", "helm tier: class sets iron, ascended silver, legendary hellsteel")
	check(DmGearModels.helm_tier_of("helm_copper") == "copper" and DmGearModels.helm_tier_of("helm_iron") == "iron" and DmGearModels.helm_tier_of("helm_gold") == "silver", "helm tier: helm_copper / iron / gold(=silver)")
	for t in tbl["helm_by_tier"]:
		check(DmGearModels.helm(t, 0.4) != null, "helm model %s loads" % t)

	# ---- helm and mantle on every hero: mounted on Head / Spine02, sized to the hero, idle..cast clips keep them on
	for slug in HEROES:
		var av := await _avatar(slug)
		var set_id := {"hero_ossuary": "ossuary", "hero_gravecaller": "gravecaller", "hero_mourner": "mourner", "hero_rotweaver": "rotweaver"}[slug] as String
		av.set_equipment({"chest": {"item_id": "set_%s_chest" % set_id, "rarity": "rare"}, "head": {"item_id": "set_%s_head" % set_id, "rarity": "uncommon"}})
		await _settle(av)
		var helm: Node3D = av._worn.head.obj
		var mantle: Node3D = av._mantle.obj
		check(helm.get_parent() is BoneAttachment3D and (helm.get_parent() as BoneAttachment3D).bone_name == "Head" and mantle.get_parent() is BoneAttachment3D and (mantle.get_parent() as BoneAttachment3D).bone_name == "Spine02", "%s: helm on Head, mantle on Spine02" % slug)
		var hb := _box_in(av.c.root, helm)
		var mb := _box_in(av.c.root, mantle)
		check(hb.size.y > 0.3 and hb.size.y < 0.55 and hb.get_center().y > 1.5 and hb.get_center().y < 1.85, "%s: helm %.2f m tall, centred at %.2f m" % [slug, hb.size.y, hb.get_center().y])
		check(maxf(mb.size.x, mb.size.z) > 0.4 and maxf(mb.size.x, mb.size.z) < 1.0 and mb.get_center().y > 1.2 and mb.get_center().y < 1.7, "%s: mantle %.2f x %.2f m at %.2f m high" % [slug, mb.size.x, mb.size.z, mb.get_center().y])
		check(av.c._attached.is_empty(), "%s: worn models add nothing to the per-frame list" % slug)
		var local0: Transform3D = mantle.transform
		var drift := 0.0
		var worst := 0.0
		var sk := av.c.skeleton
		var spine := sk.find_bone("Spine02")
		for clip in CLIPS:
			if not av.c.has(clip):
				continue
			av.c.play_once(clip, 1.0, 0.0, 0.0, 0.0)
			for k in 12:
				av.c.update(0.1)
				await process_frame
				drift = maxf(drift, (mantle.transform.origin - local0.origin).length())
				worst = maxf(worst, mantle.global_position.distance_to(sk.global_transform * sk.get_bone_global_pose(spine).origin))
		check(drift == 0.0 and worst < 0.35, "%s: the mantle stays on the chest through every clip (worst %.2f m from Spine02)" % [slug, worst])
		# Hide helm hides the helm model only
		av.settings = {"hide_helm": true}
		av.apply_gear_visibility()
		check(not helm.visible and mantle.visible, "%s: Hide helm hides the helm, not the mantle" % slug)
		av.settings = {}
		av.apply_gear_visibility()
		# a chest piece of a set without a mantle, and a legendary one below three pieces, show none; changing it swaps the mantle
		av.set_equipment({"chest": {"item_id": "set_warden_chest", "rarity": "rare"}})
		check(av._mantle == null, "%s: a chest of a set with no mantle shows none" % slug)
		av.set_equipment({"chest": {"item_id": "set_%s_ascended_chest" % set_id, "rarity": "epic"}})
		check(av._mantle != null and av._mantle.set == set_id + "_ascended", "%s: the ascended chest brings the ascended mantle" % slug)
		av.set_equipment({})
		check(av._mantle == null and av._worn.is_empty() and av._mounts.size() == 1, "%s: taking it all off leaves only the default staff mounted" % slug)
		av.dispose()

	# ---- a legendary set: the body swaps at three pieces and back at two, carrying everything; props keep their size
	var av2 := await _avatar("hero_gravecaller")
	av2.set_equipment({"main_hand": {"item_id": "scythe_gold", "rarity": "epic"}, "chest": {"item_id": "set_gravecaller_chest", "rarity": "rare"}, "head": {"item_id": "set_gravecaller_head", "rarity": "rare"}})
	await _settle(av2)
	var staff_len := _box_in(av2._worn.main_hand.obj, av2._worn.main_hand.obj).size.y
	var old_root := av2.c.root
	var leg := {"main_hand": {"item_id": "scythe_gold", "rarity": "epic"}, "chest": {"item_id": "leg_legion_unburied_chest", "rarity": "legendary"}, "head": {"item_id": "leg_legion_unburied_head", "rarity": "legendary"}}
	av2.set_equipment({"main_hand": leg.main_hand, "chest": leg.chest})
	check(av2.body_slug == "hero_gravecaller" and av2.set_pieces == 0, "legendary: two pieces do not swap")
	for i in 90:   # (the two-piece look started loading the body on a worker thread)
		await process_frame
	var cold0 := DmModels.cold_loads
	var swap_t := Time.get_ticks_usec()
	av2.set_equipment(leg.merged({"legs": {"item_id": "leg_legion_unburied_legs", "rarity": "legendary"}}))
	print("INFO perf: legendary swap after the two-piece prefetch %.2f ms, cold model loads %d" % [(Time.get_ticks_usec() - swap_t) / 1000.0, DmModels.cold_loads - cold0])
	check(DmModels.cold_loads == cold0, "legendary: the swap found the body already loaded by the two-piece prefetch (no cold load)")
	await _settle(av2)
	check(av2.body_slug == "hero_leg_legion_unburied" and av2.c.rig_slug == "hero_leg_legion_unburied" and av2.slug == "hero_gravecaller", "legendary: three pieces swap the body to the set's hero (own body slug kept)")
	await process_frame
	check(not is_instance_valid(old_root) or not old_root.is_inside_tree(), "legendary: the old body is gone")
	var wp: Node3D = av2._worn.main_hand.obj
	check(wp.get_parent() is BoneAttachment3D and av2.c.skeleton.is_ancestor_of(wp) and absf(_box_in(wp, wp).size.y - staff_len) < 0.02, "legendary: the weapon follows to the new hand at its size")
	check(av2._worn.head.obj.get_parent() is BoneAttachment3D and av2._worn.head.obj.visible, "legendary: the helm is re-fitted on the new head")
	check(av2._mantle == null, "legendary: no class mantle on a legendary body (legendary chest has none)")
	check(av2.c.root.get_parent() == av2 and av2.c.root.get_index() == 0, "legendary: the new body is where the old one was")
	check(av2._aura != null and av2._aura.get_parent() == av2.c.root, "legendary: the aura moved to the new body")
	check(av2.c._gear_tint[0].w > 0.0, "legendary: the chest tint is on the new body")
	var swapped_nodes := Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	av2.set_equipment(leg.merged({"legs": {"item_id": "set_gravecaller_legs", "rarity": "rare"}}))
	await _settle(av2)
	check(av2.body_slug == "hero_gravecaller", "legendary: dropping below three pieces swaps the hero's own body back (%s)" % av2.body_slug)
	check(av2._worn.main_hand.obj.get_parent() is BoneAttachment3D and av2.c.skeleton.is_ancestor_of(av2._worn.main_hand.obj), "legendary: the weapon is back on the original body's hand")
	# the swap cycle does not grow the scene
	await process_frame
	var n0 := Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	for i in 3:
		av2.set_equipment(leg.merged({"legs": {"item_id": "leg_legion_unburied_legs", "rarity": "legendary"}}))
		await process_frame
		av2.set_equipment(leg)
		await process_frame
	await process_frame
	check(Performance.get_monitor(Performance.OBJECT_NODE_COUNT) <= n0 + 2, "legendary: swapping back and forth three times leaks no nodes (%d -> %d)" % [n0, Performance.get_monitor(Performance.OBJECT_NODE_COUNT)])
	# an animation in progress: a walking hero keeps walking
	av2.update(1.0 / 60.0, 0, 0, 0.0, true, 3.0)
	av2.set_equipment(leg.merged({"legs": {"item_id": "leg_legion_unburied_legs", "rarity": "legendary"}}))
	for i in 5:
		av2.update(1.0 / 60.0, float(i) * 0.05, 0, 0.0, true, 3.0)
	check(av2.body_slug == "hero_leg_legion_unburied" and av2.c._loop in ["walk", "run"], "legendary: a walking hero keeps walking through the swap (%s)" % av2.c._loop)
	av2.dispose()

	# ---- the Reaper never turns into a legendary hero: she keeps her body, scythe and gets the aura and colours
	var rp := DmAvatar.new()
	rp.setup(root, 0x6ee7a0, false, "hero_mourner", "reaper")
	for i in 4:
		rp.update(1.0 / 30.0, 0, 0, 0.0, false, 0.0)
		await process_frame
	var rleg := {"chest": {"item_id": "leg_requiem_wraiths_chest", "rarity": "legendary"}, "head": {"item_id": "leg_requiem_wraiths_head", "rarity": "legendary"}, "legs": {"item_id": "leg_requiem_wraiths_legs", "rarity": "legendary"}, "hands": {"item_id": "leg_requiem_wraiths_hands", "rarity": "legendary"}}
	rp.set_equipment(rleg)
	check(rp.body_slug == "hero_mourner" and rp.set_id == "requiem_wraiths" and rp.set_pieces == 4 and rp._aura != null and rp._scheme_glow != null, "Reaper: four legendary pieces keep her own body and give the aura and the set colours (body %s)" % rp.body_slug)
	check(rp._staff != null and rp._staff.visible and rp.weapon_gesture() == "scythe", "Reaper: still holds her scythe")
	rp.dispose()

	# ---- Soul Harbinger's Raiment (her own legendary set): its hood per piece; from 3 pieces her whole body becomes the set's (hero_leg_soul_harbingers, which
	# wears the hood and ribcage itself, so the hood prop hides) and her scythe the green bone scythe (necro_gear.json legendary_hero_by_set_id, weapon_by_set_id)
	check(DmGearModels.helm_tier_of("leg_soul_harbingers_head") == "soul_harbingers" and DmGearModels.mantle_set_of("leg_soul_harbingers_chest") == "", "Soul Harbinger: its head piece shows its own hood, its chest no bolted-on mantle")
	check(DmGearModels.set_weapon_prop("soul_harbingers", 3, "scythe") == "gear_greenbone_scythe" and DmGearModels.set_weapon_prop("soul_harbingers", 2, "scythe") == "" and DmGearModels.set_weapon_prop("soul_harbingers", 5, "staff") == "", "Soul Harbinger: the set scythe from 3 pieces, scythes only")
	check(DmGearModels.legendary_slug("soul_harbingers") == "hero_leg_soul_harbingers" and DmGearModels.legendary_discipline("soul_harbingers") == "reaper" and DmGearModels.body_covers_props("soul_harbingers") and not DmGearModels.body_covers_props("plague_choir"), "Soul Harbinger: the Reaper's legendary body, which wears its own hood")
	check(DmSetText.describe_effect({"text": "Scythe Throw’s radius is doubled"}) == ["Scythe Throw’s radius is doubled"], "a text-only set bonus prints its own words")
	var scythe_file := func(n: Node3D) -> String: return n.get_child(0).scene_file_path.get_file().get_basename() if n != null and n.get_child_count() > 0 else ""
	var sh := DmAvatar.new()
	sh.setup(root, 0x6ee7a0, false, "hero_reaper", "reaper")
	for i in 4:
		sh.update(1.0 / 30.0, 0, 0, 0.0, false, 0.0)
		await process_frame
	check(sh.c.clip_duration("sweep") > 0.0 and sh.c.clip_duration("slam") > 0.0 and sh.c.clip_duration("summon") > 0.0, "Reaper: her body carries the combat clips her rites play (sweep, slam, summon)")
	var shg := {"chest": {"item_id": "leg_soul_harbingers_chest", "rarity": "legendary"}, "head": {"item_id": "leg_soul_harbingers_head", "rarity": "legendary"}}
	sh.set_equipment(shg)
	await _settle(sh)
	check(scythe_file.call(sh._staff) == DmGearProps.SCYTHE_FILE and sh._mantle == null and scythe_file.call(sh._worn.head.obj) == "gear_greenbone_helm" and sh._worn.head.obj.visible and sh.body_slug == "hero_reaper", "Soul Harbinger, 2 pieces: the green bone hood, her own body and scythe")
	shg["legs"] = {"item_id": "leg_soul_harbingers_legs", "rarity": "legendary"}
	sh.set_equipment(shg)
	await _settle(sh)
	check(sh.body_slug == "hero_leg_soul_harbingers" and scythe_file.call(sh._staff) == "gear_greenbone_scythe" and sh._staff.visible and not sh._worn.head.obj.visible, "Soul Harbinger, 3 pieces: the set's body (its own hood, no prop over it) and the green bone scythe (body %s)" % sh.body_slug)
	check(sh.c.clip_duration("sweep") > 0.0 and sh.c.clip_duration("flick") > 0.0, "Soul Harbinger body: the Reaper's combat clips")
	shg["main_hand"] = {"item_id": "scythe_iron", "rarity": "rare"}
	sh.set_equipment(shg)
	check(scythe_file.call(sh._worn.main_hand.obj) == "gear_greenbone_scythe" and not sh._staff.visible, "Soul Harbinger: an equipped scythe shows as the set's too")
	sh.set_equipment({})
	await _settle(sh)
	check(sh.body_slug == "hero_reaper" and scythe_file.call(sh._staff) == DmGearProps.SCYTHE_FILE and sh._staff.visible, "Soul Harbinger: taking the set off gives her own body and scythe back")
	sh.dispose()

	# ---- tiers keep the model's texture: the dress only nudges the colour
	for t in ["iron", "gold", "hell", "moon"]:
		var tint: Color = DmGearModels.TIER_DRESS[t].tint
		check(minf(tint.r, minf(tint.g, tint.b)) >= 0.85 and maxf(tint.r, maxf(tint.g, tint.b)) <= 1.1, "tier %s: a subtle tint, not a recolour" % t)
		if DmGearModels.TIER_DRESS[t].has("k"):
			check(float(DmGearModels.TIER_DRESS[t].k) <= 0.4, "tier %s: the glow is an accent" % t)

	# ---- cost: draw calls per hero and the equip / swap work (counters; timings are INFO)
	var bare := await _avatar("hero_rotweaver")
	var meshes0 := bare.find_children("*", "MeshInstance3D", true, false).size()
	var full := {"main_hand": {"item_id": "staff_hell", "rarity": "epic"}, "off_hand": {"item_id": "grimoire_gold", "rarity": "rare"}, "chest": {"item_id": "set_rotweaver_chest", "rarity": "rare"}, "head": {"item_id": "set_rotweaver_head", "rarity": "rare"}}
	var t0 := Time.get_ticks_usec()
	bare.set_equipment(full)
	var equip_ms := (Time.get_ticks_usec() - t0) / 1000.0
	t0 = Time.get_ticks_usec()
	bare.set_equipment({})
	var unequip_ms := (Time.get_ticks_usec() - t0) / 1000.0
	bare.set_equipment(full)
	var added := bare.find_children("*", "MeshInstance3D", true, false).size() - meshes0
	check(added == 4, "worn gear adds %d mesh instances (weapon, off-hand, helm, mantle: one each)" % added)
	var shown := 0
	for obj in bare._mounts:
		if (obj as Node3D).visible:
			shown += 1
	print("INFO perf: gear props shown on a fully geared hero: %d of %d mounted (weapon, off-hand, helm, mantle; the default staff gives way)" % [shown, bare._mounts.size()])
	print("INFO perf: equip full gear %.2f ms, unequip %.2f ms (headless)" % [equip_ms, unequip_ms])
	var swap0 := Time.get_ticks_usec()
	bare.set_equipment(full.merged({"legs": {"item_id": "leg_plague_choir_legs", "rarity": "legendary"}, "chest": {"item_id": "leg_plague_choir_chest", "rarity": "legendary"}, "head": {"item_id": "leg_plague_choir_head", "rarity": "legendary"}}, true))
	print("INFO perf: legendary swap (first, model cold) %.2f ms, body %s" % [(Time.get_ticks_usec() - swap0) / 1000.0, bare.body_slug])
	check(bare.body_slug == "hero_leg_plague_choir", "the rotweaver turns into the Plague Choir hero in a full set")
	bare.set_equipment(full)
	swap0 = Time.get_ticks_usec()
	bare.set_equipment(full.merged({"legs": {"item_id": "leg_plague_choir_legs", "rarity": "legendary"}, "chest": {"item_id": "leg_plague_choir_chest", "rarity": "legendary"}, "head": {"item_id": "leg_plague_choir_head", "rarity": "legendary"}}, true))
	print("INFO perf: legendary swap (warm) %.2f ms" % ((Time.get_ticks_usec() - swap0) / 1000.0))
	bare.dispose()
	scene.queue_free()
