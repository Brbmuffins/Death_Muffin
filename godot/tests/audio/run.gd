extends SceneTree
## Headless: godot --headless --path godot --script res://tests/audio/run.gd
## Mixer maths, music state machine + handover timing, seeded sample selection, ambience/footstep rules (golden fixtures from
## src/audio via tools/godot/fixtures-audio.ts), asset resolution (every referenced sample id resolves to an imported file) and
## an AudioDirector integration run on the headless dummy audio driver.

const FX := "res://tests/audio/fixtures/"
const Mixer := preload("res://audio/audio_mixer.gd")
const Packs := preload("res://audio/audio_packs.gd")
const Amb := preload("res://audio/audio_ambience.gd")
const Samples := preload("res://audio/audio_samples.gd")
const MusicState := preload("res://audio/audio_music_state.gd")
const Director := preload("res://audio/audio_director.gd")
const Synth := preload("res://audio/audio_synth.gd")
const Foot := preload("res://audio/audio_footsteps.gd")
const Gather := preload("res://audio/audio_gather_sfx.gd")
const AMap := preload("res://audio/audio_map.gd")
const MusicDir := preload("res://audio/audio_music.gd")

var pass_n := 0
var fail_n := 0
var section := ""


func _init() -> void:
	if not FileAccess.file_exists(FX + "mix_gain.json"):
		printerr("fixtures missing: run tools/godot/gen-fixtures.sh")
		quit(1)
		return
	for t in ["mix_gain", "mix_distance", "mix_repeat", "pick_variant", "loot", "activity", "profiles", "limiters", "packs", "legacy", "ambience", "footsteps", "gather", "duck_factor", "settings_keys", "music_state", "music_handover", "sample_selection", "resolve_assets", "synth"]:
		section = t
		call("_test_" + t)
	await process_frame
	section = "director"
	await _test_director()
	section = "music_director"
	await _test_music_director()
	print("audio: %d passed, %d failed" % [pass_n, fail_n])
	quit(1 if fail_n > 0 else 0)


func ok(cond: bool, msg: String) -> void:
	if cond:
		pass_n += 1
	else:
		fail_n += 1
		if fail_n <= 40:
			printerr("FAIL [%s]: %s" % [section, msg])


func fx(name: String) -> Variant:
	var f := FileAccess.open(FX + name + ".json", FileAccess.READ)
	return JSON.parse_string(f.get_as_text())


func diff(a: Variant, b: Variant, path: String = "") -> String:
	var an := a is int or a is float
	var bn := b is int or b is float
	if an and bn:
		var x := float(a)
		var y := float(b)
		if absf(x - y) <= 1e-9 * maxf(1.0, maxf(absf(x), absf(y))):
			return ""
		return "%s: %s != %s" % [path, str(a), str(b)]
	if a == null or b == null:
		return "" if a == null and b == null else "%s: %s != %s" % [path, str(a), str(b)]
	if a is Array and b is Array:
		if a.size() != b.size():
			return "%s: array size %d != %d" % [path, a.size(), b.size()]
		for i in a.size():
			var d := diff(a[i], b[i], "%s[%d]" % [path, i])
			if d != "":
				return d
		return ""
	if a is Dictionary and b is Dictionary:
		for k in a:
			if not b.has(k):
				return "%s: extra key %s" % [path, str(k)]
		for k in b:
			if not a.has(k):
				return "%s: missing key %s" % [path, str(k)]
			var d := diff(a[k], b[k], "%s.%s" % [path, str(k)])
			if d != "":
				return d
		return ""
	if typeof(a) != typeof(b):
		return "%s: type %d != %d (%s vs %s)" % [path, typeof(a), typeof(b), str(a), str(b)]
	return "" if a == b else "%s: %s != %s" % [path, str(a), str(b)]


func eq(got: Variant, want: Variant, label: String) -> void:
	var d := diff(got, want)
	ok(d == "", "%s -> %s" % [label, d])


func near(a: float, b: float, tol: float, label: String) -> void:
	ok(absf(a - b) <= tol, "%s: %f vs %f" % [label, a, b])


# --- mixer maths ---------------------------------------------------------------------------------

func _test_mix_gain() -> void:
	var f: Dictionary = fx("mix_gain")
	for c in f["slider"]:
		eq(Mixer.slider_gain(float(c["v"])), c["g"], "slider %s" % str(c["v"]))
	for c in f["bus"]:
		var s: Dictionary = c["s"]
		var got: float = Mixer.master_gain(s) if c["bus"] == "master" else Mixer.bus_gain(c["bus"], s)
		eq(got, c["g"], "bus %s" % c["bus"])
	# spot values by hand
	near(Mixer.slider_gain(0.5), pow(0.5, 1.5), 1e-12, "slider 0.5")
	near(Mixer.slider_gain(NAN), 1.0, 0.0, "slider NaN -> 1")
	near(Mixer.master_gain({"volume": 0.6, "combatVolume": 1.0, "ambienceVolume": 1.0, "musicVolume": 0.85, "interfaceVolume": 1.0}), pow(0.6, 1.5) * 0.9, 1e-12, "master default")
	near(Mixer.music_gain({"musicVolume": 0.85}), pow(0.85, 1.5) * 0.72, 1e-12, "music gain")
	eq(Array(Mixer.BUS_IDS), ["combat", "enemies", "thralls", "ui", "ambience"], "bus ids")


