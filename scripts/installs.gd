extends Node
## Local installs under the user data path. Launch only after the host says the account owns the game.

signal progress(game_uid: String, received: int, total: int)
signal changed(game_uid: String)

const CHANNELS := ["stable", "beta", "dev", "custom"]
const STALL_MS := 20000
const OVERALL_MS := 30 * 60 * 1000
const MAX_DOWNLOAD_BYTES := 32 * 1024 * 1024 * 1024
const MAX_UNCOMPRESSED := 512 * 1024 * 1024

var _procs: Dictionary = {}
var _installing: Dictionary = {}
var _cancel: Dictionary = {}
var _http: HTTPRequest


func _ready() -> void:
	pass


func _download(url: String, part: String, game_uid: String, paint: bool) -> Dictionary:
	var opened := _open_download(url, part, game_uid)
	if not bool(opened.get("ok", false)):
		return {"code": 0, "error": str(opened.get("error", "Download failed (0)"))}
	var client: HTTPClient = opened["client"]
	var started := int(opened["started"])
	var last := started
	var ticks := 0
	while client.get_status() == HTTPClient.STATUS_CONNECTING or client.get_status() == HTTPClient.STATUS_RESOLVING:
		client.poll()
		ticks += 1
		if ticks > 1000 or download_stalled(started, last, Time.get_ticks_msec(), STALL_MS, OVERALL_MS) or _cancelled(game_uid):
			client.close()
			return _download_fail(part, "Download timed out")
		if paint:
			await get_tree().process_frame
		else:
			OS.delay_msec(10)
	var err: Error = client.request(HTTPClient.METHOD_GET, str(opened.get("path", "/")), PackedStringArray())
	if err != OK:
		client.close()
		return _download_fail(part, "Download failed (0)")
	while client.get_status() == HTTPClient.STATUS_REQUESTING:
		client.poll()
		if download_stalled(started, last, Time.get_ticks_msec(), STALL_MS, OVERALL_MS) or _cancelled(game_uid):
			client.close()
			return _download_fail(part, "Download timed out")
		if paint:
			await get_tree().process_frame
		else:
			OS.delay_msec(10)
	var total := _content_length(client.get_response_headers())
	if total > MAX_DOWNLOAD_BYTES:
		client.close()
		return _download_fail(part, "Download is too large")
	var file: FileAccess = opened["file"]
	var hasher: HashingContext = opened["hasher"]
	var size := 0
	while client.get_status() == HTTPClient.STATUS_BODY:
		client.poll()
		var chunk := client.read_response_body_chunk()
		var now := Time.get_ticks_msec()
		if chunk.size() == 0:
			if download_stalled(started, last, now, STALL_MS, OVERALL_MS) or _cancelled(game_uid):
				file.close()
				client.close()
				return _download_fail(part, "Download timed out")
			if paint:
				await get_tree().process_frame
			else:
				OS.delay_msec(10)
			continue
		last = now
		var taken := _take_chunk(file, hasher, size, chunk)
		if not bool(taken.get("ok", false)):
			file.close()
			client.close()
			return _download_fail(part, str(taken.get("error", "Could not write the file")))
		size = int(taken.get("size", size))
		progress.emit(game_uid, size, total)
		if paint:
			await get_tree().process_frame
	return _finish_download(client, file, hasher, part, size)


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
	if pid == OS.get_process_id() or OS.is_process_running(pid):
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
		var pid := int(_procs[game_uid])
		if pid > 0 and pid != OS.get_process_id() and OS.is_process_running(pid):
			OS.kill(pid)
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
	if not _path_in_game(game_uid, exe):
		return {"ok": false, "error": "Installed file is outside the game folder"}
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
	var claim := _claim_install(game_uid)
	if not bool(claim.get("ok", false)):
		return claim
	var prepared := _prepare(game_uid, file_uid)
	if not bool(prepared.get("ok", false)):
		_release_install(game_uid)
		return prepared
	var part := str(prepared.get("dest", "")) + ".part"
	var fetched: Dictionary = {}
	for attempt in 3:
		fetched = _download_now(str(prepared.get("url", "")), part, game_uid)
		var code := int(fetched.get("code", 0))
		if code >= 200 and code < 300:
			break
		DirAccess.remove_absolute(part)
		if attempt < 2:
			OS.delay_msec(retry_wait_ms(attempt))
	var stored := _store(prepared, fetched)
	_release_install(game_uid)
	return stored


