class_name DmNextUiHost
extends Node
## The view-model adapter between DmNextGame and the existing DmGameUi / DmHud / panels: it implements the host side of
## the DmGameUi contract (character, slots, progress, settings, api, area_id, camera, hud_state(), cast(), refresh_*(), the signals) on top of
## the slice's nodes, so the real HUD and panels run unchanged. Child "UiHost" of DmNextGame.
##
## Reads: DmHeroBody (vitals), DmRiteCaster (cooldowns, essence, hit numbers, rejections), DmThrallHost (legion), DmStatusSet, the rewards
## member (character xp/gold, bag). Writes: rite casts (`request_cast`), the bag (DmInventory: loot pickups land in it and flush to the api).
## Loadout: DmLoadout.load_rites(DmContent.kit family defaults); one place, changed by the Grimoire through set_rites().

signal character_changed
signal inventory_changed
signal learned_runes_changed   ## learned_runes changed (note_learned)
signal progress_changed
signal area_changed(id: String)
signal hero_died
signal hero_respawned
signal game_event(event_id: String, ctx: Dictionary)
signal npc_interact(npc_id: String)
signal station_interact(station_id: String)
signal left_world
signal character_switch                           ## Settings -> "Switch character": back to the select screen on the same session
signal world_restart(character: Dictionary)   ## the class panel saved a new discipline: the front rebuilds the world with it
signal sfx(name: String)                     ## every sound the adapter forwards to the AudioDirector (tests listen here)
signal feedback(text: String)                ## a cast was refused / unavailable (also drawn as a float over the hero)
signal party_changed                         ## the lobby / party state changed (the Social window's Party tab redraws from party_view())
signal friends_changed                       ## the friends list changed (the Social window's Friends tab redraws from friends_view())

const REJECT_TEXT := {"essence": "Not enough Grave Essence", "souls": "Not enough souls (%d needed)", "cooldown": "%s is not ready", "locked": "%s unlocks at level %d"}
const FEEDBACK_GAP_MS := 600
const CLIENT_OWNED_CHARACTER_FIELDS := ["gold", "level", "experience", "stat_str", "stat_agi", "stat_int", "stat_vit"]
const PARTY_ALTAR := "The Altar answers only in your own world: leave the party first."
const HERO_STATUS_TEXT := {&"chill": "Chilled", &"root": "Rooted", &"stun": "Stunned"}   ## the old game's floats over the hero (DmGameCombat.on_hurt / drag_player)

var shell: DmNextGame
var api: Variant
var character: Dictionary
var prog: DmProgression
var inventory: DmInventory
var settings_store: DmSettings
var kit: Dictionary
var primary: String = "bone_needle"
var keys: Array = []                         ## the five rites on 1-4 / RMB (hotbar slot i+1), from DmLoadout
var signature: String = ""                   ## the discipline's signature rite on R (hotbar slot 6)
var in_depths := false
var hero_id: int = 0
var release := "godot-next-" + str(ProjectSettings.get_setting("application/config/version", "dev"))
var in_party: bool:                          ## hosting or joined: DmGameUi's /party, Settings and bug reports read it
	get: return shell != null and shell.party != null and shell.party.in_party()
var dev_account := false
var dev_access := false
var vm: DmNextHudVm
var counsel: DmNextCounsel
var persist := true

var slots: Array:
	get: return inventory.slots
	set(v): inventory.slots = v
var psync: DmProgressSync:
	get: return shell.progress.psync if shell.progress != null else (shell.joiner.psync if shell.joiner != null else null)
var progress: Dictionary:
	get: return prog.local
var settings: Dictionary:
	get: return settings_store.values
var area_id: String:
	get: return shell.area_id
var camera: Camera3D:
	get: return shell.camera
var sim: Object = null
var lootview: Object = null

var _kills: Dictionary = {}
var _bound: Dictionary = {}                  ## body instance id -> true: its caster / hurt signals are connected
var _bind_t := 0.0
var _last_feedback := 0
var _character_seq := 0
var _full_at := -100000
var _bag_full_noticed := false
var _got_gold := 0
var _got_shards := 0
var _got_pending := false
var _loot_tip_sent := false
var _vault_runes: Dictionary = {}            ## rune ids in the account's Vault (note_vault): a rune drop never repeats one the player owns
## The character's learned runes (rune id -> true; GET /api/runes, every learn): what the Grimoire offers per rite, and never dropped again.
var learned_runes: Dictionary = {}
var _hero_status: Dictionary = {}            ## status id -> true while the local hero has it (a float on the way in, not on every refresh)
var _target_id := 0
var _target_until := 0.0
var _build: Dictionary = {}
var _build_level := -1


