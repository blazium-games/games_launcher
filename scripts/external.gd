class_name External
extends RefCounted
## Opens a URL only when the scheme and host are ones the service is allowed to hand out.


static func open(url: String) -> bool:
	if not allowed(url):
		return false
	OS.shell_open(url)
	return true


static func allowed(url: String) -> bool:
	var text := url.strip_edges()
	if text.begins_with("blazium://") and text.length() < 2048 and not text.contains("\n"):
		return true
	if not text.begins_with("https://"):
		return false
	var host := _host(text)
	if host.is_empty() or host.contains("@") or host.begins_with("["):
		return false
	return host == "blazium.games" or host.ends_with(".blazium.games") or host == "blazium.app" or host.ends_with(".blazium.app") or host == "checkout.stripe.com"
}


static func _host(url: String) -> String:
	var rest := url.trim_prefix("https://")
	var host := rest.split("/")[0].split("?")[0].split("#")[0].to_lower()
	return host.split(":")[0]
