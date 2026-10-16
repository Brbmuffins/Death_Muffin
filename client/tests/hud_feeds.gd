class_name HudFeeds
extends RefCounted
## What every piece of the HUD can show at once: the view-model keys of the systems that are not in the game scene yet (belt, Kill Chain, Omen, prompt, Depths, the Next
## line, auto combat, a party of four) and the panels' doors. Shared by the HUD test and the draw-call measurement (tools/hud_measure.gd), merged over the view-model they apply.


static func full() -> Dictionary:
	return {
		"reveal": {},
		"chain": {"count": 12, "name": "Chain", "bonus": 0.1, "frac": 0.6, "tier": 2},
		"omen": {"name": "Omen of Ash", "icon": DmGameHud.art("omens/tolling.webp"), "blurb": "Blurb", "visible": true},
		"brews": [
			{"slot": "heal", "key": "Q", "label": "Heal", "glyph": "✚", "color": 0xe0709c, "active": false, "left": 0, "frac": 0.3, "count": 3, "empty": false, "tip": "Healing"},
			{"slot": "elixir", "key": "Z", "label": "Elixir", "glyph": "⚗", "color": 0x8a8aa0, "active": true, "left": 20, "frac": 0.6, "count": 2, "empty": false, "tip": "Elixir"},
			{"slot": "tonic", "key": "X", "label": "Tonic", "glyph": "✧", "color": 0x8a8aa0, "active": false, "left": 0, "frac": 0.0, "count": 0, "empty": true, "tip": "Tonic"}],
		"prompt": "<kbd>E</kbd> Talk to the Warden",
		"depth": {"depth": 3, "kills": 10, "need": 24, "open": false, "chest": true},
		"next": "Walk north to the Hollow Graves",
		"auto_combat": {"on": true, "available": true, "visible": true},
		"party": [
			{"id": 1, "name": "tester", "discipline": "Gravecaller · Level 20", "portrait": DmGameHud.art("portraits/gravecaller.webp"), "hp_frac": 0.8},
			{"id": 2, "name": "Helix", "discipline": "Ossuary · Level 31", "portrait": DmGameHud.art("portraits/ossuary.webp"), "hp_frac": 0.5},
			{"id": 3, "name": "warbogar", "discipline": "Rotweaver · Level 28", "portrait": DmGameHud.art("portraits/rotweaver.webp"), "hp_frac": 0.9},
			{"id": 4, "name": "brbmuffins", "discipline": "Mourner · Level 40", "portrait": DmGameHud.art("portraits/mourner.webp"), "hp_frac": 0.3}],
	}
