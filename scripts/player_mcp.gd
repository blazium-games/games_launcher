extends Node
## Player tools only, localhost. Confirm before purchase, top-up, redeem, friend requests, sends, and invites.

const TOOLS := [
	["search", "Search the catalog", {"q": "string"}],
	["open_listing", "Open a game listing", {"game_uid": "string"}],
	["library", "List owned games", {}],
	["install", "Install an owned game", {"game_uid": "string", "channel": "string"}],
	["uninstall", "Uninstall a local copy", {"game_uid": "string"}],
	["launch", "Launch an owned installed game", {"game_uid": "string"}],
	["game_status", "Installed, running, or stopped", {"game_uid": "string"}],
	["quote", "Live purchase quote", {"game_uid": "string", "kind": "string", "amount_cents": "integer"}],
	["purchase", "Buy or donate with wallet balance after confirm", {"game_uid": "string", "kind": "string", "amount_cents": "integer"}],
	["top_up_link", "Open a live card Checkout link after confirm", {"amount_cents": "integer"}],
	["redeem", "Redeem a key after confirm", {"code": "string"}],
	["review", "Write a review for a game you own or played", {"game_uid": "string", "enjoyed": "boolean", "quality": "integer", "with_friends": "boolean", "text": "string"}],
	["bug_report", "Report a bug for a game you own or played", {"game_uid": "string", "message": "string"}],
	["friends", "List friends and requests", {}],
	["friends_playing", "What friends are playing", {}],
	["friend_request", "Send a friend request after confirm", {"username": "string"}],
	["open_friends", "Open the friends window", {}],
	["open_chat", "Open a friend or game chat tab", {"kind": "string", "target": "string"}],
	["send_message", "Send a chat message after confirm", {"target": "string", "text": "string"}],
	["invite", "Invite a friend to a game after confirm", {"username": "string", "game_uid": "string"}],
	["join_channel", "Join a game channel", {"game_uid": "string"}],
]


func _ready() -> void:
	call_deferred("_register")


func _register() -> void:
	if not Engine.has_singleton("JustAMCPRuntime"):
		return
	var runtime = Engine.get_singleton("JustAMCPRuntime")
	if not runtime.has_method("register_tool"):
		return
	for spec in TOOLS:
		var schema := {"type": "object", "properties": {}, "additionalProperties": false}
		for key in spec[2].keys():
			schema["properties"][key] = {"type": spec[2][key]}
		runtime.register_tool(spec[0], spec[1], schema, Callable(self, "_run").bind(spec[0]))


func tool_names() -> PackedStringArray:
	var names: PackedStringArray = []
	for spec in TOOLS:
		names.append(spec[0])
	return names


func _run(args: Dictionary, name: String) -> Dictionary:
	match name:
		"search":
			return Session.search_games(str(args.get("q", "")))
		"open_listing":
			Shell.show_listing(str(args.get("game_uid", "")), false)
			return {"ok": true}
		"library":
			return Session.library()
		"install":
			return Installs.install_file(str(args.get("game_uid", "")), Installs.pick_file(str(args.get("game_uid", "")), str(args.get("channel", ""))))
		"uninstall":
			Installs.uninstall(str(args.get("game_uid", "")))
			return {"ok": true, "status": Installs.status(str(args.get("game_uid", "")))}
		"launch":
			return Installs.launch(str(args.get("game_uid", "")))
		"game_status":
			return {"ok": true, "status": Installs.status(str(args.get("game_uid", "")))}
		"quote":
			return Session.quote(str(args.get("game_uid", "")), str(args.get("kind", "purchase")), int(args.get("amount_cents", 0)))
		"purchase":
			return Confirm.ask("purchase", "Buy this game?", "This spends wallet balance.", func ():
				var quoted := Session.quote(str(args.get("game_uid", "")), str(args.get("kind", "purchase")), int(args.get("amount_cents", 0)))
				Session.purchase(str(args.get("game_uid", "")), str(args.get("kind", "purchase")), int(args.get("amount_cents", 0)), int(quoted.get("total_cents", args.get("amount_cents", 0))), str(Time.get_unix_time_from_system()))
			)
		"top_up_link":
			return Confirm.ask("top_up", "Add funds?", "This opens the live Checkout page.", func ():
				var created := Session.create_top_up(int(args.get("amount_cents", 0)))
				var url := str(created.get("checkout_url", ""))
				if not url.is_empty():
					OS.shell_open(url)
				Shell.poll_top_up(str(created.get("top_up_uid", "")))
			)
		"redeem":
			return Confirm.ask("redeem", "Redeem this key?", str(args.get("code", "")), func ():
				Session.redeem(str(args.get("code", "")))
			)
		"review":
			return Session.write_review(str(args.get("game_uid", "")), bool(args.get("enjoyed", false)), int(args.get("quality", 0)), bool(args.get("with_friends", false)), str(args.get("text", "")))
		"bug_report":
			return Session.report_bug(str(args.get("game_uid", "")), str(args.get("message", "")))
		"friends":
			return Session.friends()
		"friends_playing":
			return Session.friends_playing()
		"friend_request":
			return Confirm.ask("friend", "Send friend request?", str(args.get("username", "")), func ():
				Session.send_friend_request(str(args.get("username", "")))
			)
		"open_friends":
			Shell.open_friends()
			return {"ok": true}
		"open_chat":
			if str(args.get("kind", "")) == "game":
				Shell.open_chat_game(str(args.get("target", "")))
			else:
				Shell.open_chat_friend(str(args.get("target", "")))
			return {"ok": true}
		"send_message":
			return Confirm.ask("send", "Send this message?", str(args.get("text", "")), func ():
				IrcClient.send_privmsg(str(args.get("target", "")), str(args.get("text", "")))
			)
		"invite":
			return Confirm.ask("invite", "Invite this friend?", str(args.get("username", "")), func ():
				IrcClient.send_invite(str(args.get("username", "")), str(args.get("game_uid", "")))
			)
		"join_channel":
			IrcClient.join_game(str(args.get("game_uid", "")))
			Shell.open_chat_game(str(args.get("game_uid", "")))
			return {"ok": true}
	return {"ok": false, "error": "unknown tool"}
