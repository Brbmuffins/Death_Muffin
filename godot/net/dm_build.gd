class_name DmBuild
extends RefCounted
## The installed build's version and how versions compare. Used by co-op (DmSession refuses a different build), the update notice
## (DmUpdateCheck) and benchmark reports.

const DEV := "dev"
const _RE := "^\\d{8}\\.\\d{6}-[0-9a-f]{7}$"

## The installed build's version ("20261013.225809-36e80e1"): the launcher installs each build in a folder of its own with the manifest
## it came from (launcher/windows/ClientInstaller.cs), so it is read from the manifest.json next to the exe; "dev" for an editor or hand-run build.
static func version() -> String:
	var mf := OS.get_executable_path().get_base_dir().path_join("manifest.json")
	if FileAccess.file_exists(mf):
		var j: Variant = JSON.parse_string(FileAccess.get_file_as_string(mf))
		if j is Dictionary and j.get("version") is String and String(j["version"]) != "":
			return String(j["version"])
	var ver := str(ProjectSettings.get_setting("application/config/version", ""))
	return ver if ver != "" else DEV


## A real published build version (publish-godot-client.sh: UTC stamp + short sha), not "dev" or anything hand-made.
static func is_release(v: String) -> bool:
	var re := RegEx.new()
	re.compile(_RE)
	return re.search(v) != null


## True when `a` was published after `b` (both release versions; the stamp sorts as text). A rollback (an older manifest) is never newer.
static func newer(a: String, b: String) -> bool:
	return is_release(a) and is_release(b) and a.get_slice("-", 0) > b.get_slice("-", 0)


## Two builds can play together: the same release, or either side is a dev build (editor, tests).
static func compatible(a: String, b: String) -> bool:
	return a == b or not is_release(a) or not is_release(b)
