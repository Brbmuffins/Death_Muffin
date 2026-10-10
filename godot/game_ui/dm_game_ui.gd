class_name DmGameUi
extends CanvasLayer
## The in-world UI of the port (godot/GAME_CONTRACT.md): DmHud fed every frame from game.hud_state() + the UI-owned parts, every panel opened by the
## web's keys / menu buttons with real data from game.character / slots / progress, panel signals mapped to the DmApi calls their headers document and
## followed by game.refresh_*(), counsel tips from game.game_event, dialogue, Settings -> game.apply_settings.
## Ports how archive/legacy-web:src/scenes/WorldScene.ts and archive/legacy-web:src/ui/* wire the UI. Pure UI: all world state is read from `game`.

signal sound(name: String)                 ## the web's audio.play(name) at each UI site (click, coin, equip, buy, panelOpen...): connect to AudioDirector
signal left_world                          ## Settings -> "Leave the world"
signal panel_changed

const PANEL_KEYS := {
	KEY_I: "inventory", KEY_B: "inventory", KEY_J: "sheet", KEY_Y: "legion", KEY_C: "forge", KEY_P: "professions", KEY_O: "contracts", KEY_U: "garden",
	KEY_H: "labor", KEY_N: "cosmetics", KEY_V: "vault", KEY_M: "map", KEY_K: "codex", KEY_PERIOD: "atlas", KEY_L: "grimoire", KEY_F: "party",
}
const HOSTS := {
	"professions": ["acre", "skills"], "garden": ["acre", "garden"], "labor": ["acre", "labor"], "contracts": ["acre", "contracts"],
	"sheet": ["char", "stats"], "cosmetics": ["char", "pets"], "grimoire": ["grim", "grimoire"], "legion": ["grim", "legion"],
}
const CUE_TEXT := {
	"hud.upgrades": "Upgrades unlocked: spend gold on Empower (damage) and Quicken (wave speed), bottom right.",
	"hud.dial": "The wave dial appeared in the Upgrades box: choose how fast the waves you face run.",
	"hud.shards": "Soul Shards counter: kept from bosses, spent on boons at the Altar of Ascension.",
	"menu.spells": "You can swap rites now: open the Grimoire (L).",
	"menu.atlas": "Gear Atlas (.): every item, set and recipe in the game, with where to find it.",
	"menu.skills": "The Acre ledger (P): your skills, garden, laborers and contracts in one place.",
	"tab.acre.garden": "Garden, Laborers and Contracts are tabs of the Acre ledger now (P). U, H and O still open them.",
	"tab.sheet.pets": "Capes & Pets moved into the Character sheet (J). N still opens them.",
	"tab.grimoire.legion": "The Legion now sits beside the Grimoire (L). Y still opens it.",
}
## The panel a NEW cue's toast opens when clicked (WorldScene CUE_OPENS).
const CUE_OPENS := {
	"menu.skills": "professions", "menu.spells": "grimoire", "hud.spells": "grimoire", "menu.atlas": "atlas",
	"tab.acre.garden": "garden", "tab.sheet.pets": "cosmetics", "tab.grimoire.legion": "legion",
}
const TAB_CUES := ["tab.acre.garden", "tab.acre.labor", "tab.acre.contracts", "tab.sheet.pets", "tab.grimoire.legion"]
const REVEAL_IDS := ["hud.upgrades", "hud.dial", "hud.shards", "hud.spells", "menu.spells", "menu.atlas", "menu.skills"]
const LOADOUT_ACTIONS := ["loadout_next", "loadout_1", "loadout_2", "loadout_3", "loadout_4", "loadout_5", "loadout_6"]

var game: Node
var store: DmCounselStore
var hud: DmHud
var windows_root: Control
var windows: Dictionary = {}               ## id -> DmWindow (settings inventory forge vault salvage shelf codex atlas ascension map class report acre char grim)
var locks: DmItemLocks
var rites: DmRites
var reveal: DmHudReveal
var cues: DmHudReveal.CueQueue
var counsel: DmCounsel
var counsel_view: DmCounselView
var guidance_hud := DmGuidanceHud.new()
var memory: DmGuidanceMemory
var dialogue: DmDialoguePanel
var inv: DmUiInventory
var pa: DmUiPanelsA
var pb: DmUiPanelsB
var set_ui: DmUiSettings
var lobby_ui: DmUiLobby
var belt_picker: DmBeltPicker
var hud_tips: DmHudTips
var boss_key: DmBossKeyPrompt
var stair_prompt: DmDepthsStairPrompt
var binds: Dictionary = {}
var skills: Dictionary = {}                ## profession_id -> level (for the guidance state)
var labor_summary: Variant = null
var last_guidance: Dictionary = {}          ## the state of the latest 0.5 s tick (shared by whoever polls the same facts: the hub's NPC "!")
var contract_summary: Variant = null
var codex_journal := {"dead": {}, "area": {}}
var _build_cache: Dictionary = {}
var _build_sig := ""
var _guide_t := 0.0
var _busy_t := 0.0
var _tick_t := 0.0
var _last_gold := 0
var _family := "necromancer"
var _kit: Dictionary
var _vm: Dictionary = {}
const HUD_INTERVAL_MS := 50
var _hud_at := 0
var _bind_capture := ""
var _last_loadout_slot := -1
var _loadout_busy := false
var _dev_access := false
var banner_until := 0.0


