extends SceneTree
## The HUD on the combat core (client/README.md "The HUD on the core"): the game scene with today's HUD (`hud: true`), headless. It proves the HUD
## reads the core correctly and keeps to its pools:
##   - the target frame: name, hp, elite, affix chips and statuses (`core.statuses(id)` bytes) of the enemy a cast was aimed at, held for 4 s, gone with the enemy;
##   - the minimap: its dot lists equal the core's tables (living enemies, elites flagged, thralls, corpses) and the MultiMesh draws them;
##   - the hotbar: cooldowns after a cast, essence, locked rites, the "no corpse" and "no legion" dimming from the corpses near the hero and the legion, every grey baked on loading;
##   - the thrall count, the pips and the red ones; XP and level; the area name and banner; the death veil;
##   - the floating numbers: the caps (14 hit, 5 dot, 6 thrall, 22 total, crits 4 past), the events that make them (a caster's hit number, a DoT lump, a thrall's blow), the
##     timeline of one number, expiry;
##   - NO NODE PER CREATURE: the scene's node count is the same with 0 and with 100 more enemies, 30 more thralls and 40 floating numbers alive;
##   - the boss plate and his dot on the map while the Gravedigger King is awake, and the fx's banners and toasts (the sink of `bosses.fx.host`);
##   - the keys and the click: the loadout is the kit's with its icons and the signature locked at level 1, a key press casts through the
##     caster (cooldown, essence, the slot's flash, "not ready" on the second press), a click on the bar casts the primary, one hotbar listener, a hit number is drawn on the float layer,
##     damage taken floats and flashes, the minimap's destination mark, the Reliquary counts a picked-up drop, and the HUD applies at about 20 Hz;
##   - the pieces: each readout group has its anchors, moves and scales around its corner, hides for good; the HUD scale;
##   - the atlas and the drawing helpers: 9-patch pixels against what StyleBoxFlat draws, regions and their padding, the z layers of text, the meshes, the sweep;
##   - the per-frame work kept small ("The HUD's budget", CPU): a NEW glow's and an empowered slot's pulse and a cast flash fade a layer drawn once (no redraw per frame, the same
##     strength at every instant), a rite on cooldown changes its text and sweep and nothing else, a mesh appended again at the same place is one array copy, the readouts are applied
##     by section (a moving Kill Chain meter does not apply the belt), the counsel's timers wait for the earliest one due.
## Gets the robber and the hound into a scratch folder first (the checkout's baked models when tools/check/prep.sh made them, else a bake: common/dm_test_bake.gd). Run: godot --headless --path client --script res://tests/hud.gd  (--fixed-fps 60 before --path is faster)

const DmTestBake := preload("res://tests/common/dm_test_bake.gd")
const OUT := "user://hud_test"
const BAKE := ["grave_robber", "bone_hound"]
const THRALL_BASE := {"warrior": [1.3, 1.0, 5.6], "hound": [1.2, 0.7, 7.2], "archer": [7.5, 1.3, 5.4]}

class ErrorLog:
	extends Logger
	var errors: Array[String] = []

	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _backtraces: Array[ScriptBacktrace]) -> void:
		if error_type != Logger.ERROR_TYPE_WARNING:
			errors.append("%s:%d %s %s %s" % [file, line, function, code, rationale])

var fails := 0
var checks := 0
var errlog := ErrorLog.new()
var g: DmNextGame
var h: HudShim              # the HUD as the test drives it (tests/hud_shim.gd)
var hud: DmHud
var host: DmCoreHost
var core: RefCounted
var hero: DmHeroBody
var caster: DmRiteCaster
var feed: Array = []        ## the adapter's game events since the keys and the click began: {id, ctx}


func check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		fails += 1
		printerr("FAIL hud: " + what)


func near(a: float, b: float, eps := 1.0e-3) -> bool:
	return absf(a - b) <= eps


## Pixels are bytes: colours match to a quarter of a step.
func same(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) < 0.01 and absf(a.g - b.g) < 0.01 and absf(a.b - b.b) < 0.01 and absf(a.a - b.a) < 0.01


func ticks(n: int) -> void:
	var target := Engine.get_physics_frames() + n
	while Engine.get_physics_frames() < target:
		await physics_frame


func until(cond: Callable, limit_ticks: int) -> bool:
	var end := Engine.get_physics_frames() + limit_ticks
	while not bool(cond.call()) and Engine.get_physics_frames() < end:
		await physics_frame
	return bool(cond.call())


func nodes() -> int:
	return int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))


func _initialize() -> void:
	await process_frame
	OS.add_logger(errlog)
	atlas_and_helpers()
	DirAccess.make_dir_recursive_absolute(OUT)
	for slug in BAKE:
		var r: Dictionary = DmTestBake.bake(root, slug, OUT.path_join(slug), {"rows_path": "res://game/view_models.json"})
		check(r.ok, "bake %s: %s" % [slug, r.get("error", "")])
		if not r.ok:
			quit(1)
			return
	var mock := DmOffline.make_mock("")
	var api := DmOffline.make_api(mock)
	var reg := await api.register("tester", "t@example.com", "pw1234")
	api.set_token(reg.data["token"])
	var ch := await api.load_or_create_character(2)
	DmDevMock.set_level(mock, ch.data, 20)
	ch.data["experience"] = 1234
	g = load("res://next/next_game.tscn").instantiate()
	g.name = "NextGame"
	root.add_child(g)
	await g.start(ch.data, api, {"areas": ["graves"], "name": "tester", "hud": true, "audio": false, "waves": false, "wander": false, "seed": 20261016, "baked_dir": OUT})
	h = HudShim.new(g)
	check(g.ready_ and g.ui != null and g.ui.hud is DmHud and g.ui_host != null, "the game scene is up with today's HUD and panels on the adapter (hud: true)")
	hud = g.ui.hud
	check(not g.ui._vm.is_empty() and hud.minimap != null and hud.visible, "the first HUD apply happened during start (loading), before any played frame")
	host = g.core_host
	core = host.core
	hero = g.local_body()
	caster = hero.get_node("Rites") as DmRiteCaster
	await ticks(5)
	the_frame()
	await hotbar_and_cooldowns()
	await corpse_and_legion_dimming()
	await thralls_and_pips()
	await minimap_dots()
	await target_frame()
	await floats_caps()
	await floats_from_events()
	await no_node_per_creature()
	await death_veil()
	pieces()
	await layers()
	await per_frame_work()
	await draw_model()
	await keys_and_click()
	await boss_plate()
	check(errlog.errors.is_empty(), "no script or engine errors in the log (%d: %s)" % [errlog.errors.size(), str(errlog.errors.slice(0, 3))])
	await finish()


func finish() -> void:
	print("INFO atlas: %d px of %d + %d packed, %d uploads" % [DmHudAtlas.used_pixels(), DmHudAtlas.SIZE * DmHudAtlas.SIZE, DmHudAtlas.PANEL_SIZE * DmHudAtlas.PANEL_SIZE, DmHudAtlas.uploads()])
	if fails == 0:
		print("PASS hud %d checks" % checks)
	else:
		print("FAIL hud: %d of %d checks" % [fails, checks])
	g.queue_free()
	await process_frame
	quit(1 if fails > 0 else 0)


# ------------------------------------------------------------------------------------------------------------------ atlas and helpers