func _install_painted(game_uid: String, file_uid: String) -> Dictionary:
	var claim := _claim_install(game_uid)
	if not bool(claim.get("ok", false)):
		return claim
	var prepared := _prepare(game_uid, file_uid)
	if not bool(prepared.get("ok", false)):
		_release_install(game_uid)
		return prepared
	var part := str(prepared.get("dest", "")) + ".part"
	var fetched: Dictionary = {}
	for attempt in 3:
		fetched = await _download(str(prepared.get("url", "")), part, game_uid, true)
		var code := int(fetched.get("code", 0))
		if code >= 200 and code < 300:
			break
		DirAccess.remove_absolute(part)
		if attempt < 2:
			await get_tree().create_timer(float(retry_wait_ms(attempt)) / 1000.0).timeout
	var stored := _store(prepared, fetched)
	_release_install(game_uid)
	return stored


func _prepare(game_uid: String, file_uid: String) -> Dictionary:
	if not Session.is_authenticated():
		return {"ok": false, "error": "Sign in first"}
	if not Session.owns(game_uid):
		return {"ok": false, "error": "You do not own this game"}
	var listing := Session.files(game_uid)
	if not file_in_listing(listing, file_uid):
		return {"ok": false, "error": "That file is not part of this game"}
	var link := Session.download(file_uid)
	var linked_game := str(link.get("game_uid", ""))
	if linked_game != "" and linked_game != game_uid:
		return {"ok": false, "error": "That file is not part of this game"}
	var url := str(link.get("url", ""))
	if url.is_empty():
		return {"ok": false, "error": str(link.get("error", "No download url"))}
	if not bool(parse_download_url(url).get("ok", false)):
		return {"ok": false, "error": "Download URL must be https"}
	var filename := install_basename(str(link.get("filename", file_uid)))
	var dest := install_dest(game_uid, filename)
	if dest == "":
		return {"ok": false, "error": "The download filename is not valid"}
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
			"dest": dest,
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
		"dest": dest,
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
	var part := str(fetched.get("part", ""))
	if not _path_in_game(game_uid, dest):
		_discard_part(part)
		return {"ok": false, "error": "The download filename is not valid"}
	if code < 200 or code >= 300:
		_discard_part(part)
		return {"ok": false, "error": "Download failed (%s)" % code}
	var want := checksum_hex(str(prepared.get("checksum", "")))
	if want == "":
		_discard_part(part)
		return {"ok": false, "error": "The download has no checksum"}
	var got := ""
	var size := 0
	if part != "" and FileAccess.file_exists(part):
		got = str(fetched.get("sha256", "")).to_lower()
		size = int(fetched.get("size", -1))
		if size < 0 or _file_length(part) != size:
			_discard_part(part)
			return {"ok": false, "error": "Could not write the file"}
	else:
		got = _sha256_hex(body)
		size = body.size()
		part = dest + ".part"
		if not _write_all(part, body):
			_discard_part(part)
			return {"ok": false, "error": "Could not write the file"}
	if got != want:
		_discard_part(part)
		return {"ok": false, "error": "The download checksum does not match"}
	if not _commit_part(part, dest, size):
		return {"ok": false, "error": "Could not write the file"}
	if bool(prepared.get("overlay", false)):
		var target := str(prepared.get("overlay_dir", ""))
		if not _extract_zip(dest, target):
			DirAccess.remove_absolute(dest)
			return {"ok": false, "error": "Could not extract the mod"}
		DirAccess.remove_absolute(dest)
		if not _write_text(_overlay_marker(game_uid), target) or not _write_text(_marker(game_uid), target):
			return {"ok": false, "error": "Could not record the install"}
		_write_record(game_uid, prepared, target)
		changed.emit(game_uid)
		progress.emit(game_uid, size, size)
		return {"ok": true, "path": target, "status": "installed"}
	if not _write_text(_marker(game_uid), dest):
		return {"ok": false, "error": "Could not record the install"}
	_write_record(game_uid, prepared, dest)
	changed.emit(game_uid)
	progress.emit(game_uid, size, size)
	return {"ok": true, "path": dest, "status": "installed"}