## Called by DmNextGame.start after the body, character and rewards exist (before DmGameUi.setup).
func setup(shell_: DmNextGame, persist_: bool = true) -> void:
	shell = shell_
	persist = persist_
	api = shell.api
	character = shell.character
	hero_id = int(character.get("id", 0))
	var b := shell.local_body()
	var family: String = b.family if b != null else "necromancer"
	kit = DmAbilities.kit_for(family)
	signature = String(kit["signatures"].get(DmCharacterBuild.discipline_for(float(shell.character.get("class_index", 0)))["id"], ""))
	var m: DmRewardsMember = shell.my_member()   # the host's own member, or a joiner's (DmNextJoiner)
	var credits: Object = shell.rewards if shell.rewards != null else shell.joiner
	if m != null:
		prog = m.prog
		prog.character = character           # xp / level / gold credited by the rewards land straight in the character the UI reads
		credits.member_credited.connect(_on_credited)
		if shell.joiner != null:
			shell.joiner.event.connect(game_event.emit)   # a joiner's level-up banner / toasts
		if shell.progress != null:
			shell.progress.event.connect(game_event.emit)   # level-up banner, milestone / seal toasts, belt floats
		if shell.meta != null:
			shell.meta.event.connect(game_event.emit)       # difficulty toast, Soul Harvest, chain tiers, bonded dead
		if shell.rewards != null:
			shell.rewards.kill_earned.connect(func(c: int, _d: String, _p: Vector3) -> void: if c == hero_id: _kills[shell.area_id] = int(_kills.get(shell.area_id, 0)) + 1)
			shell.rewards.kill_counted.connect(func(_c: int, a: String) -> void: if _c == hero_id: _kills[a] = int(_kills.get(a, 0)) + 1)   # party kills it was not paid for
		else:   # a joiner counts the kills the host's accepted report credited to it
			shell.joiner.member_credited.connect(func(_c: int, d: Dictionary) -> void: _kills[shell.area_id] = int(_kills.get(shell.area_id, 0)) + int(d.get("kills", 0)))
	else:
		prog = DmProgression.new(character, null)
	if shell.corpses != null:   # the counsel's Exhume tip (DmEventFx._corpse): once per corpse laid
		shell.corpses.corpse_added.connect(func(c: DmSimCorpse) -> void:
			game_event.emit("corpse_near", {"area_safe": bool(DmContent.area(shell.area_id)["safe"]), "dist": _dist_hero(c.x, c.z)}))
	inventory = DmInventory.new(api, hero_id)
	inventory.changed.connect(func(_s: Array) -> void: inventory_changed.emit())
	inventory.save_failed.connect(func(m_: String) -> void: game_event.emit("toast", {"text": "Your bag could not be saved: %s. Retrying. Your items are safe on screen." % m_, "kind": "err"}))
	inventory.save_recovered.connect(func() -> void: game_event.emit("toast", {"text": "Bag saved.", "kind": "good"}))
	if shell.progress != null:
		shell.progress.belt.inventory = inventory
		inventory.changed.connect(func(_s: Array) -> void: shell.progress.request_stats())   # worn gear feeds the stats
	if m != null:
		m.take_item = Callable(self, "_take")   # a walked-over drop goes into the bag, which flushes to the backend
		m.owned_legendaries = Callable(self, "_owned_legendaries")
		m.loot_view.picked.connect(_on_picked)
		m.loot_view.rune_found.connect(_on_rune_found)
		m.loot_view.legendary_dropped.connect(_on_legendary_dropped)
		m.loot_view.rune_owned = Callable(self, "_owns_rune")
		m.loot_view.claim_requested.connect(_on_claim)
		_load_vault_runes()
	_load_learned_runes()
	settings_store = DmSettings.new(DmSettings.FILE, persist)
	settings_store.set_active_character(hero_id, character.get("auto_combat_allowed", false) == true)
	settings_store.changed.connect(func(_v: Dictionary) -> void: _apply_settings_side_effects())
	dev_account = _is_dev_account()   # old DmGame.setup: dev_access = dev_account and the Settings toggle; everything that reads it follows below
	dev_access = dev_account and bool(settings["dev_access"])
	_push_dev_access()
	_tell_server_gm_mode()
	if dev_access and shell.chapterhouse != null:
		shell.chapterhouse.apply_seals()   # sealed halls stand open for the dev preview from the first frame
	var r := DmLoadout.load_rites(hero_id, DmAbilities.rite_level(float(character.get("level", 1)), dev_access), kit, persist)
	primary = String(r["primary"])
	keys = r["keys"]
	vm = DmNextHudVm.new(self)
	counsel = DmNextCounsel.new(self)
	if m != null:
		m.loot_view.dropped_sound.connect(_on_item_landed)
	if shell.chapterhouse != null:          # NPC / station use -> the events DmGameUi opens dialogue and panels from
		shell.chapterhouse.npc_interact.connect(func(id: String) -> void: npc_interact.emit(id))
		shell.chapterhouse.station_interact.connect(func(id: String) -> void: station_interact.emit(id))
	shell.input.hotbar.connect(_on_hotbar)
	if shell.party != null:
		shell.party.changed.connect(party_changed.emit)
		shell.party.notice.connect(func(t: String, k: String) -> void: game_event.emit("toast", {"text": t, "kind": k}))
		shell.party.social_notice.connect(func(t: String) -> void: game_event.emit("toast", {"text": t, "kind": "", "open": "friends"}))
	if shell.friends != null:
		shell.friends.changed.connect(friends_changed.emit)
		shell.friends.requests_waiting.connect(_on_friend_requests)
	shell.area_changed.connect(func(id: String) -> void: area_changed.emit(id))
	shell.hero_died.connect(func(_b: DmHeroBody) -> void: hero_died.emit())
	shell.hero_respawned.connect(func(_b: DmHeroBody) -> void: hero_respawned.emit())
	_apply_settings_side_effects()
	await refresh_inventory()
	_bind_bodies()
	set_process(true)


func _process(dt: float) -> void:
	if shell == null:
		return
	inventory.tick(dt)
	_bind_t -= dt
	if _bind_t <= 0.0:
		_bind_t = 0.5
		_bind_bodies()


func _unhandled_key_input(event: InputEvent) -> void:
	var e := event as InputEventKey
	if e == null or not e.pressed or e.echo or get_viewport().gui_get_focus_owner() is LineEdit:
		return
	if e.keycode == KEY_Q:
		use_belt("heal")
	else:
		for slot in ["elixir", "tonic"]:   # Z / X (BREW_KEYS)
			if e.keycode == OS.find_keycode_from_string(String(DmContent.get_export("brews", "BREW_KEYS")[slot])):
				use_belt(slot)


# ---- DmGameUi contract: state ---------------------------------------------------------------------------------------------------------

func hud_state() -> Dictionary:
	return vm.build()


func build_cache() -> Dictionary:
	var lvl := int(character.get("level", 1))
	if _build.is_empty() or lvl != _build_level:
		_build = shell.build_for(shell.session.get_my_id())
		_build_level = lvl
	return _build


## The stats were re-read (a tier, gear, a level): drop the cached build.
func build_changed() -> void:
	_build = {}


func kills_in(area: String) -> int:
	return int(_kills.get(area, 0))


## The server's view of the character (fields the server owns only, newest request wins, as old DmGame.refresh_character): the Workbench, Vault
## and Altar panels change the backend and call this.
func refresh_character() -> void:
	_character_seq += 1
	var seq := _character_seq
	var r: DmResult = await api.get_character()
	if seq == _character_seq and r.ok and r.data is Dictionary:
		for k in r.data:
			if k in CLIENT_OWNED_CHARACTER_FIELDS and character.has(k):
				continue
			character[k] = r.data[k]
	character_changed.emit()
	await load_cosmetics()


## The saved cape and companion (the Capes & Pets panel writes them, then refreshes the character): the hero wears them.
func load_cosmetics() -> void:
	var r: DmResult = await api.get_cosmetics(hero_id)
	if r.ok and r.data is Dictionary and r.data.get("selected") is Dictionary and shell.look != null:
		shell.look.set_cosmetics(r.data["selected"])


## The Altar's vows / boons / ascension live on the backend: adopt its necro state (plus what was gathered since), as old DmGame.refresh_progress.
func refresh_progress() -> void:
	var before := _thrall_numbers()
	var tier0 := int(prog.local["legionTier"])
	var r: DmResult = await api.necro_get(hero_id)
	if r.ok and r.data is Dictionary and r.data.has("progress"):
		prog.adopt(r.data["progress"])
	if int(prog.local["legionTier"]) > tier0:
		await _adopt_server_gold()   # the Legion panel bought it straight from the backend: the purse it took must not be overwritten by the next save
	_refresh_standing_thralls(before)
	progress_changed.emit()


