extends RefCounted
## Boss event visuals (WorldScene.ts onBossEvent 4970-5134 + areaBossEvent 4676-4969): awaken / phase banners, telegraphs and
## impacts of all seven bosses, toasts, the Saint's one-time lessons. Rewards go through DmEventFx.hooks["on_boss_defeated"].
## Owned by DmEventFx (`fx`). Always called inside Vfx.danger().

## Boss impacts that stop the picture for a few frames (many-orb rains and telegraphs do not).
const BOSS_STOP := {"slam": 1.0, "maul": 1.0, "sweep": 0.8, "toll": 0.8, "cleave": 1.0, "conflagration": 1.0, "surface": 1.0, "bury": 0.7,
	"lance": 0.6, "hands": 0.7, "swing": 0.8, "defeated": 1.0}
const AREA_KINDS := ["sweep", "maul", "grasp", "hymn", "bury", "pits", "lance", "chorus", "communion", "nicheBreak", "rotRain", "swing", "blessed",
	"link", "coals", "cleave", "conflagration", "surface", "hands", "rite", "flood"]

var fx: DmEventFx
var pit_fx: Array = []
var saint_rain_told := false
var saint_link_told := false
var saint_bless_told := false
var saint_feed_at := 0.0

var _grave: Dictionary
var _cong: Dictionary
var _saint: Dictionary
var _regent: Dictionary


func _init(p_fx: DmEventFx) -> void:
	fx = p_fx
	_grave = DmContent.get_export("bosses", "GRAVEDIGGER")
	_cong = DmContent.get_export("bosses", "CONGREGATION")
	_saint = DmContent.get_export("bosses", "SAINT")
	_regent = DmContent.get_export("bosses", "REGENT")


func clear() -> void:
	for h in pit_fx:
		h.kill()
	pit_fx.clear()


func _dec(tex: String, color: Variant, x: float, z: float, r: float, duration: float, opacity: float, extra: Dictionary = {}) -> Variant:
	var o := {"tex": tex, "color": color, "x": x, "z": z, "r": r, "duration": duration, "opacity": opacity}
	o.merge(extra, true)
	return fx.decal(o)


## Boss cones and lines are the shape you must leave: a brightened fill plus a bright outline, so they read on every floor.
static func hot(color: int) -> int:
	var rr := (color >> 16) & 255
	var gg := (color >> 8) & 255
	var bb := color & 255
	var m := maxi(maxi(rr, gg), maxi(bb, 1))
	var k := minf(2.2, 214.0 / float(m))
	var ch := func(v: int) -> int: return mini(255, DmMath.js_round(float(v) * k))
	return (ch.call(rr) << 16) | (ch.call(gg) << 8) | ch.call(bb)


func _cone(ev: Dictionary, r: float, dir: float, half_deg: float, color: int, dur: float, delay: float = 0.0) -> void:
	# The melee cones strike 0.3m past their nominal reach (BossBrain), so the picture draws that too.
	var o := {"x": fx.f(ev, "x"), "z": fx.f(ev, "z"), "r": (r + 0.3) / 2.0, "sz": 1, "sx": tan(deg_to_rad(half_deg)) / tan(PI / 6.0), "anchor": 1, "rot": dir + PI,
		"duration": dur, "fadeOut": 0.05, "delay": delay, "color": hot(color)}
	var a := o.duplicate()
	a.merge({"tex": "cone", "opacity": 0.55, "fadeIn": dur * 0.6})
	fx.decal(a)
	var b := o.duplicate()
	b.merge({"tex": "coneEdge", "opacity": 0.95, "fadeIn": dur * 0.15})
	fx.decal(b)


func _line(x: float, z: float, length: float, dir: float, half_width: float, color: int, dur: float) -> void:
	fx.decal({"x": x, "z": z, "r": length / 2.0, "sz": 1, "sx": (half_width * 2.0) / length, "anchor": 1, "rot": dir + PI, "duration": dur, "fadeOut": 0.05,
		"color": hot(color), "tex": "bar", "opacity": 0.8, "fadeIn": dur * 0.3})


func _targets(ev: Dictionary, dflt: Array) -> Array:
	var t: Variant = ev.get("targets")
	return dflt if t == null else t


func _spike_line(x: float, z: float, dir: float, length: float, width: float) -> void:
	fx.vfx.spike_line(x, z, sin(dir), cos(dir), length, width)