func _download_now(url: String, part: String, game_uid: String) -> Dictionary:
	var opened := _open_download(url, part, game_uid)
	if not bool(opened.get("ok", false)):
		return {"code": 0, "error": str(opened.get("error", "Download failed (0)"))}
	var client: HTTPClient = opened["client"]
	var started := int(opened["started"])
	var last := started
	var ticks := 0
	while client.get_status() == HTTPClient.STATUS_CONNECTING or client.get_status() == HTTPClient.STATUS_RESOLVING:
		client.poll()
		OS.delay_msec(10)
		ticks += 1
		if ticks > 1000 or download_stalled(started, last, Time.get_ticks_msec(), STALL_MS, OVERALL_MS) or _cancelled(game_uid):
			client.close()
			return _download_fail(part, "Download timed out")
	var err: Error = client.request(HTTPClient.METHOD_GET, str(opened.get("path", "/")), PackedStringArray())
	if err != OK:
		client.close()
		return _download_fail(part, "Download failed (0)")
	while client.get_status() == HTTPClient.STATUS_REQUESTING:
		client.poll()
		OS.delay_msec(10)
		if download_stalled(started, last, Time.get_ticks_msec(), STALL_MS, OVERALL_MS) or _cancelled(game_uid):
			client.close()
			return _download_fail(part, "Download timed out")
	var total := _content_length(client.get_response_headers())
	if total > MAX_DOWNLOAD_BYTES:
		client.close()
		return _download_fail(part, "Download is too large")
	var file: FileAccess = opened["file"]
	var hasher: HashingContext = opened["hasher"]
	var size := 0
	while client.get_status() == HTTPClient.STATUS_BODY:
		client.poll()
		var chunk := client.read_response_body_chunk()
		var now := Time.get_ticks_msec()
		if chunk.size() == 0:
			if download_stalled(started, last, now, STALL_MS, OVERALL_MS) or _cancelled(game_uid):
				file.close()
				client.close()
				return _download_fail(part, "Download timed out")
			OS.delay_msec(10)
			continue
		last = now
		var taken := _take_chunk(file, hasher, size, chunk)
		if not bool(taken.get("ok", false)):
			file.close()
			client.close()
			return _download_fail(part, str(taken.get("error", "Could not write the file")))
		size = int(taken.get("size", size))
		progress.emit(game_uid, size, total)
	return _finish_download(client, file, hasher, part, size)


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


func revoked_game_uids() -> PackedStringArray:
	var ids: PackedStringArray = []
	if not Session.library_is_live():
		return ids
	for game_uid in installed_game_uids():
		if not Session.owns(game_uid):
			ids.append(game_uid)
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


func _extract_zip(zip_path: String, dest_dir: String, max_bytes: int = MAX_UNCOMPRESSED) -> bool:
	var declared := zip_declared_sizes(zip_path)
	if not bool(declared.get("ok", false)):
		return false
	var planned: Array = []
	var total := 0
	for entry in declared.get("entries", []):
		if not (entry is Dictionary):
			continue
		var rel := str(entry.get("name", "")).replace("\\", "/")
		if rel.ends_with("/") or not _zip_entry_ok(rel):
			continue
		var declared_size := int(entry.get("size", -1))
		if declared_size < 0 or declared_size > max_bytes or total + declared_size > max_bytes:
			return false
		total += declared_size
		planned.append({"name": rel, "size": declared_size})
	var temp := dest_dir + ".partial"
	_remove_dir(temp)
	var reader := ZIPReader.new()
	if reader.open(zip_path) != OK:
		return false
	var root := temp.simplify_path()
	DirAccess.make_dir_recursive_absolute(root)
	var uncompressed := 0
	var failed := false
	for item in planned:
		var rel := str(item.get("name", ""))
		var declared_size := int(item.get("size", 0))
		var out := root.path_join(rel).simplify_path()
		if out == root or not out.begins_with(root + "/"):
			continue
		if uncompressed + declared_size > max_bytes:
			failed = true
			break
		DirAccess.make_dir_recursive_absolute(out.get_base_dir())
		var bytes: PackedByteArray = reader.read_file(rel)
		if bytes.size() != declared_size or uncompressed + bytes.size() > max_bytes:
			failed = true
			break
		uncompressed += bytes.size()
		var out_file := FileAccess.open(out, FileAccess.WRITE)
		if out_file == null:
			failed = true
			break
		out_file.store_buffer(bytes)
		var write_err := out_file.get_error()
		var wrote := out_file.get_length()
		out_file.close()
		if write_err != OK or wrote != bytes.size():
			failed = true
			break
	reader.close()
	if failed or not _swap_dir(temp, dest_dir):
		_remove_dir(temp)
		return false
	return true


func install_basename(filename: String) -> String:
	var text := filename.replace("\\", "/").strip_edges()
	if text.find(String.chr(0)) >= 0:
		return ""
	var base := text.get_file().strip_edges()
	if base == "" or base == "." or base == ".." or base.contains("..") or base.contains(":") or base.contains("/") or base.contains("\\"):
		return ""
	for i in base.length():
		if base.unicode_at(i) < 32:
			return ""
	return base


