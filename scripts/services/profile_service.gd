class_name ProfileService
extends RefCounted

## Service-verified gamertags for the other players in a session (XR-047).
##
## The requirement is that player-visible identity comes from the platform rather than
## from whatever a peer says about itself. That is harder than it sounds here, because
## the two identity systems in play do not meet:
##
##   * PlayFab Party authenticates a *PlayFab entity id* for every peer
##     (PlayFabPartyPeer.get_peer_entity_key), and it is genuinely trustworthy — it
##     comes from the transport, not from the wire format the game controls.
##   * The Xbox profile service is keyed on *XUIDs*, and the only XUID the title has for
##     a remote player is the one that player put in its own roster entry
##     (PlayerState.xbox_user_id), which any modified client can fill in with somebody
##     else's.
##
## Feeding the claimed XUID straight into XboxProfile would therefore make things worse,
## not better: an impersonator would stop showing a made-up name and start showing the
## real, service-issued gamertag and gamerscore of the account they were pretending to
## be. So this service does not trust the claim — it *checks* it.
##
##   1. PlayFab's GetTitlePlayersFromXboxLiveIDs answers "which title player account
##      owns this XUID?" for a batch of XUIDs.
##   2. The entity id it returns is compared with the entity id Party authenticated for
##      that peer. They match only if the peer really is that Xbox account.
##   3. Only XUIDs that survive step 2 are looked up with XboxProfile.
##
## A peer claiming another player's XUID fails step 2, because PlayFab hands back the
## victim's entity id and Party hands back the impersonator's. A peer inventing a XUID
## fails it too: an account that never signed into this title has no title player
## account at all.
##
## Verification runs on every machine independently rather than on the host, so a
## dishonest host cannot inject names either. Nothing here depends on a peer's cooperation
## beyond the XUID claim, and a claim that cannot be checked simply produces no verified
## name.
##
## Fails soft everywhere, like the other platform services. Without the GDK, without
## PlayFab, on desktop and for --pf-user test clients there is no verification to do and
## every lookup returns an empty string, which callers render as the unverified name they
## already had.
##
## Addon SDK objects are held as Variant on purpose: the godot_gdk and godot_playfab
## classes only exist once their native libraries load, so naming them in type positions
## would break parsing on a machine without the extensions.

## Raised when a pass changes what any peer's verified name is, so the roster and the
## scoreboard can repaint. Verification is asynchronous and usually lands a moment after
## the player has already appeared in the list.
signal profiles_changed()

## Verified gamertags for the current session, keyed by Godot peer id. Only ever written
## for a peer whose XUID claim passed verification.
var _gamertag_by_peer: Dictionary = {}
## XUID -> the title player entity id PlayFab says owns it. Stable for the life of the
## title, so it survives roster churn and is never asked for twice.
var _entity_by_xuid: Dictionary = {}
## XUID -> gamertag from the Xbox profile service. Cached for the same reason.
var _gamertag_by_xuid: Dictionary = {}
## "<xuid>|<entity_id>" pairs already found not to match, so a peer with a bad claim
## costs one round trip rather than one per roster change for the rest of the match.
var _rejected: Dictionary = {}

## Serializes passes: a roster change arriving mid-pass queues one more rather than
## racing it, so eight players joining at once costs one round of lookups.
var _running := false
var _queued := false


## Whether verification can run at all. False on desktop, in a build without the
## extensions, and for a custom-id test client, where every lookup is empty.
func is_available(pf_user: Variant, xbox_user: Variant) -> bool:
	return _accounts() != null and _profile() != null and pf_user != null and xbox_user != null


## The verified gamertag for a peer, or an empty string when there is not one — which
## covers bots, local play, an unverified claim and every pass that has not finished yet.
func gamertag_for_peer(peer_id: int) -> String:
	return String(_gamertag_by_peer.get(peer_id, ""))