func atlas_and_helpers() -> void:
	DmHudAtlas.reset()
	# a 9-patch against what StyleBoxFlat draws: fill, a one pixel border ring, the corner rounded
	var bg := Color(0.2, 0.4, 0.6, 0.5)
	var bd := Color(1.0, 0.0, 0.0, 1.0)
	var n1 := DmHudAtlas.nine_image(bg, bd, 1, 1, 1, 1, 0, 1)
	check(n1.get_width() == 3 and same(n1.get_pixel(1, 1), bg) and same(n1.get_pixel(0, 1), bd) and same(n1.get_pixel(0, 0), bd), "a square 1 px panel: border ring, fill inside")
	var n3 := DmHudAtlas.nine_image(bg, bd, 1, 1, 1, 1, 3, 3)
	check(n3.get_width() == 7 and n3.get_pixel(0, 0).a < 0.05 and same(n3.get_pixel(3, 3), bg) and same(n3.get_pixel(3, 0), bd) and same(n3.get_pixel(0, 3), bd),
		"a radius 3 panel: the corner pixel is outside, the edges are border, the middle is fill")
	check(n3.get_pixel(1, 1).a > 0.1 and n3.get_pixel(1, 1).a < 1.0, "the rounded corner is anti-aliased (partial coverage)")
	var nl := DmHudAtlas.nine_image(bg, bd, 3, 0, 0, 0, 0, 3)
	check(same(nl.get_pixel(0, 3), bd) and same(nl.get_pixel(2, 0), bd) and same(nl.get_pixel(3, 0), bg) and same(nl.get_pixel(6, 6), bg),
		"a 3 px left rule and no other border (the omen and ward chips)")
	var nb := DmHudAtlas.nine_image(bg, Color(0, 0, 0, 0), 0, 0, 0, 0, 0, 1)
	check(same(nb.get_pixel(0, 0), bg), "no border: the fill reaches the rim")
	# regions: packed apart, each with its edge repeated outward
	var a_img := Image.create_empty(8, 8, false, Image.FORMAT_RGBA8)
	a_img.fill(Color.RED)
	var b_img := Image.create_empty(5, 6, false, Image.FORMAT_RGBA8)
	b_img.fill(Color.BLUE)
	var ra := DmHudAtlas.add("test_a", a_img)
	var rb := DmHudAtlas.add("test_b", b_img)
	check(ra.size == Vector2i(8, 8) and rb.size == Vector2i(5, 6) and not ra.intersects(rb.grow(1)) and not ra.grow(1).intersects(rb), "two regions are packed apart, a pixel of padding between")
	check(same(DmHudAtlas._main.image.get_pixelv(ra.position), Color.RED) and same(DmHudAtlas._main.image.get_pixelv(ra.position - Vector2i(1, 1)), Color.RED)
		and same(DmHudAtlas._main.image.get_pixelv(rb.end), Color.BLUE), "a region's edge pixels are repeated one pixel outward (linear filtering reads no neighbour)")
	check(DmHudAtlas.add("test_a", b_img) == ra, "a key already packed keeps its region")
	var w := DmHudAtlas.white()
	check(w.size == Vector2(2, 2) and same(DmHudAtlas._main.image.get_pixelv(Vector2i(w.position)), Color.WHITE), "the white block")
	var gr := DmHudAtlas.gradient(Color.BLACK, Color.WHITE)
	check(gr.size.x == 64 and DmHudAtlas._main.image.get_pixelv(Vector2i(gr.position)).r < 0.05 and DmHudAtlas._main.image.get_pixelv(Vector2i(gr.position) + Vector2i(63, 0)).r > 0.95, "a gradient strip runs from the first colour to the second")
	check(DmHudAtlas.icon("res://nothing/here.webp") == null, "an icon that does not exist is null")
	check(DmHudAtlas.icon("res://assets/game/art/abilities/necro-bone-fan.webp") != null or not FileAccess.file_exists("res://assets/game/art/abilities/necro-bone-fan.webp.import"), "an icon that exists loads (headless: the texture itself)")
	# a style is a 9-patch of the atlas with the margins the StyleBoxFlat had
	var st := DmHudKit.plate(bg, bd, Vector4(1, 1, 1, 1), Vector4(8, 4, 12, 6), 2)
	check(st.texture == DmHudAtlas.panel_texture and st.get_margin(SIDE_LEFT) == 8.0 and st.get_margin(SIDE_TOP) == 4.0 and st.get_margin(SIDE_RIGHT) == 12.0 and st.get_margin(SIDE_BOTTOM) == 6.0,
		"a plate draws from the atlas and keeps the padding as its content margins")
	check(DmHudKit.style(bg, bd) is StyleBoxFlat, "the copied panels still get a StyleBoxFlat from DmHudKit.style")
	# text layers: one per (font, size), a spaced font shares its base's
	var f1 := DmUi.font("body")
	check(DmHudKit.text_z(f1, 12) == DmHudKit.text_z(f1, 12) and DmHudKit.text_z(f1, 12) != DmHudKit.text_z(f1, 13) and DmHudKit.text_z(f1, 12) != DmHudKit.text_z(DmUi.font("numeric"), 12),
		"a text layer per (font, size)")
	check(DmHudKit.text_z(DmHudKit.spaced("body", 2.0), 12) == DmHudKit.text_z(f1, 12), "a letter-spaced font shares its base font's layer")
	var z := DmHudKit.text_z(f1, 12)
	check(z >= DmHudKit.Z_TEXT and z < DmHudKit.Z_OVERLAY, "text sits above the chrome and the art, below the overlay pieces (%d)" % z)
	var l := DmHudKit.lbl("x", 12, Color.WHITE, "body", true, 2.0)
	check(l.z_index == z, "a HUD label is put on its layer when it is made")
	# meshes
	var m := DmHudMesh.new()
	m.disc(Vector2.ZERO, 5.0, Color.WHITE)
	check(m.idx.size() == 64 * 3 and m.pts.size() == 65, "a disc is the 64 triangle fan draw_circle makes")
	m.ring(Vector2.ZERO, 5.0, 7.0, Color.RED, 16)
	check(m.idx.size() == 64 * 3 + 16 * 6, "a ring is a strip of quads")
	var m2 := DmHudMesh.new()
	m2.rect(Rect2(0, 0, 2, 2), Color.RED)
	m2.append(m)
	check(m2.idx.size() == 6 + m.idx.size() and m2.idx[6] == 4, "an appended bag keeps its triangles (indices shifted)")
	check(m.to_mesh().get_surface_count() == 1, "a bag becomes one ArrayMesh surface")
	# the cooldown sweep
	var half := DmHudSlot.BTN * 0.5
	var c := Vector2(half, half)
	check(DmHudSlot._square_point(-PI * 0.5, c, half).is_equal_approx(Vector2(half, 0.0)) and DmHudSlot._square_point(0.0, c, half).is_equal_approx(Vector2(DmHudSlot.BTN, half))
		and DmHudSlot._square_point(PI * 0.25, c, half).is_equal_approx(Vector2(DmHudSlot.BTN, DmHudSlot.BTN)), "the sweep's ray leaves the square at the top, the right edge and the corner")
	# one floating number's timeline: the three tweens of the old label
	var p0 := DmHudFloats.pose(0.0, 1.0)
	var p1 := DmHudFloats.pose(0.12, 1.0)
	var p2 := DmHudFloats.pose(0.52, 1.0)
	var p3 := DmHudFloats.pose(0.65, 1.0)
	var p4 := DmHudFloats.pose(1.0, 1.0)
	check(near(p0.x, 0.7) and near(p0.y, 0.0) and near(p0.z, 1.0) and near(p1.x, 1.2) and near(p2.x, 1.0) and near(p3.z, 1.0) and near(p4.z, 0.0) and near(p4.y, 46.0) and near(DmHudFloats.pose(0.32, 1.0).x, 1.1),
		"a number pops 0.7 to 1.2 to 1.0, rises 46 px and fades over the last 35 % of its life")
	check(DmHudMinimap.MAX_DOTS >= 300, "the minimap's MultiMesh holds a Full Party's dots")


# ------------------------------------------------------------------------------------------------------------------ the frame

func the_frame() -> void:
	h.refresh()
	var vm := h.last_vm()
	check(not vm.is_empty() and h.refreshes >= 1, "the HUD built and applied a view-model (%d refreshes)" % h.refreshes)
	check(near(float(vm["hp"]), hero.hp) and near(float(vm["max_hp"]), hero.max_hp) and near(hud.hp_orb.fill, hero.hp / hero.max_hp, 0.01), "the health orb reads the hero's health")
	check(near(float(vm["essence"]), hero.resource) and near(hud.ess_orb.fill, hero.resource / hero.resource_max, 0.01), "the resource orb reads the hero's essence")
	check(int(vm["level"]) == 20 and hud.level_badge.text.text == "20", "the level badge shows the character's level")
	check(hud.xp_txt.text.begins_with("1,234 / ") and near(hud.xp_bar.value, 1234.0 / DmStats.xp_to_next(20.0), 0.01), "XP and the next level: '%s'" % hud.xp_txt.text)
	check(hud.area_lbl.text == "THE HOLLOW GRAVES", "the area name: '%s'" % hud.area_lbl.text)
	check(hud.banner_active(), "the area's banner is up on entering it")
	var t0 := hud.toasts.get_child_count()   # a first run (a fresh user folder, as in CI) already shows one of the game's own toasts here
	var up: Array = []
	for t in hud.toasts.get_children():
		up.append(" / ".join(t.find_children("*", "Label", true, false).map(func(l: Node) -> String: return (l as Label).text)))
	print("INFO hud: toasts already up: %s" % str(up))
	hud.toast("The dead answer you more readily", "good")
	hud.toast("A crypt cracks open", "")
	check(hud.toasts.get_child_count() == t0 + 2, "toasts stack (%d, %d before)" % [hud.toasts.get_child_count(), t0])
	var party: Array = vm["party"]
	check(party.size() == 1 and party[0]["name"] == "tester" and hud.party_box.get_child_count() == 1, "the party list shows this hero")
	var shown_btns: Array = []
	for id in hud.menu_btns:
		if hud.menu_btns[id].visible:
			shown_btns.append(id)
	check(hud.menu_flow.visible and shown_btns.has("inventory") and shown_btns.has("friends") and shown_btns.has("settings"), "the menu row shows today's buttons: the Reliquary, Social and Settings among them (%s)" % str(shown_btns))
	check(g.ui.social_ui != null and not g.ui.is_open("friends") and not g.ui.is_open("party"), "the Social window is there, closed")
	check(hud.chat_col.visible, "the chat column shows")
	check(hud.up_plate.visible and g.ui.reveal.has("hud.upgrades"), "the upgrades box shows for a character that has earned (level %d: DmHudReveal.veteran_reveals)" % int(g.character["level"]))
	check(near(hud.hud_scale, DmSettings.clamp_hud_scale(g.ui_host.settings.get("hud_scale", 1.0))), "the HUD scale is the player's setting (%.2f)" % hud.hud_scale)
	hud.set_layout({})
	hud.set_hud_scale(1.0)


func hotbar_and_cooldowns() -> void:
	var vm := h.last_vm()
	var slots: Array = vm["slots"]
	check(slots.size() == 6 and slots[0]["key"] == "1" and slots[4]["key"] == "RMB" and slots[5]["key"] == "R" and vm["primary"]["key"] == "LMB", "the hotbar: LMB, keys 1-4, RMB and R")
	var rite0 := String(h.keys[0])
	check(rite0 == "marrow_spear" and hud._slots.size() == 6, "slot 1 is the kit's Marrow Spear (%s)" % rite0)
	check(slots[0]["left_ms"] == 0.0 and not bool(slots[0]["locked"]) and bool(slots[0]["affordable"]), "idle, unlocked and affordable before the cast")
	hero.resource = hero.resource_max
	var aim := hero.position + Vector3(0, 0, -6)
	caster.request_cast(rite0, aim, -1)
	await ticks(4)
	h.refresh()
	var s0: Dictionary = h.last_vm()["slots"][0]
	var left := caster.cooldown_left(rite0)
	check(left > 0.0 and near(float(s0["left_ms"]), left, 1.0) and float(s0["total_ms"]) >= float(s0["left_ms"]), "after a cast the slot carries the caster's cooldown (%.0f of %.0f ms)" % [left, s0["total_ms"]])
	check(hud._slots[0]._cdtext.text != "" and DmHudSlot.cd_pct(left, float(s0["total_ms"])) > 0, "the slot shows the seconds and a sweep ('%s')" % hud._slots[0]._cdtext.text)
	check(float(h.last_vm()["essence"]) < hero.resource_max or float(s0["cost"]) == 0.0, "the cast spent essence (the orb follows)")
	var packed := DmHudAtlas.used_pixels()
	hero.resource = 0.0
	h.refresh()
	var s1: Dictionary = h.last_vm()["slots"][0]
	check(not bool(s1["affordable"]) and hud._slots[0]._dim == DmHudAtlas.DIM_HARD, "without essence the slot dims (the greyed variant of its icon)")
	check(DmHudAtlas.used_pixels() == packed, "the greyed icons were baked on loading (DmNextHudVm.warm_icons): dimming every slot bakes nothing in the fight (%d -> %d px)" % [packed, DmHudAtlas.used_pixels()])
	hero.resource = hero.resource_max
	h.refresh()
	await process_frame
	check(bool(h.last_vm()["slots"][0]["affordable"]) and hud._slots[0]._dim == 0, "with essence it is back to normal")
	check(float(h.vm._rite(rite0)["unlock"]) <= 20.0 and not bool(h.last_vm()["slots"][0]["locked"]), "the rite is unlocked at level 20")


