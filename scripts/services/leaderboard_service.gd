class_name LeaderboardService
extends RefCounted

## Global scores are live PlayFab data, not local match history. Keep query status
## alongside the entries so a service failure never reads as an empty leaderboard.
##
## GlobalScore is last-write-wins. Read the entity's published score before an eligible
## update so a restart cannot make a lower score look like a first score. The read and
## write share one per-entity gate; this is still not atomic against another device.

signal _score_write_finished()

const LEADERBOARD_NAME := "GlobalScore"
const TOP_ENTRY_COUNT := 10
const _CLIENT_ACCESS_BLOCKED := 0x89235472

var _best_scores: Dictionary[String, int] = {}
var _writes_in_flight: Dictionary[String, bool] = {}
var _submission_generation := 0


## Returns {ok, entries, message}; entries contain rank, display_name and an integer score.
func get_top_entries(user: Variant) -> Dictionary:
	if user == null:
		return failure("No PlayFab user is signed in.", "Sign in to view leaderboards.")

	var pf: Variant = _playfab()
	if pf == null or not pf.is_initialized() or pf.leaderboards == null:
		return failure("PlayFab Leaderboards is unavailable.", "Leaderboards are unavailable right now.")

	var result: Variant = await pf.leaderboards.get_leaderboard_async(
		user, LEADERBOARD_NAME, 1, TOP_ENTRY_COUNT, -1)
	if result == null or not result.ok:
		return failure(_reason(result))

	var data: Variant = result.data
	if not (data is Dictionary) or not (data.get("rankings") is Array):
		return failure("PlayFab returned an invalid leaderboard payload.")

	# One malformed row must not suppress the rest of the page, but a page that yields
	# nothing usable is a failure rather than an empty board.
	var rankings: Array = data["rankings"]
	var entries: Array[Dictionary] = []
	var malformed_rows := 0
	for i in mini(rankings.size(), TOP_ENTRY_COUNT):
		var raw_entry: Variant = rankings[i]
		if not (raw_entry is Dictionary):
			malformed_rows += 1
			push_warning("[Services] Skipping leaderboard row %d: expected a dictionary." % (i + 1))
			continue
		var entry: Dictionary = raw_entry
		var display_name_value: Variant = entry.get("display_name", "")
		if display_name_value == null:
			display_name_value = ""
		if not (entry.get("rank") is int) or not (display_name_value is String) \
				or not (entry.get("scores") is PackedStringArray) \
				or not (entry.get("entity") is Dictionary):
			malformed_rows += 1
			push_warning("[Services] Skipping leaderboard row %d: invalid fields." % (i + 1))
			continue

		var entity: Dictionary = entry["entity"]
		if not (entity.get("id") is String):
			malformed_rows += 1
			push_warning("[Services] Skipping leaderboard row %d: invalid entity id." % (i + 1))
			continue
		var entity_id: String = entity["id"]
		# The reference omits an entry whose entity is missing; an empty id is how that
		# arrives here, and it is not a malformed payload.
		if entity_id.is_empty():
			push_warning("[Services] Skipping a leaderboard entry without an entity.")
			continue

		var scores: PackedStringArray = entry["scores"]
		if not scores.is_empty() and not scores[0].is_valid_int():
			malformed_rows += 1
			push_warning("[Services] Skipping leaderboard row %d: non-integer score." % (i + 1))
			continue

		# Entity ids are not player names; an unpublished profile must stay anonymous.
		var display_name := String(display_name_value).strip_escapes().strip_edges()
		if display_name.is_empty() or display_name == entity_id:
			display_name = "Unknown"
		entries.append({
			"rank": int(entry["rank"]),
			"display_name": display_name,
			"score": int(scores[0]) if not scores.is_empty() else 0,
		})

	if entries.is_empty() and malformed_rows > 0:
		return failure("PlayFab returned no usable leaderboard entries.")
	return {"ok": true, "entries": entries, "message": ""}


## Shared with the facade so unavailable sessions and failed calls have the same shape.
static func failure(reason: String, message: String = "Failed to load leaderboard") -> Dictionary:
	push_warning("[Services] Leaderboard query failed: %s" % reason)
	return {"ok": false, "entries": [], "message": message}