func setup(game_: Node) -> void:
	game = game_
	layer = 10
	var cid := int(game.character["id"])
	store = DmCounselStore.new(DmUiConfig.store_path())
	_family = String(DmCharacterBuild.discipline_for(float(game.character["class_index"]))["family"])
	_kit = DmAbilities.kit_for(_family)
	locks = DmItemLocks.new(cid, store)
	rites = DmRites.new(cid, _kit, _rite_level(), store)
	reveal = DmHudReveal.new(cid, store)
	memory = DmGuidanceMemory.new(DmUiConfig.guidance_path(cid))
	binds = DmUiBinds.load(store)

	hud = DmHud.new()
	add_child(hud)
	hud.set_hud_scale(DmSettings.clamp_hud_scale(game.settings.get("hud_scale", 1.0)))
	windows_root = Control.new()
	windows_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	windows_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(windows_root)

	_build_counsel()
	inv = DmUiInventory.new(self, locks, store)
	_add_window("inventory", inv.panel)
	set_ui = DmUiSettings.new(self)
	lobby_ui = DmUiLobby.new(self)
	pa = DmUiPanelsA.new(self)
	pb = DmUiPanelsB.new(self)
	belt_picker = DmBeltPicker.new(self)
	boss_key = DmBossKeyPrompt.new()
	_add_window("boss_key", boss_key)
	boss_key.normal_chosen.connect(func(b: String) -> void: call_game_sync("summon_boss", [b]))
	boss_key.empowered_chosen.connect(func(b: String) -> void: call_game_sync("summon_boss_empowered", [b]))
	stair_prompt = DmDepthsStairPrompt.new()
	_add_window("depths_stair", stair_prompt)
	stair_prompt.depth_picked.connect(func(d: int) -> void: call_game_sync("enter_depths", [d]))
	hud_tips = DmHudTips.new(self)
	hud.spell_card = Callable(hud_tips, "card")
	_connect_hud()
	_connect_game()
	_init_progressive()
	dialogue = DmDialoguePanel.new()
	dialogue.source = DmCovenantDialogue.new(Callable(self, "guidance_state"), memory)
	dialogue.visible = false
	dialogue.npc_changed.connect(func(npc: String) -> void:
		if npc != "":
			sound.emit("dialogueOpen")
		_guide_t = 0.0)
	dialogue.sound.connect(func() -> void: sound.emit("uiSelect"))
	dialogue.position = Vector2(0, 24)
	windows_root.add_child(dialogue)
	hud.hint.text = "Right-click or 5 casts your fifth rite"
	_last_gold = int(game.character.get("gold", 0))
	_load_side_data()
	# First HUD apply now, during setup (loading), not in the first played frame: it builds the hotbar, loads the slot/omen/portrait
	# textures and shapes every label once (~50 ms headless).
	_hud_at = Time.get_ticks_msec()
	_vm = merged_vm()
	hud.apply(_vm)
	set_process(true)
	set_process_unhandled_key_input(true)


## Await after setup() while still loading: the first frame with the HUD does the whole control tree's first layout + theme/text
## shaping (~30 ms headless), so take it here rather than in the first played frame.
func warm() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	await _warm_panels()


## Panels worth building ahead: a first open used to cost 50-500 ms (every row built, fonts shaped, first layout) in the middle of play.
const WARM_PANELS := ["inventory", "sheet", "cosmetics", "legion", "forge", "professions", "garden", "labor", "contracts", "grimoire", "codex", "atlas", "ascension",
	"map", "settings", "salvage", "shelf", "party"]
## The panels warm() builds ahead (a shell that wires fewer panels, like the slice, narrows this before warm()).
var warm_panels: Array = WARM_PANELS
## True while warm() opens the panels behind its cover: no sounds, cue/counsel events, gathering stops or "seen" marks (they belong to the player's own opens).
var warming := false
var warm_ms := 0


## Build + lay out + draw every panel once under an opaque cover (still the loading screen), so the player's first open of each is a show, not a build.
func _warm_panels() -> void:
	var t0 := Time.get_ticks_msec()
	warming = true
	var cover := DmLoadingScreen.acquire(self, "Waking the dead...")
	var tree := get_tree()
	await tree.process_frame
	var pi := 0
	for p in warm_panels:
		cover.set_progress(0.82 + 0.17 * float(pi) / float(warm_panels.size()))
		pi += 1
		close_panels()
		toggle_panel(p)
		await tree.process_frame
		await tree.process_frame
	close_panels()
	await tree.process_frame
	if cover.owned:
		cover.dismiss(false)
	warming = false
	warm_ms = Time.get_ticks_msec() - t0


func _rite_level() -> float:
	return DmAbilities.rite_level(float(game.character.get("level", 1)), _dev_access)


func slots_first(item_id: String) -> Dictionary:
	for s in game.slots:
		if s["item_id"] == item_id:
			return s
	return {}


func is_necromancer() -> bool:
	return _family == "necromancer"


func family() -> String:
	return _family


