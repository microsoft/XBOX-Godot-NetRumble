extends RefCounted

## Join failures say what actually went wrong. PlayFab has no "lobby full" error, so a
## code join reads the member counts the lobby search already returned and refuses a full
## lobby before any Lobby or Party join. A failed search is not reported as a search that
## found nothing, and the friend list's empty state is worded around joinable matches
## because full ones are filtered out of it.

const Doubles := preload("res://tools/tests/doubles.gd")
const CODE := "ABCDE"
const NO_MATCH := "No match found for code ABCDE."
const E_FAIL := 0x80004005
const LOBBY_NOT_JOINABLE := 0x89236227
const LOBBY_RATE_LIMITED := 0x89236216
const TOKEN_EXPIRED := 0x8923620D


## Shaped like PlayFabLobbySummary: the addon fills member_count and max_member_count
## from the service's currentMemberCount and maxMemberCount.
class Summary extends RefCounted:
	var connection_string := ""
	var member_count := 0
	var max_member_count := 0

	func _init(connection: String, members: int, capacity: int) -> void:
		connection_string = connection
		member_count = members
		max_member_count = capacity


class Lobby extends RefCounted:
	var connection_string := "joined-lobby"
	var search_properties := {}
	var properties := {}

	func _init(code: String) -> void:
		search_properties = {PartyService.JOIN_CODE_KEY: code, NRProtocol.LOBBY_KEY: NRProtocol.version_string()}
		properties = {PartyService.DESCRIPTOR_KEY: "test-descriptor"}

	func leave_async() -> Dictionary:
		return {"ok": true}


class LobbySDK extends RefCounted:
	signal released()
	var block_search := false
	var search_result: Variant = null
	var join_result: Variant = null
	var searches := 0
	var joins: Array[String] = []

	func find_lobbies_async(_user: Variant, _search: Variant) -> Variant:
		searches += 1
		if block_search:
			await released
		return search_result

	func join_lobby_async(_user: Variant, connection_string: String, _cfg: Variant) -> Variant:
		joins.append(connection_string)
		return join_result


class NetworkSDK extends RefCounted:
	var joins := 0
	var network := Doubles.Network.new()

	func join_network_async(_user: Variant, _descriptor: String, _cfg: Variant) -> Dictionary:
		joins += 1
		return {"ok": true, "data": network}


class JoinParty extends Doubles.SessionParty:
	var lobby_sdk := LobbySDK.new()
	var network_sdk := NetworkSDK.new()
	var searched_codes: Array[String] = []

	func _playfab() -> Variant:
		return {"multiplayer": lobby_sdk, "party": network_sdk}

	func _make_search_config(code: String) -> Variant:
		searched_codes.append(code)
		return {"code": code}


class ActivityInfo extends RefCounted:
	var connection_string := ""
	var current := 0
	var maximum := 0

	func _init(connection: String, current_players: int, max_players: int) -> void:
		connection_string = connection
		current = current_players
		maximum = max_players

	func get_connection_string() -> String:
		return connection_string

	func get_current_players() -> int:
		return current

	func get_max_players() -> int:
		return maximum

	func get_join_restriction() -> String:
		return "followed"


class ActivitySDK extends RefCounted:
	var cached := {}

	func get_activities_async(_user: Variant, _xuids: PackedStringArray) -> Dictionary:
		return {"ok": true}

	func get_cached_activity(xuid: String) -> Variant:
		return cached.get(xuid)


class Activity extends ActivityService:
	var sdk := ActivitySDK.new()

	func _multiplayer_activity() -> Variant:
		return sdk


func run(test: Node) -> void:
	await test._reset()
	test._select("join-failure", test._folder())
	test._check(await Services.sign_in(), "join-failure account ready")
	var user: Variant = Services.playfab_user()
	await _full_lobbies(test, user)
	await _lobbies_with_room(test, user)
	await _unknown_capacity(test, user)
	await _selected_result(test, user)
	await _search_outcomes(test, user)
	await _cancelled_search(test, user)
	await _dialog_reason(test)
	await _friend_list(test, user)


func _found(summaries: Array) -> Dictionary:
	return {"ok": true, "data": {"lobbies": summaries}}


func _error(hresult: int, code: String) -> Dictionary:
	return {"ok": false, "hresult": hresult, "code": code, "data": null,
		"message": "Injected SDK message 0x%08X" % (hresult & 0xFFFFFFFF)}


