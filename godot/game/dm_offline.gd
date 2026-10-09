class_name DmOffline
extends RefCounted
## The dev-offline mode's backend: DmMockBackend (accounts and saves under user://dm_offline_db.json, no live server) with the item
## catalogue filled from the game content (the web's MOCK_ITEMS), so gear equips and stats work. `keep` holds the mock alive.

static func make_mock(path: String = "user://dm_offline_db.json") -> DmMockBackend:
	var mock := DmMockBackend.new(path)
	var cat := {}
	var items: Dictionary = DmContent.items()
	for id in items:
		var m: Dictionary = items[id]
		cat[id] = {"name": m.get("name", id), "item_type": m.get("type", "material"), "rarity": m.get("rarity", "common"),
			"stat_bonus": m.get("offlineStats"), "sell_value": int(m.get("sell", 0))}
	mock.catalog = cat
	return mock


static func make_api(mock: DmMockBackend) -> DmApi:
	var api := DmApi.new(mock.transport_callable())
	api.base_url = ""
	api.slot_decorator = Callable(DmAffixes, "decorate_slots")
	return api