func _test_mix_distance() -> void:
	var f: Dictionary = fx("mix_distance")
	for c in f["gain"]:
		eq(Mixer.distance_gain(float(c["d"]), c["bus"]), c["g"], "distance gain %s %s" % [c["bus"], str(c["d"])])
	for c in f["culled"]:
		ok(Mixer.culled(float(c["d"]), c["bus"], int(c["p"])) == c["c"], "culled %s d=%s p=%s" % [c["bus"], str(c["d"]), str(c["p"])])
	for c in f["pan"]:
		eq(Mixer.pan_for(float(c["dx"])), c["p"], "pan %s" % str(c["dx"]))


func _test_mix_repeat() -> void:
	var f: Dictionary = fx("mix_repeat")
	for c in f["gain"]:
		eq(Mixer.repeat_gain(int(c["n"])), c["g"], "repeat gain %d" % int(c["n"]))
	for c in f["drop"]:
		ok(Mixer.repeat_dropped(int(c["n"]), int(c["p"])) == c["d"], "repeat drop n=%s p=%s" % [str(c["n"]), str(c["p"])])
	for c in f["cap"]:
		ok(Mixer.effective_cap(c["bus"], int(c["p"])) == int(c["cap"]), "cap %s p=%s: %d vs %d" % [c["bus"], str(c["p"]), Mixer.effective_cap(c["bus"], int(c["p"])), int(c["cap"])])
		ok(int(Mixer.BUS_CAP[c["bus"]]) == int(c["base"]), "base cap %s" % c["bus"])


func _test_pick_variant() -> void:
	for c in fx("mix_pick_variant"):
		ok(Mixer.pick_variant(int(c["count"]), int(c["last"]), float(c["rnd"])) == int(c["v"]), "pick_variant %s" % str(c))


func _test_loot() -> void:
	for c in fx("mix_loot"):
		ok(Mixer.loot_sfx(c["r"]) == c["s"], "loot %s" % str(c["r"]))


func _test_activity() -> void:
	var act := Mixer.CombatActivity.new()
	for c in fx("mix_activity"):
		var weight := Mixer.activity_weight(c["bus"], int(c["p"]))
		eq(weight, c["weight"], "weight")
		# the generator bumped with probability 0.6; replay by detecting the bump from the recorded level
		var before := act.level(float(c["t"]))
		var want := float(c["level"])
		var bumped := absf(minf(1.5, before + weight) - want) < 1e-9 and weight > 0.0
		if bumped:
			act.bump(float(c["t"]), weight)
		near(act.level(float(c["t"])), want, 1e-9, "activity level t=%s" % str(c["t"]))
		near(Mixer.bed_duck_gain(want), float(c["bed"]), 1e-12, "bed duck")
		ok(Mixer.accents_allowed(want) == c["accents"], "accents allowed")
	near(Mixer.music_combat_gain(1.0, false), 0.62, 1e-12, "music combat gain")
	near(Mixer.music_combat_gain(1.0, true), 0.8, 1e-12, "music combat gain boss")
	near(Mixer.music_combat_gain(5.0, false), 0.62, 1e-12, "music combat gain clamps")


func _test_profiles() -> void:
	for c in fx("profiles"):
		var p := Mixer.profile_of(c["n"])
		eq({"bus": p["bus"], "priority": p["priority"], "dur": p["dur"], "thin": p.get("thin"), "duck": p.get("duck")},
			{"bus": c["bus"], "priority": c["priority"], "dur": c["dur"], "thin": c["thin"], "duck": c["duck"]}, "profile %s" % c["n"])


func _test_limiters() -> void:
	var f: Dictionary = fx("limiters")
	var vl := Mixer.VoiceLimiter.new()
	for c in f["voice"]:
		var reason := vl.request(c["bus"], int(c["priority"]), float(c["now"]), float(c["dur"]))
		ok((reason == "") == bool(c["ok"]) and reason == c["reason"], "voice limiter admit %s" % str(c["now"]))
		ok(vl.active(c["bus"], float(c["now"])) == int(c["active"]) and vl.total(float(c["now"])) == int(c["total"]), "voice limiter counts")
	ok(vl.dropped == int(f["dropped"]), "voice limiter dropped")
	eq(vl.dropped_by_bus, f["droppedByBus"], "dropped by bus")
	eq(vl.peak, f["peak"], "peak")
	var il := Mixer.IdLimiter.new()
	for c in f["id"]:
		ok(il.request(c["id"], float(c["now"]), float(c["dur"]), int(c["maxVoices"]), float(c["cooldown"])) == c["ok"] and il.dropped == int(c["dropped"]), "id limiter %s" % str(c["now"]))
	var wc := Mixer.WindowCounter.new()
	for c in f["window"]:
		ok(wc.count(c["key"], float(c["now"]), float(c["window"])) == int(c["count"]), "window counter %s" % str(c["now"]))
		if c["added"]:
			wc.add(c["key"], float(c["now"]))
	# a deterministic window check of our own
	wc = Mixer.WindowCounter.new()
	for t in [0.0, 0.05, 0.1, 0.2]:
		wc.add("k", t)
	ok(wc.count("k", 0.2, 0.15) == 2, "window counter prunes (>=0.15 old are out)")


