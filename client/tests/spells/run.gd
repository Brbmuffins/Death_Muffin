extends SceneTree
## Every spell of every playable class, driven by the class data (client/README.md "Tests"): nobody writes a test for a new spell or a newly playable class, it is covered the moment it
## exists in `data/combat/abilities.json` (the kits) and `data/combat/disciplines.json`. The playable families come from `DmCharacterBuild.is_playable` over the disciplines, the spells of a
## family from its kit (hotbar, grimoire, primaries, RMB, signatures; de-duplicated). One fresh offline game (client/next/next_game.tscn, a level-20 hero, no waves, headless) per playable
## discipline, the way tests/rites.gd boots it; every spell of the family is cast in it (the discipline's own signature included), each in a reset arena (core enemies, corpses and a
## legion near, like tests/warm_coverage.gd). Per spell:
##   1 data       a rite module (DmRiteRegistry), an ability row, an icon file, a name and a description, a place in the kit (hotbar slot, grimoire, primary, RMB or the discipline's signature);
##   2 cast       through the way the player casts it (the hotbar slot through DmNextInput.cast_at, else the caster's request_cast the Grimoire's sockets use): the cooldown after the cast is the
##                row's `cooldownMs`, the resource spent is its `essenceCost` (the Reaper: `soulCost`), a second cast at once is refused and a second one after the cast lock is refused by the
##                cooldown (when the row has one). The expectations are the data's numbers, not the game's formulas: a hero with a bare loadout has no cooldown mods, and any essence the
##                spell hands back is held off by capping the pool for the cast;
##   3 tooltip    the spell card the HUD builds (DmSpellTooltip.build, for the hero's discipline) shows the row's name, description, cost and cooldown;
##   4 effect     the cast plays events and draws (the caster's counted effects), makes a sound (a recording stand-in for the AudioDirector), and every Binbun scene it showed is in the set
##                the load-time warm-up builds, with no scene read from disk after the start (the materials are tests/warm_coverage.gd's);
##   5 errors     ZERO script errors or engine errors in the log (an OS Logger counts them);
##   6 discipline each discipline's `mods` in the data are the hero's mods, the stats the game derives for it stand to the family's first discipline as the mods do (health, essence a second,
##                thrall health and damage), Exhume raises its thrall kind up to its cap, and its signature casts.
## A part that cannot be checked for a spell is printed as `INFO spells: ... skipped ...` with the reason. Bakes the robber, the hound and the legionnaire into a scratch folder first.
## Run: godot --headless --fixed-fps 60 --path client --script res://tests/spells/run.gd   (PACED in the runner; about a minute)

const OUT := "user://spells_test"
const BAKE := ["grave_robber", "bone_hound", "thrall_legionnaire"]
const BIG := 1000.0   ## health multiplier of a target that must survive the cast
const KINDS := ["data", "cast", "tooltip", "effect", "sound", "warmed", "mods", "signature"]
const VISUAL_KEYS := ["decal", "emit", "smoke", "flash", "light", "beam", "orbit", "projectile", "bb", "motif", "spikes", "hands", "bone_orbit", "shake"]


class ErrorLog:
	extends Logger
	var errors: Array[String] = []

	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _backtraces: Array[ScriptBacktrace]) -> void:
		if error_type != Logger.ERROR_TYPE_WARNING:
			errors.append("%s:%d %s %s %s" % [file, line, function, code, rationale])


## The AudioDirector as the rites' effects call it (the same two calls DmRiteFx makes), recording.
class RecAudio:
	extends RefCounted
	var sfx: Array = []
	var loops: Array = []

	func play_sfx(id, _p = null, _i = 1.0) -> bool:
		sfx.append(String(id))
		return true

	func loop_sfx(id, _ms, _p = null, _f = Callable()) -> int:
		loops.append(String(id))
		return 0


