extends Node
## Launch update prompts. "Not now" lasts until the next relaunch.
## A launcher update skips separate CLI and crash reporter prompts, because the installer ships both.

signal status_changed(message: String)

const PRODUCT_ORDER := ["launcher", "cli", "crash_reporter"]
const PRODUCT_LABELS := {
	"launcher": "BlaziumLauncher",
	"cli": "blazium-cli",
	"crash_reporter": "Blazium Crash Reporter",
}

var _dismissed: Dictionary = {}
var _queue: Array = []
var _products: Array = []
var _busy: bool = false
var _quit_when_idle: bool = false
var _dialog: ConfirmationDialog
var _pending: Dictionary = {}
var _last_summary: String = ""
var _last_error: String = ""
var _launcher_includes_cli: bool = false
var _launcher_includes_crash_reporter: bool = false
var _exec_mutex := Mutex.new()
var _exec_done: bool = false
var _exec_code: int = 1
var _exec_text: String = ""


func get_last_summary() -> String:
	return _last_summary


func clear_dismissals() -> void:
	_dismissed.clear()


func launcher_version() -> String:
	return str(ProjectSettings.get_setting("application/config/version", ""))


func _version_parts(text: String) -> Array:
	var raw := text.strip_edges()
	if raw.is_empty():
		return []
	if raw.begins_with("v") and raw.length() > 1 and raw.substr(1, 1).is_valid_int():
		raw = raw.substr(1)
	var core := raw.split("-")[0].split("+")[0]
	var parts: Array = []
	for piece in core.split("."):
		if piece.is_empty() or not piece.is_valid_int():
			return []
		parts.append(int(piece))
	return parts


func compare_versions(a: String, b: String) -> int:
	var pa := _version_parts(a)
	var pb := _version_parts(b)
	if pa.is_empty() or pb.is_empty():
		return -2
	var width := pa.size()
	if pb.size() > width:
		width = pb.size()
	for i in width:
		var av := 0
		var bv := 0
		if i < pa.size():
			av = int(pa[i])
		if i < pb.size():
			bv = int(pb[i])
		if av < bv:
			return -1
		if av > bv:
			return 1
	return 0


func _has_hash(item: Dictionary) -> bool:
	var digest := str(item.get("sha256", "")).strip_edges().to_lower()
	if digest.begins_with("sha256:"):
		digest = digest.trim_prefix("sha256:")
	if digest.length() != 64:
		return false
	for i in digest.length():
		var ch := digest.unicode_at(i)
		var hex := (ch >= 48 and ch <= 57) or (ch >= 97 and ch <= 102)
		if not hex:
			return false
	return true


func update_is_upgrade(latest: String, current: String) -> bool:
	if latest.strip_edges().is_empty() or current.strip_edges().is_empty():
		return false
	return compare_versions(latest, current) == 1


func _version_floor(item: Dictionary) -> String:
	var current := str(item.get("current_version", "")).strip_edges()
	if current.is_empty() and str(item.get("product", "")) == "launcher":
		current = launcher_version()
	return current


func install_dir() -> String:
	return OS.get_executable_path().get_base_dir()


func launcher_update_outstanding(products: Array) -> bool:
	return _find_product_status(products, "launcher") != null


func build_update_queue(products: Array, dismissed: Dictionary) -> Array:
	var launcher_outstanding := launcher_update_outstanding(products) and not dismissed.has("launcher")
	var queue: Array = []
	for name in PRODUCT_ORDER:
		if (name == "cli" or name == "crash_reporter") and launcher_outstanding:
			continue
		if dismissed.has(name):
			continue
		var item: Variant = _find_product_status(products, name)
		if item == null:
			continue
		queue.append(item)
	return queue


func prompt_title(product: String) -> String:
	return "%s Update Available" % str(PRODUCT_LABELS.get(product, product))


func prompt_body(product: String, latest: String, current: String) -> String:
	var label := str(PRODUCT_LABELS.get(product, product))
	var cur := current if not current.is_empty() else "(unknown)"
	return "%s %s is available (current %s). Update now?" % [label, latest, cur]


