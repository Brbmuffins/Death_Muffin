class_name DmRiteFx
extends RefCounted
## The per-rite visuals and sounds of Bone Needle and Miasma Circle, shared by the current game (DmAbilitySystem delegates here, behaviour and
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
func shot(from: Vector3, to: Variant, speed: float, arc: float, kind: String, color: Color) -> Variant:
	stats["projectile"] += 1
	if fx == null:
		return null
	var to_fn: Callable = to if to is Callable else (func() -> Variant: return to)
	return fx.projectile({"from": from, "to": to_fn, "speed": speed, "color": color, "kind": kind, "arc": arc})