func kit() -> Dictionary:
	return _kit


func _add_window(id: String, w: DmWindow) -> void:
	windows[id] = w
	windows_root.add_child(w)
	w.closed.connect(func() -> void: panel_changed.emit())
	w.opened.connect(func() -> void: panel_changed.emit())


func play(name: String) -> void:
	sound.emit(name)


func toast(text: String, kind: String = "") -> void:
	hud.toast(text, kind)


func area_safe() -> bool:
	return bool(DmContent.area(String(game.area_id)).get("safe", false))


func near_grinder() -> bool:
	return bool(game.near_grinder()) if game.has_method("near_grinder") else false


func call_game(method: String, args: Array = []) -> Variant:
	if game.has_method(method):
		return await game.callv(method, args)
	return null


# --- character build / stat context (WorldScene.statContext, refreshStats) -------------------------------------------------

func local_progress() -> Dictionary:
	return game.progress


## DmCharacterBuild.build for the current character, cached until the character, bag or progress changes.
func build() -> Dictionary:
	if _build_cache.is_empty():
		_build_cache = DmCharacterBuild.build(game.character, game.slots, game.progress)
	return _build_cache


func _invalidate() -> void:
	_build_cache = {}


func stat_ctx() -> Variant:
	if game.slots == null:
		return null
	var b := build()
	return {"character": game.character, "slots": game.slots, "discipline": b["discipline"], "damageTier": float(game.progress.get("damageTier", 0)), "legion": b["legion"]}


# --- counsel ----------------------------------------------------------------------------------------------------------------

func _build_counsel() -> void:
	var cid := int(game.character["id"])
	counsel = DmCounsel.new(cid, store)
	counsel.auto_allowed = bool(game.character.get("auto_combat_allowed", false))
	counsel.tips_enabled = not bool(game.settings.get("no_tips", false))
	counsel.key_for = func(ability: String) -> String:
		var i := rites.keys.find(ability)
		return str(i + 1) if i >= 0 else ""
	counsel.stale = func(id: String) -> bool:
		return id == "thrall" and int(game.hud_state().get("thralls", 0)) <= 0
	counsel.tips_disabled.connect(func() -> void: update_setting({"no_tips": true}))
	counsel.card_shown.connect(func(_id: String, _k: String, _t: String, _b: String, _ms: int) -> void: sound.emit("counselCard"))
	counsel_view = DmCounselView.new()
	counsel_view.set_anchors_preset(Control.PRESET_FULL_RECT)
	counsel_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	counsel_view.reduce_motion = bool(game.settings.get("reduce_motion", false))
	add_child(counsel_view)
	counsel_view.setup(counsel, hud, store)


func notify(event_id: String, ctx: Dictionary = {}) -> void:
	if warming:
		return
	counsel.notify(event_id, ctx)


func counsel_busy() -> Dictionary:
	var b := DmCounselCadence.not_busy()
	if game.has_method("counsel_busy"):
		var g: Dictionary = game.counsel_busy()
		for k in g:
			b[k] = g[k]
	b["talking"] = dialogue != null and dialogue.visible
	b["banner"] = hud.banner_active()
	b["panel"] = panel_open() and not b["talking"]
	b["area"] = String(game.area_id)
	b["safe"] = area_safe()
	return b


# --- progressive HUD + NEW cues (WorldScene.initProgressive) -----------------------------------------------------------------

func _init_progressive() -> void:
	cues = DmHudReveal.CueQueue.new()
	cues.hold_ms = 7500.0
	cues.show_cb = func(text: String, key: String) -> void:
		var opens: String = CUE_OPENS.get(key, "")
		hud.toast(text, "new", Callable(self, "toggle_panel").bind(opens) if opens != "" else Callable())
	cues.blocked = func() -> bool: return hud.banner_active() or (dialogue != null and dialogue.visible)
	var level := int(game.character.get("level", 1))
	var loc: Dictionary = game.progress
	if reveal.fresh:
		for id in DmHudReveal.veteran_reveals({"level": level, "gold": int(game.character.get("gold", 0)), "damage_tier": int(loc.get("damageTier", 0)),
				"wave_owned": int(loc.get("waveTierOwned", 0)), "shards": int(loc.get("shards", 0)), "knows_acre": false, "swap_ready": grimoire_unlocked(),
				"has_gear": level >= 3, "has_hunted": codex_has("area", "graves")}):
			reveal.reveal(id, false)
		if DmHudReveal.is_veteran(level):
			reveal.flag("menu.skills")
			reveal.flag("tab.acre.labor")
			reveal.flag("tab.acre.contracts")
			var tabs: Array = ["tab.acre.garden", "tab.sheet.pets"]
			if is_necromancer():
				tabs.append("tab.grimoire.legion")
			for id in tabs:
				if reveal.flag(id):
					cues.push(id, CUE_TEXT[id])
	for id in reveal.new_ids():
		_show_cue(id, true)


func grimoire_unlocked() -> bool:
	return DmRites.swap_ready(_kit["grimoire"], _rite_level())


func codex_has(kind: String, id: String) -> bool:
	return codex_journal[kind].has(id)