func _party(search: Variant, joined: Variant = null) -> JoinParty:
	var party := JoinParty.new(Doubles.Chat.new())
	party.lobby_sdk.search_result = search
	party.lobby_sdk.join_result = joined
	return party


func _no_join(party: JoinParty) -> bool:
	return party.lobby_sdk.joins.is_empty() and party.network_sdk.joins == 0 and party.attachments == 0


func _full_lobbies(test: Node, user: Variant) -> void:
	for counts: Array in [[4, 4], [5, 4], [2, 2]]:
		print("CASE: code join refuses a lobby the search reports full, before joining: %d/%d" % counts)
		var party := _party(_found([Summary.new("full-lobby", counts[0], counts[1])]))
		var result := await party.join(user, " abcde ")
		test._check(not result.ok and result.error == PartyService.JOIN_FAILED_FULL, "full lobby reports full: " + str(result))
		test._check(party.searched_codes == [CODE] and party.lobby_sdk.searches == 1 and _no_join(party),
			"full lobby is found by its normalized code and attempts no Lobby or Party join")


func _lobbies_with_room(test: Node, user: Variant) -> void:
	print("CASE: a lobby with room still goes through normal admission")
	var open := _party(_found([Summary.new("open-lobby", 3, 4)]), {"ok": true, "data": Lobby.new(CODE)})
	var joined := await open.join(user, CODE)
	test._check(joined.ok and joined.code == CODE, "3/4 lobby joins: " + str(joined))
	test._check(open.lobby_sdk.joins == ["open-lobby"] and open.network_sdk.joins == 1 and open.attachments == 1,
		"3/4 lobby joined the lobby and then the Party network")
	await open._chat.destroy_control()

	print("CASE: a lobby that fills after the search keeps the service's generic refusal")
	var filling := _party(_found([Summary.new("filling-lobby", 3, 4)]), _error(LOBBY_NOT_JOINABLE, "lobby_join_failed"))
	var refused := await filling.join(user, CODE)
	test._check(not refused.ok and refused.error == PartyService.JOIN_FAILED_NOT_JOINABLE,
		"stale below-capacity count is not relabelled full: " + str(refused))
	test._check(filling.lobby_sdk.joins == ["filling-lobby"] and filling.network_sdk.joins == 0, "below-capacity lobby was asked")


func _unknown_capacity(test: Node, user: Variant) -> void:
	print("CASE: missing or non-positive capacity is never read as full")
	for summary: Variant in [Summary.new("unknown-lobby", 0, 0), Summary.new("unknown-lobby", 3, 0),
			Summary.new("unknown-lobby", 4, -1), {"connection_string": "unknown-lobby"}]:
		var party := _party(_found([summary]), _error(E_FAIL, "lobby_join_failed"))
		var result := await party.join(user, CODE)
		test._check(result.error == PartyService.JOIN_FAILED_UNKNOWN and party.lobby_sdk.joins == ["unknown-lobby"],
			"unknown capacity is joined, not called full: " + str(result))


func _selected_result(test: Node, user: Variant) -> void:
	print("CASE: the capacity check reads the lobby it would join, not another search result")
	var skipped := _party(_found([null, Summary.new("", 4, 4), Summary.new("open-lobby", 1, 4), Summary.new("other-lobby", 4, 4)]),
		_error(LOBBY_NOT_JOINABLE, "lobby_join_failed"))
	var result := await skipped.join(user, CODE)
	test._check(result.error == PartyService.JOIN_FAILED_NOT_JOINABLE and skipped.lobby_sdk.joins == ["open-lobby"],
		"full results that are unusable or not selected do not block the join: " + str(result))
	var first_full := _party(_found([Summary.new("full-lobby", 4, 4), Summary.new("open-lobby", 1, 4)]))
	result = await first_full.join(user, CODE)
	test._check(result.error == PartyService.JOIN_FAILED_FULL and _no_join(first_full),
		"the selected full lobby is refused even with another result present")


