extends RefCounted

const Doubles := preload("res://tools/tests/doubles.gd")


class InterruptedSaves extends Doubles.Saves:
	var keep_bytes := -1
	var candidate_size := 0
	var corrupt_same_length := false

	func _write_bytes(path: String, bytes: PackedByteArray) -> Error:
		candidate_size = bytes.size()
		if corrupt_same_length:
			var altered := bytes.duplicate()
			altered[altered.size() / 2] ^= 1
			super._write_bytes(path, altered)
			return OK
		if keep_bytes >= 0:
			# Model a short/failed flush hidden by FileAccess's cached successful error.
			super._write_bytes(path, bytes.slice(0, keep_bytes))
			return OK
		return super._write_bytes(path, bytes)


func run(test: Node) -> void:
	await _interrupted_slots(test)
	await _windows_locks(test)
	await _process_crashes(test)
	await _record_validation(test)


func _open(test: Node, folder: String, user: Variant) -> GameSaveService:
	var store := Doubles.Saves.new()
	store.sdk.folder = folder
	test._status(await store.prepare(user, 1), GameSaveService.Status.OK, "review storage: prepare independent reader")
	return store


func _interrupted_slots(test: Node) -> void:
	print("CASE: every truncated candidate preserves the latest slot across independent reloads")
	var user := Doubles.User.new("integrity")
	for file_name: String in test.FILES:
		var folder: String = test._folder()
		var store := InterruptedSaves.new()
		store.sdk.folder = folder
		test._status(await store.prepare(user, 1), GameSaveService.Status.OK, "integrity owner ready")
		var old_value: Variant = _value(test, file_name, 1)
		test._status(store.write_now(user, 1, file_name, old_value), GameSaveService.Status.OK, "initial integrity commit")
		# Exercise both physical slots as the previous committed save.
		for round_index in 2:
			var active := file_name if round_index == 0 else file_name + GameSaveService.SLOT_SUFFIX
			var active_path := folder.path_join(active)
			var committed := FileAccess.get_file_as_bytes(active_path)
			var new_value: Variant = _value(test, file_name, round_index + 2)
			for length in store.candidate_size:
				store.keep_bytes = length
				var written := store.write_now(user, 1, file_name, new_value)
				test._status(written, GameSaveService.Status.FAILED, "truncated write at byte %d" % length)
				test._check(written.reason.contains("verify"), "hidden flush failure caught by reopened byte verification")
				test._check(FileAccess.get_file_as_bytes(active_path) == committed, "latest committed bytes never truncated or removed")
				var reader := await _open(test, folder, user)
				var read := reader.read(user, 1, file_name)
				test._status(read, GameSaveService.Status.OK, "recover intact slot after interrupted candidate")
				test._check(read.data == JSON.parse_string(JSON.stringify(old_value)), "fresh reader recovers exactly the previous committed payload")
			store.keep_bytes = -1
			store.corrupt_same_length = true
			test._status(store.write_now(user, 1, file_name, new_value), GameSaveService.Status.FAILED, "same-length corruption fails full byte verification")
			test._check(FileAccess.get_file_as_bytes(active_path) == committed, "same-length corruption leaves latest committed bytes intact")
			store.corrupt_same_length = false
			test._status(store.write_now(user, 1, file_name, new_value), GameSaveService.Status.OK, "Retry commits complete verified slot")
			test._check(FileAccess.get_file_as_bytes(active_path) == committed, "successful new commit still preserves previous slot")
			var reader := await _open(test, folder, user)
			test._check(reader.read(user, 1, file_name).data == JSON.parse_string(JSON.stringify(new_value)), "fresh reader selects newer complete slot")
			old_value = new_value
		var fresh := InterruptedSaves.new()
		var fresh_value: Variant = _value(test, file_name, 4)
		fresh.sdk.folder = test._folder()
		test._status(await fresh.prepare(user, 1), GameSaveService.Status.OK, "prepare first-write fault")
		fresh.keep_bytes = 0
		test._status(fresh.write_now(user, 1, file_name, fresh_value), GameSaveService.Status.FAILED, "first write detects hidden flush failure")
		fresh.keep_bytes = -1
		test._status(fresh.write_now(user, 1, file_name, fresh_value), GameSaveService.Status.OK, "same-owner first-write Retry repairs only its own incomplete candidate")


