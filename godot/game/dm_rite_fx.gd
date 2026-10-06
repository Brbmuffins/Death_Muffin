class_name DmRiteFx
extends RefCounted
## The per-rite visuals and sounds of the necromancer's rites (needle, miasma, exhume, corpse rites), shared by the current game (DmAbilitySystem delegates here, behaviour and
## stats counters unchanged) and by the rebuild's DmRiteCaster (godot/next/rites). One place draws a rite, so the two cannot drift apart.
##
## `fx` / `audio` are the Vfx / AudioDirector back-ends (null-safe; tests pass recording stubs). `stats` is the SAME Dictionary the owner counts
## into (DmAbilitySystem.stats), so every call is counted exactly once, here.

var fx: Object = null
var audio: Object = null
var stats: Dictionary = {"decal": 0, "emit": 0, "smoke": 0, "flash": 0, "light": 0, "beam": 0, "orbit": 0, "projectile": 0, "bb": 0, "motif": 0, "spikes": 0,
	"hands": 0, "bone_orbit": 0, "sfx": 0, "loop": 0, "gesture": 0, "shake": 0, "float": 0}


## Binbun scenes the rites play. Loading a scene stalls the NEXT frame for ~0.3-0.45 s (measured headless), so they are loaded under the loading
## screen (warm), never on the first cast. Add the id here when a rite plays a new `bb(...)`.
const BINBUN_IDS := ["miasma_cloud", "toxic_puddle", "carrion_seed_armed", "carrion_seed_burst", "corpse_explosion", "crit_hit", "exhume_lift",
	"grave_offering_orb", "grave_offering_ripple", "litany_pulse"]


func warm() -> void:
	if fx != null and fx.get("binbun") != null and fx.binbun.enabled:
		fx.binbun.preload_ids(BINBUN_IDS)


static func with_autoloads() -> DmRiteFx:
	var r := DmRiteFx.new()
	var ml := Engine.get_main_loop()
	if ml is SceneTree:
		var root := (ml as SceneTree).root
		r.fx = root.get_node_or_null("Vfx")
		r.audio = root.get_node_or_null("AudioDirector")
	return r


# --- counted primitives ------------------------------------------------------------------------------------------------------------------

func decal(tex: String, color: Variant, x: float, z: float, r: float, duration: float, opacity: float, extra: Dictionary = {}) -> Variant:
	var o := {"tex": tex, "color": color, "x": x, "z": z, "r": r, "duration": duration, "opacity": opacity}
	o.merge(extra, true)
	stats["decal"] += 1
	return fx.decal(o) if fx != null else null


func emit(x: float, y: float, z: float, count: int, color: Variant, spread: float, speed: float, up: float, life: float, size: float, extra: Dictionary = {}) -> void:
	var o := {"x": x, "y": y, "z": z, "count": count, "color": color, "spread": spread, "speed": speed, "up": up, "life": life, "size": size}
	o.merge(extra, true)
	stats["emit"] += 1
	if fx != null:
		fx.emit(o)


func smoke(x: float, y: float, z: float, count: int, color: Variant, spread: float, speed: float, up: float, life: float, size: float, extra: Dictionary = {}) -> void:
	var o := {"x": x, "y": y, "z": z, "count": count, "color": color, "spread": spread, "speed": speed, "up": up, "life": life, "size": size}
	o.merge(extra, true)
	stats["smoke"] += 1
	if fx != null:
		fx.emit_smoke(o)


func flash(x: float, y: float, z: float, color: Variant, size: float, duration: float, extra: Dictionary = {}) -> void:
	var o := {"x": x, "y": y, "z": z, "color": color, "size": size, "duration": duration}
	o.merge(extra, true)
	stats["flash"] += 1
	if fx != null:
		fx.flash(o)


func bb(id: String, x: float, z: float, o: Dictionary = {}) -> Variant:
	stats["bb"] += 1
	if fx == null:
		return null
	return fx.play(id, Vector3(x, float(o.get("y", 0.0)), z), o)


func splinters(x: float, y: float, z: float, n: int, color: Variant, speed: float = 3.6, origin: String = "player") -> void:
	stats["motif"] += 1
	if fx != null:
		fx.motifs.bone_splinters(x, y, z, {"n": n, "color": color, "speed": speed, "origin": origin})


func sfx(id: String, x: float, z: float, intensity: float = 1.0) -> void:
	stats["sfx"] += 1
	if audio != null:
		audio.play_sfx(id, Vector2(x, z), intensity)


func loop(id: String, ms: float, x: float, z: float, follow: Callable = Callable()) -> void:
	stats["loop"] += 1
	if audio != null:
		audio.loop_sfx(id, ms, Vector2(x, z), follow)


func lf(x: float, y: float, z: float, color: Color, intensity: float, life: float) -> void:
	stats["light"] += 1
	if fx != null:
		fx.light_flash(Vector3(x, y, z), color, intensity, life)


func beam(a: Variant, b: Callable, color: Variant, width: float, duration: float) -> Variant:
	stats["beam"] += 1
	return fx.beam(a, b, color, width, duration) if fx != null else null


func dirt(x: float, z: float, r: float, n: int, up: float = 2.4, origin: String = "player") -> void:
	stats["motif"] += 1
	if fx != null:
		fx.motifs.grave_dirt(x, z, {"r": r, "n": n, "up": up, "origin": origin})


func motes(x: float, z: float, color: Variant, r: float, n: int, up: float = 1.1, y: float = 0.25, origin: String = "player") -> void:
	stats["motif"] += 1
	if fx != null:
		fx.motifs.soul_motes(x, z, color, {"r": r, "n": n, "up": up, "y": y, "origin": origin})


func skulls(x: float, z: float, color: Variant, o: Dictionary) -> void:
	stats["motif"] += 1
	if fx != null:
		fx.motifs.skull_wisps(x, z, color, o)


static func kill(h: Variant) -> void:
	if h != null and h is Object and is_instance_valid(h) and h.has_method("kill"):
		h.kill()


# --- Bone Needle -------------------------------------------------------------------------------------------------------------------------

## The cast: muzzle flash at the staff tip + the cast sound (+ the Volley rune's burst when `volley`). `from` = [x, y, z] tip; (px, pz) = caster.
func needle_cast(from: Array, px: float, pz: float, volley: bool = false) -> void:
	var N := DmFxData.spell_group("needle")
	flash(from[0], from[1], from[2], N["trail"], 0.7, 0.14)
	sfx("needleCast", px, pz)
	if volley:
		splinters(from[0], from[1], from[2], 5, N["core"], 3.5)
		decal("ring", N["trail"], px, pz, 1.3, 0.35, 0.55, {"growFrom": 0.4})


## The landing: sound, flash, dust, shards (+ crit flare). `pos` = [x, y, z].
func needle_hit(pos: Array, crit: bool) -> void:
	var N := DmFxData.spell_group("needle")
	sfx("needleHit", pos[0], pos[2], 1.4 if crit else 1.0)
	flash(pos[0], pos[1], pos[2], N["impact"], 1.7 if crit else 1.05, 0.2)
	emit(pos[0], pos[1], pos[2], 16 if crit else 8, N["dust"], 0.1, 3.2, 1.2, 0.4, 0.13, {"gravity": 7.0})
	if crit:
		emit(pos[0], pos[1], pos[2], 10, N["trail"], 0.2, 4.0, 0.5, 0.3, 0.3)
	splinters(pos[0], pos[1], pos[2], 7 if crit else 3, N["core"])
	if crit:
		bb("crit_hit", pos[0], pos[2], {"y": pos[1]})


## The Splinters rune's shard: a thread of bone from the struck enemy to the next (the current game's DmAbilitySystem._splinter).
func splinter_shard(a: Vector3, b: Vector3) -> void:
	var core: Variant = DmFxData.spell("needle", "core")
	beam(a, func() -> Variant: return b, core, 0.03, 0.16)
	flash(b.x, 1.0, b.z, core, 0.7, 0.16)
	splinters(b.x, 1.0, b.z, 3, core)
	splinters(a.x, 1.0, a.z, 6, core, 4.5)


# --- Miasma Circle -----------------------------------------------------------------------------------------------------------------------