var fails := 0
var checks := 0
var errlog := ErrorLog.new()
var matrix := {}              ## discipline -> kind -> [passed, failed, skipped]
var skipped: Array = []       ## "discipline/spell: part: reason"
var g: DmNextGame
var api_: DmApi
var mock_: DmMockBackend
var host: DmCoreHost
var core: RefCounted
var hero: DmHeroBody
var c: DmRiteCaster
var field: DmCoreCorpses
var origin := Vector3.ZERO
var dirv := Vector3(1, 0, 0)
var side := Vector3(0, 0, 1)
var base_mods: Dictionary = {}
var rejected := ""
var ev_log: Array = []
var rec: RecAudio
var seen_fx := {}             ## Binbun effect ids shown since the last clear
var stat_rows := {}           ## discipline -> numbers the game derived for its hero
var cast_count := 0
var all_fx := {}              ## every Binbun scene the casts showed
var booted := 0
var t0_msec := 0
var cur := ""                 ## the discipline being played


func chk(kind: String, ok: bool, what: String) -> void:
	checks += 1
	var row: Array = (matrix[cur] as Dictionary)[kind]
	if ok:
		row[0] += 1
	else:
		row[1] += 1
		fails += 1
		printerr("FAIL spells: [%s] %s" % [cur, what])


func skip(kind: String, spell: String, why: String) -> void:
	((matrix[cur] as Dictionary)[kind] as Array)[2] += 1
	skipped.append("%s/%s: %s: %s" % [cur, spell, kind, why])
	print("INFO spells: %s/%s %s skipped: %s" % [cur, spell, kind, why])


func near(a: float, b: float, tol := 1e-6) -> bool:
	return absf(a - b) <= tol * maxf(1.0, maxf(absf(a), absf(b)))


func ticks(n: int) -> void:
	var target := Engine.get_physics_frames() + n
	while Engine.get_physics_frames() < target:
		await physics_frame


func secs(s: float) -> void:
	await ticks(int(round(s * 60.0)))


## The number as the spell card writes it: whole numbers bare, the rest to two places without trailing zeros.
func fmt(x: float) -> String:
	if is_equal_approx(x, roundf(x)):
		return str(int(roundf(x)))
	var s := String.num(x, 2)
	while s.ends_with("0"):
		s = s.trim_suffix("0")
	return s.trim_suffix(".")


# ------------------------------------------------------------------------------------------------------------------------ the data

## The playable disciplines (ids sorted by class index) and their families, from the data.
func playable_disciplines() -> Array:
	var rows: Array = []
	for d in (DmCombatData.disciplines()["disciplines"] as Dictionary).values():
		if DmCharacterBuild.is_playable(float(d["classIndex"])):
			rows.append(d)
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["classIndex"]) < float(b["classIndex"]))
	return rows


## Every spell of a family's kit, de-duplicated, in the order hotbar, grimoire, primaries, RMB, signatures.
func kit_spells(family: String) -> Array:
	var kit: Dictionary = DmContent.kit(family)
	var out: Array = []
	for key in ["hotbar", "grimoire", "primaries"]:
		for r in kit.get(key, []):
			if not out.has(String(r)):
				out.append(String(r))
	if kit.has("rmb") and not out.has(String(kit["rmb"])):
		out.append(String(kit["rmb"]))
	for r in (kit.get("signatures", {}) as Dictionary).values():
		if not out.has(String(r)):
			out.append(String(r))
	return out


## How the player reaches a spell: the hotbar slot (0 = LMB .. 6 = R) for this discipline, or "".
func slot_of(id: String, family: String, disc: String) -> int:
	for s in 7:
		if DmRiteHotbar.rite_for_slot(s, family, disc) == id:
			return s
	return -1


func data_checks(disc: Dictionary, id: String) -> void:
	var fam := String(disc["family"])
	var kit: Dictionary = DmContent.kit(fam)
	var defs := DmAbilities.defs()
	chk("data", DmRiteRegistry.has(id) and DmRiteRegistry.module(id) != null, "%s has a rite module in the registry" % id)
	chk("data", defs.has(id), "%s has an ability row in abilities.json" % id)
	if not defs.has(id):
		return
	var d: Dictionary = defs[id]
	var icon := DmGameHud.art(String(d.get("icon", "")).replace("art/", ""))
	chk("data", String(d.get("icon", "")) != "" and ResourceLoader.exists(icon), "%s has its icon file (%s)" % [id, icon])
	chk("data", String(d.get("name", "")).strip_edges() != "" and String(d.get("description", "")).strip_edges() != "", "%s has a name and a description" % id)
	var in_kit: bool = (kit.get("hotbar", []) as Array).has(id) or (kit.get("grimoire", []) as Array).has(id) or (kit.get("primaries", []) as Array).has(id) \
		or String(kit.get("rmb", "")) == id or (kit.get("signatures", {}) as Dictionary).values().has(id)
	chk("data", in_kit, "%s is in the %s kit (hotbar, grimoire, primary, RMB or signature)" % [id, fam])
	if (kit.get("hotbar", []) as Array).has(id):
		var found := false
		for dd in playable_disciplines():
			if String(dd["family"]) == fam and slot_of(id, fam, String(dd["id"])) >= 0:
				found = true
		chk("data", found, "%s is on the %s hotbar (a slot of the keys)" % [id, fam])


