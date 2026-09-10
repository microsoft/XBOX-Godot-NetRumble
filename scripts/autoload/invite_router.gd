extends Node

## Turns an accepted Xbox invite or a protocol launch into a join (XR-064 / XR-124).
##
## ActivityService raises the platform event and hands over a join request; this decides
## what that means for the player given where they currently are, and resolves the
## request into a reachable session. It lives in its own autoload because the decision
## needs both ScreenManager and NetManager, and neither should have to know about
## invites.
##
## Registered after ScreenManager in project.godot so both are up before the first
## activation event can be delivered.

## Emitted when an invite starts or stops waiting, so a screen that wants to say one is
## pending can keep up with it.
signal pending_invite_changed()

## How long a buffered activation stays redeemable. A cold launch has to survive the
## whole acquire-user flow, including system sign-in UI that waits on the player, so
## this is generous. It is not unbounded, though: an activation redeemed half an hour
## after it arrived drags the player into a match that ended long ago, which reads as
## the title acting on its own rather than on their behalf.
const PENDING_TTL_SECONDS := 300.0

## An activation that arrived before the title was ready to act on it, held until it is.
## A cold launch from an invite is the normal case, not an edge case: the activation
## fires while the player is still on the acquire-user screen.
##
## Held as the raw request — `{"connection_string", "xuid"}` — rather than a resolved
## connection string, because resolving an XUID needs a signed-in user, which is exactly
## what is missing at the moment a cold-launch activation arrives.
var _pending_request: Dictionary = {}
## When the buffered activation arrived, for PENDING_TTL_SECONDS.
var _pending_since_msec := 0
## Set while a join is being routed, so a second invite arriving mid-flight is buffered
## rather than tearing down the join it is racing.
var _joining := false


func _ready() -> void:
	if Services == null:
		return
	Services.sign_in_completed.connect(_on_sign_in_completed)
	var activity := Services.activity()
	if activity != null:
		activity.join_requested.connect(_on_join_requested)
	# Redeeming waits on the front end as well as on sign-in, so the stack has to be
	# watched too — see _ready_to_join().
	ScreenManager.screen_pushed.connect(_on_screen_changed)
	ScreenManager.screen_popped.connect(_on_screen_changed)


## Every activation is buffered first and redeemed second, even when it could be acted
## on straight away. Routing one directly from the platform callback means deciding, at
## the least predictable moment in the run, whether the title is in a fit state to
## join — and getting that wrong silently drops the invite.
##
## Buffered even mid-join. The claim on _joining covers an unbounded wait — the "leave
## the current match" prompt sits there until the player answers it — so discarding
## anything that arrives inside it throws away invites over a window the player
## controls. _redeem_pending() runs again once the join in flight settles, so the newer
## activation replaces the older rather than racing it.
func _on_join_requested(request: Dictionary) -> void:
	if request.is_empty():
		return
	_pending_request = request
	_pending_since_msec = Time.get_ticks_msec()
	pending_invite_changed.emit()
	_redeem_pending()


func _on_sign_in_completed(_success: bool) -> void:
	_redeem_pending()


func _on_screen_changed(_screen: NRScreen) -> void:
	_redeem_pending()


## True when a buffered activation has an identity to join with and a front end to come
## back to. Both halves matter, and the second one is easy to miss: sign_in_completed
## fires from inside Services.sign_in(), which the acquire-user screen is still
## awaiting, so acting on it puts a loading screen on top of a screen that is about to
## hand over. AcquireUserScreen._hand_off() then pops "itself" — really the join's
## loading screen — and the join is left running under a screen that never leaves.
func _ready_to_join() -> bool:
	if _pending_request.is_empty() or _joining:
		return false
	if Services == null or not Services.is_online():
		return false
	# Nothing to return to yet; the join's own screens would be the whole stack.
	if ScreenManager.current_screen() == null:
		return false
	return not ScreenManager.has_screen(ScreenManager.ACQUIRE_USER)


func _redeem_pending() -> void:
	if _is_pending_stale():
		# Never silent: an activation that expired unredeemed and one that never arrived
		# look identical from the outside, and they have entirely different causes.
		push_warning("[Invite] A buffered activation went unredeemed for %d seconds and was discarded." % int(PENDING_TTL_SECONDS))
		_clear_pending()
		return
	if not _ready_to_join():
		return
	var request := _pending_request
	_clear_pending()
	await _join(request)


## True while an activation is waiting on sign-in or on the front end. The acquire-user
## screen asks, so a cold launch from an invite can say why it is here.
func has_pending_invite() -> bool:
	return not _pending_request.is_empty() and not _is_pending_stale()


