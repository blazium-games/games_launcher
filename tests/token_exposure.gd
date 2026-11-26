extends SceneTree
## Owner-only loopback tokens. Group or world access must not be able to focus
## the launcher or open a library or game link. A path stat that disagrees with
## the descriptor being read must not count.

const PLANTED := "placeholder-token-not-a-secret-value"
const OWNER_TOKEN := "placeholder-owner-token-not-a-secret"
const CONTROL_UID := "12345678-1234-1234-1234-123456789abc"
const ATTACK_UID := "abcdefab-abcd-abcd-abcd-abcdefabcdef"
const LOOSE := 63


var _failed := false
var _auth: Object
var _flag := ""


class AuthHost extends Object:
	func is_authenticated() -> bool:
		return true


func _init() -> void:
	process_frame.connect(_start)


func _start() -> void:
	if _flag != "":
		return
	_flag = OS.get_user_data_dir().path_join("token-exposure.flag")
	OS.set_environment("TOKEN_EXPOSURE_FLAG", _flag)
	await _run()
	if _failed:
		quit(1)
		return
	print("token exposure ok")
	quit(0)


func check(cond: bool, message: String) -> void:
	if cond:
		print("PASS: ", message)
		return
	_failed = true
	push_error(message)
	print("FAIL: ", message)


func _run() -> void:
	var remote: Node = root.get_node_or_null("LauncherRemote")
	var single: Node = root.get_node_or_null("SingleInstance")
	var session: Node = root.get_node_or_null("Session")
	var installs: Node = root.get_node_or_null("Installs")
	var shell: Node = root.get_node_or_null("Shell")
	if remote == null or single == null or session == null or installs == null or shell == null:
		check(false, "autoload missing")
		return
	_startup_files_are_owner_only(remote)
	_arm_account(session)
	await _owner_can_drive(single, shell)
	await _loose_ipc_is_refused(single, shell)
	_fresh_ipc_is_owner_only(single)
	_fresh_remote_is_owner_only(remote)
	_loose_remote_is_refused(remote)
	_clear_watch()


func _startup_files_are_owner_only(remote: Node) -> void:
	var remote_path := str(remote._user_path())
	check(FileAccess.file_exists(remote_path), "startup writes the remote token file")
	check(_owner_only_file(remote_path), "startup remote token file is owner-only, mode %d" % _mode(remote_path))
	check(_owner_only_dir(remote_path.get_base_dir()), "startup remote token directory is owner-only, mode %d" % _mode(remote_path.get_base_dir()))
	var ipc_path := _ipc_path()
	check(FileAccess.file_exists(ipc_path), "startup writes the ipc token file")
	check(_owner_only_file(ipc_path), "startup ipc token file is owner-only, mode %d" % _mode(ipc_path))
	check(_owner_only_dir(ipc_path.get_base_dir()), "startup ipc token directory is owner-only, mode %d" % _mode(ipc_path.get_base_dir()))


func _arm_account(session: Node) -> void:
	if not Engine.has_singleton("Blazium"):
		_auth = AuthHost.new()
		Engine.register_singleton("Blazium", _auth)
	check(bool(session.is_authenticated()), "logged-in launcher session")
	session.invalidate_library()
	session._scripted = {
		"get_library": {
			"success": true,
			"data": {
				"library": [
					{"game_uid": CONTROL_UID, "name": "Control"},
					{"game_uid": ATTACK_UID, "name": "Attack"},
				],
			},
		},
		"get_game_overview": {"success": true, "data": {"name": "Game", "username": "dev"}},
		"get_game_changelog": {"success": true, "data": {}},
	}
	check(bool(session.owns(CONTROL_UID)) and bool(session.owns(ATTACK_UID)), "owned games")


func _owner_can_drive(single: Node, shell: Node) -> void:
	var path := _ipc_path()
	_plant(path, OWNER_TOKEN, false)
	_clear_watch()
	var loaded := str(single._load_or_create_token())
	single._token = loaded
	check(loaded == OWNER_TOKEN, "owner-only ipc token is loaded")
	shell.pending_page = "sentinel"
	await _send(single.PORT, "%s SHOW" % OWNER_TOKEN)
	check(str(shell.pending_page) == "home", "owner token focuses the launcher")
	await _send(single.PORT, "%s blazium://library" % OWNER_TOKEN)
	check(str(shell.pending_page) == "library", "owner token opens a library link")
	await _send(single.PORT, "%s blazium://game/%s" % [OWNER_TOKEN, CONTROL_UID])
	check(str(shell.pending_page) == "listing", "owner token opens a game link")
	check(bool(shell.pending_extra.get("launch", false)) and str(shell.pending_extra.get("uid", "")) == CONTROL_UID, "owner game link is marked to launch")