## Checks of the kit itself (once a family).
func kit_checks(family: String) -> void:
	var kit: Dictionary = DmContent.kit(family)
	var hot: Array = kit.get("hotbar", [])
	for r in kit.get("defaultLoadout", []):
		chk("data", hot.has(r), "%s: the default loadout's %s is on the hotbar" % [family, r])
	chk("data", (kit.get("primaries", []) as Array).has(kit.get("defaultPrimary")), "%s: the default primary %s is one of the primaries" % [family, kit.get("defaultPrimary")])
	chk("data", hot.has(kit.get("rmb")), "%s: the RMB spell %s is on the hotbar" % [family, kit.get("rmb")])
	for dd in playable_disciplines():
		if String(dd["family"]) == family:
			chk("data", (kit.get("signatures", {}) as Dictionary).has(String(dd["id"])), "%s: the discipline %s has its signature in the kit" % [family, dd["id"]])


# ------------------------------------------------------------------------------------------------------------------------ boot

func _initialize() -> void:
	await process_frame
	OS.add_logger(errlog)
	t0_msec = Time.get_ticks_msec()
	DirAccess.make_dir_recursive_absolute(OUT)
	for slug in BAKE:
		var r: Dictionary = CrowdBaker.bake(root, slug, OUT.path_join(slug), {"rows_path": "res://game/view_models.json"})
		if not r.ok:
			printerr("FAIL spells: bake %s: %s" % [slug, r.get("error", "")])
			quit(1)
			return
	var mock := DmOffline.make_mock("")
	api_ = DmOffline.make_api(mock)
	mock_ = mock
	var reg := await api_.register("tester", "t@example.com", "pw1234")
	api_.set_token(reg.data["token"])
	var discs := playable_disciplines()
	var families := {}
	for d in discs:
		(matrix as Dictionary)[String(d["id"])] = {}
		for k in KINDS:
			matrix[String(d["id"])][k] = [0, 0, 0]
	for d in discs:
		cur = String(d["id"])
		await boot(d)
		var fam := String(d["family"])
		if not families.has(fam):
			families[fam] = true
			kit_checks(fam)
			for id in kit_spells(fam):
				data_checks(d, id)
		await play_discipline(d)
	await finish(discs)


## A fresh game with a level-20 hero of the discipline, the suite's globals pointed at it.
func boot(d: Dictionary) -> void:
	var ch := await api_.load_or_create_character(int(d["classIndex"]))
	DmDevMock.set_level(mock_, ch.data, 20)
	if g != null:
		g.process_mode = Node.PROCESS_MODE_DISABLED
		await g.leave()
		g.queue_free()
		await process_frame
		root.multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	g = load("res://next/next_game.tscn").instantiate()
	g.name = "NextGame"
	root.add_child(g)
	# the warm-up runs in the first game (the effects' pools stay built for the next ones, as in warm_coverage)
	await g.start(ch.data, api_, {"areas": ["graves"], "offline": true, "name": "tester", "hud": true, "audio": false, "seed": 20261016, "waves": false, "wander": false, "baked_dir": OUT, "warmup": booted == 0})
	booted += 1
	if booted == 1:
		cur = String(d["id"])
		chk("warmed", DmNextWarmup.last_ms > 0 and DmNextWarmup.effects > 0, "the load-time warm-up ran and built %d effects" % DmNextWarmup.effects)
		var vfx := root.get_node_or_null("Vfx")
		chk("warmed", vfx != null and vfx.binbun != null and vfx.binbun.enabled, "the Binbun effects are on, so the casts' scenes can be seen")
	host = g.core_host
	core = host.core
	hero = g.local_body()
	c = hero.get_node("Rites") as DmRiteCaster
	field = host.corpses
	origin = hero.position
	base_mods = c.mods.duplicate(true)
	c.random = func() -> float: return 0.5   # no crit
	c.cast_rejected.connect(func(_rite: String, why: String) -> void: rejected = why)
	c.event_played.connect(func(ev: Dictionary) -> void: ev_log.append(ev))
	find_arena()
	await ticks(2)   # the avatar is made a frame after the body enters the tree


