extends Node
## Local installs under the user data path. Launch only after the host says the account owns the game.

signal progress(game_uid: String, received: int, total: int)
signal changed(game_uid: String)

var _procs: Dictionary = {}
var _http: HTTPRequest


func _ready() -> void:
	pass


func _download(url: String, game_uid: String, paint: bool) -> Dictionary:
	var client := HTTPClient.new()
	var err := OK
	if url.begins_with("https"):
		err = client.connect_to_host(url.substr(8).split("/")[0], 443, TLSOptions.client())
	else:
		err = client.connect_to_host(url.substr(7).split("/")[0], 80)
	if err != OK:
		return {"code": 0, "body": PackedByteArray()}
	var ticks := 0
	while client.get_status() == HTTPClient.STATUS_CONNECTING or client.get_status() == HTTPClient.STATUS_RESOLVING:
		client.poll()
		if paint:
			await get_tree().process_frame
		else:
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
		if paint:
			await get_tree().process_frame
		else:
			OS.delay_msec(10)
	var total := _content_length(client.get_response_headers())
	var body := PackedByteArray()
	while client.get_status() == HTTPClient.STATUS_BODY:
		client.poll()
		var chunk := client.read_response_body_chunk()
		if chunk.size() == 0:
			if paint:
				await get_tree().process_frame
			else:
				OS.delay_msec(10)
		else:
			body.append_array(chunk)
			progress.emit(game_uid, body.size(), total)
			if paint:
				await get_tree().process_frame
	return {"code": client.get_response_code(), "body": body}


func _content_length(headers: PackedStringArray) -> int:
	for header in headers:
		var lower := header.to_lower()
		if lower.begins_with("content-length:"):
			return int(lower.substr(15).strip_edges())
	return 0


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
	var overlay := _overlay_marker(game_uid)
	if FileAccess.file_exists(overlay):
		var target := FileAccess.get_file_as_string(overlay).strip_edges()
		if _overlay_target_ok(target):
			_remove_dir(target)
	_remove_dir(game_dir(game_uid))
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
	return _install_now(game_uid, file_uid)


func install_file_with_progress(game_uid: String, file_uid: String) -> Dictionary:
	return await _install_painted(game_uid, file_uid)


func _install_now(game_uid: String, file_uid: String) -> Dictionary:
	var prepared := _prepare(game_uid, file_uid)
	if not bool(prepared.get("ok", false)):
		return prepared
	var fetched := _download_now(str(prepared.get("url", "")), game_uid)
	return _store(prepared, fetched)


func _install_painted(game_uid: String, file_uid: String) -> Dictionary:
	var prepared := _prepare(game_uid, file_uid)
	if not bool(prepared.get("ok", false)):
		return prepared
	var fetched: Dictionary = await _download(str(prepared.get("url", "")), game_uid, true)
	return _store(prepared, fetched)


func _prepare(game_uid: String, file_uid: String) -> Dictionary:
	if not Session.is_authenticated():
		return {"ok": false, "error": "Sign in first"}
	if not Session.owns(game_uid):
		return {"ok": false, "error": "You do not own this game"}
	var link := Session.download(file_uid)
	var url := str(link.get("url", ""))
	if url.is_empty():
		return {"ok": false, "error": str(link.get("error", "No download url"))}
	var filename := str(link.get("filename", file_uid))
	var listing := Session.files(game_uid)
	var settings: Dictionary = listing.get("mod_settings", {}) if listing.get("mod_settings") is Dictionary else {}
	var loader := str(settings.get("loader", "")).strip_edges()
	var install_path := str(settings.get("install_path", "")).strip_edges()
	DirAccess.make_dir_recursive_absolute(game_dir(game_uid))
	if loader != "" and install_path != "":
		var parent: Dictionary = listing.get("parent", {}) if listing.get("parent") is Dictionary else {}
		var parent_uid := str(parent.get("uid", ""))
		if parent_uid == "" or not is_installed(parent_uid):
			return {"ok": false, "error": "The parent game is not installed"}
		var target := _overlay_dir(parent_uid, install_path)
		if target == "":
			return {"ok": false, "error": "The install path is not valid"}
		return {
			"ok": true,
			"url": url,
			"dest": game_dir(game_uid).path_join(filename),
			"game_uid": game_uid,
			"overlay": true,
			"overlay_dir": target,
		}
	return {"ok": true, "url": url, "dest": game_dir(game_uid).path_join(filename), "game_uid": game_uid}