## Drops a buffered activation because the player chose to carry on without signing in.
## Continuing offline is them declining the invite, not deferring it: without an
## identity it can never be redeemed, and holding it means a sign-in twenty minutes
## later pulls them into a match they have long since forgotten accepting.
func decline_pending_invite() -> void:
	if _pending_request.is_empty():
		return
	print("[Invite] Continuing offline; the buffered activation was discarded.")
	_clear_pending()


func _is_pending_stale() -> bool:
	if _pending_request.is_empty():
		return false
	return Time.get_ticks_msec() - _pending_since_msec > int(PENDING_TTL_SECONDS * 1000.0)


## Rebinds rather than clears in place, so a caller that took a reference to the request
## on its way out — _redeem_pending() does — still holds the real thing.
func _clear_pending() -> void:
	if _pending_request.is_empty():
		return
	_pending_request = {}
	_pending_since_msec = 0
	pending_invite_changed.emit()


## Lands the player in their friend's match. Mirrors
## main_menu_screen._on_join_code_submitted so an invite ends up exactly where a typed
## join code would, including the entry-point privilege check that keeps a restricted
## account from being seated by a platform activation that skipped the menu.
func _join(request: Dictionary) -> void:
	# Claimed before the first await, not after: the confirmation prompt and the activity
	# lookup are both awaits, and an invite arriving inside either would otherwise start
	# a second join alongside this one.
	_joining = true

	var checking := ScreenManager.push(ScreenManager.LOADING, {"message": "Checking online permissions"})
	var denial := await _multiplayer_denial()
	ScreenManager.remove(checking)
	if not denial.is_empty():
		await ScreenManager.show_dialog("Cannot Join", denial, "error", false)
		_finish_join()
		return

	# Accepting an invite while already playing means abandoning the current match, so
	# it is the player's call rather than ours.
	if not NetManager.is_offline() and NetManager.local_player() != null:
		var confirmed: bool = await ScreenManager.show_dialog(
			"Join Match",
			"Leave the current match and join your friend's match?",
			"warning",
			true,
		)
		if not confirmed:
			_finish_join()
			return

	var loading := ScreenManager.push(ScreenManager.LOADING, {"message": "Joining match"})

	# An Xbox activation names the host, not the session, so the session has to be looked
	# up from their published activity before there is anything to join.
	var connection_string := String(request.get("connection_string", ""))
	if connection_string.is_empty():
		connection_string = await Services.connection_string_for_xuid(String(request.get("xuid", "")))
	if connection_string.is_empty():
		# Removed by name rather than popped: the lookup above is an await, and anything
		# pushed over this screen in the meantime is not this flow's to take down.
		ScreenManager.remove(loading)
		await ScreenManager.show_dialog(
			"Join Failed",
			"That match is no longer available to join.",
			"error",
			false,
		)
		_finish_join()
		return

	var join_request := NetManager.join_by_invite(connection_string)
	await join_request.wait()
	ScreenManager.remove(loading)
	# Another join replaced this one and owns the screen and the outcome, so this flow
	# leaves quietly: no dialog for a join the player themselves moved on from.
	if join_request.was_superseded():
		_finish_join()
		return
	# Checked together: a join reports success once the host admits this player, and the
	# session can still end between that and this navigation.
	if not NetManager.joined_session_is_live(join_request):
		if not join_request.was_cancelled():
			await ScreenManager.show_dialog("Join Failed", NetManager.join_failure_reason(join_request), "error", false)
		_finish_join()
		return
	ScreenManager.replace_all(ScreenManager.LOBBY, {"option": "join", "code": NetManager.join_code})
	# A duplicate of the invite just redeemed — a friend pressing send twice, or the
	# platform re-raising the same activation — would otherwise ask the player to leave
	# the match they have this moment landed in.
	if _same_request(_pending_request, request):
		_clear_pending()
	_finish_join()


## The live multiplayer denial for a routed activation. Empty includes the deliberate
## XR-074 fail-open cases where the privilege service could not answer.
func _multiplayer_denial() -> String:
	if Services == null:
		return "Online services are unavailable in this build."
	return await Services.resolve_multiplayer_denial_reason()


## Releases the join claim and gives an activation that arrived mid-flight its turn.
## Called after the dialogs rather than before them, so the claim covers the whole
## outcome the player is still reading.
func _finish_join() -> void:
	_joining = false
	_redeem_pending()


func _same_request(left: Dictionary, right: Dictionary) -> bool:
	if left.is_empty() or right.is_empty():
		return false
	return (
		String(left.get("connection_string", "")) == String(right.get("connection_string", ""))
		and String(left.get("xuid", "")) == String(right.get("xuid", ""))
	)
