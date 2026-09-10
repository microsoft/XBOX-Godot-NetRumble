class_name PrivacyService
extends RefCounted

## Per-player communication privacy (XR-015).
##
## The communications *privilege* (PrivilegeService) says whether this account may chat
## at all. This service answers the other half of the question: whether it may chat with
## a particular player. Three platform sources feed that answer, and all three are
## consulted before anyone is put into a voice mesh:
##
##   avoid list  - people the player asked never to be matched with. Blocks voice and
##                 text both ways as far as this title is concerned.
##   mute list   - people the player muted at the platform level. Blocks incoming voice;
##                 text is left alone, because a platform mute is about audio.
##   permissions - communicate_using_voice / communicate_using_text, which fold in the
##                 target's own privacy settings, the pair's relationship and any
##                 enforcement action. Batched: one call per permission per roster.
##
## Verdicts are cached per XUID for the life of a session and re-used as the roster
## changes, so an eight-player lobby costs two service calls rather than sixteen.
##
## Like ActivityService and PrivilegeService, everything here fails *open* when the GDK
## is missing, the runtime has not initialized, or there is no XboxUser — the state of
## every desktop dev machine and every --pf-user test client. is_available() reports
## which of the two worlds the caller is in, so a console session can fail *closed* on a
## player it cannot identify while a desktop session stays untouched.

## Permission strings accepted by XboxPrivacy.check_permission_async.
const PERMISSION_VOICE := "communicate_using_voice"
const PERMISSION_TEXT := "communicate_using_text"

## XUID -> verdict dictionary. Cleared on sign-out and when the lists are refreshed.
var _verdicts: Dictionary = {}
## XUIDs on the platform mute list and avoid list, as sets.
var _muted: Dictionary = {}
var _avoided: Dictionary = {}
var _lists_loaded := false
var _cache_generation := 0


## Whether privacy answers are real on this machine. False on desktop, in a build
## without the GDK and for a custom-id test client, where every verdict is permissive.
func is_available(user: Variant) -> bool:
	return _gdk_ready() != null and user != null


## Verdict shape:
##   voice  - may the local player exchange voice with this XUID?
##   text   - may they exchange text?
##   forced - the platform decided this, so the player cannot lift it from inside the
##            title. Drives the roster's "restricted" state; a plain local mute is not
##            forced and stays toggleable.
##   reason - short player-facing explanation, empty when unrestricted.
static func _verdict(voice: bool, text: bool, forced: bool = false, reason: String = "") -> Dictionary:
	return {"voice": voice, "text": text, "forced": forced, "reason": reason}


static func allowed() -> Dictionary:
	return _verdict(true, true)


## Pulls the mute and avoid lists once per session. Cheap to call again — a refresh
## re-reads the lists and drops the per-XUID cache, which is what a new session wants.
func refresh_lists(user: Variant) -> bool:
	clear_cache()
	var generation := _cache_generation

	var privacy: Variant = _privacy()
	if privacy == null or user == null:
		return false

	var muted: Variant = await privacy.get_mute_list_async(user)
	if generation != _cache_generation:
		return false
	if muted == null or not muted.ok:
		push_warning("[Privacy] Could not read the mute list: %s" % _reason(muted))

	var avoided: Variant = await privacy.get_avoid_list_async(user)
	if generation != _cache_generation:
		return false
	if avoided == null or not avoided.ok:
		push_warning("[Privacy] Could not read the avoid list: %s" % _reason(avoided))

	_muted = _to_set(muted.data) if muted != null and muted.ok else {}
	_avoided = _to_set(avoided.data) if avoided != null and avoided.ok else {}
	_lists_loaded = true
	return true