func corpse_and_legion_dimming() -> void:
	var exhume := h.keys.find("exhume")
	check(exhume >= 0, "Exhume is on the bar")
	for id in core.corpse_ids():
		core.corpse_consume(id, hero.owner_peer, "consumed")
	await ticks(2)
	var packed := DmHudAtlas.used_pixels()
	h.refresh()
	check(DmHudAtlas.used_pixels() == packed, "the \"no corpse\" grey was baked on loading too (%d -> %d px)" % [packed, DmHudAtlas.used_pixels()])
	var s: Dictionary = h.last_vm()["slots"][exhume]
	check(s["needs"] == "corpse" and hud._slots[exhume].needs == "corpse" and hud._slots[exhume]._dim == DmHudAtlas.DIM_SOFT, "no corpse near the hero: Exhume says so and is dimmed")
	check(hud._slots[exhume]._need.text == "no corpse", "the slot's note: '%s'" % hud._slots[exhume]._need.text)
	var far: int = core.corpse_add(Vector2(hero.position.x + 20.0, hero.position.z), "normal", "robber", false, 0.0, 1.0, "graves")
	await ticks(1)
	h.refresh()
	check(far != 0 and h.last_vm()["slots"][exhume]["needs"] == "corpse", "a corpse beyond the 13 m reach does not count")
	var near_id: int = core.corpse_add(Vector2(hero.position.x + 4.0, hero.position.z), "normal", "robber", false, 0.0, 1.0, "graves")
	await ticks(1)
	h.refresh()
	check(near_id != 0 and h.last_vm()["slots"][exhume]["needs"] == "" and hud._slots[exhume].needs == "", "a corpse within reach: the note is gone")
	var rend := 5 if h.signature == "command_rend" else -1
	if rend >= 0:
		check(h.last_vm()["slots"][rend]["needs"] == "legion", "no thralls: the signature (Command: Rend) needs a legion")
	for id in core.corpse_ids():
		core.corpse_consume(id, hero.owner_peer, "consumed")


func thralls_and_pips() -> void:
	var cap := int(hero.mods.get("thrallCap", 0))
	check(cap > 0 and h.last_vm()["thrall_cap"] == cap and hud.thrall_num.text == "0/%d" % cap, "no thralls: 0/%d" % cap)
	var ids: Array = []
	for i in cap:
		var base: Array = THRALL_BASE["warrior"]
		ids.append(int(core.raise_thrall({"kind": "warrior", "hp": 40.0, "maxHp": 40.0, "damage": 1.0, "attackInterval": base[1], "range": base[0], "speed": base[2], "empowered": false,
			"champion": false, "allyHeal": 0.0}, hero.core_id, Vector2(hero.position.x + float(i), hero.position.z + 3.0), 0.0, float(cap))))
	await ticks(2)
	h.refresh()
	var vm := h.last_vm()
	var places := int(core.thrall_places(hero.core_id))
	check(places == cap and vm["thralls"] == places and hud.thrall_num.text == "%d/%d" % [places, cap], "a full legion: the chip says %s" % hud.thrall_num.text)
	check(hud.thrall_pips.on.size() == cap and hud.thrall_pips.on.count(false) == cap - places, "the pips: one per place of the cap, %d lit" % places)
	check(vm["thrall_hurt"] == 0, "none hurt")
	core.set_thrall_stats(ids[0], {"hp": 5.0})
	core.set_thrall_stats(ids[1], {"hp": 13.0})
	core.set_thrall_stats(ids[2], {"hp": 14.5})   # 14.5 of 40 is above the third (35 % = 14)
	await ticks(1)
	h.refresh()
	check(h.last_vm()["thrall_hurt"] == 2 and hud.thrall_pips.on.count(2) == 2, "two under 35 %% are red (%d)" % int(h.last_vm()["thrall_hurt"]))
	check(int(h.last_vm()["minimap"]["thralls"].size() / 3) == cap, "the minimap shows all %d" % cap)
	if hero.mods.get("wardPerThrall", 0.0) > 0.0:
		check(h.last_vm()["ward"] != null and hud.ward.visible, "Bone Ward shows with thralls")
	for id in ids:
		core.kill_thrall(id, "killed")
	await ticks(2)
	h.refresh()
	check(h.last_vm()["thralls"] == 0 and hud.thrall_num.text == "0/%d" % cap, "no thralls again")


func minimap_dots() -> void:
	var alive_before := host.alive_count()
	var made := PackedInt32Array()
	var elites := 0
	for i in 60:
		var a := float(i) / 60.0 * TAU
		var p := hero.position + Vector3(cos(a), 0.0, sin(a)) * (10.0 + float(i % 5))
		var elite := i % 12 == 5
		elites += 1 if elite else 0
		made.append(host.spawn_enemy("robber" if i % 3 != 0 else "hound", p, 1, 1000.0, 0.0, elite, "graves", false))
	var tids: Array = []
	for i in 12:
		var base: Array = THRALL_BASE["hound"]
		tids.append(int(core.raise_thrall({"kind": "hound", "hp": 1.0e6, "maxHp": 1.0e6, "damage": 0.0, "attackInterval": base[1], "range": base[0], "speed": base[2], "empowered": false,
			"champion": false, "allyHeal": 0.0}, hero.core_id, Vector2(hero.position.x + float(i) - 6.0, hero.position.z + 3.0), 0.0, 20.0)))
	for i in 7:
		core.corpse_add(Vector2(hero.position.x - 8.0 + i, hero.position.z + 6.0), "normal", "robber", false, 0.0, 1.0, "graves")
	await ticks(3)
	h.refresh()
	await process_frame
	var mm: Dictionary = h.last_vm()["minimap"]
	var living := host.alive_count()
	check(mm["enemies"].size() == living * 3, "the minimap has a dot per living enemy: %d of %d in the core" % [mm["enemies"].size() / 3, living])
	var flagged := 0
	for i in mm["enemies"].size() / 3:
		flagged += int(mm["enemies"][i * 3 + 2])
	check(flagged >= elites and flagged == _elite_count(), "elites are flagged: %d" % flagged)
	check(mm["thralls"].size() == 12 * 3 and mm["corpses"].size() == int(core.corpse_count()) * 4, "thralls and corpses: %d and %d, as the core has them" % [mm["thralls"].size() / 3, mm["corpses"].size() / 4])
	check(near(float(mm["px"]), hero.position.x) and near(float(mm["pz"]), hero.position.z), "the map is centred on the hero")
	var map_node: Object = hud.minimap._mask.get_child(0)
	check(map_node.dots_drawn == living + 12 + int(core.corpse_count()), "the MultiMesh draws every dot in view (%d)" % map_node.dots_drawn)
	# a dead enemy leaves the map at once, though the core keeps its body for 4 s
	for i in 5:
		host.damage(made[i], 1.0e9, hero.core_id, false)
	await ticks(2)
	h.refresh()
	check(h.last_vm()["minimap"]["enemies"].size() == host.alive_count() * 3 and host.enemy_total() > host.alive_count(), "the dead are not dots (the core holds %d bodies, %d alive)" % [host.enemy_total(), host.alive_count()])
	# a corpse is a dot too and it leaves when it is eaten
	var corpses := int(core.corpse_count())
	for id in core.corpse_ids():
		core.corpse_consume(id, hero.owner_peer, "consumed")
	await ticks(2)
	h.refresh()
	check(corpses > 0 and h.last_vm()["minimap"]["corpses"].size() == int(core.corpse_count()) * 4, "eaten corpses are gone from the map")
	# the click on the map: its centre is the hero, and a click on walkable ground asks the hero to walk there
	var map: Dictionary = h.last_vm()["minimap"]
	check(DmHudMinimap.walkable(hero.position.x, hero.position.z, map) and not DmHudMinimap.walkable(hero.position.x + 500.0, hero.position.z, map), "ground in the loaded area is walkable, beyond it is not")
	var walked := [Vector2.INF]
	hud.navigate.connect(func(x: float, z: float) -> void: walked[0] = Vector2(x, z))
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = Vector2(2.0 + 95.0 + 20.0, 2.0 + 95.0)
	hud.minimap._gui_input(click)
	check(walked[0] != Vector2.INF and near(walked[0].x, hero.position.x + 20.0 / DmHudMinimap.SCALE, 0.05), "a click on the map names the ground under it (%s)" % str(walked[0]))
	click.position = Vector2(2.0 + 95.0, 2.0 + 95.0)
	hud.minimap._gui_input(click)
	check(near(walked[0].x, hero.position.x, 0.05) and near(walked[0].y, hero.position.z, 0.05), "the centre of the map is the hero")
	walked[0] = Vector2.INF
	click.position = Vector2(2.0, 2.0)   # a corner of the square map: outside the disc
	hud.minimap._gui_input(click)
	check(walked[0] == Vector2.INF, "a click outside the disc names nothing")
	var travel := [Vector2.INF]
	h.game.input.clicked_move.connect(func(p: Vector3) -> void: travel[0] = Vector2(p.x, p.z))
	hud.navigate.emit(hero.position.x + 3.0, hero.position.z)
	check(travel[0] != Vector2.INF, "and the game scene walks the hero there (the adapter routes navigate to the input)")
	# tidy: kill what was made, remove the thralls
	for id in made:
		if host.enemy_alive(id):
			host.damage(id, 1.0e9, hero.core_id, false)
	for id in tids:
		core.kill_thrall(id, "killed")
	await ticks(2)