func _show_cue(id: String, on: bool) -> void:
	for w in [pa.acre_win, pa.char_win, pa.grim_win]:
		if w != null:
			w.set_new(id, on)


func reveal_hud(id: String, with_toast: bool = true) -> void:
	if not reveal.reveal(id, true):
		return
	_show_cue(id, true)
	if with_toast and CUE_TEXT.has(id):
		cues.push(id, CUE_TEXT[id])


func use_cue(id: String) -> void:
	reveal.clear(id)
	_show_cue(id, false)
	cues.drop(id)


func use_tab_cue(win: String, tab: String) -> void:
	if warming:
		return
	var id := "tab.%s.%s" % [win, tab]
	if TAB_CUES.has(id):
		use_cue(id)


func _clear_cues_for(p: String) -> void:
	if p == "professions":
		use_cue("menu.skills")
	elif p == "grimoire":
		use_cue("menu.spells")
		use_cue("hud.spells")
	elif p == "atlas":
		use_cue("menu.atlas")


func _progressive_tick() -> void:
	var gold := int(game.character.get("gold", 0))
	var loc: Dictionary = game.progress
	if not reveal.has("hud.upgrades") and gold > _last_gold and not area_safe():
		reveal_hud("hud.upgrades")
	_last_gold = gold
	if not reveal.has("hud.dial") and int(loc.get("waveTierOwned", 0)) > 0:
		reveal_hud("hud.dial")
	if not reveal.has("hud.shards") and int(loc.get("shards", 0)) > 0:
		reveal_hud("hud.shards")
	if not reveal.has("menu.spells") and grimoire_unlocked():
		reveal_hud("hud.spells", false)
		reveal_hud("menu.spells")
	if not reveal.has("menu.skills"):
		for k in skills:
			if int(skills[k]) > 1:
				reveal_hud("menu.skills")
				break


# --- guidance (WorldScene.guidanceState / tickGuidance) ---------------------------------------------------------------------

func guidance_state() -> Dictionary:
	var loc: Dictionary = game.progress
	var bag := 0
	var dust := 0
	for s in game.slots:
		if int(s["slot_index"]) >= 0 and int(s["slot_index"]) < 48:
			bag += 1
			if s["item_id"] == "reagent_grave_dust":
				dust += int(s["quantity"])
	var unlocked: Array = loc.get("unlocked", []).duplicate()
	var run: Dictionary = loc.get("run", {})
	var boons := DmAscension.boon_effects(loc.get("boons", {}))
	return {"level": int(game.character.get("level", 1)), "area": String(game.area_id), "ascension": int(loc.get("ascension", 0)),
		"canAscend": _can_ascend(), "ashesOnAscend": _ashes_on_ascend(), "shards": int(loc.get("shards", 0)), "unlocked": unlocked,
		"areaKills": loc.get("areaKills", {}), "unlockMult": float(boons.get("unlockKillsMult", 1.0)),
		"bossesBeaten": DmGuidance.parse_trophies(store.get_item(DmGuidance.boss_trophy_key(float(game.character["id"])))),
		"prelateThisRun": int(run.get("prelateKills", 0)) > 0, "totalKills": int(loc.get("totalKills", 0)), "skills": skills.duplicate(),
		"bagUsed": bag, "bagSize": 48, "dust": dust, "labor": labor_summary, "contracts": contract_summary}


func _can_ascend() -> bool:
	var p := DmProgression.new(game.character, game.progress)
	return p.can_ascend()


func _ashes_on_ascend() -> int:
	var p := DmProgression.new(game.character, game.progress)
	return p.ashes_on_ascend()


func _tick_guidance(dt: float) -> void:
	_guide_t -= dt
	if _guide_t > 0.0:
		return
	_guide_t = 0.5
	last_guidance = guidance_state()
	guidance_hud.update(last_guidance, bool(game.settings.get("guidance", true)))


func _load_side_data() -> void:
	var cid := int(game.character["id"])
	var r: DmResult = await game.api.get_professions(cid)
	if r.ok and r.data is Array:
		for p in r.data:
			skills[String(p["profession_id"])] = int(p["skill_level"])
	var lr: DmResult = await game.api.get_labor(cid)
	if lr.ok and lr.data is Dictionary and lr.data.has("slots"):
		labor_summary = DmGuidance.summarize_labor(lr.data)
	var cr: DmResult = await game.api.get_contracts(cid)
	if cr.ok and cr.data is Dictionary and cr.data.has("contracts"):
		contract_summary = DmGuidance.summarize_contracts(cr.data)


# --- HUD wiring (WorldScene.mountUi) -----------------------------------------------------------------------------------------