## Verdicts for a roster, keyed by XUID. Only XUIDs with no cached answer cost a service
## call, and those are batched into one call per permission.
func evaluate(user: Variant, xuids: PackedStringArray) -> Dictionary:
	var verdicts: Dictionary = {}
	var privacy: Variant = _privacy()
	if privacy == null or user == null:
		for xuid in xuids:
			verdicts[xuid] = allowed()
		return verdicts

	if not _lists_loaded:
		if not await refresh_lists(user):
			return {}
	var generation := _cache_generation

	var pending := PackedStringArray()
	for xuid in xuids:
		var trimmed := String(xuid).strip_edges()
		if trimmed.is_empty() or verdicts.has(trimmed):
			continue
		if _verdicts.has(trimmed):
			verdicts[trimmed] = _verdicts[trimmed]
		elif not pending.has(trimmed):
			pending.append(trimmed)

	if not pending.is_empty():
		var voice := await _batch(privacy, user, PERMISSION_VOICE, pending)
		if generation != _cache_generation:
			return {}
		var text := await _batch(privacy, user, PERMISSION_TEXT, pending)
		if generation != _cache_generation:
			return {}
		for xuid in pending:
			var verdict := _verdict(
				bool(voice.get(xuid, true)),
				bool(text.get(xuid, false)),
				not bool(voice.get(xuid, true)) or not bool(text.get(xuid, false)),
				"Xbox privacy settings limit chat with this player.",
			)
			if voice.has(xuid) and text.has(xuid):
				_verdicts[xuid] = verdict
			verdicts[xuid] = verdict

	# The lists win over the permission answer: a player who muted or avoided someone
	# asked for that directly, and it is not something the title may soften.
	for xuid in verdicts:
		verdicts[xuid] = _apply_lists(String(xuid), verdicts[xuid])
	return verdicts


## The cached verdict for one XUID, permissive when it has never been evaluated.
func verdict_for(xuid: String) -> Dictionary:
	var trimmed := xuid.strip_edges()
	if trimmed.is_empty():
		return allowed()
	return _apply_lists(trimmed, _verdicts.get(trimmed, allowed()))


func clear_cache() -> void:
	_cache_generation += 1
	_verdicts.clear()
	_muted.clear()
	_avoided.clear()
	_lists_loaded = false


## Overlays the platform lists on a permission verdict. Kept separate from the service
## call so a cached verdict picks up a list refreshed after it was stored.
func _apply_lists(xuid: String, verdict: Dictionary) -> Dictionary:
	if _avoided.has(xuid):
		return _verdict(false, false, true, "You have added this player to your avoid list.")
	if _muted.has(xuid):
		return _verdict(false, bool(verdict.get("text", true)), true, "You have muted this player on Xbox.")
	return verdict


## A missing text answer does not authorize publishing or displaying text. The existing
## voice fallback is independent; evaluate() chooses each channel's missing-answer policy.
func _batch(privacy: Variant, user: Variant, permission: String, xuids: PackedStringArray) -> Dictionary:
	var allowed_by_xuid: Dictionary = {}
	var result: Variant = await privacy.batch_check_permission_async(user, permission, xuids)
	if result == null or not result.ok or not (result.data is Array):
		push_warning("[Privacy] Could not check %s: %s" % [permission, _reason(result)])
		return allowed_by_xuid

	var rows: Array = result.data
	for index in rows.size():
		if not (rows[index] is Dictionary):
			continue
		var row: Dictionary = rows[index]
		# The rows carry their own target_xuid; the request order is only the fallback
		# for a service that ever stops echoing it.
		var xuid := String(row.get("target_xuid", "")).strip_edges()
		if xuid.is_empty() and index < xuids.size():
			xuid = String(xuids[index])
		if xuid.is_empty():
			continue
		allowed_by_xuid[xuid] = bool(row.get("allowed", permission == PERMISSION_VOICE))
	return allowed_by_xuid


func _to_set(data: Variant) -> Dictionary:
	var xuid_set: Dictionary = {}
	if data == null:
		return xuid_set
	for entry in data:
		var xuid := String(entry).strip_edges()
		if not xuid.is_empty():
			xuid_set[xuid] = true
	return xuid_set


# --- Shared -----------------------------------------------------------------

func _privacy() -> Variant:
	var gdk: Variant = _gdk_ready()
	return gdk.privacy if gdk != null else null


func _gdk_ready() -> Variant:
	return PlatformAccess.gdk_ready()


func _reason(result: Variant) -> String:
	return PlatformAccess.reason(result)
