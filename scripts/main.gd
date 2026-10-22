extends Control
## Player pages. A link opens a page; buying, topping up, and redeeming wait for confirm.

var _status: Label
var _body: VBoxContainer
var _poll: Timer
var _poll_uid: String = ""
var _polls: int = 0
var _after_pay: Dictionary = {}
var _install_uid: String = ""
var _game_update_timer: Timer


func _ready() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)
	var nav := HBoxContainer.new()
	root.add_child(nav)
	for item in [["Home", "home"], ["Library", "library"], ["Wallet", "wallet"], ["Friends", "friends"], ["Profile", "profile"]]:
		var button := Button.new()
		button.text = item[0]
		var page := str(item[1])
		button.pressed.connect(func () -> void:
			if page == "friends":
				Shell.open_friends()
			else:
				Shell.show_page(page)
		)
		nav.add_child(button)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(_status)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(scroll)
	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_body)
	_poll = Timer.new()
	_poll.wait_time = 3.0
	_poll.timeout.connect(_tick_top_up)
	add_child(_poll)
	Shell.navigate.connect(_show)
	Session.login_url_ready.connect(_on_login_url)
	Session.login_state_changed.connect(_on_login_state)
	IrcClient.status.connect(func (text: String) -> void:
		_status.text = text
	)
	Installs.progress.connect(_on_install_progress)
	Session.authenticated.connect(func () -> void:
		_show("home", {})
		_offer_game_updates()
	)
	if Shell.pending_page != "":
		_show(Shell.pending_page, Shell.pending_extra)
	elif Session.is_authenticated():
		_show("home", {})
	else:
		_show("login", {})
	if LauncherUpdates:
		LauncherUpdates.status_changed.connect(func (message: String) -> void:
			_status.text = message
		)
		LauncherUpdates.check_and_prompt(false)
	_game_update_timer = Timer.new()
	_game_update_timer.wait_time = 1800.0
	_game_update_timer.timeout.connect(_offer_game_updates)
	add_child(_game_update_timer)
	_game_update_timer.start()
	call_deferred("_offer_game_updates")


func _show(page: String, extra: Dictionary) -> void:
	_clear()
	match page:
		"notice":
			_status.text = str(extra.get("text", ""))
		"login":
			_login()
		"home":
			_home()
		"library":
			_library()
		"wallet":
			_wallet()
		"profile":
			_profile()
		"search":
			_search(str(extra.get("q", "")))
		"listing":
			_listing(str(extra.get("uid", "")), bool(extra.get("launch", false)))
		"user":
			_user(str(extra.get("username", "")))
		"install":
			_install(str(extra.get("uid", "")), str(extra.get("channel", "")))
		"install_prompt":
			_install_prompt(str(extra.get("uid", "")), str(extra.get("channel", "")))
		"checkout":
			_checkout(str(extra.get("uid", "")))
		"play":
			_play(str(extra.get("uid", "")))
		"review":
			_review(str(extra.get("uid", "")))
		"bug":
			_bug(str(extra.get("uid", "")))
		"redeem":
			_redeem(str(extra.get("code", "")))
		"topup":
			_watch_top_up(str(extra.get("uid", "")))
		_:
			_status.text = page


func _on_login_url(url: String) -> void:
	if url.is_empty():
		return
	_status.text = "Continue in the browser"
	_body.add_child(_line(url))
	_login_link_actions(url)


func _on_login_state(state: int, error: String) -> void:
	if state == 4:
		return
	var text := Session.login_failure_text(state, error)
	if text == "":
		text = Session.login_error
	_show("login", {})
	if text != "":
		_status.text = text


func _login() -> void:
	_status.text = Session.login_heading()
	if Session.login_error != "":
		_body.add_child(_line(Session.login_error))
	if Session.login_url != "":
		_body.add_child(_line(Session.login_url))
		_login_link_actions(Session.login_url)
	var button := Button.new()
	button.text = "Try again" if Session.login_error != "" else "Sign in"
	button.pressed.connect(func () -> void:
		Session.login_error = ""
		Session.start_login()
		_status.text = "Continue in the browser" if Session.login_url != "" else "Waiting for the browser"
	)
	_body.add_child(button)