func find_arena() -> void:
	var map: RID = g.world.nav_map()
	var best := -1.0
	for a in range(0, 360, 15):
		var d := Vector3(cos(deg_to_rad(a)), 0.0, sin(deg_to_rad(a)))
		var s := Vector3(-d.z, 0.0, d.x)
		var run := 0.0
		for k in range(1, 19):
			var ok := true
			for off in [-3.0, 0.0, 3.0]:
				var q: Vector3 = origin + d * float(k) + s * off
				var cp := NavigationServer3D.map_get_closest_point(map, q)
				if Vector2(cp.x - q.x, cp.z - q.z).length() > 0.3:
					ok = false
			if not ok:
				break
			run = float(k)
		if run > best:
			best = run
			dirv = d
			side = s
		if run >= 18.0:
			break


func at(along: float, across := 0.0) -> Vector3:
	return origin + dirv * along + side * across


# ------------------------------------------------------------------------------------------------------------------------ the arena

func reset() -> void:
	c._pending.clear()
	c._mem.clear()
	if c._legends != null:
		c._legends.wisps.clear()
	for id in core.enemy_ids():
		core.damage(id, 1.0e12, 0)
	for id in core.corpse_ids():
		core.corpse_consume(id, 0, "consumed")
	for id in core.thrall_ids():
		core.kill_thrall(id, "crumbled")
	hero.teleport(origin)
	hero.stop()
	c._set_mods(base_mods)
	var p := c.p
	p["hp"] = float(p["stats"]["maxHp"])
	refill()
	p["cooldowns"] = {}
	p["castUntil"] = 0.0
	p["rootedUntil"] = 0.0
	p["barrier"] = 0.0
	p["barrierPeak"] = 0.0
	p["runes"] = {}
	p["loadout"] = DmWeaponLine.no_loadout()
	p.erase("weaveStroke")
	p["harvestAmp"] = false
	p["lastHurtAt"] = 1.0e12
	for e in c.get_children():
		if String(e.name).begins_with("Ribs"):
			e.queue_free()
	rejected = ""


func refill() -> void:
	c.p["resource"]["value"] = float(c.p["resource"]["max"])
	if String(c.p.get("family", "")) == "reaper":
		c.p["souls"] = int(c.p["soulsMax"])


func foe(pos: Vector3, hp_mult := BIG) -> int:
	var id := host.spawn_enemy("robber", pos, 1, hp_mult, 0.0, false, "graves", false)
	core.stun(id, 3600.0)   # static and harmless
	return id


## Enemies, corpses and (when `legion`) three thralls round the hero. Returns {foe, corpse_at}.
func arena(legion: bool) -> Dictionary:
	reset()
	await ticks(2)
	var foes: Array = [foe(at(6.0)), foe(at(7.5, 2.2)), foe(at(8.0, -2.0)), foe(at(9.5, 0.5))]
	var spots: Array = [at(6.5, 1.0), at(8.5, -0.5), at(3.0, 2.5), at(4.0, -2.5)]
	for s in spots:
		field.add_corpse(s.x, s.z, "normal", "robber", false, 0.0, 1.0, "graves")
	if legion:
		for pt in [at(2.0, 2.0), at(2.5, -2.0), at(1.5, 0.0)]:
			raise_at(pt)
		await secs(DmSimConsts.THRALL_RISE_TIME + 0.7)   # (a rising thrall cannot act yet: the rules' rising time, and a moment more)
	await ticks(3)
	return {"foe": foes[0], "corpse_at": spots[0]}