func _elite_count() -> int:
	var n := 0
	for id in core.enemy_ids():
		if core.enemy_info(id)["elite"] and int(core.enemy_info(id)["state"]) != DmCoreEvents.State.DEAD:
			n += 1
	return n


func target_frame() -> void:
	var made := host.spawn_enemy("robber", hero.position + Vector3(0, 0, -9), 3, 2.0, 0.0, true, "graves", false, PackedStringArray(["hungering", "vengeful"]))
	await ticks(3)
	var info: Dictionary = core.enemy_info(made)
	h._on_hotbar(0, Vector3.ZERO, made)
	for st in [["chill", 1.0], ["fracture", 3.0], ["withered", 2.0]]:
		host.apply_status(made, st[0], hero.core_id, st[1], 60.0)
	await ticks(2)
	h.refresh()
	var t: Variant = h.last_vm()["target"]
	check(t != null and t["name"] == DmContent.enemy("robber")["name"], "the frame names the enemy: %s" % str(t["name"] if t != null else "none"))
	check(t != null and bool(t["elite"]) and near(float(t["hp"]), float(info["hp"])) and near(float(t["max_hp"]), float(info["max_hp"])), "elite flag, hp %s of %s from the core" % [str(t["hp"]), str(t["max_hp"])])
	var ed: Dictionary = DmContent.get_export("enemies", "ELITE_AFFIXES")
	var names: Array = []
	for c in t["affixes"]:
		names.append(c["name"])
	check(names == [ed["hungering"]["name"], ed["vengeful"]["name"]], "affix chips are the core's affixes: %s" % str(names))
	var labels: Dictionary = {}
	for s in t["statuses"]:
		labels[s["label"]] = int(s["n"])
	check(labels.get("Chilled") == 1 and labels.get("Fracture") == 3 and labels.get("Withered") == 2, "statuses from the core's bytes with their stacks: %s" % str(labels))
	check(t["statuses"].size() == core.statuses(made).size() / 4, "one chip per status the core reports (%d)" % t["statuses"].size())
	check(hud.target_box.visible and not hud.boss.visible and near(hud.target_bar.value, float(t["hp"]) / float(t["max_hp"]), 0.001), "the target plate is up, its bar at the enemy's health")
	check(hud.target_name_row.get_child_count() >= 3 and hud.target_stat.get_child_count() == t["statuses"].size(), "name, ELITE and two chips; a chip per status")
	# hurt it: the bar follows the core
	host.damage(made, float(info["max_hp"]) * 0.4, hero.core_id, false)
	h.refresh()
	check(near(hud.target_bar.value, core.enemy_info(made)["hp"] / core.enemy_info(made)["max_hp"], 0.001), "the bar follows the damage")
	# a status past the byte (Withered goes to the thousands) prints its real stacks
	host.apply_status(made, "withered", hero.core_id, 400.0, 60.0)
	h.refresh()
	var w := 0
	for s in h.last_vm()["target"]["statuses"]:
		if s["label"] == "Withered":
			w = int(s["n"])
	check(w == 402, "Withered stacks past 255 are the core's real count (%d)" % w)
	# it goes when the cursor lets go and the hold runs out; and with the enemy
	h._target_until = 0.0
	h.refresh()
	check(h.last_vm()["target"] == null and not hud.target_box.visible, "four seconds after the last cast the frame is gone")
	h._on_hotbar(0, Vector3.ZERO, made)
	h.refresh()
	check(h.last_vm()["target"] != null, "a cast brings it back")
	host.damage(made, 1.0e9, hero.core_id, false)
	await ticks(2)
	h.refresh()
	check(h.last_vm()["target"] == null, "a dead enemy has no frame")
	h._target_until = 0.0


# ------------------------------------------------------------------------------------------------------------------ floating numbers

func floats_caps() -> void:
	var fl: DmHudFloats = hud.float_layer
	h._on_hotbar(0, Vector3.ZERO, 0)
	fl._time += 100.0   # everything old expires
	fl._process(0.0)
	check(fl.alive == 0, "no number alive to start with")
	h.floats = DmFloatBudget.new()
	var p := hero.position + Vector3(0, 1.6, -3)
	var now := 1_000_000.0
	for i in 40:
		h.float_text(p + Vector3(i * 0.1, 0, 0), str(i), "hit", null, now)
	check(fl.alive == 14, "14 hit numbers live at most (%d)" % fl.alive)
	for i in 10:
		h.float_text(p, "1", "dot", null, now)
	check(fl.alive == 14 + 5, "5 dot numbers beside them (%d)" % fl.alive)
	for i in 10:
		h.float_text(p, "1", "thrall", null, now)
	check(fl.alive == 22, "6 thrall numbers would be 25: 22 in all (%d)" % fl.alive)
	h.float_text(p, "999", "crit", null, now)
	check(fl.alive == 23, "a crit may go 4 past the class cap and the total (%d)" % fl.alive)
	h.float_text(p, "x", "info", null, now)
	h.float_text(p, "-12", "hurt", null, now)
	check(fl.alive == 25, "words and the hero's own hurt numbers are never limited (%d)" % fl.alive)
	# the numbers rise and fade, then free their slots; later ones are allowed again
	now += 900.0
	fl._process(0.9)
	check(fl.alive <= 3, "after a second only the 1.6 s words are left (%d)" % fl.alive)
	for i in 10:
		h.float_text(p, str(i), "hit", null, now)
	check(fl.alive >= 10, "the budget lets new hit numbers in after theirs expired (%d)" % fl.alive)
	check(fl.get_child_count() == 0, "no node was made for any number")
	fl._process(5.0)
	check(fl.alive == 0, "all expired")
	# the setting turns the combat numbers off, not the words
	h.damage_numbers = false
	h.float_text(p, "5", "hit", null, now + 5000.0)
	h.float_text(p, "word", "info", null, now + 5000.0)
	check(fl.alive == 1, "damage numbers off: hits are dropped, words are not")
	h.damage_numbers = true
	fl._process(5.0)


func floats_from_events() -> void:
	var fl: DmHudFloats = hud.float_layer
	h.floats = DmFloatBudget.new()
	fl._process(10.0)
	var made := host.spawn_enemy("robber", hero.position + Vector3(2, 0, -7), 1, 1000.0, 0.0, false, "graves", false)
	var base: Array = THRALL_BASE["warrior"]
	var tid := int(core.raise_thrall({"kind": "warrior", "hp": 1.0e6, "maxHp": 1.0e6, "damage": 0.0, "attackInterval": base[1], "range": base[0], "speed": base[2], "empowered": false,
		"champion": false, "allyHeal": 0.0}, hero.core_id, Vector2(hero.position.x, hero.position.z - 5.0), 0.0, 20.0))
	await ticks(3)
	var before := fl.alive
	caster.hit_number.emit(hero.position + Vector3(0, 0, -7), 42.0, false)
	check(fl.alive == before + 1, "a rite's hit number is a float (the caster's hit_number signal)")
	host.enemy_damaged.emit(made, tid, 17.0, 100.0)
	check(fl.alive == before + 2, "a thrall's blow on an enemy is a float, over the enemy")
	host.enemy_damaged.emit(made, hero.core_id, 17.0, 100.0)
	check(fl.alive == before + 2, "the hero's own blow is not counted twice (his rites send hit_number)")
	host.status_dot.emit(made, 7, hero.core_id, false, 6.0)
	check(fl.alive == before + 3, "a DoT lump is a float")
	hero.hurt.emit(12.0, 0)
	check(fl.alive == before + 4, "a blow on the hero is a float")
	core.kill_thrall(tid, "killed")
	host.damage(made, 1.0e9, hero.core_id, false)
	await ticks(2)
	fl._process(10.0)


# ------------------------------------------------------------------------------------------------------------------ pools

func no_node_per_creature() -> void:
	var fl: DmHudFloats = hud.float_layer
	h.refresh()
	await process_frame
	await process_frame
	var n0 := nodes()
	var children0 := hud.safe.get_child_count()
	var made := PackedInt32Array()
	for i in 100:
		var a := float(i) / 100.0 * TAU
		made.append(host.spawn_enemy("robber" if i % 3 != 0 else "hound", hero.position + Vector3(cos(a), 0.0, sin(a)) * (8.0 + float(i % 7) * 2.0), 1, 1000.0, 0.0, i % 20 == 5, "graves", false))
	var tids: Array = []
	for i in 30:
		var base: Array = THRALL_BASE["hound"]
		tids.append(int(core.raise_thrall({"kind": "hound", "hp": 1.0e6, "maxHp": 1.0e6, "damage": 0.0, "attackInterval": base[1], "range": base[0], "speed": base[2], "empowered": false,
			"champion": false, "allyHeal": 0.0}, hero.core_id, Vector2(hero.position.x + float(i % 10) - 5.0, hero.position.z + 2.0 + float(i / 10)), 0.0, 40.0)))
	await ticks(3)
	for i in 40:
		h.float_text(hero.position + Vector3(float(i % 9) - 4.0, 1.6, -2.0), str(i), ["hit", "crit", "dot", "thrall"][i % 4], null, 5_000_000.0 + i)
	h.refresh()
	await process_frame
	await process_frame
	check(fl.alive > 0 and hud.minimap._mask.get_child(0).dots_drawn >= 130, "130 creatures on the map and numbers in the air (%d dots, %d numbers)" % [hud.minimap._mask.get_child(0).dots_drawn, fl.alive])
	check(nodes() == n0, "the scene tree has the same %d nodes with 100 more enemies, 30 more thralls and numbers alive (%d)" % [n0, nodes()])
	check(hud.safe.get_child_count() == children0 and fl.get_child_count() == 0, "the HUD grew no node: the minimap and the numbers are pools")
	for id in made:
		if host.enemy_alive(id):
			host.damage(id, 1.0e9, hero.core_id, false)
	for id in tids:
		core.kill_thrall(id, "killed")
	await ticks(3)
	fl._process(10.0)