func _login_link_actions(url: String) -> void:
	var row := HBoxContainer.new()
	var copy := Button.new()
	copy.text = "Copy link"
	copy.pressed.connect(func () -> void:
		DisplayServer.clipboard_set(url)
		_status.text = "Sign-in link copied"
	)
	var again := Button.new()
	again.text = "Open again"
	again.pressed.connect(func () -> void:
		if not External.open(url):
			_status.text = "No browser opened. Copy the link and open it yourself."
	)
	row.add_child(copy)
	row.add_child(again)
	_body.add_child(row)


func _home() -> void:
	if not Session.is_authenticated():
		_login()
		return
	_status.text = "Blazium Games"
	var shelves := [
		["featured", "Featured"],
		["new", "New"],
		["recently_updated", "Recently updated"],
		["made_with_blazium", "Made with Blazium"],
		["in_development", "In development"],
		["browser_playable", "Play in your browser"],
		["community", "From the community"],
		["tools_and_assets", "Tools, mods and assets"],
		["tonight", "Something for tonight"],
		["unheard_of", "Unheard of"],
	]
	for item in shelves:
		var shelf := Session.shelf(str(item[0]))
		var rows := _rows(shelf, ["games", "items"])
		if rows.is_empty():
			continue
		_heading(str(item[1]))
		for row in rows:
			if row is Dictionary:
				Session.remember_owner(str(row.get("uid", row.get("game_uid", ""))), str(row.get("username", "")))
				_game_row(row)


func _offer_game_updates() -> void:
	if _status == null or not Session.is_authenticated():
		return
	var count := Installs.pending_update_count()
	if count > 0:
		_status.text = "%d game update(s) available" % count


func _library() -> void:
	var count := 0
	if Session.is_authenticated():
		count = Installs.pending_update_count()
	_status.text = "Library" if count == 0 else ("%d game update(s) available" % count)
	Session.invalidate_library()
	var body := Session.library()
	var offline := Session.offline_notice()
	if offline != "":
		_status.text = offline
		_action("Retry", func () -> void:
			Session.invalidate_library()
			Shell.show_page("library")
		)
	if not Session.ok(body) and body.has("error"):
		_status.text = _err(body)
		_action("Retry", func () -> void:
			Session.invalidate_library()
			Shell.show_page("library")
		)
		return
	var seen := {}
	for row in _rows(body, ["library", "games"]):
		if row is Dictionary:
			seen[str(row.get("game_uid", ""))] = true
			_owned_row(row)
	if Session.library_is_live():
		var any := false
		for uid in Installs.installed_game_uids():
			if bool(seen.get(uid, false)):
				continue
			if not any:
				_heading("Installed, not owned")
				any = true
			_revoked_row(uid)


func _wallet() -> void:
	Session.load_payment_options()
	var body := Session.wallet()
	for row in Session.wallet_summary(body):
		_body.add_child(_line(row))
	_status.text = str(Session.wallet_summary(body)[0]) if Session.wallet_summary(body).size() > 0 else "Wallet"
	var amount := SpinBox.new()
	amount.min_value = Session.top_up_min_cents()
	amount.max_value = Session.top_up_max_cents()
	amount.step = 100
	amount.value = mini(maxi(1000, Session.top_up_min_cents()), Session.top_up_max_cents())
	_body.add_child(amount)
	var button := Button.new()
	button.text = "Add funds"
	button.pressed.connect(func () -> void:
		var cents := int(amount.value)
		if cents < Session.top_up_min_cents() or cents > Session.top_up_max_cents():
			_status.text = Session.top_up_refusal()
			return
		Confirm.ask("top_up", "Add funds?", Session.card_checkout_text(cents), func () -> void:
			_after_pay = {}
			var created := Session.create_top_up(cents)
			var url := str(created.get("checkout_url", ""))
			if url.is_empty():
				_status.text = _err(created)
				return
			External.open(url)
			_watch_top_up(str(created.get("top_up_uid", "")))
		)
	)
	_body.add_child(button)


