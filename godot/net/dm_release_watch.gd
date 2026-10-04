class_name DmReleaseWatch
extends RefCounted
## Auto-refresh support (port of src/net/releaseWatch.ts): remember the release seen at start and report when it changes.
## Any failure to read the marker means "unknown", never "changed".

var api: DmApi
var baseline: String = ""

func _init(api_ref: DmApi = null) -> void:
	api = api_ref

## "<sha> <iso-time>" -> lower-case sha, or "" when the first token is not 7-64 hex characters.
static func parse_release(text: String) -> String:
	var m := RegEx.create_from_string("^\\S*").search(text.strip_edges())
	var sha := m.get_string() if m != null else ""
	var re := RegEx.create_from_string("^[0-9a-fA-F]{7,64}$")
	return sha.to_lower() if re.search(sha) != null else ""

func init_baseline() -> void:
	if baseline.is_empty():
		baseline = await api.get_release()

func changed() -> bool:
	if baseline.is_empty():
		await init_baseline()
		return false
	var now := await api.get_release()
	return not now.is_empty() and now != baseline
