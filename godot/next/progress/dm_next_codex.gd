class_name DmNextCodex
extends Node
## The Codex journal of the rebuild (child "Codex" of DmNextGame): what this character has met. Discoveries come from events only: an enemy kind the
## first time one stands within 40 m of the local hero (every spawn on every peer), a boss the moment it wakes, an area on entry (DmAreaFlow). The
## journal is the HUD's `ui.codex_journal` (the Codex panel's "the dead" and "the diocese" read it): each discovery is sent to it as the `codex` game
## event, and the set is kept per character in the local store (the web's CodexJournal lives in localStorage) so a relaunch remembers it.

signal discovered(kind: String, id: String)

const NEAR := 40.0                                ## the reference's EventFx rule: only what this player actually encounters
const KEY := "dm_codex_v1:"

var game: Node
var found := {"dead": {}, "area": {}}
var store: DmCounselStore
var _hero_id := 0


func setup(game_: Node, store_: DmCounselStore) -> void:
	game = game_
	store = store_
	_hero_id = int(game.character.get("id", 0))
	var raw := store.get_item(KEY + str(_hero_id))
	if raw != "":
		var d: Variant = JSON.parse_string(raw)
		if d is Dictionary:
			for kind in found:
				for id in d.get(kind, []):
					found[kind][String(id)] = true
	game.enemy_spawned.connect(_on_spawn)
	game.bosses.boss_spawned.connect(func(b: DmBoss) -> void: discover("dead", b.boss_id))


func has(kind: String, id: String) -> bool:
	return found[kind].has(id)


## Records a discovery; true only the first time. The HUD hears it (a late-built HUD is seeded by `seed_ui`).
func discover(kind: String, id: String, notify: bool = true) -> bool:
	if not found.has(kind) or id == "" or found[kind].has(id):
		return false
	found[kind][id] = true
	store.set_item(KEY + str(_hero_id), JSON.stringify({"dead": found["dead"].keys(), "area": found["area"].keys()}))
	if notify:
		_to_ui(kind, id)
	discovered.emit(kind, id)
	return true


## The HUD was built after the journal was loaded: hand it everything known.
func seed_ui() -> void:
	for kind in found:
		for id in found[kind]:
			_to_ui(kind, id)


func _to_ui(kind: String, id: String) -> void:
	var ui: Node = game.get("ui_host")
	if ui != null:
		ui.game_event.emit("codex", {"kind": kind, "id": id})


func _on_spawn(e: DmEnemy) -> void:
	if e is DmBoss or found["dead"].has(e.def_id):
		return
	var b: DmHeroBody = game.local_body()
	if b != null and b.position.distance_to(e.position) < NEAR:
		discover("dead", e.def_id)