## Verifies and resolves a batch of claims, each `{peer_id, entity_id, xuid}` where
## `entity_id` is Party's authenticated key for that peer and `xuid` is what the peer
## claims to be. Claims missing either half are dropped: there is nothing to check.
func resolve(pf_user: Variant, xbox_user: Variant, claims: Array[Dictionary]) -> void:
	if _running:
		_queued = true
		return
	if not is_available(pf_user, xbox_user):
		return

	_running = true
	var changed := _prune(claims)
	var pending := _pending_claims(claims)

	if not pending.is_empty():
		if await _map_xuids_to_entities(pf_user, _unmapped_xuids(pending)):
			var verified := _verified_xuids(pending)
			if not verified.is_empty():
				await _load_gamertags(xbox_user, verified)
		if _apply(pending):
			changed = true

	_running = false
	if changed:
		profiles_changed.emit()
	if _queued:
		_queued = false
		await resolve(pf_user, xbox_user, claims)


## Forgets everything. Called when the session ends or the account changes: verified
## names belong to the session they were proven in, and peer ids are reused.
func clear_session() -> void:
	_gamertag_by_peer.clear()


## Forgets the cross-session caches as well. The XUID -> entity and XUID -> gamertag maps
## are not user-specific, but they were read with one account's credentials, so they go
## when that account does.
func clear() -> void:
	clear_session()
	_entity_by_xuid.clear()
	_gamertag_by_xuid.clear()
	_rejected.clear()


## Drops verified names for peers that are no longer in the batch. Returns true when
## anything was removed, so a player leaving repaints the roster.
func _prune(claims: Array[Dictionary]) -> bool:
	var live: Dictionary = {}
	for claim in claims:
		live[int(claim.get("peer_id", 0))] = true
	var changed := false
	for peer_id: int in _gamertag_by_peer.keys():
		if not live.has(peer_id):
			_gamertag_by_peer.erase(peer_id)
			changed = true
	return changed


## The claims worth working on: both halves present, and not already resolved or already
## known to be bogus.
func _pending_claims(claims: Array[Dictionary]) -> Array[Dictionary]:
	var pending: Array[Dictionary] = []
	for claim in claims:
		var xuid := String(claim.get("xuid", "")).strip_edges()
		var entity_id := String(claim.get("entity_id", "")).strip_edges()
		var peer_id := int(claim.get("peer_id", 0))
		if xuid.is_empty() or entity_id.is_empty() or peer_id == 0:
			continue
		if _rejected.has(_pair_key(xuid, entity_id)):
			continue
		if _gamertag_by_peer.has(peer_id):
			continue
		pending.append({"peer_id": peer_id, "entity_id": entity_id, "xuid": xuid})
	return pending


func _unmapped_xuids(pending: Array[Dictionary]) -> PackedStringArray:
	var xuids := PackedStringArray()
	for claim in pending:
		var xuid := String(claim["xuid"])
		if not _entity_by_xuid.has(xuid) and not xuids.has(xuid):
			xuids.append(xuid)
	return xuids


## The XUIDs in this batch whose claim checks out and whose gamertag is not cached yet.
func _verified_xuids(pending: Array[Dictionary]) -> PackedStringArray:
	var xuids := PackedStringArray()
	for claim in pending:
		var xuid := String(claim["xuid"])
		if not _is_verified(xuid, String(claim["entity_id"])):
			continue
		if not _gamertag_by_xuid.has(xuid) and not xuids.has(xuid):
			xuids.append(xuid)
	return xuids


## Step 2, and the whole point of this service: the claim holds only when PlayFab agrees
## that the claimed XUID belongs to the entity Party authenticated for that peer. A XUID
## with no title player account fails here as well, which is what catches invented ones.
func _is_verified(xuid: String, entity_id: String) -> bool:
	var owner := String(_entity_by_xuid.get(xuid, ""))
	if owner.is_empty() or owner != entity_id:
		_rejected[_pair_key(xuid, entity_id)] = true
		return false
	return true