## The cloud settling at (x, z) with radius r. `creep` = the Creeping Rot rune (no cloud model, the zone itself moves: `follow` -> its ground point or
## null); `contagion` = the Contagion rune's green ring.
func miasma_land(x: float, z: float, r: float, creep: bool = false, follow: Callable = Callable(), contagion: bool = false) -> void:
	var M := DmFxData.spell_group("miasma")
	var fo := {"follow": follow} if follow.is_valid() else {}
	decal("ring", M["rot"], x, z, r, 0.45, 0.7, {"growFrom": 0.2})
	if follow.is_valid():   # the walking circle is drawn where it is, for as long as it lives
		decal("disc", M["deep"], x, z, r, 6.0, 0.5, fo.merged({"growFrom": 0.3, "fadeOut": 0.6}))
		bb("miasma_cloud", x, z, fo.merged({"scale": r / 3.8, "duration": 6.0}))
	if contagion:
		decal("ring", DmFxData.spell("lance", "rot"), x, z, r * 1.02, 6.0, 0.55, fo.merged({"pulse": 3.0, "fadeOut": 0.6}))
	sfx("miasma", x, z)
	loop("miasmaLoop", 6000.0, x, z, follow)
	smoke(x, 0.4, z, 6, M["spore"], r * 0.6, 0.5, 0.3, 0.9, 1.1, {"shrink": -0.3, "drag": 0.8})
	emit(x, 0.3, z, 16, M["rot"], r * 0.5, 1.1, 0.6, 0.65, 0.18)
	if fx != null:
		stats["motif"] += 1
		fx.motifs.rot_spores(x, z, M["rot"], {"r": r * 0.75, "n": DmMath.js_round(8.0 + r * 2.0)})
	if not creep:
		bb("miasma_cloud", x, z, {"scale": r / 3.8})


## Plague Choir: "plague" = a fresh circle opens on an enemy, "spread" = a dead enemy's Withered passes on (the current game's DmEventFx._legend).
func legend_burst(kind: String, x: float, z: float, r: float) -> void:
	var rot: Variant = DmFxData.spell("miasma", "rot")
	if kind == "spread":
		decal("ring", rot, x, z, r * 0.7, 0.35, 0.7, {"growFrom": 0.2})
		if fx != null:
			stats["motif"] += 1
			fx.motifs.rot_spores(x, z, rot, {"r": r * 0.5, "n": 6})
		return
	decal("ring", rot, x, z, r, 0.5, 0.9, {"growFrom": 0.15})
	emit(x, 0.5, z, 14, rot, r * 0.4, 2.6, 1.2, 0.55, 0.22)
	if fx != null:
		stats["motif"] += 1
		fx.motifs.rot_spores(x, z, rot, {"r": r * 0.6, "n": 10})
	sfx("miasma", x, z, 0.7)


## Colossus Mantle: r > 0 = the broken barrier's shard burst around (x, z); r = 0 = a few bone chips where the reflected blow struck.
func legend_hit(x: float, z: float, r: float) -> void:
	var S := DmFxData.spell_group("spear")
	if r <= 0.0:
		emit(x, 1.0, z, 5, S["bone"], 0.2, 2.4, 0.8, 0.3, 0.12)
		return
	decal("ring", S["bone"], x, z, r, 0.5, 1.0, {"growFrom": 0.1})
	splinters(x, 1.0, z, 12, S["bone"], 6.0)
	emit(x, 0.8, z, 14, S["bone"], 0.5, 5.0, 1.2, 0.5, 0.16, {"gravity": 6.0})
	sfx("boneHit", x, z, 1.1)


## Requiem Wraiths: a wisp circling the caster for `secs` (`follow` -> its ground point or null).
func wisp(secs: float, speed: float, radius: float, follow: Callable) -> void:
	var jade: Variant = DmFxData.spell("souls", "jade")
	if fx != null:
		stats["orbit"] += 1
		fx.orbit({"tex": "wisp", "color": jade, "count": 1, "radius": radius, "y": 1.5, "size": 0.6, "duration": secs, "speed": speed, "follow": follow})


## Requiem Wraiths 5: a nova ring at each source `pts` ([[x, z]]), radius r.
func legend_nova(pts: Array, r: float) -> void:
	var jade: Variant = DmFxData.spell("souls", "jade")
	var pale: Variant = DmFxData.spell("souls", "pale")
	for s: Array in pts:
		decal("ring", jade, float(s[0]), float(s[1]), r, 0.45, 0.8, {"growFrom": 0.15})
		emit(float(s[0]), 0.9, float(s[1]), 8, pale, 0.4, 3.2, 0.6, 0.4, 0.16)
	if not pts.is_empty():
		sfx("soulRelease", float(pts[0][0]), float(pts[0][1]), 0.8)


## Contagion rune: a thread of rot from the dying body to the next, and spores where it lands.
func contagion_thread(x: float, z: float, tx: float, tz: float) -> void:
	var rot: Variant = DmFxData.spell("lance", "rot")
	beam(Vector3(x, 0.9, z), func() -> Variant: return Vector3(tx, 1.0, tz), rot, 0.05, 0.45)
	emit(tx, 0.9, tz, 10, rot, 0.3, 1.4, 1.0, 0.6, 0.2)
	if fx != null:
		stats["motif"] += 1
		fx.motifs.rot_spores(tx, tz, rot, {"r": 0.6, "n": 5})
	sfx("miasma", tx, tz)


# --- shot visuals (rebuild only: the current game flies the caster's own projectile) -----------------------------------------------------

## A visual-only projectile. `to` = Vector3 or a Callable returning Vector3/null (follows a moving target).
func shot(from: Vector3, to: Variant, speed: float, arc: float, kind: String, color: Color, extra: Dictionary = {}) -> Variant:
	stats["projectile"] += 1
	if fx == null:
		return null
	var to_fn: Callable = to if to is Callable else (func() -> Variant: return to)
	var o := {"from": from, "to": to_fn, "speed": speed, "color": color, "kind": kind, "arc": arc}
	o.merge(extra, true)
	return fx.projectile(o)


# --- Exhume ------------------------------------------------------------------------------------------------------------------------------

## The digging: beam from the staff tip to the corpse (cx, cz), spirit burst, cracks, hands, the lift. `others` = [[x, z]] extra corpses of a Mass Grave;
## `company` = [[x, z]] corpses a Bone Colossus draws together (a non-empty array means a Colossus rises). Returns the camera shake to apply (0 = none).
func exhume_cast(tip: Vector3, cx: float, cz: float, others: Array, company: Array) -> float:
	var X := DmFxData.spell_group("exhume")
	var N := DmFxData.spell_group("needle")
	beam(tip, func() -> Variant: return Vector3(cx, 0.3, cz), X["beam"], 0.06, 0.4)
	sfx("exhume", cx, cz)
	emit(cx, 0.2, cz, 26, X["spirit"], 0.6, 0.4, 3.4, 1.0, 0.34, {"gravity": -0.5})
	decal("cracks", X["deep"], cx, cz, 1.4, 1.3, 0.9, {"rot": randf() * 6.0, "growFrom": 0.3})
	dirt(cx, cz, 0.6, 9, 3.0)
	if fx != null:
		stats["motif"] += 2
		fx.motifs.spectral_hands(cx, cz, {"n": 3, "r": 0.6, "duration": 1.2})
		fx.motifs.spirit_wisps(cx, cz, X["spirit"], {"n": 2, "r": 0.3, "y": 0.5, "size": 0.7})
	bb("exhume_lift", cx, cz)
	for o: Array in others:
		beam(tip, func() -> Variant: return Vector3(o[0], 0.3, o[1]), X["beam"], 0.04, 0.35)
		decal("cracks", X["deep"], o[0], o[1], 1.2, 1.2, 0.9, {"rot": randf() * 6.0, "growFrom": 0.3})
		dirt(o[0], o[1], 0.5, 6, 2.6)
		if fx != null:
			stats["motif"] += 1
			fx.motifs.spectral_hands(o[0], o[1], {"n": 2, "r": 0.5, "duration": 1.1})
		emit(o[0], 0.2, o[1], 18, X["spirit"], 0.5, 0.4, 3.0, 1.0, 0.3, {"gravity": -0.5})
	if not others.is_empty() or company.is_empty():
		return 0.0
	var ccx := 0.0
	var ccz := 0.0
	for o: Array in company:
		ccx += o[0]
		ccz += o[1]
	ccx /= company.size()
	ccz /= company.size()
	for o: Array in company:
		beam(Vector3(o[0], 0.4, o[1]), func() -> Variant: return Vector3(ccx, 1.2, ccz), X["beam"], 0.05, 0.7)
		emit(o[0], 0.3, o[1], 14, X["spirit"], 0.4, 2.2, 1.2, 0.8, 0.3)
		splinters(o[0], 0.4, o[1], 5, N["core"], 3.0)
	decal("sigil", X["spirit"], ccx, ccz, 3.2, 1.4, 0.8, {"growFrom": 1.4, "spin": 0.8})
	decal("ring", X["beam"], ccx, ccz, 3.6, 0.9, 0.9, {"growFrom": 0.4})
	emit(ccx, 0.4, ccz, 36, X["spirit"], 3.0, 5.0, 0.4, 0.5, 0.3, {"inward": true, "drag": 0.0})
	lf(ccx, 1.5, ccz, X["spirit"], 34.0, 0.9)
	return 0.1