func death_veil() -> void:
	check(not bool(h.last_vm()["death"]["show"]) and not hud.death.visible, "the veil is down while the hero lives")
	hero.take_damage(1.0e9, 0, "melee")
	await ticks(2)
	h.refresh()
	check(not hero.alive and bool(h.last_vm()["death"]["show"]) and hud.death.visible, "the hero fell: the veil comes up")
	check(hud.death_sub.text != "", "with its line ('%s')" % hud.death_sub.text)
	var waited := 0
	while not hero.alive and waited < 400:
		await physics_frame
		waited += 1
	h.refresh()
	check(hero.alive and not bool(h.last_vm()["death"]["show"]), "he got up: the veil goes down")


# ------------------------------------------------------------------------------------------------------------------ the keys, the click, the listener, the refresh rate

func floats_of(kind: String) -> Array:
	return feed.filter(func(e: Dictionary) -> bool: return e["id"] == "float" and e["ctx"]["kind"] == kind)


func keys_and_click() -> void:
	var uh := g.ui_host
	var listener := func(id: String, ctx: Dictionary) -> void: feed.append({"id": id, "ctx": ctx})
	uh.game_event.connect(listener)
	# the loadout is the kit's default loadout + RMB, with each rite's icon on its slot
	var kit := DmContent.kit("necromancer")
	var want: Array = (kit["defaultLoadout"] as Array).duplicate()
	want.append(kit["rmb"])
	check(uh.keys == want and uh.primary == kit["defaultPrimary"], "loadout = the kit's default loadout + rmb, primary %s" % uh.primary)
	check(hud.primary_slot != null and hud.primary_slot.key_text == "LMB", "HUD built the primary slot (LMB)")
	for i in 5:
		check(String(hud._slots[i].icon_path).ends_with(String(DmAbilities.def(want[i])["icon"]).replace("art/", "")), "slot %d icon is %s" % [i + 1, want[i]])
	# R is the discipline's signature, locked at level 1 (the level of this run is 20)
	var level0: Variant = g.character["level"]
	g.character["level"] = 1
	h.refresh()
	var sig_vm: Dictionary = h.last_vm()["slots"][5]
	check(sig_vm["key"] == "R" and sig_vm["locked"] and uh.rite_at(6) == kit["signatures"][hero.discipline_id], "vm: R is the discipline's signature, locked at level 1")
	g.character["level"] = level0
	h.refresh()
	# the minimap's destination mark follows a click-to-move goal
	check(uh.hud_state()["minimap"]["destination"] == null, "minimap: no destination while standing")
	hero.set_move_target(hero.position + Vector3(6, 0, 0))
	var dest: Variant = uh.hud_state()["minimap"]["destination"]
	check(dest != null and near(float(dest["x"]), hero.position.x + 6.0), "minimap: a click-to-move goal shows as the destination mark")
	hero.has_target = false
	check(uh.hud_state()["minimap"]["destination"] == null, "minimap: the mark clears on arrival")
	# a key press casts through the caster: the slowest rite of the bar that is ready and costs essence
	hero.resource = hero.resource_max
	var slot := -1
	var slowest := 0.0
	for i in 5:
		var rid := String(uh.keys[i])
		var d := DmAbilities.def(rid)
		if caster.cooldown_left(rid) <= 0.0 and float(d["essenceCost"]) > 0.0 and float(DmAbilities.unlock_level(rid)) <= 20.0 and float(d["cooldownMs"]) > slowest:
			slot = i
			slowest = float(d["cooldownMs"])
	check(slot >= 0, "a rite of the bar is ready to cast")
	if slot >= 0:
		var rid := String(uh.keys[slot])
		var key_ev := InputEventKey.new()
		key_ev.pressed = true
		key_ev.physical_keycode = KEY_1 + slot
		g.input._unhandled_input(key_ev)
		await ticks(3)
		check(caster.cooldown_left(rid) > 0.0, "key %d casts %s (cooldown %.0f ms)" % [slot + 1, rid, caster.cooldown_left(rid)])
		check(hero.resource < hero.resource_max - 1.0, "essence spent")
		check(g.input.hotbar.get_connections().size() == 1, "one hotbar listener (the HUD): %d (two = every key cast twice)" % g.input.hotbar.get_connections().size())
		check(feed.any(func(e: Dictionary) -> bool: return e["id"] == "slot_flash" and e["ctx"]["slot"] == slot + 1), "slot flash for the cast")
		# the same key again, past the cast lock, is on cooldown: said as a float
		await ticks(120)
		feed.clear()
		g.input._unhandled_input(key_ev)
		# the float comes with the HUD's next refresh, which runs on a REAL-time interval (20 a second): under --fixed-fps a fast machine plays
		# dozens of frames before it, so wait in real time (up to 2 s), as the 20 Hz cadence check below does
		var not_ready := func() -> bool: return floats_of("info").any(func(e: Dictionary) -> bool: return String(e["ctx"]["text"]).find("not ready") >= 0)
		var t_end_nr := Time.get_ticks_msec() + 2000
		while not not_ready.call() and Time.get_ticks_msec() < t_end_nr:
			await process_frame
		check(not_ready.call(), "cooldown rejection shows a float: %s" % [floats_of("info").map(func(e: Dictionary) -> String: return e["ctx"]["text"])])
	# a click on the bar's primary slot casts it at an enemy, and the hit number is drawn on the HUD's float layer
	var foe: int = host.spawn_enemy("robber", hero.position + Vector3(0, 0, -4), 1, 1000.0, 0.0, false, "graves", false)
	await ticks(30)
	hero.heal(1.0e6)
	feed.clear()
	var primary_cd := caster.cooldown_left(uh.primary)
	h.floats = DmFloatBudget.new()   # (the caps test above ran its numbers at a made-up time)
	var drawn_before: int = hud.float_layer.drawn
	g.input.hotbar.emit(0, host.enemy_position(foe), foe)
	await ticks(2)
	check(caster.cooldown_left(uh.primary) > primary_cd, "LMB casts %s" % uh.primary)
	check(await until(func() -> bool: return not floats_of("hit").is_empty() or not floats_of("crit").is_empty(), 60 * 4), "a primary hit floats a damage number")
	await ticks(2)
	check(hud.float_layer.drawn > drawn_before, "the number is drawn on the HUD float layer (a pool: DmHudFloats)")
	host.remove_enemy(foe)
	# damage taken floats a hurt number and flashes
	feed.clear()
	var hp0 := hero.hp
	hero.take_damage(12.0, 0, "melee")
	await ticks(2)
	check(not floats_of("hurt").is_empty() and hero.hp < hp0, "damage taken floats a hurt number")
	check(feed.any(func(e: Dictionary) -> bool: return e["id"] == "hit_flash"), "hit flash on damage")
	hero.heal(1.0e6)
	# a picked-up drop is counted by the Reliquary
	var member: DmRewardsMember = g.rewards.members[int(g.character["id"])]
	var bag0 := uh.inventory.count("reagent_grave_dust")
	member.loot_view.item(hero.position, {"item_id": "reagent_grave_dust", "quantity": 3}, true)
	member.loot_view.request_pickup(member.loot_view._drops[-1])   # what a click on it does (DmNextUiHost.loot_click)
	check(await until(func() -> bool: return uh.inventory.count("reagent_grave_dust") == bag0 + 3, 60 * 3), "a clicked drop lands in the bag")
	g.ui.toggle_panel("inventory")
	await process_frame
	check(g.ui.inv.count("reagent_grave_dust") == bag0 + 3, "the Reliquary counts the drop")
	g.ui.close_panels()
	uh.game_event.disconnect(listener)
	# the HUD applies at 20 Hz, not per frame
	var n0 := Time.get_ticks_msec()
	var applies := 0
	var frames := 0
	var last_at: int = g.ui._hud_at   # the time of the last apply (the client's view-model is one reused dictionary, so a new object cannot say it)
	while Time.get_ticks_msec() - n0 < 1000:
		await process_frame
		frames += 1
		if g.ui._hud_at != last_at:
			applies += 1
			last_at = g.ui._hud_at
	# The throttle is wall-clock (50 ms), so on a loaded machine frames can be slower than 50 ms and every frame applies: the floor is
	# min(8, frames / 2), the cap stays 22, and with plenty of frames the throttle must be visible (fewer applies than frames).
	check(applies >= mini(8, frames / 2) and applies <= 22 and (frames < 60 or applies < frames / 2), "HUD applies at ~20 Hz (%d applies in %d frames in 1 s)" % [applies, frames])


# ------------------------------------------------------------------------------------------------------------------ the boss

