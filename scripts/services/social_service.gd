class_name SocialService
extends RefCounted

## The local player's Xbox friends, and which of them are in a joinable session
## (XR-070).
##
## Wraps the Social Manager half of godot_gdk's XboxSocial. The Social Manager is a
## tracked graph rather than a query API: a group is created once, the service keeps it
## up to date in the background, and reading it is a local call. That shape is kept
## here — `friends()` loads the group on the first call and re-reads it on every one
## after, so opening the friends list twice costs one service round trip, not two.
##
## Joinability is not part of the social graph. A friend is joinable when they have a
## multiplayer activity for *this title*, which is ActivityService's question; Services
## joins the two halves together. That is also what makes the answer trustworthy:
## activities are per-title, so a friend playing something else simply has none.
##
## Like the other platform services, everything here fails soft. Without the GDK
## extension, without an initialized runtime or without an XboxUser, the friends list is empty
## rather than an error, and the UI says there is nobody to join rather than looking
## broken.
##
## Addon SDK objects (XboxUser, XboxResult, XboxSocialGroup, XboxSocialUser) are held as
## Variant on purpose: the godot_gdk classes only exist when the native library loads,
## so naming them in type positions would break parsing on a machine without the
## extension.

## The loaded friends group, kept for the life of the session. Destroying it stops the
## Social Manager tracking those users, so it is held rather than rebuilt per call.
var _friends_group: Variant = null
## Guards the load, so two screens opening at once share one round trip instead of
## creating two groups for the same user.
var _loading := false
var _generation := 0
var _owner: Variant = null
signal _group_loaded()


## Whether a real friends list can be produced with this platform and user.
## This does not replace the facade's account/save readiness checks.
func is_available(user: Variant) -> bool:
	return _social() != null and user != null


## The local player's friends as `{xuid, gamertag, display_name}` dictionaries, sorted
## by gamertag. Empty whenever the platform cannot answer — see is_available().
func friends(user: Variant) -> Array[Dictionary]:
	var social: Variant = _social()
	if social == null or user == null:
		return []

	if not await _ensure_group(social, user):
		return []
	if user != _owner or _friends_group == null:
		return []

	var users: Variant = social.get_group_users(_friends_group)
	if users == null or not users.ok:
		push_warning("[Social] Reading the friends group failed: %s" % _reason(users))
		return []

	var result: Array[Dictionary] = []
	for social_user: Variant in users.data:
		if social_user == null:
			continue
		var xuid := String(social_user.get_xuid()).strip_edges()
		if xuid.is_empty():
			continue
		var gamertag := String(social_user.get_gamertag()).strip_edges()
		var display_name := String(social_user.get_display_name()).strip_edges()
		if gamertag.is_empty():
			gamertag = display_name if not display_name.is_empty() else xuid
		result.append({
			"xuid": xuid,
			"gamertag": gamertag,
			"display_name": display_name if not display_name.is_empty() else gamertag,
		})
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a["gamertag"]).naturalnocasecmp_to(String(b["gamertag"])) < 0)
	return result


## Drops the tracked group and releases this generation's waiters. An outstanding SDK
## call still owns its eventual result, not a replacement account's load claim.
func clear() -> void:
	_generation += 1
	_loading = false
	_owner = null
	var group: Variant = _friends_group
	_friends_group = null
	var social: Variant = _social()
	if social != null and group != null:
		social.destroy_social_group(group)
	_group_loaded.emit()


## Loads the friends group once. get_friends_async both creates the group and waits for
## its initial data, which is the whole reason this is awaited rather than read
## directly.
func _ensure_group(social: Variant, user: Variant) -> bool:
	if _owner != null and _owner != user:
		clear()
	_owner = user
	var generation := _generation
	if _friends_group != null:
		return true
	if _loading:
		await _group_loaded
		return generation == _generation and user == _owner and _friends_group != null
	_loading = true
	var result: Variant = await social.get_friends_async(user)
	if generation != _generation or user != _owner:
		if result != null and result.ok and result.data != null and result.data != _friends_group:
			social.destroy_social_group(result.data)
		return false
	_loading = false
	if result == null or not result.ok or result.data == null:
		push_warning("[Social] Loading the friends list failed: %s" % _reason(result))
		_group_loaded.emit()
		return false
	_friends_group = result.data
	_group_loaded.emit()
	return generation == _generation and user == _owner and _friends_group == result.data


func _social() -> Variant:
	var gdk: Variant = _gdk()
	if gdk == null or not gdk.is_initialized():
		return null
	return gdk.social


func _gdk() -> Variant:
	return PlatformAccess.gdk()


func _reason(result: Variant) -> String:
	return PlatformAccess.reason(result)
