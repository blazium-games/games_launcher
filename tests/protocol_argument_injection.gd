extends SceneTree
## Holds the project open long enough for autoload startup to finish, then records
## the remote-control token the launcher installed. The Python test supplies the
## command line and decides whether that result is safe.

var _frames := 0


func _init() -> void:
	process_frame.connect(_on_frame)


func _on_frame() -> void:
	_frames += 1
	if _frames < 3:
		return
	var report_path := OS.get_environment("PROBE_REPORT")
	var token := ""
	if ProjectSettings.has_setting("blazium/remote_control/token"):
		token = str(ProjectSettings.get_setting("blazium/remote_control/token"))
	if report_path != "":
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify({"token_setting": token}))
			file.close()
	quit(0)