func area_boss_event(ev: Dictionary, ms: float) -> void:
	var boss_id := String(ev["boss"]) if ev.get("boss") != null else "prelate"
	var def: Dictionary = fx.boss_def(boss_id)
	var kind := String(ev["kind"])
	var ex := fx.f(ev, "x")
	var ez := fx.f(ev, "z")
	# The danger channel: the element's tell sounds once at the START of a telegraph, while it can still be dodged.
	if ms > 0.0 and ev.get("boss") != null and boss_id != "prelate":
		var tell := DmAudioMap.boss_tell(boss_id)
		fx.snd(tell if tell != "" else "bossTell", ex, ez)
	var dirt: int = fx.sp("enemy", "dirt")
	var curse: int = fx.sp("enemy", "curse")
	var tide := 0x5f8f8a
	var dir := fx.f(ev, "dir")
	var players: Variant = ev.get("players")
	var mine: bool = players is Array and (players as Array).has(fx.me())
	if (kind == "bury" or kind == "hands" or (kind == "grasp" and boss_id == "congregation")) and ms == 0.0 and mine and fx.f(ev, "root") != 0.0:
		# Buried / grasped: root yourself (players are client-simulated); casting stays allowed.
		fx.game.p["rootedUntil"] = maxf(float(fx.game.p.get("rootedUntil", 0.0)), fx.now() + fx.f(ev, "root") * 1000.0)
		fx.float_text(fx.px(), 2.4, fx.pz(), "Buried!" if kind == "bury" else "Grasped!", "info")
	match kind:
		"sweep", "maul":
			if ms > 0.0:
				_cone(ev, fx.f(ev, "r", 4.0), dir, float(_grave["sweep"]["halfDeg"]) if kind == "sweep" else float(_cong["melee"]["halfDeg"]), dirt if boss_id == "gravedigger" else tide, ms)
			else:
				fx.emit({"x": ex + sin(dir) * 2.0, "y": 0.4, "z": ez + cos(dir) * 2.0, "count": 20, "color": dirt if boss_id == "gravedigger" else tide, "spread": 1.2, "speed": 3, "up": 1.5, "life": 0.6, "size": 0.2, "gravity": 9})
				fx.snd("bossSlam", ex, ez)
				fx.shake(0.2)
		"bury":
			for t in _targets(ev, [[ex, ez]]):
				var x := float(t[0])
				var z := float(t[1])
				if ms > 0.0:
					var b: Dictionary = _grave["burial"]
					_dec("graveOutline", 0xe0a458, x, z, float(b["hd"]), ms, 0.9, {"sx": float(b["hw"]) / float(b["hd"]), "fadeIn": ms * 0.5, "fadeOut": 0.05})
				else:
					fx.emit({"x": x, "y": 0.3, "z": z, "count": 18, "color": dirt, "spread": 0.8, "speed": 1.8, "up": 2, "life": 0.6, "size": 0.2, "gravity": 9})
					_dec("cracks", dirt, x, z, 1.4, 1.2, 0.8, {"rot": randf() * 6.0, "fadeOut": 0.4})
			if ms == 0.0:
				fx.snd("boneHit", ex, ez)
		"pits":
			var pr := fx.f(ev, "r", 1.2)
			for t in _targets(ev, []):
				var x := float(t[0])
				var z := float(t[1])
				pit_fx.append(_dec("disc", 0x120c08, x, z, pr, 1e9, 0.95, {"growFrom": 0.2}))
				pit_fx.append(_dec("graveOutline", 0xe0a458, x, z, pr * 1.3, 1e9, 0.7, {"sx": 0.55, "pulse": 1.5}))
			fx.toast("Every grave is open: stay out of the pits.", "err")
		"lance":
			if ms > 0.0:
				_line(ex, ez, fx.f(ev, "r", 11.0), dir, 0.8, curse, ms)
			else:
				_spike_line(ex, ez, dir, fx.f(ev, "r", 11.0), 1.0)
				fx.snd("boneHit", ex, ez)
		"chorus":
			for i in 8:
				var d := dir + float(i) * PI / 4.0
				if ms > 0.0:
					_line(ex, ez, fx.f(ev, "r", 9.0), d, 0.7, fx.sp("boss", "shard"), ms)
				else:
					_spike_line(ex, ez, d, fx.f(ev, "r", 9.0), 0.9)
			if ms == 0.0:
				fx.snd("bossSlam", ex, ez)
				fx.shake(0.25)
		"grasp":
			if boss_id == "abbess":
				if ms > 0.0:
					_cone(ev, fx.f(ev, "r", 3.5), dir, 55.0, fx.sp("boss", "shard"), ms)
			else:
				var gr := fx.f(ev, "r", 1.4)
				for t in _targets(ev, []):
					var x := float(t[0])
					var z := float(t[1])
					if ms > 0.0:
						_dec("disc", tide, x, z, gr + 0.2, ms, 0.5, {"fadeIn": ms * 0.7, "fadeOut": 0.05, "growFrom": 0.3})
						_dec("drownedHand", 0x8fb4c8, x, z, gr * 0.9, ms, 0.8, {"growFrom": 0.2, "fadeOut": 0.05})
					else:
						fx.emit({"x": x, "y": 0.3, "z": z, "count": 16, "color": 0x8fb4c8, "spread": 0.6, "speed": 1.2, "up": 2.4, "life": 0.7, "size": 0.22})
		"hymn":
			if ms > 0.0:
				var hr := fx.f(ev, "r", 15.0)
				_cone(ev, hr, dir, float(_cong["hymn"]["halfDeg"]), tide, ms)
				# Tide crests march outward across the arc: find a pew before they reach you.
				for k in range(1, 6):
					var rr := hr * float(k) / 5.5
					for off in [-0.6, 0.0, 0.6]:
						var d: float = dir + off
						_dec("tideCrest", 0x8fb4c8, ex + sin(d) * rr, ez + cos(d) * rr, 1.1, 0.6, 0.85, {"rot": d + PI, "fadeOut": 0.3, "delay": (ms / 1000.0) * (float(k) / 6.0)})
				fx.toast("Flood Hymn: put a pew between you and her!", "err")
			else:
				for k in 6:
					var d := dir + (float(k) - 2.5) * 0.35
					fx.emit_smoke({"x": ex + sin(d) * 7.0, "y": 0.4, "z": ez + cos(d) * 7.0, "count": 3, "color": 0x2a3a40, "spread": 1.5, "speed": 2.5, "up": 0.8, "life": 0.9, "size": 1.4})
				fx.snd("bossSlam", ex, ez)
				fx.shake(0.3)
		"communion":
			if ms > 0.0:
				for t in _targets(ev, []):
					fx.beam(Vector3(float(t[0]), 0.3, float(t[1])), Vector3(ex, 1.5, ez), curse, 0.05, ms)
				_dec("sigil", curse, ex, ez, 2.4, ms, 0.8, {"spin": 1.5})
				fx.toast("Bone Communion: spend the corpses before they reach her!", "err")
			elif fx.f(ev, "r") > 0.0:
				fx.float_text(ex, 3.0, ez, "+%d corpses devoured" % DmMath.js_round(fx.f(ev, "r")), "info")
		"rotRain":
			if ms > 0.0 and not saint_rain_told:
				saint_rain_told = true
				fx.toast("Rot Rain: leave the circles! The pools they leave behind heal her.", "err")
			for t in _targets(ev, []):
				var x := float(t[0])
				var z := float(t[1])
				if ms > 0.0:
					_dec("disc", fx.sp("enemy", "toxic"), x, z, fx.f(ev, "r", 2.0) + DmSimConsts.BOSS_RING_PAD, ms, 0.55, {"fadeIn": ms * 0.7, "fadeOut": 0.05, "growFrom": 0.2})
				else:
					fx.emit_smoke({"x": x, "y": 0.3, "z": z, "count": 3, "color": 0x4a5a22, "spread": 1, "speed": 1.2, "up": 1, "life": 1, "size": 1.1})
			if ms > 0.0:
				fx.toast("Rot Rain: step out of the green, then keep her out of it.", "err")
			else:
				fx.snd("boneHit", ex, ez)
		"swing":
			if ms > 0.0:
				_cone(ev, fx.f(ev, "r", 4.5), dir, float(_saint["swing"]["halfDeg"]), fx.sp("enemy", "rot"), ms)
			else:
				fx.emit_smoke({"x": ex + sin(dir) * 2.0, "y": 0.8, "z": ez + cos(dir) * 2.0, "count": 4, "color": 0x5a6a2a, "spread": 1.4, "speed": 2, "up": 0.6, "life": 0.8, "size": 1})
				fx.snd("bossSlam", ex, ez)
				fx.shake(0.2)
		"link":
			# Plague Doctors feeding her: a green tether from each, so "kill the doctors" is visible.
			var tg := _targets(ev, [])
			for t in tg:
				var x := float(t[0])
				var z := float(t[1])
				fx.beam(Vector3(x, 1.6, z), Vector3(ex, 2.2, ez), 0x9cc43a, 0.07, 900.0)
				fx.emit({"x": x, "y": 1.4, "z": z, "count": 4, "color": 0x9cc43a, "spread": 0.3, "speed": 0.5, "up": 1.4, "life": 0.7, "size": 0.18})
			if tg.size() > 0 and not saint_link_told:
				saint_link_told = true
				fx.toast("The Plague Doctors are feeding her: cut them down first!", "err")
		"blessed":
			fx.emit({"x": ex, "y": 0.4, "z": ez, "count": 10, "color": 0x9cc43a, "spread": 0.8, "speed": 0.6, "up": 2.2, "life": 0.9, "size": 0.2})
			# A pulse ring under her every beat she feeds, so "she is healing right now" reads at a glance.
			_dec("ring", 0x9cc43a, ex, ez, 3.2, 0.7, 0.85, {"growFrom": 0.4, "fadeOut": 0.4})
			var tick := float(Time.get_ticks_msec())
			if tick - saint_feed_at > 3500.0:
				saint_feed_at = tick
				fx.float_text(ex, 3.5, ez, "She feeds on the rot!", "info")
				if not saint_bless_told:
					saint_bless_told = true
					fx.toast("She heals while standing in rot pools: lure her onto clean ground!", "err")
		"coals":
			var ember: int = fx.sp("enemy", "ember")
			var core: int = fx.sp("enemy", "emberCore")
			var deep: int = fx.sp("enemy", "emberDeep")
			var cr := fx.f(ev, "r", 1.8)
			for t in _targets(ev, []):
				var x := float(t[0])
				var z := float(t[1])
				if ms > 0.0:
					_dec("disc", ember, x, z, cr + DmSimConsts.BOSS_RING_PAD, ms, 0.55, {"fadeIn": ms * 0.7, "fadeOut": 0.05, "growFrom": 0.2})
					_dec("ring", core, x, z, cr + DmSimConsts.BOSS_RING_PAD, ms, 0.9, {"fadeOut": 0.05})
					fx.vfx.projectile({"from": Vector3(ex, 3.4, ez), "to": func() -> Variant: return Vector3(x, 0.3, z), "kind": "orb", "color": ember,
						"speed": maxf(5.0, sqrt((x - ex) * (x - ex) + (z - ez) * (z - ez)) / maxf(0.3, ms)), "arc": 45.0})
				else:
					fx.bb("vengeful_burst", x, z, {"scale": cr / 1.4, "colors": [ember, core, deep]})
					fx.emit({"x": x, "y": 0.4, "z": z, "count": 14, "color": core, "spread": 0.7, "speed": 3, "up": 2.6, "life": 0.7, "size": 0.13, "gravity": 8})
			if ms > 0.0:
				fx.snd("emberThrow", ex, ez)
			else:
				fx.snd("emberBurst", ex, ez)
		"cleave":
			if ms > 0.0:
				_cone(ev, fx.f(ev, "r", 5.2), dir, float(_regent["cleave"]["halfDeg"]), fx.sp("enemy", "ember"), ms)
			else:
				var core := fx.sp("enemy", "emberCore")
				for d in _regent["cleave"]["trail"]:
					var x := ex + sin(dir) * float(d)
					var z := ez + cos(dir) * float(d)
					fx.emit({"x": x, "y": 0.5, "z": z, "count": 12, "color": core, "spread": 0.5, "speed": 3.4, "up": 2.4, "life": 0.6, "size": 0.12, "gravity": 8})
				fx.emit_smoke({"x": ex + sin(dir) * 2.5, "y": 0.8, "z": ez + cos(dir) * 2.5, "count": 4, "color": fx.sp("enemy", "emberDeep"), "spread": 1.4, "speed": 2, "up": 0.6, "life": 0.8, "size": 1})
				fx.snd("slagSlam", ex, ez)
				fx.shake(0.25)
		"conflagration":
			_conflagration(ev, ms, ex, ez)
		"surface":
			_surface(ev, ms, ex, ez)
		"hands":
			var T := 0x7fb4a8
			var hr2 := fx.f(ev, "r", 1.5)
			for t in _targets(ev, []):
				var x := float(t[0])
				var z := float(t[1])
				if ms > 0.0:
					_dec("disc", T, x, z, hr2 + 0.2, ms, 0.5, {"fadeIn": ms * 0.7, "fadeOut": 0.05, "growFrom": 0.3})
					_dec("drownedHand", 0x8fb4c8, x, z, hr2 * 0.9, ms, 0.85, {"growFrom": 0.2, "fadeOut": 0.05})
				else:
					fx.emit({"x": x, "y": 0.3, "z": z, "count": 14, "color": T, "spread": 0.6, "speed": 1.2, "up": 2.4, "life": 0.7, "size": 0.22})
					fx.add_ripple(x, z, 1.6)
			if ms > 0.0:
				fx.toast("Drowned hands rise under anyone wading the open water: get onto dry ground!", "err")
		"rite":
			_rite(ev, ms, ex, ez)
		"flood":
			# The arena floods: rings race outward, the hummocks sink to their new size (WorldView eases them).
			var T2 := 0x5fc4b4
			for k in 4:
				_dec("ring", T2, ex, ez, 6.0 + float(k) * 3.0, 1.0, 1.0 - float(k) * 0.2, {"growFrom": 0.1, "delay": float(k) * 0.1})
			for t in _targets(ev, []):
				fx.emit({"x": float(t[0]), "y": 0.3, "z": float(t[1]), "count": 24, "color": 0x7fe0d0, "spread": 0.6, "speed": 0.8, "up": 2.4, "life": 1, "size": 0.25})
			fx.light_flash(ex, 3, ez, T2, 70, 0.9)
			fx.shake(0.5)
		"nicheBreak":
			fx.emit({"x": ex, "y": 1.6, "z": ez, "count": 40, "color": 0xe0d6c2, "spread": 1, "speed": 3.5, "up": 2.5, "life": 0.9, "size": 0.25, "gravity": 8})
			fx.light_flash(ex, 2, ez, fx.sp("boss", "shard"), 40, 0.5)
			fx.snd("nicheBreak", ex, ez)