# --- Corpse Explosion --------------------------------------------------------------------------------------------------------------------

## The blast the host reported (ev: x, z, r, elite, corpseKind). Ember burst + bone shrapnel. Returns the camera shake to apply.
func detonated(ev: Dictionary, mine: bool) -> float:
	var D := DmFxData.spell_group("detonate")
	var x := float(ev["x"])
	var z := float(ev["z"])
	var r := float(ev["r"])
	var elite: bool = ev.get("elite", false)
	sfx("corpseExplode", x, z)
	flash(x, 0.7, z, D["hot"], r * 0.8, 0.2)
	decal("ring", D["ember"], x, z, r, 0.45, 1.0, {"growFrom": 0.15})
	decal("glow", D["crimson"], x, z, r * 0.9, 0.7, 0.85, {"growFrom": 0.4})
	decal("cracks", D["crimson"], x, z, r * 0.75, 1.6, 0.85, {"rot": randf() * 6.0, "growFrom": 0.5})
	emit(x, 0.6, z, 24, D["ember"], 0.3, r * 2.8, 1.6, 0.5, 0.34, {"drag": 1.5})
	emit(x, 0.7, z, 16, D["bone"], 0.25, r * 2.3, 4.5, 0.9, 0.14, {"gravity": 14.0})
	emit(x, 0.4, z, 8, D["crimson"], 0.3, 2.0, 2.4, 0.8, 0.26, {"gravity": 6.0})
	smoke(x, 0.4, z, 4, D["smoke"], r * 0.35, 1.4, 0.8, 0.75, 1.0, {"shrink": -0.3})
	var who := "player" if mine else "thrall"
	dirt(x, z, r * 0.4, 9, 3.2, who)
	splinters(x, 0.8, z, 8, D["bone"], r * 1.8, who)
	skulls(x, z, D["hot"], {"n": 1, "y": 0.8, "size": 0.7, "rise": 1.2, "origin": who})
	lf(x, 1.2, z, D["ember"], 55.0 if elite else 38.0, 0.45)
	bb("corpse_explosion", x, z, {"scale": r / 3.0})
	if ev.get("corpseKind") == "resonant":
		decal("ring", DmFxData.spell("enemy", "toll"), x, z, r * 1.05, 0.6, 0.8, {"growFrom": 0.2, "delay": 0.06})
		sfx("tollSmall", x, z)
	if ev.get("corpseKind") == "toxic":
		emit(x, 0.4, z, 24, DmFxData.spell("miasma", "rot"), 0.5, 3.0, 1.4, 0.8, 0.3)
	if elite:
		decal("ring", D["hot"], x, z, r * 1.2, 0.5, 0.9, {"growFrom": 0.1, "delay": 0.08})
	return (0.055 if mine else 0.025) + (0.035 if elite else 0.0)


## The rot pool a toxic corpse leaves (friendly): a cracked-ground decal for its life.
func rot_pool(x: float, z: float, r: float, seconds: float) -> void:
	decal("cracks", DmFxData.spell("enemy", "rot"), x, z, r * 0.95, seconds, 0.22, {"fadeOut": 0.6})


# --- Black Litany ------------------------------------------------------------------------------------------------------------------------

## The ritual burst the host reported (ev: x, z, r, corpses, thralls, tethers). `tip` = [x, y, z] the beams run to. Returns the camera shake.
func litany_result(ev: Dictionary, mine: bool, tip: Array) -> float:
	var L := DmFxData.spell_group("litany")
	var x := float(ev["x"])
	var z := float(ev["z"])
	var r := float(ev["r"])
	var tethers: Array = ev["tethers"]
	for k in mini(10, tethers.size()):
		var tt: Array = tethers[k]
		beam(Vector3(tt[0], 0.6, tt[1]), func() -> Variant: return Vector3(tip[0], tip[1], tip[2]), L["core"], 0.045, 0.5)
		emit(tt[0], 0.5, tt[1], 8, L["core"], 0.3, 0.6, 1.5, 0.6, 0.3)
	emit(x, 0.6, z, 32, L["core"], r, 7.0, 0.2, 0.25, 0.22, {"inward": true, "drag": 0.0})
	smoke(x, 0.5, z, 4, L["void"], 1.0, 0.4, 0.2, 0.65, 1.3, {"shrink": -0.3})
	decal("sigil", L["core"], x, z, r, 0.7, 0.5, {"growFrom": 0.1, "spin": 0.35})
	bb("litany_pulse", x, z, {"scale": r / 7.0})
	decal("ring", L["hot"], x, z, r * 1.15, 0.55, 1.0, {"growFrom": 0.05, "delay": 0.18})
	emit(x, 0.5, z, 48, L["core"], 1.0, 9.0, 1.8, 0.55, 0.23)
	emit(x, 0.8, z, 16, L["hot"], 0.6, 5.0, 3.0, 0.45, 0.2)
	flash(x, 1.5, z, L["core"], minf(2.0, r * 0.24), 0.3)
	var who := "player" if mine else "thrall"
	if fx != null:
		stats["motif"] += 1
		fx.motifs.skull_ring(x, z, minf(r * 0.62, 5.0), L["hot"], {"n": mini(8, 4 + int(ev["corpses"]) + int(ev["thralls"])), "origin": who})
	for k in mini(5, tethers.size()):
		motes(tethers[k][0], tethers[k][1], L["hot"], 0.3, 3, 1.8, 0.25, who)
	lf(x, 2.0, z, L["core"], 32.0, 0.4)
	return 0.0   # the caller adds the sound + shake (they depend on the counts); see litany_finish


## The sound and shake of the burst, which scale with what it consumed. Returns the shake.
func litany_finish(ev: Dictionary) -> float:
	var n := int(ev["corpses"]) + int(ev["thralls"])
	sfx("litany", float(ev["x"]), float(ev["z"]), 1.0 + minf(0.6, float(n) * 0.05))
	return 0.08 + minf(0.08, float(n) * 0.008)


## Requiem rune: the ground is marked; a ring of skulls closes in over the warning and the burst follows (ev: x, z, r, ms).
func requiem(ev: Dictionary, mine: bool) -> void:
	var core := DmFxData.spell("litany", "core")
	var hot := DmFxData.spell("litany", "hot")
	var x := float(ev["x"])
	var z := float(ev["z"])
	var r := float(ev["r"])
	var sec := float(ev["ms"]) / 1000.0
	decal("sigil", core, x, z, r, sec, 0.55, {"growFrom": 0.6, "spin": 0.5, "fadeOut": 0.3})
	decal("ring", hot, x, z, r, sec, 0.9, {"growFrom": 1.0, "pulse": 4})
	decal("ring", core, x, z, r * 0.45, sec, 0.5, {"growFrom": 1.6})
	if fx != null:
		stats["motif"] += 1
		fx.motifs.skull_ring(x, z, minf(r * 0.7, 9.0), hot, {"n": 8, "origin": "player" if mine else "thrall"})
	sfx("toll", x, z)


# --- Grave Offering ----------------------------------------------------------------------------------------------------------------------

## The corpse burning away (ev: x, z), then the orb that flies to the caster is `offering_orb`.
func offering_start(x: float, z: float) -> void:
	var X := DmFxData.spell_group("exhume")
	decal("ring", X["spirit"], x, z, 1.1, 0.5, 0.9, {"growFrom": 0.3})
	emit(x, 0.5, z, 14, X["spirit"], 0.3, 1.0, 2.2, 0.6, 0.18)
	bb("grave_offering_ripple", x, z)
	sfx("graveOffering", x, z)


