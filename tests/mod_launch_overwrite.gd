extends SceneTree
## A mod listing can name another publisher's installed game as parent and set
## install_path to the folder a zip install uses for its launch file. These
## checks fail until that folder is rejected and launch refuses a launch file
## whose bytes changed after install.
##
## The install confirm is built in scripts/main.gd _install_prompt. This runner's
## Godot 4.3 does not parse that script (a nested variable shadows a parameter),
## so the confirm copy is not executed here.
##
## Callers that reach the same _prepare/_store sink and are not invoked here,
## because they download over HTTPS before _store: install_file,
## install_file_with_progress, the player MCP "install" tool, the library Update
## button, and the play card Install button. The install link only opens the
## confirm page.

const PARENT_UID := "11111111-1111-4111-8111-111111111111"
const MOD_UID := "22222222-2222-4222-8222-222222222222"
const PARENT_TITLE := "Trusted Game"
const MOD_TITLE := "Community Mod"

var _failed := false
var _host: Object
var _sentinel := ""


class CatalogHost:
	extends Object

	func is_authenticated() -> bool:
		return true


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var installs: Node = root.get_node_or_null("Installs")
	var session: Node = root.get_node_or_null("Session")
	if installs == null or session == null:
		push_error("autoload missing")
		quit(1)
		return
	_sentinel = OS.get_user_data_dir().path_join("mod-launch-sentinel.txt")
	DirAccess.remove_absolute(_sentinel)
	if not _arm_host(session):
		quit(1)
		return
	var launch_name := _launch_name(installs)
	var launch_path := ""
	var original := PackedByteArray()
	if not _install_parent(installs, launch_name):
		quit(1)
		return
	launch_path = FileAccess.get_file_as_string(installs._marker(PARENT_UID)).strip_edges()
	original = FileAccess.get_file_as_bytes(launch_path)
	_overlay(installs, session, "game", launch_name, launch_path, original)
	# Same folder with a trailing slash. A check that compares the raw string
	# "game" and then joins the path again still merges here.
	_restore_launch_file(launch_path, original)
	_overlay(installs, session, "game/", launch_name, launch_path, original)
	_launch_rejects_replaced_file(installs, launch_path, original)
	_cleanup(installs)
	if _failed:
		quit(1)
		return
	print("mod launch overwrite ok")
	quit(0)


func _arm_host(session: Node) -> bool:
	if not Engine.has_singleton("Blazium"):
		_host = CatalogHost.new()
		Engine.register_singleton("Blazium", _host)
	if not session.is_authenticated():
		push_error("catalog host did not authenticate")
		return false
	return true


func _script_catalog(session: Node, install_path: String, file_uid: String, checksum: String, launch_name: String, host_os: String) -> void:
	session._scripted = {
		"get_library": {
			"success": true,
			"data": {"library": [
				{"game_uid": PARENT_UID, "name": PARENT_TITLE},
				{"game_uid": MOD_UID, "name": MOD_TITLE},
			]},
		},
		"get_game_overview": {"success": true, "data": {"name": MOD_TITLE, "username": "other-publisher"}},
		"list_game_files": {
			"success": true,
			"data": {
				"name": MOD_TITLE,
				"parent": {"uid": PARENT_UID},
				"mod_settings": {"loader": "bepinex", "install_path": install_path},
				"files": [{
					"file_uid": file_uid,
					"channel": "stable",
					"os": host_os,
					"downloadable": true,
					"latest": true,
					"build_id": "mod-build",
				}],
			},
		},
		"get_download": {
			"success": true,
			"data": {
				"url": "https://cdn.example/mod.zip",
				"filename": "mod.zip",
				"checksum": "sha256:" + checksum,
				"game_uid": MOD_UID,
				"entry": launch_name,
			},
		},
	}
	session.invalidate_library()


func _install_parent(installs: Node, launch_name: String) -> bool:
	var dir: String = installs.game_dir(PARENT_UID)
	DirAccess.make_dir_recursive_absolute(dir)
	var zip_path := dir.path_join("build.zip")
	var body := "#!/bin/sh\nexit 0\n# parent-launch\n".to_utf8_buffer()
	if not _write_zip(zip_path, launch_name, body):
		push_error("could not write the parent zip")
		return false
	var zipped := FileAccess.get_file_as_bytes(zip_path)
	DirAccess.remove_absolute(zip_path)
	var stored: Dictionary = installs._store({
		"game_uid": PARENT_UID,
		"dest": dir.path_join("build.zip"),
		"overlay": false,
		"checksum": "sha256:" + _sha(zipped),
		"file_uid": "parent-file",
		"build_id": "parent-build",
		"channel": "stable",
		"entry": launch_name,
		"title": PARENT_TITLE,
	}, {"code": 200, "body": zipped})
	if not bool(stored.get("ok", false)):
		push_error("parent zip did not install: %s" % str(stored.get("error", "")))
		return false
	var marker := FileAccess.get_file_as_string(installs._marker(PARENT_UID)).strip_edges()
	if marker.get_file() != launch_name or marker.get_base_dir().get_file() != "game":
		push_error("parent launch file is not in the game folder: %s" % marker)
		return false
	return true