func _connect_hud() -> void:
	hud.cast.connect(func(slot: int) -> void: game.cast(slot))
	hud.buy_damage.connect(func() -> void: game.buy_upgrade("damage"))
	hud.buy_wave.connect(func() -> void: game.buy_upgrade("wave"))
	hud.dial_wave.connect(func(d: int) -> void: call_game("dial_wave", [d]))
	hud.open_panel.connect(func(p: String) -> void: toggle_panel(p))
	hud.open_grimoire.connect(open_grimoire)
	hud.swap_slot.connect(func(i: int) -> void: open_grimoire(i))
	hud.chat_sent.connect(_on_chat)
	hud.toggle_auto_combat.connect(toggle_auto_combat)
	hud.dismiss_next.connect(func() -> void:
		guidance_hud.dismiss()
		_guide_t = 0.0)
	hud.report_bug.connect(open_bug_report)
	hud.belt_clicked.connect(func(slot: String) -> void: belt_picker.toggle(slot))
	hud.brew_dropped.connect(func(_slot: String, item_id: String) -> void: set_belt(item_id))
	hud.navigate.connect(func(x: float, z: float) -> void:
		if not _blocking_panel_open():
			game.navigate(x, z))
	hud.cue_used.connect(func(id: String) -> void: use_cue(id))


func _on_chat(text: String) -> void:
	if chat_command(text):
		return
	if game.has_method("send_chat"):
		game.send_chat(text)
	else:
		hud.chat_line("(solo) Nobody hears you in the dark.")


## `/party [code]`, `/solo`, `/leave` (WorldScene.chatCommand). True when the line was a command and the game can do it.
func chat_command(text: String) -> bool:
	var c := DmChatCommand.parse(text)
	if c.is_empty():
		return false
	var code := String(game.get("party_code")) if game.get("party_code") != null else ""
	if c["cmd"] != "party":
		if not game.has_method("party_leave"):
			return false
		game.party_leave()
	elif c["arg"] != "":
		if not game.has_method("party_join"):
			return false
		var clean := DmChatCommand.clean_code(String(c["arg"]))
		if clean == "":
			toast("Enter a party code (letters and numbers).", "err")
		else:
			game.party_join(clean)
	elif code != "":
		hud.chat_line("Your party code is %s. Friends join with /party %s. /solo leaves it." % [code, code])
	else:
		if not game.has_method("party_create"):
			return false
		game.party_create()
	return true


func _connect_game() -> void:
	game.character_changed.connect(func() -> void:
		_invalidate()
		rites.set_level(_rite_level())
		pa.atlas_dirty()
		pa.refresh_open())
	game.inventory_changed.connect(_on_inventory_changed)
	game.progress_changed.connect(func() -> void:
		_invalidate()
		pa.atlas_dirty()
		pa.refresh_open())
	game.area_changed.connect(func(_id: String) -> void:
		_guide_t = 0.0
		if not area_safe():
			reveal_hud("hud.omen", false))
	game.hero_died.connect(func() -> void: close_panels())
	game.game_event.connect(_on_game_event)
	game.npc_interact.connect(talk_to)
	game.station_interact.connect(func(id: String) -> void: open_station(id))


func _on_inventory_changed() -> void:
	_invalidate()
	pa.atlas_dirty()
	locks.prune(game.slots)
	if inv.panel.visible:
		inv.render()
	pa.refresh_open()
	var used := 0
	var candidates := false
	for s in game.slots:
		if int(s["slot_index"]) >= 0 and int(s["slot_index"]) < 48:
			used += 1
	candidates = not DmLegionText.kit_candidates(game.slots).is_empty()
	var owned := not DmRunes.owned_runes(game.slots).is_empty()
	var learned := 0
	for id in DmRites.assignable(_kit):
		if DmAbilities.unlock_level(id) <= _rite_level():
			learned += 1
	var runes := 0
	for k in DmRunes.owned_runes(game.slots):
		runes += int(DmRunes.owned_runes(game.slots)[k])
	runes += DmRunes.sockets_of(game.slots).size()
	notify("bag_changed", {"slots_used": used, "bag_size": 48, "family": _family, "kit_candidates": candidates and is_necromancer(), "owns_rune": owned and is_necromancer(),
		"learned_rites": learned, "rune_count": runes})


## A game moment: toast / banner / loot / float / chat are drawn here; everything else is a counsel event id.
func _on_game_event(event_id: String, ctx: Dictionary) -> void:
	match event_id:
		"toast":
			hud.toast(String(ctx.get("text", "")), String(ctx.get("kind", "")))
		"banner":
			hud.banner(String(ctx.get("title", "")), String(ctx.get("sub", "")), int(ctx.get("ms", 3200)))
		"loot":
			hud.loot_toast(String(ctx.get("name", "")), int(ctx.get("qty", 1)), String(ctx.get("rarity", "common")))
		"float":
			var pos := Vector2.ZERO
			if ctx.has("screen"):
				pos = ctx["screen"]
			elif ctx.has("world") and game.camera != null:
				pos = game.camera.unproject_position(ctx["world"])
			hud.float_text(pos, String(ctx.get("text", "")), String(ctx.get("kind", "hit")), ctx.get("color", Color(0, 0, 0, 0)))
		"chat":
			hud.chat_line(String(ctx.get("text", "")))
		"gather_report":
			pb.report.show_report(ctx.get("report", ctx))
			pb.report.window.open()
		"boss_key_offer":
			close_panels()
			boss_key.open_offer(ctx)
		"depths_stair_offer":
			close_panels()
			stair_prompt.open_deepest(int(ctx.get("deepest", 1)))
		"codex":
			record_codex(String(ctx.get("kind", "")), String(ctx.get("id", "")))
		"hit_flash":
			hud.hit_flash()
		"slot_flash":
			hud.slot_flash(int(ctx.get("slot", 0)))
		"panel_toggle":
			toggle_panel(String(ctx.get("panel", "")))
		"tip":
			counsel.show(String(ctx.get("id", "")), float(ctx.get("delay_ms", 0.0)), ctx.get("opts", {}))
		_:
			counsel.notify(event_id, ctx)
	if event_id == "level_up":
		rites.set_level(_rite_level())
		_refresh_grimoire_pips()