## The orb flying from the corpse to the caster; `follow` returns the caster's point (Vector3 / null).
func offering_orb(x: float, z: float, follow: Callable, speed: float) -> Variant:
	var X := DmFxData.spell_group("exhume")
	return shot(Vector3(x, 0.8, z), follow, speed, 0.0, "sprite", X["beam"], {"tex": "wisp", "size": 0.9})


## The orb arriving at the caster (pos = [x, y, z]).
func offering_arrive(pos: Array, mine: bool) -> void:
	flash(pos[0], pos[1], pos[2], DmFxData.spell("exhume", "spirit"), 1.2, 0.2)
	bb("grave_offering_orb", pos[0], pos[2])
	if mine:
		sfx("graveOffering", pos[0], pos[2])


# --- Carrion Seed ------------------------------------------------------------------------------------------------------------------------

## A seed planted (ev: x, z, armMs). Returns [bud decal, core effect] so the caller can end them early.
func seeded(ev: Dictionary) -> Array:
	var BL := DmFxData.spell_group("bloom")
	var life := float(DmSimData.CARRION_SEED["lifeS"]) + 1.0
	var core: Variant = bb("carrion_seed_armed", float(ev["x"]), float(ev["z"]), {"duration": life})
	emit(float(ev["x"]), 0.4, float(ev["z"]), 10, BL["petal"], 0.3, 0.8, 1.2, 0.5, 0.14)
	var bud: Variant = decal("seedBud", BL["petal"], float(ev["x"]), float(ev["z"]), 0.75, life, 0.95, {"growFrom": 0.2, "pulse": 3.0, "fadeIn": float(ev["armMs"]) / 1000.0})
	return [bud, core]


## The seed burst (ev: x, z, r). Returns the camera shake.
func seed_burst(ev: Dictionary) -> float:
	var BL := DmFxData.spell_group("bloom")
	var x := float(ev["x"])
	var z := float(ev["z"])
	var r := float(ev["r"])
	decal("ring", BL["petal"], x, z, r, 0.5, 1.0, {"growFrom": 0.2})
	decal("disc", BL["rot"], x, z, r * 0.9, 1.5, 0.55, {"fadeOut": 0.8})
	emit(x, 0.5, z, 30, BL["petal"], 0.4, r * 2.4, 1.6, 0.6, 0.22, {"drag": 1.4})
	smoke(x, 0.6, z, 6, BL["spore"], r * 0.4, 1.0, 0.6, 1.0, 1.4, {"shrink": -0.4})
	lf(x, 1.0, z, BL["petal"], 22.0, 0.3)
	bb("carrion_seed_burst", x, z, {"scale": r / 3.0})
	bb("toxic_puddle", x, z, {"scale": r / 3.0, "duration": 1.5})
	sfx("seedBurst", x, z)
	return 0.06


# --- Bone Mantle -------------------------------------------------------------------------------------------------------------------------

## The mantle drawn up (ev: x, z, corpses, tethers); `follow` returns the caster's ground point (Vector3 / null). Returns [orbit, ring] handles.
func mantle(ev: Dictionary, mine: bool, follow: Callable) -> Array:
	var MN := DmFxData.spell_group("mantle")
	var M: Dictionary = DmSimData.BONE_MANTLE
	var beam_end := func() -> Variant:
		var f: Variant = follow.call()
		return Vector3(f.x, 1.1, f.z) if f != null else null
	for tt: Array in ev["tethers"]:
		beam(Vector3(tt[0], 0.4, tt[1]), beam_end, MN["bone"], 0.05, 0.4)
		emit(tt[0], 0.4, tt[1], 10, MN["bone"], 0.4, 1.2, 1.6, 0.5, 0.16, {"gravity": 4.0})
		smoke(tt[0], 0.3, tt[1], 2, MN["dust"], 0.4, 0.5, 0.4, 0.8, 0.9)
		splinters(tt[0], 0.5, tt[1], 3, MN["bone"], 3.6, "player" if mine else "thrall")
	var handle: Variant = null
	if fx != null:
		stats["bone_orbit"] += 1
		handle = fx.bone_orbit({"fallbackTex": "boneShard", "fallbackColor": MN["bone"], "count": mini(15, 6 + int(ev["corpses"]) * 2), "radius": float(M["orbitRadius"]),
			"y": 0.7, "size": 0.5, "duration": float(M["durationS"]), "speed": 3.4, "follow": follow})
	var ring: Variant = decal("boneRing", MN["amber"], float(ev["x"]), float(ev["z"]), float(M["orbitRadius"]) + 0.5, float(M["durationS"]), 0.45,
		{"growFrom": 0.4, "spin": 0.5, "fadeOut": 0.4, "follow": follow})
	lf(float(ev["x"]), 1.4, float(ev["z"]), MN["gold"], 26.0, 0.4)
	sfx("mantle", float(ev["x"]), float(ev["z"]))
	return [handle, ring]


# --- Projectile rites (rebuild: bone_fan, rot_lance, marrow_spear, wailing_skull, ivory_cleave, bone_storm, soul_siphon) ----------------------------------------
# The same calls, colours and sounds as DmAbilitySystem's overrides of those rites; positions come from the host's events. Vectors are Vector3.

func spike_line(x: float, z: float, dx: float, dz: float, length: float, width: float, sequential: bool = false) -> void:
	stats["spikes"] += 1
	if fx != null:
		fx.spike_line(x, z, dx, dz, length, width, sequential)


func spike_ring(x: float, z: float, r: float, count: int, life: float) -> void:
	stats["spikes"] += 1
	if fx != null:
		fx.spike_ring(x, z, r, count, life)


## Bone Fan: the muzzle flash + sound (the slivers themselves are `shot`s).
func fan_cast(tip: Vector3, px: float, pz: float) -> void:
	flash(tip.x, tip.y, tip.z, DmFxData.spell("needle", "trail"), 0.8, 0.14)
	sfx("boneFan", px, pz)


func fan_hit(pos: Vector3) -> void:
	var N := DmFxData.spell_group("needle")
	sfx("needleHit", pos.x, pos.z, 0.8)
	flash(pos.x, pos.y, pos.z, N["impact"], 0.8, 0.16)
	emit(pos.x, pos.y, pos.z, 6, N["dust"], 0.1, 3.0, 1.1, 0.35, 0.12, {"gravity": 7.0})


## Rot Lance: flash + sound + the beam down the lane (`end` = where the lance stops).
func lance_cast(tip: Vector3, end: Vector3, px: float, pz: float) -> void:
	var LN := DmFxData.spell_group("lance")
	flash(tip.x, tip.y, tip.z, LN["rot"], 0.7, 0.14)
	sfx("rotLance", px, pz, 0.8)
	beam(tip, func() -> Variant: return end, LN["deep"], 0.03, 0.18)


## The lance landing on `hits` ([Vector3] of the enemies it pierced, ground y ignored).
func lance_hit(hits: Array) -> void:
	var LN := DmFxData.spell_group("lance")
	for h: Vector3 in hits:
		smoke(h.x, 0.9, h.z, 2, LN["spore"], 0.3, 0.5, 0.5, 0.6, 0.8, {"shrink": -0.3})
		emit(h.x, 1.0, h.z, 8, LN["rot"], 0.2, 2.0, 0.8, 0.45, 0.14, {"gravity": 3.0})
	if not hits.is_empty():
		sfx("needleHit", (hits[0] as Vector3).x, (hits[0] as Vector3).z, 0.7)


## Marrow Spear: flash + beam at the staff tip.
func spear_cast(tip: Vector3, end: Vector3) -> void:
	var S := DmFxData.spell_group("spear")
	flash(tip.x, tip.y, tip.z, S["bone"], 0.65, 0.12)
	beam(tip, func() -> Variant: return end, S["bone"], 0.025, 0.16)


