extends SceneTree
## Golden-fixture runner for godot/rules/progression.
## Run: /home/ubuntu/tools/godot/godot --headless --path godot --script res://tests/rules-progression/run.gd
## Fixtures: tools/godot/fixtures-progression.ts (tools/godot/gen-fixtures.sh) -> godot/tests/rules-progression/fixtures/*.json

const DIR := "res://tests/rules-progression/fixtures/"
var passed := 0
var failed := 0
var per_file: Dictionary = {}
var _shown := 0
var _cur := ""


func _initialize() -> void:
	if not FileAccess.file_exists(DIR + "pure.json"):
		print("fixtures missing: run tools/godot/gen-fixtures.sh")
		quit(1)
		return
	for t in ["pure", "necro_seq", "kill_chain", "chronicle_seq", "progression_seq"]:
		_cur = t
		call("t_" + t)
	print("--- rules-progression: %d / %d passed, %d failed ---" % [passed, passed + failed, failed])
	for k in per_file:
		print("  %-18s %s" % [k, per_file[k]])
	quit(0 if failed == 0 else 1)


func load_json(name: String) -> Variant:
	var f := FileAccess.open(DIR + name + ".json", FileAccess.READ)
	return DmProgUtil.ints(JSON.parse_string(f.get_as_text()))


func is_n(v: Variant) -> bool:
	return v is int or v is float


## Deep equality: numbers within 1e-9 (int == float), exact keys.
func eq(a: Variant, b: Variant) -> bool:
	if is_n(a) and is_n(b):
		var x := float(a)
		var y := float(b)
		return absf(x - y) <= 1e-9 or absf(x - y) <= 1e-12 * maxf(absf(x), absf(y))
	if a is Dictionary and b is Dictionary:
		if a.size() != b.size():
			return false
		for k in a:
			if not b.has(k) or not eq(a[k], b[k]):
				return false
		return true
	if a is Array and b is Array:
		if a.size() != b.size():
			return false
		for i in a.size():
			if not eq(a[i], b[i]):
				return false
		return true
	return typeof(a) == typeof(b) and a == b


func diff(a: Variant, b: Variant, path: String = "") -> String:
	if eq(a, b):
		return ""
	if a is Dictionary and b is Dictionary:
		for k in a:
			if not b.has(k):
				return path + "/" + str(k) + " (unexpected)"
			var d := diff(a[k], b[k], path + "/" + str(k))
			if d != "":
				return d
		for k in b:
			if not a.has(k):
				return path + "/" + str(k) + " (missing)"
	if a is Array and b is Array and a.size() == b.size():
		for i in a.size():
			var d2 := diff(a[i], b[i], path + "[%d]" % i)
			if d2 != "":
				return d2
	return "%s: got %s want %s" % [path, JSON.stringify(a).left(150), JSON.stringify(b).left(150)]


func check(ok: bool, what: String, got: Variant, want: Variant) -> void:
	var key := _cur
	if not per_file.has(key):
		per_file[key] = [0, 0]
	if ok:
		passed += 1
		per_file[key][0] += 1
	else:
		failed += 1
		per_file[key][1] += 1
		if _shown < 15:
			_shown += 1
			print("FAIL [%s] %s\n   %s" % [key, what.left(160), diff(got, want)])


func cmp(what: String, got: Variant, want: Variant) -> void:
	check(eq(got, want), what, got, want)


func nul(i: int) -> Variant:
	return null if i == -1 else i


# --- pure -----------------------------------------------------------------------