func boss_plate() -> void:
	check(h.last_vm()["boss"] == null and not hud.boss.visible, "no boss plate while the King sleeps")
	var me := g.session.get_my_id()
	hero.teleport(g.bosses.site_pos("gravedigger") + Vector3(0.0, 0.0, 2.0))
	await ticks(3)
	g.my_member().prog.add_shards(int(DmContent.boss("gravedigger")["shards"]))   # the summon's price
	var why := g.bosses.try_summon(me, "gravedigger")
	await ticks(12)
	var king := g.bosses.active_boss()
	check(why == "" and king != null, "the King wakes at his grave (%s)" % why)
	if king == null:
		return
	h.refresh()
	var b: Variant = h.last_vm()["boss"]
	var def: Dictionary = DmContent.boss("gravedigger")
	check(b != null and b["name"] == String(def["name"]) and near(float(b["hp"]), king.hp) and near(float(b["max_hp"]), king.max_hp) and int(b["phase"]) == king.phase and b["phases"] == def["phases"],
		"the plate has his name, phase and health (%s)" % str(b))
	check(hud.boss.visible and not hud.target_box.visible and near(hud.boss_bar.value, king.hp / king.max_hp, 0.001), "his plate is up, its bar at his health, and the target frame gives way to it")
	var mm: Dictionary = h.last_vm()["minimap"]
	check(mm["boss"] != null and near(float(mm["boss"]["x"]), king.position.x) and near(float(mm["boss"]["z"]), king.position.z), "he is a dot on the map")
	host.damage(king.core_id, king.max_hp * 0.3, hero.core_id, false)
	h.refresh()
	check(near(hud.boss_bar.value, king.hp / king.max_hp, 0.001) and king.hp < king.max_hp, "the bar follows his health (%.0f of %.0f)" % [king.hp, king.max_hp])
	g.bosses.fx.host.emit_game_event("toast", {"text": "The Gravedigger King stirs", "kind": "err"})
	check(hud.toasts.get_children().any(func(t: Node) -> bool: return t.get_meta("text", "") == "The Gravedigger King stirs"), "the boss fx's toast reaches the HUD")
	g.bosses.fx.host.emit_game_event("banner", {"title": "The Gravedigger King", "sub": "He wakes", "ms": 3000})
	check(hud.banner_active(), "and its banner")


# ------------------------------------------------------------------------------------------------------------------ pieces

func pieces() -> void:
	var ids := ["party", "omen", "ward", "chain", "belt", "target", "boss", "map", "toasts", "banner", "prompt", "hint", "chat", "xp", "altar", "upgrades"]
	var ok := true
	for id in ids:
		if not hud.pieces.has(id) or not (hud.pieces[id] is Control) or hud.pieces[id].get_parent() != hud.safe:
			ok = false
			printerr("  missing piece ", id)
	check(ok and hud.pieces.size() == ids.size(), "%d pieces, each a Control of its own in the safe frame" % hud.pieces.size())
	var map: Control = hud.pieces["map"]
	var r0 := map.get_global_rect()
	var corner0 := Vector2(r0.end.x, r0.position.y)    # the map column hangs from the top right
	hud.set_piece("map", Vector2(-40, 25), 0.8)
	var r1 := map.get_global_rect()
	check(near(r1.position.y - r0.position.y, 25.0 + (r0.size.y * 0.0), 0.5) or r1.position.y > r0.position.y, "a piece moves by its offset")
	check(map.scale == Vector2(0.8, 0.8) and near(map.pivot_offset.x, map.size.x) and near(map.pivot_offset.y, 0.0), "it scales around the corner its anchor holds (top right)")
	check(near(map.get_global_rect().size.x, r0.size.x * 0.8, 1.0) and near(map.get_global_rect().end.x, corner0.x - 40.0, 1.0), "scaled 0.8, moved 40 px left: its right edge went 40 px left and its width shrank by a fifth")
	check(hud.layout.has("map"), "the layout remembers it")
	hud.set_layout({})
	check(map.scale == Vector2.ONE and near(map.get_global_rect().position.x, r0.position.x, 0.5), "an empty layout puts every piece back")
	var altar: Control = hud.pieces["altar"]
	var a0 := altar.get_global_rect()
	hud.set_piece("altar", Vector2.ZERO, 1.5)
	check(near(altar.pivot_offset.x, altar.size.x * 0.5) and near(altar.pivot_offset.y, altar.size.y) and near(altar.get_global_rect().get_center().x, a0.get_center().x, 1.0) and near(altar.get_global_rect().end.y, a0.end.y, 1.0),
		"the hotbar, anchored at the bottom centre, grows up and out of its centre")
	hud.set_piece("altar")
	hud.show_piece("party", false)
	h.refresh()
	check(not hud.pieces["party"].visible, "a hidden piece stays hidden through a refresh")
	hud.show_piece("party", true)
	h.refresh()
	check(hud.pieces["party"].visible, "and comes back")
	var w0 := hud.safe.scale
	hud.set_hud_scale(1.2)
	check(hud.effective_scale > 1.0 and near(hud.safe.scale.x, hud.effective_scale, 0.001), "the HUD scale scales every piece (the safe frame) at once: x%.2f" % hud.effective_scale)
	hud.set_hud_scale(1.0)
	check(hud.safe.scale == w0, "and back")
	hud.set_hud_scale(1.0)


# ------------------------------------------------------------------------------------------------------------------ z layers

## Every menu button on (the full HUD's row, for the worst case), or back to the game scene's row (the Social button only).
## (The gated ones, Acre and Atlas, show once the feeds reveal everything: HudFeeds.full().)
func _menu_all(on: bool) -> void:
	for id in hud.menu_btns:
		hud.menu_btns[id].visible = on or id == "friends"


## With every piece on, each visible control sits on the z layer of what it draws (DmHudKit): text above the art above the chrome above the panels, in each overlay's own
## hundred. A control left on the wrong layer is a draw call per panel or per label the budget does not allow.
func layers() -> void:
	h.feeds = HudFeeds.full()
	_menu_all(true)
	hud.chat_col.visible = true
	hud.chat_line("[Helix] over here")
	hud.chat_line("You found Bone Dust")
	hud.toast("A crypt cracks open", "good")
	var made := host.spawn_enemy("robber", hero.position + Vector3(0, 0, -9), 3, 2.0, 0.0, true, "graves", false, PackedStringArray(["hungering"]))
	await ticks(3)
	h._on_hotbar(0, Vector3.ZERO, made)
	host.apply_status(made, "chill", hero.core_id, 1.0, 60.0)
	h.refresh()
	await process_frame
	await process_frame
	var seen := {"text": 0, "icon": 0, "panel": 0, "chrome": 0, "art": 0}
	var bad: Array[String] = []
	_audit(hud, seen, bad)
	check(bad.is_empty(), "every visible control is on the layer of what it draws (%d wrong: %s)" % [bad.size(), str(bad.slice(0, 6))])
	check(seen["text"] > 40 and seen["icon"] > 8 and seen["panel"] > 15 and seen["art"] > 5, "and there is a lot to check: %s" % str(seen))
	print("INFO the full HUD: %s controls on their layers; %d text layers in use" % [str(seen), DmHudKit._text_z.size()])
	_menu_all(false)
	hud.chat_col.visible = false
	h.feeds = {}
	host.damage(made, 1.0e9, hero.core_id, false)
	h._target_until = 0.0
	await ticks(2)
	h.refresh()


func _audit(n: Node, seen: Dictionary, bad: Array[String]) -> void:
	if n is CanvasItem and (n as CanvasItem).is_visible_in_tree():
		var z := _abs_z(n)
		var layer := z % 100 if z >= 100 else z
		var want := -99
		var kind := ""
		if n is RichTextLabel or n is Label or n is LineEdit or (n is Button and (n as Button).text != ""):
			kind = "text"
			if layer < DmHudKit.Z_TEXT:
				bad.append("%s %s z%d" % [n.name, n.get_class(), z])
		elif n is TextureRect:
			kind = "icon"
			want = DmHudKit.Z_CHROME
		elif n is PanelContainer and (n as Control).has_theme_stylebox_override("panel") and (n as Control).get_theme_stylebox("panel") is StyleBoxTexture:
			kind = "panel"
			want = DmHudKit.Z_PANEL
		elif n is DmHudBar or n is DmCorners or n is DmHudParts.Rule:
			kind = "chrome"
			want = DmHudKit.Z_CHROME
		elif n is DmHudOrb or n is DmHudParts.Diamonds or n is DmHudParts.LevelBadge or n is DmHudMinimap:
			kind = "art"
			want = DmHudKit.Z_ART
		if kind != "":
			seen[kind] = int(seen[kind]) + 1
		if want != -99 and layer != want and z != -1:
			bad.append("%s %s z%d (want %d)" % [n.name, n.get_class(), z, want])
	for c in n.get_children():
		_audit(c, seen, bad)


## A control's z in the whole canvas: its own plus its parents' (z_as_relative), as the renderer sums them.
func _abs_z(n: Node) -> int:
	var z := 0
	var c: Node = n
	while c != null and c != hud.get_parent():
		if c is CanvasItem:
			z += (c as CanvasItem).z_index
			if not (c as CanvasItem).z_as_relative:
				break
		c = c.get_parent()
	return z


# ------------------------------------------------------------------------------------------------------------------ the per-frame work