## The signature: the whole arena reddens over the windup while the ash circles glow pale; when it lands the floor erupts everywhere else.
func _conflagration(ev: Dictionary, ms: float, ex: float, ez: float) -> void:
	var ember: int = fx.sp("enemy", "ember")
	var core: int = fx.sp("enemy", "emberCore")
	var deep: int = fx.sp("enemy", "emberDeep")
	var r := fx.f(ev, "r", 11.0)
	var safe_r := float(_regent["conflagration"]["safeR"])
	if ms > 0.0:
		_dec("disc", ember, ex, ez, r, ms, 0.5, {"fadeIn": ms * 0.9, "fadeOut": 0.05, "growFrom": 0.9})
		_dec("ring", core, ex, ez, r, ms, 0.9, {"pulse": 6, "fadeOut": 0.05})
		for t in _targets(ev, []):
			var x := float(t[0])
			var z := float(t[1])
			_dec("disc", 0xd8d4c8, x, z, safe_r, ms, 0.6, {"fadeOut": 0.05})
			_dec("ring", 0xffffff, x, z, safe_r, ms, 0.95, {"pulse": 3, "fadeOut": 0.05})
			fx.emit({"x": x, "y": 0.3, "z": z, "count": 6, "color": 0xd8d4c8, "spread": safe_r * 0.6, "speed": 0.3, "up": 1.2, "life": ms, "size": 0.16, "drag": 0.5})
		fx.snd("bossAwaken", ex, ez)
		fx.toast("Conflagration! Run to a grey ash circle and stand on it!", "err")
	else:
		for k in 4:
			_dec("ring", core if k % 2 == 1 else ember, ex, ez, r * (0.4 + float(k) * 0.3), 0.7, 1.0 - float(k) * 0.2, {"growFrom": 0.1, "delay": float(k) * 0.08})
		fx.emit({"x": ex, "y": 0.6, "z": ez, "count": 160, "color": core, "spread": r * 0.55, "speed": 5, "up": 4, "life": 1.1, "size": 0.16, "gravity": 6})
		fx.light_flash(ex, 3, ez, ember, 110, 0.9)
		fx.bb("surge_eruption", ex, ez, {"scale": r / 4.0, "colors": [ember, core, deep]})
		fx.snd("slagSlam", ex, ez)
		fx.shake(0.55)