func _profile() -> void:
	var name := str(Session.profile.get("username", ""))
	_status.text = name if name != "" else "Profile"
	for key in Session.profile.keys():
		if str(key).to_lower().find("jwt") >= 0 or str(key).to_lower().find("token") >= 0:
			continue
		_body.add_child(_line("%s: %s" % [key, Session.profile[key]]))
	var updates := Button.new()
	updates.text = "Check for updates"
	updates.pressed.connect(func () -> void:
		if LauncherUpdates:
			LauncherUpdates.check_and_prompt(true)
	)
	_body.add_child(updates)


func _search(query: String) -> void:
	var field := LineEdit.new()
	field.text = query
	field.placeholder_text = "Search"
	_body.add_child(field)
	var button := Button.new()
	button.text = "Search"
	button.pressed.connect(func () -> void:
		Shell.show_search(field.text)
	)
	_body.add_child(button)
	var body := Session.search_games(query)
	_status.text = "Search"
	for row in _rows(body, ["games", "items", "results"]):
		if row is Dictionary:
			_game_row(row)


func _listing(uid: String, launch_if_owned: bool) -> void:
	var snap := Session.listing(uid)
	var body: Dictionary = snap.get("overview", {})
	Session.remember_owner(uid, str(_field(body, ["username", "developer"])))
	var name := str(_field(body, ["name"]))
	if name.is_empty():
		name = uid
	_status.text = name
	var summary := str(_field(body, ["summary", "description", "tagline"]))
	if summary != "":
		_body.add_child(_line(summary))
	_body.add_child(_line("Price %s" % _money(_int_field(body, ["price_cents"]))))
	_editions(body)
	_changelog(uid, body, snap.get("changelog", {}))
	if bool(snap.get("owned", false)):
		_status.text = "%s — in your library" % name
		if launch_if_owned and Installs.is_installed(uid):
			Installs.launch(uid)
		_action("Play", func () -> void:
			Shell.show_play_card(uid)
		)
		_action("Chat", func () -> void:
			Shell.open_chat_game(uid)
		)
	else:
		_action("Buy", func () -> void:
			Shell.show_checkout(uid)
		)
	if bool(snap.get("may_write", false)):
		_action("Review", func () -> void:
			Shell.show_review(uid)
		)
		_action("Report a bug", func () -> void:
			Shell.show_bug(uid)
		)


func _user(username: String) -> void:
	var body := Session.public_user(username)
	_status.text = username
	for key in body.keys():
		if key != "jwt":
			_body.add_child(_line("%s: %s" % [key, body[key]]))


func _install(uid: String, channel: String) -> void:
	_status.text = "Installing"
	_install_uid = uid
	if not Session.owns(uid):
		_status.text = "Buy this game before installing"
		_action("Buy", func () -> void:
			Shell.show_checkout(uid)
		)
		return
	var file_uid := Installs.pick_file(uid, channel)
	if file_uid.is_empty():
		var listing := Session.files(uid)
		_status.text = Installs.channel_missing_text(channel, listing.get("files", []), Installs.os_name())
		return
	var result: Dictionary = await Installs.install_file_with_progress(uid, file_uid)
	if result.has("error"):
		_status.text = _err(result)
	else:
		_status.text = str(result.get("status", "Install failed"))


func _install_prompt(uid: String, channel: String) -> void:
	var title := Session.display_name(Session.game_title(uid), uid)
	var chosen := channel.strip_edges().to_lower()
	if chosen == "":
		chosen = "stable"
	_status.text = "Install %s (%s)?" % [title, chosen]
	_body.add_child(_line("This downloads %s on the %s channel." % [title, chosen]))
	_action("Install", func () -> void:
		Shell.install_game(uid, channel)
	)


func _on_install_progress(game_uid: String, received: int, total: int) -> void:
	if game_uid != _install_uid:
		return
	if total > 0:
		_status.text = "Downloading %s / %s" % [_bytes(received), _bytes(total)]
	else:
		_status.text = "Downloading %s" % _bytes(received)


func _checkout(uid: String) -> void:
	_status.text = "Checkout"
	_pay_panel(uid)


