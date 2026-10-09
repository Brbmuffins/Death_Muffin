class_name DmAudioPacks
extends RefCounted
## Port of archive/legacy-web:src/audio/packs.ts: lazy-load groups for the recorded layer, plus per-id mixer bus and clip-length caps.
## Groups: core, ui, rites, world, amb (loaded once), boss, foot_<surface>, fam_<voice> (per area, released two areas later).

const _CORE := "needleCast needleHit boneHit thrallMelee thrallShot thrallMagic thrallDeath hurt playerDeath enemyDeath"
const _RITES := """needleCast needleHit boneHit spear exhume thrallRise miasma litany wail bloodStep frost mantle siphon prison hands storm
  soulRelease sigWall sigRend sigDirge sigBloom curse raise burst flail lantern chain pyre ward palm choir crow bloodRite veilRite spiritBolt
  rotLance boneFan ivoryCleave hollowCut veilStep rallyDead carrionSeed seedBurst graveOffering corpseExplode shieldBash graveSlam
  graveSlamLand bulwarkRaise bulwarkBlock oathUnbroken corpseVigil graveBrand thrallDeath thrallBind miasmaLoop siphonLoop handsLoop
  boneStormLoop dirgeLoop bloomPulse crowSwarmLoop thrallMelee thrallShot thrallMagic hurt playerDeath enemyDeath"""
const _BOSS := """bossToll bossSlam bossAwaken bossDefeat bossTell bossTellEarth bossTellWater bossTellRot bossTellFire bossPhase bossSummon
  nicheBreak slagSlam emberBurst emberThrow eliteDeath toll tollSmall wave surgeStart surgeCleared surgeFailed affixTell eliteAggro tellStrike"""
const _WORLD := """chop pick splash shovel reel sawpit kiln cook grind craft pickOre gatherHerb nodeDepleted gardenTend gardenPlant
  gardenHarvest gardenReady brewTick brewCraft craftWeapon craftArmor craftMagic forgeFire chestOpen vaultOpen vaultClose gate waystoneTravel
  recallStart recallCancel runeSocket drinkFlask drinkElixir eatMeal lootDrop lootDropRare lootDropEpic lootDropLegendary goldPileDrop"""
## Sounds whose build-up IS the sound (the web encoder keeps their start; kept for parity).
const _BUILDUP := """litany oathUnbroken playerDeath bossAwaken bossPhase bossDefeat bossSummon bossToll bossTell bossTellEarth bossTellWater
  bossTellRot bossTellFire toll tollSmall surgeStart surgeCleared surgeFailed waystoneTravel recallStart levelUp skillUp lootLegendary
  lootDropLegendary wave eliteAggro tellStrike affixTell eliteDeath"""

const GLOBAL_PACKS: Array[String] = ["core", "ui", "rites", "world", "amb"]

static var _sets: Dictionary = {}
static var _voice_re: RegEx
static var _by_pack: Dictionary = {}


static func _words(key: String, text: String) -> Dictionary:
	if not _sets.has(key):
		var d := {}
		for w in text.replace("\n", " ").split(" ", false):
			var t := w.strip_edges()
			if t != "":
				d[t] = true
		_sets[key] = d
	return _sets[key]


static func _re() -> RegEx:
	if _voice_re == null:
		_voice_re = RegEx.new()
		_voice_re.compile("^(enemyAttack|enemyDeath)(Beast|Humanoid|Brute|Spirit)$")
	return _voice_re


static func is_enemy_voice_attack_death(id: String) -> bool:
	return _re().search(id) != null


static func is_boss_set(id: String) -> bool:
	return _words("boss", _BOSS).has(id)


static func pack_of(id: String) -> String:
	var m := _re().search(id)
	if m != null:
		return "fam_" + m.get_string(2).to_lower()
	if id == "step":
		return "foot_stone"
	if id.begins_with("step"):
		return "foot_" + id.substr(4).to_lower()
	if _words("boss", _BOSS).has(id):
		return "boss"
	if _words("world", _WORLD).has(id):
		return "world"
	var d := DmAudioMap.defn(id)
	if d["bus"] == "ambience":
		return "amb"
	if _words("core", _CORE).has(id):
		return "core"
	if _words("rites", _RITES).has(id):
		return "rites"
	if d["bus"] == "ui":
		return "ui"
	return "core"