## The Altar (old DmGame.do_ascend / do_swear / do_open / the Ascension panel): the backend rules the state (ashes, vows, unlocks, boons), `refresh_progress`
## adopts it, and DmNextProgress.apply_progress -> DmNextMeta.sync carries it into the world. "" = done, else the Altar's refusal.
func do_ascend() -> String:
	if shell.progress == null:
		return PARTY_ALTAR
	var heat := DmAscension.vow_heat(prog.vows())
	await shell.progress.psync.flush()   # the run's kills are what the Ashes pay for: bank them first, or they land on the NEXT run
	var r: DmResult = await api.necro_ascend(hero_id)
	if not r.ok:
		return r.error if r.error != "" else "The Altar refuses."
	await refresh_progress()
	var earned := int((r.data as Dictionary).get("earned", 0)) if r.data is Dictionary else 0
	game_event.emit("banner", {"title": "Ascended at heat %d" % heat, "sub": "+%d Ashes · swear your vows for the next run" % earned, "ms": 4200})
	shell.progress.sfx("levelUp")
	return ""


func do_swear(next: Dictionary) -> String:
	if shell.progress == null:
		return PARTY_ALTAR
	await shell.progress.psync.flush()   # a vow change restarts the run's tally: the kills so far must be in it
	var r: DmResult = await api.necro_vows(hero_id, next)
	if not r.ok:
		return r.error if r.error != "" else "The Altar refuses."
	await refresh_progress()
	game_event.emit("toast", {"text": "Vows sworn: heat %d" % DmAscension.vow_heat(prog.vows()), "kind": "good"})
	shell.progress.sfx("shard")
	return ""


## `key` "vow:<id>" / "boon:<id>" opens it with shards; a bare boon id buys the next rank with ashes (the panel's two buttons).
func do_open(key: String) -> String:
	var r: DmResult = await (api.necro_unlock(hero_id, key) if key.contains(":") else api.necro_boon(hero_id, key))
	if not r.ok:
		return r.error if r.error != "" else "The Altar refuses."
	await refresh_progress()
	game_event.emit("toast", {"text": "%s unlocked" % key.substr(key.find(":") + 1) if key.contains(":") else "Boon deepened: %s" % key, "kind": "good"})
	shell.progress.sfx("levelUp")
	return ""


## Bag edits the Reliquary makes (GAME_CONTRACT.md; as old DmGame): `slots` is for reading, these change the bag.
func bag_remove(slot_index: int, _item_id: String, n: int) -> int:
	return inventory.remove_from_slot(slot_index, n)


func bag_sort(on_moves: Callable = Callable(), is_locked: Callable = Callable()) -> void:
	inventory.sort_bag(on_moves, is_locked)


## Save the bag now. "" = the server has it; otherwise the reason (the player was told by a toast).
func bag_commit() -> String:
	return await inventory.commit()


func refresh_inventory() -> void:
	var r: DmResult = await api.get_inventory(hero_id)
	if r.ok and r.data is Array:
		inventory.replace(r.data)
	inventory_changed.emit()


func apply_settings(s: Dictionary) -> void:
	if s != settings_store.values:
		settings_store.update(s)
	else:
		_apply_settings_side_effects()


const DEV_ACCOUNTS := ["brbmuffins"]


## gm_enabled on the character, or a DEV_ACCOUNTS name in the session token (downloadable offline profiles can never be staff).
func _is_dev_account() -> bool:
	if character.get("gm_enabled", false) == true:
		return true
	var tok: String = api.get_token()
	if tok.begins_with("offline:"):
		return false
	return DmMain.token_username(tok).to_lower() in DEV_ACCOUNTS


## Every consumer of dev access on the rebuild: the progression (sealed areas, kills banked), the gathering tiers, the host's own caster (locked rites),
## the world's gates. Event driven (setup, the Settings toggle); no per-frame work.
func _push_dev_access() -> void:
	if prog != null:
		prog.dev_access = dev_access
	if shell.gather != null:
		shell.gather.skills.dev_access = dev_access
	var b := shell.local_body()
	var c := b.get_node_or_null("Rites") as DmRiteCaster if b != null else null
	if c != null:
		c.dev = dev_access and shell.session.is_host()   # the host validates casts: a client's flag is never trusted


## GM mode toggle (Settings -> GM mode; off = a normal player): rites, areas and gathering tiers open or close, and the server follows.
func _apply_dev_access() -> void:
	if not dev_account:
		return
	var on := bool(settings["dev_access"])
	if on == dev_access:
		return
	dev_access = on
	_push_dev_access()
	_tell_server_gm_mode()
	if shell.chapterhouse != null:
		shell.chapterhouse.apply_seals()
	progress_changed.emit()
	game_event.emit("toast", {"text": "GM mode on: every rite, area and gathering tier is open; the server logs what you save and marks this character GM." if on else "GM mode off: playing as a normal player, checked like everyone else.", "kind": "good"})


## The server follows the GM mode toggle (POST /api/gm/mode, backend gm-mode.cjs): only while it is on does the server skip its checks for
## this account, and it logs every save. A dev account only; a normal player's client never asks (the server would refuse anyway).
func _tell_server_gm_mode() -> void:
	if not dev_account or api == null or api.get_token().begins_with("offline:"):
		return
	var on := dev_access
	var r: DmResult = await api.set_gm_mode(on)
	if not r.ok and on:
		game_event.emit("toast", {"text": "The server did not switch GM mode on: %s" % (r.error if r.error != "" else "try again"), "kind": "err"})


## F9 (dev tool): break every seal. Gated exactly like the Settings toggle's effects: only a dev account with GM mode on (never a normal player or a
## downloadable offline profile). The seals really break (saved), the gates and navmesh follow at once. Returns how many broke.
func dev_break_seals() -> int:
	if not dev_access or prog == null:
		return 0
	var n := 0
	for id in DmContent.area_order():
		if prog.unlock(String(id)):
			n += 1
	if shell.chapterhouse != null:
		shell.chapterhouse.apply_seals()
	progress_changed.emit()
	game_event.emit("toast", {"text": "Dev: %d seal%s broken." % [n, "" if n == 1 else "s"] if n > 0 else "Dev: every seal is already broken.", "kind": "good"})
	return n


func _apply_settings_side_effects() -> void:
	_apply_dev_access()
	DmAvatar.refresh_all()   # Hide helm
	if shell.meta != null:
		shell.meta.set_difficulty(String(settings["difficulty"]), not shell.ready_)   # Settings -> difficulty: the next dead to rise feel it
	var audio := get_node_or_null("/root/AudioDirector")
	if audio != null and shell.opts.get("audio", DisplayServer.get_name() != "headless"):
		audio.apply_settings(settings_store.audio_dict())
	var vfx := get_node_or_null("/root/Vfx")
	if vfx != null:
		vfx.quality = String(DmGraphicsPreset.get_preset(settings["graphics"])["fx"])
		vfx.reduced_motion = bool(settings["reduce_motion"])
	if shell.perf != null:
		shell.perf.apply(settings)
	if shell.camera != null:
		shell.camera.reduced_motion = bool(settings["reduce_motion"])


