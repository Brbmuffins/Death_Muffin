class_name DmCounselData
extends RefCounted
## Covenant counsel data: every tip's title/body/kind/group/priority/place/anchor plus the cadence constants, all exported from the real
## TypeScript (src/ui/Onboarding.ts TIPS + TIP_ANCHOR, src/ui/counselCadence.ts) by tools/godot/fixtures-onboarding.ts into
## res://data/onboarding/tips.json. Never hand-edited. Also `render_text` (Onboarding.ts renderText).

const PATH := "res://data/onboarding/tips.json"

static var _d: Dictionary = {}


static func data() -> Dictionary:
	if _d.is_empty():
		var f := FileAccess.open(PATH, FileAccess.READ)
		if f == null:
			push_error("counsel data missing: run tools/godot/gen-fixtures.sh (%s)" % PATH)
			return {}
		_d = JSON.parse_string(f.get_as_text())
	return _d


static func tips() -> Dictionary:
	return data().get("tips", {})


static func order() -> Array:
	return data().get("order", [])


static func has_tip(id: String) -> bool:
	return tips().has(id)


## 0 = unknown id (the web would throw on a tip not in TIPS; callers only pass TipIds).
static func title(id: String) -> String:
	return String(tips().get(id, {}).get("title", ""))


static func body(id: String) -> String:
	return String(tips().get(id, {}).get("body", ""))


static func constants() -> Dictionary:
	return data().get("constants", {})


static func c(name: String) -> Variant:
	return constants().get(name)


## counselCadence.kindOf: 'urgent' | 'danger' | 'asked' | 'calm' (anything unlisted is calm).
static func kind_of(id: String) -> String:
	var t: Variant = tips().get(id)
	return String(t.get("kind", "calm")) if t != null else "calm"


## counselCadence.groupOf: subject group or "" (the web's null).
static func group_of(id: String) -> String:
	var t: Variant = tips().get(id)
	if t == null or t.get("group") == null:
		return ""
	return String(t["group"])


static func priority_of(id: String) -> int:
	var t: Variant = tips().get(id)
	return int(t.get("priority", 50)) if t != null else 50


## counselCadence.HERE: areas a place-bound tip belongs to, or an empty array.
static func here_of(id: String) -> Array:
	var h: Variant = constants().get("HERE", {}).get(id)
	return h if h != null else []


## Onboarding.ts TIP_ANCHOR selector for a tip ("" = none).
static func anchor_selector(id: String) -> String:
	var a: Variant = data().get("anchors", {}).get(id)
	return String(a) if a != null else ""


## The DmHud.tip_anchor_rect() key for each TIP_ANCHOR selector. The HUD keys its parts by the tip that first pointed at them.
const ANCHOR_HUD_KEY := {
	"[data-mapframe]": "minimap",
	"[data-brews]": "belt",
	".hud-upgrades": "wave",
	"[data-chain]": "chain",
	".hud-omen": "omen",
	"[data-reveal=\"hud.shards\"]": "prelate",
	"[data-grimbtn], [data-open=\"grimoire\"]": "grimoire",
	"[data-open=\"atlas\"]": "atlas",
	"[data-open=\"codex\"]": "codex",
	"[data-open=\"inventory\"]": "relic",
	"[data-open=\"professions\"]": "gather",
}


## DmHud.tip_anchor_rect() key for a tip ("" = the tip lights nothing).
static func hud_anchor_key(id: String) -> String:
	var sel := anchor_selector(id)
	return String(ANCHOR_HUD_KEY.get(sel, "")) if sel != "" else ""


## Onboarding.renderText: `{auto}..{/auto}` is kept only when auto combat is allowed (the web: owner-only), `[[desktop||touch]]` resolves to its
## desktop half, `{p:X}` -> " (<kbd>X</kbd>)", `{key:<ability>}` -> the key from `key_for` (Callable(ability) -> String, "" = not on the bar).
## Returns the same trusted HTML as the web; DmUi.markup() turns it into BBCode.
static func render_text(text: String, key_for: Callable = Callable(), auto_allowed: bool = false) -> String:
	var s := text
	var re_auto := RegEx.create_from_string("\\{auto\\}([\\s\\S]*?)\\{/auto\\}")
	s = _sub(re_auto, s, func(m: RegExMatch) -> String: return m.get_string(1) if auto_allowed else "")
	var re_pair := RegEx.create_from_string("\\[\\[([\\s\\S]*?)\\|\\|([\\s\\S]*?)\\]\\]")
	s = _sub(re_pair, s, func(m: RegExMatch) -> String: return m.get_string(1))
	var re_p := RegEx.create_from_string("\\{p:(\\w)\\}")
	s = _sub(re_p, s, func(m: RegExMatch) -> String: return " (<kbd>%s</kbd>)" % m.get_string(1))
	var re_key := RegEx.create_from_string("\\{key:(\\w+)\\}")
	s = _sub(re_key, s, func(m: RegExMatch) -> String:
		var k := ""
		if key_for.is_valid():
			k = String(key_for.call(m.get_string(1)))
		return "<kbd>%s</kbd>" % k if k != "" else "a key from your Grimoire (<kbd>L</kbd>)")
	return s


static func _sub(re: RegEx, s: String, fn: Callable) -> String:
	var out := ""
	var at := 0
	for m in re.search_all(s):
		out += s.substr(at, m.get_start() - at) + String(fn.call(m))
		at = m.get_end()
	return out + s.substr(at)


## Word count the web uses for the show time: strip tags, split on whitespace.
static func word_count(html: String) -> int:
	var re := RegEx.create_from_string("<[^>]+>")
	var plain := re.sub(html, " ", true)
	var n := 0
	for w in plain.split(" ", false):
		for part in String(w).split("\n", false):
			for p2 in String(part).split("\t", false):
				if p2.strip_edges() != "":
					n += 1
	return n