func install_dest(game_uid: String, filename: String) -> String:
	var base := install_basename(filename)
	if base == "":
		return ""
	var root := _norm_path(game_dir(game_uid))
	var dest := _norm_path(root.path_join(base))
	if not dest.begins_with(root + "/") or dest.get_file() != base:
		return ""
	return dest


func file_in_listing(listing: Dictionary, file_uid: String) -> bool:
	return not _file_row(listing, file_uid).is_empty()


func parse_download_url(url: String) -> Dictionary:
	var text := url.strip_edges()
	if not text.to_lower().begins_with("https://"):
		return {"ok": false}
	var rest := text.substr(8)
	if rest.is_empty() or rest.begins_with("/") or rest.begins_with("\\") or rest.contains("@") or rest.contains("\\") or rest.contains(" "):
		return {"ok": false}
	var slash := rest.find("/")
	var hostport := rest if slash < 0 else rest.substr(0, slash)
	var path := "/" if slash < 0 else rest.substr(slash)
	var host := hostport
	var port := 443
	if hostport.begins_with("["):
		var end := hostport.find("]")
		if end <= 1:
			return {"ok": false}
		host = hostport.substr(1, end - 1)
		var tail := hostport.substr(end + 1)
		if tail.begins_with(":"):
			port = int(tail.substr(1))
	elif hostport.contains(":"):
		var bits := hostport.rsplit(":", true, 1)
		host = str(bits[0])
		port = int(bits[1])
	if host.is_empty() or host.contains(":") or port <= 0 or port > 65535:
		return {"ok": false}
	return {"ok": true, "host": host, "port": port, "path": path}


func download_stalled(started_ms: int, last_ms: int, now_ms: int, stall_ms: int, overall_ms: int) -> bool:
	if stall_ms > 0 and now_ms - last_ms >= stall_ms:
		return true
	if overall_ms > 0 and now_ms - started_ms >= overall_ms:
		return true
	return false


func retry_wait_ms(attempt: int) -> int:
	var wait := 200
	for _i in attempt:
		wait *= 2
		if wait > 2000:
			return 2000
	return wait


func cancel_download(game_uid: String) -> void:
	_cancel[game_uid] = true


func _claim_install(game_uid: String) -> Dictionary:
	if is_running(game_uid):
		return {"ok": false, "error": "This game is running"}
	if _installing.has(game_uid):
		return {"ok": false, "error": "This game is already installing"}
	_installing[game_uid] = true
	_cancel.erase(game_uid)
	return {"ok": true}


func _release_install(game_uid: String) -> void:
	_installing.erase(game_uid)
	_cancel.erase(game_uid)


func _cancelled(game_uid: String) -> bool:
	return bool(_cancel.get(game_uid, false))


func _norm_path(path: String) -> String:
	return path.simplify_path().replace("\\", "/")


func _path_in_game(game_uid: String, path: String) -> bool:
	var root := _norm_path(game_dir(game_uid))
	var dest := _norm_path(path)
	return dest.begins_with(root + "/")


func _open_download(url: String, part: String, _game_uid: String) -> Dictionary:
	var target := parse_download_url(url)
	if not bool(target.get("ok", false)):
		return {"ok": false, "error": "Download URL must be https"}
	var client := HTTPClient.new()
	var err := client.connect_to_host(str(target.get("host", "")), int(target.get("port", 443)), TLSOptions.client())
	if err != OK:
		return {"ok": false, "error": "Download failed (0)"}
	DirAccess.make_dir_recursive_absolute(part.get_base_dir())
	var file := FileAccess.open(part, FileAccess.WRITE)
	if file == null:
		client.close()
		return {"ok": false, "error": "Could not write the file"}
	var hasher := HashingContext.new()
	hasher.start(HashingContext.HASH_SHA256)
	return {
		"ok": true,
		"client": client,
		"file": file,
		"hasher": hasher,
		"path": str(target.get("path", "/")),
		"started": Time.get_ticks_msec(),
	}


func _take_chunk(file: FileAccess, hasher: HashingContext, size: int, chunk: PackedByteArray) -> Dictionary:
	if size + chunk.size() > MAX_DOWNLOAD_BYTES:
		return {"ok": false, "size": size, "error": "Download is too large"}
	file.store_buffer(chunk)
	if file.get_error() != OK:
		return {"ok": false, "size": size, "error": "Could not write the file"}
	hasher.update(chunk)
	return {"ok": true, "size": size + chunk.size()}