## The spear line landing (ev: ox, oz, dx, dz, rng, radius, mult, end, hits). Returns the camera shake.
func spear_line(ev: Dictionary) -> float:
	var S := DmFxData.spell_group("spear")
	var ox := float(ev["ox"])
	var oz := float(ev["oz"])
	var dx := float(ev["dx"])
	var dz := float(ev["dz"])
	var rng_m := float(ev["rng"])
	var radius := float(ev["radius"])
	var mult := float(ev["mult"])
	var end: Vector3 = ev["end"]
	for h: Vector3 in ev["hits"]:
		flash(h.x, 0.8, h.z, S["bone"], 0.65, 0.14)
	spike_line(ox, oz, dx, dz, rng_m, radius * 1.3, false)
	decal("cracks", S["crack"], ox + dx * rng_m * 0.5, oz + dz * rng_m * 0.5, rng_m * 0.5, 0.65, 0.55, {"sx": 0.16 * mult, "rot": atan2(dx, dz)})
	for i in range(1, 7):
		var x := ox + dx * (float(i) / 6.0) * rng_m
		var z := oz + dz * (float(i) / 6.0) * rng_m
		emit(x, 0.3, z, 3, S["bone"], 0.25, 1.4, 2.1, 0.4, 0.12, {"gravity": 9.0})
		if i % 2 == 0:
			dirt(x, z, radius * 0.8, int(4.0 * mult))
	splinters(end.x, 0.6, end.z, 6, S["bone"], 4.5)
	lf(ox + dx * 4.0, 1.0, oz + dz * 4.0, S["crack"], 12.0, 0.22)
	sfx("spear", ox + dx * 3.0, oz + dz * 3.0)
	return 0.055


## Ossuary Ring rune (ev: cx, cz, r, hits). Returns the camera shake.
func spear_ring(ev: Dictionary) -> float:
	var S := DmFxData.spell_group("spear")
	var cx := float(ev["cx"])
	var cz := float(ev["cz"])
	var r := float(ev["r"])
	for h: Vector3 in ev["hits"]:
		flash(h.x, 0.8, h.z, S["bone"], 0.65, 0.14)
	spike_ring(cx, cz, r * 0.95, DmMath.js_round(10.0 + r * 3.0), 1.1)
	spike_ring(cx, cz, r * 0.5, 6, 0.9)
	decal("ring", S["bone"], cx, cz, r * 1.05, 0.7, 0.85, {"growFrom": 0.3})
	decal("cracks", S["crack"], cx, cz, r, 0.8, 0.6, {"rot": randf() * 6.0})
	dirt(cx, cz, r * 0.8, 8, 3.0)
	splinters(cx, 0.6, cz, 8, S["bone"], 4.5)
	lf(cx, 1.0, cz, S["crack"], 14.0, 0.25)
	sfx("spear", cx, cz)
	return 0.07


## Impaling rune (ev: ox, oz, dx, dz, rng, tx, tz, along, hit, root_s). `hit` false = the spear found nothing. Returns the camera shake.
func spear_impale(ev: Dictionary) -> float:
	var S := DmFxData.spell_group("spear")
	var ox := float(ev["ox"])
	var oz := float(ev["oz"])
	var dx := float(ev["dx"])
	var dz := float(ev["dz"])
	if not bool(ev["hit"]):
		var rng_m := float(ev["rng"])
		spike_line(ox, oz, dx, dz, 2.0, 0.6, false)
		dirt(ox + dx * rng_m, oz + dz * rng_m, 0.6, 4)
		sfx("spear", ox + dx * rng_m, oz + dz * rng_m)
		return 0.0
	var tx := float(ev["tx"])
	var tz := float(ev["tz"])
	var root_s := float(ev["root_s"])
	spike_ring(tx, tz, 0.95, 9, root_s + 0.1)
	decal("ring", S["crack"], tx, tz, 1.3, root_s, 0.7, {"growFrom": 0.5, "fadeOut": 0.4})
	spike_line(ox, oz, dx, dz, maxf(1.5, float(ev["along"])), 0.5, false)
	flash(tx, 1.0, tz, S["bone"], 1.4, 0.2)
	splinters(tx, 1.0, tz, 8, S["bone"], 4.5)
	lf(tx, 1.0, tz, S["crack"], 14.0, 0.25)
	sfx("spear", tx, tz)
	return 0.06


## Wailing Skull: the cast flash + wail at the staff tip.
func skull_cast(tip: Vector3, px: float, pz: float) -> void:
	flash(tip.x, tip.y, tip.z, DmFxData.spell("skull", "jade"), 0.9, 0.18)
	sfx("wail", px, pz)


## One skull in flight: the sprite shot (follows `to`) + its billboard glow. `more` = another leap follows (the old game's wail on the leap's start).
func skull_leap(from: Vector3, to: Variant, speed: float) -> void:
	var jade := DmFxData.spell("skull", "jade")
	var h: Variant = shot(from, to, speed, 0.0, "sprite", jade, {"tex": "skull", "size": 0.95, "trail": jade})
	bb("wailing_skull_projectile", from.x, from.z, {"y": from.y, "follow": Callable(h, "pos") if h != null else Callable()})


## A skull landing (pos, killed = the blow killed it: bigger burst).
func skull_hit(pos: Vector3, killed: bool, more: bool) -> void:
	var SK := DmFxData.spell_group("skull")
	sfx("needleHit", pos.x, pos.z, 1.2)
	flash(pos.x, pos.y, pos.z, SK["pale"], 1.9 if killed else 1.3, 0.22, {"tex": "skull"})
	decal("ring", SK["jade"], pos.x, pos.z, 0.9, 0.4, 0.9, {"growFrom": 0.3})
	emit(pos.x, pos.y, pos.z, 18 if killed else 10, SK["jade"], 0.2, 2.4, 1.4, 0.5, 0.22, {"gravity": -1.0})
	splinters(pos.x, pos.y, pos.z, 6 if killed else 3, SK["pale"])
	if more:
		sfx("wail", pos.x, pos.z, 0.6)


## Ivory Cleave (ev: x, z, dx, dz, hits). Returns the camera shake.
func cleave(ev: Dictionary) -> float:
	var S := DmFxData.spell_group("spear")
	var x := float(ev["x"])
	var z := float(ev["z"])
	var dx := float(ev["dx"])
	var dz := float(ev["dz"])
	var k := 0
	for h: Vector3 in ev["hits"]:
		k += 1
		emit(h.x, 0.9, h.z, 5, S["bone"], 0.2, 2.4, 1.1, 0.35, 0.12, {"gravity": 8.0})
		if k <= 2:
			bb("ivory_cleave_hit", h.x, h.z)
	var rot := atan2(dx, dz)
	decal("crescent", S["bone"], x + dx * 1.5, z + dz * 1.5, 2.2, 0.45, 1.0, {"rot": rot, "growFrom": 0.6, "fadeOut": 0.3})
	decal("crescent", S["crack"], x + dx * 1.6, z + dz * 1.6, 2.4, 0.35, 0.6, {"rot": rot, "growFrom": 0.7})
	lf(x + dx * 1.5, 1.0, z + dz * 1.5, S["crack"], 14.0, 0.2)
	sfx("ivoryCleave", x, z, 1.3)
	if not (ev["hits"] as Array).is_empty():
		sfx("boneHit", x + dx * 2.0, z + dz * 2.0)
	return 0.05


## Bone Storm begins: `follow` -> Vector3 (ground point) or null when it is over. Returns the handles [bones, dust, ring] so the caller can end them early.
func storm_start(life: float, r: float, follow: Callable, x: float, z: float) -> Array:
	var BS := DmFxData.spell_group("storm")
	var B: Dictionary = DmCombatData.const_table("BONE_STORM")
	var bones: Variant = null
	if fx != null:
		stats["bone_orbit"] += 1
		bones = fx.bone_orbit({"fallbackTex": "boneShard", "fallbackColor": BS["bone"], "count": int(B["shards"]), "radius": r * 0.8, "y": 0.25, "size": 0.34, "duration": life,
			"speed": 7.0, "follow": follow, "funnel": true})
	var dust: Variant = bb("bone_storm_dust", x, z, {"follow": follow, "duration": life, "colors": [BS["bone"], BS["ash"], BS["dust"]]})
	var ring: Variant = decal("ring", BS["ash"], x, z, r, life, 0.35, {"spin": 2.0, "fadeOut": 0.4, "follow": follow})
	sfx("storm", x, z)
	loop("boneStormLoop", life * 1000.0, x, z)
	return [bones, dust, ring]