func _loose_ipc_is_refused(single: Node, shell: Node) -> void:
	var path := _ipc_path()
	_plant(path, PLANTED, true)
	check((_mode(path) & LOOSE) != 0, "planted ipc token is group or world accessible")
	OS.set_environment("TOKEN_EXPOSURE_LIE", path)
	var lied := _mode(path)
	check((lied & LOOSE) == 0, "path stat can hide group and world bits")
	_watch([path, path.get_base_dir()])
	var loaded := str(single._load_or_create_token())
	single._token = loaded
	var created_loose := _flag_text()
	_clear_watch()
	check(created_loose == "", "loading a token must not rewrite it with group or world access")
	check(loaded != PLANTED, "group or world readable ipc token must not be adopted")
	check(loaded.is_empty() or _owner_only_file(_ipc_path()), "adopted ipc token is stored owner-only")
	shell.pending_page = "sentinel"
	await _send(single.PORT, "%s SHOW" % PLANTED)
	check(str(shell.pending_page) == "sentinel", "readable ipc token must not focus the launcher")
	await _send(single.PORT, "%s blazium://library" % PLANTED)
	check(str(shell.pending_page) == "sentinel", "readable ipc token must not open a library link")
	await _send(single.PORT, "%s blazium://game/%s" % [PLANTED, ATTACK_UID])
	check(str(shell.pending_page) == "sentinel", "readable ipc token must not open a game link")


func _fresh_ipc_is_owner_only(single: Node) -> void:
	var path := _ipc_path()
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	_watch([path, path.get_base_dir()])
	var loaded := str(single._load_or_create_token())
	var created_loose := _flag_text()
	_clear_watch()
	check(not loaded.is_empty(), "new ipc token is created")
	check(created_loose == "", "new ipc token is never group or world accessible: %s" % created_loose.strip_edges())
	check(_owner_only_file(path), "ipc token file stays owner-only, mode %d" % _mode(path))
	check(_owner_only_dir(path.get_base_dir()), "ipc token directory stays owner-only, mode %d" % _mode(path.get_base_dir()))
	check(FileAccess.get_file_as_string(path).strip_edges() == loaded, "ipc token file matches the loaded token")


func _fresh_remote_is_owner_only(remote: Node) -> void:
	var parent := OS.get_user_data_dir().path_join("token-exposure-remote")
	DirAccess.make_dir_recursive_absolute(parent)
	_mode_set(parent, 493)
	var directory := parent.path_join("blazium")
	var path := directory.path_join("launcher_remote.json")
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	if DirAccess.dir_exists_absolute(directory):
		DirAccess.remove_absolute(directory)
	remote.config_path = path
	check(str(remote._user_path()).ends_with(".config/blazium/launcher_remote.json"), "linux remote token path")
	_watch([path, directory])
	remote._ensure_file()
	var created_loose := _flag_text()
	_clear_watch()
	remote._apply_settings()
	check(str(remote.host) == "127.0.0.1", "remote control stays on loopback")
	check(int(remote.port) == 39220, "remote control stays on its loopback port")
	check(not str(remote.token).is_empty(), "new remote token is created")
	check(created_loose == "", "new remote token is never group or world accessible: %s" % created_loose.strip_edges())
	check(_owner_only_file(path), "remote token file stays owner-only, mode %d" % _mode(path))
	check(_owner_only_dir(directory), "remote token directory stays owner-only, mode %d" % _mode(directory))
	var body := FileAccess.get_file_as_string(path)
	check(body.find(str(remote.token)) >= 0, "remote token file stores the active token")
	check(str(ProjectSettings.get_setting("blazium/remote_control/token", "")) == str(remote.token), "loopback server receives the owner-only remote token")
	check(str(ProjectSettings.get_setting("blazium/remote_control/bind_address", "")) == "127.0.0.1", "loopback bind is unchanged")


