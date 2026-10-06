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


# --- Miasma Circle -----------------------------------------------------------------------------------------------------------------------

## The cloud settling at (x, z) with radius r. `creep` = the Creeping Rot rune (no cloud model, the zone itself moves).
func miasma_land(x: float, z: float, r: float, creep: bool = false) -> void:
	var M := DmFxData.spell_group("miasma")
	decal("ring", M["rot"], x, z, r, 0.45, 0.7, {"growFrom": 0.2})
	sfx("miasma", x, z)
	loop("miasmaLoop", 6000.0, x, z)
	smoke(x, 0.4, z, 6, M["spore"], r * 0.6, 0.5, 0.3, 0.9, 1.1, {"shrink": -0.3, "drag": 0.8})
	emit(x, 0.3, z, 16, M["rot"], r * 0.5, 1.1, 0.6, 0.65, 0.18)
	if fx != null:
		stats["motif"] += 1
		fx.motifs.rot_spores(x, z, M["rot"], {"r": r * 0.75, "n": DmMath.js_round(8.0 + r * 2.0)})
	if not creep:
		bb("miasma_cloud", x, z, {"scale": r / 3.8})


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