func _value(test: Node, file_name: String, number: int) -> Variant:
	match file_name:
		"profile.json":
			return {"musicVolume": number / 10.0}
		"history.json":
			return [test._row(number)]
		_:
			return {"kills": number}


func _windows_locks(test: Node) -> void:
	print("CASE: real Windows sharing and byte-range locks preserve committed save bytes")
	var user := Doubles.User.new("windows-lock")
	for fault: String in ["locked-target", "locked-current", "locked-candidate-delete", "locked-flush"]:
		var folder := ProjectSettings.globalize_path("res://test-data/" + fault)
		var store := await _open(test, folder, user)
		var before := FileAccess.get_file_as_bytes(folder.path_join("profile.json"))
		test._check(store.read(user, 1, "profile.json").data == {"musicVolume": 0.3}, "locked fixture has valid committed slot")
		var written := store.write_now(user, 1, "profile.json", {"musicVolume": 0.8})
		if fault in ["locked-current", "locked-candidate-delete"]:
			test._status(written, GameSaveService.Status.OK, "commit needs no delete sharing on current or candidate slot")
			test._check(store.read(user, 1, "profile.json").data == {"musicVolume": 0.8}, "alternate slot publishes verified new value")
		else:
			test._status(written, GameSaveService.Status.FAILED, "locked inactive slot fails explicitly")
			if fault == "locked-flush":
				test._check(written.reason.contains("verify"), "actual buffered write/fflush failure detected on reopen")
				test._check(FileAccess.get_file_as_bytes(folder.path_join("profile.json.alt")).is_empty(),
					"actual byte-range lock reproduces zero-byte candidate after cached fwrite success")
			var restarted := await _open(test, folder, user)
			test._check(restarted.read(user, 1, "profile.json").data == {"musicVolume": 0.3}, "failed locked write preserves previous value after reload")
		test._check(FileAccess.get_file_as_bytes(folder.path_join("profile.json")) == before, "Windows failure never deletes or replaces committed slot")


func _process_crashes(test: Node) -> void:
	print("CASE: separate killed Godot writers leave an intact committed or complete new slot")
	var user := Doubles.User.new("crash-reader")
	for mode: String in ["partial", "complete"]:
		var folder := ProjectSettings.globalize_path("res://test-data/crash-" + mode)
		var store := await _open(test, folder, user)
		var current := store.read(user, 1, "profile.json")
		test._status(current, GameSaveService.Status.OK, "reload after writer process termination")
		test._check(current.data == {"musicVolume": 0.3 if mode == "partial" else 0.8}, "interrupted process yields old or fully complete value")
		var original: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(folder.path_join("profile.json")))
		test._check(JSON.parse_string(original.payload) == {"musicVolume": 0.3}, "terminated writer preserved original committed file")


func _record_validation(test: Node) -> void:
	print("CASE: current integrity format rejects ambiguous/corrupt records without migration")
	var folder: String = test._folder()
	var user := Doubles.User.new("record")
	var store := await _open(test, folder, user)
	var raw := FileAccess.open(folder.path_join("profile.json"), FileAccess.WRITE)
	raw.store_string('{"musicVolume":0.7}')
	raw.close()
	test._status(store.read(user, 1, "profile.json"), GameSaveService.Status.FAILED, "bare payload is not imported as an integrity record")
	test._status(store.write_now(user, 1, "profile.json", {}), GameSaveService.Status.FAILED, "invalid existing store cannot be overwritten with defaults")
	test._json(folder, "profile.json", {"musicVolume": 0.7})
	test._check(store.read(user, 1, "profile.json").data == {"musicVolume": 0.7}, "current envelope retains explicit music 0.7")
	var record: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(folder.path_join("profile.json")))
	record.payload = '{"musicVolume":0.9}'
	record.sha256 = ("%d\n%s" % [int(record.sequence), record.payload]).sha256_text()
	raw = FileAccess.open(folder.path_join("profile.json.alt"), FileAccess.WRITE)
	raw.store_string(JSON.stringify(record))
	raw.close()
	test._status(store.read(user, 1, "profile.json"), GameSaveService.Status.FAILED, "conflicting same-sequence slots fail closed")
	test._status(store.write_now(user, 1, "profile.json", {}), GameSaveService.Status.FAILED, "conflicting records cannot be overwritten")
	test._check(not FileAccess.get_file_as_string("res://scripts/services/game_save_service.gd").contains("DirAccess.rename_absolute"),
		"storage never uses destructive Windows rename-overwrite")
