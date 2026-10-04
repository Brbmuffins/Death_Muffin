class_name DmDialogueLines
extends RefCounted
## Port of src/content/dialogue.ts: what the people of the Covenant say. Every answer is a small function of the real GuidanceState (DmGuidance).
## Labels, topic ids/labels and boss hints are exported JSON (godot/data/content/dialogue.json); the line functions live here.


static func _n(v: Variant) -> String:
	return DmJsFmt.locale(float(v))


static func _s(v: Variant) -> String:
	return DmJsFmt.num_str(float(v)) if (v is float or v is int) else String(v)


static func _has(news: Array, prefix: String) -> Variant:
	for x: Dictionary in news:
		if String(x["key"]).begins_with(prefix):
			return x
	return null


static func _pick(open: Array, k: Variant) -> String:
	return open[posmod(int(float(k)), open.size())]


static func _level_desc(a: String) -> String:
	var ar := DmGuidance.area(a)
	return "level %s%s" % [_s(ar["level"]), "+" if ar.get("scaling") != null else ""]


static func boss_hint(id: String) -> String:
	return String((DmContent.get_export("dialogue", "BOSS_HINT") as Dictionary).get(id, ""))


static func _boss_hint_for(name: Variant) -> String:
	for id in DmGuidance.boss_ids():
		if DmGuidance.boss(id)["name"] == name:
			return boss_hint(id)
	return ""


static func topics(npc: String) -> Array:
	return DmContent.get_export("dialogue", "TOPICS")[npc]


# --- The opening words -------------------------------------------------------------------------------------------------------------

## greetingLines(npc, s, news, met): `news` is what DmGuidanceMemory.unheard returned before this talk was recorded.
static func greeting_lines(npc: String, s: Dictionary, news: Array, met: bool) -> Array:
	match npc:
		"prior":
			return _prior_greeting(s, news, met)
		"sexton":
			return _sexton_greeting(s, news, met)
	return _apothecary_greeting(s, news, met)


static func _prior_greeting(s: Dictionary, news: Array, met: bool) -> Array:
	if not met:
		return ["Welcome to the Chapterhouse, child of the Covenant. I am the Prior; the seals and the dead of this diocese are my charge.",
			"No one commands you here. Ask me where to go and I will say it plainly; you may ignore every word."]
	if _has(news, "ascend:ready") != null:
		return ["The Bell-Sworn Prelate lies silent, and the Altar of Ascension stands ready.",
			"It will take this run's tally and give back %s Ashes, if you choose. The vows you swore set the sum. No one is hurrying you." % _n(s["ashesOnAscend"])]
	for x: Dictionary in news:
		var k := String(x["key"])
		if k.begins_with("boss:") and not k.begins_with("boss:prelate"):
			var id := k.split(":")[1]
			return ["%s is buried. Even the cloisters have heard." % DmGuidance.boss(id)["name"], "Take your rest in the Chapterhouse, or walk on while the dead are still frightened."]
	var seal: Variant = _has(news, "seal:")
	if seal != null:
		var a := String(seal["key"]).split(":")[1]
		return ["A seal has broken: %s lies open to you, and its dead are %s." % [DmGuidance.lower_the(String(DmGuidance.area(a)["name"])), _level_desc(a)], "Go when you feel ready. The road will wait."]
	if _has(news, "rank:") != null and float(s["ascension"]) > 0.0:
		return ["Your hardest run was rank %s. The seals stay open behind you; the vows are what you chose to carry." % _s(s["ascension"]), "Ask, and I will tell you what lies open."]
	if float(s["totalKills"]) < 10.0 and float(s["ascension"]) == 0.0:
		return ["The Hollow Graves lie north, through the door at the top of this hall. Begin there."]
	return [_pick(["Walk carefully. The dead remember.", "The Covenant keeps what it can. What it cannot keep, you bury.", "You look well. The diocese is not, but that is hardly your fault."], s["level"])]


