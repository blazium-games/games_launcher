extends Node
## Local installs under the user data path. Launch only after the host says the account owns the game.

signal progress(game_uid: String, received: int, total: int)
signal changed(game_uid: String)

const CHANNELS := ["stable", "beta", "dev", "custom"]

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
	var row := _file_row(listing, file_uid)
	var channel := str(row.get("channel", "")).strip_edges().to_lower()
	if channel == "" or not CHANNELS.has(channel):
		channel = "stable"
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
			"checksum": str(link.get("checksum", "")),
			"file_uid": file_uid,
			"build_id": str(row.get("build_id", "")),
			"channel": channel,
		}
	return {
		"ok": true,
		"url": url,
		"dest": game_dir(game_uid).path_join(filename),
		"game_uid": game_uid,
		"checksum": str(link.get("checksum", "")),
		"file_uid": file_uid,
		"build_id": str(row.get("build_id", "")),
		"channel": channel,
	}


func _store(prepared: Dictionary, fetched: Dictionary) -> Dictionary:
	var game_uid := str(prepared.get("game_uid", ""))
	var dest := str(prepared.get("dest", ""))
	var code := int(fetched.get("code", 0))
	var body: PackedByteArray = fetched.get("body", PackedByteArray())
	if code < 200 or code >= 300:
		return {"ok": false, "error": "Download failed (%s)" % code}
	var want := checksum_hex(str(prepared.get("checksum", "")))
	if want == "":
		return {"ok": false, "error": "The download has no checksum"}
	var got := _sha256_hex(body)
	if got != want:
		return {"ok": false, "error": "The download checksum does not match"}
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
		_write_record(game_uid, prepared, target)
		changed.emit(game_uid)
		progress.emit(game_uid, body.size(), body.size())
		return {"ok": true, "path": target, "status": "installed"}
	var marker := FileAccess.open(_marker(game_uid), FileAccess.WRITE)
	if marker != null:
		marker.store_string(dest)
		marker.close()
	_write_record(game_uid, prepared, dest)
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


func os_name() -> String:
	return "windows" if OS.get_name() == "Windows" else "linux"


func allowed_channel(channel: String) -> bool:
	return CHANNELS.has(channel.strip_edges().to_lower())


func resolve_channel(channel: String, listing_channel: String = "") -> String:
	var chosen := channel.strip_edges().to_lower()
	if chosen.is_empty():
		chosen = listing_channel.strip_edges().to_lower()
	if chosen.is_empty():
		return "stable"
	if not CHANNELS.has(chosen):
		return ""
	return chosen


func pick_from_rows(rows: Variant, channel: String, host_os: String) -> String:
	if not (rows is Array) or not CHANNELS.has(channel):
		return ""
	var fallback := ""
	for row in rows:
		if not (row is Dictionary):
			continue
		if not bool(row.get("downloadable", false)):
			continue
		var uid := str(row.get("file_uid", ""))
		if uid.is_empty():
			continue
		if str(row.get("os", "")).to_lower() != host_os:
			continue
		if str(row.get("channel", "")).to_lower() != channel:
			continue
		if bool(row.get("latest", false)):
			return uid
		if fallback.is_empty():
			fallback = uid
	return fallback


func pick_file(game_uid: String, channel: String) -> String:
	var body := Session.files(game_uid)
	var chosen := resolve_channel(channel, str(body.get("channel", "")))
	if chosen.is_empty():
		return ""
	return pick_from_rows(body.get("files", []), chosen, os_name())


func plan_update(record: Dictionary, listing: Dictionary, host_os: String) -> Dictionary:
	var chosen := resolve_channel(str(record.get("channel", "")), str(listing.get("channel", "")))
	if chosen.is_empty():
		return {}
	var latest := pick_from_rows(listing.get("files", []), chosen, host_os)
	if latest.is_empty() or latest == str(record.get("file_uid", "")):
		return {}
	var build_id := ""
	var rows = listing.get("files", [])
	if rows is Array:
		for row in rows:
			if row is Dictionary and str(row.get("file_uid", "")) == latest:
				build_id = str(row.get("build_id", ""))
				break
	return {"file_uid": latest, "build_id": build_id, "channel": chosen}


func offer_for(game_uid: String) -> Dictionary:
	if not is_installed(game_uid):
		return {}
	return plan_update(read_record(game_uid), Session.files(game_uid), os_name())


func pending_update_count() -> int:
	if not Session.is_authenticated():
		return 0
	var count := 0
	var host_os := os_name()
	for game_uid in installed_game_uids():
		if not plan_update(read_record(game_uid), Session.files(game_uid), host_os).is_empty():
			count += 1
	return count


func installed_game_uids() -> PackedStringArray:
	var ids: PackedStringArray = []
	var dir := DirAccess.open(root_dir())
	if dir == null:
		return ids
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if dir.current_is_dir() and name != "." and name != "..":
			if FileAccess.file_exists(_marker(name)):
				ids.append(name)
		name = dir.get_next()
	dir.list_dir_end()
	return ids


func read_record(game_uid: String) -> Dictionary:
	var path := record_path(game_uid)
	if not FileAccess.file_exists(path):
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if parsed is Dictionary:
		return parsed
	return {}


func record_path(game_uid: String) -> String:
	return game_dir(game_uid).path_join("installed.json")


func checksum_hex(raw: String) -> String:
	var text := raw.strip_edges().to_lower()
	if text.begins_with("sha256:"):
		text = text.substr(7).strip_edges()
	if text.length() != 64:
		return ""
	for i in text.length():
		var ch := text.unicode_at(i)
		var ok := (ch >= 48 and ch <= 57) or (ch >= 97 and ch <= 102)
		if not ok:
			return ""
	return text


func _sha256_hex(body: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(body)
	return ctx.finish().hex_encode().to_lower()


func _file_row(listing: Dictionary, file_uid: String) -> Dictionary:
	var rows = listing.get("files", [])
	if not (rows is Array):
		return {}
	for row in rows:
		if row is Dictionary and str(row.get("file_uid", "")) == file_uid:
			return row
	return {}


func _write_record(game_uid: String, prepared: Dictionary, path: String) -> void:
	var channel := str(prepared.get("channel", "")).strip_edges().to_lower()
	if not CHANNELS.has(channel):
		channel = "stable"
	var record := {
		"file_uid": str(prepared.get("file_uid", "")),
		"build_id": str(prepared.get("build_id", "")),
		"channel": channel,
		"path": path,
	}
	var out := FileAccess.open(record_path(game_uid), FileAccess.WRITE)
	if out == null:
		return
	out.store_string(JSON.stringify(record))
	out.close()


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
	var uncompressed := 0
	const max_uncompressed := 512 * 1024 * 1024
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
		uncompressed += bytes.size()
		if uncompressed > max_uncompressed:
			reader.close()
			return false
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