func raise_at(pos: Vector3) -> void:
	var cp := field.add_corpse(pos.x, pos.z, "normal", "robber", false, 0.0, 1.0, "graves")
	var ex := {"kind": c.mods["thrallKind"], "cap": c.mods["thrallCap"], "hp": c.p["stats"]["thrallHp"], "damage": c.p["stats"]["thrallDamage"], "attackSpeedMult": c.mods["thrallAttackSpeedMult"], "r": 0.8}
	var r: Dictionary = c.thralls().raise(ex, pos)
	if not bool(r["ok"]):
		printerr("INFO spells: a thrall did not rise at %s (corpse %d)" % [str(pos), cp])


# ------------------------------------------------------------------------------------------------------------------------ one discipline

func play_discipline(disc: Dictionary) -> void:
	var fam := String(disc["family"])
	var did := String(disc["id"])
	await ticks(2)
	mods_checks(disc)
	var kit: Dictionary = DmContent.kit(fam)
	var sigs: Dictionary = kit.get("signatures", {})
	var own_sig := String(sigs.get(did, ""))
	var mine := kit_spells(fam).filter(func(s: String) -> bool: return not (sigs as Dictionary).values().has(s) or s == own_sig)
	chk("signature", own_sig != "" and g.rite_for_slot(6) == own_sig, "R is the signature %s (%s)" % [own_sig, g.rite_for_slot(6)])
	for id in mine:
		tooltip_checks(disc, id)
		await spell_case(disc, id, id == own_sig)
	await stat_row(disc)
	if mine.has("exhume") and DmRiteRegistry.has("exhume"):
		await thrall_checks(disc)


## The numbers the game derived for this hero (for the ratios at the end).
func stat_row(disc: Dictionary) -> void:
	await arena(false)
	stat_rows[String(disc["id"])] = {
		"maxHp": c.max_hp(), "thrallHp": float(c.p["stats"]["thrallHp"]), "thrallDamage": float(c.p["stats"]["thrallDamage"]),
		"regen": DmResources.passive(String(disc["family"]), {"stats": c.p["stats"], "value": 0.0, "max": c.p["resource"]["max"], "sinceHurtMs": 1e9, "sinceResourceGainMs": 1e9}),
	}


## 6: the discipline's mods in the data are the hero's.
func mods_checks(disc: Dictionary) -> void:
	var did := String(disc["id"])
	chk("mods", String(hero.discipline_id) == did and String(hero.family) == String(disc["family"]), "the hero is a %s of the %s family (%s, %s)" % [did, disc["family"], hero.discipline_id, hero.family])
	var want: Dictionary = disc["mods"]
	var bad: Array = []
	for k in want:
		var got: Variant = c.mods.get(k)
		var is_num: bool = typeof(want[k]) in [TYPE_INT, TYPE_FLOAT]
		var ok: bool = got != null and ((is_num and typeof(got) in [TYPE_INT, TYPE_FLOAT] and near(float(got), float(want[k]), 1e-6)) or (not is_num and typeof(got) == typeof(want[k]) and got == want[k]))
		if not ok:
			bad.append("%s: the data %s, the hero %s" % [k, str(want[k]), str(got)])
	chk("mods", bad.is_empty(), "%s: the hero has the discipline's %d mods (%s)" % [did, want.size(), "; ".join(bad)])


## The stats of each discipline stand to the family's first discipline as its mods do.
func ratio_checks(discs: Array) -> void:
	var base_of := {}
	for d in discs:
		if not base_of.has(String(d["family"])):
			base_of[String(d["family"])] = d
	for d in discs:
		var b: Dictionary = base_of[String(d["family"])]
		if b == d or not stat_rows.has(String(d["id"])) or not stat_rows.has(String(b["id"])):
			continue
		cur = String(d["id"])
		var rows: Dictionary = stat_rows[cur]
		var base_row: Dictionary = stat_rows[String(b["id"])]
		# (a thrall's health is a share of the hero's maximum health times thrallHpMult: DmStats)
		for pair in [["maxHp", ["maxHpMult"]], ["thrallHp", ["maxHpMult", "thrallHpMult"]], ["thrallDamage", ["thrallDamageMult"]], ["regen", ["essenceRegenMult"]]]:
			var ratio := 1.0
			for mk in pair[1]:
				ratio *= float(d["mods"][mk]) / float(b["mods"][mk])
			var want := float(base_row[pair[0]]) * ratio
			chk("mods", near(float(rows[pair[0]]), want, 0.01), "%s: %s %.2f = the %s's %.2f x %s (%s)" % [cur, pair[0], float(rows[pair[0]]), b["id"], float(base_row[pair[0]]), fmt(ratio), ", ".join(PackedStringArray(pair[1]))])