func _play(uid: String) -> void:
	_status.text = "Play"
	if Session.owns(uid):
		_body.add_child(_line("Status: %s" % Installs.status(uid)))
		var offer := Installs.offer_for(uid)
		if not offer.is_empty():
			_action("Update", func () -> void:
				Shell.install_game(uid, str(offer.get("channel", "stable")))
			)
		_action("Install", func () -> void:
			Shell.install_game(uid, "")
		)
		_action("Launch", func () -> void:
			var result := Installs.launch(uid)
			if result.has("error"):
				_status.text = _err(result)
			else:
				_status.text = str(result.get("status", ""))
		)
		_action("Chat", func () -> void:
			Shell.open_chat_game(uid)
		)
	else:
		_pay_panel(uid)


func _review(uid: String) -> void:
	_status.text = "Review"
	var enjoyed := CheckBox.new()
	enjoyed.text = "I enjoyed it"
	var friends := CheckBox.new()
	friends.text = "I would play with friends"
	var quality := SpinBox.new()
	quality.min_value = 1
	quality.max_value = 5
	quality.value = 5
	var text := TextEdit.new()
	text.placeholder_text = "Review"
	text.custom_minimum_size = Vector2(0, 120)
	_body.add_child(enjoyed)
	_body.add_child(friends)
	_body.add_child(quality)
	_body.add_child(text)
	_action("Publish review", func () -> void:
		var result := Session.write_review(uid, enjoyed.button_pressed, int(quality.value), friends.button_pressed, text.text)
		_status.text = "Review saved" if Session.ok(result) else _err(result)
	)


func _bug(uid: String) -> void:
	_status.text = "Bug report"
	var text := TextEdit.new()
	text.placeholder_text = "What happened?"
	text.custom_minimum_size = Vector2(0, 120)
	_body.add_child(text)
	_action("Send report", func () -> void:
		var result := Session.report_bug(uid, text.text)
		_status.text = "Report sent" if Session.ok(result) else _err(result)
	)


func _redeem(code: String) -> void:
	_status.text = "Redeem a key"
	var field := LineEdit.new()
	field.text = code
	field.placeholder_text = "Code"
	_body.add_child(field)
	_action("Redeem", func () -> void:
		var value := field.text.strip_edges()
		Confirm.ask("redeem", "Redeem this key?", value, func () -> void:
			var result := Session.redeem(value)
			_status.text = "Redeemed" if Session.ok(result) else _err(result)
		)
	)


func _watch_top_up(uid: String) -> void:
	_poll_uid = uid
	_polls = 0
	_status.text = "Waiting for the payment"
	if uid.is_empty():
		_status.text = "No payment to watch"
		return
	_poll.start()
	_tick_top_up()


func _tick_top_up() -> void:
	if _poll_uid.is_empty():
		_poll.stop()
		return
	_polls += 1
	var body := Session.top_up(_poll_uid)
	var state := str(body.get("status", ""))
	_status.text = "Payment %s" % state
	if state == "paid" and not _after_pay.is_empty() and not bool(_after_pay.get("bought", false)):
		var game := str(_after_pay.get("game", ""))
		if str(_after_pay.get("idem", "")).is_empty():
			_after_pay["idem"] = Session.purchase_key(game, str(_after_pay.get("kind", "purchase")), int(_after_pay.get("total", 0)))
		var result := Session.purchase(game, str(_after_pay.get("kind", "purchase")), int(_after_pay.get("amount", 0)), int(_after_pay.get("total", 0)), str(_after_pay.get("idem", "")))
		if Session.ok(result):
			_after_pay["bought"] = true
			Session.clear_purchase_key(game, str(_after_pay.get("kind", "purchase")), int(_after_pay.get("total", 0)))
		else:
			_status.text = _err(result)
			_poll.stop()
			_poll_uid = ""
			return
	var game_uid := str(_after_pay.get("game", ""))
	var bought := bool(_after_pay.get("bought", false))
	var settled := state == "paid" and (_after_pay.is_empty() or Session.owns(game_uid) or (str(_after_pay.get("kind", "")) == "donation" and bought))
	if Session.top_up_poll_action(_polls, settled) == "wait":
		_status.text = "Still waiting for payment"
		return
	if settled:
		_poll.stop()
		_poll_uid = ""
		if game_uid != "":
			Session.invalidate_library()
			Session.library()
		if game_uid != "" and Session.owns(game_uid):
			_after_pay = {}
			Shell.show_page("library")
		elif state == "paid":
			_after_pay = {}