func set_auto_combat(on: bool) -> void:
	settings_store.update({"auto_combat": on})


## Spends gold on the tier (the backend prices it); the tier reaches the rites' stats and the wave director (DmNextProgress.buy).
func buy_upgrade(kind: String) -> void:
	if kind == "legion":
		await buy_legion()
		return
	if shell.progress.buy(kind) if shell.progress != null else (prog.buy_damage() if kind == "damage" else prog.buy_wave()):
		progress_changed.emit()
		character_changed.emit()


func set_rites(new_primary: String, new_keys: Array) -> void:
	primary = new_primary
	keys = new_keys.duplicate()
	DmLoadout.save_rites(hero_id, {"primary": primary, "keys": keys}, persist)


## The Q key and the Reliquary's Drink: a healing flask (the heal belt chip). Host-side vitals; a joiner's drink is a later phase.
func use_item(item_id: String) -> void:
	if shell.progress == null and shell.joiner != null:
		_party_belt_note()
		return
	if shell.progress != null and shell.session.is_host():
		shell.progress.belt.use(item_id)   # a flask, brew or meal, with the old game's rules (cooldown, replace / extend, Dry Cellar)


func use_belt(slot: String) -> void:
	if shell.progress == null or not shell.session.is_host():
		if shell.joiner != null:
			_party_belt_note()
		return
	if slot == "heal":
		shell.progress.belt.drink_flask()
	else:
		shell.progress.belt.drink_belt(slot)


func _party_belt_note() -> void:
	game_event.emit("toast", {"text": "Flasks and brews work only in your own world for now.", "kind": ""})


## The UI keeps the belt pick in its store and tells the game which brew a slot holds.
func set_belt(slot: String, item_id: String) -> void:
	if shell.progress != null:
		shell.progress.belt.set_belt(slot, item_id)


# ---- hub: the Chapterhouse node (next/chapterhouse/) answers these DmGameUi calls ------------------------------------------------------

func talk_key() -> void:
	if shell.chapterhouse != null:
		shell.chapterhouse.talk_key()


func travel(area_id_: String) -> void:
	if shell.chapterhouse != null:
		shell.chapterhouse.travel(area_id_)


## The stair card's "Start at depth 1" / "Resume at deepest" (DmGameUi calls enter_depths).
func enter_depths(depth: int) -> void:
	if shell.depths != null:
		shell.depths.enter(depth)


func stop_player() -> void:
	if shell.chapterhouse != null:
		shell.chapterhouse.stop_player()


## Gathering (DmGameUi's Skills tab calls these by name through call_game_sync): AFK in the Acre, pause on a panel / move.
func start_afk(node_id: String) -> String:
	var err: String = await shell.gather.start_afk(node_id)
	if err != "":
		game_event.emit("toast", {"text": err, "kind": "err"})
	return err


func stop_gathering(reason: String) -> void:
	if shell.gather != null:
		shell.gather.stop_gathering(reason)


## The Boss key prompt's two answers (DmGameUi calls them by name): wake it with soul shards / call it Empowered (next/bosses/dm_boss_meta.gd).
func summon_boss(id: String) -> void:
	if shell.boss_meta != null:
		shell.boss_meta.summon_normal(id)


func summon_boss_empowered(id: String) -> void:
	if shell.boss_meta != null:
		shell.boss_meta.call_empowered(id)


## The Codex's Chronicle tab reads the backend: send what is pending first (DmUiPanelsA._load_chronicle).
func flush_chronicle() -> void:
	if shell.chron != null:
		await shell.chron.flush()


func afk_active() -> bool:
	return shell.gather != null and shell.gather.loop != null and shell.gather.loop.afk


func afk_status() -> Dictionary:
	return shell.gather.afk_status() if shell.gather != null else {}


func near_grinder() -> bool:
	return shell.chapterhouse != null and shell.chapterhouse.near_grinder()


## The Acre panels' hooks (DmUiPanelsB): the glue that owns the labor / garden / contract rules is `DmNextAcre` (next/gathering/).
func on_labor_collected(r: Dictionary, slot: int) -> void:
	if shell.acre != null:
		shell.acre.on_labor_collected(r, slot)


func on_garden_result(kind: String, r: Dictionary) -> void:
	if shell.acre != null:
		shell.acre.on_garden_result(kind, r)


func on_contract_delivered(d: Dictionary) -> void:
	if shell.acre != null:
		shell.acre.on_contract_delivered(d)


func navigate(x: float, z: float) -> void:
	shell.input.click_move(Vector3(x, 0.0, z))
	game_event.emit("minimap_travel", {})   # the counsel's minimap tip (DmGameInput.click_minimap)


func send_chat(text: String) -> void:
	if shell.party == null or not shell.party.chat(text):
		game_event.emit("chat", {"text": "(solo) Nobody hears you in the dark."})


# ---- party / lobby (DmNextParty; the Social window's Party tab reads party_view() and calls these) ---------------------------------------------------

func party_view() -> Dictionary:
	return shell.party.view() if shell.party != null else {}


## The window opened / closed: a lobby socket is kept (and the list refreshed) only while it is open.
func party_watch(on: bool) -> void:
	shell.party.set_watching(on)


func party_refresh() -> void:
	shell.party.refresh()


## DmGameUi's /party and Settings' "Make a party": hosts a Closed party (the Party tab's Host form picks the name and Open / Closed).
func party_create(session_name: String = "", is_private: bool = true) -> void:
	if shell.party.in_party():   # already hosting (or joined): show the party instead of a refusal
		game_event.emit("panel_toggle", {"panel": "party"})
		return
	shell.party.host_session(session_name, is_private)


func party_join_id(id: String, code: String = "") -> void:
	shell.party.join_session(id, code)


func party_leave() -> void:
	shell.party.leave()


func party_kick(peer_id: int) -> void:
	shell.party.kick(peer_id)


func party_set_closed(closed: bool) -> void:
	shell.party.set_closed(closed)


# ---- friends (DmNextFriends; the Social window's Friends tab reads friends_view() and calls these) -----------------------------------------

func friends_view() -> Dictionary:
	return shell.friends.view() if shell.friends != null else {}


func friends_refresh() -> void:
	shell.friends.refresh()


func friends_request(username: String) -> void:
	shell.friends.send_request(username)


func friends_accept(account_id: int) -> void:
	shell.friends.accept(account_id)


func friends_remove(account_id: int) -> void:
	shell.friends.remove(account_id)


func friends_join(account_id: int) -> void:
	shell.party.join_friend(account_id)


