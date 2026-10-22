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
	_install_safety(installs, session)
	_chat_and_wallet(session)
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
	DirAccess.remove_absolute(install.path_join("blazium-cli.exe"))
	DirAccess.remove_absolute(install.path_join("bin").path_join("blazium-cli"))
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


func _install_safety(installs: Node, session: Node) -> void:
	var uid := "12345678-1234-1234-1234-123456789abc"
	check(installs.install_dest(uid, "../../evil.exe") == installs._norm_path(installs.game_dir(uid).path_join("evil.exe")), "filename is reduced to a basename")
	check(installs.install_dest(uid, "..") == "", "dotdot filename is rejected")
	check(installs.install_dest(uid, "C:/Windows/notepad.exe") == installs._norm_path(installs.game_dir(uid).path_join("notepad.exe")), "drive path stays in the game folder")
	check(not bool(installs.parse_download_url("http://cdn.example/a").get("ok", false)), "plain http download is rejected")
	check(not bool(installs.parse_download_url("httpsfoo/a").get("ok", false)), "https prefix is not a scheme")
	var https: Dictionary = installs.parse_download_url("https://cdn.example/a/b")
	check(bool(https.get("ok", false)) and str(https.get("host", "")) == "cdn.example" and str(https.get("path", "")) == "/a/b", "https download target")
	check(installs.download_stalled(0, 0, 20000, 15000, 100000), "idle download stalls")
	check(not installs.download_stalled(0, 19000, 20000, 15000, 100000), "fresh bytes are not a stall")
	check(installs.download_stalled(0, 1000, 60000, 15000, 50000), "overall download deadline")
	check(not installs.file_in_listing({"files": []}, "nope"), "missing file is not in the listing")
	check(installs.file_in_listing({"files": [{"file_uid": "abc"}]}, "abc"), "listed file belongs to the game")
	installs._procs["running-game"] = OS.get_process_id()
	var running: Dictionary = installs.install_file("running-game", "file")
	check(not bool(running.get("ok", false)) and str(running.get("error", "")).find("running") >= 0, "install while running is refused")
	installs._procs.erase("running-game")
	installs._installing["busy-game"] = true
	var busy: Dictionary = installs.install_file("busy-game", "file")
	check(not bool(busy.get("ok", false)) and str(busy.get("error", "")).find("installing") >= 0, "concurrent install is refused")
	installs._installing.erase("busy-game")

	var game := "short-write"
	var dir: String = installs.game_dir(game)
	DirAccess.make_dir_recursive_absolute(dir)
	var dest := dir.path_join("game.bin")
	var old := FileAccess.open(dest, FileAccess.WRITE)
	old.store_string("old-build")
	old.close()
	var part := dest + ".part"
	var partial := FileAccess.open(part, FileAccess.WRITE)
	partial.store_string("x")
	partial.close()
	check(not installs._commit_part(part, dest, 10), "short write is not committed")
	check(FileAccess.get_file_as_string(dest) == "old-build", "short write keeps the previous build")
	check(not installs.is_installed(game), "short write is not marked installed")
	var body := "payload".to_utf8_buffer()
	var outside: String = str(installs.game_dir(game)).path_join("..").path_join("escaped.exe")
	var escaped: Dictionary = installs._store({
		"game_uid": game,
		"dest": outside,
		"checksum": "sha256:" + _sha(body),
		"file_uid": "f1",
		"channel": "stable",
	}, {"code": 200, "body": body})
	check(not bool(escaped.get("ok", false)) and not installs.is_installed(game), "escaped dest is not installed")
	check(not FileAccess.file_exists(outside), "escaped dest is not written")

	var zip_dir := dir.path_join("overlay")
	DirAccess.make_dir_recursive_absolute(zip_dir)
	var keep := FileAccess.open(zip_dir.path_join("keep.txt"), FileAccess.WRITE)
	keep.store_string("stay")
	keep.close()
	var zip_path := dir.path_join("mod.zip")
	var packer := ZIPPacker.new()
	check(packer.open(zip_path) == OK, "zip opens")
	packer.start_file("readme.txt")
	packer.write_file("hello".to_utf8_buffer())
	packer.close_file()
	packer.close()
	check(not installs._extract_zip(zip_path, zip_dir, 4), "oversize declared entry is refused")
	check(FileAccess.get_file_as_string(zip_dir.path_join("keep.txt")) == "stay", "failed extract leaves the folder")
	check(not FileAccess.file_exists(zip_dir.path_join("readme.txt")), "failed extract does not leave partial files")
	installs.uninstall(game)

	session.invalidate_library()
	session._scripted = {}
	var now := int(Time.get_unix_time_from_system())
	session.write_library_cache({"library": [{"game_uid": uid, "name": "Offline"}]}, now)
	check(session.owns(uid), "owned game launches from the cached library")
	var offline_dir: String = installs.game_dir(uid)
	DirAccess.make_dir_recursive_absolute(offline_dir)
	var marker := FileAccess.open(installs._marker(uid), FileAccess.WRITE)
	marker.store_string(offline_dir.path_join("missing.exe"))
	marker.close()
	var offline: Dictionary = installs.launch(uid)
	check(str(offline.get("error", "")) == "Installed file is missing", "offline launch is not blocked as unowned")
	session.note_live_library({"library": []})
	check(installs.revoked_game_uids().has(uid), "revoked install stays listed")
	var blocked: Dictionary = installs.launch(uid)
	check(str(blocked.get("error", "")) == "You do not own this game", "revoked install does not launch")
	installs.uninstall(uid)
	check(not installs.is_installed(uid), "revoked install can be uninstalled")
	check(not installs.revoked_game_uids().has(uid), "uninstalled revoke is gone")
	session.note_live_library({"library": [{"game_uid": uid}]})
	DirAccess.make_dir_recursive_absolute(offline_dir)
	var bad_marker := FileAccess.open(installs._marker(uid), FileAccess.WRITE)
	bad_marker.store_string(installs.root_dir().path_join("..").path_join("evil.exe"))
	bad_marker.close()
	var outside_launch: Dictionary = installs.launch(uid)
	check(str(outside_launch.get("error", "")).find("outside") >= 0, "launch refuses a marker outside the game folder")
	installs.uninstall(uid)