## Mire Mother: ripple rings converge on a hummock for the whole windup; when they meet, she bursts out under it.
func _surface(ev: Dictionary, ms: float, ex: float, ez: float) -> void:
	var T := 0x5fc4b4
	var r := fx.f(ev, "r", 3.7)
	if ms > 0.0:
		_dec("disc", T, ex, ez, r + 0.3, ms, 0.4, {"fadeIn": ms * 0.9, "fadeOut": 0.05, "growFrom": 0.3})
		_dec("ring", 0xc8fff4, ex, ez, r + 0.3, ms, 0.95, {"pulse": 4, "fadeOut": 0.05})
		for k in 3:
			_dec("ring", T, ex, ez, r * 1.8, maxf(0.3, ms / 3.0), 0.8, {"growFrom": 1, "delay": (ms / 3.0) * float(k)})
		for k in 6:
			fx.add_ripple(ex, ez, 1.4)
		fx.toast("The Mire Mother sinks: leave the ringed hummock before she surfaces!", "err")
	else:
		for k in 3:
			_dec("ring", T, ex, ez, r * (0.6 + float(k) * 0.35), 0.6, 1.0 - float(k) * 0.25, {"growFrom": 0.2, "delay": float(k) * 0.08})
		fx.emit({"x": ex, "y": 0.4, "z": ez, "count": 80, "color": 0x9fe8da, "spread": 1.6, "speed": 4.5, "up": 4, "life": 1, "size": 0.3, "gravity": 7})
		fx.emit_smoke({"x": ex, "y": 0.4, "z": ez, "count": 6, "color": 0x1c3a38, "spread": 1.4, "speed": 1.4, "up": 0.9, "life": 1.2, "size": 1.6})
		fx.add_ripple(ex, ez, 3.0)
		fx.light_flash(ex, 2, ez, T, 60, 0.6)
		fx.snd("bossSlam", ex, ez)
		fx.shake(0.4)
		fx.float_text(ex, 3.6, ez, "Winded!", "info")


