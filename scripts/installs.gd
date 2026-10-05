extends Node
## Local installs under the user data path. Launch only after the host says the account owns the game.

signal progress(game_uid: String, received: int, total: int)
signal changed(game_uid: String)

var _procs: Dictionary = {}
var _http: HTTPRequest


func _ready() -> void:
	pass


func _download(url: String) -> Dictionary:
	var client := HTTPClient.new()
	var err := client.connect_to_host(url.substr(url.find("://") + 3).split("/")[0], 443 if url.begins_with("https") else 80)
	if url.begins_with("https"):
		err = client.connect_to_host(url.substr(8).split("/")[0], 443, TLSOptions.client())
	else:
		err = client.connect_to_host(url.substr(7).split("/")[0], 80)
	if err != OK:
		return {"code": 0, "body": PackedByteArray()}
	var ticks := 0
	while client.get_status() == HTTPClient.STATUS_CONNECTING or client.get_status() == HTTPClient.STATUS_RESOLVING:
		client.poll()
		OS.delay_msec(10)
		ticks += 1
		if ticks > 1000:
			return {"code": 0, "body": PackedByteArray()}
	var path := "/"
	var slash := url.find("/", url.find("://") + 3)
	if slash >= 0:
		path = url.substr(slash)
	err = client.request(HTTPClient.METHOD_GET, path, [])
	if err != OK:
		return {"code": 0, "body": PackedByteArray()}
	while client.get_status() == HTTPClient.STATUS_REQUESTING:
		client.poll()
		OS.delay_msec(10)
	var body := PackedByteArray()
	while client.get_status() == HTTPClient.STATUS_BODY:
		client.poll()
		var chunk := client.read_response_body_chunk()
		if chunk.size() == 0:
			OS.delay_msec(10)
		else:
			body.append_array(chunk)
	return {"code": client.get_response_code(), "body": body}


func root_dir() -> String:
	return OS.get_user_data_dir().path_join("library")


func game_dir(game_uid: String) -> String:
	return root_dir().path_join(game_uid)


func is_installed(game_uid: String) -> bool:
	return FileAccess.file_exists(_marker(game_uid))


func is_running(game_uid: String) -> bool:
	var pid := int(_procs.get(game_uid, 0))
	if pid <= 0:
		return false
	if OS.is_process_running(pid):
		return true
	_procs.erase(game_uid)
	return false


func status(game_uid: String) -> String:
	if is_running(game_uid):
		return "running"
	if is_installed(game_uid):
		return "installed"
	return "stopped"


func uninstall(game_uid: String) -> void:
	if is_running(game_uid):
		OS.kill(int(_procs[game_uid]))
		_procs.erase(game_uid)
	var dir := game_dir(game_uid)
	_remove_dir(dir)
	changed.emit(game_uid)


func launch(game_uid: String) -> Dictionary:
	if not Session.owns(game_uid):
		return {"ok": false, "error": "You do not own this game"}
	if not is_installed(game_uid):
		return {"ok": false, "error": "Not installed"}
	if is_running(game_uid):
		return {"ok": true, "status": "running"}
	var exe := FileAccess.get_file_as_string(_marker(game_uid)).strip_edges()
	if exe.is_empty() or not FileAccess.file_exists(exe):
		return {"ok": false, "error": "Installed file is missing"}
	var pid := OS.create_process(exe, [])
	if pid <= 0:
		return {"ok": false, "error": "Failed to start"}
	_procs[game_uid] = pid
	changed.emit(game_uid)
	return {"ok": true, "status": "running", "pid": pid}


func install_file(game_uid: String, file_uid: String) -> Dictionary:
	if not Session.is_authenticated():
		return {"ok": false, "error": "Sign in first"}
	if not Session.owns(game_uid):
		return {"ok": false, "error": "You do not own this game"}
	var link := Session.download(file_uid)
	var url := str(link.get("url", ""))
	if url.is_empty():
		return {"ok": false, "error": str(link.get("error", "No download url"))}
	var filename := str(link.get("filename", file_uid))
	DirAccess.make_dir_recursive_absolute(game_dir(game_uid))
	var dest := game_dir(game_uid).path_join(filename)
	var fetched := _download(url)
	var code := int(fetched.get("code", 0))
	var body: PackedByteArray = fetched.get("body", PackedByteArray())
	if code < 200 or code >= 300:
		return {"ok": false, "error": "Download failed (%s)" % code}
	var f := FileAccess.open(dest, FileAccess.WRITE)
	if f == null:
		return {"ok": false, "error": "Could not write the file"}
	f.store_buffer(body)
	f.close()
	var marker := FileAccess.open(_marker(game_uid), FileAccess.WRITE)
	if marker != null:
		marker.store_string(dest)
		marker.close()
	changed.emit(game_uid)
	progress.emit(game_uid, body.size(), body.size())
	return {"ok": true, "path": dest, "status": "installed"}


func pick_file(game_uid: String, channel: String) -> String:
	var body := Session.files(game_uid)
	var rows = body.get("files", [])
	if not (rows is Array):
		return ""
	var os_name := "windows" if OS.get_name() == "Windows" else "linux"
	var fallback := ""
	for row in rows:
		if not (row is Dictionary):
			continue
		if not bool(row.get("downloadable", false)):
			continue
		var uid := str(row.get("file_uid", ""))
		if str(row.get("os", "")).to_lower() != os_name:
			continue
		if channel != "" and str(row.get("channel", "")).to_lower() != channel:
			continue
		if bool(row.get("latest", false)):
			return uid
		if fallback.is_empty():
			fallback = uid
	return fallback


func _marker(game_uid: String) -> String:
	return game_dir(game_uid).path_join("installed.path")


func _remove_dir(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if name != "." and name != "..":
			var child := path.path_join(name)
			if dir.current_is_dir():
				_remove_dir(child)
			else:
				dir.remove(name)
		name = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(path)