func _pay_panel(uid: String) -> void:
	var body := Session.overview(uid)
	if not Session.can_show_purchase(body):
		_body.add_child(_line("Could not load this game."))
		return
	var price := _int_field(body, ["price_cents"])
	var donations := _bool_field(body, ["donations_enabled"])
	if price > 0:
		_quote_actions(uid, "purchase", 0, "Buy this game?", "This spends wallet balance.")
	elif not donations:
		_body.add_child(_line("This game is free."))
	if donations:
		var amount := SpinBox.new()
		amount.min_value = 100
		amount.max_value = 50000
		amount.step = 100
		amount.value = 500
		_body.add_child(amount)
		_action("Quote donation", func () -> void:
			_quote_actions(uid, "donation", int(amount.value), "Donate?", "This spends wallet balance and is not refundable.")
		)


func _quote_actions(uid: String, kind: String, amount: int, title: String, detail: String) -> void:
	var quoted := Session.quote(uid, kind, amount)
	if quoted.has("error"):
		_body.add_child(_line(_err(quoted)))
		return
	var price := int(quoted.get("price_cents", amount))
	var total := int(quoted.get("total_cents", price))
	var key := Session.purchase_key(uid, kind, total)
	var scope := Session.purchase_scope(uid, kind, total)
	_body.add_child(_line("Total %s" % _money(total)))
	_action("Pay with balance", func () -> void:
		var named := "%s. %s" % [Session.display_name(Session.game_title(uid), uid), detail]
		Confirm.ask(kind, named, Session.purchase_confirm_text(total, named), func () -> void:
			if not Session.begin_purchase(scope):
				_status.text = "Payment already in progress"
				return
			var result := Session.purchase(uid, kind, price, total, key)
			Session.end_purchase(scope)
			if Session.ok(result):
				Session.clear_purchase_key(uid, kind, total)
				Session.invalidate_library()
				if kind == "purchase" and Session.owns(uid):
					Shell.show_page("library")
				else:
					_status.text = "Donation sent" if kind == "donation" else "Purchased"
			else:
				_status.text = _err(result)
		)
	)
	_action("Pay by card", func () -> void:
		Session.load_payment_options()
		var wallet := Session.wallet()
		var balance := int(wallet.get("available_cents", wallet.get("balance_cents", 0)))
		var cents := Session.card_top_up_cents(total, balance, Session.top_up_max_cents(), Session.top_up_min_cents())
		if cents < 0:
			_status.text = Session.top_up_refusal()
			return
		if cents == 0:
			_status.text = "Wallet balance already covers this total"
			return
		var detail := "%s %s" % [Session.purchase_confirm_text(total, "This opens the live Checkout page."), Session.card_checkout_text(cents)]
		Confirm.ask("top_up", title, detail, func () -> void:
			var created := Session.create_top_up(cents)
			var url := str(created.get("checkout_url", ""))
			if url.is_empty():
				_status.text = _err(created)
				return
			_after_pay = {"game": uid, "kind": kind, "amount": price, "total": total, "bought": false, "idem": key}
			External.open(url)
			_watch_top_up(str(created.get("top_up_uid", "")))
		)
	)


func _editions(body: Dictionary) -> void:
	var skus = _field(body, ["skus", "editions"])
	if not (skus is Array) or (skus as Array).is_empty():
		return
	_heading("Editions")
	for sku in skus:
		if sku is Dictionary:
			_body.add_child(_line("%s — %s" % [str(sku.get("name", "")), _money(int(sku.get("price_cents", 0)))]))


func _changelog(uid: String, body: Dictionary, log: Dictionary = {}) -> void:
	if log.is_empty():
		log = Session.changelog(uid)
	var rows = log.get("changelogs", [])
	if not (rows is Array) or (rows as Array).is_empty():
		var latest = _field(body, ["latest_changelog", "changelog"])
		if latest is Dictionary:
			rows = [latest]
		elif latest is Array:
			rows = latest
	if not (rows is Array) or (rows as Array).is_empty():
		return
	_heading("Changelog")
	for entry in rows:
		if entry is Dictionary:
			_body.add_child(_line("%s — %s" % [str(entry.get("title", "")), str(entry.get("description", entry.get("created_at", "")))]))


