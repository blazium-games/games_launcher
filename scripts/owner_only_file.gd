extends RefCounted
## Credential files only the current account can open. Godot has no umask or
## fstat, so on Unix the file work runs in /bin/sh under umask 077: nothing is
## ever created group or world accessible, and a file is read only after its
## owner and mode are checked on the same descriptor the bytes come from.

const SHELL := "/bin/sh"
const MAX_BYTES := 65536
const TIMEOUT_MSEC := 5000
# Content reaches the child through its environment, which only the owner can
# read, never through argv. Writing to its stdin instead would kill the
# launcher with SIGPIPE if the child exited first.
const CONTENT_ENV := "BLAZIUM_OWNER_ONLY_CONTENT"

const _READ_SCRIPT := """exec 2>/dev/null </dev/null
umask 077
f=$1
d=$2
mkdir -p -- "$d" && chmod 700 -- "$d" && [ -O "$d" ] || exit 1
[ -L "$f" ] && exit 2
[ -f "$f" ] || exit 2
exec 3< "$f" || exit 2
[ -f /dev/fd/3 ] && [ -O /dev/fd/3 ] || exit 3
m=$(stat -L -c %a /dev/fd/3) || exit 3
case $m in *00) ;; *) exit 3 ;; esac
exec head -c 65536 <&3
"""

const _WRITE_SCRIPT := """exec 2>/dev/null </dev/null
c=$BLAZIUM_OWNER_ONLY_CONTENT
unset BLAZIUM_OWNER_ONLY_CONTENT
umask 077
f=$1
d=$2
mkdir -p -- "$d" && chmod 700 -- "$d" && [ -O "$d" ] || exit 1
[ -d "$f" ] && exit 1
t=$(mktemp "$f.XXXXXX") || exit 1
if printf '%s' "$c" > "$t" && mv -f -- "$t" "$f"; then
	exit 0
fi
rm -f -- "$t"
exit 1
"""

# Godot 4.3's stderr pipe closes fd 0 when it is released, so each one is
# kept for the life of the process.
static var _stderr_pipes: Array = []


static func read(path: String) -> String:
	if OS.get_name() == "Windows":
		if not FileAccess.file_exists(path):
			return ""
		return FileAccess.get_file_as_string(path)
	var target := _absolute(path)
	if target.is_empty():
		return ""
	var result := _run(_READ_SCRIPT, target)
	if int(result.get("code", -1)) != 0:
		return ""
	return str(result.get("out", ""))


static func write(path: String, content: String) -> bool:
	if OS.get_name() == "Windows":
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f == null:
			return false
		f.store_string(content)
		f.close()
		return true
	var target := _absolute(path)
	if target.is_empty() or content.is_empty() or content.find(String.chr(0)) >= 0 or content.to_utf8_buffer().size() > MAX_BYTES:
		return false
	OS.set_environment(CONTENT_ENV, content)
	var result := _run(_WRITE_SCRIPT, target)
	return int(result.get("code", -1)) == 0


static func _run(script: String, target: String) -> Dictionary:
	if not FileAccess.file_exists(SHELL):
		OS.unset_environment(CONTENT_ENV)
		return {}
	var proc := OS.execute_with_pipe(SHELL, PackedStringArray(["-c", script, "sh", target, target.get_base_dir()]))
	OS.unset_environment(CONTENT_ENV)
	if proc.is_empty():
		return {}
	_stderr_pipes.append(proc.get("stderr"))
	var stdio: FileAccess = proc["stdio"]
	var out := PackedByteArray()
	while out.size() <= MAX_BYTES:
		var chunk := stdio.get_buffer(4096)
		if chunk.is_empty():
			break
		out.append_array(chunk)
	stdio.close()
	return {"code": _wait(int(proc["pid"])), "out": out.get_string_from_utf8()}


static func _absolute(path: String) -> String:
	var target := ProjectSettings.globalize_path(path)
	if not target.begins_with("/"):
		return ""
	return target


static func _wait(pid: int) -> int:
	var waited := 0
	while OS.is_process_running(pid):
		if waited >= TIMEOUT_MSEC:
			OS.kill(pid)
			return -1
		OS.delay_msec(5)
		waited += 5
	return OS.get_process_exit_code(pid)