func record_codex(kind: String, id: String) -> void:
	if kind in ["dead", "area"] and id != "":
		codex_journal[kind][id] = true


# --- per frame ----------------------------------------------------------------------------------------------------------------

## Accumulated _process time in microseconds while `prof_on` (the F3 overlay turns it on): the HUD / counsel share of a frame.
var prof_on := false
var prof_us := 0

func _process(delta: float) -> void:
	if game == null:
		return
	var prof_t0 := Time.get_ticks_usec() if prof_on else 0
	_ui_frame(delta)
	if prof_on:
		prof_us += Time.get_ticks_usec() - prof_t0


func _ui_frame(delta: float) -> void:
	# The web refreshes the HUD at most every HUD_INTERVAL_MS (WorldScene hudDue); every frame here was ~2 ms of view-model + apply.
	var now := Time.get_ticks_msec()
	if _vm.is_empty() or now - _hud_at >= HUD_INTERVAL_MS or now < _hud_at:
		_hud_at = now
		_vm = merged_vm()
		hud.apply(_vm)
	# The counsel's "is the player busy" snapshot (window scan, game.counsel_busy(), area checks) is refreshed 10x a second; its timers
	# still advance every frame. It rebuilt the whole dictionary every frame before.
	_busy_t -= delta
	var busy_now: Variant = null
	if _busy_t <= 0.0:
		_busy_t = 0.1
		busy_now = counsel_busy()
	counsel.tick(delta, busy_now)
	cues.tick(delta)
	_tick_guidance(delta)
	_tick_t += delta
	if _tick_t >= 0.4:
		_tick_t = 0.0
		_progressive_tick()
		if game.has_method("counsel_tick_ctx"):
			counsel.notify_tick(game.counsel_tick_ctx())
	pa.process(delta)


func _exit_tree() -> void:
	if pa != null:
		pa.shutdown()
	if store != null:
		store.flush()


## hud.apply(merge(game.hud_state(), ui-owned parts)).
func merged_vm() -> Dictionary:
	var v: Dictionary = game.hud_state()
	var held := {}
	for id in REVEAL_IDS:
		if not reveal.has(id):
			held[id] = false
	var fresh := {}
	for id in reveal.new_ids():
		fresh[id] = true
	v["reveal"] = held
	v["new"] = fresh
	v["grimoire_new"] = rites.has_unseen()
	v["dev"] = _dev_access
	var swap := grimoire_unlocked()
	if v.has("slots"):
		var sl: Array = v["slots"]
		for i in mini(5, sl.size()):
			sl[i]["swap"] = swap
	v["next"] = guidance_hud.text() if guidance_hud.current != null else null
	if not v.has("area_name"):
		v["area_name"] = String(DmContent.area(String(game.area_id)).get("name", ""))
	if not v.has("auto_combat"):
		var allowed := bool(game.character.get("auto_combat_allowed", false))
		v["auto_combat"] = {"on": bool(game.settings.get("auto_combat", false)), "available": allowed, "visible": allowed and String(game.settings.get("difficulty", "medium")) == "easy"}
	if not v.has("omen") or v["omen"] == null:
		pass
	elif v["omen"] is Dictionary:
		(v["omen"] as Dictionary)["visible"] = not area_safe()
	return v


func _refresh_grimoire_pips() -> void:
	pass


# --- panels (WorldScene.togglePanel / closePanels / panelOpen) -----------------------------------------------------------------

func host_of(p: String) -> Array:
	return HOSTS.get(p, [])


func window_for(p: String) -> DmWindow:
	var h := host_of(p)
	if not h.is_empty():
		return pa.acre_win if h[0] == "acre" else (pa.char_win if h[0] == "char" else pa.grim_win)
	return windows.get(p)


func panel_open() -> bool:
	for k in windows:
		if (windows[k] as Control).visible:
			return true
	for w in [pa.acre_win, pa.char_win, pa.grim_win]:
		if w.visible:
			return true
	return dialogue != null and dialogue.visible


func _blocking_panel_open() -> bool:
	# navigateFromMinimap refuses while class/settings/inventory/forge/shelf/professions/codex/ascension/waystone is open
	for k in ["class", "settings", "inventory", "forge", "shelf", "codex", "ascension", "map"]:
		if windows.has(k) and (windows[k] as Control).visible:
			return true
	return pa.acre_win.visible and pa.acre_win.active == "skills"


func is_open(p: String) -> bool:
	var h := host_of(p)
	if not h.is_empty():
		var w := window_for(p)
		return w.visible and w.active == h[1]
	return windows.has(p) and (windows[p] as Control).visible


func close_panels() -> void:
	for k in windows:
		(windows[k] as DmWindow).close()
	for w in [pa.acre_win, pa.char_win, pa.grim_win]:
		w.close()
	if belt_picker != null:
		belt_picker.close()
	if dialogue != null:
		dialogue.close()