func friends_ask(account_id: int) -> void:
	shell.party.ask_to_join(account_id)


func friends_invite(account_id: int) -> void:
	shell.party.invite_friend(account_id)


func invite_answer(from_id: int, accept: bool) -> void:
	if accept:
		shell.party.accept_invite(from_id)
	else:
		shell.party.decline_invite(from_id)


func ask_answer(account_id: int, accept: bool) -> void:
	shell.party.answer_request(account_id, accept)


func _on_friend_requests(names: Array) -> void:
	var who := String(names[0]) if names.size() == 1 else "%d players" % names.size()
	game_event.emit("toast", {"text": "%s asked to be your friend. Answer in Social (O)." % who, "kind": "", "open": "friends"})


func leave_world() -> void:
	left_world.emit()


func switch_character() -> void:
	character_switch.emit()


## ClassPanel -> a new discipline: the shell tears the session down and re-enters with the new character (old DmGame.class_changed).
func class_changed(new_character: Dictionary) -> void:
	world_restart.emit(new_character)


# ---- hotbar: HUD click / key / mouse -> DmRiteCaster.request_cast -------------------------------------------------------------------

## The rite id of a hotbar slot: 0 = LMB primary, 1..5 = keys 1-4 and RMB, 6 = R (the signature).
func rite_at(slot: int) -> String:
	if slot == 0:
		return primary
	if slot == 6:
		return signature
	return String(keys[slot - 1]) if slot - 1 < keys.size() else ""


## HUD slot click (0 = LMB, 1..): aims at the cursor like the key does.
func cast(slot: int) -> void:
	var i := shell.input
	var tid := i.hovered_enemy_id()
	var e := shell.enemy_by_id(tid) if tid != 0 else null
	_on_hotbar(slot, e.global_position if e != null else i.aim_point(), tid if e != null else 0)


func _on_hotbar(slot: int, aim: Vector3, enemy_id: int) -> void:
	var b := shell.local_body()
	var caster := b.get_node_or_null("Rites") as DmRiteCaster if b != null else null
	var id := rite_at(slot)
	if caster == null or id == "":
		return
	if not DmRiteRegistry.has(id):               # rites present in the slice (next/rites/dm_rite_registry.gd)
		_feedback("%s is not in the slice yet" % String(DmAbilities.def(id)["name"]))
		return
	if enemy_id != 0:
		_target_id = enemy_id
		_target_until = Time.get_ticks_msec() + 4000.0
	if shell.gather != null:
		shell.gather.stop_gathering("moved")     # casting pauses gathering
	caster.request_cast(id, aim, enemy_id if enemy_id != 0 else -1)
	game_event.emit("slot_flash", {"slot": slot})


func _on_rejected(rite: String, reason: String) -> void:
	var def := DmAbilities.def(rite)
	match reason:
		"essence":
			game_event.emit("essence_short", {})
			_feedback(REJECT_TEXT["essence"])
		"souls":
			_feedback(REJECT_TEXT["souls"] % int(def.get("soulCost", 0)))
		"cooldown":
			_feedback(REJECT_TEXT["cooldown"] % def["name"])
		"locked":
			_feedback(REJECT_TEXT["locked"] % [def["name"], int(DmAbilities.unlock_level(rite))])


## The old game's cast feedback: one "info" float over the hero, at most every 600 ms.
func _feedback(text: String) -> void:
	var now := Time.get_ticks_msec()
	if now - _last_feedback < FEEDBACK_GAP_MS:
		return
	_last_feedback = now
	var b := shell.local_body()
	if b != null:
		float_text(b.position + Vector3(0, 2.4, 0), text, "info")
	feedback.emit(text)


## The enemy the target frame shows: the one under the cursor, else the last one a cast was aimed at for a few seconds.
func target_enemy() -> DmEnemy:
	var tid := shell.input.hovered_enemy_id()
	if tid == 0 and Time.get_ticks_msec() < _target_until:
		tid = _target_id
	var e := shell.enemy_by_id(tid) if tid != 0 else null
	return e if e != null and e.sm != null and e.sm.id() != DmEnemyState.Id.DEAD else null


# ---- floating text, toasts ----------------------------------------------------------------------------------------------------------

var floats := DmFloatBudget.new()   ## on-screen cap of the combat numbers (hit / crit / dot / thrall)


func float_text(pos: Vector3, text: String, kind: String = "info", color: Variant = null) -> void:
	if not bool(settings["damage_numbers"]) and kind in ["hit", "crit", "dot", "thrall", "hurt"]:
		return
	if not floats.allow(kind, float(Time.get_ticks_msec())):
		return
	var ctx := {"world": pos, "text": text, "kind": kind}
	if color != null:
		ctx["color"] = color
	game_event.emit("float", ctx)


func _on_hit_number(pos: Vector3, amount: float, crit: bool) -> void:
	float_text(Vector3(pos.x, 1.6, pos.z), str(DmMath.js_round(amount)), "crit" if crit else "hit")


func _on_hurt(amount: float, _source: Node) -> void:
	var b := shell.local_body()
	if b == null:
		return
	float_text(b.position + Vector3(0, 2.0, 0), "-%d" % DmMath.js_round(amount), "hurt")
	game_event.emit("hit_flash", {})
	_hurt_feeds(b)


## Who the gear text is for (DmGameRewards.stat_context): the compare / "worth wearing" rules read it.
func stat_context() -> Variant:
	var b := build_cache()
	return {"character": character, "slots": inventory.slots, "discipline": b["discipline"], "damageTier": float(progress.get("damageTier", 0)), "legion": b["legion"]}


## DmLootView.try_take: the bag, or false (the drop stays on the ground) with a "Reliquary full" float now and then and, once, what to do about it.
## Legendary pieces worn or in the bag: what a legendary roll avoids repeating (the server reads the same from its rows).
func _owned_legendaries() -> Array:
	var out: Array = []
	for row in inventory.all():
		var id := String(row.get("item_id", ""))
		if id.begins_with("leg_") and not out.has(id):
			out.append(id)
	return out


func _take(d: Dictionary) -> bool:
	if inventory.add(d):
		_bag_full_noticed = false   # room again: the next time something does not fit, say so once more
		return true
	var now := Time.get_ticks_msec()
	if now - _full_at > 8000:
		_full_at = now
		var b := shell.local_body()
		if b != null:
			float_text(b.position + Vector3(0, 2.4, 0), "Reliquary full", "info")
	if not _bag_full_noticed:
		_bag_full_noticed = true
		game_event.emit("toast", {"text": "Your Reliquary is full. Sell spare gear (Sell all junk) or, back in the Chapterhouse or the Acre, store materials in the Vault (V). What you cannot carry stays on the ground for a minute.", "kind": "err"})
	return false


const GOT_WINDOW_S := 1.2

