extends SceneTree
## The hero's look on the rebuild (godot/next/hero/dm_hero_look.gd): worn gear, cape, pet and hero ring on the offline backend, driven through the
## real bag / Capes & Pets paths, replicated to an in-process ENet client; plus the cost of a pet + full gear and of an equip change.
## godot --headless --path godot --script res://tests/next_hero_look/run.gd

const DT := 1.0 / 60.0
const BAG := ["sword_copper", "helm_copper", "set_gravecaller_chest", "set_gravecaller_legs", "charm_tithe_bat"]

var passed := 0
var failed := 0
var api: DmApi
var mock: DmMockBackend
var cid := 0
var PORT := DmTestPorts.free_port()


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, what: String) -> void:
	if ok:
		passed += 1
	else:
		failed += 1
		print("FAIL: ", what)


func ticks(n: int) -> void:
	var target := Engine.get_physics_frames() + n
	while Engine.get_physics_frames() < target:
		await physics_frame


func until(cond: Callable, limit_s: float) -> bool:
	var end := Engine.get_physics_frames() + int(limit_s / DT)
	while Engine.get_physics_frames() < end:
		if cond.call():
			return true
		await physics_frame
	return cond.call()


func ms(f: Callable) -> float:
	var t := Time.get_ticks_usec()
	f.call()
	return (Time.get_ticks_usec() - t) / 1000.0


func _worn(av: DmAvatar, slot: String) -> Variant:
	return av._worn.get(slot)