static func _sexton_greeting(s: Dictionary, news: Array, met: bool) -> Array:
	if not met:
		return ["Mind the graves, they are tended. I am the Sexton; this Acre is mine and, I suppose, yours now.", "Nothing here bites. Trees, seams, pools and graves: pick whichever takes your fancy."]
	if _has(news, "labor:ready") != null:
		return ["Your laborers have been busy. There is work waiting on them: press H and collect it."]
	if _has(news, "bag:full") != null:
		return ["That bag of yours is groaning (%s of %s). The Grinder turns spare gear into ingots, and the Vault keeps the rest." % [_s(s["bagUsed"]), _s(s["bagSize"])]]
	if _has(news, "contracts:open") != null and s.get("contracts") != null:
		var o: float = float(s["contracts"]["open"])
		return ["The board has %s %s still unfilled today. Press O to see them." % [_s(o), "order" if o == 1.0 else "orders"]]
	return [_pick(["Wood, ore, fish, bones. The Acre gives what you are patient enough to take.", "Quiet today. The dead here do not complain, which is why I like them.", "Take your time. The nodes come back, they always come back."], s["level"])]


static func _apothecary_greeting(s: Dictionary, news: Array, met: bool) -> Array:
	if not met:
		return ["Hush, mind the vials. This is my Wing now: the Great Cauldron, the Alembic, and the Shelf where every reagent you find gets its place.",
			"Four Grave Dust and a little patience make a first tonic. Ask, and I will tell you what to brew."]
	if _has(news, "dust:first") != null:
		return ["You are carrying %s Grave Dust, enough for a tonic. Bring it to the Great Cauldron, here in the Wing." % _s(s["dust"])]
	if _has(news, "reagent:fen") != null:
		return ["The Fen grows bog myrtle and drowned lotus. The Mire Mother’s ichor and a lotus make a Moonlight Elixir, if you are brave."]
	if _has(news, "reagent:pyre") != null:
		return ["Cinder Ash from the Pyre, and ash-bloom if you grow it. Both go into stronger elixirs."]
	if _has(news, "reagent:cloister") != null:
		return ["Plague Bile from the Cloister, and rot-cap if you forage it. Do not taste either."]
	return [_pick(["Careful with that. No, the other one.", "A good brew is mostly patience, and a little contempt for the dead.", "Everything in this room is either medicine or poison. Occasionally both."], s["level"])]


# --- Advice (the first button) --------------------------------------------------------------------------------------------------------

## adviceLines(npc, s): the answer to "where next?", from the best suggestion on that person's subject.
static func advice_lines(npc: String, s: Dictionary) -> Array:
	var sg: Variant = DmGuidance.suggestion_for(npc, s)
	match npc:
		"prior":
			return _prior_advice(sg, s)
		"sexton":
			return _sexton_advice(sg)
	return _apothecary_advice(sg, s)


static func _prior_advice(sg: Variant, s: Dictionary) -> Array:
	if sg == null:
		return ["Nothing presses. Hunt where you like, and come back when you want counsel."]
	var d: Dictionary = sg["data"]
	match sg["kind"]:
		"first-steps":
			return ["North, through the door at the top of this hall, lie the Hollow Graves. Strike the robbers and hounds there.", "Gather what falls. Your bag is the Reliquary on the west wall (I)."]
		"seal":
			var lvl := float(d["level"])
			var note := "You are level %s; a few more levels will make that road kinder." % _s(s["level"]) if float(s["level"]) + 2.0 < lvl else "You are level %s. You are strong enough for it." % _s(s["level"])
			return ["The road onward is sealed. Slay %s more of the dead in %s, and %s will open. %s." % [_n(float(d["need"]) - float(d["kills"])), d["from"], d["to"], d["seal"]], note]
		"boss-ready":
			return ["%s stirs at %s, in %s. You hold the %s soul shards it asks." % [d["boss"], d["at"], d["area"], _s(d["shards"])], _boss_hint_for(d["boss"])]
		"boss-short":
			return ["%s will answer %s in %s once you bring %s soul shards. You hold %s; elites carry them." % [d["boss"], d["at"], d["area"], _s(d["shards"]), _s(d["have"])], _boss_hint_for(d["boss"])]
		"ascend":
			return ["The Altar of Ascension is ready. It trades this run's tiers for %s Ashes, and keeps your seals, shards, level, gold and gear." % _n(d["ashes"]), "It is a choice, never a duty."]
		"hunt":
			if float(d["clear"]) != 0.0:
				return ["Every seal I know of is broken and every king buried. Hunt in %s, where the dead are level %s+ and the spoils richest." % [d["area"], _s(d["level"])], "Or ascend, or hunt for a set of armor. The diocese is yours."]
			return ["Hunt in %s: its dead are level %s+. When you wish for a harder master, ask me again." % [d["area"], _s(d["level"])]]
	return [sg["text"]]