## Step 1: ask PlayFab which title player account owns each XUID. Returns false when the
## call could not be made, so the caller skips the profile lookup rather than treating an
## empty answer as "nobody owns this".
func _map_xuids_to_entities(pf_user: Variant, xuids: PackedStringArray) -> bool:
	if xuids.is_empty():
		return true
	var accounts: Variant = _accounts()
	if accounts == null:
		return false

	var result: Variant = await accounts.get_title_players_from_xbox_live_ids_async(pf_user, {
		"xbox_live_ids": xuids,
	})
	if result == null or not result.ok:
		push_warning("[Profile] Resolving title players from XUIDs failed: %s" % _reason(result))
		return false

	var data: Dictionary = result.data if result.data != null else {}
	var accounts_by_xuid := _title_player_accounts(data)
	for xuid in xuids:
		# An absent entry means the XUID has no title player account, which is recorded
		# as an empty owner so the claim fails verification instead of being retried.
		_entity_by_xuid[xuid] = String(accounts_by_xuid.get(xuid, ""))
	return true


## Step 3: one batched Xbox profile lookup for the XUIDs that passed verification.
func _load_gamertags(xbox_user: Variant, xuids: PackedStringArray) -> void:
	var profile: Variant = _profile()
	if profile == null:
		return

	var result: Variant = await profile.get_profiles_async(xbox_user, xuids)
	if result == null or not result.ok or result.data == null:
		push_warning("[Profile] Xbox profile lookup failed: %s" % _reason(result))
		return

	for entry: Variant in result.data:
		if entry == null:
			continue
		var xuid := String(entry.get_xuid()).strip_edges()
		if xuid.is_empty():
			continue
		# Prefer the in-game display name the platform picked for this title, falling
		# back to the classic gamertag. Both are service-issued; neither is player text.
		var gamertag := String(entry.get_game_display_name()).strip_edges()
		if gamertag.is_empty():
			gamertag = String(entry.get_gamertag()).strip_edges()
		if not gamertag.is_empty():
			_gamertag_by_xuid[xuid] = gamertag


## Writes the verified names for this batch. Returns true when anything changed.
func _apply(pending: Array[Dictionary]) -> bool:
	var changed := false
	for claim in pending:
		var xuid := String(claim["xuid"])
		if not _is_verified(xuid, String(claim["entity_id"])):
			continue
		var gamertag := String(_gamertag_by_xuid.get(xuid, ""))
		if gamertag.is_empty():
			continue
		var peer_id := int(claim["peer_id"])
		if String(_gamertag_by_peer.get(peer_id, "")) == gamertag:
			continue
		_gamertag_by_peer[peer_id] = gamertag
		changed = true
	return changed


## PlayFab returns the XUID -> entity key mapping either as a dictionary or as a list of
## key/value entries depending on how the SDK marshals the response. Both are read here
## so the service does not hinge on which one this addon build produces.
func _title_player_accounts(data: Dictionary) -> Dictionary:
	var mapped: Dictionary = {}
	var raw: Variant = data.get("title_player_accounts", null)
	if raw is Dictionary:
		for xuid: Variant in (raw as Dictionary).keys():
			mapped[String(xuid)] = _entity_id(raw[xuid])
	elif raw is Array:
		for entry: Variant in raw as Array:
			if entry is Dictionary:
				var xuid := String((entry as Dictionary).get("key", ""))
				if not xuid.is_empty():
					mapped[xuid] = _entity_id((entry as Dictionary).get("value", null))
	return mapped


func _entity_id(value: Variant) -> String:
	if value is Dictionary:
		return String((value as Dictionary).get("id", "")).strip_edges()
	return String(value).strip_edges()


func _pair_key(xuid: String, entity_id: String) -> String:
	return "%s|%s" % [xuid, entity_id]


func _accounts() -> Variant:
	var pf: Variant = PlatformAccess.playfab()
	return pf.accounts if pf != null else null


func _profile() -> Variant:
	var gdk: Variant = PlatformAccess.gdk_ready()
	return gdk.profile if gdk != null else null


func _reason(result: Variant) -> String:
	return PlatformAccess.reason(result)