## One storm pulse at (x, z) with radius r; `hit` = it struck something.
func storm_tick(x: float, z: float, r: float, hit: bool) -> void:
	var BS := DmFxData.spell_group("storm")
	if hit:
		sfx("boneHit", x, z)
	smoke(x, 0.4, z, 3, BS["ash"], r * 0.4, 0.9, 1.4, 0.9, 1.1, {"shrink": -0.4})
	splinters(x, 0.8, z, 6 if hit else 3, BS["bone"], r * 1.2)
	dirt(x, z, r * 0.5, 3, 3.0)


## Soul Siphon begins: tether beams from `cas` (caster point) to `tgt` (target point), both Callables -> Vector3 or null. Returns [beams, core, rim].
func siphon_start(dur: float, cas: Callable, tgt: Callable, px: float, pz: float) -> Array:
	var SI := DmFxData.spell_group("siphon")
	var beams: Array = [beam(cas, tgt, SI["deep"], 0.1, dur), beam(cas, tgt, SI["jade"], 0.055, dur), beam(cas, tgt, SI["pale"], 0.02, dur)]
	var first: Variant = tgt.call()
	var core: Variant = null
	if first != null:
		core = bb("soul_orb", first.x, first.z, {"y": first.y, "follow": tgt, "duration": dur, "colors": [SI["jade"], SI["pale"], SI["deep"]]})
	var rim: Variant = bb("soul_siphon_beam", px, pz, {"follow": cas, "duration": dur})
	sfx("siphon", px, pz)
	loop("siphonLoop", dur * 1000.0, px, pz, cas)
	return [beams, core, rim]


## One drain tick: motes along the tether (q = target point, c = caster point), `odd` = every other tick draws a rising skull.
func siphon_tick(q: Vector3, c: Vector3, odd: bool) -> void:
	var SI := DmFxData.spell_group("siphon")
	for k in 6:
		var f := (float(k) + randf()) / 6.0
		emit(q.x + (c.x - q.x) * f, q.y + (1.4 - q.y) * f, q.z + (c.z - q.z) * f, 1, SI["pale"] if k % 2 == 1 else SI["jade"], 0.08, 0.2, 0.1, 0.3, 0.22)
	emit(q.x, q.y, q.z, 5, SI["pale"], 0.25, 0.6, 0.3, 0.35, 0.16)
	emit(c.x, 1.3, c.z, 3, SI["jade"], 0.2, 0.3, 0.6, 0.4, 0.18)
	if odd:
		skulls(q.x, q.z, SI["pale"], {"n": 1, "y": q.y + 0.3, "size": 0.5, "rise": 0.9, "duration": 0.7})


# --- Grave Step ---------------------------------------------------------------------------------------------------------------------------

## The blood-mist leaving (ox, oz). The caster's gesture (current game) goes between this and `step_arrive`.
func step_depart(ox: float, oz: float) -> void:
	var ST := DmFxData.spell_group("step")
	smoke(ox, 0.9, oz, 6, ST["mist"], 0.45, 0.7, 0.7, 0.75, 1.2, {"shrink": -0.4})
	emit(ox, 1.0, oz, 18, ST["blood"], 0.4, 2.2, 1.2, 0.45, 0.2, {"gravity": 6.0})
	decal("bloodSigil", ST["crimson"], ox, oz, 1.2, 0.8, 0.85, {"growFrom": 0.6})
	dirt(ox, oz, 0.5, 6)
	motes(ox, oz, ST["blood"], 0.4, 4, 1.4)
	bb("grave_step_smoke", ox, oz, {"duration": 1.4})


## The re-forming at (x, z): a beam from the old spot to `follow` (the caster's point), a flash on each struck enemy `flash_pts` [[x, z]], the burst.
func step_arrive(ox: float, oz: float, x: float, z: float, follow: Callable, flash_pts: Array) -> void:
	var ST := DmFxData.spell_group("step")
	beam(Vector3(ox, 1.0, oz), follow, ST["blood"], 0.07, 0.22)
	for pt: Array in flash_pts:
		flash(pt[0], 0.9, pt[1], ST["blood"], 0.7, 0.16)
	var rr := float(DmCombatData.const_table("GRAVE_STEP")["burstRadius"])
	decal("bloodSigil", ST["blood"], x, z, rr * 1.15, 0.9, 1.0, {"growFrom": 0.25, "spin": 0.8})
	decal("ring", ST["crimson"], x, z, rr * 1.05, 0.4, 0.9, {"growFrom": 0.15})
	emit(x, 0.6, z, 26, ST["blood"], 0.3, rr * 2.6, 1.4, 0.5, 0.26, {"drag": 1.5})
	emit(x, 0.8, z, 8, ST["hot"], 0.2, 2.0, 2.2, 0.35, 0.18)
	smoke(x, 0.5, z, 5, ST["mist"], rr * 0.4, 1.2, 0.5, 0.8, 1.2, {"shrink": -0.4})
	lf(x, 1.2, z, ST["blood"], 30.0, 0.35)
	dirt(x, z, rr * 0.5, 8, 3.0)
	splinters(x, 0.5, z, 6, DmFxData.hex(int(DmFxData.data()["necro_matter"]["bone"])))
	bb("grave_step_smoke", x, z, {"scale": 1.2, "duration": 1.4})
	sfx("bloodStep", x, z)


# --- Veil Step ----------------------------------------------------------------------------------------------------------------------------

## The slip from (fx0, fz0) to (tx, tz): a streak, smoke and a ring at the end.
func veil(fx0: float, fz0: float, tx: float, tz: float) -> void:
	var VL := DmFxData.spell_group("veil")
	var dist := Vector2(tx - fx0, tz - fz0).length()
	var rot := atan2(tx - fx0, tz - fz0)
	decal("veilStreak", VL["jade"], (fx0 + tx) / 2.0, (fz0 + tz) / 2.0, dist / 2.0 + 0.4, 0.6, 0.85, {"sx": 0.35, "rot": rot, "fadeOut": 0.45})
	smoke(fx0, 0.9, fz0, 4, VL["deep"], 0.4, 0.5, 0.5, 0.6, 1.0, {"shrink": -0.3})
	emit(fx0, 1.0, fz0, 12, VL["pale"], 0.3, 1.6, 0.8, 0.4, 0.14)
	bb("veil_step_trail", fx0, fz0, {"duration": 0.6, "rot": rot})
	decal("ring", VL["jade"], tx, tz, 1.0, 0.45, 0.9, {"growFrom": 0.2})
	lf(tx, 1.2, tz, VL["jade"], 14.0, 0.25)
	sfx("veilStep", fx0, fz0, 1.3)


# --- Grave Frost --------------------------------------------------------------------------------------------------------------------------

## The cone's cast (after the gesture): muzzle flash at `tip` [x, y, z], the fan along (dx, dz) from (ox, oz) for `ln` metres, mist, cracks, sound.
func frost_cast(tip: Array, ox: float, oz: float, dx: float, dz: float, ln: float) -> void:
	var FR := DmFxData.spell_group("frost")
	var rot := atan2(dx, dz)
	flash(tip[0], tip[1], tip[2], FR["pale"], 0.8, 0.14)
	decal("frostFan", FR["frost"], ox + dx * ln * 0.5, oz + dz * ln * 0.5, ln * 0.5, 0.9, 0.95, {"rot": rot + PI, "growFrom": 0.35, "fadeIn": 0.08, "fadeOut": 0.45})
	for i in range(1, 5):
		var k := float(i) / 4.0
		smoke(ox + dx * ln * k * 0.8, 0.7, oz + dz * ln * k * 0.8, 2, 0xb9cbe6, 0.4 + k * 1.4, 0.6, 0.3, 0.7, 1.0 + k * 0.6, {"shrink": -0.4, "drag": 1.0})
		emit(ox + dx * ln * k * 0.85, 0.8, oz + dz * ln * k * 0.85, 5, FR["pale"], 0.3 + k * 1.2, 1.2, 0.4, 0.45, 0.14)
	sfx("frost", ox + dx * 2.0, oz + dz * 2.0)
	if fx != null:
		stats["motif"] += 4
		fx.motifs.cracked_ground(ox + dx * ln * 0.5, oz + dz * ln * 0.5, ln * 0.5, FR["pale"], {"rot": rot, "sx": 0.5, "duration": 1.8, "opacity": 0.4})
		for i in range(1, 4):
			fx.motifs.mist_whisper(ox + dx * ln * i * 0.28, oz + dz * ln * i * 0.28, 0x8fa6c8, {"r": 0.5 + i * 0.5, "n": 2})
	bb("grave_frost_mist", ox + dx * ln * 0.45, oz + dz * ln * 0.45, {"rot": rot})