func _test_packs() -> void:
	var f: Dictionary = fx("packs")
	for c in f["ids"]:
		var id: String = c["id"]
		ok(Packs.pack_of(id) == c["pack"], "pack_of %s: %s vs %s" % [id, Packs.pack_of(id), c["pack"]])
		eq(Packs.cap_seconds(id), c["cap"], "cap %s" % id)
		eq(Packs.cap_seconds(id, true), c["capLayer"], "cap layer %s" % id)
		ok(Packs.keeps_start(id) == c["keepsStart"], "keeps_start %s" % id)
		ok(Packs.mix_bus_of(id) == c["mixBus"], "mix_bus_of %s" % id)
		eq(Packs.clips_of(id), c["clips"], "clips_of %s" % id)
		ok(Packs.is_keep(id) == c["keep"], "is_keep %s" % id)
	eq(Packs.all_packs(), f["all"], "all packs")
	for p in f["byPack"]:
		var got := Packs.pack_clips(p)
		got.sort()
		eq(got, f["byPack"][p], "pack clips %s" % p)
	for a in f["areas"]:
		var got := Packs.area_packs(a)
		var want: Array = f["areas"][a]
		got.sort()
		var w2 := want.duplicate()
		w2.sort()
		eq(got, w2, "area packs %s" % a)
		ok(got.size() == want.size(), "area packs unique %s" % a)
	for c in f["clipFileSample"]:
		ok(Samples.clip_path(c["c"]) == "res://assets/audio/esm/" + String(c["f"]).trim_prefix("audio/esm/").trim_suffix(".opus") + ".wav", "clip path %s" % c["c"])


func _test_legacy() -> void:
	var f: Dictionary = fx("legacy")
	eq(Samples.legacy_names(), f["names"], "legacy names")
	for c in f["urls"]:
		var want := "res://assets/" + String(c["u"]).trim_suffix(".ogg") + ".ogg"
		ok(Samples.legacy_path(c["n"]) == want, "legacy path %s: %s vs %s" % [c["n"], Samples.legacy_path(c["n"]), want])
	for k in f["LEGACY"]:
		var spec: Dictionary = f["LEGACY"][k]
		var mine: Dictionary = Samples.LEGACY[k]
		eq(mine["files"], spec["files"], "legacy files %s" % k)
		eq(mine["gain"], spec["gain"], "legacy gain %s" % k)
		eq(mine["synthMix"], spec["synthMix"], "legacy synthMix %s" % k)
	ok(Samples.LEGACY.size() == f["LEGACY"].size(), "legacy size")


func _test_ambience() -> void:
	var f: Dictionary = fx("ambience")
	for a in f["beds"]:
		var want: Dictionary = f["beds"][a]
		var got: Dictionary = Amb.ZONE_BEDS[a]
		var loops: Array = []
		for l in want["loops"]:
			loops.append({"file": l["file"], "gain": l["gain"], "rate": l.get("rate", 1.0), "lp": l.get("lp", 0)})
		eq(got["loops"], loops, "bed loops %s" % a)
		eq(got["wind"], want["wind"], "bed wind %s" % a)
		eq(got["drones"], want["drones"], "bed drones %s" % a)
		eq(Amb.ZONE_ACCENTS[a]["gap"], f["accents"][a]["gap"], "accent gap %s" % a)
		eq(Amb.ZONE_ACCENTS[a]["sounds"], f["accents"][a]["sounds"], "accent sounds %s" % a)
	ok(Amb.ZONE_BEDS.size() == f["beds"].size(), "bed count")
	for c in f["gap"]:
		eq(Amb.accent_gap(c["a"], float(c["r"])), c["v"], "accent_gap %s" % c["a"])
	for c in f["pick"]:
		ok(Amb.pick_accent(c["a"], float(c["r"])) == c["v"], "pick_accent %s %s" % [c["a"], str(c["r"])])
	for a in f["music"]:
		ok(MusicState.cue_for(a) == f["music"][a], "music for area %s" % a)
	ok(MusicState.MUSIC_FOR_AREA.size() == f["music"].size(), "music map size")
	ok(Amb.bed_ready("graves", func(x: String) -> bool: return true), "bed ready when all loaded")
	ok(not Amb.bed_ready("graves", func(x: String) -> bool: return x != "bed_rain"), "bed not ready when one missing")


func _test_footsteps() -> void:
	var n := 0
	for run in fx("footsteps"):
		var ft := Foot.new()
		for fr in run:
			if fr["reset"]:
				ft.reset()
			var phase := -1.0 if fr["phase"] == null else float(fr["phase"])
			var got := ft.step(phase, float(fr["x"]), float(fr["z"]))
			ok(got == bool(fr["step"]), "footstep frame mismatch")
			n += 1
	ok(n == 2400, "footstep frames replayed (%d)" % n)
	# deterministic scenario: phase crossing 0.04 and 0.54 emits exactly two steps per cycle
	var ft2 := Foot.new()
	var steps := 0
	var ph := 0.0
	for i in 200:
		ph = fposmod(ph + 0.02, 1.0)
		if ft2.step(ph, 0.0, 0.0):
			steps += 1
	ok(steps >= 7 and steps <= 8, "two footfalls per cycle over 4 cycles (%d)" % steps)
	# fallback: one step per 1.35 units walked without a phase
	var ft3 := Foot.new()
	var s3 := 0
	for i in 101:
		if ft3.step(-1.0, float(i) * 0.1, 0.0):
			s3 += 1
	ok(s3 == 7, "fallback stride: 10 units -> 7 steps (%d)" % s3)