## Longest audible length (s) of an id's clip (the engine fades each id out at its own cap).
static func cap_seconds(id: String, layer: bool = false) -> float:
	var d := DmAudioMap.defn(id)
	if d.has("trim") and d["trim"].has("maxMs"):
		return (float(d["trim"].get("startMs", 0.0)) + float(d["trim"]["maxMs"])) / 1000.0
	if id.begins_with("step"):
		return 0.45
	if d.has("loopMs"):
		return 1.0
	if d["bus"] == "ambience":
		return 1.2
	if d["bus"] == "ui":
		return 1.4 if int(d["priority"]) >= 3 else 0.9
	if int(d["priority"]) >= 5 or pack_of(id) == "boss":
		return 2.6
	if d["bus"] == "voice":
		return 1.5
	return 1.5 if layer else 1.3


static func keeps_start(id: String) -> bool:
	var d := DmAudioMap.defn(id)
	return _words("buildup", _BUILDUP).has(id) or d["bus"] == "ambience" or d.has("loopMs") or id.begins_with("step") \
		or (_words("world", _WORLD).has(id) and not id.begins_with("lootDrop"))


## Mixer bus an id plays on (the map's sfx/voice/ui/ambience split the way mixer.ts PROFILES split them).
static func mix_bus_of(id: String) -> String:
	var d := DmAudioMap.defn(id)
	if d["bus"] == "ui":
		return "ui"
	if d["bus"] == "ambience" or id.begins_with("step"):
		return "ambience"
	if id.begins_with("thrall") and id != "thrallRise":
		return "thralls"
	var boss_enemy: bool = is_boss_set(id) and not id.begins_with("boss") and id != "slagSlam" and id != "eliteDeath" and id != "emberBurst" and id != "emberThrow"
	if d["bus"] == "voice" or is_enemy_voice_attack_death(id) or boss_enemy:
		return "enemies"
	if id in ["eliteDeath", "slagSlam", "emberBurst", "emberThrow", "enemyDeath", "tellStrike"]:
		return "enemies"
	return "combat"


## Clip names (`folder/name`) one id may play, layers included.
static func clips_of(id: String) -> Array[String]:
	var d := DmAudioMap.defn(id)
	var out: Array[String] = []
	for f in d["files"]:
		out.append(f)
	if d.has("layer"):
		for f in d["layer"]["files"]:
			out.append(f)
	return out


static func _index() -> void:
	if not _by_pack.is_empty():
		return
	for id in DmAudioMap.all():
		var pack := pack_of(id)
		if not _by_pack.has(pack):
			_by_pack[pack] = {}
		for c in clips_of(id):
			_by_pack[pack][c] = true


static func all_packs() -> Array[String]:
	_index()
	var out: Array[String] = []
	for k in _by_pack.keys():
		out.append(k)
	out.sort()
	return out


static func pack_clips(pack: String) -> Array[String]:
	_index()
	var out: Array[String] = []
	if _by_pack.has(pack):
		for k in _by_pack[pack].keys():
			out.append(k)
	return out


## Packs one area adds: its floor, the wading sound, its dead's voices and (outside safe areas) the boss moments.
static func area_packs(area_id: String) -> Array[String]:
	var out: Array[String] = ["foot_" + DmAudioMap.area_surface(area_id), "foot_water"]
	var area := DmContent.area(area_id)
	for e in area.get("enemies", []):
		var fam := DmAudioMap.enemy_voice(str(e["id"]))
		if fam != "" and not out.has("fam_" + fam):
			out.append("fam_" + fam)
	if not bool(area.get("safe", false)) and not out.has("boss"):
		out.append("boss")
	return out


## True when the map has no pack clip for this id (status keep): the older sound stays.
static func is_keep(id: String) -> bool:
	var d := DmAudioMap.defn(id)
	return d.get("status", "") == "keep" or d["files"].size() == 0