func _on_picked(ev: Dictionary) -> void:
	match String(ev["kind"]):
		"gold":
			_got_gold += int(ev["amount"])
			_schedule_got()
		"shard":
			_got_shards += int(ev["amount"])
			_schedule_got()
		"item":
			var it: Dictionary = ev["item"]
			var meta := DmContent.item(String(it["item_id"]))
			_loot_toast(it, meta)
			_item_collected(it, meta)


## Gold and shards credited within GOT_WINDOW_S are one float + one sound: a fight pays out once, not per pile.
func _schedule_got() -> void:
	if not _got_pending:
		_got_pending = true
		get_tree().create_timer(GOT_WINDOW_S).timeout.connect(_flush_got)


func _flush_got() -> void:
	_got_pending = false
	var b := shell.local_body()
	var at: Vector3 = b.position if b != null else Vector3.ZERO
	if _got_gold > 0:
		float_text(at + Vector3(0, 2.1, 0), "+%dg" % _got_gold, "gold")
		_sfx("coin")
	if _got_shards > 0:
		float_text(at + Vector3(0, 2.3, 0), "+%d soul shard%s" % [_got_shards, "s" if _got_shards > 1 else ""], "shard")
		_sfx("shard")
	_got_gold = 0
	_got_shards = 0


## The pickup toast: the name in the colour the beam had on the ground (affixes raise it), and "(upgrade)" on a piece that beats what you wear.
func _loot_toast(it: Dictionary, meta: Dictionary) -> void:
	var nm := _loot_name(it, meta)
	if DmAffixRules.is_affix_gear(String(meta.get("type", ""))):
		var slot: Variant = DmLoot.add_to_slots([], it)
		if slot != null and not (slot as Array).is_empty():
			var sl: Dictionary = (slot as Array)[0]
			if it.get("instance") != null:
				sl["inst"] = it["instance"]
			if DmItemText.badge(stat_context(), sl) == "up":
				nm += " (upgrade)"
	game_event.emit("loot", {"name": nm, "qty": int(it.get("quantity", 1)), "rarity": DmLootView.rarity_of(it)})


## The loot name as the player knows it: affixed gear reads "Cruel Bone Wand of X".
func _loot_name(it: Dictionary, meta: Dictionary) -> String:
	var nm := String(meta.get("name", it["item_id"]))
	if it.get("instance") != null:
		nm = DmAffixRules.affixed_name(nm, it["instance"]["affixes"])
	return nm


## An item landed on the ground: its drop sound (by rarity, positioned) and, once per session, the counsel's "click to pick up" tip.
func _on_item_landed(sound_id: String, pos: Vector3) -> void:
	_sfx(sound_id, pos)
	if not _loot_tip_sent:
		_loot_tip_sent = true
		game_event.emit("loot_landed", {})


## A rune the player did not own went straight into the bag: the pickup's sound, toast and counsel facts, and a line in chat (the party sees it too).
func _on_rune_found(drop: Dictionary, _pos: Vector3) -> void:
	var meta := DmContent.item(String(drop["item_id"]))
	_loot_toast(drop, meta)
	_item_collected(drop, meta)
	var rune: Dictionary = DmContent.get_export("runes", "RUNES").get(String(drop["item_id"]), {})
	var nm := String(meta.get("name", drop["item_id"]))
	var short := String(rune.get("short", ""))
	var reaper := shell.local_body() != null and shell.local_body().family != "necromancer"
	_loot_chat("You found the %s%s%s. Select it in your Reliquary (I) and click Learn." % [nm, (": " + short.substr(0, 1).to_lower() + short.substr(1)) if short != "" else "", " (a necromancer rune)" if reaper else ""],
		"{who} found the %s." % nm)


func _on_legendary_dropped(drop: Dictionary, _pos: Vector3) -> void:
	var nm := _loot_name(drop, DmContent.item(String(drop["item_id"])))
	_loot_chat("You found %s (legendary)." % nm, "{who} found %s (legendary)." % nm)


## A find worth telling: in a party every member reads `party_line` ("{who}" = the finder's roster name) in chat, solo you read `own_line`.
func _loot_chat(own_line: String, party_line: String) -> void:
	if shell.party != null and shell.party.announce(party_line):
		return
	game_event.emit("chat", {"text": own_line})


## DmLootView.rune_owned: a rune the character has learned, holds (bag, sockets) or keeps in the Vault (note_vault) does not drop again.
func _owns_rune(drop: Dictionary) -> bool:
	var id := String(drop["item_id"])
	if learned_runes.has(id) or _vault_runes.has(id):
		return true
	for r: Dictionary in inventory.slots:
		if r.get("item_id") == id:
			return true
	return false


## Reliquary -> Drop: the gear on `row` goes onto the party session's ground at the hero's feet (ground.cjs). It stays until the session ends;
## the server says who may take it (you, and members who were there when it was found) and the party draws it for them. "" = dropped, else why not.
func drop_gear(row: Dictionary) -> String:
	var b := shell.local_body()
	var sid := shell.party_session_id()
	if b == null or not b.alive or sid == "":
		return "You can only drop gear while you are in the world."
	var err := await bag_commit()   # unsaved bag edits first: the server's answer replaces the bag
	if err != "":
		return "Could not save the bag first: %s" % err
	var r: DmResult = await api.ground_drop(hero_id, sid, int(row["slot_index"]), b.position.x, b.position.z)
	if not r.ok:
		return r.error if r.error != "" else "It would not drop."
	inventory.replace(r.data["bag"])
	inventory_changed.emit()
	var entry := {"drop_id": String(r.data["dropId"]), "item": r.data["item"], "x": b.position.x, "z": b.position.z, "eligible": r.data["eligible"]}
	show_shared_drop(entry)
	if shell.party != null:
		shell.party.share_ground(entry)
	return ""


## Draw a dropped piece (ours, or one the host relayed because the server lets us take it).
func show_shared_drop(entry: Dictionary) -> void:
	var m: DmRewardsMember = shell.my_member()
	if m != null:
		m.loot_view.shared_item(entry)


func remove_shared_drop(drop_id: String) -> void:
	var m: DmRewardsMember = shell.my_member()
	if m != null:
		m.loot_view.remove_shared(drop_id)


## The hero reached a dropped piece: the server hands it over (or says why not). The first pickup wins; everyone else's copy goes away.
func _on_claim(d: Dictionary) -> void:
	if d.get("claiming", false):
		return
	d["claiming"] = true
	if not d.has("drop_id"):
		await _claim_from_tape(d)
		return
	var id := String(d["drop_id"])
	var err := await bag_commit()
	var r: DmResult = await api.ground_pickup(hero_id, id) if err == "" else null
	d["claiming"] = false
	if r != null and r.ok:
		inventory.replace(r.data["bag"])
		inventory_changed.emit()
		remove_shared_drop(id)
		if shell.party != null:
			shell.party.share_taken(id)
		var meta := DmContent.item(String(d["item"]["item_id"]))
		_loot_toast(d["item"], meta)
		_item_collected(d["item"], meta)
		return
	var why := err if r == null else (r.error if r.error != "" else "You could not pick that up.")
	game_event.emit("toast", {"text": why, "kind": "err"})
	if why.begins_with("It is gone"):
		remove_shared_drop(id)