func check_and_prompt(clear_session_dismissals: bool = false) -> void:
	if _busy:
		return
	if clear_session_dismissals:
		clear_dismissals()
	_busy = true
	status_changed.emit("Checking for updates…")
	var data: Variant = await _run(PackedStringArray([
		"update", "check",
		"--product", "launcher,cli,crash_reporter",
		"--current", launcher_version(),
		"--install-root", install_dir(),
	]))
	if data == null:
		_last_summary = friendly_update_error(_last_error if not _last_error.is_empty() else "Update check skipped")
		status_changed.emit(_last_summary)
		_busy = false
		return
	var products: Array = []
	if typeof(data) == TYPE_DICTIONARY:
		var p = data.get("products", [])
		if typeof(p) == TYPE_ARRAY:
			products = p
	_launcher_includes_cli = (
		launcher_update_outstanding(products) and _find_product_status(products, "cli") != null
	)
	_launcher_includes_crash_reporter = (
		launcher_update_outstanding(products) and _find_product_status(products, "crash_reporter") != null
	)
	_products = products
	_queue = build_update_queue(products, _dismissed)
	if _queue.is_empty():
		_last_summary = check_status_summary(products, _queue)
		status_changed.emit(_last_summary)
		_busy = false
		return
	_last_summary = "%d update(s) available" % _queue.size()
	status_changed.emit(_last_summary)
	_show_next()


func _find_product_status(products: Array, name: String) -> Variant:
	for item in products:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		if str(item.get("product", "")) != name:
			continue
		if not bool(item.get("update_available", false)):
			continue
		if not str(item.get("error", "")).is_empty():
			continue
		if not update_is_upgrade(str(item.get("latest_version", "")), _version_floor(item)):
			continue
		if not _has_hash(item):
			continue
		return item
	return null


func _ensure_dialog() -> void:
	if _dialog != null and is_instance_valid(_dialog):
		return
	_dialog = ConfirmationDialog.new()
	_dialog.size.x = 600
	_dialog.title = "Update Available"
	_dialog.ok_button_text = "Update"
	_dialog.get_ok_button().theme_type_variation = "FilledButton"
	_dialog.cancel_button_text = "Not now"
	_dialog.confirmed.connect(_on_accepted)
	_dialog.canceled.connect(_on_declined)
	get_tree().root.add_child(_dialog)


func _show_next() -> void:
	if _queue.is_empty():
		_busy = false
		status_changed.emit(_last_summary)
		return
	_pending = _queue.pop_front()
	var product := str(_pending.get("product", ""))
	var cur := str(_pending.get("current_version", ""))
	var latest := str(_pending.get("latest_version", ""))
	var body := prompt_body(product, latest, cur)
	if product == "launcher" and _launcher_includes_cli:
		body += "\nThis launcher update includes the latest blazium-cli."
	if product == "launcher" and _launcher_includes_crash_reporter:
		body += "\nThis launcher update includes the latest Blazium Crash Reporter."
	_ensure_dialog()
	_dialog.title = prompt_title(product)
	_dialog.ok_button_text = "Update"
	_dialog.dialog_text = body
	_dialog.dialog_autowrap = true
	_dialog.popup_centered()


func _on_declined() -> void:
	var product := str(_pending.get("product", ""))
	if not product.is_empty():
		_dismissed[product] = true
		_last_summary = "Skipped %s until next relaunch" % str(PRODUCT_LABELS.get(product, product))
		status_changed.emit(_last_summary)
		if product == "launcher":
			_queue = build_update_queue(_products, _dismissed)
	_pending = {}
	call_deferred("_show_next")