func _chat_and_wallet(session: Node) -> void:
	var uid := "12345678-1234-1234-1234-123456789abc"
	var other := "abcdefab-abcd-abcd-abcd-abcdefabcdef"
	var irc: Node = root.get_node("IrcClient")
	check(irc.privmsg_line("#a" + String.chr(13) + "\nJOIN #b", "hi") == "", "crlf target is rejected")
	check(not irc.target_ok("nick name"), "spaces are rejected in targets")
	check(irc.game_join_line("uid" + String.chr(13) + "\nQUIT") == "", "crlf game id is rejected")
	check(irc.game_join_line(uid) == "GAMEJOIN " + uid, "valid game join")
	var spoof: Dictionary = irc.parse_line(":nick!u@h PRIVMSG me :x JOIN #y 904 z")
	check(str(spoof.get("command", "")) == "PRIVMSG", "join text is not the command")
	check(not irc.server_numeric(spoof, "904"), "privmsg is not a numeric")
	check(irc.join_channel_from(":nick!u@h PRIVMSG me :hi JOIN #fake") == "", "join inside text is ignored")
	check(irc.join_channel_from(":nick!u@h JOIN #game-" + uid) == "#game-" + uid, "join command is a whole token")
	var numeric: Dictionary = irc.parse_line(":irc.blazium.online 903 me :ok")
	check(irc.server_numeric(numeric, "903"), "server numeric matches the command")
	irc.connected = false
	irc._cap_sent = true
	irc.nick = "me"
	irc._on_line(":nick!u@h PRIVMSG me : 903 ")
	check(not irc.connected, "chat text does not finish login")
	irc._on_line(":irc.blazium.online 903 me :ok")
	check(irc.connected, "server 903 finishes login")
	irc._active_joins.clear()
	irc._active_joins.append(uid)
	irc.note_disconnect()
	check(not irc.connected and not irc._cap_sent, "disconnect clears registration")
	check(irc._pending_joins.has(uid), "disconnect keeps joins to send again")
	check(irc._retry_msec > 0, "disconnect schedules a reconnect")
	check(irc.backoff_seconds(1) == 1.0 and irc.backoff_seconds(3) == 4.0, "reconnect backs off")
	irc._raw = PackedByteArray()
	check(irc.push_bytes(PackedByteArray([0xC3])).is_empty(), "split utf-8 waits for the rest")
	var lines: PackedStringArray = irc.push_bytes(PackedByteArray([0xA9, 10]))
	check(lines.size() == 1 and lines[0] == "é", "bytes are decoded per line")
	check(irc.play_invite_uid("#other", "PLAY:" + uid, true) == "", "play invite from another channel is ignored")
	check(irc.play_invite_uid("friend", "PLAY:" + uid, false) == "", "play invite from a stranger is ignored")
	check(irc.play_invite_uid("friend", "PLAY:" + uid, true) == uid, "play invite from a friend pm is kept")
	check(irc.play_invite_uid("friend", "PLAY:not-a-uid", true) == "", "play invite uid must be a uuid")
	var pages := {"game:" + uid: {}, "game:" + other: {}}
	check(irc.bind_joined_channel(pages, "#game-" + other) == "game:" + other, "join binds the matching game tab")
	check(str(pages["game:" + other].get("channel", "")) == "#game-" + other, "tab stores the joined channel")
	check(str(pages["game:" + uid].get("channel", "")) == "", "the other tab is left alone")
	check(not irc.can_open_tab(20) and irc.can_open_tab(19), "open tabs are capped")
	irc.connected = false
	irc._cap_sent = false
	irc._sasl_sent = false
	irc._tls = null
	irc._pending_joins.clear()
	irc._active_joins.clear()
	irc._retry_msec = 0
	irc._attempt = 0
	irc.set_process(false)

	var key := str(session.purchase_key("game", "donation", 500))
	check(key == str(session.purchase_key("game", "donation", 500)) and key != "", "confirm reuses one idempotency key")
	check(str(session.purchase_key("game", "donation", 700)) != key, "a different amount gets its own key")
	check(key.find("game") >= 0 and key.find("donation") >= 0 and key.find("500") >= 0, "key is scoped to the quote")
	check(session.card_top_up_cents(60000, 0, 50000) == -1, "top-up over the cap is refused")
	check(session.card_top_up_cents(60000, 20000, 50000) == -1, "top-up cannot leave balance above the cap")
	check(session.card_top_up_cents(40000, 10000, 50000) == 30000, "top-up covers the shortfall")
	check(not session.can_show_purchase({}), "empty overview is not a buy button")
	check(session.can_show_purchase({"name": "A", "price_cents": 100}), "a quote body can be purchased")
	check(session.purchase_confirm_text(1234, "pay") == "Total $12.34. pay", "confirm shows the quoted cents")
	var scope := str(session.purchase_scope("game", "donation", 500))
	check(session.begin_purchase(scope), "purchase can start")
	check(not session.begin_purchase(scope), "a second confirm waits")
	session.end_purchase(scope)

	session._host_log = []
	session._scripted = {
		"get_library": {"success": true, "data": {"library": []}},
		"get_game_overview": {"success": true, "data": {"name": "N", "username": "dev", "price_cents": 100}},
		"get_game_changelog": {"success": true, "data": {"changelogs": []}},
	}
	session.invalidate_library()
	var snap: Dictionary = session.listing(uid)
	var libraries := 0
	var shelves := 0
	var overviews := 0
	for call in session._host_log:
		if str(call) == "get_library":
			libraries += 1
		elif str(call) == "get_shelf":
			shelves += 1
		elif str(call) == "get_game_overview":
			overviews += 1
	check(libraries == 1 and shelves == 0 and overviews == 1, "listing does not fan out across shelves")
	check(str(snap.get("overview", {}).get("name", "")) == "N", "listing returns the overview")
	session._scripted = {}
	session._host_log = []
	session.invalidate_library()


func _sha(body: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(body)
	return ctx.finish().hex_encode()