## The pulse and the flash of the HUD's animated edges are layers drawn once and faded (their alpha is the animation), so a frame costs a property, not a redraw of 16 to 24 rectangles.
func per_frame_work() -> void:
	var redraws := [0]
	var count := func() -> void: redraws[0] += 1
	# a NEW glow: halo alpha = the pulse 0.5 + 0.5 sin(t / 1.6 TAU), the edge drawn once
	var host := Control.new()
	host.size = Vector2(80, 30)
	root.add_child(host)
	var glow := DmHudParts.NewGlow.new()
	host.add_child(glow)
	check(not glow.visible, "a NEW glow is hidden until its element is new")
	glow.active = true
	await process_frame
	await process_frame
	glow.connect("draw", count)
	glow._halo.connect("draw", count)
	redraws[0] = 0
	var wrong := 0
	for i in 40:
		await process_frame
		if not near(glow._halo.modulate.a, 0.5 + 0.5 * sin(glow._t / 1.6 * TAU), 1.0e-4):
			wrong += 1
	check(glow.visible and glow._halo.visible and glow._t > 0.5 and wrong == 0, "the glow's halo fades with the pulse, frame by frame (%d of 40 off, t = %.2f)" % [wrong, glow._t])
	check(redraws[0] == 0, "and nothing is redrawn for it (%d redraws in 40 frames)" % redraws[0])
	glow.active = false
	check(not glow.visible, "a glow switched off is hidden again")
	host.queue_free()
	# an empowered slot's pulse and a cast flash
	var slot := DmHudSlot.new()
	root.add_child(slot)
	var base := {"icon": "", "key": "1", "cost": 10, "left_ms": 0.0, "total_ms": 4000.0, "affordable": true, "empowered": false, "locked": false, "unlock_level": 1,
		"needs": "", "alt": false, "swap": false, "rune_icon": ""}
	slot.apply(base)
	await process_frame
	await process_frame
	check(not slot._pulse.visible and not slot._flashfx.visible, "a plain slot shows neither pulse nor flash")
	slot._edge.connect("draw", count)
	slot._pulse.connect("draw", count)
	slot._flashfx.connect("draw", count)
	var emp := base.duplicate()
	emp["empowered"] = true
	slot.apply(emp)
	slot.flash()   # (the first show of each layer draws it)
	await process_frame
	await process_frame
	slot.set_process(false)   # driven by hand from here
	slot._flash = 0.0
	slot._fade()
	check(slot._pulse.visible and not slot._flashfx.visible, "an empowered slot pulses")
	redraws[0] = 0
	slot._process(0.35)
	var want := (0.5 * (0.5 + 0.5 * cos(slot._t / 1.4 * TAU)) + 0.12) / 0.62
	check(near(slot._pulse.modulate.a, want, 1.0e-4), "the pulse is %.3f of its strongest rings at t = %.2f (%.3f)" % [want, slot._t, slot._pulse.modulate.a])
	slot.flash()
	slot._process(0.1)
	check(slot._flashfx.visible and slot._pulse.visible and near(slot._flashfx.modulate.a, (0.35 - 0.1) / 0.35, 1.0e-4), "a flash fades from full over 0.35 s, over the pulse (%.3f)" % slot._flashfx.modulate.a)
	for i in 20:
		slot._process(0.0167)
		await process_frame
	check(not slot._flashfx.visible and slot._pulse.visible, "the flash is gone after 0.35 s, the pulse goes on")
	check(redraws[0] <= 1, "and the 22 frames of it redraw one layer once, when it is shown, not the borders (%d redraws)" % redraws[0])
	slot.apply(base)
	await process_frame
	check(not slot._pulse.visible and not slot.is_processing(), "a slot that is no longer empowered stops pulsing")
	# a rite on cooldown: only the seconds, the note and the sweep move; the result is the slot a full apply of the same state gives
	var needy := base.duplicate()
	needy["needs"] = "corpse"
	var fresh_slot := DmHudSlot.new()
	root.add_child(fresh_slot)
	var a := needy.duplicate()
	a["left_ms"] = 2500.0
	var b := needy.duplicate()
	b["left_ms"] = 0.0
	var mismatch := PackedStringArray()
	for pair in [[needy, a], [a, b], [b, a]]:
		slot.apply(pair[0])
		slot.apply(pair[1])
		fresh_slot._last = {}
		fresh_slot.apply(pair[1])
		for prop in ["left_ms", "_drawn_pct", "needs", "locked", "affordable", "_dim", "swap", "key_text"]:
			if slot.get(prop) != fresh_slot.get(prop):
				mismatch.append("%s %s/%s" % [prop, str(slot.get(prop)), str(fresh_slot.get(prop))])
		if slot._cdtext.text != fresh_slot._cdtext.text or slot._need.text != fresh_slot._need.text or slot._cost.text != fresh_slot._cost.text:
			mismatch.append("text '%s' '%s' / '%s' '%s'" % [slot._cdtext.text, slot._need.text, fresh_slot._cdtext.text, fresh_slot._need.text])
	check(mismatch.is_empty(), "a rite that only moved along its cooldown ends up as a full apply makes it (%s)" % str(mismatch))
	slot.apply(a)
	slot.apply(b)
	check(slot._last == b and slot._cdtext.text == "", "the state kept is the new one (a ready rite shows no seconds)")
	var changed := a.duplicate()
	changed["cost"] = 99
	slot.apply(a)
	check(not slot._only_cooldown_moved(changed), "another change besides the cooldown takes the whole apply")
	slot.queue_free()
	fresh_slot.queue_free()
	# the low-health wash eases while it moves and rests, not processing, once it has settled; a hit wakes it
	var wash := DmHudParts.Vignette.new()
	root.add_child(wash)
	await process_frame
	await process_frame
	check(near(wash.strength, 0.0) and not wash.is_processing(), "a wash at rest does not process")
	wash.low = true
	check(wash.is_processing(), "low health wakes the wash")
	for i in 60:
		await process_frame
	check(near(wash.strength, 0.45) and not wash.is_processing(), "and it settles at 0.45 and rests again (%.2f)" % wash.strength)
	wash.flash()
	await process_frame
	check(wash.is_processing() and near(wash.strength, 0.55), "a hit flashes it to 0.55")
	wash.low = false
	for i in 90:
		await process_frame
	check(near(wash.strength, 0.0) and not wash.is_processing(), "and health back lets it fade away and rest (%.2f)" % wash.strength)
	wash.queue_free()
	var commas_ok := DmHudKit.commas(0) == "0" and DmHudKit.commas(999) == "999" and DmHudKit.commas(1000) == "1,000" and DmHudKit.commas(1234567) == "1,234,567" and DmHudKit.commas(-1234) == "-1,234"
	for i in 700:
		commas_ok = commas_ok and DmHudKit.commas(float(i * 1013)) == (str(i * 1013) if i * 1013 < 1000 else str(i * 1013).insert(str(i * 1013).length() - 3, ",") if i * 1013 < 1000000 else str(i * 1013).insert(str(i * 1013).length() - 3, ",").insert(str(i * 1013).length() - 6, ","))
	check(commas_ok and DmHudKit.commas(1234567.0) == "1,234,567", "the thousands separators are right, from the kept text and after it was dropped")
	# a mesh appended again at the same place: the same indices as a loop would make, kept
	var stat := DmHudMesh.new()
	stat.disc(Vector2.ZERO, 5.0, Color.WHITE, 12)
	var m := DmHudMesh.new()
	m.tri(Vector2.ZERO, Vector2(1, 0), Vector2(0, 1), Color.RED)
	m.append(stat)
	m.append(stat)
	var base2 := 3 + stat.pts.size()
	var ok := m.idx.size() == 3 + 2 * stat.idx.size()
	for k in stat.idx.size():
		ok = ok and m.idx[3 + k] == stat.idx[k] + 3 and m.idx[3 + stat.idx.size() + k] == stat.idx[k] + base2
	var again := DmHudMesh.new()
	again.tri(Vector2.ZERO, Vector2(1, 0), Vector2(0, 1), Color.RED)
	again.append(stat)
	again.append(stat)
	check(ok and again.idx == m.idx and stat._moved.size() == 2, "a bag appended at a start it was appended at before gives the same indices (%d starts kept)" % stat._moved.size())
	stat.clear()
	check(stat._moved.is_empty(), "and a cleared bag forgets them")
	# the readouts are applied by section (the panel host's own refresh waits meanwhile)
	g.ui.set_process(false)
	var chips0: Dictionary = hud._brew_chips
	for slot_id in chips0:
		(chips0[slot_id] as DmHudBrewChip).connect("draw", count)
	var vm0 := h.last_vm().duplicate(true)
	vm0["chain"] = {"count": 3, "name": "Chain", "bonus": 0.1, "frac": 0.5, "tier": 1}
	hud.apply(vm0)
	await process_frame
	redraws[0] = 0
	var vm1 := vm0.duplicate(true)
	vm1["chain"]["frac"] = 0.4
	hud.apply(vm1)
	await process_frame
	await process_frame
	check(near(hud.chain_bar.value, 0.4) and redraws[0] == 0, "a moving Kill Chain meter moves the meter and applies none of the belt (%d chip redraws)" % redraws[0])
	vm1["chain"] = null
	hud.apply(vm1)
	check(not hud.chain.visible, "and the chain readout goes with its data")
	g.ui.set_process(true)
	h.refresh()
	# the counsel card's draining line is drawn once and squeezed by what is left of the time
	var card := DmTipCard.new()
	root.add_child(card)
	card.set_tip("Test", "A tip", 8000)
	card.size = Vector2(360, 120)
	await process_frame
	await process_frame
	var line_draws := [0]
	card._timer_rect.connect("draw", func() -> void: line_draws[0] += 1)
	var line_off := 0
	for i in 30:
		card._process(0.1)   # (0.1 s of the card's own clock a frame)
		await process_frame
		if absf(card._line_k - maxf(clampf(1.0 - card._t / 8000.0, 0.0, 1.0), 0.0001)) > 1.0e-4:
			line_off += 1
	check(card._line.is_valid() and line_off == 0 and card._line_k < 0.65, "the card's line is what is left of its 8 s (%.2f after %.1f s; %d frames off)" % [card._line_k, card._t / 1000.0, line_off])
	check(line_draws[0] == 0, "and nothing redraws it per frame (%d draws)" % line_draws[0])
	card.queue_free()
	# the counsel's timers: the clock runs every frame, the timers only when one is due
	var c := DmCounsel.new(7, DmCounselStore.new(""), 0.0)
	var fired := PackedStringArray()
	c._later(func() -> void: fired.append("b"), 300.0)
	c._later(func() -> void: fired.append("a"), 100.0)
	var gone := c._later(func() -> void: fired.append("x"), 200.0)
	c._cancel(gone)
	c.tick(0.05)
	check(fired.is_empty() and near(c.now_ms, 50.0, 1.0e-6), "the counsel's clock runs with no timer due")
	c.tick(0.06)
	check(fired == PackedStringArray(["a"]), "a timer fires when its time comes (%s)" % str(fired))
	c.tick(0.5)
	check(fired == PackedStringArray(["a", "b"]) and near(c.now_ms, 610.0, 1.0e-6), "in order, a cancelled one never (%s, clock %.0f)" % [str(fired), c.now_ms])
	c._later(func() -> void: fired.append("c"), 10.0)
	c.tick(0.02)
	check(fired.size() == 3, "and one set later is not missed by the wait for the earliest")


# ------------------------------------------------------------------------------------------------------------------ the draw-call model