func _test_gather() -> void:
	for c in fx("gather_sfx"):
		ok(Gather.gather_sfx(c["s"], c["k"]) == c["v"], "gather_sfx %s/%s" % [c["s"], c["k"]])


# --- ducking ----------------------------------------------------------------------------------------

func _test_duck_factor() -> void:
	near(Mixer.duck_factor(0.4, 0.3, 0.35, 0.0), 1.0, 1e-9, "duck starts at 1")
	near(Mixer.duck_factor(0.4, 0.3, 0.35, 0.3), 0.6 + 0.4 * exp(-10.0), 1e-9, "duck reaches the floor within hold")
	ok(Mixer.duck_factor(0.4, 0.3, 0.35, 0.1) < Mixer.duck_factor(0.4, 0.3, 0.35, 0.03), "duck keeps falling")
	var low := Mixer.duck_factor(0.4, 0.3, 0.35, 0.3)
	ok(Mixer.duck_factor(0.4, 0.3, 0.35, 0.65) > low and Mixer.duck_factor(0.4, 0.3, 0.35, 0.65) < 1.0, "duck releasing")
	near(Mixer.duck_factor(0.4, 0.3, 0.35, 5.0), 1.0, 1e-4, "duck fully released")
	ok(Mixer.duck_factor(0.6, 1.5, 1.2, 1.0) < 0.41, "playerDeath duck is deep")
	var d := Mixer.map_duck("bossTellRot")
	ok(not d.is_empty() and absf(d["depth"] - 0.3) < 1e-9 and absf(d["hold"] - 0.6) < 1e-9, "bossTell* share the bossTell rule")
	ok(Mixer.map_duck("coin").is_empty(), "no duck for coin")


func _test_settings_keys() -> void:
	var a := Mixer.normalize_settings({"vol_master": 0.7, "vol_combat": 0.8, "vol_amb": 0.6, "vol_music": 0.5, "vol_ui": 0.8})
	eq(a, {"volume": 0.7, "combatVolume": 0.8, "ambienceVolume": 0.6, "musicVolume": 0.5, "interfaceVolume": 0.8}, "panel keys map to web keys")
	var b := Mixer.normalize_settings({"volume": 0.3, "vol_master": 0.9})
	near(b["volume"], 0.3, 0.0, "web key wins")
	near(b["musicVolume"], 0.85, 0.0, "default music")
	near(Mixer.bus_slider("enemies", a), 0.8, 0.0, "enemies follow the combat slider")
	near(Mixer.bus_slider("thralls", a), 0.8, 0.0, "thralls follow the combat slider")
	near(Mixer.bus_slider("ui", a), 0.8, 0.0, "ui follows interface")
	near(Mixer.bus_slider("ambience", a), 0.6, 0.0, "ambience follows ambience")


# --- music state machine ----------------------------------------------------------------------------

func _ops(cmds: Array) -> String:
	var out: PackedStringArray = []
	for c in cmds:
		out.append("%s%s" % [c["op"], (":" + str(c["cue"])) if c.has("cue") else ""])
	return ",".join(out)


func _test_music_state() -> void:
	var s := MusicState.new()
	ok(_ops(s.set_volume(0.85)) == "", "volume up with no area does nothing")
	ok(_ops(s.set_area("")) == "", "same (empty) area is a no-op")
	var c := s.set_area("graves")
	ok(_ops(c) == "start:graves" and s.pending_cue == "graves" and s.current_cue == "", "entering graves starts its theme")
	var slot: int = c[0]["slot"]
	ok(_ops(s.started(slot)) == "" and s.current_cue == "graves" and s.pending_cue == "", "first start becomes current, nothing to retire")
	ok(_ops(s.set_area("fen")) == "", "fen shares graves' theme: no restart")
	ok(_ops(s.set_area("coliseum")) == "" and s.current_cue == "graves", "coliseum too")
	c = s.set_boss(true)
	ok(_ops(c) == "start:boss", "boss starts the boss cue")
	var boss_slot: int = c[0]["slot"]
	var r := s.started(boss_slot)
	ok(_ops(r) == "retire" and r[0]["slot"] == slot and s.current_cue == "boss", "crossfade: old theme retires when boss plays")
	ok(_ops(s.set_boss(true)) == "", "boss twice is a no-op")
	c = s.set_boss(false)
	ok(_ops(c) == "start:graves", "boss over: back to the area's theme")
	s.started(c[0]["slot"])
	# a new area resets the boss flag
	s.set_boss(true)
	var bc := s.pending_slot
	s.started(bc)
	c = s.set_area("pyre")
	ok(s.boss == false and _ops(c) == "start:pyre", "changing area clears boss and starts pyre")
	s.started(c[0]["slot"])
	# stale start: switch twice before the first finishes
	c = s.set_area("nave")
	var stale: int = c[0]["slot"]
	var c2 := s.set_area("chapterhouse")
	ok(_ops(c2) == "dispose,start:chapterhouse" and c2[0]["slot"] == stale, "a newer start disposes the pending one")
	var st := s.started(stale)
	ok(_ops(st) == "dispose" and s.current_cue == "pyre", "stale started() is disposed, current unchanged")
	s.started(c2[1]["slot"])
	ok(s.current_cue == "chapterhouse", "latest start wins")
	# back to the cue already playing while another is pending: pending is dropped, current kept
	c = s.set_area("graves")
	var pend: int = c[0]["slot"]
	var back := s.set_area("alchemist_wing")  # same cue as chapterhouse (current)
	ok(_ops(back) == "dispose" and back[0]["slot"] == pend and s.current_cue == "chapterhouse" and s.pending_slot == 0, "returning to the playing cue cancels the pending one")
	# volume 0 stops, volume back restarts
	c = s.set_volume(0.0)
	ok(_ops(c) == "retire" and s.current_cue == "", "volume 0 retires the music")
	c = s.set_volume(0.5)
	ok(_ops(c) == "start:chapterhouse", "volume back on restarts the area theme")
	s.started(c[0]["slot"])
	c = s.set_area("")
	ok(_ops(c) == "retire" and s.desired == "", "leaving the world retires the music")
	# volume 0 -> area set produces no music
	var q := MusicState.new()
	ok(_ops(q.set_area("graves")) == "", "no music while volume is 0")
	# failure paths
	var f := MusicState.new()
	f.set_volume(1.0)
	c = f.set_area("ossuary")
	var fr := f.start_failed(c[0]["slot"], "boom")
	ok(_ops(fr) == "dispose" and f.desired == "" and f.last_error == "boom", "a failed first start gives up (desired cleared)")
	c = f.set_area("pyre")
	f.started(c[0]["slot"])
	var cur: int = f.current_slot
	f.set_volume(1.0)
	c = f.handover_check(cur, 2.0)
	ok(_ops(c) == "start:pyre", "handover begins")
	fr = f.start_failed(c[0]["slot"], "no file")
	ok(_ops(fr) == "dispose,loop" and fr[1]["slot"] == cur and f.desired == "pyre", "a failed hand-over keeps the playing copy and loops it")
	ok(_ops(MusicState.new().set_area("depths")) == "", "fresh state, zero volume: depths silent")
	for a in ["depths", "warren", "sanctum", "nave", "ossuary"]:
		ok(MusicState.cue_for(a) == "ossuary", "%s uses the ossuary theme" % a)
	ok(MusicState.cue_for("acre") == "chapterhouse" and MusicState.cue_for("nope") == "", "acre quiet theme / unknown area")


