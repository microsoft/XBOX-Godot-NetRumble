extends Node

const Doubles := preload("res://tools/tests/doubles.gd")


class CrashSaves extends Doubles.Saves:
	var complete := false

	func _write_bytes(path: String, bytes: PackedByteArray) -> Error:
		var error := super._write_bytes(path, bytes if complete else bytes.slice(0, bytes.size() / 2))
		if error != OK:
			return error
		print("SAVE CRASH TEST: terminating writer after candidate bytes")
		var killed := OS.kill(OS.get_process_id())
		push_error("SAVE TEST FAIL: writer survived termination (%d)." % killed)
		return FAILED


func _ready() -> void:
	var mode := "complete" if OS.get_cmdline_user_args().has("complete") else "partial"
	var folder := ProjectSettings.globalize_path("res://test-data/crash-" + mode)
	var store := CrashSaves.new()
	store.complete = mode == "complete"
	store.sdk.folder = folder
	var user := Doubles.User.new("crash-writer")
	var ready := await store.prepare(user, 1)
	if ready.status == GameSaveService.Status.OK:
		store.write_now(user, 1, "profile.json", {"musicVolume": 0.8})
	push_error("SAVE TEST FAIL: crash writer did not reach termination.")
	get_tree().quit(1)