func _finish_download(client: HTTPClient, file: FileAccess, hasher: HashingContext, part: String, size: int) -> Dictionary:
	var code := client.get_response_code()
	var digest := hasher.finish().hex_encode().to_lower()
	var length := file.get_length()
	var err := file.get_error()
	file.close()
	client.close()
	if code < 200 or code >= 300 or err != OK or length != size:
		_discard_part(part)
		return {"code": code, "error": "Download failed (%s)" % code}
	return {"code": code, "sha256": digest, "size": size, "part": part}


func _download_fail(part: String, message: String) -> Dictionary:
	_discard_part(part)
	return {"code": 0, "error": message}


func _write_all(path: String, body: PackedByteArray) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_buffer(body)
	var err := file.get_error()
	var length := file.get_length()
	file.close()
	if err != OK or length != body.size():
		DirAccess.remove_absolute(path)
		return false
	return true


func _write_text(path: String, text: String) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(text)
	var err := file.get_error()
	file.close()
	return err == OK and FileAccess.file_exists(path)


func _commit_part(part: String, dest: String, expected: int) -> bool:
	if _file_length(part) != expected:
		_discard_part(part)
		return false
	var backup := dest + ".bak"
	var had := FileAccess.file_exists(dest)
	if had and DirAccess.rename_absolute(dest, backup) != OK:
		return false
	if DirAccess.rename_absolute(part, dest) != OK:
		if had:
			DirAccess.rename_absolute(backup, dest)
		_discard_part(part)
		return false
	if had:
		DirAccess.remove_absolute(backup)
	return true


func _file_length(path: String) -> int:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return -1
	var length := file.get_length()
	file.close()
	return length


func _discard_part(part: String) -> void:
	if part != "" and FileAccess.file_exists(part):
		DirAccess.remove_absolute(part)


func _swap_dir(temp: String, dest: String) -> bool:
	if not DirAccess.dir_exists_absolute(temp):
		return false
	DirAccess.make_dir_recursive_absolute(dest.get_base_dir())
	var backup := dest + ".old"
	_remove_dir(backup)
	var had := DirAccess.dir_exists_absolute(dest)
	if had and DirAccess.rename_absolute(dest, backup) != OK:
		return false
	if DirAccess.rename_absolute(temp, dest) != OK:
		if had:
			DirAccess.rename_absolute(backup, dest)
		return false
	if had:
		_remove_dir(backup)
	return true


func zip_declared_sizes(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"ok": false}
	var length := file.get_length()
	if length < 22:
		file.close()
		return {"ok": false}
	var tail_n := mini(length, 22 + 65535)
	file.seek(length - tail_n)
	var tail := file.get_buffer(tail_n)
	var eocd := _find_eocd(tail)
	if eocd < 0 or eocd + 22 > tail.size():
		file.close()
		return {"ok": false}
	var cd_size := _u32(tail, eocd + 12)
	var cd_off := _u32(tail, eocd + 16)
	if cd_size < 0 or cd_off < 0 or cd_off + cd_size > length:
		file.close()
		return {"ok": false}
	file.seek(cd_off)
	var cd := file.get_buffer(cd_size)
	file.close()
	var pos := 0
	var entries: Array = []
	while pos + 46 <= cd.size():
		if _u32(cd, pos) != 0x02014b50:
			break
		var compressed := _u32(cd, pos + 20)
		var uncompressed := _u32(cd, pos + 24)
		var name_len := _u16(cd, pos + 28)
		var extra_len := _u16(cd, pos + 30)
		var comment_len := _u16(cd, pos + 32)
		var next := pos + 46 + name_len + extra_len + comment_len
		if next > cd.size():
			return {"ok": false}
		if uncompressed == 0xFFFFFFFF or compressed == 0xFFFFFFFF:
			return {"ok": false}
		var name := cd.slice(pos + 46, pos + 46 + name_len).get_string_from_utf8()
		if not name.ends_with("/") and uncompressed == 0 and compressed > 0:
			return {"ok": false}
		entries.append({"name": name, "size": uncompressed})
		pos = next
	return {"ok": true, "entries": entries}


func _find_eocd(data: PackedByteArray) -> int:
	if data.size() < 22:
		return -1
	var i := data.size() - 22
	while i >= 0:
		if data[i] == 0x50 and data[i + 1] == 0x4b and data[i + 2] == 0x05 and data[i + 3] == 0x06:
			return i
		i -= 1
	return -1


func _u16(data: PackedByteArray, at: int) -> int:
	return data[at] | (data[at + 1] << 8)


func _u32(data: PackedByteArray, at: int) -> int:
	return data[at] | (data[at + 1] << 8) | (data[at + 2] << 16) | (data[at + 3] << 24)


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