func _int_field(body: Dictionary, keys: Array) -> int:
	var value: Variant = _field(body, keys)
	if value == null or str(value).is_empty():
		return 0
	return int(value)


func _bool_field(body: Dictionary, keys: Array) -> bool:
	var value: Variant = _field(body, keys)
	if value == null:
		return false
	return bool(value)


func _field(body: Dictionary, keys: Array) -> Variant:
	return _find_field(body, keys)


func _find_field(node: Variant, keys: Array) -> Variant:
	if node is Dictionary:
		for key in keys:
			if node.has(key) and node[key] != null:
				return node[key]
		for nest in ["asset", "game", "overview", "data"]:
			if node.get(nest) is Dictionary:
				var inner: Variant = _find_field(node[nest], keys)
				if inner != null:
					return inner
	return null


func _money(cents: int) -> String:
	return Session.format_cents(cents)


func _bytes(n: int) -> String:
	if n < 1024:
		return "%s B" % n
	return "%s KB" % (n / 1024)


func _game_row(row: Dictionary) -> void:
	var uid := str(row.get("game_uid", row.get("uid", row.get("id", ""))))
	var name := str(row.get("name", uid))
	_action(name, func () -> void:
		Shell.show_listing(uid, false)
	)


func _owned_row(row: Dictionary) -> void:
	var uid := str(row.get("game_uid", ""))
	var name := str(row.get("name", uid))
	var line := HBoxContainer.new()
	line.add_child(_line("%s — %s" % [name, Installs.status(uid)]))
	var play := Button.new()
	play.text = "Play"
	play.pressed.connect(func () -> void:
		Shell.show_play_card(uid)
	)
	line.add_child(play)
	var offer := Installs.offer_for(uid)
	if not offer.is_empty():
		var update := Button.new()
		update.text = "Update"
		var update_channel := str(offer.get("channel", "stable"))
		update.pressed.connect(func () -> void:
			Shell.install_game(uid, update_channel)
		)
		line.add_child(update)
	var remove := Button.new()
	remove.text = "Uninstall"
	remove.pressed.connect(func () -> void:
		_confirm_uninstall(uid, name)
	)
	line.add_child(remove)
	_body.add_child(line)


func _confirm_uninstall(uid: String, name: String) -> void:
	if Installs.install_in_progress(uid):
		_status.text = "Wait for the install to finish"
		return
	var running := Installs.is_running(uid)
	Confirm.ask("uninstall", "Uninstall?", Installs.uninstall_prompt(name, running), func () -> void:
		var result := Installs.uninstall(uid, true)
		if not bool(result.get("ok", false)):
			_status.text = _err(result)
			return
		Shell.show_page("library")
	)


func _revoked_row(uid: String) -> void:
	var title := str(Installs.read_record(uid).get("title", ""))
	if title == "":
		title = Session.game_title(uid)
	var name := Session.display_name(title, uid)
	var line := HBoxContainer.new()
	line.add_child(_line("%s — installed, license revoked" % name))
	var remove := Button.new()
	remove.text = "Uninstall"
	remove.pressed.connect(func () -> void:
		_confirm_uninstall(uid, name)
	)
	line.add_child(remove)
	_body.add_child(line)


func _heading(text: String) -> void:
	var label := _line(text)
	label.add_theme_font_size_override("font_size", 18)
	_body.add_child(label)


func _action(text: String, action: Callable) -> void:
	var button := Button.new()
	button.text = text
	button.pressed.connect(action)
	_body.add_child(button)


func _line(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label


func _clear() -> void:
	for child in _body.get_children():
		_body.remove_child(child)
		child.free()


func _rows(body: Dictionary, keys: Array) -> Array:
	for key in keys:
		if body.get(key) is Array:
			return body[key]
	return []


func _err(result: Dictionary) -> String:
	var err = result.get("error", {})
	if err is Dictionary:
		return str(err.get("message", "Request failed"))
	return str(result.get("error", "Request failed"))
