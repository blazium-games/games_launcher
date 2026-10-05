extends Node
## Loopback remote_control on port 39220. Own token in launcher_remote.json. Eval stays off.

const DEFAULT_PORT := 39220

var host: String = "127.0.0.1"
var port: int = DEFAULT_PORT
var token: String = ""
var config_path: String = ""
var ensure_only: bool = false


func _ready() -> void:
	for arg in OS.get_cmdline_user_args() + OS.get_cmdline_args():
		var text := str(arg)
		if text == "--ensure-launcher-remote":
			ensure_only = true
		elif text.begins_with("--launcher-remote-path="):
			config_path = text.substr("--launcher-remote-path=".length()).strip_edges()
	call_deferred("_bootstrap")


func _bootstrap() -> void:
	if config_path.is_empty():
		var user := _user_path()
		config_path = user if _valid(user) or not _valid(_machine_path()) else _machine_path()
		if not _valid(config_path):
			config_path = user
	_ensure_file()
	_apply_settings()
	if ensure_only:
		get_tree().quit(0)
		return
	_start()
	_register()


func _user_path() -> String:
	if OS.get_name() == "Windows":
		var base := OS.get_environment("APPDATA")
		if base.is_empty():
			base = OS.get_environment("USERPROFILE").path_join("AppData").path_join("Roaming")
		return base.path_join("blazium").path_join("launcher_remote.json")
	var home := OS.get_environment("HOME")
	if home.is_empty():
		home = OS.get_environment("USERPROFILE")
	return home.path_join(".config").path_join("blazium").path_join("launcher_remote.json")


func _machine_path() -> String:
	if OS.get_name() == "Windows":
		var base := OS.get_environment("PROGRAMDATA")
		if base.is_empty():
			base = "C:/ProgramData"
		return base.path_join("blazium").path_join("launcher_remote.json")
	return "/etc/blazium/launcher_remote.json"


func _valid(path: String) -> bool:
	if not FileAccess.file_exists(path):
		return false
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed is Dictionary and not str(parsed.get("token", "")).is_empty()


func _ensure_file() -> void:
	var parsed = {}
	if FileAccess.file_exists(config_path):
		var raw = JSON.parse_string(FileAccess.get_file_as_string(config_path))
		if raw is Dictionary:
			parsed = raw
	token = str(parsed.get("token", "")).strip_edges()
	if token.is_empty():
		token = _random_token()
	host = "127.0.0.1"
	port = DEFAULT_PORT
	var payload := {
		"host": host,
		"port": port,
		"token": token,
		"executable": OS.get_executable_path(),
		"created_unix": int(parsed.get("created_unix", Time.get_unix_time_from_system())),
	}
	DirAccess.make_dir_recursive_absolute(config_path.get_base_dir())
	var f := FileAccess.open(config_path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(payload, "\t"))
		f.close()


func _random_token() -> String:
	var crypto := Crypto.new()
	return crypto.generate_random_bytes(32).hex_encode()


func _apply_settings() -> void:
	ProjectSettings.set_setting("blazium/remote_control/server_enabled", true)
	ProjectSettings.set_setting("blazium/remote_control/allow_runtime", true)
	ProjectSettings.set_setting("blazium/remote_control/server_port", port)
	ProjectSettings.set_setting("blazium/remote_control/bind_address", host)
	ProjectSettings.set_setting("blazium/remote_control/token", token)
	ProjectSettings.set_setting("blazium/remote_control/allow_eval", false)


func _start() -> void:
	if not Engine.has_singleton("RemoteControlServer"):
		return
	var server = Engine.get_singleton("RemoteControlServer")
	if server.has_method("set_token"):
		server.set_token(token)
	if server.has_method("is_started") and bool(server.is_started()):
		return
	if server.has_method("start"):
		server.start()


func _register() -> void:
	if not Engine.has_singleton("RemoteControlRegistry"):
		return
	var registry = Engine.get_singleton("RemoteControlRegistry")
	if not registry.has_method("register_command"):
		return
	registry.register_command("ping", Callable(self, "_ping"), "Liveness")
	registry.register_command("focus", Callable(self, "_focus"), "Focus the launcher")
	registry.register_command("open_uri", Callable(self, "_open_uri"), "Forward a blazium:// URI")


func _ping(_args: Dictionary) -> Dictionary:
	return {"ok": true, "pong": true}


func _focus(_args: Dictionary) -> Dictionary:
	Shell.focus_window()
	return {"ok": true, "focused": true}


func _open_uri(args: Dictionary) -> Dictionary:
	var uri := str(args.get("uri", ""))
	if not uri.begins_with("blazium://"):
		return {"ok": false, "error": "uri required"}
	UriRouter.open_uri(uri)
	return {"ok": true, "uri": uri}