func toggle_panel(p: String) -> void:
	var h := host_of(p)
	var win := window_for(p)
	if win == null and p != "forge":
		return
	var switching: bool = not h.is_empty() and win.visible and win.active != h[1]
	var was_open := is_open(p)
	var vault := p == "vault"
	if not switching and not warming and not (vault and not was_open and not area_safe()):
		var snd := "panelOpen"
		if p == "inventory":
			snd = "panelOpenInventory"
		elif p in ["forge", "salvage"]:
			snd = "panelOpenForge"
		elif p in ["codex", "grimoire", "ascension", "atlas", "contracts"]:
			snd = "panelOpenBook"
		sound.emit(("vaultClose" if vault else "panelClose") if was_open else ("vaultOpen" if vault else snd))
	if not switching:
		close_panels()
	if was_open:
		return
	if not warming:
		_clear_cues_for(p)
		if not (p == "professions" and _truthy(call_game_sync("afk_active"))):
			call_game_sync("stop_gathering", ["panel"])
	if not h.is_empty():
		win.select_tab(h[1])
		if not win.visible:
			win.open()
			pa.on_open(p)
		if p == "grimoire":
			notify("grimoire_opened", _grimoire_ctx())
		return
	match p:
		"inventory":
			inv.panel.open()
			inv.render()
		"settings":
			set_ui.open()
		"party":
			lobby_ui.open()
		"vault":
			if not area_safe():
				toast("The Vault is in the Chapterhouse", "err")
				return
			pb.open("vault")
		"forge", "salvage", "shelf":
			pb.open(p)
		_:
			pa.open_window(p)


func call_game_sync(method: String, args: Array = []) -> Variant:
	if game.has_method(method):
		return game.callv(method, args)
	return null


func _grimoire_ctx() -> Dictionary:
	var owns := not DmRunes.owned_runes(game.slots).is_empty() or not DmRunes.sockets_of(game.slots).is_empty()
	return {"family": _family, "owns_rune": owns}


func open_grimoire(select: Variant = null) -> void:
	sound.emit("click")
	close_panels()
	call_game_sync("stop_gathering", ["panel"])
	_clear_cues_for("grimoire")
	pa.grim_select = select
	pa.grim_win.select_tab("grimoire")
	pa.grim_win.open()
	pa.on_open("grimoire")
	pa.grim_select = null
	notify("grimoire_opened", _grimoire_ctx())


func open_bug_report() -> void:
	close_panels()
	call_game_sync("stop_gathering", ["panel"])
	set_ui.open_bug_report()


func open_station(id: String) -> void:
	# The scene opens the panel the station belongs to (WorldScene interact): workbench/kiln/sawpit/fire/cauldron -> forge, altar -> ascension, ...
	match id:
		"workbench", "kiln", "sawpit", "fire", "cauldron", "alembic":
			close_panels()
			pb.open_forge(id)
		"altar":
			toggle_panel("ascension")
		"vault":
			toggle_panel("vault")
		"waystone":
			toggle_panel("map")
		"grinder":
			toggle_panel("salvage")
		"shelf":
			toggle_panel("shelf")
		"lectern":
			toggle_panel("codex")
		"class":
			open_class_panel()


func open_class_panel() -> void:
	close_panels()
	call_game_sync("stop_player")
	pa.open_window("class")
	notify("class_panel_opened")


func talk_to(npc: String) -> void:
	close_panels()
	call_game_sync("stop_gathering", ["panel"])
	call_game_sync("stop_player")
	sound.emit("click")
	dialogue.open_npc(npc)
	_guide_t = 0.0


# --- belt (WorldScene.setBelt / beltChoices) ---------------------------------------------------------------------------------------

func belt_key() -> String:
	return "dm_belt_%d" % int(game.character["id"])


func belt_pick() -> Dictionary:
	var raw: Variant = DmUiConfig.parse(store.get_item(belt_key()))
	var out := {"elixir": null, "tonic": null}
	if raw is Dictionary:
		for slot in ["elixir", "tonic"]:
			var id: Variant = raw.get(slot)
			if id is String and DmContent.brew(id).get("slot", "") == slot:
				out[slot] = id
	return out


func set_belt(item_id: String) -> void:
	var b := DmContent.brew(item_id)
	if b.is_empty():
		return
	var pick := belt_pick()
	pick[b["slot"]] = item_id
	store.set_item(belt_key(), JSON.stringify(pick))
	call_game_sync("set_belt", [String(b["slot"]), item_id])
	toast("%s is on your belt: press %s to drink it" % [b["label"], "Z" if b["slot"] == "elixir" else "X"], "good")


# --- auto combat / settings ---------------------------------------------------------------------------------------------------------

func toggle_auto_combat() -> void:
	if not bool(game.character.get("auto_combat_allowed", false)):
		return
	if String(game.settings.get("difficulty", "medium")) != "easy":
		toast("Auto combat is available on Easy difficulty. Change it in Settings.")
		return
	var on := not bool(game.settings.get("auto_combat", false))
	update_setting({"auto_combat": on})
	game.set_auto_combat(on)
	toast("Auto combat on — your hero engages nearby enemies. Click or use keys to take control; G turns it off." if on else "Auto combat off — click enemies and use your rites manually.", "good")