## A known lower/equal score needs no round trip. Every candidate that could raise the
## known best reads the server first; a failed read must not become permission to overwrite.
func submit_score(user: Variant, score: int, account_current: Callable = Callable()) -> Dictionary:
	var generation := _submission_generation
	var entity_id := _entity_id(user)
	if entity_id.is_empty():
		return score_failure("A valid signed-in PlayFab entity is required.")

	while _writes_in_flight.has(entity_id) and generation == _submission_generation:
		await _score_write_finished
	if generation != _submission_generation or (account_current.is_valid() and not account_current.call()):
		return score_failure("The session ended while the score was queued; UpdateLeaderboardEntries was not called.")
	if _best_scores.has(entity_id) and score <= int(_best_scores[entity_id]):
		return _skip_score(score, int(_best_scores[entity_id]))

	var pf: Variant = _playfab()
	if pf == null or not pf.is_initialized() or pf.leaderboards == null:
		return score_failure("PlayFab Leaderboards is unavailable or not initialized.")
	var title_id := String(pf.get_title_id()).strip_edges()
	if title_id.is_empty():
		return score_failure("PlayFab has no initialized title; sign in before submitting a score.")

	# Serialize the read too: otherwise two first submissions can both read the same
	# old best, then race their writes despite each having passed its own comparison.
	_writes_in_flight[entity_id] = true
	var published: Dictionary = await _read_published_best(user, entity_id, pf)
	if generation != _submission_generation or (account_current.is_valid() and not account_current.call()) \
			or not pf.is_initialized() \
			or String(pf.get_title_id()).strip_edges().to_upper() != title_id.to_upper():
		return _finish_submission(entity_id,
			score_failure("The session or title changed while checking the published best; no update was started."))
	if not bool(published["ok"]):
		return _finish_submission(entity_id, published)

	if bool(published["found"]):
		var server_score := int(published["score"])
		# An older read must not lower a best this process already knows was accepted.
		if not _best_scores.has(entity_id) or server_score > int(_best_scores[entity_id]):
			_best_scores[entity_id] = server_score
	if _best_scores.has(entity_id) and score <= int(_best_scores[entity_id]):
		return _finish_submission(entity_id, _skip_score(score, int(_best_scores[entity_id])))

	var had_previous := _best_scores.has(entity_id)
	var previous_best := int(_best_scores.get(entity_id, 0))
	_best_scores[entity_id] = score
	var result: Variant = await pf.leaderboards.submit_score_async(user, LEADERBOARD_NAME, score)
	if result == null or not result.ok:
		if had_previous:
			_best_scores[entity_id] = previous_best
		else:
			_best_scores.erase(entity_id)

	return _finish_submission(entity_id, _submission_outcome(result, score, title_id))


## Only this entity's row can seed its guard. A successful empty page is an absent
## entry; an error or a non-empty page that omits this entity is not evidence of zero.
func _read_published_best(user: Variant, entity_id: String, pf: Variant) -> Dictionary:
	var key: Variant = user.entity_key
	# Normalize both sides the way the title comparison does: `_entity_id()` strips, so
	# comparing a raw id here would fail closed forever on a key with stray whitespace.
	if not (key is Dictionary) or not (key.get("type") is String) \
			or String(key["type"]).is_empty() \
			or String(key.get("id", "")).strip_edges() != entity_id:
		return _seed_failure("The signed-in entity key is invalid.")
	var entity_type: String = key["type"]

	var result: Variant = await pf.leaderboards.get_leaderboard_around_user_async(
		user, LEADERBOARD_NAME, 1, -1)
	if result == null or not result.ok:
		return _seed_failure("The leaderboard read failed.", result)
	var data: Variant = result.data
	if not (data is Dictionary) or not (data.get("rankings") is Array):
		return _seed_failure("The leaderboard returned an invalid page.", result)

	var rows: Array = data["rankings"]
	if rows.is_empty():
		return {"ok": true, "found": false}
	var found := false
	var highest := 0
	for value: Variant in rows:
		if not (value is Dictionary):
			continue
		var row: Dictionary = value
		var entity: Variant = row.get("entity")
		if not (entity is Dictionary) \
				or String(entity.get("id", "")).strip_edges() != entity_id \
				or entity.get("type") != entity_type:
			continue
		var scores: Variant = row.get("scores")
		if not (scores is PackedStringArray) or scores.size() != 1:
			return _seed_failure("This account's row does not contain one score.", result)

		var text := String(scores[0]).strip_edges()
		if not text.is_valid_int():
			return _seed_failure("The published score is not an integer.", result)
		# Never turn an unrepresentable published value into zero before comparing it.
		var digits := text.trim_prefix("-").trim_prefix("+").lstrip("0")
		var limit := "9223372036854775808" if text.begins_with("-") else "9223372036854775807"
		if digits.length() > limit.length() or (digits.length() == limit.length() and digits > limit):
			return _seed_failure("The published score is outside the supported integer range.", result)
		var stored_score := text.to_int()
		if not found or stored_score > highest:
			highest = stored_score
		found = true

	if found:
		return {"ok": true, "found": true, "score": highest}
	return _seed_failure("The non-empty around-user page did not contain this account; refusing to assume no score.", result)


