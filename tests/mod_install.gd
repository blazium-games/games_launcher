extends SceneTree

func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var installs: Node = root.get_node("Installs")
	var parent_uid := "mod-install-parent"
	var mod_uid := "mod-install-mod"
	var parent := installs.game_dir(parent_uid)
	var mod_dir := installs.game_dir(mod_uid)
	DirAccess.make_dir_recursive_absolute(parent)
	var marker := FileAccess.open(parent.path_join("installed.path"), FileAccess.WRITE)
	marker.store_string(parent.path_join("game.exe"))
	marker.close()
	var keep := FileAccess.open(parent.path_join("keep.txt"), FileAccess.WRITE)
	keep.store_string("stay")
	keep.close()

	var target: String = installs._overlay_dir(parent_uid, "mods/my-mod")
	if target == "":
		push_error("install path was rejected")
		quit(1)
		return
	var zip_path := mod_dir.path_join("incoming.zip")
	DirAccess.make_dir_recursive_absolute(mod_dir)
	if not _write_zip(zip_path):
		push_error("could not write the zip")
		quit(1)
		return
	if not installs._extract_zip(zip_path, target):
		push_error("extract failed")
		quit(1)
		return
	if not FileAccess.file_exists(target.path_join("readme.txt")):
		push_error("named loader did not extract under the parent path")
		quit(1)
		return
	if FileAccess.file_exists(parent.path_join("escape.txt")) or FileAccess.file_exists(target.path_join("escape.txt")):
		push_error("zip entry escaped the install path")
		quit(1)
		return
	var note := FileAccess.open(installs._overlay_marker(mod_uid), FileAccess.WRITE)
	note.store_string(target)
	note.close()
	installs.uninstall(mod_uid)
	if DirAccess.dir_exists_absolute(target):
		push_error("uninstall left the mod directory")
		quit(1)
		return
	if not FileAccess.file_exists(parent.path_join("keep.txt")):
		push_error("uninstall removed the parent game")
		quit(1)
		return

	var plain := installs.game_dir("mod-install-plain")
	DirAccess.make_dir_recursive_absolute(plain)
	var stored: Dictionary = installs._store({
		"game_uid": "mod-install-plain",
		"dest": plain.path_join("pack.zip"),
		"overlay": false,
	}, {"code": 200, "body": "not-a-mod".to_utf8_buffer()})
	if not bool(stored.get("ok", false)):
		push_error("empty loader store failed")
		quit(1)
		return
	if not FileAccess.file_exists(plain.path_join("pack.zip")):
		push_error("empty loader did not keep the file in its own folder")
		quit(1)
		return
	if FileAccess.file_exists(parent.path_join("pack.zip")):
		push_error("empty loader wrote into the game folder")
		quit(1)
		return
	installs.uninstall("mod-install-plain")
	installs.uninstall(parent_uid)
	print("mod install ok")
	quit(0)


func _write_zip(path: String) -> bool:
	var packer := ZIPPacker.new()
	if packer.open(path) != OK:
		return false
	packer.start_file("readme.txt")
	packer.write_file("hello".to_utf8_buffer())
	packer.close_file()
	packer.start_file("../escape.txt")
	packer.write_file("bad".to_utf8_buffer())
	packer.close_file()
	packer.close()
	return true
