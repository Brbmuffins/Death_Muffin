class_name DmDevMock
extends RefCounted
## The local mock backend's records, set for a dev run, a test or a tool (the client's own, not a copy). The server owns a character's totals
## (DECISIONS B23): a save's reply puts back the level the server holds, so a character that plays at another level must have it on the server too.


## The character `ch` (the mock's answer to load_or_create_character) at `level`, on the mock's record and in `ch`.
static func set_level(mock: DmMockBackend, ch: Dictionary, level: int) -> void:
	for acc: Dictionary in mock.db["accounts"].values():
		var c: Variant = acc.get("character")
		if c is Dictionary and int(c["id"]) == int(ch["id"]):
			c["level"] = level
	ch["level"] = level