## Exhume raises the discipline's thrall kind up to its cap, at its health.
func thrall_checks(disc: Dictionary) -> void:
	var did := String(disc["id"])
	await arena(false)
	var cap := int(c.mods["thrallCap"])
	var gap := minf(1.0, (float(DmAbilities.def("exhume")["range"]) - 3.5) / float(cap))   # (every corpse inside Exhume's range, whatever the cap)
	for k in cap + 1:
		var pt := at(3.0 + gap * float(k), 1.5 * float(k % 2))
		field.add_corpse(pt.x, pt.z, "normal", "robber", false, 0.0, 1.0, "graves")
		c.p["castUntil"] = 0.0
		c.p["cooldowns"].erase("exhume")
		refill()
		c.request_cast("exhume", pt, -1)
		await ticks(2)
	var ids: Array = c.thralls().list()
	chk("mods", ids.size() == int(disc["mods"]["thrallCap"]), "%s: Exhume raises up to the cap of %s (%d)" % [did, fmt(float(disc["mods"]["thrallCap"])), ids.size()])
	var kinds_ok := not ids.is_empty()
	var hp_ok := not ids.is_empty()
	for tid in ids:
		var info: Dictionary = c.thralls().info(tid)
		kinds_ok = kinds_ok and String(info["kind"]) == String(disc["mods"]["thrallKind"])
		hp_ok = hp_ok and near(float(info["max_hp"]), float(c.p["stats"]["thrallHp"]), 0.01)
	chk("mods", kinds_ok and hp_ok, "%s: every thrall is a %s at the hero's thrall health" % [did, disc["mods"]["thrallKind"]])


# ------------------------------------------------------------------------------------------------------------------------ tooltip

func tooltip_checks(disc: Dictionary, id: String) -> void:
	var defs := DmAbilities.defs()
	if not defs.has(id):
		return   # (reported by the data checks)
	var d: Dictionary = defs[id]
	var abilities: Dictionary = DmContent.get_export("abilities", "ABILITIES")
	var codex: Dictionary = DmContent.get_export("codex", "CODEX_RITES")
	var prereq: bool = abilities.has(id) and codex.has(id) and DmSpellTooltip.TARGETING.has(String(d.get("targeting", "")))
	chk("tooltip", prereq, "%s: the spell card's sources have it (ability export %s, codex tip %s, targeting %s)" % [id, abilities.has(id), codex.has(id), d.get("targeting")])
	if not prereq:
		return
	var tip: Dictionary = DmSpellTooltip.build(id, disc, {"auto": false})
	var by_label := {}
	for m in tip["metrics"]:
		by_label[String(m["label"])] = String(m["value"])
	chk("tooltip", String(tip["name"]) == String(d["name"]) and String(tip["description"]) == String(d["description"]), "%s: the card's name and description are the row's (%s | %s)" % [id, tip["name"], tip["description"]])
	var reaper: bool = String(disc["family"]) == "reaper"
	var cost := float(d.get("soulCost", 0)) if reaper else float(d.get("essenceCost", 0))
	var cost_value := String((tip["metrics"] as Array)[0]["value"])
	var want_cost := "Free" if cost == 0.0 else fmt(cost)
	chk("tooltip", cost_value == want_cost or (cost != 0.0 and cost_value.begins_with(want_cost)), "%s: the card's cost is %s (%s)" % [id, want_cost, cost_value])
	chk("tooltip", String(by_label.get("Cooldown", "")) == "%ss" % fmt(float(d["cooldownMs"]) / 1000.0), "%s: the card's cooldown is %ss (%s)" % [id, fmt(float(d["cooldownMs"]) / 1000.0), by_label.get("Cooldown", "none")])
	chk("tooltip", String(tip["control"]) != "" and not (tip["details"] as Array).is_empty() and String(tip["tip"]) != "", "%s: the card has its control line, details and tip" % id)