func _rite(ev: Dictionary, ms: float, ex: float, ez: float) -> void:
	var T := 0x5fc4b4
	var tg := _targets(ev, [])
	if ms > 0.0:
		for t in tg:
			var x := float(t[0])
			var z := float(t[1])
			fx.beam(Vector3(x, 0.3, z), Vector3(ex, 2.2, ez), T, 0.05, ms)
			_dec("sigil", T, x, z, 1.1, ms, 0.85, {"spin": 3, "fadeOut": 0.05})
		_dec("sigil", T, ex, ez, 3, ms, 0.8, {"spin": 1.5, "fadeOut": 0.05})
		fx.toast("The Drowned Rite: she raises every corpse in the Fen. Spend them now!", "err")
	elif tg.size() == 0:
		fx.float_text(ex, 3.6, ez, "The rite finds no dead", "info")
		fx.emit({"x": ex, "y": 1.6, "z": ez, "count": 30, "color": 0x9fb4b0, "spread": 1, "speed": 1.4, "up": 1.2, "life": 0.9, "size": 0.25})
		fx.toast("The rite failed: no corpses left. She reels!", "good")
	else:
		for t in tg:
			var x := float(t[0])
			var z := float(t[1])
			fx.emit({"x": x, "y": 0.3, "z": z, "count": 26, "color": T, "spread": 0.5, "speed": 0.6, "up": 3, "life": 1, "size": 0.3, "gravity": -0.4})
			_dec("ring", T, x, z, 1.6, 0.6, 0.9, {"growFrom": 0.2})
		fx.snd("raise", ex, ez)