static func _sexton_advice(sg: Variant) -> Array:
	if sg == null:
		return ["Nothing presses. Work a node, fill an order, or let your laborers carry on, whichever suits you."]
	var d: Dictionary = sg["data"]
	match sg["kind"]:
		"bag-full":
			return ["Your bag is %s of %s. Spare gear can go to the Bone Grinder by the kiln (it trains Salvaging), and anything you wish to keep can go in the Vault (V)." % [_s(d["used"]), _s(d["size"])], "Padlock the pieces you want to keep first, and the bulk buttons will leave them be."]
		"labor-ready":
			return ["%s of your laborers %s a good haul waiting. Press H to collect it and set them back to work." % [_s(d["ready"]), "has" if float(d["ready"]) == 1.0 else "have"]]
		"contracts":
			return ["The board has %s of %s orders unfilled today (O). Deliver from your bag for gold and sometimes an item; all three pay a bonus." % [_s(d["open"]), _s(d["total"])]]
		"labor-idle":
			return ["A laborer stands idle. Press H and give them a post: they gather slowly, for up to eight hours, while you hunt or sleep."]
		"gather-intro":
			return ["Click a Coffin-Oak, a Seam, a Still Pool or a Pauper’s Grave to start a skill at level 1. Press P to watch your skills grow.", "You can also set one to work while you do other things: P, choose a tier, Start AFK."]
	return [sg["text"]]


static func _reagent_tip(s: Dictionary) -> String:
	if DmGuidance.is_open(s, "fen"):
		return "The Fen gives bog myrtle and drowned lotus; the Mire Mother’s ichor and a lotus make a Moonlight Elixir."
	if DmGuidance.is_open(s, "pyre"):
		return "The Pyre gives Cinder Ash, and ash-bloom if you grow it from seed in the Acre."
	if DmGuidance.is_open(s, "cloister"):
		return "The Cloister gives Plague Bile, and rot-cap you can forage and plant in the Acre."
	return "Spirits drop Wraith Ectoplasm. Each deeper hall adds a reagent of its own; I will tell you as you open them."


static func _apothecary_advice(sg: Variant, s: Dictionary) -> Array:
	if sg == null:
		return ["Brew what you can. %s" % _reagent_tip(s)]
	var d: Dictionary = sg["data"]
	match sg["kind"]:
		"brew-dust":
			return ["You carry %s Grave Dust. At the Great Cauldron here, four of them brew a Grave-Dust Tonic: more essence regeneration for a minute." % _s(d["dust"]), "The first brew anyone can make from what the dead drop."]
		"brew-first":
			return ["Grave Dust drops now and then from the dead of the Hollow Graves and the Catacomb Warren. Four make your first tonic.", "You hold %s. Keep killing; it will come." % _s(d["dust"])]
	return [sg["text"]]


# --- Topics (Tell me about...) -----------------------------------------------------------------------------------------------------