# ------------------------------------------------------------------------------------------------------------------------ one spell

func poll_fx() -> void:
	var vfx := root.get_node_or_null("Vfx")
	if vfx == null or vfx.get("binbun") == null:
		return
	for l in vfx.binbun._live:
		seen_fx[String(l.id)] = true
		all_fx[String(l.id)] = true


func visual_total() -> int:
	var n := 0
	for k in VISUAL_KEYS:
		n += int(c.fx.stats.get(k, 0))
	return n


func spell_case(disc: Dictionary, id: String, is_sig: bool) -> void:
	var defs := DmAbilities.defs()
	if not defs.has(id) or not DmRiteRegistry.has(id):
		skip("cast", id, "no ability row or no rite module (the data check says so)")
		return
	var d: Dictionary = defs[id]
	var fam := String(disc["family"])
	var did := String(disc["id"])
	var reaper := String(c.p.get("family", "")) == "reaper"
	var legion := false
	var tries := 0
	var accepted := false
	var info := {}
	while tries < 2 and not accepted:
		var a := await arena(legion)
		var target := int(a["foe"])
		var aim: Vector3 = a["corpse_at"] if String(d.get("targeting", "")) == "corpse" else host.enemy_position(target)
		rec = RecAudio.new()
		c.fx.audio = rec
		ev_log.clear()
		seen_fx.clear()
		var fx0 := visual_total()
		var cold0 := DmFxBinbun.cold_loads
		# the pool is capped for the cast: whatever the spell hands back is held off, so what is spent is the price
		var full: float
		var cost: float
		var cap_key: String
		var cap_old: Variant
		var holder: Dictionary
		if reaper:
			holder = c.p
			cap_key = "soulsMax"
			full = float(int(c.p["souls"]))
			cost = float(int(d.get("soulCost", 0)))
		else:
			holder = c.p["stats"]
			cap_key = "maxEssence"
			full = float(c.p["resource"]["value"])
			cost = float(d.get("essenceCost", 0))
		cap_old = holder[cap_key]
		holder[cap_key] = int(full - cost) if reaper else full - cost
		rejected = ""
		var slot := slot_of(id, fam, did)
		var via := "caster"
		if slot >= 0:
			via = "hotbar slot %d" % slot
			g.input.cast_at(slot, aim, target, true)
		else:
			c.request_cast(id, aim, target)
		holder[cap_key] = cap_old
		accepted = rejected == ""
		if accepted:
			cast_count += 1
			var left: float = full - (float(int(c.p["souls"])) if reaper else c.essence())
			var cd_left := c.cooldown_left(id)
			info = {"spent": left, "cd": cd_left, "via": via, "fx0": fx0, "cold0": cold0, "target": target, "aim": aim, "cost": cost, "full": full}
		else:
			info = {"why": rejected}
			legion = true   # some spells need the legion on its feet: once more with it
		tries += 1
	chk("cast", accepted, "%s: the cast is accepted (%s)" % [id, info.get("why", "")])
	if not accepted:
		skip("cast", id, "refused (%s): its cost, cooldown, effect and sound were not measured" % info.get("why", ""))
		skip("effect", id, "no accepted cast")
		skip("sound", id, "no accepted cast")
		skip("warmed", id, "no accepted cast")
		if is_sig:
			chk("signature", false, "%s: the signature casts (refused: %s)" % [id, info.get("why", "")])
		return
	if is_sig:
		chk("signature", true, "%s: the signature casts" % id)
	# 2: price and cooldown are the row's
	if reaper:
		var spent := float(info["spent"])
		chk("cast", spent >= float(info["cost"]), "%s: %s souls spent, the row's soulCost is %s (%s)" % [id, fmt(spent), fmt(float(info["cost"])), info["via"]])
		if spent > float(info["cost"]):
			print("INFO spells: %s/%s also spends the rest of the bag (%s of %s souls, the row's soulCost is the least)" % [did, id, fmt(spent), fmt(float(info["full"]))])
	else:
		chk("cast", near(float(info["spent"]), float(info["cost"]), 1e-6), "%s: essence spent %s, the row's essenceCost is %s (%s)" % [id, fmt(float(info["spent"])), fmt(float(info["cost"])), info["via"]])
	chk("cast", near(float(info["cd"]), float(d["cooldownMs"]), 1e-6), "%s: the cooldown is %s ms, the row's cooldownMs is %s" % [id, fmt(float(info["cd"])), fmt(float(d["cooldownMs"]))])
	var lock := float(DmAbilities.cast_flow(id)["lockMs"])
	if lock > 0.0 or float(d["cooldownMs"]) > 0.0:
		rejected = ""
		c.request_cast(id, info["aim"], int(info["target"]))
		chk("cast", rejected in ["busy", "cooldown"], "%s: a second cast at once is refused (%s)" % [id, rejected])
	c.p["castUntil"] = 0.0   # (past the cast lock: only the cooldown can refuse now)
	refill()
	rejected = ""
	c.request_cast(id, info["aim"], int(info["target"]))
	if float(d["cooldownMs"]) > 0.0:
		chk("cast", rejected == "cooldown", "%s: a second cast inside the cooldown is refused by the cooldown (%s)" % [id, rejected])
	else:
		chk("cast", rejected != "cooldown", "%s: the row has no cooldown and none refuses (%s)" % [id, rejected])
	# 4: effect and sound, warmed (three quarters of a second, or the spell's own cast lock and gesture and a half second more when those take longer)
	var flow := DmAbilities.cast_flow(id)
	for k in maxi(45, int((float(flow["lockMs"]) / 1000.0 + float(flow.get("gestureSeconds", 0.0))) * 60.0) + 30):
		await physics_frame
		poll_fx()
	chk("effect", not ev_log.is_empty(), "%s: the cast plays events (%d)" % [id, ev_log.size()])
	chk("effect", visual_total() > int(info["fx0"]), "%s: the cast draws effects (%d counted)" % [id, visual_total() - int(info["fx0"])])
	chk("sound", not rec.sfx.is_empty() or not rec.loops.is_empty(), "%s: the cast makes a sound (%s)" % [id, ", ".join(PackedStringArray(rec.sfx + rec.loops.map(func(l: String) -> String: return "loop:" + l)))])
	var known: Dictionary = DmFxData.data().get("effects", {})
	var missing: Array = seen_fx.keys().filter(func(e: String) -> bool: return not known.has(e))
	chk("warmed", missing.is_empty(), "%s: every Binbun scene it showed (%s) is in the set the warm-up builds (missing: %s)" % [id, ", ".join(PackedStringArray(seen_fx.keys())), ", ".join(PackedStringArray(missing))])
	chk("warmed", DmFxBinbun.cold_loads == int(info["cold0"]), "%s: no effect scene is read from disk during the cast (%d)" % [id, DmFxBinbun.cold_loads - int(info["cold0"])])
	c.fx.audio = null


