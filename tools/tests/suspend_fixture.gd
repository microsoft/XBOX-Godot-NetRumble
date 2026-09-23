extends RefCounted

const Doubles := preload("res://tools/tests/doubles.gd")
const Review := preload("res://tools/tests/review_lifecycle.gd")
const FILES := ["profile.json", "history.json", "stats.json"]


class ObservedSaves extends Doubles.Saves:
	var watching := false
	var events: Array[String] = []
	var before_teardown := true
	var teardown_data: Dictionary = {}

	func write_now(user: Variant, generation: int, file_name: String, data: Variant) -> Dictionary:
		if watching:
			events.append("begin:" + file_name)
			before_teardown = before_teardown and NetManager.has_session() \
				and not NetManager._account_teardown_pending
		var result := super.write_now(user, generation, file_name, data)
		if watching:
			events.append("end:" + file_name)
		return result


class ObservedParty extends Doubles.SessionParty:
	var store: ObservedSaves

	func cancel_pending_join() -> void:
		if store.watching:
			store.events.append("teardown")
			if Services.is_account_ready():
				for file_name: String in FILES:
					store.teardown_data[file_name] = store.read(
						Services.xbox_user(), Services.account_generation(), file_name).data
		super.cancel_pending_join()


var store := ObservedSaves.new()
var identity := Doubles.Identity.new()
var chat := Doubles.Chat.new()
var party := ObservedParty.new(chat)
var activity := Review.Activity.new()
var app: Node
var menu: NRScreen
var folder := ""
var pending: Dictionary = {}
var committed: Dictionary = {}


func open(root: Node, path: String) -> bool:
	folder = path.path_join(GameSaveService.SAVE_DIRECTORY)
	identity.target = Doubles.User.new("suspend-fixture")
	store.sdk.folder = path
	party.store = store
	Services._identity = identity
	Services._game_saves = store
	Services._party = party
	Services._chat = chat
	Services._activity = activity
	if not await Services.sign_in():
		return false
	if not PlayerProfile.save_settings() or not Services.report_match_result(_payload(11)):
		return false
	store.failed_files.assign(["history.json"])
	if Services.report_match_result(_payload(22)):
		return false
	store.failed_files.clear()
	committed = read_all()
	if not NetManager.start_offline():
		return false
	NetManager.match_state = NRTypes.MatchState.RUNNING
	var tracker := Services.achievement_tracker()
	tracker.begin_match()
	tracker.note_kill()
	tracker.note_death()
	tracker.note_asteroid_destroyed()
	tracker.note_weapon_fired(1)
	tracker.note_buff_collected(1)
	app = preload("res://scenes/main.tscn").instantiate()
	app.set_script(Review.MainProbe)
	root.add_child(app)
	menu = ScreenManager.push(ScreenManager.GAME_MENU)
	menu._build_options_rows()
	var changed := false
	for row: Node in menu._menu.get_children():
		if row is NRSpinner and row.label_text == "Music Volume":
			row._step(1)
			changed = true
	pending = {
		"profile.json": JSON.parse_string(JSON.stringify(PlayerProfile.to_dict())),
		"history.json": JSON.parse_string(JSON.stringify(Services.get_match_history())),
		"stats.json": JSON.parse_string(JSON.stringify(tracker.to_dict())),
	}
	return changed and pending != committed


func arm() -> void:
	store.events.clear()
	store.teardown_data.clear()
	store.before_teardown = true
	store.watching = true


func sdk_calls() -> Array:
	return [identity.calls, store.sdk.calls,
		party.leaves, party.sdk.creates, party.attachments, party.advertisements,
		chat.sdk.calls.duplicate(), activity.sdk.calls.size(), activity.sdk.deletes.size(),
		Services._achievements.reports.size()]


func read_all() -> Dictionary:
	var data := {}
	for file_name: String in FILES:
		var result := store.read(Services.xbox_user(), Services.account_generation(), file_name)
		if result.status != GameSaveService.Status.OK:
			return {}
		data[file_name] = result.data
	return data


func memory_all() -> Dictionary:
	return JSON.parse_string(JSON.stringify({
		"profile.json": PlayerProfile.to_dict(),
		"history.json": Services._history,
		"stats.json": Services._achievement_tracker.to_dict(),
	}))


func disk_bytes() -> Dictionary:
	var data := {}
	for file_name: String in FILES:
		for suffix: String in ["", GameSaveService.SLOT_SUFFIX]:
			var name := file_name + suffix
			var path := folder.path_join(name)
			data[name] = FileAccess.get_file_as_bytes(path) if FileAccess.file_exists(path) else null
	return data


func _payload(score: int) -> Dictionary:
	return {"game_mode": "Deathmatch", "game_mode_type": 0, "score": score,
		"placement": 1, "player_count": 3, "human_count": 1}