static func topic_lines(npc: String, id: String, s: Dictionary) -> Array:
	match npc:
		"prior":
			match id:
				"seals":
					return _t_seals(s)
				"bosses":
					return _t_bosses(s)
				"ascension":
					return _t_ascension(s)
		"sexton":
			match id:
				"gather":
					return _t_gather(s)
				"grinder":
					return _t_grinder(s)
				"contracts":
					return _t_contracts(s)
		_:
			match id:
				"brewing":
					return _t_brewing(s)
				"reagents":
					return _t_reagents(s)
				"belt":
					return ["You have two brew slots: an Elixir for combat (Z) and a Tonic for everything else (X). A new elixir replaces the old one.",
						"Right-click a brew in the Reliquary (I) to put it on your belt. Drinking the same brew again extends it, up to twice its length."]
	return []


static func _side_halls(s: Dictionary) -> Array:
	var out: Array = []
	for a in ["warren", "coliseum"]:
		if DmGuidance.is_open(s, a):
			continue
		var u: Dictionary = DmGuidance.area(a)["unlock"]
		var need: float = maxf(1.0, float(DmMath.js_round(float(u["kills"]) * float(s["unlockMult"]))))
		out.append("%s (%s dead in %s)" % [DmGuidance.area(a)["name"], _n(need), DmGuidance.lower_the(String(DmGuidance.area(String(u["area"]))["name"]))])
	return out


static func _t_seals(s: Dictionary) -> Array:
	var seals: Array = []
	for x: Dictionary in DmGuidance.pending_seals(s):
		if not x["side"]:
			seals.append(x)
	var first := "Slay enough of the dead in a hall and the seal to the next breaks by itself. There is nothing to carry or to buy."
	var now := "Every seal on the main road is broken."
	if seals.size() > 0:
		var z: Dictionary = seals[0]
		now = "Now: %s, in %s." % [DmGuidance.format_seal_progress(z["area"], z["kills"], z["need"]), DmGuidance.lower_the(String(DmGuidance.area(z["from"])["name"]))]
	var side := _side_halls(s)
	var out: Array = [first, now]
	if side.size() > 0:
		out.append("Two side halls open sooner: %s." % " and ".join(side))
	return out


static func _t_bosses(s: Dictionary) -> Array:
	var waiting := DmGuidance.bosses_waiting(s)
	var base := "Each hunting ground has an altar that wakes its king for soul shards. Elites carry the shards; only one king can wake at a time."
	if waiting.is_empty():
		return [base, "Every king in the halls you have opened is buried. Their first defeat paid two extra shards and a rare relic."]
	var id: String = waiting[0]
	var b := DmGuidance.boss(id)
	return [base, "Next: %s at %s, %s shards (you hold %s). %s" % [b["name"], DmGuidance.lower_the(String(b["summonLabel"])), _s(b["shards"]), _s(s["shards"]), boss_hint(id)]]


static func _t_ascension(s: Dictionary) -> Array:
	if bool(s["canAscend"]):
		return ["It is ready. Ascending resets your Damage and Wave Speed tiers; it keeps your seals, shards, level, gold, gear and skills, and pays %s Ashes." % _n(s["ashesOnAscend"]),
			"Swear Vows at the Altar before a run: the hotter they are, the more Ashes. Ashes buy Covenant Boons; shards unlock new vows and boons."]
	if not DmGuidance.boss_beaten(s, "prelate"):
		return ["Defeat the Bell-Sworn Prelate at the Sundered Bell, in the Bell Sanctum (5 soul shards), and the Altar will open to you.",
			("You hold rank %s already." % _s(s["ascension"])) if float(s["ascension"]) > 0.0 else "It is far ahead of you yet, and entirely optional."]
	return ["Your hardest run was rank %s. Another Prelate kill this run will make the Altar ready again." % _s(s["ascension"]),
		"Swear Vows to raise the heat of a run and the Ashes it pays; Ashes buy Covenant Boons."]