## The model of the canvas renderer (tests/hud_cost.gd) against the numbers a rendered run measured for the same trees (Forward+, lavapipe, 2026-10-16), then the HUD in a Full
## Party fight, as the game scene shows it and with every piece on. A model's number is not a measurement: the measured proof is tools/hud_measure.gd on a rendered run.
func draw_model() -> void:
	var lab_host := Control.new()
	root.add_child(lab_host)
	var body: Font = DmUi.font("body")
	var num: Font = DmUi.font("numeric")
	var atlas := ImageTexture.create_from_image(Image.create_empty(64, 64, false, Image.FORMAT_RGBA8))
	var textures: Array[ImageTexture] = []
	for i in 20:
		var im := Image.create_empty(8, 8, false, Image.FORMAT_RGBA8)
		im.fill(Color.from_hsv(i / 20.0, 1, 1))
		textures.append(ImageTexture.create_from_image(im))
	var lab := func(font: Font, size: int, shadow: bool, outline: int, z: int) -> Label:
		var l := Label.new()
		l.text = "Health 123"
		l.add_theme_font_override("font", font)
		l.add_theme_font_size_override("font_size", size)
		if shadow:
			l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
			l.add_theme_constant_override("shadow_offset_y", 1)
		if outline > 0:
			l.add_theme_constant_override("outline_size", outline)
			l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
		l.z_index = z
		return l
	var flat := func() -> PanelContainer:
		var p := PanelContainer.new()
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.1, 0.1, 0.2, 0.8)
		sb.border_color = Color.GRAY
		sb.set_border_width_all(1)
		sb.set_corner_radius_all(3)
		p.add_theme_stylebox_override("panel", sb)
		return p
	var nine := func(i: int) -> PanelContainer:
		var p := PanelContainer.new()
		var st := StyleBoxTexture.new()
		st.texture = atlas
		st.region_rect = Rect2((i % 4) * 16, 0, 16, 16)
		st.modulate_color = Color.from_hsv(i / 20.0, 0.5, 1.0)
		p.add_theme_stylebox_override("panel", st)
		return p
	var tr := func(t: Texture2D) -> TextureRect:
		var r := TextureRect.new()
		r.texture = t
		return r
	var add := func(n: Node) -> void: lab_host.add_child(n)
	# [what, the draw calls the rendered run counted, how to build it]
	var cases := [
		["20 labels, one font", 1, func() -> void:
			for i in 20: add.call(lab.call(body, 14, false, 0, 0))],
		["20 labels with a shadow", 1, func() -> void:
			for i in 20: add.call(lab.call(body, 14, true, 0, 0))],
		["20 labels with an outline (the floating numbers)", 40, func() -> void:
			for i in 20: add.call(lab.call(num, 17, false, 3, 0))],
		["20 labels, two fonts alternating", 20, func() -> void:
			for i in 20: add.call(lab.call(body if i % 2 == 0 else num, 14, false, 0, 0))],
		["20 labels, two fonts alternating, one font on z 1", 2, func() -> void:
			for i in 20: add.call(lab.call(body if i % 2 == 0 else num, 14, false, 0, i % 2))],
		["20 StyleBoxFlat panels", 20, func() -> void:
			for i in 20: add.call(flat.call())],
		["10 panels, each followed by its label", 20, func() -> void:
			for i in 10:
				add.call(flat.call())
				add.call(lab.call(body, 12, true, 0, 0))],
		["10 panels each followed by its label, the labels on z 1", 11, func() -> void:
			for i in 10:
				add.call(flat.call())
				add.call(lab.call(body, 12, true, 0, 1))],
		["10 panels, then 10 labels", 11, func() -> void:
			for i in 10: add.call(flat.call())
			for i in 10: add.call(lab.call(body, 12, true, 0, 0))],
		["10 buttons with a style", 20, func() -> void:
			for i in 10:
				var b := Button.new()
				b.text = "Bag"
				b.add_theme_stylebox_override("normal", flat.call().get_theme_stylebox("panel"))
				add.call(b)],
		["20 icons of one texture", 1, func() -> void:
			for i in 20: add.call(tr.call(textures[0]))],
		["20 icons of one texture in different colours", 1, func() -> void:
			for i in 20:
				var r: TextureRect = tr.call(textures[0])
				r.modulate = Color.from_hsv(i / 20.0, 0.6, 1.0)
				add.call(r)],
		["20 icons of 20 textures", 20, func() -> void:
			for i in 20: add.call(tr.call(textures[i]))],
		["20 icons, regions of one atlas", 1, func() -> void:
			for i in 20:
				var at := AtlasTexture.new()
				at.atlas = atlas
				at.region = Rect2((i % 8) * 8, (i / 8) * 8, 8, 8)
				add.call(tr.call(at))],
		["20 9-patch panels of one texture, other regions and colours", 1, func() -> void:
			for i in 20: add.call(nine.call(i))],
		["5 rich text labels", 5, func() -> void:
			for i in 5:
				var r := RichTextLabel.new()
				r.bbcode_enabled = true
				r.text = "[center]%d slain here[/center]" % i
				add.call(r)],
		["8 icons each followed by a label", 16, func() -> void:
			for i in 8:
				add.call(tr.call(textures[i]))
				add.call(lab.call(num, 12, true, 0, 0))],
		["6 icons with one material", 6, func() -> void:
			var mat := ShaderMaterial.new()
			for i in 6:
				var r: TextureRect = tr.call(textures[i])
				r.material = mat
				add.call(r)],
	]
	var wrong: Array[String] = []
	for c in cases:
		for ch in lab_host.get_children():
			lab_host.remove_child(ch)
			ch.free()
		c[2].call()
		var got := int(HudCost.estimate(lab_host)["draws"])
		if got != int(c[1]):
			wrong.append("%s: model %d, measured %d" % [c[0], got, c[1]])
	check(wrong.is_empty(), "the model reproduces the %d measured draw-call counts of the rendered run (%s)" % [cases.size(), str(wrong)])
	lab_host.queue_free()
	# the HUD in a Full Party fight
	var made := PackedInt32Array()
	for i in 72:
		var a := float(i) / 72.0 * TAU
		made.append(host.spawn_enemy("robber" if i % 3 != 0 else "hound", hero.position + Vector3(cos(a), 0.0, sin(a)) * (10.0 + float(i % 5) * 1.5), 1, 1000.0, 0.0, i % 24 == 5, "graves", false))
	for i in 12:
		var base: Array = THRALL_BASE["warrior"]
		core.raise_thrall({"kind": "warrior", "hp": 1.0e6, "maxHp": 1.0e6, "damage": 0.0, "attackInterval": base[1], "range": base[0], "speed": base[2], "empowered": false,
			"champion": false, "allyHeal": 0.0}, hero.core_id, Vector2(hero.position.x + float(i % 10) - 5.0, hero.position.z + 2.0 + float(i / 10)), 0.0, 40.0)
	hero.resource = hero.resource_max
	for rite in ["marrow_spear", "miasma", "exhume"]:
		caster.request_cast(rite, hero.position + Vector3(0, 0, -6), -1)
	await ticks(8)
	var elite := 0
	for id in core.enemy_ids():
		if core.enemy_info(id)["elite"]:
			elite = id
			break
	h._on_hotbar(0, Vector3.ZERO, elite)
	for st in ["chill", "fracture", "withered", "bleed"]:
		host.apply_status(elite, st, hero.core_id, 3.0 if st in ["fracture", "withered"] else 1.0, 60.0)
	hud.toast("The dead answer you more readily", "good")
	hud.toast("A crypt cracks open", "")
	var kinds := ["hit", "crit", "dot", "thrall", "hit", "hit"]
	for i in 60:
		h.float_text(hero.position + Vector3(float(i % 9) - 4.0, 1.6, -3.0), str(100 + i), kinds[i % 6], null, 9_000_000.0)
	h.refresh()
	await process_frame
	var game_state := await _model_of("as the game scene shows it")
	_menu_all(true)
	hud.chat_col.visible = true
	hud.chat_line("[Helix] over here")
	hud.chat_line("You found Bone Dust")
	h.feeds = HudFeeds.full()
	h.refresh()
	await process_frame
	var full_state := await _model_of("every piece on and fed")
	check(int(game_state["draws"]) <= 150 and int(full_state["draws"]) <= 150, "the model puts the HUD under the 150 draw calls (%d as the game shows it, %d with every piece on)" % [game_state["draws"], full_state["draws"]])
	check(game_state["unknown"].is_empty() and full_state["unknown"].is_empty(), "every control that draws by script said what it drew (unknown: %s)" % str(full_state["unknown"]))
	_menu_all(false)
	hud.chat_col.visible = false
	h.feeds = {}
	hud.set_hud_scale(1.0)
	for id in made:
		if host.enemy_alive(id):
			host.damage(id, 1.0e9, hero.core_id, false)
	h._target_until = 0.0
	hud.float_layer._process(10.0)
	await ticks(3)


## The model's count of the HUD now, with the scripts' drawing logged: INFO line per state and the layers that cost.
func _model_of(label: String) -> Dictionary:
	DmHudKit.recording = true
	DmHudKit.log.clear()
	_redraw_all(g.ui)
	await process_frame
	await process_frame
	var e := HudCost.estimate(g.ui)
	DmHudKit.recording = false
	var layers_ := {}
	for z in e["by_z"]:
		var kind: String = "overlay" if z >= 100 and z < 200 else ("floats" if z >= 200 else ("text" if z >= DmHudKit.Z_TEXT else ["panels", "chrome", "art", "edge"][maxi(z, 0)]))
		layers_[kind] = int(layers_.get(kind, 0)) + int(e["by_z"][z])
	print("INFO draw-call model, %s: %d draw calls (%s)" % [label, e["draws"], str(layers_)])
	return e


func _redraw_all(n: Node) -> void:
	if n is CanvasItem:
		(n as CanvasItem).queue_redraw()
	for c in n.get_children():
		_redraw_all(c)