func _run() -> void:
	mock = DmOffline.make_mock("")
	api = DmOffline.make_api(mock)
	var r := await api.register("look%d" % (Time.get_ticks_usec() % 100000), "l@example.com", "pw1234")
	api.set_token(r.data["token"])
	var ch := await api.load_or_create_character(2)
	cid = int(ch.data["id"])
	# a bag with a weapon, a helm, two legendary-collection-free armour pieces and a pet charm; the account has mining 99 (cape_mining)
	var rows: Array = []
	for i in BAG.size():
		rows.append({"slot_index": i, "item_id": BAG[i], "quantity": 1, "equipped": 0})
	check((await api.save_inventory(cid, rows, 48)).ok, "seed the bag")
	for k in mock.db["accounts"]:
		mock.db["accounts"][k]["professions"][0]["skill_level"] = 99
	var g: DmNextGame = load("res://next/next_game.tscn").instantiate()
	root.add_child(g)
	await g.start(ch.data, api, {"dressing": false, "persist": false, "waves": false, "audio": false})
	var look := g.look
	var b := g.local_body()
	await until(func() -> bool: return b.avatar != null, 3.0)
	check(look != null and b.avatar != null, "the Look node exists and the hero has an avatar")
	check(b.avatar.lantern != null, "the local hero carries the lantern")
	var fc := DmFrameCost.attach(g)

	# ---- worn gear: equip -> the avatar shows the piece, unequip -> it is gone
	check(_worn(b.avatar, "main_hand") == null, "A: nothing worn at first")
	await g.ui_host.refresh_inventory()
	var row := func(id: String) -> Dictionary:
		for s in g.ui_host.inventory.slots:
			if s["item_id"] == id:
				return s
		return {}
	var sent0 := look.sent
	await g.ui.inv.toggle_equip(row.call("sword_copper"))
	check(_worn(b.avatar, "main_hand") != null and _worn(b.avatar, "main_hand").key == "sword_copper", "A: equipping the sword puts it in the hand (the staff gives way)")
	check(not b.avatar._staff.visible, "A: the default staff is hidden while a weapon is worn")
	await g.ui.inv.toggle_equip(row.call("helm_copper"))
	await g.ui.inv.toggle_equip(row.call("set_gravecaller_chest"))
	check(_worn(b.avatar, "head") != null, "A: the helm shows")
	check(b.avatar.c._gear_tint.any(func(t: Vector4) -> bool: return t.w > 0.0), "A: the chest piece tints the body")
	check(look.looks[1]["g"].has("chest") and look.looks[1]["g"]["chest"][0] == "set_gravecaller_chest", "A: the chest piece is in the look descriptor")
	var applied0 := look.applied
	look.set_gear_from_slots(g.ui_host.inventory.slots)   # nothing changed: nothing is rebuilt
	g.ui_host.inventory.changed.emit(g.ui_host.inventory.slots)
	check(look.applied == applied0, "A: an unchanged bag rebuilds nothing")
	await g.ui.inv.toggle_equip(row.call("sword_copper"))
	check(_worn(b.avatar, "main_hand") == null and b.avatar._staff.visible, "A: unequipping the sword brings the staff back")
	check(_worn(b.avatar, "head") != null, "A: the helm stays when only the sword changed")
	await g.ui.inv.toggle_equip(row.call("sword_copper"))

	# ---- cape and pet from the Capes & Pets panel
	check((await api.adopt_pet(cid, "pet_tithe_bat")).ok, "B: adopt the Tithe Bat")
	await g.ui_host.refresh_inventory()
	await g.ui.pa._cosmetics_act({"cape": "cape_mining"})
	check(b.avatar._cape != null and b.avatar._cape.id == "cape_mining", "B: the panel's cape appears on the hero")
	await g.ui.pa._cosmetics_act({"pet": "pet_tithe_bat"})
	check(look.pet_of(1) != null and look.pet_of(1).id() == "pet_tithe_bat" and look.pet_of(1).c.root.is_inside_tree(), "B: the panel's pet appears")
	var pet := look.pet_of(1)
	b.teleport(Vector3(b.position.x + 12.0, 0, b.position.z))
	check(await until(func() -> bool: return Vector2(pet.x - b.position.x, pet.z - b.position.z).length() < 2.5, 6.0), "B: the pet follows the hero (%.1f m)" % Vector2(pet.x - b.position.x, pet.z - b.position.z).length())

	# ---- hero ring
	check(look._ring.size() == 7 and look._ring.all(func(h: Variant) -> bool: return h != null), "C: the hero ring and halos are laid (7 decals)")

	# ---- perf: a pet + full gear frame, an equip change
	await g.ui.inv.toggle_equip(row.call("set_gravecaller_legs"))
	await ticks(30)
	fc.reset()
	await ticks(180)
	var with_look := fc.median_ms()
	look.set_process(false)
	fc.reset()
	await ticks(180)
	var without_pet := fc.median_ms()
	look.set_process(true)
	print("perf: frame median %.2f ms with pet+gear+cape, %.2f ms with the pet frozen (pet update ~%.2f ms)" % [with_look, without_pet, maxf(0.0, with_look - without_pet)])
	perf_info(with_look < 14.0 and fc.worst_ms() < 150.0, "D: a dressed hero with a pet: frame median %.2f ms under 14, worst %.1f ms under 150" % [with_look, fc.worst_ms()])
	var pu := ms(func() -> void:
		for i in 300:
			pet.update(DT, b.position.x, b.position.z, 0.0))
	print("perf: pet update %.4f ms each" % (pu / 300.0))
	perf_info(pu / 300.0 < 0.5, "D: one pet update costs %.4f ms (under 0.5)" % (pu / 300.0))
	var items: Dictionary = {"main_hand": {"item_id": "sword_copper", "rarity": "common"}}
	var eq_ms := ms(func() -> void:
		b.avatar.set_equipment({}))
	var eq2_ms := ms(func() -> void:
		b.avatar.set_equipment({"main_hand": {"item_id": "sword_copper", "rarity": "common"}, "chest": {"item_id": "set_gravecaller_chest", "rarity": "uncommon"}}))
	print("perf: equip change: unequip all %.2f ms, re-equip sword + chest %.2f ms" % [eq_ms, eq2_ms])
	perf_info(eq_ms < 40.0 and eq2_ms < 40.0, "D: an equip change costs %.2f / %.2f ms (under 40)" % [eq_ms, eq2_ms])
	look.set_gear_from_slots(g.ui_host.inventory.slots)   # restore the bag's look (the direct set_equipment above bypassed the diff)
	b.avatar.set_equipment(DmHeroLook_items(look.looks[1]))

	# ---- leaving: no pet left behind
	var pet_root: Node3D = pet.c.root
	var api0 := api
	await g.leave()
	g.queue_free()
	await ticks(3)
	check(not is_instance_valid(pet_root) or not pet_root.is_inside_tree(), "E: the pet is gone with the game")

	# ---- replication to an in-process ENet client; the client's own look reaches the host
	await _replication(api0, ch.data)
	print("%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


func DmHeroLook_items(d: Dictionary) -> Dictionary:
	var items := {}
	for slot in d["g"]:
		items[slot] = {"item_id": d["g"][slot][0], "rarity": d["g"][slot][1]}
	return items


func _replication(api0: DmApi, ch: Dictionary) -> void:
	var hr := Node.new()
	hr.name = "HostRoot"
	root.add_child(hr)
	var cr := Node.new()
	cr.name = "ClientRoot"
	root.add_child(cr)
	var hg: DmNextGame = load("res://next/next_game.tscn").instantiate()
	hr.add_child(hg)
	var cg: DmNextGame = load("res://next/next_game.tscn").instantiate()
	cr.add_child(cg)
	set_multiplayer(SceneMultiplayer.new(), NodePath("/root/HostRoot"))
	set_multiplayer(SceneMultiplayer.new(), NodePath("/root/ClientRoot"))
	var sp := ENetMultiplayerPeer.new()
	check(sp.create_server(PORT, 4) == OK, "F: ENet server")
	# the host has a bag with the sword on and the cape + pet chosen
	var e := await api0.equip_item(int(ch["id"]), 0, 1)
	await api0.select_cosmetics(int(ch["id"]), {"cape": "cape_mining", "pet": "pet_tithe_bat"})
	await hg.start(ch, api0, {"peer": sp, "dressing": false, "persist": false, "waves": false, "audio": false})
	var cp := ENetMultiplayerPeer.new()
	cp.create_client("127.0.0.1", PORT)
	# the client is another character (a second account) with a different bag: the helm only, no cape, no pet
	var mock2 := DmOffline.make_mock("")
	var api2 := DmOffline.make_api(mock2)
	var r2 := await api2.register("lookb%d" % (Time.get_ticks_usec() % 100000), "b@example.com", "pw1234")
	api2.set_token(r2.data["token"])
	var ch2 := await api2.load_or_create_character(2)
	await api2.save_inventory(int(ch2.data["id"]), [{"slot_index": 0, "item_id": "helm_copper", "quantity": 1, "equipped": 1}], 48)
	await cg.start(ch2.data, api2, {"peer": cp, "host": false, "world": false, "hud": false, "audio": false})
	check(await until(func() -> bool: return cg.session.is_active() and cg.session.get_bodies().size() == 2 and hg.session.get_bodies().size() == 2, 8.0), "F: client joined")
	var hb_on_client := func() -> DmHeroBody: return cg.body_of(1)
	check(await until(func() -> bool:
		var hb: DmHeroBody = hb_on_client.call()
		return hb != null and hb.avatar != null and _worn(hb.avatar, "main_hand") != null, 12.0), "F: the host's weapon shows on the client's puppet")
	var hb: DmHeroBody = hb_on_client.call()
	check(hb.avatar._cape != null and hb.avatar._cape.id == "cape_mining", "F: the host's cape shows on the client")
	check(cg.look.pet_of(1) != null and cg.look.pet_of(1).id() == "pet_tithe_bat", "F: the host's pet shows on the client")
	check(hb.avatar.lantern == null, "F: a puppet carries no lantern (one light, the local hero's)")
	var cb := hg.body_of(cg.session.get_my_id())
	check(await until(func() -> bool: return cb != null and cb.avatar != null and _worn(cb.avatar, "head") != null, 10.0), "F: the client's helm shows on the host's puppet of it")
	check(hg.look.pet_of(cg.session.get_my_id()) == null and cb.avatar._cape == null, "F: the client's no-cape no-pet look is respected")
	# a live change on the host reaches the client
	hg.look.set_cosmetics({"cape": null, "pet": null})
	check(await until(func() -> bool: return hb.avatar._cape == null and cg.look.pet_of(1) == null, 6.0), "F: taking the cape and pet off on the host clears them on the client")
	var sent := hg.look.sent
	hg.look.set_cosmetics({"cape": null, "pet": null})
	check(hg.look.sent == sent, "F: an unchanged look sends nothing")
	var d := hg.look.descriptor()
	print("look descriptor: %d bytes" % var_to_bytes(d).size())
	check(var_to_bytes(d).size() < 400, "F: the look descriptor is compact (%d B)" % var_to_bytes(d).size())
	# a bogus descriptor from a client is dropped
	check(not DmHeroLook._valid({"g": {"nope": ["a", "b"]}, "c": "", "p": ""}) and not DmHeroLook._valid({"g": 3}), "F: a malformed look is refused")
	await hg.leave()
	await cg.leave()
	hg.queue_free()
	cg.queue_free()
	await ticks(3)


## Report-only timing line: tests never assert wall-clock time (owner decision 2026-10-10), so a timing figure is printed, not counted as a check.
## "cond" is whether the old budget would have held; it only changes the wording. Real performance is judged on real hardware (F3 overlay).
func perf_info(cond: bool, what: String) -> void:
	print("INFO perf: %s [%s]" % [what, "within the old budget" if cond else "over the old budget"])