## The cone landing. `seen` = [{x, z, scale, shatter}] (the first 14 are drawn), (px, pz) = where the bolt arrived. Sound when any shattered.
func frost_hits(seen: Array, ox: float, oz: float, dx: float, dz: float, ln: float, px: float, pz: float) -> void:
	var FR := DmFxData.spell_group("frost")
	var shown := 0
	var shattered := 0
	for s: Dictionary in seen:
		shown += 1
		if s["shatter"]:
			shattered += 1
		if shown <= 14:
			decal("rime", FR["frost"], s["x"], s["z"], 0.75 * float(s["scale"]), 1.4, 0.9, {"rot": randf() * 6.0, "growFrom": 0.4})
			if s["shatter"]:
				if shown <= 3:
					bb("frost_shard_hit", s["x"], s["z"])
				flash(s["x"], 1.0, s["z"], FR["pale"], 1.2, 0.18)
				emit(s["x"], 1.0, s["z"], 10, FR["pale"], 0.2, 3.4, 2.0, 0.5, 0.13, {"gravity": 10.0})
				if shown <= 4:
					splinters(s["x"], 1.0, s["z"], 4, FR["pale"])
	lf(ox + dx * ln * 0.5, 1.0, oz + dz * ln * 0.5, FR["frost"], 18.0, 0.3)
	if shattered > 0:
		sfx("needleHit", px, pz, 1.4)


# --- Bone Prison --------------------------------------------------------------------------------------------------------------------------

## The ring of spikes bursting at (x, z) with radius rr (after the gesture).
func prison(x: float, z: float, rr: float) -> void:
	var PR := DmFxData.spell_group("prison")
	var P: Dictionary = DmSimData.BONE_PRISON
	if fx != null:
		stats["spikes"] += 1
		fx.spike_ring(x, z, rr, int(P["spikes"]), float(P["rootS"]) + 0.1)
	decal("cracks", PR["dust"], x, z, rr * 1.1, float(P["rootS"]) + 0.4, 0.8, {"rot": randf() * 6.0, "growFrom": 0.6, "fadeOut": 0.4})
	decal("boneRing", PR["amber"], x, z, rr + 0.3, float(P["rootS"]), 0.4, {"growFrom": 0.8, "fadeOut": 0.3})
	smoke(x, 0.3, z, 6, PR["dust"], rr * 0.8, 0.9, 0.5, 0.9, 1.1)
	emit(x, 0.4, z, 18, PR["bone"], rr, 1.8, 2.2, 0.5, 0.12, {"gravity": 9.0})
	for i in 6:
		var a := (float(i) / 6.0) * TAU
		dirt(x + cos(a) * rr * 0.9, z + sin(a) * rr * 0.9, 0.35, 3)
	splinters(x, 0.9, z, 10, PR["bone"], rr * 1.6)
	bb("bone_prison_burst", x, z, {"scale": rr / 2.4})
	sfx("prison", x, z)


# --- Grave Hands --------------------------------------------------------------------------------------------------------------------------

## The field rising at (x, z) (after the gesture). Returns {hands, ground, seep} handles for `hands_end`.
func hands_start(x: float, z: float, rr: float, hands: int, dur: float) -> Dictionary:
	var GH := DmFxData.spell_group("hands")
	var vis: Dictionary = {"hands": null, "ground": null, "seep": null}
	if fx != null:
		stats["hands"] += 1
		vis["hands"] = fx.grave_hands(x, z, rr, hands, dur)
	vis["ground"] = decal("disc", GH["earth"], x, z, rr, dur, 0.7, {"growFrom": 0.5, "fadeOut": 0.4})
	vis["seep"] = decal("cracks", GH["seep"], x, z, rr * 0.95, dur, 0.35, {"rot": randf() * 6.0, "pulse": 2.0, "fadeOut": 0.4})
	smoke(x, 0.2, z, 8, GH["earth"], rr * 0.7, 0.8, 0.6, 1.0, 1.2)
	for i in 5:
		var a := float(i) * 2.4
		dirt(x + cos(a) * rr * 0.55, z + sin(a) * rr * 0.55, 0.4, 3)
	bb("grave_hands_pulse", x, z, {"scale": rr / 3.5})
	sfx("hands", x, z)
	loop("handsLoop", 3000.0, x, z)
	return vis


## One 0.5 s rake: a spray under each of the first 4 struck enemies `pts` [[x, z]], a mote somewhere in the field.
func hands_tick(x: float, z: float, rr: float, pts: Array) -> void:
	var GH := DmFxData.spell_group("hands")
	for k in mini(4, pts.size()):
		emit(pts[k][0], 0.4, pts[k][1], 3, GH["bone"], 0.3, 1.2, 1.2, 0.35, 0.1, {"gravity": 8.0})
	var a := randf() * TAU
	var d := sqrt(randf()) * rr * 0.85
	motes(x + cos(a) * d, z + sin(a) * d, GH["seep"], 0.25, 2, 0.9, 0.15)


func hands_end(vis: Dictionary) -> void:
	for k in ["hands", "ground", "seep"]:
		kill(vis.get(k))


# --- Rally the Dead -----------------------------------------------------------------------------------------------------------------------

## The sigil under the caster (cast time).
func rally_cast(px: float, pz: float) -> void:
	decal("rallySigil", DmFxData.spell("rend", "jade"), px, pz, 2.4, 0.8, 0.9, {"growFrom": 0.4, "spin": 1.0})


## The rally the host reported (ev: x, z, ids = the thralls). `follow` = the caster's point (Vector3 / null), `thrall_at(id) -> Vector3 | null` = where a
## rallied thrall stands (null once it is gone or the rally ended): a beam from the caster and a sigil + rim that follow each thrall.
func rally(ev: Dictionary, follow: Callable, thrall_at: Callable) -> void:
	var RD := DmFxData.spell_group("rend")
	var dur := float(DmSimData.RALLY["durationS"]) + float(DmSimData.RALLY["gravecallerBonusS"])
	for id in ev["ids"]:
		var tid := int(id)
		var at := func() -> Variant: return thrall_at.call(tid)
		var fv: Variant = follow.call() if follow.is_valid() else null
		var fx_ := Vector3(ev["x"], 0.0, ev["z"]) if fv == null else (fv as Vector3)
		var beam_end := func() -> Variant:
			var a: Variant = at.call()
			return Vector3(a.x, 1.0, a.z) if a != null else null
		beam(Vector3(fx_.x, 1.2, fx_.z), beam_end, RD["jade"], 0.04, 0.45)
		decal("rallySigil", RD["jade"], 0.0, 0.0, 0.7, dur, 0.7, {"spin": 1.4, "fadeOut": 0.4, "follow": at})
		var a0: Variant = at.call()
		if a0 != null:
			bb("rally_thrall_rim", a0.x, a0.z, {"follow": at, "duration": dur})
	lf(float(ev["x"]), 1.2, float(ev["z"]), RD["jade"], 18.0, 0.3)
	bb("rally_area", float(ev["x"]), float(ev["z"]))
	sfx("rallyDead", float(ev["x"]), float(ev["z"]))


# --- Discipline signatures (rebuild only; the current game draws these in DmAbilitySystem / DmEventFx) ---------------------------------------

const SIG_LOOK := {"wall": ["amber", "sigWall"], "rend": ["jade", "sigRend"], "dirge": ["frost", "sigDirge"], "bloom": ["petal", "sigBloom"]}
static var _rib: CylinderMesh = null


## The cast flourish every signature shares: sparks + light at the staff tip and its sound; the Dirge / Bloom start their bed. `sig` = wall rend dirge bloom.
func signature_cast(sig: String, tip: Vector3) -> void:
	var look: Array = SIG_LOOK[sig]
	var color := DmFxData.spell(sig, look[0])
	emit(tip.x, 1.4, tip.z, 24, color, 0.4, 1.6, 1.2, 0.6, 0.24)
	lf(tip.x, 1.8, tip.z, color, 24.0, 0.4)
	sfx(look[1], tip.x, tip.z)
	if sig == "dirge":
		loop("dirgeLoop", 4000.0, tip.x, tip.z)
	elif sig == "bloom":
		loop("bloomPulse", 6000.0, tip.x, tip.z)


