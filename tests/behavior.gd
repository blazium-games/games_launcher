extends SceneTree

var _failed := false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var updates: Node = root.get_node_or_null("LauncherUpdates")
	var router: Node = root.get_node_or_null("UriRouter")
	var installs: Node = root.get_node_or_null("Installs")
	var single: Node = root.get_node_or_null("SingleInstance")
	var session: Node = root.get_node_or_null("Session")
	var external: Node = root.get_node_or_null("External")
	if updates == null or router == null or installs == null or single == null or session == null or external == null:
		push_error("autoload missing")
		quit(1)
		return
	_launcher_updates(updates)
	_uri(router)
	_channels(installs)
	_checksums(installs)
	_commands(single, external)
	_session(session)
	if _failed:
		quit(1)
		return
	print("behavior ok")
	quit(0)


func check(cond: bool, message: String) -> void:
	if not cond:
		_failed = true
		push_error(message)


func _launcher_updates(updates: Node) -> void:
	var products: Array = [
		{"product": "launcher", "update_available": true, "latest_version": "0.2.0", "current_version": "0.1.0", "sha256": "ab".repeat(32)},
		{"product": "cli", "update_available": true, "latest_version": "0.2.0", "current_version": "0.1.0", "sha256": "ab".repeat(32)},
		{"product": "crash_reporter", "update_available": true, "latest_version": "0.2.0", "current_version": "0.1.0", "sha256": "ab".repeat(32)},
	]
	var queue: Array = updates.build_update_queue(products, {})
	check(queue.size() == 1 and str(queue[0].get("product", "")) == "launcher", "launcher update skips bundled tools")
	var dismissed := {"launcher": true}
	var skipped: Array = updates.build_update_queue(products, dismissed)
	check(skipped.is_empty(), "dismissed launcher does not queue bundled tools")
	var downgrade = updates._find_product_status([
		{"product": "cli", "update_available": true, "latest_version": "0.1.0", "current_version": "0.2.0"},
	], "cli")
	check(downgrade == null, "downgrade is not an update")
	var unsigned = updates._find_product_status([
		{"product": "cli", "update_available": true, "latest_version": "0.3.0", "current_version": "0.1.0"},
	], "cli")
	check(unsigned == null, "update without a hash is refused")
	check(not updates.update_is_upgrade("1.0.0", "1.2.0"), "older is not an upgrade")
	check(not updates.update_is_upgrade("1.2.0", "1.2.0"), "same version is not an upgrade")
	check(updates.update_is_upgrade("1.2.0", "1.0.0"), "newer is an upgrade")
	check(not updates.update_is_upgrade("1.2.0", ""), "missing floor is not an upgrade")
	check(updates._parse("", 1) == null, "empty cli output")
	var parsed = updates._parse("noise\n{\"ok\": true, \"products\": []}", 0)
	check(typeof(parsed) == TYPE_DICTIONARY and bool(parsed.get("ok", false)), "parse last json")
	check(updates._parse("{\"error\": \"nope\"}", 1) == null, "cli error")
	var root := OS.get_user_data_dir().path_join("cli-resolve-test")
	var parent := root.path_join("parent")
	var install := parent.path_join("Games")
	DirAccess.make_dir_recursive_absolute(install)
	var decoy := FileAccess.open(parent.path_join("blazium-cli.exe"), FileAccess.WRITE)
	decoy.store_string("nope")
	decoy.close()
	check(updates.resolve_cli_in(install, "Windows") == "", "parent cli must not be used")
	check(updates.resolve_cli_in(parent, "Linux") == "", "windows name is not a linux cli")
	var real := FileAccess.open(install.path_join("blazium-cli.exe"), FileAccess.WRITE)
	real.store_string("yes")
	real.close()
	check(updates.resolve_cli_in(install, "Windows") == install.path_join("blazium-cli.exe"), "install dir cli")
	var nested := install.path_join("bin")
	DirAccess.make_dir_recursive_absolute(nested)
	var linux := FileAccess.open(nested.path_join("blazium-cli"), FileAccess.WRITE)
	linux.store_string("yes")
	linux.close()
	check(updates.resolve_cli_in(install, "Linux") == nested.path_join("blazium-cli"), "bin cli")


func _uri(router: Node) -> void:
	var uid := "12345678-1234-1234-1234-123456789abc"
	var dev: Dictionary = router.parse("blazium://install/%s?channel=dev" % uid)
	check(bool(dev.get("ok", false)) and str(dev.get("channel", "")) == "dev", "dev channel")
	var custom: Dictionary = router.parse("blazium://install/%s?channel=Custom" % uid)
	check(bool(custom.get("ok", false)) and str(custom.get("channel", "")) == "custom", "custom channel")
	var beta: Dictionary = router.parse("blazium://install/%s?channel=beta" % uid)
	check(bool(beta.get("ok", false)) and str(beta.get("channel", "")) == "beta", "beta channel")
	var bad: Dictionary = router.parse("blazium://install/%s?channel=nightly" % uid)
	check(not bool(bad.get("ok", false)), "unknown channel")
	var plain: Dictionary = router.parse("blazium://install/%s" % uid)
	check(bool(plain.get("ok", false)) and str(plain.get("channel", "")) == "", "install without channel")
	var library: Dictionary = router.parse("blazium://library")
	check(bool(library.get("ok", false)) and str(library.get("host", "")) == "library", "library route")
	var broken: Dictionary = router.parse("https://example.com")
	check(not bool(broken.get("ok", false)), "non blazium link")