func _test_music_handover() -> void:
	var s := MusicState.new()
	s.set_volume(0.85)
	var c := s.set_area("graves")
	s.started(c[0]["slot"])
	var cur := s.current_slot
	near(MusicState.HANDOVER_LEFT, 3.25, 1e-12, "handover window is FADE_SECONDS + 0.25")
	ok(_ops(s.handover_check(cur, 60.0)) == "", "no handover with a minute left")
	ok(_ops(s.handover_check(cur, 3.2501)) == "", "no handover just outside the window")
	ok(_ops(s.handover_check(cur, INF)) == "" and _ops(s.handover_check(cur, NAN)) == "", "no handover for unknown length")
	c = s.handover_check(cur, 3.25)
	ok(_ops(c) == "start:graves" and s.pending_cue == "graves", "handover at exactly 3.25 s left starts a fresh copy")
	ok(_ops(s.handover_check(cur, 1.0)) == "", "no second handover while one is pending")
	var nxt: int = c[0]["slot"]
	var r := s.started(nxt)
	ok(_ops(r) == "retire" and r[0]["slot"] == cur and s.current_slot == nxt, "the old copy fades out when the new one plays")
	ok(_ops(s.handover_check(cur, 0.5)) == "", "the retired copy never hands over again")
	ok(_ops(s.handover_check(nxt, 100.0)) == "", "the new copy has plenty left")
	# handover only while the cue is still wanted
	s.set_boss(true)
	var bs := s.pending_slot
	ok(_ops(s.handover_check(nxt, 1.0)) == "", "no handover while a different cue is pending")
	s.started(bs)
	ok(_ops(s.handover_check(nxt, 1.0)) == "", "an already-retired slot is ignored")
	# a loop of N seconds: simulate playback and count hand-overs (one per cycle, spaced length - 3.25 s apart)
	var m := MusicState.new()
	m.set_volume(1.0)
	var cc := m.set_area("pyre")
	m.started(cc[0]["slot"])
	var length := 30.0
	var pos := 0.0
	var t := 0.0
	var starts: Array[float] = []
	var cur2 := m.current_slot
	while t < 100.0:
		t += 0.05
		pos += 0.05
		var cmds := m.handover_check(cur2, length - pos)
		if not cmds.is_empty():
			starts.append(t)
			var ns: int = cmds[0]["slot"]
			m.started(ns)  # starts immediately in Godot
			cur2 = ns
			pos = 0.0
	ok(starts.size() == 3, "100 s of a 30 s loop hands over 3 times (%d)" % starts.size())
	if starts.size() >= 2:
		near(starts[1] - starts[0], length - 3.25, 0.06, "hand-over spacing is length - 3.25 s")


# --- seeded sample selection ---------------------------------------------------------------------