func _loose_remote_is_refused(remote: Node) -> void:
	var parent := OS.get_user_data_dir().path_join("token-exposure-remote-loose")
	DirAccess.make_dir_recursive_absolute(parent)
	_mode_set(parent, 493)
	var directory := parent.path_join("config")
	DirAccess.make_dir_recursive_absolute(directory)
	_mode_set(directory, 493)
	var path := directory.path_join("launcher_remote.json")
	_plant_json(path)
	check((_mode(path) & LOOSE) != 0, "planted remote token is group or world accessible")
	OS.set_environment("TOKEN_EXPOSURE_LIE", path)
	check((_mode(path) & LOOSE) == 0, "path stat can hide the remote token mode")
	_watch([path, directory])
	remote.config_path = path
	remote.token = ""
	remote._ensure_file()
	var created_loose := _flag_text()
	_clear_watch()
	remote._apply_settings()
	check(created_loose == "", "replacing a remote token must not write it with group or world access: %s" % created_loose.strip_edges())
	check(str(remote.token) != PLANTED, "group or world readable remote token must not be adopted")
	check(not str(remote.token).is_empty(), "remote token is replaced rather than cleared")
	check(_owner_only_file(path), "replacement remote token file is owner-only")
	check(_owner_only_dir(directory), "replacement remote token directory is owner-only")
	var body := FileAccess.get_file_as_string(path)
	check(body.find(PLANTED) < 0, "readable remote token is not left in the file")
	check(body.find(str(remote.token)) >= 0, "replacement remote token is the one stored owner-only")
	check(str(ProjectSettings.get_setting("blazium/remote_control/token", "")) == str(remote.token), "loopback server does not keep the readable remote token")


func _plant(path: String, value: String, loose: bool) -> void:
	_clear_watch()
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(value)
	file.close()
	if loose:
		_mode_set(path, 420)
	else:
		_mode_set(path, 384)


func _plant_json(path: String) -> void:
	_clear_watch()
	var payload := {"host": "127.0.0.1", "port": 39220, "token": PLANTED}
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(payload))
	file.close()
	_mode_set(path, 420)


func _send(port: int, text: String) -> void:
	var peer := StreamPeerTCP.new()
	var err := peer.connect_to_host("127.0.0.1", port)
	if err != OK:
		check(false, "loopback connect failed")
		return
	var ticks := 0
	while peer.get_status() == StreamPeerTCP.STATUS_CONNECTING and ticks < 40:
		peer.poll()
		await process_frame
		ticks += 1
	if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		check(false, "loopback control port did not accept")
		return
	peer.put_data(text.to_utf8_buffer())
	peer.poll()
	await _frames(8)
	peer.disconnect_from_host()


func _frames(count: int) -> void:
	for _i in count:
		await process_frame


func _ipc_path() -> String:
	return ProjectSettings.globalize_path("user://launcher_ipc.token")


func _mode(path: String) -> int:
	return int(FileAccess.get_unix_permissions(path)) & 4095


func _mode_set(path: String, mode: int) -> void:
	FileAccess.set_unix_permissions(path, mode)


func _owner_only_file(path: String) -> bool:
	var mode := _mode(path)
	return FileAccess.file_exists(path) and (mode & LOOSE) == 0 and (mode & 256) != 0 and (mode & 128) != 0


func _owner_only_dir(path: String) -> bool:
	var mode := _mode(path)
	return DirAccess.dir_exists_absolute(path) and (mode & LOOSE) == 0 and (mode & 256) != 0 and (mode & 64) != 0


func _watch(paths: Array) -> void:
	_clear_flag()
	OS.set_environment("TOKEN_EXPOSURE_WATCH", ":".join(paths))


func _clear_watch() -> void:
	OS.set_environment("TOKEN_EXPOSURE_WATCH", "")
	OS.set_environment("TOKEN_EXPOSURE_LIE", "")


func _clear_flag() -> void:
	if FileAccess.file_exists(_flag):
		DirAccess.remove_absolute(_flag)


func _flag_text() -> String:
	if not FileAccess.file_exists(_flag):
		return ""
	return FileAccess.get_file_as_string(_flag)