func pure_call(fn: String, a: Array) -> Variant:
	match fn:
		"vowSteps": return DmAscension.vow_steps(a[0], a[1])
		"sanitizeVows": return DmAscension.sanitize_vows(a[0])
		"vowHeat": return DmAscension.vow_heat(a[0])
		"worldVows": return DmAscension.world_vows(a[0])
		"vowEffects": return DmAscension.vow_effects(a[0])
		"ascensionRewardMult": return DmAscension.ascension_reward_mult(a[0])
		"ascensionLevels": return DmAscension.ascension_levels(a[0])
		"legacyVows": return DmAscension.legacy_vows(a[0])
		"roman": return DmAscension.roman(int(a[0]))
		"boonEffects": return DmAscension.boon_effects(a[0])
		"boonBlocked":
			var b := DmAscension.boon_blocked(a[0], a[1], a[2], a[3])
			return null if b == "" else b
		"boonCost": return nul(DmAscension.boon_cost(a[0], a[1]))
		"isUnlocked": return DmAscension.is_unlocked(a[0], a[1])
		"unlockCost": return nul(DmAscension.unlock_cost(a[0]))
		"ashesForRun": return DmAscension.ashes_for_run(a[0], a[1])
		"damageUpgradeCost": return DmUpgrades.damage_cost(int(a[0]))
		"legionUpgradeCost": return DmUpgrades.legion_cost(int(a[0]))
		"waveUpgradeCost": return DmUpgrades.wave_cost(int(a[0]))
		"damageBonusPct": return DmUpgrades.damage_bonus_pct(float(a[0]))
		"densityTier": return DmUpgrades.density_tier(float(a[0]))
		"waveModifiers": return DmUpgrades.wave_modifiers(float(a[0]))
		"milestones": return DmUpgrades.milestones(float(a[0]), float(a[1]))
		"milestoneActive": return DmUpgrades.milestone_active(a[0], float(a[1]))
		"xpToNext": return DmProgression.xp_to_next(int(a[0]))
		"tierFor": return DmKillChain.tier_for(int(a[0]))
		"damageCost": return nul(DmNecroRules.damage_cost(a[0]))
		"waveCost": return nul(DmNecroRules.wave_cost(a[0]))
		"legionCost": return nul(DmNecroRules.legion_cost(a[0]))
		"runHeat": return DmNecroRules.run_heat(a[0])
		"ashesOnAscend": return DmNecroRules.ashes_on_ascend(a[0])
		"unlockKills": return nul(DmNecroRules.unlock_kills(a[0], a[1]))
		"normalise": return DmNecroRules.normalise(a[0])
		"milestonesList":
			var out: Array = []
			for m in DmMilestones.list():
				out.append({"id": m["id"], "title": m["title"], "text": m["text"], "gold": m["gold"]})
			return out
		"newlyReached":
			var ids: Array = []
			for m in DmMilestones.newly_reached(a[0], a[1]):
				ids.append(m["id"])
			return ids
	return "UNKNOWN FN " + fn


func t_pure() -> void:
	for c in load_json("pure"):
		cmp("%s(%s)" % [c["fn"], JSON.stringify(c["args"]).left(200)], pure_call(c["fn"], c["args"]), c["out"])


# --- necro sequences ------------------------------------------------------------------

func necro_step(st: Dictionary, state: Dictionary) -> Dictionary:
	var a: Array = st["args"]
	var o: Variant = st.get("opts")
	match st["op"]:
		"applySave": return DmNecroRules.apply_save(state, a[0], o)
		"purchase": return DmNecroRules.purchase(state, float(a[0]), a[1])
		"summonPrelate": return DmNecroRules.summon_prelate(state, o)
		"summonAreaBoss": return DmNecroRules.summon_area_boss(state, a[0], o)
		"ascend": return DmNecroRules.ascend(state)
		"swearVows": return DmNecroRules.swear_vows(state, a[0])
		"unlockEntry": return DmNecroRules.unlock_entry(state, a[0])
		"buyBoon": return DmNecroRules.buy_boon(state, a[0])
		"importLocal": return DmNecroRules.import_local(state, a[0])
	return {"ok": false, "error": "UNKNOWN OP"}


func t_necro_seq() -> void:
	var n := 0
	for seq in load_json("necro_seq"):
		n += 1
		var state: Dictionary = seq["start"]
		var i := 0
		for st in seq["steps"]:
			var got := necro_step(st, state)
			cmp("seq %d step %d %s %s" % [n, i, st["op"], JSON.stringify(st["args"]).left(200)], got, st["out"])
			if got["ok"]:
				state = got["state"]
			i += 1


# --- kill chain ----------------------------------------------------------------------------

func t_kill_chain() -> void:
	var n := 0
	for seq in load_json("kill_chain"):
		n += 1
		var kc := DmKillChain.new()
		var i := 0
		for st in seq["steps"]:
			var now: float = st["now"]
			var out: Variant = null
			match st["op"]:
				"hit": out = kc.hit(now)
				"tick": out = kc.tick(now)
				"reset": kc.reset()
				"frac": out = kc.frac(now)
			var got := {"out": out, "count": kc.count, "best": kc.best, "mult": kc.mult(), "active": kc.active(), "tier": kc.tier(), "frac": kc.frac(now)}
			var want := {"out": st["out"], "count": st["count"], "best": st["best"], "mult": st["mult"], "active": st["active"], "tier": st["tier"], "frac": st["frac"]}
			cmp("chain %d step %d %s" % [n, i, st["op"]], got, want)
			i += 1


# --- chronicle ----------------------------------------------------------------------------------

