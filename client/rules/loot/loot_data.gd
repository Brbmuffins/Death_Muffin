class_name DmLootData
extends RefCounted
## Content the loot rules read (areas' loot tables, enemy gold/xp, item meta, armour sets, rune pools, reagent drops, ...).
## Originally exported from the web game's TS content modules.
## Since the registry refactor this is DmDb.loot_view(): a projection of godot/data/content/* (no separate file), or set_content().


static var _c: Dictionary = {}

static func set_content(c: Dictionary) -> void:
	_c = c

static func content() -> Dictionary:
	if _c.is_empty():
		_c = DmDb.loot_view()
	return _c

static func bag_size() -> int:
	return int(content()["bagSlots"])

## Dictionary or {} when the id is unknown.
static func area(id: String) -> Dictionary:
	return content()["areas"].get(id, {})

static func enemy(id: String) -> Dictionary:
	return content()["enemies"][id]

## Item meta {name,type,rarity,sell,stack(null),offlineStats(null)} or {} when unknown (TS: ITEMS[id] undefined).
static func item(id: String) -> Dictionary:
	return content()["items"].get(id, {})

static func armor_discipline(id: String) -> Variant:
	return content()["armor"].get(id, null)

static func is_armor(id: String) -> bool:
	return content()["armor"].has(id)

static func is_necro_weapon(id: String) -> bool:
	return content()["necroWeapons"].has(id)

static func discipline_family(id: String) -> String:
	return str(content()["disciplineFamily"].get(id, ""))

static func difficulty_reward_mult(d: String) -> float:
	return float(content()["difficulty"][d])
