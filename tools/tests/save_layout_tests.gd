extends RefCounted

const Doubles := preload("res://tools/tests/doubles.gd")
const Store := preload("res://scripts/services/game_save_service.gd")


class InterruptedMigration extends Doubles.Saves:
	func _write_bytes(path: String, bytes: PackedByteArray) -> Error:
		if path.get_file() == "history.json.migrate":
			super._write_bytes(path, bytes.slice(0, bytes.size() / 2))
			return OK
		return super._write_bytes(path, bytes)


class ConsoleSaves extends Doubles.Saves:
	var root_reads := 0

	func _supports_root_migration() -> bool:
		return false

	func _read_bytes(path: String, label: String) -> Dictionary:
		if path.get_base_dir() == sdk.folder:
			root_reads += 1
			return result(Status.FAILED, null, "Virtual root does not support file queries.")
		return super._read_bytes(path, label)


func _record(value: Variant, sequence: int = 1) -> PackedByteArray:
	var payload := JSON.stringify(value)
	return JSON.stringify({"sequence": sequence, "payload": payload,
		"sha256": Store._digest(sequence, payload)}).to_utf8_buffer()


func _put(test: Node, path: String, bytes: PackedByteArray) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	test._check(file != null, "layout fixture opens")
	if file != null:
		file.store_buffer(bytes)
		file.close()


func run(test: Node) -> void:
	print("CASE: Files API child directory, no root query on console, guarded PC save migration")
	var user := Doubles.User.new("layout-owner")
	var root: String = test._folder()
	var child := root.path_join(Store.SAVE_DIRECTORY)
	test._check(DirAccess.remove_absolute(child) == OK, "layout starts without child")
	var console := ConsoleSaves.new()
	console.sdk.folder = root
	await _assert_ready(test, console, user)
	test._check(DirAccess.dir_exists_absolute(child), "single child created below SDK root")
	test._status(console.write_now(user, 1, "profile.json", {"musicVolume": 0.6}), Store.Status.OK, "console-like absolute write")
	test._check(console.read(user, 1, "profile.json").data == {"musicVolume": 0.6}, "console-like read back")
	test._check(console.root_reads == 0 and not FileAccess.file_exists(root.path_join("profile.json")),
		"console never probes or writes root-level slots")
	var reload := ConsoleSaves.new()
	reload.sdk.folder = root
	await _assert_ready(test, reload, user)
	test._check(reload.read(user, 1, "profile.json").data == {"musicVolume": 0.6}, "child data survives new service")

	root = test._folder()
	child = root.path_join(Store.SAVE_DIRECTORY)
	var originals := {
		"profile.json": _record({"musicVolume": 0.2}),
		"profile.json.alt": _record({"musicVolume": 0.7}, 2),
		"history.json": _record([test._row(44)]),
		"stats.json": _record({"kills": 19}),
	}
	for name: String in originals:
		_put(test, root.path_join(name), originals[name])
	var store := Doubles.Saves.new()
	store.sdk.folder = root
	await _assert_ready(test, store, user)
	test._check(store.read(user, 1, "profile.json").data == {"musicVolume": 0.7}, "migration chooses newer intact slot")
	test._check(store.read(user, 1, "history.json").data == JSON.parse_string(JSON.stringify([test._row(44)])), "migration preserves history")
	test._check(store.read(user, 1, "stats.json").data == {"kills": 19.0}, "migration preserves counters")
	test._check(FileAccess.get_file_as_bytes(child.path_join("profile.json")) == originals["profile.json.alt"],
		"migration retains original integrity sequence and bytes")
	for name: String in originals:
		test._check(FileAccess.get_file_as_bytes(root.path_join(name)) == originals[name], "migration leaves source untouched")
	test._status(store.write_now(user, 1, "profile.json", {"musicVolume": 0.9}), Store.Status.OK, "new layout continues ordinary saves")
	_put(test, root.path_join("profile.json.alt"), "{".to_utf8_buffer())
	store.reset()
	await _assert_ready(test, store, user)
	test._check(store.read(user, 1, "profile.json").data == {"musicVolume": 0.9}, "completed migration never reimports obsolete root data")

	root = test._folder()
	child = root.path_join(Store.SAVE_DIRECTORY)
	var source := _record({"musicVolume": 0.4})
	_put(test, root.path_join("profile.json"), source)
	_put(test, root.path_join("history.json"), _record([test._row(23)]))
	var interrupted := InterruptedMigration.new()
	interrupted.sdk.folder = root
	test._status(await interrupted.prepare(user, 1), Store.Status.FAILED, "interrupted copy denies readiness")
	test._check(not interrupted.is_bound(user, 1), "partial migration never binds")
	var established := FileAccess.get_file_as_bytes(child.path_join("profile.json"))
	var retry := Doubles.Saves.new()
	retry.sdk.folder = root
	await _assert_ready(test, retry, user)
	test._check(retry.read(user, 1, "profile.json").data == {"musicVolume": 0.4}, "retry retains completed profile")
	test._check(retry.read(user, 1, "history.json").data == JSON.parse_string(JSON.stringify([test._row(23)])), "retry completes interrupted history")
	test._check(FileAccess.get_file_as_bytes(root.path_join("profile.json")) == source, "retry leaves original unchanged")
	test._check(FileAccess.get_file_as_bytes(child.path_join("profile.json")) == established, "retry never overwrites completed destination")


func _assert_ready(test: Node, store: GameSaveService, user: Variant) -> void:
	test._status(await store.prepare(user, 1), Store.Status.OK, "layout preparation")