func t_chronicle_seq() -> void:
	var n := 0
	for seq in load_json("chronicle_seq"):
		n += 1
		var c := DmChronicle.new()
		c.set_data(seq["data"])
		var i := 0
		for st in seq["steps"]:
			var a: Array = st["args"]
			match st["op"]:
				"add": c.add(a[0], a[1])
				"max": c.max_(a[0], float(a[1]))
				"time": c.time(float(a[0]), a[1])
				"flush_ok", "flush_fail":
					var b := c.flush_begin()
					if not b.is_empty():
						c.flush_done(b, st["op"] == "flush_ok")
			var got := {"sums": c.sums, "maxes": c.maxes, "data": {"life": c.data["life"], "run": c.data["run"]}, "view": {"life": c.view()["life"], "run": c.view()["run"]}, "fraction": c.fraction}
			var want := {"sums": st["sums"], "maxes": st["maxes"], "data": st["data"], "view": st["view"], "fraction": st["fraction"]}
			cmp("chronicle %d step %d %s" % [n, i, st["op"]], got, want)
			i += 1


# --- progression ------------------------------------------------------------------------------------

func snap(p: DmProgression) -> Dictionary:
	var out := {
		"local": p.local,
		"character": {"level": p.character["level"], "experience": p.character["experience"], "gold": p.character["gold"]},
		"pending": p.pending,
		"pendingWaveActive": p.pending_wave_active,
		"chronicle": null,
	}
	if p.chronicle != null:
		var v := p.chronicle.view()
		out["chronicle"] = {"life": v["life"], "run": v["run"]}
	return out


func prog_op(p: DmProgression, st: Dictionary) -> Variant:
	var a: Array = st["args"]
	match st["op"]:
		"addXp": return p.add_xp(float(a[0]))
		"addGold":
			p.add_gold(float(a[0]))
			return null
		"buyDamage": return p.buy_damage()
		"buyWave": return p.buy_wave()
		"buyLegion": return p.buy_legion()
		"ascend": return p.ascend()
		"swearVows":
			var pr := p.vows_problem(a[0])
			var rs := p.vows_restart_run(a[0])
			return [null if pr == "" else pr, rs, p.swear_vows(a[0])]
		"unlockAtAltar":
			var up := p.unlock_problem(a[0])
			return [null if up == "" else up, p.unlock_at_altar(a[0])]
		"buyBoon":
			var bp := p.boon_problem(a[0])
			return [null if bp == "" else bp, p.buy_boon(a[0])]
		"recordKill":
			if a.size() > 1:
				p.record_kill(a[0], float(a[1]))
			else:
				p.record_kill(a[0])
			return null
		"recordPrelateKill":
			p.record_prelate_kill()
			return null
		"unlock": return [p.unlock(a[0]), p.is_unlocked(a[0]), p.really_unlocked(a[0])]
		"addShards":
			p.add_shards(int(a[0]))
			return null
		"spendShards": return p.spend_shards(int(a[0]))
		"spendBossShards": return p.spend_boss_shards(a[0])
		"refundBossShards":
			p.refund_boss_shards(a[0])
			return null
		"setActiveWaveTier":
			p.set_active_wave_tier(float(a[0]))
			return null
		"adopt":
			p.adopt(a[0])
			return null
		"queries":
			return [p.damage_cost() if p.damage_cost() != -1 else null, p.wave_cost() if p.wave_cost() != -1 else null, p.legion_cost() if p.legion_cost() != -1 else null, p.ashes_on_ascend(), p.can_ascend(), p.heat(), p.boons(), p.vow_fx(), p.kills(a[0]), p.unlock_kills(float(a[1] if a.size() > 1 else 1))]
	return "UNKNOWN OP"


func t_progression_seq() -> void:
	var n := 0
	for seq in load_json("progression_seq"):
		n += 1
		var ch: Dictionary = seq["character"].duplicate()
		var p := DmProgression.new(ch, seq["savedLocal"])
		cmp("prog %d loaded" % n, p.local, seq["loaded"])
		p.mode = seq["mode"]
		p.dev_access = seq["dev"]
		if seq["withChron"]:
			p.chronicle = DmChronicle.new()
		# the TS fixture bumps shards/prelate before the first snapshot when seeded that way; compare via `initial`
		var init: Dictionary = seq["initial"]
		if not eq(snap(p)["local"], init["local"]):
			# generator applied: shards += 150, run.prelateKills >= 1 (50% of runs)
			p.local["shards"] += 150
			p.local["run"]["prelateKills"] = maxi(1, int(p.local["run"]["prelateKills"]))
		cmp("prog %d initial" % n, snap(p), init)
		cmp("prog %d toNecro" % n, DmProgression.to_necro(p.local), seq["toNecro"])
		var i := 0
		for st in seq["steps"]:
			var ret: Variant = prog_op(p, st)
			var got := snap(p)
			got["ret"] = ret
			var want: Dictionary = {"ret": st["ret"]}
			for k in ["local", "character", "pending", "pendingWaveActive", "chronicle"]:
				want[k] = st[k]
			cmp("prog %d step %d %s %s" % [n, i, st["op"], JSON.stringify(st["args"]).left(150)], got, want)
			i += 1