static func _t_gather(s: Dictionary) -> Array:
	var skills: Dictionary = s["skills"]
	var all_one := true
	for k in ["woodcutting", "mining", "fishing", "gravedigging"]:
		if float(DmCombatData.nn(skills.get(k), 1.0)) > 1.0:
			all_one = false
	var first := "Click a Coffin-Oak, a Seam, a Still Pool or a Pauper’s Grave to begin. Press P for your skills, or Start AFK to keep working while you do other things." if all_one \
		else "Higher tiers need higher skill. Press P to see what you unlock next, and Start AFK to keep a node worked while you do other things."
	var lab := "Grave Laborers (H) gather slowly while you are away, for up to eight hours. You gain another for every 50 total gathering levels."
	var l: Variant = s.get("labor")
	if l != null:
		if float(l["ready"]) > 0.0:
			lab = "Your laborers have work waiting: press H."
		elif float(l["unlocked"]) > float(l["assigned"]):
			lab = "A laborer stands idle: press H and give them a post."
		else:
			lab = "Your laborers are at their posts. They gather slowly for up to eight hours (H)."
	return [first, lab]


static func _t_grinder(s: Dictionary) -> Array:
	var size := float(s["bagSize"])
	var used := float(s["bagUsed"])
	var bag := ""
	if size > 0.0 and used / size >= DmGuidance.BAG_FULL_FRACTION:
		bag = "Your bag is %s of %s: it is time." % [_s(used), _s(size)]
	elif size > 0.0 and used / size >= 0.6:
		bag = "Your bag is %s of %s; there is no hurry yet." % [_s(used), _s(size)]
	var out: Array = ["The Bone Grinder, beside the kiln, turns spare gear into ingots and planks, and trains Salvaging. Worn and padlocked pieces are never touched.",
		"The Ossuary Vault (V), here or in the Chapterhouse, keeps 120 slots shared by every character on your account."]
	if bag != "":
		out.append(bag)
	return out


static func _t_contracts(s: Dictionary) -> Array:
	var c: Variant = s.get("contracts")
	var second := "Fill all three for a bonus, and a streak that grows each day."
	if c != null:
		if float(c["open"]) == 0.0:
			second = "Today’s board is done. A fresh one comes tomorrow; finishing all three pays a bonus and builds a streak."
		else:
			second = "%s of today’s %s are still open." % [_s(c["open"]), _s(c["total"])]
	return ["Three orders a day (O), easy to hard, drawn from what your skills can make. Deliver from your bag for gold, and sometimes an item. Now and then I want gems, fragments or seals; I pay double for those.", second]


static func _t_brewing(s: Dictionary) -> Array:
	var dust := float(s["dust"])
	return ["The Great Cauldron or the Alembic here in the Wing. Each recipe wants reagents and a level in Alchemy, which brewing itself trains.",
		("You have the dust for a first tonic (%s)." % _s(dust)) if dust >= DmGuidance.GRAVE_DUST_FOR_TONIC else "Four Grave Dust make your first tonic. You hold %s." % _s(dust)]


static func _t_reagents(s: Dictionary) -> Array:
	return ["Grave Dust: the Hollow Graves and the Catacomb Warren. Wraith Ectoplasm: spirits. Plague Bile: the Cloister. Cinder Ash: the Pyre.",
		"Every area boss leaves an ichor. Herbs such as rot-cap and ash-bloom grow in the Acre from foraged seeds (U).", _reagent_tip(s)]


const FAREWELLS := {
	"prior": ["Go with the Covenant’s quiet.", "The door is always open.", "Walk well."],
	"sexton": ["Mind the graves.", "Come back with dirt on your boots.", "Right. Back to it."],
	"apothecary": ["Do not drink anything you did not brew.", "Come back alive, I have questions.", "Mind the vials on the way out."],
}


static func farewell(npc: String, s: Dictionary) -> String:
	return _pick(FAREWELLS[npc], s["totalKills"])