## settings.ts updateSettings: the same patch rules, then game.apply_settings(full settings).
func update_setting(patch: Dictionary) -> void:
	var s: Dictionary = game.settings.duplicate(true)
	var allowed := bool(game.character.get("auto_combat_allowed", false))
	if patch.has("difficulty") and not patch.has("auto_combat"):
		patch["auto_combat"] = allowed and patch["difficulty"] == "easy"
	var diff: String = String(patch.get("difficulty", s.get("difficulty", "medium")))
	if not allowed or diff != "easy":
		patch["auto_combat"] = false
	for k in patch:
		s[k] = patch[k]
	game.apply_settings(s)
	if patch.has("hud_scale"):
		hud.set_hud_scale(DmSettings.clamp_hud_scale(patch["hud_scale"]))
	if patch.has("no_tips"):
		counsel.set_tips_enabled(not bool(patch["no_tips"]))
	if patch.has("reduce_motion"):
		counsel_view.reduce_motion = bool(patch["reduce_motion"])
	if patch.has("auto_combat") and game.has_method("set_auto_combat"):
		game.set_auto_combat(bool(patch["auto_combat"]))
	if set_ui != null:
		set_ui.sync_values()


# --- keys (WorldScene.bindInput: the UI half) -------------------------------------------------------------------------------------------

func _unhandled_key_input(event: InputEvent) -> void:
	var e := event as InputEventKey
	if e == null or not e.pressed:
		return
	if _bind_capture != "":
		set_ui.capture_key(e)
		get_viewport().set_input_as_handled()
		return
	if get_viewport().gui_get_focus_owner() is LineEdit or get_viewport().gui_get_focus_owner() is TextEdit:
		return
	var k := e.keycode
	if is_necromancer() and not e.ctrl_pressed and not e.meta_pressed and not e.alt_pressed:
		var action := DmUiBinds.action_for_key(binds, DmUiBinds.key_name(e))
		if action != "":
			get_viewport().set_input_as_handled()
			if not e.echo:
				loadout_hotkey(action)
			return
	if e.echo and not PANEL_KEYS.has(k):
		return
	if PANEL_KEYS.has(k):
		var p: String = PANEL_KEYS[k]
		if p == "legion" and not is_necromancer():
			return
		toggle_panel(p)
		get_viewport().set_input_as_handled()
	elif k == KEY_G:
		toggle_auto_combat()
	elif k == KEY_ENTER or k == KEY_KP_ENTER:
		hud.focus_chat()
		get_viewport().set_input_as_handled()
	elif k == KEY_ESCAPE:
		if panel_open() and not is_open("settings"):
			sound.emit("panelClose")
			close_panels()
		else:
			toggle_panel("settings")
		get_viewport().set_input_as_handled()
	elif k == KEY_E:
		if dialogue.visible:
			dialogue.close()
		else:
			call_game_sync("talk_key")


# --- loadouts (WorldScene.loadoutHost / loadoutHotkey / applyRitesPreset) --------------------------------------------------------------------

func set_rite(slot: int, id: String) -> void:
	if not rites.set_rite(slot, id):
		return
	_push_rites()
	sound.emit("click")
	notify("rite_key_set", {"ability": id})


func set_primary(id: String) -> void:
	if not rites.set_primary(id):
		return
	_push_rites()
	sound.emit("click")
	notify("rite_primary_set", {"ability": id})


func _push_rites() -> void:
	call_game_sync("set_rites", [rites.primary, rites.keys])
	pa.refresh_grimoire()


func apply_rites_preset(preset_rites: Dictionary) -> Array:
	var lines := rites.apply_preset(preset_rites)
	_push_rites()
	return lines


func loadout_hotkey(action: String) -> void:
	await pa.loadouts.hotkey(action)


# --- small hooks the panels call ----------------------------------------------------------------------------------------------------

func on_equipped() -> void:
	sound.emit("equip")
	notify("gear_equipped")


func on_salvaged(r: Variant) -> void:
	sound.emit("grind")
	if r is Dictionary and r.has("gained"):
		var n := (r.get("salvaged", []) as Array).size()
		var parts: Array = []
		for g in r["gained"]:
			parts.append("%d× %s" % [int(g["quantity"]), String(DmContent.item(String(g["item_id"])).get("name", g["item_id"]))])
		toast("Ground %d piece%s: %s" % [n, "" if n == 1 else "s", ", ".join(parts)], "good")
	notify("salvaged")


func runes_found() -> Array:
	var key := "dm_runes_found_v1_%d" % int(game.character["id"])
	var raw: Variant = DmUiConfig.parse(store.get_item(key))
	var found: Array = raw if raw is Array else []
	var grew := false
	for id in DmRunes.owned_runes(game.slots).keys() + DmRunes.sockets_of(game.slots).values():
		if not found.has(id):
			found.append(id)
			grew = true
	if grew:
		store.set_item(key, JSON.stringify(found))
	return found


static func _truthy(v: Variant) -> bool:
	return v != null and bool(v)