# ------------------------------------------------------------------------------------------------------------------------ the end

func finish(discs: Array) -> void:
	ratio_checks(discs)
	if g != null:
		g.queue_free()
	await ticks(5)
	await process_frame
	var secs_total := float(Time.get_ticks_msec() - t0_msec) / 1000.0
	print("INFO spells: coverage, passed/failed/skipped checks per discipline (columns: %s)" % ", ".join(PackedStringArray(KINDS)))
	for d in discs:
		var row: Array = []
		for k in KINDS:
			var m: Array = matrix[String(d["id"])][k]
			row.append("%d/%d/%d" % [m[0], m[1], m[2]])
		print("INFO spells:   %-10s %s" % [d["id"], "  ".join(PackedStringArray(row))])
	print("INFO spells: %d Binbun scenes seen over the casts, of %d the warm-up builds" % [all_fx.size(), DmFxData.data().get("effects", {}).size()])
	print("INFO spells: %d games, %d casts, %d checks in %.0f s, %d parts skipped" % [booted, cast_count, checks, secs_total, skipped.size()])
	checks += 1
	if not errlog.errors.is_empty():
		fails += 1
		printerr("FAIL spells: ZERO script errors or engine errors in the log (%d)" % errlog.errors.size())
		for e in errlog.errors:
			printerr("ERROR LOG: " + e)
	if fails == 0 and checks > 0:
		print("PASS spells (%d checks)" % checks)
		quit(0)
	else:
		printerr("FAIL spells: %d of %d checks failed" % [fails, checks])
		quit(1)