func _store(prepared: Dictionary, fetched: Dictionary) -> Dictionary:
	var game_uid := str(prepared.get("game_uid", ""))
	var dest := str(prepared.get("dest", ""))
	var code := int(fetched.get("code", 0))
	var body: PackedByteArray = fetched.get("body", PackedByteArray())
	if code < 200 or code >= 300:
		return {"ok": false, "error": "Download failed (%s)" % code}
	var f := FileAccess.open(dest, FileAccess.WRITE)
	if f == null:
		return {"ok": false, "error": "Could not write the file"}
	f.store_buffer(body)
	f.close()
	if bool(prepared.get("overlay", false)):
		var target := str(prepared.get("overlay_dir", ""))
		if not _extract_zip(dest, target):
			DirAccess.remove_absolute(dest)
			return {"ok": false, "error": "Could not extract the mod"}
		DirAccess.remove_absolute(dest)
		var note := FileAccess.open(_overlay_marker(game_uid), FileAccess.WRITE)
		if note == null:
			return {"ok": false, "error": "Could not record the install"}
		note.store_string(target)
		note.close()
		var marker := FileAccess.open(_marker(game_uid), FileAccess.WRITE)
		if marker != null:
			marker.store_string(target)
			marker.close()
		changed.emit(game_uid)
		progress.emit(game_uid, body.size(), body.size())
		return {"ok": true, "path": target, "status": "installed"}
	var marker := FileAccess.open(_marker(game_uid), FileAccess.WRITE)
	if marker != null:
		marker.store_string(dest)
		marker.close()
	changed.emit(game_uid)
	progress.emit(game_uid, body.size(), body.size())
	return {"ok": true, "path": dest, "status": "installed"}


func _download_now(url: String, game_uid: String) -> Dictionary:
	var client := HTTPClient.new()
	var err := OK
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
	var total := _content_length(client.get_response_headers())
	var body := PackedByteArray()
	while client.get_status() == HTTPClient.STATUS_BODY:
		client.poll()
		var chunk := client.read_response_body_chunk()
		if chunk.size() == 0:
			OS.delay_msec(10)
		else:
			body.append_array(chunk)
			progress.emit(game_uid, body.size(), total)
	return {"code": client.get_response_code(), "body": body}


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


func _overlay_marker(game_uid: String) -> String:
	return game_dir(game_uid).path_join("installed.overlay")


func _overlay_dir(parent_uid: String, install_path: String) -> String:
	var clean := install_path.replace("\\", "/").strip_edges()
	if clean == "" or clean.begins_with("/") or clean.contains("..") or clean.contains(":"):
		return ""
	var parts := clean.split("/", false)
	var rel := ""
	for part in parts:
		if part == "" or part == "." or part == "..":
			return ""
		rel = part if rel == "" else rel.path_join(part)
	var root := game_dir(parent_uid).simplify_path()
	var target := root.path_join(rel).simplify_path()
	if target == root or not target.begins_with(root + "/"):
		return ""
	return target


func _overlay_target_ok(target: String) -> bool:
	var clean := target.simplify_path()
	var library := root_dir().simplify_path()
	if clean == "" or clean == library or not clean.begins_with(library + "/"):
		return false
	var rest := clean.substr(library.length() + 1)
	return rest.find("/") >= 0


func _zip_entry_ok(name: String) -> bool:
	var rel := name.replace("\\", "/")
	if rel.begins_with("/") or rel.contains("..") or rel.contains(":"):
		return false
	return rel != ""


func _extract_zip(zip_path: String, dest_dir: String) -> bool:
	var reader := ZIPReader.new()
	if reader.open(zip_path) != OK:
		return false
	var root := dest_dir.simplify_path()
	DirAccess.make_dir_recursive_absolute(root)
	var ok := true
	for name in reader.get_files():
		if not _zip_entry_ok(str(name)):
			continue
		var rel := str(name).replace("\\", "/")
		if rel.ends_with("/"):
			DirAccess.make_dir_recursive_absolute(root.path_join(rel.trim_suffix("/")))
			continue
		var out := root.path_join(rel).simplify_path()
		if out == root or not out.begins_with(root + "/"):
			continue
		DirAccess.make_dir_recursive_absolute(out.get_base_dir())
		var bytes: PackedByteArray = reader.read_file(name)
		var out_file := FileAccess.open(out, FileAccess.WRITE)
		if out_file == null:
			ok = false
			continue
		out_file.store_buffer(bytes)
		out_file.close()
	reader.close()
	return ok


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