func _on_accepted() -> void:
	var product := str(_pending.get("product", ""))
	var latest := str(_pending.get("latest_version", ""))
	if not update_is_upgrade(latest, _version_floor(_pending)):
		_last_summary = "Refusing a downgrade"
		status_changed.emit(_last_summary)
		_pending = {}
		call_deferred("_show_next")
		return
	status_changed.emit("Updating %s…" % str(PRODUCT_LABELS.get(product, product)))
	var ok := false
	match product:
		"launcher":
			var blocked := packaged_update_block(install_dir(), OS.get_name())
			if blocked != "":
				_last_summary = blocked
				status_changed.emit(_last_summary)
				_dismissed["launcher"] = true
				_queue = build_update_queue(_products, _dismissed)
				_pending = {}
				call_deferred("_show_next")
				return
			# blazium-cli update apply --product launcher --current <version> --install-root <Games> --launch
			var r: Variant = await _run(PackedStringArray([
				"update", "apply", "--product", "launcher",
				"--current", launcher_version(),
				"--install-root", install_dir(),
				"--launch",
			]))
			ok = r != null
			if not ok:
				_last_summary = friendly_update_error(_last_error)
				status_changed.emit(_last_summary)
				_dismissed["launcher"] = true
				_queue = build_update_queue(_products, _dismissed)
				_pending = {}
				call_deferred("_show_next")
				return
			var waiting := update_quit_block(Installs.any_running(), Installs.install_in_progress())
			if waiting != "":
				_quit_when_idle = true
				_last_summary = waiting
				status_changed.emit(_last_summary)
				set_process(true)
				return
			_last_summary = "Launcher installer launched; quitting…"
			status_changed.emit(_last_summary)
			get_tree().quit()
			return
		"cli":
			var r: Variant = await _run(PackedStringArray(["update", "apply", "--product", "cli"]))
			ok = r != null
			if ok:
				_last_summary = "blazium-cli updated to %s" % latest
			else:
				_last_summary = friendly_update_error(_last_error)
		"crash_reporter":
			var r: Variant = await _run(PackedStringArray([
				"update", "apply", "--product", "crash_reporter",
				"--install-root", install_dir(),
			]))
			ok = r != null
			if ok:
				_last_summary = "Blazium Crash Reporter updated to %s" % latest
			else:
				_last_summary = friendly_update_error(_last_error)
		_:
			_last_summary = "Unknown product %s" % product
	status_changed.emit(_last_summary)
	_pending = {}
	call_deferred("_show_next")


func resolve_cli() -> String:
	return resolve_cli_in(install_dir(), OS.get_name())


func resolve_cli_in(exe_dir: String, os_name: String) -> String:
	# Only the launcher's own directory. PATH, BLAZIUM, and the parent folder are not trusted.
	var names: PackedStringArray = ["blazium-cli.exe"] if os_name == "Windows" else ["blazium-cli"]
	if exe_dir.is_empty():
		return ""
	for name in names:
		var direct := exe_dir.path_join(name)
		if FileAccess.file_exists(direct):
			return direct
		var nested := exe_dir.path_join("bin").path_join(name)
		if FileAccess.file_exists(nested):
			return nested
	return ""


func _run(args: PackedStringArray) -> Variant:
	_last_error = ""
	var bin := resolve_cli()
	if bin.is_empty():
		_last_error = "blazium-cli not found"
		return null
	var argv: PackedStringArray = ["--json"]
	argv.append_array(args)
	_exec_mutex.lock()
	_exec_done = false
	_exec_code = 1
	_exec_text = ""
	_exec_mutex.unlock()
	var thread := Thread.new()
	thread.start(_worker.bind(bin, argv))
	while true:
		_exec_mutex.lock()
		var done := _exec_done
		_exec_mutex.unlock()
		if done:
			break
		await get_tree().process_frame
	thread.wait_to_finish()
	_exec_mutex.lock()
	var code := _exec_code
	var text := _exec_text
	_exec_mutex.unlock()
	return _parse(text, code)


func _worker(bin: String, argv: PackedStringArray) -> void:
	var output: Array = []
	var code := OS.execute(bin, argv, output, true, false)
	var text := ""
	for line in output:
		if text.is_empty():
			text = str(line)
		else:
			text += "\n" + str(line)
	_exec_mutex.lock()
	_exec_code = code
	_exec_text = text
	_exec_done = true
	_exec_mutex.unlock()