func _overlay(installs: Node, session: Node, install_path: String, launch_name: String, launch_path: String, original: PackedByteArray) -> void:
	var file_uid := "mod-file-" + install_path.replace("/", "")
	var dir: String = installs.game_dir(MOD_UID)
	DirAccess.make_dir_recursive_absolute(dir)
	var zip_path := dir.path_join("mod.zip")
	var payload := ("#!/bin/sh\nprintf ran > '%s'\n" % _sentinel).to_utf8_buffer()
	if not _write_zip(zip_path, launch_name, payload):
		check(false, "could not write the mod zip")
		return
	var zipped := FileAccess.get_file_as_bytes(zip_path)
	DirAccess.remove_absolute(zip_path)
	var checksum := _sha(zipped)
	_script_catalog(session, install_path, file_uid, checksum, launch_name, installs.os_name())
	if not session.owns(MOD_UID) or not session.owns(PARENT_UID):
		check(false, "player ownership did not reach the catalog")
		return
	var picked := str(installs.pick_file(MOD_UID, "stable"))
	if picked != file_uid:
		check(false, "the mod file was not the one selected for this machine")
		return
	var prepared: Dictionary = installs._prepare(MOD_UID, file_uid)
	if not bool(prepared.get("ok", false)):
		var err := str(prepared.get("error", ""))
		if _harness_error(err):
			check(false, "install did not reach the path check: %s" % err)
		_assert_launch_file(launch_path, original, install_path)
		return
	if not bool(prepared.get("overlay", false)):
		_assert_launch_file(launch_path, original, install_path)
		return
	var stored: Dictionary = installs._store(prepared, {"code": 200, "body": zipped})
	if bool(stored.get("ok", false)):
		check(false, "mod install_path %s was installed onto the parent" % install_path)
	_assert_launch_file(launch_path, original, install_path)
	if FileAccess.file_exists(_sentinel):
		check(false, "mod install_path %s ran while it was being installed" % install_path)


func _launch_rejects_replaced_file(installs: Node, launch_path: String, original: PackedByteArray) -> void:
	var payload := ("#!/bin/sh\nprintf ran > '%s'\n" % _sentinel).to_utf8_buffer()
	var out := FileAccess.open(launch_path, FileAccess.WRITE)
	if out == null:
		check(false, "could not replace the launch file for the launch check")
		return
	out.store_buffer(payload)
	out.close()
	# Windows CreateProcess runs this path with no Unix mode bit. Set the bit
	# so this machine's execvp actually starts the image launch hands it.
	FileAccess.set_unix_permissions(launch_path, 493)
	DirAccess.remove_absolute(_sentinel)
	var launched: Dictionary = installs.launch(PARENT_UID)
	OS.delay_msec(300)
	var ran := FileAccess.file_exists(_sentinel)
	if ran:
		check(false, "launch ran the file that replaced the installed launch file")
	if bool(launched.get("ok", false)):
		check(false, "launch started a file whose bytes no longer match the install")
	var pid := int(launched.get("pid", 0))
	if pid > 0 and pid != OS.get_process_id() and OS.is_process_running(pid):
		OS.kill(pid)
	_restore_launch_file(launch_path, original)


func _assert_launch_file(launch_path: String, original: PackedByteArray, install_path: String) -> void:
	if not FileAccess.file_exists(launch_path):
		check(false, "install_path %s removed the parent launch file" % install_path)
		return
	var now := FileAccess.get_file_as_bytes(launch_path)
	if now != original:
		check(false, "install_path %s replaced the parent launch file (mode %s)" % [install_path, FileAccess.get_unix_permissions(launch_path)])


func _restore_launch_file(launch_path: String, original: PackedByteArray) -> void:
	var out := FileAccess.open(launch_path, FileAccess.WRITE)
	if out == null:
		return
	out.store_buffer(original)
	out.close()
	FileAccess.set_unix_permissions(launch_path, 493)


func _harness_error(err: String) -> bool:
	return err == "Sign in first" or err == "You do not own this game" or err.find("not part of this game") >= 0 or err.find("Download URL") >= 0 or err.find("filename") >= 0 or err.find("checksum") >= 0 or err.find("No download") >= 0


func _launch_name(installs: Node) -> String:
	if installs.os_name() == "windows":
		return "game.exe"
	return "game.x86_64"


func _write_zip(path: String, name: String, body: PackedByteArray) -> bool:
	var packer := ZIPPacker.new()
	if packer.open(path) != OK:
		return false
	packer.start_file(name)
	packer.write_file(body)
	packer.close_file()
	packer.close()
	return true


func _sha(body: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(body)
	return ctx.finish().hex_encode()


func _cleanup(installs: Node) -> void:
	installs.uninstall(MOD_UID)
	installs.uninstall(PARENT_UID)
	DirAccess.remove_absolute(_sentinel)


func check(cond: bool, message: String) -> void:
	if not cond:
		_failed = true
		push_error(message)