func _search_outcomes(test: Node, user: Variant) -> void:
	print("CASE: a failed lobby search is not reported as a search that found nothing")
	var failures := [
		[_error(LOBBY_RATE_LIMITED, "find_lobbies_failed"), PartyService.JOIN_FAILED_BUSY],
		[_error(LOBBY_RATE_LIMITED - 0x100000000, "find_lobbies_failed"), PartyService.JOIN_FAILED_BUSY],
		[_error(TOKEN_EXPIRED, "find_lobbies_failed"), PartyService.JOIN_FAILED_SIGNED_OUT],
		[_error(E_FAIL, "find_lobbies_failed"), PartyService.JOIN_FAILED_SEARCH],
		[null, PartyService.JOIN_FAILED_SEARCH],
	]
	for failure: Array in failures:
		var party := _party(failure[0])
		var result := await party.join(user, CODE)
		test._check(not result.ok and result.error == failure[1], "search failure reads '%s': %s" % [failure[1], result])
		test._check(result.error != NO_MATCH and not String(result.error).contains("Injected") and _no_join(party),
			"failed search joins nothing, claims no empty result and shows no SDK text")
	print("CASE: a successful search with no usable lobby still reports no match")
	for search: Variant in [_found([]), _found([Summary.new("", 4, 4)]), {"ok": true, "data": null}]:
		var party := _party(search)
		var result := await party.join(user, CODE)
		test._check(result.error == NO_MATCH and _no_join(party), "empty search reports no match: " + str(result))


func _capture_join(party: PartyService, user: Variant, results: Array) -> void:
	results.append(await party.join(user, CODE))


func _cancelled_search(test: Node, user: Variant) -> void:
	for counts: Array in [[4, 4], [1, 4]]:
		print("CASE: a join cancelled during the search shows no late verdict: %d/%d" % counts)
		var party := _party(_found([Summary.new("late-lobby", counts[0], counts[1])]))
		party.lobby_sdk.block_search = true
		var results: Array = []
		_capture_join(party, user, results)
		test._check(results.is_empty() and party.lobby_sdk.searches == 1, "join is waiting on the search")
		party.cancel_pending_join()
		party.lobby_sdk.released.emit()
		await test._settle(results, 1)
		test._check(results.size() == 1 and results[0].error == "Join cancelled." and _no_join(party),
			"cancelled search neither reports full nor joins: " + str(results))


func _dialog_reason(test: Node) -> void:
	print("CASE: NetManager hands the full-lobby reason to the Join Failed dialog and keeps no session")
	var chat := Doubles.Chat.new()
	var party := JoinParty.new(chat)
	party.lobby_sdk.search_result = _found([Summary.new("full-lobby", 4, 4)])
	Services._party = party
	Services._chat = chat
	var request: JoinRequest = await NetManager.join_by_code(CODE).wait()
	var reason := NetManager.join_failure_reason(request)
	test._check(request.outcome == JoinRequest.Outcome.FAILED and reason == PartyService.JOIN_FAILED_FULL,
		"full-lobby join fails with the full message: " + reason)
	test._check(not NetManager.has_session() and _no_join(party), "no session, lobby or network after the refusal")
	Services._party = null
	Services._chat = null


func _friend_list(test: Node, user: Variant) -> void:
	print("CASE: friend list hides full matches and words its empty state around joinability")
	var activity := Activity.new()
	activity.sdk.cached = {
		"1001": ActivityInfo.new("full", 4, 4),
		"1002": ActivityInfo.new("open", 3, 4),
		"1003": ActivityInfo.new("uncounted", 2, 0),
	}
	var joinable := await activity.joinable_activities(user, PackedStringArray(["1001", "1002", "1003"]))
	test._check(not joinable.has("1001") and joinable.has("1002") and joinable.has("1003"),
		"full activity hidden, open and uncounted ones kept: " + str(joinable.keys()))
	activity.sdk.cached = {"1001": ActivityInfo.new("full", 4, 4)}
	joinable = await activity.joinable_activities(user, PackedStringArray(["1001"]))
	test._check(joinable.is_empty(), "friends in only full matches leave nothing to join")

	var list := NRFriendList.new()
	list._account_generation = Services.account_generation()
	var social: SocialService = Services._social
	Services._social = Doubles.Social.new()
	test._check(list._empty_reason() == "None of your friends have a joinable NetRumble match right now.",
		"empty state describes joinable matches: " + list._empty_reason())
	Services._social = null
	test._check(list._empty_reason() == "Joining a friend needs an Xbox sign-in on a console or PC GDK build.",
		"platform-unavailable explanation unchanged")
	Services._social = social
	list.free()