# --- onBossEvent -----------------------------------------------------------------------------------------------------------

func on_boss_event(ev: Dictionary) -> void:
	var telegraphs = fx.game.get("telegraphs")
	if telegraphs == null and fx.game.get("input") != null:
		telegraphs = fx.game.input.get("telegraphs")
	if telegraphs != null and telegraphs.has_method("on_event"):
		telegraphs.on_event(ev, fx.now())
	var kind := String(ev["kind"])
	var ex := fx.f(ev, "x")
	var ez := fx.f(ev, "z")
	var ms := fx.f(ev, "ms") / 1000.0
	var stop: float = BOSS_STOP.get(kind, 0.0)
	if stop > 0.0 and (ms == 0.0 or kind == "defeated") and fx.dist_player(ex, ez) < 18.0:
		fx.hitstop(stop)
	var boss_id := String(ev["boss"]) if ev.get("boss") != null else "prelate"
	var def: Dictionary = fx.boss_def(boss_id)
	var phase := int(fx.f(ev, "phase", 1.0))
	if kind == "awaken":
		_awaken(ev, def, boss_id, ex, ez)
	elif kind == "phase":
		_phase(ev, def, boss_id, phase, ex, ez)
	elif AREA_KINDS.has(kind):
		area_boss_event(ev, ms)
	elif kind == "toll":
		var bronze: int = fx.sp("boss", "bronze")
		var r := fx.f(ev, "r", 6.5)
		if ms == 0.0:
			fx.snd("bossToll", ex, ez)
		if ms > 0.0:
			_dec("disc", bronze, ex, ez, r + DmSimConsts.BOSS_RING_PAD, ms, 0.75, {"fadeIn": ms * 0.8, "fadeOut": 0.05, "growFrom": 0.15})
		else:
			for k in 3:
				_dec("ring", bronze, ex, ez, r * (0.8 + float(k) * 0.25), 0.6, 1.0 - float(k) * 0.25, {"growFrom": 0.1, "delay": float(k) * 0.07})
			fx.emit({"x": ex, "y": 1, "z": ez, "count": 70, "color": bronze, "spread": 2, "speed": 7, "up": 1, "life": 0.7, "size": 0.35})
			fx.light_flash(ex, 3, ez, bronze, 60, 0.6)
			fx.bb("bell_toll_ring", ex, ez, {"scale": r / 3.0})
			fx.shake(0.4)
	elif kind == "slam" or kind == "rain":
		var circles := _targets(ev, [[ex, ez]])
		var bronze2: int = fx.sp("boss", "bronze")
		var sr := fx.f(ev, "r", 2.3)
		for t in circles:
			var x := float(t[0])
			var z := float(t[1])
			if ms > 0.0:
				_dec("disc", bronze2, x, z, sr + DmSimConsts.BOSS_RING_PAD, ms, 0.8, {"fadeIn": ms * 0.8, "fadeOut": 0.05, "growFrom": 0.3})
			else:
				fx.emit({"x": x, "y": 0.5, "z": z, "count": 24, "color": fx.sp("boss", "shard"), "spread": 0.6, "speed": 3, "up": 2, "life": 0.6, "size": 0.25, "gravity": 6})
				fx.vfx.flash({"x": x, "y": 0.6, "z": z, "color": bronze2, "size": 2.2, "duration": 0.25})
				fx.emit_smoke({"x": x, "y": 0.3, "z": z, "count": 5, "color": 0x3a3340, "spread": 0.8, "speed": 1.4, "up": 0.6, "life": 1, "size": 1.4})
				fx.vfx.spike_line(x - 0.5, z, 1.0, 0.0, 1.2, 1.2)
				fx.bb("prelate_impact" if kind == "slam" else "boss_rain_orb", x, z, {"scale": sr / 2.3})
		if ms == 0.0:
			fx.shake(0.25)
			fx.snd("bossSlam", ex, ez)
	elif kind == "summon":
		var spirit: int = fx.sp("boss", "spirit")
		for t in _targets(ev, []):
			var x := float(t[0])
			var z := float(t[1])
			_dec("cracks", spirit, x, z, 2.4, 2, 0.9, {"growFrom": 0.3})
			fx.emit({"x": x, "y": 0.4, "z": z, "count": 30, "color": spirit, "spread": 0.8, "speed": 0.6, "up": 2.5, "life": 1.2, "size": 0.3})
	elif kind == "defeated":
		_defeated(ev, def, boss_id, ex, ez)