## Ossuary Wall: the ribs tear out of the ground along (x0, z0)-(x1, z1). Returns the MultiMesh node for the caller to parent and free (null without a back-end).
func wall_raise(x0: float, z0: float, x1: float, z1: float, node_name: String) -> MultiMeshInstance3D:
	var bone := DmFxData.spell("wall", "bone")
	var length := Vector2(x1 - x0, z1 - z0).length()
	var n := maxi(6, DmMath.js_round(length * 2.2))
	if _rib == null:
		_rib = CylinderMesh.new()
		_rib.top_radius = 0.0
		_rib.bottom_radius = 0.22
		_rib.height = 1.0
		_rib.radial_segments = 5
		_rib.rings = 1
		var mat := StandardMaterial3D.new()
		mat.albedo_color = bone
		mat.roughness = 0.8
		mat.emission_enabled = true
		mat.emission = DmFxData.spell("wall", "amber")
		mat.emission_energy_multiplier = 0.08
		_rib.material = mat
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = _rib
	mm.instance_count = n
	for i in n:
		var t := (float(i) + 0.5) / float(n)
		var h := 1.4 + float((i * 7919) % 5) * 0.18
		var eul := Vector3(float((i % 3) - 1) * 0.18, float(i) * 1.3, float((i % 2) * 2 - 1) * 0.12)
		mm.set_instance_transform(i, Transform3D(Basis.from_euler(eul, EULER_ORDER_XYZ) * Basis.from_scale(Vector3(1.0, h, 1.0)), Vector3(x0 + (x1 - x0) * t, h / 2.0, z0 + (z1 - z0) * t)))
	var node := MultiMeshInstance3D.new()
	node.multimesh = mm
	node.name = node_name
	for i in 7:   # the wall tears out of the grave: bone chips and soil along its foot, a crack beneath it
		var t := float(i) / 6.0
		emit(x0 + (x1 - x0) * t, 0.3, z0 + (z1 - z0) * t, 6, bone, 0.3, 1.5, 2.5, 0.6, 0.14, {"gravity": 9.0})
	var cx := (x0 + x1) / 2.0
	var cz := (z0 + z1) / 2.0
	if fx != null:
		stats["motif"] += 7
		for i in 5:
			fx.motifs.grave_dirt(x0 + (x1 - x0) * float(i) / 4.0, z0 + (z1 - z0) * float(i) / 4.0, {"r": 0.4, "n": 3})
		fx.motifs.bone_splinters(cx, 1.0, cz, {"n": 8, "color": bone, "speed": 4.5})
		fx.motifs.cracked_ground(cx, cz, length * 0.5, DmFxData.spell("wall", "dust"), {"rot": atan2(x1 - x0, z1 - z0), "sx": 0.22, "duration": 2.2, "opacity": 0.6})
	sfx("boneHit", cx, cz)
	return node


## The wall crumbles to dust.
func wall_gone(cx: float, cz: float) -> void:
	smoke(cx, 0.6, cz, 16, DmFxData.spell("wall", "dust"), 2.4, 0.8, 0.8, 1.4, 1.6)


## Command: Rend. `leaps` = [[from_x, from_z, to_x, to_z]] per thrall; (x, z) the target point. `mine`: the caster's own legion draws full strength.
## Returns the camera shake.
func rend(leaps: Array, x: float, z: float, mine: bool) -> float:
	var jade := DmFxData.spell("rend", "jade")
	var bone := DmFxData.spell("rend", "bone")
	var pale := DmFxData.spell("rend", "pale")
	var own := "player" if mine else "thrall"
	for l: Array in leaps:
		var to := Vector3(float(l[2]), 0.8, float(l[3]))
		beam(Vector3(float(l[0]), 0.8, float(l[1])), func() -> Variant: return to, jade, 0.06, 0.35)
		emit(to.x, 0.6, to.z, 10, bone, 0.5, 3.0, 1.5, 0.5, 0.14, {"gravity": 8.0})
		if fx != null:   # the thrall's claw: bone chips and a spectral slash where it bites
			stats["motif"] += 2
			fx.motifs.bone_splinters(to.x, 0.8, to.z, {"n": 4, "color": bone, "origin": own})
			fx.motifs.slash_mark(to.x, to.z, pale, {"rot": atan2(to.x - float(l[0]), to.z - float(l[1])), "r": 1.0, "origin": own})
		bb("rend_impact", to.x, to.z)
	decal("ring", jade, x, z, 3.0, 0.5, 1.0, {"growFrom": 0.3})
	lf(x, 1.5, z, jade, 40.0, 0.4)
	sfx("boneHit", x, z)
	return 0.2 if mine else 0.0


## Dirge: the bell-song ground (radius r for `seconds`): cold-blue disc and ring, soul-lights, grave mist, the small toll.
func dirge_zone(x: float, z: float, r: float, seconds: float) -> void:
	var D := DmFxData.spell_group("dirge")
	decal("disc", D["deep"], x, z, r, seconds, 0.45, {"growFrom": 0.3, "fadeOut": 0.6})
	decal("ring", D["frost"], x, z, r * 0.95, seconds, 0.6, {"pulse": 6, "spin": 0.0, "fadeOut": 0.6})
	emit(x, 0.4, z, 30, D["pale"], r * 0.5, 0.6, 2.0, 1.0, 0.22)
	if fx != null:
		stats["motif"] += 2
		fx.motifs.mist_whisper(x, z, D["deep"], {"r": r * 0.6, "n": 3})
		fx.motifs.spirit_wisps(x, z, D["pale"], {"n": 3, "r": r * 0.6, "y": 0.3, "size": 0.8})
	sfx("tollSmall", x, z)
	bb("dirge_area", x, z, {"scale": r / 6.0})


## One heartbeat of the Dirge: a ring runs out from its centre as it mends.
func dirge_pulse(x: float, z: float, r: float) -> void:
	decal("ring", DmFxData.spell("dirge", "frost"), x, z, r, 0.5, 0.7, {"growFrom": 0.15, "fadeOut": 0.4})


## Plague Bloom: a chartreuse flower sigil (radius r for `seconds`) shedding spores.
func bloom_zone(x: float, z: float, r: float, seconds: float) -> void:
	var B := DmFxData.spell_group("bloom")
	decal("disc", B["rot"], x, z, r, seconds, 0.45, {"growFrom": 0.3, "fadeOut": 0.6})
	decal("sigil", B["petal"], x, z, r * 0.95, seconds, 0.6, {"pulse": 2, "spin": 0.9, "fadeOut": 0.6})
	emit(x, 0.4, z, 18, B["petal"], r * 0.5, 0.6, 1.2, 1.0, 0.22)
	if fx != null:
		stats["motif"] += 1
		fx.motifs.rot_spores(x, z, B["petal"], {"r": r * 0.7, "n": 12})
	bb("plague_bloom_area", x, z, {"scale": r / 2.4})


## A flower seeds the next one: a thread of petals runs from the old bloom to the corpse that becomes the new one.
func bloom_spread(x0: float, z0: float, x1: float, z1: float) -> void:
	var petal := DmFxData.spell("bloom", "petal")
	var to := Vector3(x1, 0.5, z1)
	beam(Vector3(x0, 0.5, z0), func() -> Variant: return to, petal, 0.05, 0.45)
	emit(x1, 0.5, z1, 10, petal, 0.3, 1.0, 1.0, 0.6, 0.18)


## A corpse in the Rotweaver's Miasma bursts (r metres): violet ring, spores, smoke.
func bloom_burst(x: float, z: float, r: float) -> void:
	var petal := DmFxData.spell("bloom", "petal")
	sfx("burst", x, z)
	decal("ring", Color.hex(0xb58cffff), x, z, r, 0.5, 1.0, {"growFrom": 0.2})
	emit(x, 0.6, z, 30, Color.hex(0xb58cffff), r * 0.5, 3.0, 1.5, 0.8, 0.35)
	smoke(x, 0.4, z, 8, Color.hex(0x3a2d55ff), r * 0.4, 1.2, 0.8, 1.4, 1.6, {"shrink": -1.0})
	if fx != null:
		stats["motif"] += 1
		fx.motifs.rot_spores(x, z, petal, {"r": r * 0.6, "n": 8})