## A drop rolled from the tape (DECISIONS B20): the server rolls the same event again and puts its own roll in the bag. The ground copy goes once the
## server answers; it stays (and can be clicked again) only when the bag is full or the server could not be reached.
func _claim_from_tape(d: Dictionary) -> void:
	var m: DmRewardsMember = shell.my_member()
	var err := await bag_commit()
	var sid: String = shell.joiner.session_id if shell.joiner != null else (shell.rewards.session_id if shell.rewards != null else "")
	var r: DmResult = await api.drops_claim(hero_id, d["item"]["claim"], sid) if err == "" else null
	d["claiming"] = false
	if r != null and r.ok:
		inventory.replace(r.data["bag"])
		inventory_changed.emit()
		if m != null:
			m.loot_view.take_claimed(d)
			m.stats["items_picked"] += 1
		var g: Dictionary = r.data["item"]
		var got := {"item_id": String(g["item_id"]), "quantity": int(g.get("quantity", 1))}
		if g.has("ilvl"):
			got["instance"] = {"id": g.get("instance_id"), "ilvl": int(g["ilvl"]), "affixes": g.get("affixes", [])}
		var meta := DmContent.item(String(got["item_id"]))
		if DmRunes.is_rune_id(got["item_id"]) and m != null:
			m.loot_view.rune_found.emit(got, Vector3(float(d["x"]), 0, float(d["z"])))
		else:
			_loot_toast(got, meta)
		_item_collected(got, meta)
		return
	var why := err if r == null else (r.error if r.error != "" else "You could not pick that up.")
	game_event.emit("toast", {"text": why, "kind": "err"})
	var keep := r == null or r.status == 0 or r.status >= 500 or why.begins_with("Your bag is full")
	if not keep and m != null:
		m.loot_view.take_claimed(d)


## A left click on a drop (DmNextInput): the hero walks there and takes it on arrival. False = no drop under the cursor.
func loot_click(screen: Vector2) -> bool:
	var m: DmRewardsMember = shell.my_member()
	var b := shell.local_body()
	if m == null or b == null or not b.alive:
		return false
	var d := m.loot_view.pick(screen, shell.camera)
	if d.is_empty():
		return false
	m.loot_view.request_pickup(d)
	shell.input.click_move(Vector3(float(d["x"]), 0.0, float(d["z"])))
	return true


## Any other click or a WASD step: the hero no longer heads for a drop.
func loot_cancel() -> void:
	var m: DmRewardsMember = shell.my_member()
	if m != null:
		m.loot_view.cancel_pickup()


## The 10 Hz hover pick (DmNextInput): the drop under the cursor shows its name; Alt shows every name.
func loot_hover(screen: Vector2, enemy_hovered: bool, alt: bool) -> void:
	var m: DmRewardsMember = shell.my_member()
	if m == null:
		return
	m.loot_view.all_labels = alt
	m.loot_view.hover({} if enemy_hovered and not alt else m.loot_view.pick(screen, shell.camera))


## The Vault's rows (every {bag, vault} answer, and once at setup): which runes the account keeps there.
func note_vault(data: Dictionary) -> void:
	if not (data.get("vault") is Array):
		return
	_vault_runes.clear()
	for r: Dictionary in data["vault"]:
		if DmRunes.is_rune_id(r.get("item_id")):
			_vault_runes[String(r["item_id"])] = true


## The learned runes from a server answer ([rune ids]).
func note_learned(ids: Variant) -> void:
	if not (ids is Array):
		return
	learned_runes.clear()
	for id in ids:
		if DmRunes.is_rune_id(id):
			learned_runes[String(id)] = true
	learned_runes_changed.emit()


func _load_learned_runes() -> void:
	if api == null or not api.has_method("runes_learned"):
		return
	var r: DmResult = await api.runes_learned(hero_id)
	if r.ok and r.data is Dictionary:
		note_learned(r.data.get("learned"))


## In a fight (DmNextCounsel.busy: hurt in the last 4 s, three living dead within 9 m, or a boss awake): runes cannot be swapped.
func in_combat() -> bool:
	return counsel != null and bool(counsel.busy()["combat"])


func _load_vault_runes() -> void:
	if api == null or not api.has_method("get_vault"):
		return
	var r: DmResult = await api.get_vault(hero_id)
	if r.ok and r.data is Dictionary:
		note_vault(r.data)


func _on_credited(cid: int, delta: Dictionary) -> void:
	if cid != hero_id:
		return
	character_changed.emit()
	if shell.progress == null and int(delta.get("levels", 0)) > 0:   # DmNextProgress presents level-ups when it exists
		game_event.emit("toast", {"text": "Level %d reached" % int(character["level"]), "kind": "good"})
		game_event.emit("level_up", {"level": int(character["level"])})


## The local hero got chilled / rooted / stunned: the old game's float, once per status as it appears.
func _on_hero_statuses(hs: DmStatusSet) -> void:
	var b := shell.local_body()
	for id: StringName in HERO_STATUS_TEXT:
		var on := hs.has(id)
		if on and not _hero_status.has(id) and b != null:
			float_text(b.position + Vector3(0, 2.5, 0), String(HERO_STATUS_TEXT[id]), "info")
		if on:
			_hero_status[id] = true
		else:
			_hero_status.erase(id)


func _on_hero_effect(kind: StringName) -> void:
	var b := shell.local_body()
	if kind == &"pull" and b != null:
		float_text(b.position + Vector3(0, 2.5, 0), "Dragged!", "info")
		if shell.camera != null:
			shell.camera.shake(0.2)


## Enemy hooks (called for every spawned enemy): thrall blows and Miasma ticks get numbers, like the old DmEventFx.
func watch_enemy(e: DmEnemy) -> void:
	# Counsel moments the original game raises from its event fx (DmEventFx._spawn / _sanctify): once per spawn, no per-frame cost.
	var near_d := _dist_hero(e.position.x, e.position.z)
	if near_d < 40.0 and not e is DmBoss:
		game_event.emit("enemy_spawned", {"def": e.def_id, "elite": e.elite, "near": true, "area_safe": bool(DmContent.area(shell.area_id)["safe"])})
	e.cue.connect(func(kind: StringName, at: Vector3, _r: float) -> void:
		if kind == &"sanctify":
			game_event.emit("sanctify_near", {"dist": _dist_hero(at.x, at.z)}))
	e.damaged.connect(func(amount: float, _hp: float, from: Node) -> void:
		if from is DmThrall and is_instance_valid(e):
			float_text(e.position + Vector3(0, 1.4, 0), str(int(amount)), "thrall"))
	var st := DmStatusSet.of(e)
	if st != null:
		st.dot_damage.connect(func(_id: StringName, amount: float, _src: Node, _killed: bool, target: Node) -> void:
			if is_instance_valid(target) and target is Node3D:
				float_text((target as Node3D).position + Vector3(0, 1.2, 0), str(int(amount)), "dot"))