func _awaken(ev: Dictionary, def: Dictionary, boss_id: String, ex: float, ez: float) -> void:
	if fx.game.has_method("codex_discover"):
		fx.game.codex_discover("dead", boss_id)
	fx.snd("bossAwaken", ex, ez)
	if boss_id == "regent":
		fx.toast("The Cinder Regent: when Conflagration begins, run to a grey ash circle. Kill the Pyre Priests early.", "err")
	if boss_id == "mire":
		fx.toast("The Mire Mother: she sinks and resurfaces. Leave the ringed hummock, punish her while she is winded, and spend your corpses before she raises them.", "err")
	if boss_id == "saint":
		saint_bless_told = false
		saint_rain_told = false
		saint_link_told = false
	var empowered := bool(ev.get("empowered", false))
	fx.banner("Empowered %s" % def.get("name", "") if empowered else String(def.get("name", "")), "Bound by a Covenant Seal: stronger, and it pays better" if empowered else String(def.get("awaken", "")), 3500)
	var col: int = 0xff6a2a if empowered else int(def.get("color", 0xffffff))
	fx.light_flash(ex, 3, ez, col, 90, 1.6)
	fx.emit({"x": ex, "y": 0.5, "z": ez, "count": 160, "color": 0xb58cff if boss_id == "prelate" else int(def.get("color", 0xffffff)), "spread": 3, "speed": 4, "up": 4, "life": 1.6, "size": 0.5})
	fx.shake(0.6)
	if boss_id == "prelate":
		for g in ["west", "east", "north"]:
			fx.set_candle_group(g, true)