func _channels(installs: Node) -> void:
	var rows: Array = [
		{"file_uid": "beta-file", "os": "windows", "channel": "beta", "downloadable": true, "latest": true, "build_id": "b1"},
		{"file_uid": "stable-file", "os": "windows", "channel": "stable", "downloadable": true, "latest": true, "build_id": "b2"},
		{"file_uid": "dev-file", "os": "linux", "channel": "dev", "downloadable": true, "latest": true, "build_id": "b3"},
	]
	check(installs.resolve_channel("", "") == "stable", "empty channel defaults to stable")
	check(installs.resolve_channel("", "beta") == "beta", "player channel is kept")
	check(installs.resolve_channel("dev", "stable") == "dev", "explicit dev")
	check(installs.resolve_channel("nightly", "") == "", "unknown channel rejected")
	check(installs.pick_from_rows(rows, "stable", "windows") == "stable-file", "stable not beta")
	check(installs.pick_from_rows(rows, "beta", "windows") == "beta-file", "beta when asked")
	check(installs.pick_from_rows(rows, "dev", "windows") == "", "dev file is not windows")
	var legacy: Dictionary = installs.plan_update({}, {"channel": "", "files": rows}, "windows")
	check(str(legacy.get("file_uid", "")) == "stable-file", "legacy install updates on stable")
	var same: Dictionary = installs.plan_update({"file_uid": "stable-file", "channel": "stable"}, {"files": rows}, "windows")
	check(same.is_empty(), "current file is not an update")
	var beta_offer: Dictionary = installs.plan_update({"file_uid": "old", "channel": "beta", "build_id": "old"}, {"files": rows}, "windows")
	check(str(beta_offer.get("file_uid", "")) == "beta-file" and str(beta_offer.get("channel", "")) == "beta", "beta install stays on beta")
	check(str(beta_offer.get("build_id", "")) == "b1", "update carries the build id")


func _checksums(installs: Node) -> void:
	var game := "checksum-test"
	var dir: String = installs.game_dir(game)
	DirAccess.make_dir_recursive_absolute(dir)
	var dest := dir.path_join("game.bin")
	var body := "payload".to_utf8_buffer()
	var empty: Dictionary = installs._store({
		"game_uid": game,
		"dest": dest,
		"overlay": false,
	}, {"code": 200, "body": body})
	check(not bool(empty.get("ok", false)) and not FileAccess.file_exists(dest), "empty checksum fails closed")
	var bad: Dictionary = installs._store({
		"game_uid": game,
		"dest": dest,
		"overlay": false,
		"checksum": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
	}, {"code": 200, "body": body})
	check(not bool(bad.get("ok", false)) and not FileAccess.file_exists(dest), "checksum mismatch")
	var good: Dictionary = installs._store({
		"game_uid": game,
		"dest": dest,
		"overlay": false,
		"checksum": "sha256:" + _sha(body),
		"file_uid": "f1",
		"build_id": "b1",
		"channel": "stable",
	}, {"code": 200, "body": body})
	check(bool(good.get("ok", false)) and FileAccess.file_exists(dest), "matching checksum installs")
	var rec: Dictionary = installs.read_record(game)
	check(str(rec.get("file_uid", "")) == "f1", "record stores file_uid")
	check(str(rec.get("build_id", "")) == "b1", "record stores build_id")
	check(str(rec.get("channel", "")) == "stable", "record stores channel")
	installs.uninstall(game)


func _commands(single: Node, external: Node) -> void:
	var empty: PackedStringArray = PackedStringArray()
	check(single.command_message(empty) == "SHOW", "no args shows")
	var link: PackedStringArray = PackedStringArray(["--flag", "blazium://library"])
	check(single.command_message(link) == "blazium://library", "uri forwarded")
	var long := "blazium://" + "a".repeat(2048)
	var huge: PackedStringArray = PackedStringArray([long])
	check(single.command_message(huge) == "SHOW", "overlong uri ignored")
	check(single.accept_command("secret", "secret SHOW") == "SHOW", "matching token shows")
	check(single.accept_command("secret", "other SHOW") == "", "wrong token is ignored")
	check(single.accept_command("secret", "SHOW") == "", "bare command is ignored")
	check(external.allowed("https://blazium.games/login"), "service host opens")
	check(external.allowed("blazium://library"), "blazium scheme opens")
	check(not external.allowed("https://evil.example/login"), "other hosts stay closed")
	check(not external.allowed("http://blazium.games/login"), "plain http stays closed")


func _session(session: Node) -> void:
	var wrapped: Dictionary = session.payload({"success": true, "data": {"name": "a"}})
	check(str(wrapped.get("name", "")) == "a", "payload unwraps data")
	var raw: Dictionary = session.payload({"success": false, "error": "no"})
	check(bool(raw.get("success", true)) == false, "payload keeps failures")
	check(session.ok({"name": "a"}), "ok accepts a body")
	check(not session.ok({}), "ok rejects empty")
	check(not session.ok({"success": false}), "ok rejects failure")
	check(not session.ok({"error": "x"}), "ok rejects error")


func _sha(body: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(body)
	return ctx.finish().hex_encode()