func _parse(text: String, code: int) -> Variant:
	text = text.strip_edges()
	if text.is_empty():
		_last_error = "empty CLI output (exit %d)" % code
		return null
	var payload := _extract_last_json(text)
	if payload.is_empty():
		payload = text
	var data: Variant = null
	if payload.begins_with("{") or payload.begins_with("["):
		data = JSON.parse_string(payload)
	if data == null:
		_last_error = "failed to parse JSON: %s" % text.substr(0, 200)
		return null
	if typeof(data) == TYPE_DICTIONARY and data.has("error"):
		_last_error = str(data["error"])
		if code != 0:
			return null
	if code != 0 and (typeof(data) != TYPE_DICTIONARY or not data.get("ok", false)):
		if _last_error.is_empty():
			_last_error = "CLI exit %d" % code
		return null
	return data


func _extract_last_json(text: String) -> String:
	var last := ""
	var i := 0
	while i < text.length():
		var ch := text[i]
		if ch == "{" or ch == "[":
			var end := _json_end(text, i)
			if end >= i:
				last = text.substr(i, end - i + 1)
				i = end + 1
				continue
		i += 1
	return last


func _json_end(text: String, start: int) -> int:
	var open_ch := text[start]
	var close_ch := "}" if open_ch == "{" else "]"
	var depth := 0
	var in_str := false
	var escape := false
	for i in range(start, text.length()):
		var ch := text[i]
		if in_str:
			if escape:
				escape = false
			elif ch == "\\":
				escape = true
			elif ch == "\"":
				in_str = false
			continue
		if ch == "\"":
			in_str = true
			continue
		if ch == open_ch:
			depth += 1
		elif ch == close_ch:
			depth -= 1
			if depth == 0:
				return i
	return -1


func product_check_notes(products: Array) -> PackedStringArray:
	var notes := PackedStringArray()
	for item in products:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var name := str(item.get("product", ""))
		var label := str(PRODUCT_LABELS.get(name, name))
		var err := str(item.get("error", "")).strip_edges()
		if err != "":
			notes.append("Couldn't check %s: %s" % [label, err])
			continue
		if bool(item.get("update_available", false)) and not _has_hash(item):
			notes.append("Couldn't check %s: update skipped: catalog entry has no checksum" % label)
	return notes


func check_status_summary(products: Array, queue: Array) -> String:
	if queue.size() > 0:
		return "%d update(s) available" % queue.size()
	var notes := product_check_notes(products)
	if notes.size() > 0:
		return "\n".join(notes)
	return "All products up to date"


func friendly_update_error(raw: String) -> String:
	var text := raw.strip_edges()
	if text.is_empty() or text == "Update check skipped" or text.find("not found") >= 0:
		return "The update tool is not installed. Reinstall the launcher to check for updates."
	if text.begins_with("empty CLI"):
		return "The update tool returned nothing. Try again later."
	if text.begins_with("failed to parse JSON"):
		return "The update tool returned a response that could not be read. Try again later."
	if text.begins_with("CLI exit"):
		return "The update tool failed. Try again later."
	return text


func packaged_update_block(exe_dir: String, os_name: String) -> String:
	if os_name == "Windows":
		return ""
	var clean := exe_dir.replace("\\", "/")
	if clean == "/opt/blazium/games" or clean.begins_with("/opt/blazium/games/"):
		return "Update with your package manager"
	return ""


func update_quit_block(running: bool, installing: bool) -> String:
	if running or installing:
		return "A game is running or an install is in progress. The update will apply when that finishes."
	return ""


func _process(_delta: float) -> void:
	if not _quit_when_idle:
		set_process(false)
		return
	if update_quit_block(Installs.any_running(), Installs.install_in_progress()) != "":
		return
	_quit_when_idle = false
	get_tree().quit()