func _phase(ev: Dictionary, def: Dictionary, boss_id: String, phase: int, ex: float, ez: float) -> void:
	fx.snd("bossPhase", ex, ez)
	if boss_id == "prelate":
		fx.banner("The Procession" if phase == 2 else "The Bell Breaks", "Penitents file in from the aisles" if phase == 2 else "The Prelate is enraged", 2600)
		fx.set_candle_group("west" if phase == 2 else "east", false)
	else:
		fx.banner(String(def["phases"][phase - 1]), String(def["name"]), 2600)
		if boss_id == "regent":
			var ember: int = fx.sp("enemy", "ember")
			var core: int = fx.sp("enemy", "emberCore")
			for k in 3:
				_dec("ring", ember, ex, ez, 5.0 + float(k) * 3.0, 0.9, 1.0 - float(k) * 0.25, {"growFrom": 0.1, "delay": float(k) * 0.12})
			fx.emit({"x": ex, "y": 1, "z": ez, "count": 90, "color": core, "spread": 2.5, "speed": 6, "up": 2.5, "life": 0.9, "size": 0.2, "gravity": 4})
			fx.light_flash(ex, 3, ez, ember, 70, 0.9)
			fx.shake(0.5)
			fx.toast("The pyre feeds: Husks and Pyre Priests join. Kill the Priests before their coals cover the ash." if phase == 2 else "The pyre burns down: fewer ash circles, and hounds hunt in packs.", "err")
		if boss_id == "mire":
			fx.toast("The marsh floods: the hummocks shrink and the water drags harder. Leeches climb out." if phase == 2 else "The drowned rise: spend your corpses before she raises them. Hags will hex your thralls.", "err")
		if boss_id == "saint":
			if phase == 3:
				# The swarm: a rot nova so the phase change feels like an event.
				for k in 3:
					_dec("ring", 0x9cc43a, ex, ez, 6.0 + float(k) * 3.0, 0.9, 1.0 - float(k) * 0.25, {"growFrom": 0.1, "delay": float(k) * 0.12})
				fx.emit({"x": ex, "y": 1, "z": ez, "count": 90, "color": 0x9cc43a, "spread": 2.5, "speed": 6, "up": 1.5, "life": 0.9, "size": 0.35})
				fx.light_flash(ex, 3, ez, 0x9cc43a, 70, 0.9)
				fx.shake(0.5)
			fx.toast("Her flock gathers: Plague Doctors feed her through a green link. Cut them down first, then keep her out of the rot." if phase == 2 else "The swarm: the rain falls heavier and the pools last longer. Keep her out of them.", "err")
	fx.shake(0.5)


func _defeated(ev: Dictionary, def: Dictionary, boss_id: String, ex: float, ez: float) -> void:
	if fx.game.has_method("boss_view_hide"):
		fx.game.boss_view_hide(boss_id)
	elif fx.game.has_method("boss_view"):
		var bv = fx.game.boss_view(boss_id)
		if bv != null and bv.has_method("hide_boss"):
			bv.hide_boss()
		elif bv != null and bv.has_method("hide"):
			bv.hide()
	clear()
	if boss_id == "prelate":
		for g in ["west", "east", "north"]:
			fx.set_candle_group(g, true)
	var killer: Variant = ev.get("killer")
	var has_killer: bool = killer is String and killer != ""
	if has_killer:
		fx.snd("bossDefeat", ex, ez)
		var d: Array = def.get("defeated", ["", ""])
		fx.banner(String(d[0]), String(d[1]), 4200)
	# Rewards follow the normal-kill rule (owner, 3 Oct 2026): only a living hero within 38 m of the boss is paid.
	if has_killer and fx.player_alive() and fx.dist_player(ex, ez) < float(DmContent.file("gameplay_killCredit")["KILL_REWARD_RANGE"]):
		fx.hook("on_boss_defeated", ev)
		fx.light_flash(ex, 3, ez, 0xc6a4ff, 100, 2)
		fx.shake(0.7)