func _test_sample_selection() -> void:
	var bank := Samples.new()
	bank.load_pack_now("core")
	bank.load_pack_now("rites")
	var rng := DmRng.new(424242)
	var seq_a: Array[String] = []
	for i in 40:
		var h := bank.pick("needleCast", rng.next())
		seq_a.append(h["clip"])
	var bank2 := Samples.new()
	bank2.load_pack_now("core")
	bank2.load_pack_now("rites")
	var rng2 := DmRng.new(424242)
	var seq_b: Array[String] = []
	for i in 40:
		seq_b.append(bank2.pick("needleCast", rng2.next())["clip"])
	ok(seq_a == seq_b, "same seed -> same clip sequence")
	var files: Array = AMap.defn("needleCast")["files"]
	var repeats := 0
	var seen := {}
	for i in seq_a.size():
		seen[seq_a[i]] = true
		if i > 0 and seq_a[i] == seq_a[i - 1]:
			repeats += 1
	ok(repeats == 0, "never the same variant twice in a row (%d repeats)" % repeats)
	ok(seen.size() == files.size(), "every variant is reached (%d of %d)" % [seen.size(), files.size()])
	# a missing variant is skipped
	ok(bank.pick("distantBell", 0.5).is_empty(), "'keep' ids have no pack clip")
	ok(bank.pick("nonexistent", 0.5).is_empty(), "unknown id has no clip")
	bank.load_legacy_now()
	var l := bank.pick_legacy("distantBell", 0.0)
	ok(not l.is_empty() and (l["spec"] as Dictionary)["gain"] == 0.5, "legacy bell is picked")
	var seen_l := {}
	var rl := DmRng.new(99)
	var prev := ""
	var rep_l := 0
	for i in 60:
		var pl := bank.pick_legacy("distantBell", rl.next())
		var key := str((pl["stream"] as AudioStream).resource_path)
		seen_l[key] = true
		if key == prev:
			rep_l += 1
		prev = key
	ok(seen_l.size() == 3 and rep_l == 0, "legacy bells: 3 variants, no immediate repeat (%d, %d)" % [seen_l.size(), rep_l])
	# layers
	var layered := ""
	for id in AMap.all():
		if AMap.defn(id).has("layer"):
			layered = id
			break
	ok(layered != "", "map has layered ids")
	# pack release keeps clips another pack owns
	var b3 := Samples.new()
	b3.load_pack_now("core")
	b3.load_pack_now("rites")
	var shared: Array[String] = []
	for c in Packs.pack_clips("core"):
		if Packs.pack_clips("rites").has(c):
			shared.append(c)
	b3.release_pack("core")
	var kept := true
	for c in shared:
		kept = kept and b3.has(c)
	ok(kept, "release_pack keeps clips another loaded pack owns (%d shared)" % shared.size())
	b3.release_pack("rites")
	ok(b3.loaded() == 0 and b3.loaded_packs().is_empty(), "releasing every pack empties the bank")


func _test_resolve_assets() -> void:
	var clips := AMap.all_clip_names()
	ok(clips.size() > 250, "map references %d clips" % clips.size())
	var missing: PackedStringArray = []
	for c in clips:
		var path := Samples.clip_path(c)
		if not FileAccess.file_exists(path) or not FileAccess.file_exists(path + ".import") or not ResourceLoader.exists(path):
			missing.append(c)
			continue
		var s := load(path) as AudioStream
		if s == null or s.get_length() <= 0.0:
			missing.append(c + " (won't load)")
	ok(missing.is_empty(), "every referenced clip resolves to an imported file; missing: %s" % ", ".join(missing))
	# every id's clips resolve (ids with no clips must be 'keep')
	var empty_ids: PackedStringArray = []
	for id in AMap.all():
		if Packs.clips_of(id).is_empty():
			empty_ids.append(id)
			ok(Packs.is_keep(id), "%s has no clips but is not 'keep'" % id)
	ok(empty_ids.size() == 3, "only the 3 keep ids lack clips: %s" % ",".join(empty_ids))
	for stem in Samples.legacy_names():
		var p := Samples.legacy_path(stem)
		ok(FileAccess.file_exists(p) and FileAccess.file_exists(p + ".import") and load(p) is AudioStream, "legacy/bed clip %s resolves" % stem)
	for cue in MusicState.CUES:
		var p := Samples.MUSIC_DIR + cue + ".mp3"
		ok(FileAccess.file_exists(p + ".import") and load(p) is AudioStream, "music cue %s resolves" % cue)
	for a in MusicState.MUSIC_FOR_AREA:
		ok(MusicState.CUES.has(MusicState.MUSIC_FOR_AREA[a]), "area %s music cue exists" % a)
	for a in Amb.ZONE_BEDS:
		for l in Amb.ZONE_BEDS[a]["loops"]:
			ok(Amb.BED_FILES.has(l["file"]), "bed file %s is a known bed" % l["file"])
	# every Sfx id the ambience accents name is defined in the map or LEGACY
	for a in Amb.ZONE_ACCENTS:
		for e in Amb.ZONE_ACCENTS[a]["sounds"]:
			ok(AMap.has_def(e[0]) or Samples.LEGACY.has(e[0]), "accent %s resolvable" % e[0])
	# beds loop, are Vorbis
	for b in Amb.BED_FILES:
		ok(load(Samples.legacy_path(b)) is AudioStreamOggVorbis, "%s is Ogg Vorbis" % b)
		var imp := FileAccess.get_file_as_string(Samples.legacy_path(b) + ".import")
		ok(imp.contains("loop=true"), "%s imports with loop=true" % b)
	# step ids for every surface exist in the map
	for s in ["stone", "dirt", "grass", "water"]:
		ok(AMap.has_def(AMap.step_sound(s)), "step sound %s defined" % s)
	for a in DmContent.area_order():
		ok(AMap.area_surface(a) != "" and Amb.ZONE_BEDS.has(a) and MusicState.MUSIC_FOR_AREA.has(a), "area %s has bed + music + surface" % a)


