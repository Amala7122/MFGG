extends RefCounted
## Static, versioned art resources. A source/config change safely falls back to
## generation until tests/bake_valley_art.gd rebuilds the resources.
const Terrain := preload("res://scripts/terrain_field.gd")
const DIRECTORY := "res://assets/generated/valley"
const MOUNTAIN_PATH := DIRECTORY + "/sanctum_mountains.res"
const ART_PATH := DIRECTORY + "/sanctum_art.scn"
const MANIFEST_PATH := DIRECTORY + "/manifest.json"
const FORMAT_VERSION := 1
const SOURCES := ["res://scripts/valley_art.gd", "res://scripts/valley_terrain.gd",
	"res://scripts/terrain_field.gd", "res://scripts/lowpoly_mesh.gd"]
static var force_generation := false
static var _fingerprint := ""
static var _checked := false
static var _current := false

static func terrain_signature() -> String:
	return JSON.stringify(Terrain._arena_params).sha256_text()

static func signature() -> String:
	var terrain_key := terrain_signature()
	var data := str(FORMAT_VERSION) + terrain_key
	for path in SOURCES:
		if FileAccess.file_exists(path):
			data += FileAccess.get_file_as_string(path)
	var next_fingerprint := data.sha256_text()
	if next_fingerprint != _fingerprint:
		_fingerprint = next_fingerprint
		_checked = false
	return _fingerprint

static func current() -> bool:
	if force_generation or OS.get_cmdline_user_args().has("--valley-source") \
		or OS.get_cmdline_user_args().has("--bake-valley"):
		return false
	var fingerprint := signature()
	if _checked:
		return _current
	_checked = true
	_current = false
	if not FileAccess.file_exists(MANIFEST_PATH) or not ResourceLoader.exists(MOUNTAIN_PATH) \
		or not ResourceLoader.exists(ART_PATH):
		return false
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST_PATH))
	if not raw is Dictionary:
		return false
	var manifest := raw as Dictionary
	_current = int(manifest.get("format_version", 0)) == FORMAT_VERSION \
		and String(manifest.get("terrain_signature", "")) == terrain_signature()
	# Development builds must also match source. Exported builds use the baked
	# version/config contract; their script source may have been compiled away.
	if OS.has_feature("editor"):
		_current = _current and String(manifest.get("signature", "")) == fingerprint
	return _current