## Refusing this upload is safer than lowering a published score we could not read.
## It is not a successful skip or an automatic retry; the next eligible call tries again.
func _seed_failure(reason: String, result: Variant = null) -> Dictionary:
	var message := "Score not uploaded: unable to establish your published %s best. %s" % [LEADERBOARD_NAME, reason]
	if result != null:
		message += "\nLeaderboard read HRESULT: 0x%08X; SDK code: \"%s\"\n%s" % [
			int(result.hresult) & 0xFFFFFFFF, String(result.code), _reason(result)]
	var outcome := score_failure(message)
	outcome["stage"] = "read_best"
	if result != null:
		outcome["read_hresult"] = int(result.hresult) & 0xFFFFFFFF
		outcome["read_code"] = String(result.code)
	return outcome


func _skip_score(score: int, best: int) -> Dictionary:
	return {
		"ok": true,
		"pending": false,
		"attempted": false,
		"skipped": true,
		"score": score,
		"best_score": best,
		"message": "Score %d is not higher than the known best %d. Upload skipped successfully; UpdateLeaderboardEntries was not called."
			% [score, best],
	}


## Every exit after taking the gate, including a failed seed, releases it and wakes waiters.
func _finish_submission(entity_id: String, outcome: Dictionary) -> Dictionary:
	_writes_in_flight.erase(entity_id)
	_score_write_finished.emit()
	return outcome


## Invalidates queued work and a seed still in flight, not an update already started.
## Owners observe the generation at continuation; the active gate is never cleared here.
func invalidate_pending_submissions() -> void:
	_submission_generation += 1
	# Wake queued callers now so they can observe the new generation and abort, instead
	# of waiting for an unrelated in-flight write to finish first.
	_score_write_finished.emit()


## No HRESULT is invented for a refusal before the addon call.
static func score_failure(message: String) -> Dictionary:
	push_warning("[Services] Leaderboard submission failed: %s" % message)
	return {"ok": false, "pending": false, "attempted": false, "skipped": false, "message": message}


func _submission_outcome(result: Variant, score: int, title_id: String) -> Dictionary:
	if result == null:
		var missing := score_failure("UpdateLeaderboardEntries was called on PlayFab title %s but returned no result. HRESULT unavailable." % title_id)
		missing["attempted"] = true
		missing["title_id"] = title_id
		return missing

	# HRESULT is signed and 32-bit in the SDK; preserve its exact bits for display.
	var hresult := int(result.hresult) & 0xFFFFFFFF
	var code := String(result.code)
	var message := ""
	if result.ok:
		message = "UpdateLeaderboardEntries accepted score %d for %s on PlayFab title %s."
		message = message % [score, LEADERBOARD_NAME, title_id]
	elif hresult == _CLIENT_ACCESS_BLOCKED:
		message = "PlayFab title %s: API Features policy blocks client access to UpdateLeaderboardEntries. In Game Manager > Title settings > API Features, enable client access to UpdateLeaderboardEntries. If the endpoint has no exposed control, request title-level API feature enablement from PlayFab support." % title_id
	else:
		message = "UpdateLeaderboardEntries failed for %s on PlayFab title %s." % [LEADERBOARD_NAME, title_id]
	message += "\nHRESULT: 0x%08X; SDK code: \"%s\"" % [hresult, code]
	if not result.ok:
		message += "\n" + _reason(result)
		push_warning("[Services] %s" % message)
	else:
		message += "\nRefresh after synchronization to observe the board."
		print("[Services] %s" % message)
	return {
		"ok": bool(result.ok),
		"pending": false,
		"attempted": true,
		"skipped": false,
		"score": score,
		"title_id": title_id,
		"hresult": hresult,
		"code": code,
		"message": message,
	}


func _entity_id(user: Variant) -> String:
	if user == null:
		return ""
	var key: Variant = user.entity_key
	if not (key is Dictionary) or not (key.get("id") is String):
		return ""
	return String(key["id"]).strip_edges()


func _playfab() -> Variant:
	return PlatformAccess.playfab()


func _reason(result: Variant) -> String:
	return PlatformAccess.reason(result)