func _dist_hero(x: float, z: float) -> float:
	var b := shell.local_body() if shell != null else null
	return Vector2(b.position.x - x, b.position.z - z).length() if b != null else 99.0


## Connect every body's caster / hurt signals once (casters of party members attach 0.8 s after the body spawns).
func _bind_bodies() -> void:
	if shell == null or not shell.session.is_active():
		return
	var mine := shell.local_body()
	for r in shell.session.get_roster():
		var b := shell.body_of(int(r["peer_id"]))
		if b == null or _bound.has(b.get_instance_id()):
			continue
		var c := b.get_node_or_null("Rites") as DmRiteCaster
		if c == null:
			continue
		_bound[b.get_instance_id()] = true
		c.hit_number.connect(_on_hit_number)
		if b == mine:
			c.dev = dev_access and shell.session.is_host()
			c.cast_rejected.connect(_on_rejected)
			var hs := DmStatusSet.of(b)
			if hs != null:
				hs.changed.connect(_on_hero_statuses.bind(hs))   # replicated: a client's own hero would show them too
			if shell.session.is_host():
				b.hurt.connect(_on_hurt)
				b.enemy_effect.connect(_on_hero_effect)


# ---- HUD / counsel feeds (parity items 8 and 10): save chip, wave dial, sounds, counsel facts, Legion -----------------------------------

const SAVE_CHIP := {"saved": ["Saved ✓", false], "dirty": ["Unsaved changes", false], "saving": ["Saving…", false], "retrying": ["Save failed, retrying…", true]}
const SAVE_RANK := ["saved", "dirty", "saving", "retrying"]
var _save_vm := {"text": "Saved ✓", "warn": false}


## The HUD's save chip: the worse of the progression sync's state and the bag's (saved < dirty < saving < retrying).
func save_chip() -> Dictionary:
	var st := "saved"
	var a: String = shell.progress.psync.state if shell.progress != null else "saved"
	for s in [a, inventory.state]:
		if SAVE_RANK.find(s) > SAVE_RANK.find(st):
			st = s
	var c: Array = SAVE_CHIP[st]
	_save_vm["text"] = c[0]
	_save_vm["warn"] = c[1]
	return _save_vm


## The upgrades box's wave dial (old DmGame.dial_wave): the active Wave Speed tier, 0..owned; the director and rewards follow.
func dial_wave(delta: int) -> void:
	prog.set_active_wave_tier(float(prog.local["waveTierActive"]) + delta)
	if shell.progress != null:
		shell.progress.apply_progress()
	progress_changed.emit()


func counsel_busy() -> Dictionary:
	return counsel.busy()


func counsel_tick_ctx() -> Dictionary:
	return counsel.tick_ctx()


func _sfx(id: String, pos: Variant = null) -> void:
	sfx.emit(id)
	var a := get_node_or_null("/root/AudioDirector")
	if a != null and bool(shell.opts.get("audio", DisplayServer.get_name() != "headless")):
		a.play_sfx(id, Vector2(pos.x, pos.z) if pos is Vector3 else null, 1.0)


## DmGameCombat.on_hurt's side: the hurt sound (+ low-health under 30 %), the counsel's hurt tip / hurt_check, the fight bookkeeping.
func _hurt_feeds(b: DmHeroBody) -> void:
	counsel.hurt()
	_sfx("hurt")
	if b.alive and b.hp < b.max_hp * 0.3:
		_sfx("lowHealth")
	if b.hp < b.max_hp * 0.5:
		game_event.emit("tip", {"id": "hurt", "delay_ms": 0.0, "opts": {}})
	game_event.emit("hurt_check", {"hp": b.hp, "max_hp": b.max_hp})


## DmGameRewards.collected: the pickup sound by rarity and the counsel's "collected" facts (gear / legendary / armor / reagent / affixed).
func _item_collected(it: Dictionary, meta: Dictionary) -> void:
	var rarity := String(meta.get("rarity", "common"))
	sfx.emit(DmAudioMixer.loot_sfx([rarity]))
	var a := get_node_or_null("/root/AudioDirector")
	if a != null and bool(shell.opts.get("audio", DisplayServer.get_name() != "headless")):
		a.play_loot([rarity])
	var item_id := String(it["item_id"])
	var legendary := rarity == "legendary"
	game_event.emit("collected", {"gear": DmAffixRules.is_affix_gear(String(meta.get("type", ""))), "legendary": legendary, "armor": DmContent.armor_sets().has(item_id) and not legendary,
		"reagent": DmContent.reagents().has(item_id), "affixed": it.get("instance") != null and not (it["instance"]["affixes"] as Array).is_empty()})
	if legendary:
		game_event.emit("toast", {"text": "Legendary: %s" % String(meta.get("name", item_id)), "kind": "good"})


## Legion tier (the Legion panel's Reinforce and buy_upgrade("legion")): the backend prices it, `refresh_progress` adopts the tier, the stats (thrall cap,
## hp, damage) follow through DmNextProgress.apply_progress, and standing thralls get the one-time bump (old DmGame.buy_upgrade). "" = bought, else why not.
func buy_legion() -> String:
	var r: DmResult = await api.necro_purchase(hero_id, "legion")
	if not r.ok:
		return r.error if r.error != "" else "Not enough gold."
	await refresh_progress()
	await refresh_character()
	_sfx("buy")
	return ""


func _adopt_server_gold() -> void:
	var r: DmResult = await api.get_character()
	if r.ok and r.data is Dictionary and r.data.has("gold"):
		character["gold"] = r.data["gold"]
		character_changed.emit()


func _thrall_numbers() -> Dictionary:
	var st: Dictionary = build_cache()
	return {"hp": float(st["stats"]["thrallHp"]), "damage": float(st["stats"]["thrallDamage"]), "speedMult": float(st["discipline"]["mods"]["thrallAttackSpeedMult"])}


func _refresh_standing_thralls(before: Dictionary) -> void:
	var b := shell.local_body()
	var th := b.get_node_or_null("Thralls") as DmThrallHost if b != null else null
	var r := DmLegion.thrall_refresh(before, _thrall_numbers())
	if th != null and not r.is_empty():
		th.refresh(float(r["hpMult"]), float(r["damageMult"]), float(r["speedMult"]))
