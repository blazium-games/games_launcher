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
var _busy: bool = false
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


func install_dir() -> String:
	return OS.get_executable_path().get_base_dir()


func launcher_update_outstanding(products: Array) -> bool:
	return _find_product_status(products, "launcher") != null


func build_update_queue(products: Array, dismissed: Dictionary) -> Array:
	var launcher_outstanding := launcher_update_outstanding(products)
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
		_last_summary = _last_error
		if _last_summary.is_empty():
			_last_summary = "Update check skipped"
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
	_queue = build_update_queue(products, _dismissed)
	if _queue.is_empty():
		_last_summary = "All products up to date"
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
	_pending = {}
	call_deferred("_show_next")


func _on_accepted() -> void:
	var product := str(_pending.get("product", ""))
	var latest := str(_pending.get("latest_version", ""))
	status_changed.emit("Updating %s…" % str(PRODUCT_LABELS.get(product, product)))
	var ok := false
	match product:
		"launcher":
			# blazium-cli update apply --product launcher --current <version> --install-root <Games> --launch
			var r: Variant = await _run(PackedStringArray([
				"update", "apply", "--product", "launcher",
				"--current", launcher_version(),
				"--install-root", install_dir(),
				"--launch",
			]))
			ok = r != null
			if not ok:
				_last_summary = _last_error
				status_changed.emit(_last_summary)
				_pending = {}
				call_deferred("_show_next")
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
				_last_summary = _last_error
		"crash_reporter":
			var r: Variant = await _run(PackedStringArray([
				"update", "apply", "--product", "crash_reporter",
				"--install-root", install_dir(),
			]))
			ok = r != null
			if ok:
				_last_summary = "Blazium Crash Reporter updated to %s" % latest
			else:
				_last_summary = _last_error
		_:
			_last_summary = "Unknown product %s" % product
	status_changed.emit(_last_summary)
	_pending = {}
	call_deferred("_show_next")


func resolve_cli() -> String:
	var is_win := OS.get_name() == "Windows"
	var names: PackedStringArray = ["blazium-cli.exe"] if is_win else ["blazium-cli"]
	var candidates: PackedStringArray = []
	var blazium := OS.get_environment("BLAZIUM").strip_edges()
	if not blazium.is_empty():
		for name in names:
			candidates.append(blazium.path_join(name))
			candidates.append(blazium.path_join("bin").path_join(name))
	var exe_dir := OS.get_executable_path().get_base_dir()
	var parent := exe_dir.get_base_dir()
	for root in [parent, exe_dir]:
		if root.is_empty():
			continue
		for name in names:
			candidates.append(root.path_join(name))
			candidates.append(root.path_join("bin").path_join(name))
	if not is_win:
		candidates.append("/opt/blazium/bin/blazium-cli")
		candidates.append("/usr/bin/blazium-cli")
	for path in candidates:
		if FileAccess.file_exists(path):
			return path
	return "blazium-cli.exe" if is_win else "blazium-cli"


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
	var s := text.strip_edges()
	var end := -1
	for i in range(s.length() - 1, -1, -1):
		var ch := s[i]
		if ch == "}" or ch == "]":
			end = i
			break
	if end < 0:
		return ""
	var open_ch := "{" if s[end] == "}" else "["
	var close_ch := s[end]
	var depth := 0
	var in_str := false
	var escape := false
	for i in range(end, -1, -1):
		var ch := s[i]
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
		if ch == close_ch:
			depth += 1
		elif ch == open_ch:
			depth -= 1
			if depth == 0:
				return s.substr(i, end - i + 1)
	return ""