func _test_synth() -> void:
	var d := Synth.drone(41.2)
	var w: AudioStreamWAV = d["stream"]
	ok(w.loop_mode == AudioStreamWAV.LOOP_FORWARD and absf(w.get_length() - 10.0) < 0.01, "drone loops for 10 s")
	var n := w.data.size() / 2
	var max_step := 0
	for i in range(1, n):
		max_step = maxi(max_step, absi(w.data.decode_s16(i * 2) - w.data.decode_s16((i - 1) * 2)))
	var seam := absi(w.data.decode_s16(0) - w.data.decode_s16((n - 1) * 2))
	ok(seam <= max_step * 2 + 4, "drone loop seam is continuous (seam %d, max step %d)" % [seam, max_step])
	ok(float(d["peak"]) > 0.05 and float(d["peak"]) < 2.0, "drone peak %f" % float(d["peak"]))
	var drum := Synth.boss_drum()
	near(drum.get_length(), 1.6, 0.01, "boss drum cycle is 1.6 s")
	ok(drum.loop_mode == AudioStreamWAV.LOOP_FORWARD, "drum loops")
	var nd := drum.data.size() / 2
	var peak := 0
	for i in nd:
		peak = maxi(peak, absi(drum.data.decode_s16(i * 2)))
	ok(peak > 8000 and peak < 32767, "drum audible and unclipped (%d)" % peak)
	ok(Synth.drone(41.2) == d, "drones are cached")


# --- AudioDirector integration (dummy audio driver) ------------------------------------------------

func _db(bus: String) -> float:
	return AudioServer.get_bus_volume_db(AudioServer.get_bus_index(bus))


func _test_director() -> void:
	var d := Director.new()
	root.add_child(d)
	d.setup()
	d.time_override = 100.0
	d.seed_rng(7)
	d.bank.pump(1 << 20)
	ok(d.bank.failed == 0 and d.bank.pending() == 0, "all queued clips loaded, none failed (%d)" % d.bank.failed)
	for b in ["Combat", "Enemies", "Thralls", "Ui", "Ambience", "Music"]:
		ok(AudioServer.get_bus_index(b) >= 0, "bus %s exists" % b)
	# settings -> bus volumes
	d.apply_settings({"vol_master": 0.5, "vol_combat": 0.8, "vol_amb": 0.6, "vol_music": 0.5, "vol_ui": 0.8})
	near(_db("Master"), linear_to_db(pow(0.5, 1.5) * 0.9), 1e-4, "master db")
	near(_db("Combat"), linear_to_db(pow(0.8, 1.5)), 1e-4, "combat db")
	near(_db("Enemies"), linear_to_db(pow(0.8, 1.5) * 0.8), 1e-4, "enemies db (trim 0.8)")
	near(_db("Thralls"), linear_to_db(pow(0.8, 1.5) * 0.5), 1e-4, "thralls db (trim 0.5)")
	near(_db("Ui"), linear_to_db(pow(0.8, 1.5) * 0.9), 1e-4, "ui db")
	near(_db("Ambience"), linear_to_db(pow(0.6, 1.5)), 1e-4, "ambience db")
	d.apply_settings({"volume": 0.6, "combatVolume": 1.0, "ambienceVolume": 1.0, "musicVolume": 0.85, "interfaceVolume": 1.0})
	near(_db("Master"), linear_to_db(pow(0.6, 1.5) * 0.9), 1e-4, "web-key master db")
	# play, gap, cull
	ok(d.play_sfx("needleCast", Vector2(2, 3)), "needleCast plays")
	ok(not d.play_sfx("needleCast", Vector2(2, 3)), "cooldown blocks the second start")
	ok(d.stats()["dropped_by_reason"]["gap"] == 1, "gap drop counted")
	d.time_override = 100.06
	ok(d.play_sfx("needleCast", Vector2(2, 3)), "plays again after the cooldown")
	ok(not d.play_sfx("thrallMelee", Vector2(500, 0)), "a far thrall is culled")
	ok(d.stats()["dropped_by_reason"]["far"] == 1, "far drop counted")
	d.partner = true
	d.time_override = 101.0
	ok(not d.play_sfx("needleCast", Vector2(60, 0)), "a partner's far spell is inaudible (radius 22)")
	ok(d.play_sfx("needleCast", Vector2(5, 0)), "a nearby partner spell plays")
	d.partner = false
	# thinning: 3 thrall sounds per 100 ms
	d.time_override = 105.0
	d.set_listener(0.0, 0.0)
	var admitted := 0
	for id in ["thrallMelee", "thrallShot", "thrallMagic", "thrallDeath", "thrallBind"]:
		if d.play_sfx(id, Vector2(2, 2)):
			admitted += 1
	ok(admitted == 3 and d.stats()["dropped_by_reason"]["thin"] == 2, "thrall thinning admits 3 per 100 ms (%d)" % admitted)
	# ducks: hurt pulls thralls/enemies down, then releases
	d.time_override = 110.0
	var base_thralls := _db("Thralls")
	ok(d.play_sfx("hurt"), "hurt plays")
	d.advance(0.0)
	ok(d.stats()["ducks"] >= 1, "hurt ducks")
	d.advance(0.3)
	ok(_db("Thralls") < base_thralls - 2.0, "thralls ducked while hurt rings (%f vs %f)" % [_db("Thralls"), base_thralls])
	ok(_db("Enemies") < linear_to_db(0.8) - 2.0, "enemies ducked")
	for i in 40:
		d.time_override += 0.1
		d.advance(0.1)
	near(_db("Thralls"), base_thralls, 0.2, "thralls back after release")
	ok(d.stats()["nodes"] == 0, "voices are recycled after their clips end (%d)" % d.stats()["nodes"])
	# loot + gather + footsteps go through the same pipeline
	d.time_override = 130.0
	d.play_loot(["common", "epic"])
	d.gather("mining", "seam", Vector2(1, 1))
	d.bank.load_pack_now("foot_dirt")
	d.bank.load_pack_now("foot_stone")
	var before: int = d.stats()["sample_plays"]
	d.hero_footfall(0.0, 0.0, 0.0, "graves")
	d.hero_footfall(0.06, 0.0, 0.0, "graves")  # crosses 0.04
	ok(d.stats()["sample_plays"] == before + 1, "a footfall plays one step clip")
	d.hero_stopped()
	# per-id cap
	d.time_override = 140.0
	var steps_ok := 0
	for i in 6:
		d.time_override += 0.3
		if d.play_sfx("stepStone", Vector2(1, 1)):
			steps_ok += 1
	ok(steps_ok >= 4, "footsteps keep playing at walking pace (%d)" % steps_ok)
	# rite loop: re-triggers every loopMs, stops at the end
	d.time_override = 150.0
	var h := d.loop_sfx("miasmaLoop", 3000.0, Vector2(1, 1))
	var loop_ms: float = float(AMap.defn("miasmaLoop")["loopMs"])
	var p0: int = d.stats()["played"]
	for i in 12:
		d.time_override += loop_ms / 1000.0 / 4.0
		d.advance(loop_ms / 1000.0 / 4.0)
	ok(d.stats()["played"] > p0, "the loop retriggered")
	d.stop_loop(h)
	var p1: int = d.stats()["played"]
	d.time_override += loop_ms / 1000.0 * 2.0
	d.advance(0.1)
	ok(d.stats()["played"] == p1, "stop_loop stops it")
	# areas, music, boss
	d.time_override = 200.0
	d.set_area("graves")
	for i in 5:
		d.advance(0.1)
	var st: Dictionary = d.stats()
	ok(st["area"] == "graves" and st["bed_kind"] == "loops" and d.music_cue() == "graves", "graves: loop bed + graves theme")
	ok(d.bank.has_pack("foot_dirt") and d.bank.has_pack("fam_humanoid") and d.bank.has_pack("boss"), "graves packs queued")
	d.set_boss_music(true)
	ok(d.music_cue() == "boss", "boss score")
	d.set_boss_music(false)
	ok(d.music_cue() == "graves", "boss score ends")
	d.set_area("pyre")
	ok(d.music_cue() == "pyre" and d.current_area() == "pyre", "pyre theme")
	d.set_area("chapterhouse")
	ok(d.music_cue() == "chapterhouse", "chapterhouse theme")
	for i in 40:
		d.advance(0.1)
	ok(d.bank.has_pack("foot_stone"), "chapterhouse floor loaded")
	# boss drum under bossAwaken
	d.time_override = 300.0
	d.play_sfx("bossAwaken")
	ok(d.boss_bed_active(), "bossAwaken starts the war drum")
	d.time_override = 310.0
	d.play_sfx("bossDefeat")
	ok(not d.boss_bed_active(), "bossDefeat ends it")
	# combat override ducks the bed
	d.set_combat(true)
	for i in 30:
		d.advance(0.1)
	ok(d.combat_level() >= 1.0 and d.stats()["bed_duck"] < 0.55, "set_combat ducks the zone bed (%f)" % d.stats()["bed_duck"])
	d.set_combat(false)
	# stop
	d.stop_area()
	ok(d.current_area() == "" and d.music_cue() == "", "stop_area ends bed and music")
	d.free()
	await process_frame


func _test_music_director() -> void:
	var m := MusicDir.new()
	root.add_child(m)
	# bus must exist for volume writes; create like the director does
	if AudioServer.get_bus_index("Music") < 0:
		AudioServer.add_bus()
		AudioServer.set_bus_name(AudioServer.bus_count - 1, "Music")
	m.set_volume_slider(0.85)
	m.set_area("ossuary")
	ok(m.current_cue() == "ossuary", "ossuary theme plays")
	var first := m.state.current_slot
	var pl: AudioStreamPlayer = m._slots[first]["player"]
	var length := pl.stream.get_length()
	ok(length > 60.0, "theme is a real file (%f s)" % length)
	m.advance(0.1)
	ok(m.state.current_slot == first, "no hand-over early in the track")
	pl.seek(length - 3.0)
	m.advance(0.05)
	ok(m.state.current_slot != first and m.state.current_cue == "ossuary", "hand-over to a fresh copy ~3 s before the end")
	var second := m.state.current_slot
	ok(m._slots.has(first) and float(m._slots[first]["target"]) == 0.0, "the old copy is fading out")
	for i in 40:
		m.advance(0.1)
	ok(not m._slots.has(first) and m._slots.has(second), "the old copy is gone after the fade")
	var g := float(m._slots[second]["gain"])
	ok(g > 0.6 and g <= 1.0, "new copy faded in (%f)" % g)
	m.set_volume_slider(0.0)
	ok(m.current_cue() == "", "volume 0 stops the music")
	for i in 50:
		m.advance(0.1)
	ok(m._slots.is_empty(), "everything disposed")
	m.free()
	await process_frame
