class_name MatchmakingFlow
extends RefCounted

## One matchmaking attempt, from the staging lobby a group gathers in to the arranged
## match the service puts them in.
##
## NetManager owns this object and remains the only place RPCs are declared; the flow
## owns what those RPCs mean. It holds everything that has to outlive a bound transport:
## the online-entry lease, the captured account and entry epochs, both PlayFab lobby
## contexts, the frozen group, the ticket attempt and the durable reason the players are
## shown when a search ends. NetManager's own session model -- peer, generation, roster --
## deliberately does not survive the staging-to-arranged transport swap; this does.
##
## Authority is the staging owner's. Guests follow the owner's phase broadcasts and act
## on their own ticket status, never on a lobby message claiming a match.
##
## Not an autoload. It is created per attempt and dropped once its native cleanup has
## settled, which is what releases the lease.

## Raised whenever the phase, the durable outcome or anything the lobby draws changes.
signal changed()

enum Phase {
	IDLE,
	CREATING_STAGING,
	GATHERING,
	FREEZING,
	CREATING_TICKET,
	JOINING_TICKET,
	SEARCHING,
	CANCELLING,
	RESTORING_STAGING,
	MATCHED,
	JOINING_ARRANGED,
	ARMING_HANDOFF,
	SWITCHING_TRANSPORT,
	ADMITTING_COHORT,
	COMMITTING_START,
	GAMEPLAY,
	REMATCH_GATHERING,
	LEAVING,
	QUARANTINED,
}

enum Role { OWNER, GUEST }

## Staging lobby, staging Party network, activity and roster all hold four. A full group
## of four is submitted as one ticket like any smaller group; see docs/known-issues.md
## for why the fixed-four queue then rejects it.
const CAPACITY := 4

## Phase budgets. Each is an absolute deadline taken when its phase begins; inner
## operations consume what remains rather than starting their own clocks.
const FREEZE_SECONDS := 15.0
const RESTORE_SECONDS := 15.0
const CANCEL_GRACE_SECONDS := 5.0
const ARRANGED_JOIN_SECONDS := 30.0
const HANDOFF_SECONDS := 90.0
const OWNER_TRANSPORT_SECONDS := 30.0
const POLL_SECONDS := 0.1

## Search-control envelope phases. PartyService owns the encoding; these are the values.
const ENVELOPE_GATHERING := "gathering"
const ENVELOPE_FREEZING := "freezing"
const ENVELOPE_SEARCHING := "searching"
const ENVELOPE_CANCELLING := "cancelling"
const ENVELOPE_MATCHED := "matched"

## Session phases published with a transport descriptor.
const SESSION_PHASE_GATHERING := "gathering"
const SESSION_PHASE_BOOTSTRAP := "bootstrap"

const REASON_CANCELLED := &"search_cancelled"
const REASON_GROUP_CHANGED := &"group_changed"
const REASON_FREEZE_FAILED := &"freeze_failed"
const REASON_MEMBER_LEFT := &"member_left"
const REASON_GUEST_JOIN_FAILED := &"guest_join_failed"
const REASON_NO_MATCH := &"no_match"
const REASON_SEARCH_FAILED := &"search_failed"

const TEXT_CANCELLED := "The search was cancelled."
const TEXT_GROUP_CHANGED := "The group changed, so the search was stopped. Press Ready to search again."
const TEXT_FREEZE_FAILED := "The group could not be locked in for a search. Press Ready to try again."
const TEXT_MEMBER_LEFT := "A player left the group, so the search was stopped."
const TEXT_GUEST_JOIN_FAILED := "A player could not join the search, so it was stopped."
const TEXT_NO_MATCH := "No match was found. Press Ready to search again."
const TEXT_SEARCH_FAILED := "The search could not continue. Press Ready to try again."
const TEXT_UNAVAILABLE := "Matchmaking is unavailable in this build."

var id := 0
var role: Role = Role.OWNER
var phase: Phase = Phase.IDLE
var account_generation := -1
var entry_epoch := 0
## The owner's attempt number. Strictly increasing for one staging lobby, carried by every
## phase broadcast and search envelope so a late message from an earlier attempt can be
## told apart from the current one.
var epoch := 0
var mode: NRTypes.GameModeType = NRTypes.GameModeType.DEATHMATCH
## PartyService.LobbyContext handles. Opaque: only PartyService reads or writes them.
var staging_context: Variant = null
var arranged_context: Variant = null
## NetManager's session id for the bound staging transport, so a disconnect can be matched
## to the transport it belongs to rather than to whichever session exists by then.
var staging_session := 0
## The group the ticket is built from, frozen at FREEZING: peer id -> full entity key.
var frozen_peers: Dictionary = {}
var frozen_keys: Array[Dictionary] = []
var acks: Dictionary = {}
## MatchmakingService.TicketAttempt for the current epoch, or null.
var ticket: Variant = null
var match_id := ""
var arrangement := ""
var arranged_owner_key: Dictionary = {}
var arranged_owner := false
## The durable outcome of the last attempt. Kept through the restored Gathering phase so a
## coalesced snapshot or a rebuilt screen still explains why the search stopped.
var reason_code: StringName = &""
var reason := ""
var reason_epoch := 0
var presented_reason_epoch := 0
var restoration_failed := false
var cancel_unresolved := false
## Set once this member's arranged join has succeeded and a staging-transport loss is
## expected rather than fatal. See NetManager._on_server_disconnected().
var armed := false
var staging_reset := false
var admission_request: JoinRequest = null
var search_deadline_msec := 0
var phase_deadline_msec := 0
var retired := false
var native_release_started := false
## Players per match for this flow's mode, as the service validated it from the mode's
## real configuration when the flow started. Tickets are built from a fresh validation;
## this is what the flow was admitted with.
var match_size := CAPACITY

var _clock: OnlineFlowClock = null
var _restoring := false
var _pending_stop: Dictionary = {}
var _progress_callback: Callable = Callable()
var _finished_callback: Callable = Callable()
## Attempts this flow has retired whose native cleanup the service still owes. A live
## ticket could still match this player, so while any of these is unresolved the group is
## neither reopened nor searched again, and a leaving flow keeps the lease.
var _unresolved_attempts: Array = []
## The attempt this guest last told the owner it cannot join, so a refusal is sent once.
var _refused_epoch := 0


func _init(flow_id: int, flow_role: Role, generation: int, entry: int, flow_mode: NRTypes.GameModeType, clock: OnlineFlowClock) -> void:
	id = flow_id
	role = flow_role
	account_generation = generation
	entry_epoch = entry
	mode = flow_mode
	_clock = clock if clock != null else OnlineFlowClock.new()


# --- State ------------------------------------------------------------------

## True while this flow still owns its online work. Quarantine is not live -- nothing may
## advance -- but it still holds the lease until its native cleanup settles.
func is_live() -> bool:
	return not retired and phase != Phase.IDLE and phase != Phase.LEAVING and phase != Phase.QUARANTINED


## True when this is still NetManager's flow for the same account and entry epoch. Every
## continuation re-reads this after an await; a false answer means someone else owns the
## outcome now and this coroutine must stop without touching shared state.
func is_current() -> bool:
	return not retired and NetManager._flow == self \
		and Services.is_current_account(account_generation) \
		and NetManager._entry_epoch == entry_epoch


func is_owner() -> bool:
	return role == Role.OWNER


## Phases in which the group is frozen: readiness, appearance and membership are held.
func is_frozen() -> bool:
	return phase in [
		Phase.FREEZING, Phase.CREATING_TICKET, Phase.JOINING_TICKET, Phase.SEARCHING,
		Phase.CANCELLING, Phase.RESTORING_STAGING, Phase.MATCHED, Phase.JOINING_ARRANGED,
		Phase.ARMING_HANDOFF, Phase.SWITCHING_TRANSPORT, Phase.ADMITTING_COHORT,
		Phase.COMMITTING_START,
	]


## Whether players may change readiness or appearance right now.
func allows_customization() -> bool:
	return phase == Phase.GATHERING or phase == Phase.REMATCH_GATHERING or phase == Phase.GAMEPLAY


func is_searching() -> bool:
	return phase in [Phase.FREEZING, Phase.CREATING_TICKET, Phase.JOINING_TICKET, Phase.SEARCHING, Phase.CANCELLING]


## Whether the hosted-return "reopen the lobby" path may run. Only an arranged rematch
## reopens; a staging lobby is reopened by its own restoration transaction and never by a
## screen being rebuilt mid-search.
func allows_reopen() -> bool:
	return phase == Phase.REMATCH_GATHERING


## The social activity this member should publish now. The flow's veto comes first: a
## freezing, searching, bootstrapping or leaving session is never advertised, whatever the
## local admission gate says and even across an activity handover.
func social_snapshot(session_open: bool) -> Dictionary:
	var snapshot := {
		"joinable": false,
		"audience": ActivityService.JOIN_RESTRICTION,
		"capacity": CAPACITY,
		"connection_string": "",
		"group_id": "",
	}
	var context: Variant = null
	match phase:
		Phase.GATHERING:
			if not restoration_failed:
				context = staging_context
		Phase.REMATCH_GATHERING:
			context = arranged_context
			snapshot["audience"] = ActivityService.AUDIENCE_INVITE_ONLY
	var party: PartyService = Services.party() if Services != null else null
	if context == null or party == null:
		return snapshot
	snapshot["connection_string"] = party.lobby_connection_string(context)
	snapshot["group_id"] = party.lobby_id(context)
	snapshot["joinable"] = session_open and not String(snapshot["connection_string"]).is_empty()
	return snapshot


## What the lobby screen draws. Read-only; the screen never infers matchmaking from an
## empty join code or a screen payload.
func presentation() -> Dictionary:
	return {
		"id": id,
		"phase": phase,
		"owner": role == Role.OWNER,
		"capacity": CAPACITY,
		"match_size": match_size,
		"searching": is_searching(),
		"frozen": is_frozen(),
		"cancellable": role == Role.OWNER and phase in [Phase.FREEZING, Phase.CREATING_TICKET, Phase.SEARCHING],
		"reason": reason,
		"reason_code": String(reason_code),
		"reason_epoch": reason_epoch,
		"presented_epoch": presented_reason_epoch,
		"restoration_failed": restoration_failed,
		"cancel_unresolved": cancel_unresolved,
	}


## Records that a member's screen has shown this epoch's outcome, so a rebuilt screen
## does not show it twice.
func mark_reason_presented(presented_epoch: int) -> void:
	presented_reason_epoch = maxi(presented_reason_epoch, presented_epoch)


## The lobby contexts this flow still holds, arranged first so the newer resource is
## released before the one it replaced.
func held_contexts() -> Array:
	var contexts: Array = []
	if arranged_context != null:
		contexts.append(arranged_context)
	if staging_context != null and staging_context != arranged_context:
		contexts.append(staging_context)
	return contexts


func _set_phase(next: Phase) -> void:
	if phase == next:
		return
	phase = next
	changed.emit()


func _record_reason(code: StringName, text: String) -> void:
	reason_code = code
	reason = text
	reason_epoch = epoch
	changed.emit()


func _clear_reason() -> void:
	if reason.is_empty() and reason_code == &"":
		return
	reason_code = &""
	reason = ""
	changed.emit()


# --- Staging entry ----------------------------------------------------------

## Creates the staging lobby and its Party network and opens it. Returns false when the
## lobby never opened; the reason has then been reported through NetManager.
##
## The transport is activated synchronously -- bind, register, open the local gate --
## before the descriptor is published, so the first joiner who can find the network is
## admitted rather than refused as late.
func start_owner() -> bool:
	_set_phase(Phase.CREATING_STAGING)
	var resolved: Dictionary = await NetManager._resolve_signed_in_user()
	if not is_current():
		return false
	var user: Variant = resolved.get("user")
	if user == null:
		NetManager._flow_start_failed(self, String(resolved.get("error", "Could not start matchmaking.")))
		return false
	await NetManager._platform.apply_chat_privilege()
	if not is_current():
		return false
	var party := Services.party()
	if party == null:
		NetManager._flow_start_failed(self, TEXT_UNAVAILABLE)
		return false
	var mode_name := String(NRTypes.GameModeType.keys()[mode])
	var created: PartyService.PartyResult = await party.create_staging(
		user, CAPACITY, mode_name, account_generation, id)
	if not is_current():
		if created != null and created.context != null:
			await _release_context(created.context)
		return false
	if created == null or not created.ok() or created.context == null:
		NetManager._flow_start_failed(self, _result_reason(created, "Could not create the matchmaking lobby."))
		return false
	staging_context = created.context
	if not NetManager._flow_activate_transport(self, created.peer, true):
		NetManager._flow_start_failed(self, "PlayFab Party did not return a usable network peer.")
		return false
	staging_session = NetManager.session_id()
	var published: PartyService.PartyResult = await party.publish_transport(
		staging_context, created.publication_permit, SESSION_PHASE_GATHERING)
	if not is_current():
		return false
	if published == null or not published.ok():
		NetManager._flow_start_failed(self, _result_reason(published, "Could not open the matchmaking lobby."))
		return false
	_set_phase(Phase.GATHERING)
	NetManager._flow_session_opened(self)
	return true


## A guest admitted into a staging lobby through an ordinary invite, activity or
## connection-string join. The owner's lobby only admits while it is gathering, so this
## always begins there.
func start_guest(context: Variant) -> void:
	staging_context = context
	staging_session = NetManager.session_id()
	_set_phase(Phase.GATHERING)


# --- Gathering and the ready transaction -------------------------------------

## Called on every roster or lobby change. The owner starts a search the moment the exact
## admitted group is ready; during a search the same signals are how divergence is caught.
func on_group_changed() -> void:
	if not is_current() or role != Role.OWNER:
		return
	if phase == Phase.GATHERING:
		evaluate_ready()
		return
	if phase in [Phase.FREEZING, Phase.CREATING_TICKET, Phase.SEARCHING] and not _group_intact():
		_stop_search(REASON_GROUP_CHANGED, TEXT_GROUP_CHANGED)


## Starts the freeze once every admitted human is ready. A group of one to four takes the
## same path; four is not refused here or privately started.
func evaluate_ready() -> void:
	if role != Role.OWNER or phase != Phase.GATHERING or _restoring or restoration_failed:
		return
	if not is_current():
		return
	var group := admitted_group()
	if group.is_empty() or not _all_ready():
		return
	_freeze(group)


## The admitted group, peer id -> full entity key, when it equals the connected native
## staging membership exactly; otherwise empty. The equality is what keeps a lobby member
## who never finished joining Party from being silently left out of the ticket.
func admitted_group() -> Dictionary:
	var party := Services.party()
	if party == null or staging_context == null:
		return {}
	var snapshot: Dictionary = party.snapshot(staging_context)
	var native := {}
	for member: Variant in snapshot.get("members", []):
		if typeof(member) != TYPE_DICTIONARY:
			continue
		var entry := member as Dictionary
		if not bool(entry.get("connected", false)):
			continue
		var native_key := entity_key(entry.get("key", {}))
		if not native_key.is_empty():
			native[fingerprint(native_key)] = native_key
	var admitted := {}
	var seen := {}
	var local_id := NetManager.local_peer_id()
	for peer_id: int in NetManager.players:
		var state: PlayerState = NetManager.players[peer_id]
		if state == null or state.is_bot:
			return {}
		var key := entity_key(party.local_entity_key(staging_context) if peer_id == local_id else party.entity_key_for(peer_id))
		if key.is_empty() or seen.has(fingerprint(key)):
			return {}
		seen[fingerprint(key)] = true
		admitted[peer_id] = key
	if admitted.is_empty() or admitted.size() > CAPACITY or admitted.size() != native.size():
		return {}
	for peer_id: int in admitted:
		if not native.has(fingerprint(admitted[peer_id])):
			return {}
	return admitted


func _all_ready() -> bool:
	if NetManager.players.is_empty():
		return false
	for peer_id: int in NetManager.players:
		var state: PlayerState = NetManager.players[peer_id]
		if state == null or state.is_bot or not state.is_ready:
			return false
	return true


## The frozen group is still exactly the group in the lobby -- the admitted roster and
## the connected native membership alike -- and still all ready.
func _group_intact() -> bool:
	if not _same_group(admitted_group(), frozen_peers):
		return false
	for peer_id: int in frozen_peers:
		var state: PlayerState = NetManager.players.get(peer_id, null)
		if state == null or not state.is_ready:
			return false
	return true


func _freeze(group: Dictionary) -> void:
	# Re-entry is closed by the phase itself: it leaves GATHERING before the first await,
	# and evaluate_ready() only ever starts a freeze from GATHERING.
	epoch += 1
	var attempt := epoch
	acks.clear()
	cancel_unresolved = false
	frozen_peers = group.duplicate(true)
	frozen_keys.clear()
	for peer_id: int in frozen_peers:
		frozen_keys.append((frozen_peers[peer_id] as Dictionary).duplicate())
	frozen_keys.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return fingerprint(a) < fingerprint(b))
	phase_deadline_msec = _clock.deadline_after(FREEZE_SECONDS)
	_clear_reason()
	_set_phase(Phase.FREEZING)
	# The local gate closes before anything is awaited, and every existing member is
	# told in the same frame: they retire their own activity and acknowledge.
	NetManager._flow_set_admission(false)
	NetManager._flow_broadcast_phase(self, {})
	var party := Services.party()
	var posted: PartyService.PartyResult = await party.post_context_update(
		staging_context, {PartyService.SEARCH_CONTROL_KEY: _envelope(ENVELOPE_FREEZING, "")},
		{}, {}, phase_deadline_msec)
	if not _freeze_current(attempt):
		return
	if posted == null or not posted.ok():
		await _restore(REASON_FREEZE_FAILED, TEXT_FREEZE_FAILED)
		return
	var locked: PartyService.PartyResult = await party.set_context_locked(staging_context, true, phase_deadline_msec)
	if not _freeze_current(attempt):
		return
	if locked == null or not locked.ok():
		await _restore(REASON_FREEZE_FAILED, TEXT_FREEZE_FAILED)
		return
	while not _acks_complete():
		if _clock.has_expired(phase_deadline_msec):
			await _restore(REASON_FREEZE_FAILED, TEXT_FREEZE_FAILED)
			return
		await _clock.sleep_seconds(minf(POLL_SECONDS, _clock.remaining_seconds(phase_deadline_msec)))
		if not _freeze_current(attempt):
			return
	# Rechecked after every await: membership, readiness and ownership can all move while
	# the lock and the acknowledgements are in flight, and the ticket must describe the
	# group that exists now.
	var current := admitted_group()
	if not _same_group(current, frozen_peers) or not _all_ready() or not _is_staging_owner():
		await _restore(REASON_GROUP_CHANGED, TEXT_GROUP_CHANGED)
		return
	_begin_ticket(attempt)


func _freeze_current(attempt: int) -> bool:
	return is_current() and epoch == attempt and phase == Phase.FREEZING


func _acks_complete() -> bool:
	var local_id := NetManager.local_peer_id()
	for peer_id: int in frozen_peers:
		if peer_id != local_id and not acks.has(peer_id):
			return false
	return true


func _same_group(a: Dictionary, b: Dictionary) -> bool:
	if a.size() != b.size():
		return false
	for peer_id: Variant in a:
		if not b.has(peer_id) or fingerprint(a[peer_id]) != fingerprint(b[peer_id]):
			return false
	return true


func _is_staging_owner() -> bool:
	var party := Services.party()
	if party == null or staging_context == null:
		return false
	return bool(party.snapshot(staging_context).get("is_local_owner", false))


## A member acknowledged the freeze, or asked for the search to stop.
func on_member_report(sender: int, report_epoch: int, reported_phase: int) -> void:
	if role != Role.OWNER or not is_current() or report_epoch != epoch or not frozen_peers.has(sender):
		return
	if reported_phase == Phase.FREEZING and phase == Phase.FREEZING:
		acks[sender] = true
	elif reported_phase == Phase.CANCELLING:
		_stop_search(REASON_GUEST_JOIN_FAILED, TEXT_GUEST_JOIN_FAILED)


## A guest's binding Leave Group. Consent withdrawn mid-search cancels the whole ticket.
func on_member_leave(sender: int, leave_epoch: int) -> void:
	if role != Role.OWNER or not is_current() or not frozen_peers.has(sender):
		return
	if leave_epoch == epoch and is_searching():
		_stop_search(REASON_MEMBER_LEFT, TEXT_MEMBER_LEFT)


# --- Ticket lifecycle -------------------------------------------------------

func _begin_ticket(attempt: int) -> void:
	var matchmaking := Services.matchmaking()
	if matchmaking == null:
		await _restore(REASON_SEARCH_FAILED, TEXT_UNAVAILABLE)
		return
	# Built from a fresh validation of the mode's real configuration, never from a
	# constant: the configuration can change between the group opening and this ticket.
	var profile: Dictionary = matchmaking.runtime_profile(mode)
	if not bool(profile.get("ok", false)):
		await _restore(_profile_code(profile), _profile_text(profile))
		return
	_set_phase(Phase.CREATING_TICKET)
	# One budget from the owner's attempt: creating the ticket, publishing its id, every
	# premade guest joining it and the opponent search all spend these 600 seconds.
	search_deadline_msec = _clock.deadline_after(float(MatchmakingService.SEARCH_TIMEOUT_SECONDS))
	var spec := MatchmakingService.SearchSpec.new()
	spec.user = Services.playfab_user()
	spec.account_generation = account_generation
	spec.flow_epoch = attempt
	spec.owner = true
	spec.frozen_members.assign(frozen_keys)
	spec.mode = mode
	spec.expected_match_count = int(profile.get("player_count", 0))
	spec.deadline_msec = search_deadline_msec
	_watch_ticket(matchmaking.begin_create(spec), attempt)


## A guest joins the ticket the owner published, once, and only as a member of the frozen
## group for the current epoch. The id arrives in the lobby envelope; the owner's phase
## broadcast only says when to look.
func _reconcile_guest_ticket() -> void:
	if role != Role.GUEST or not is_current() or ticket != null:
		return
	if phase != Phase.JOINING_TICKET and phase != Phase.SEARCHING:
		return
	var party := Services.party()
	var matchmaking := Services.matchmaking()
	if party == null or matchmaking == null or staging_context == null:
		return
	var snapshot: Dictionary = party.snapshot(staging_context)
	var envelope: Variant = snapshot.get("search_control", {})
	if typeof(envelope) != TYPE_DICTIONARY or not bool((envelope as Dictionary).get("valid", false)):
		return
	var control := envelope as Dictionary
	if int(control.get("epoch", 0)) != epoch or String(control.get("phase", "")) != ENVELOPE_SEARCHING:
		return
	var ticket_id := String(control.get("ticket_id", ""))
	var local_key := entity_key(party.local_entity_key(staging_context))
	if ticket_id.is_empty() or local_key.is_empty():
		return
	var members: Array[Dictionary] = []
	var included := false
	for raw: Variant in control.get("group", []):
		var key := entity_key(raw)
		if key.is_empty():
			return
		included = included or fingerprint(key) == fingerprint(local_key)
		members.append(key)
	if not included:
		return
	# This member joins only with a configuration the service still accepts, and never
	# while a ticket it already let go of could still match it. Either way it cannot join,
	# so it asks the owner to stop -- once per attempt.
	var profile: Dictionary = matchmaking.runtime_profile(mode)
	if not bool(profile.get("ok", false)) or _cleanup_outstanding():
		if _refused_epoch != epoch:
			_refused_epoch = epoch
			NetManager._flow_send_report(epoch, Phase.CANCELLING)
		return
	frozen_keys.assign(members)
	var spec := MatchmakingService.SearchSpec.new()
	spec.user = Services.playfab_user()
	spec.account_generation = account_generation
	spec.flow_epoch = epoch
	spec.owner = false
	spec.frozen_members.assign(members)
	spec.mode = mode
	spec.expected_match_count = int(profile.get("player_count", 0))
	spec.deadline_msec = search_deadline_msec
	spec.ticket_id = ticket_id
	_watch_ticket(matchmaking.begin_join(spec), epoch)


func _watch_ticket(attempt: Variant, attempt_epoch: int) -> void:
	_release_ticket_observation()
	ticket = attempt
	if attempt == null:
		return
	_progress_callback = _on_ticket_progress.bind(attempt_epoch)
	_finished_callback = _on_ticket_finished.bind(attempt_epoch)
	attempt.progress_changed.connect(_progress_callback)
	attempt.finished.connect(_finished_callback)
	# A synchronous failure has already settled; a snapshot may already carry an id.
	if not attempt.is_pending():
		_on_ticket_finished(attempt, attempt_epoch)
	elif not String(attempt.ticket_id).is_empty():
		_on_ticket_progress(attempt, attempt_epoch)


func _release_ticket_observation() -> void:
	if ticket == null:
		return
	if _progress_callback.is_valid() and ticket.progress_changed.is_connected(_progress_callback):
		ticket.progress_changed.disconnect(_progress_callback)
	if _finished_callback.is_valid() and ticket.finished.is_connected(_finished_callback):
		ticket.finished.disconnect(_finished_callback)
	_progress_callback = Callable()
	_finished_callback = Callable()
	ticket = null


## Hands the attempt back to the service, then stops observing it. Retired first, so a
## still-pending attempt settles as superseded -- which the handlers below ignore as this
## flow letting go, not a search result -- and any native cleanup it still owes stays the
## service's, remembered here until the service reports it safe.
func _retire_ticket() -> void:
	var attempt: Variant = ticket
	var matchmaking: MatchmakingService = Services.matchmaking() if Services != null else null
	if attempt != null and matchmaking != null:
		matchmaking.retire(attempt)
		if bool(attempt.cleanup_pending) and not _unresolved_attempts.has(attempt):
			_unresolved_attempts.append(attempt)
	_release_ticket_observation()


## Whether any attempt this flow retired still has native cleanup the service owes.
func _cleanup_outstanding() -> bool:
	for index in range(_unresolved_attempts.size() - 1, -1, -1):
		var attempt: Variant = _unresolved_attempts[index]
		if attempt == null or not bool(attempt.cleanup_pending):
			_unresolved_attempts.remove_at(index)
	return not _unresolved_attempts.is_empty()


func _ticket_current(attempt: Variant, attempt_epoch: int) -> bool:
	return is_current() and attempt == ticket and attempt_epoch == epoch


func _on_ticket_progress(attempt: Variant, attempt_epoch: int) -> void:
	if bool(attempt.retired) or not _ticket_current(attempt, attempt_epoch) or not attempt.is_pending():
		return
	var status := int(attempt.status)
	var active := status == MatchmakingService.STATUS_WAITING_FOR_PLAYERS \
		or status == MatchmakingService.STATUS_WAITING_FOR_MATCH
	if role == Role.OWNER:
		if phase == Phase.CREATING_TICKET and active and not String(attempt.ticket_id).is_empty():
			_publish_ticket(attempt_epoch)
	elif phase == Phase.JOINING_TICKET and active:
		# The service accepted this member into the ticket. A handle alone never means that.
		_set_phase(Phase.SEARCHING)


## Publishes the usable id once, then tells every guest how much of the search budget is
## left. Budgets cross the wire as time remaining: each console's clock is its own.
func _publish_ticket(attempt_epoch: int) -> void:
	_set_phase(Phase.SEARCHING)
	var party := Services.party()
	var posted: PartyService.PartyResult = await party.post_context_update(
		staging_context, {PartyService.SEARCH_CONTROL_KEY: _envelope(ENVELOPE_SEARCHING, String(ticket.ticket_id) if ticket != null else "")},
		{}, {}, search_deadline_msec)
	if not is_current() or epoch != attempt_epoch or phase != Phase.SEARCHING:
		return
	if posted == null or not posted.ok():
		_stop_search(REASON_SEARCH_FAILED, TEXT_SEARCH_FAILED)
		return
	NetManager._flow_broadcast_phase(self, {"remaining_ms": maxi(0, search_deadline_msec - _clock.now_msec())})


func _on_ticket_finished(attempt: Variant, attempt_epoch: int) -> void:
	if bool(attempt.retired) or not _ticket_current(attempt, attempt_epoch):
		return
	var outcome := int(attempt.outcome)
	if outcome == MatchmakingService.Outcome.MATCHED:
		if phase == Phase.CANCELLING or not _pending_stop.is_empty():
			# The match won a cancel race. The cancel request stays binding: the group
			# leaves rather than starting a match nobody asked to keep.
			_retire_ticket()
			NetManager._flow_fail(self, TEXT_CANCELLED)
			return
		_on_matched(attempt)
		return
	var code: StringName = attempt.reason_code
	var text := String(attempt.reason)
	if outcome == MatchmakingService.Outcome.NO_MATCH:
		if code == &"":
			code = REASON_NO_MATCH
		if text.is_empty():
			text = TEXT_NO_MATCH
	elif outcome == MatchmakingService.Outcome.CANCELLED:
		if code == &"":
			code = REASON_CANCELLED
		if text.is_empty():
			text = TEXT_CANCELLED
	else:
		if code == &"":
			code = REASON_SEARCH_FAILED
		if text.is_empty():
			text = TEXT_SEARCH_FAILED
	if not _pending_stop.is_empty():
		code = StringName(_pending_stop.get("code", code))
		text = String(_pending_stop.get("text", text))
	# The outcome is copied; the attempt now goes back to the service before this flow
	# stops observing it.
	_retire_ticket()
	if role == Role.OWNER:
		if _cleanup_outstanding():
			_hold_for_cleanup(code, text)
		else:
			_restore(code, text)
	elif phase in [Phase.JOINING_TICKET, Phase.SEARCHING] and outcome == MatchmakingService.Outcome.FAILED:
		# This member could not join the owner's ticket. It cannot restart the group
		# alone; it asks the owner to stop and waits for the restoration broadcast.
		NetManager._flow_send_report(epoch, Phase.CANCELLING)


## The search has stopped, but the service still owes native cleanup for its ticket --
## usually a cancellation it could not confirm. A live ticket could still match the group,
## so it stays closed and visibly cancelling; nothing is reopened or searched again until
## the service reports the ticket safe, and then the group is restored with the reason
## already captured. Leaving stays available throughout.
func _hold_for_cleanup(code: StringName, text: String) -> void:
	var holding_epoch := epoch
	_pending_stop = {"code": code, "text": text}
	cancel_unresolved = true
	if phase != Phase.CANCELLING:
		_set_phase(Phase.CANCELLING)
		NetManager._flow_broadcast_phase(self, {})
	changed.emit()
	while _cleanup_outstanding():
		await _clock.sleep_seconds(POLL_SECONDS)
		if not is_current() or epoch != holding_epoch or phase != Phase.CANCELLING:
			return
	_restore(code, text)


## Stops the current search attempt. Before a ticket exists this is a restoration; with a
## live ticket it is a service-confirmed cancellation first.
func _stop_search(code: StringName, text: String) -> void:
	if role != Role.OWNER or not is_current():
		return
	match phase:
		Phase.FREEZING:
			_restore(code, text)
		Phase.CREATING_TICKET, Phase.SEARCHING:
			_cancel_and_restore(code, text)


## The owner's Cancel Search.
func cancel_search() -> void:
	_stop_search(REASON_CANCELLED, TEXT_CANCELLED)


func _cancel_and_restore(code: StringName, text: String) -> void:
	if ticket == null:
		_restore(code, text)
		return
	_pending_stop = {"code": code, "text": text}
	_set_phase(Phase.CANCELLING)
	NetManager._flow_broadcast_phase(self, {})
	var party := Services.party()
	if party != null and staging_context != null:
		party.post_context_update(staging_context, {PartyService.SEARCH_CONTROL_KEY: _envelope(ENVELOPE_CANCELLING, "")}, {}, {}, _clock.deadline_after(CANCEL_GRACE_SECONDS))
	Services.matchmaking().request_cancel(ticket)
	# Cancellation is confirmed by the ticket, not by this request. The grace below only
	# decides when the lobby admits that confirmation is taking a while.
	var cancelling_epoch := epoch
	await _clock.sleep_seconds(CANCEL_GRACE_SECONDS)
	if is_current() and epoch == cancelling_epoch and phase == Phase.CANCELLING:
		cancel_unresolved = true
		changed.emit()


# --- Restoration ------------------------------------------------------------

## Returns every survivor to the same staging lobby after a search stops before a match:
## usable ticket metadata removed, everyone unready, the lobby unlocked and reopened,
## every member's activity restored, and the reason kept for the players to read.
##
## Fails closed. An unconfirmed write or unlock leaves the group locked with Retry and
## Leave rather than advertising a lobby the service still refuses.
func _restore(code: StringName, text: String) -> void:
	if role != Role.OWNER or not is_current() or _restoring:
		return
	_restoring = true
	_pending_stop = {}
	cancel_unresolved = false
	_retire_ticket()
	var restoring_epoch := epoch
	_record_reason(code, text)
	_set_phase(Phase.RESTORING_STAGING)
	NetManager._flow_broadcast_phase(self, {"reason_code": String(code), "reason": text})
	var party := Services.party()
	var deadline := _clock.deadline_after(RESTORE_SECONDS)
	var posted: PartyService.PartyResult = await party.post_context_update(
		staging_context, {PartyService.SEARCH_CONTROL_KEY: _envelope(ENVELOPE_GATHERING, "")},
		{}, {}, deadline)
	if not _restore_current(restoring_epoch):
		return
	NetManager._flow_reset_readiness()
	var unlocked: PartyService.PartyResult = await party.set_context_locked(staging_context, false, deadline)
	if not _restore_current(restoring_epoch):
		return
	if posted == null or not posted.ok() or unlocked == null or not unlocked.ok():
		restoration_failed = true
		_restoring = false
		changed.emit()
		return
	restoration_failed = false
	_restoring = false
	# Gathering is set before the gate opens, so the admission signal already sees a
	# joinable phase and every activity is republished from one consistent state.
	_set_phase(Phase.GATHERING)
	NetManager._flow_set_admission(true)
	NetManager._flow_broadcast_phase(self, {"reason_code": String(code), "reason": text})


func _restore_current(restoring_epoch: int) -> bool:
	if is_current() and epoch == restoring_epoch and phase == Phase.RESTORING_STAGING:
		return true
	_restoring = false
	return false


## Retry after a restoration write or unlock failed.
func retry_restore() -> void:
	if role == Role.OWNER and restoration_failed and phase == Phase.RESTORING_STAGING and not _restoring:
		_restore(reason_code, reason)


# --- Guest side ---------------------------------------------------------------

## The staging owner's phase broadcast. Guests adopt the owner's epoch, retire their own
## activity while frozen, acknowledge the freeze, and join the owner's ticket when it is
## published. A lobby message never manufactures a match: that comes from this member's
## own ticket status.
func on_owner_phase(owner_epoch: int, next_phase: int, detail: Dictionary) -> void:
	if role != Role.GUEST or not is_current() or owner_epoch < epoch:
		return
	if next_phase == Phase.FREEZING:
		epoch = owner_epoch
		_retire_ticket()
		cancel_unresolved = false
		_clear_reason()
		_set_phase(Phase.FREEZING)
		NetManager._flow_send_report(epoch, Phase.FREEZING)
	elif next_phase == Phase.SEARCHING:
		if owner_epoch != epoch:
			return
		search_deadline_msec = _clock.now_msec() + maxi(0, int(detail.get("remaining_ms", 0)))
		if phase == Phase.FREEZING:
			_set_phase(Phase.JOINING_TICKET)
		_reconcile_guest_ticket()
	elif next_phase == Phase.CANCELLING:
		if owner_epoch == epoch and is_searching():
			_set_phase(Phase.CANCELLING)
	elif next_phase == Phase.RESTORING_STAGING or next_phase == Phase.GATHERING:
		epoch = owner_epoch
		_retire_ticket()
		cancel_unresolved = false
		var code := String(detail.get("reason_code", ""))
		var text := String(detail.get("reason", ""))
		if text.is_empty() and not code.is_empty():
			text = MatchmakingService.reason_for_code(code)
		if not text.is_empty() and (reason_epoch != epoch or reason != text):
			_record_reason(StringName(code), text)
		_set_phase(Phase.RESTORING_STAGING if next_phase == Phase.RESTORING_STAGING else Phase.GATHERING)


## Lobby state moved: a newly replicated envelope may carry the ticket id this guest was
## waiting for, and any member change is the owner's cue to re-check its group.
func on_lobby_changed(context: Variant) -> void:
	if not is_current():
		return
	if context == staging_context:
		if role == Role.GUEST:
			_reconcile_guest_ticket()
		else:
			on_group_changed()


# --- Matched handoff ------------------------------------------------------------

## A match. From here every failure is terminal: a partly dispersed group cannot be put
## back together, so the players are returned to the menu with the reason.
func _on_matched(attempt: Variant) -> void:
	match_id = String(attempt.match_id)
	arrangement = String(attempt.arrangement)
	# Copied first; then the attempt goes back to the service. A matched ticket is natively
	# terminal, so retiring it cancels nothing.
	_retire_ticket()
	_set_phase(Phase.MATCHED)
	if role == Role.OWNER and staging_context != null:
		Services.party().post_context_update(staging_context, {PartyService.SEARCH_CONTROL_KEY: _envelope(ENVELOPE_MATCHED, "")}, {}, {}, _clock.deadline_after(ARRANGED_JOIN_SECONDS))
	_join_arranged()


func _join_arranged() -> void:
	_set_phase(Phase.JOINING_ARRANGED)
	phase_deadline_msec = _clock.deadline_after(ARRANGED_JOIN_SECONDS)
	var party := Services.party()
	var properties := {
		MatchmakingService.PROTOCOL_MEMBER_KEY: NRProtocol.version_string(),
		PartyService.MATCH_ID_MEMBER_KEY: match_id,
		PartyService.MATCH_ORIGIN_MEMBER_KEY: PartyService.MATCH_ORIGIN_VALUE,
	}
	var joined: PartyService.PartyResult = await party.join_arranged(
		Services.playfab_user(), arrangement, properties, account_generation, id, phase_deadline_msec)
	if not is_current():
		if joined != null and joined.context != null:
			await _release_context(joined.context)
		return
	if joined == null or not joined.ok() or joined.context == null:
		NetManager._flow_fail(self, _result_reason(joined, "The match could not be joined."))
		return
	arranged_context = joined.context
	arranged_owner_key = entity_key(joined.owner_key)
	var local_key := entity_key(party.local_entity_key(arranged_context))
	arranged_owner = not arranged_owner_key.is_empty() and fingerprint(arranged_owner_key) == fingerprint(local_key)
	_arm_handoff()


## Arms intentional old-transport loss handling before announcing readiness, then waits
## for every arranged member to have done the same and for the arranged owner's lock. Only
## then does anyone deliberately retire the staging transport.
func _arm_handoff() -> void:
	armed = true
	phase_deadline_msec = _clock.deadline_after(HANDOFF_SECONDS)
	_set_phase(Phase.ARMING_HANDOFF)
	var party := Services.party()
	var ready_post: PartyService.PartyResult = await party.post_context_update(
		arranged_context, {}, {}, {PartyService.HANDOFF_READY_MEMBER_KEY: match_id}, phase_deadline_msec)
	if not is_current() or phase != Phase.ARMING_HANDOFF:
		return
	if ready_post == null or not ready_post.ok():
		NetManager._flow_fail(self, _result_reason(ready_post, "The match could not be prepared."))
		return
	if arranged_owner:
		var locked: PartyService.PartyResult = await party.set_context_locked(arranged_context, true, phase_deadline_msec)
		if not is_current() or phase != Phase.ARMING_HANDOFF:
			return
		if locked == null or not locked.ok():
			NetManager._flow_fail(self, _result_reason(locked, "The match could not be locked."))
			return
	while not _handoff_barrier_met():
		if not _arranged_owner_unchanged():
			NetManager._flow_fail(self, "The match host changed before the match began.")
			return
		if _clock.has_expired(phase_deadline_msec):
			NetManager._flow_fail(self, "The other players did not arrive in time.")
			return
		await _clock.sleep_seconds(minf(POLL_SECONDS, _clock.remaining_seconds(phase_deadline_msec)))
		if not is_current() or phase != Phase.ARMING_HANDOFF:
			return
	await switch_transport()


func _handoff_barrier_met() -> bool:
	var party := Services.party()
	if party == null or arranged_context == null:
		return false
	var snapshot: Dictionary = party.snapshot(arranged_context)
	var members: Variant = snapshot.get("members", [])
	if typeof(members) != TYPE_ARRAY or (members as Array).size() != match_size:
		return false
	for member: Variant in members:
		if typeof(member) != TYPE_DICTIONARY or not bool((member as Dictionary).get("connected", false)):
			return false
		var properties: Variant = (member as Dictionary).get("properties", {})
		if typeof(properties) != TYPE_DICTIONARY \
				or String((properties as Dictionary).get(PartyService.HANDOFF_READY_MEMBER_KEY, "")) != match_id:
			return false
	return bool(snapshot.get("membership_locked", false))


func _arranged_owner_unchanged() -> bool:
	var party := Services.party()
	if party == null or arranged_context == null:
		return false
	var owner := entity_key(party.snapshot(arranged_context).get("owner_key", {}))
	return not owner.is_empty() and fingerprint(owner) == fingerprint(arranged_owner_key)


## An involuntary loss of the old staging transport after arming. The local session ends
## now, but the replacement network is still prepared only once the barrier is met.
func on_armed_staging_loss() -> void:
	if not is_current() or phase != Phase.ARMING_HANDOFF or staging_reset:
		return
	staging_reset = NetManager._end_local_session_for_handoff(self)
	if not staging_reset:
		NetManager._flow_fail(self, "The match could not be prepared.")


## The staging-to-arranged swap. NetManager's old session ends synchronously and
## completely before anything is awaited (see NetManager._end_local_session_for_handoff);
## this flow keeps the identity, lease and both lobby contexts across the gap. Only the
## actual arranged owner creates the fresh network that makes it Godot peer 1.
func switch_transport() -> void:
	if not is_current():
		return
	_set_phase(Phase.SWITCHING_TRANSPORT)
	if not staging_reset:
		staging_reset = NetManager._end_local_session_for_handoff(self)
		if not staging_reset:
			NetManager._flow_fail(self, "The match could not be prepared.")
			return
	var party := Services.party()
	if staging_context != null:
		await party.leave_transport(staging_context)
		if not is_current():
			return
	# The platform reset cleared the previous session's communications verdict; it is
	# resolved again before any network exists, exactly as hosting and joining do.
	await NetManager._platform.apply_chat_privilege()
	if not is_current():
		return
	var user: Variant = Services.playfab_user()
	var prepared: PartyService.PartyResult = null
	if arranged_owner:
		var slice := mini(phase_deadline_msec, _clock.deadline_after(OWNER_TRANSPORT_SECONDS))
		prepared = await party.prepare_transport(arranged_context, user, slice)
	else:
		prepared = await party.join_transport(arranged_context, user, phase_deadline_msec)
	if not is_current():
		return
	if prepared == null or not prepared.ok():
		NetManager._flow_fail(self, _result_reason(prepared, "The match network could not be reached."))
		return
	# Copied before activation: nothing inside the synchronous block below may ask
	# PartyService anything.
	var permit := prepared.publication_permit
	var peer: Variant = prepared.peer
	_set_phase(Phase.ADMITTING_COHORT)
	if not NetManager._flow_activate_transport(self, peer, arranged_owner):
		NetManager._flow_fail(self, "PlayFab Party did not return a usable network peer.")
		return
	if arranged_owner:
		var published: PartyService.PartyResult = await party.publish_transport(
			arranged_context, permit, SESSION_PHASE_BOOTSTRAP, {}, {}, phase_deadline_msec)
		if not is_current():
			return
		if published == null or not published.ok():
			NetManager._flow_fail(self, _result_reason(published, "The match could not be opened."))
			return
		return
	await _drive_admission()


## Installed by NetManager inside the guest's activation block, immediately after the
## new peer binds. No request of any kind spans the transport swap.
func install_admission_request(request: JoinRequest) -> void:
	admission_request = request


## Waits for the arranged owner to admit this guest, on this phase's own deadline rather
## than the 45-second ordinary join budget, and never through the ordinary join driver's
## global teardown.
func _drive_admission() -> void:
	var request := admission_request
	while request != null and request.is_pending():
		if not is_current() or request != admission_request:
			return
		if request.admitted:
			NetManager._consume_flow_admission(self, request)
			return
		if _clock.has_expired(phase_deadline_msec):
			NetManager._flow_fail(self, "The match could not be joined in time.")
			return
		await _clock.sleep_seconds(minf(POLL_SECONDS, _clock.remaining_seconds(phase_deadline_msec)))


# --- Retirement ---------------------------------------------------------------

## Ends this flow for good. Synchronous, so account loss and suspend can call it from
## callbacks that must not await. `defer_native` is for the callbacks that must not start
## SDK work at all: the ticket's native cancellation and the guest's leave message then wait
## for the deferred teardown, which calls release_native().
func retire(defer_native: bool = false) -> void:
	if retired:
		return
	# A guest leaving mid-search tells the owner first, so its withdrawal cancels the
	# group ticket rather than being mistaken for a transport fault.
	if not defer_native and role == Role.GUEST and is_searching() and NetManager.has_session():
		NetManager._flow_send_leave(epoch)
	retired = true
	_restoring = false
	if not defer_native:
		_retire_ticket()
	if admission_request != null and admission_request.is_pending():
		admission_request.settle(JoinRequest.Outcome.CANCELLED)
	admission_request = null
	_set_phase(Phase.LEAVING)


## The cleanup NetManager runs once the flow is retired: the ticket (if deferred) and every
## captured lobby and transport, each through its own context so nothing global is touched.
func release_native() -> void:
	if native_release_started:
		return
	native_release_started = true
	_retire_ticket()
	var party: PartyService = Services.party() if Services != null else null
	if party != null:
		for context: Variant in held_contexts():
			await party.leave_lobby(context)
			await party.leave_transport(context)
	# A retired ticket the service has not finished with could still match this player, so
	# the lease -- and with it every online entry -- is held until the service reports it
	# safe, for as long as this is the signed-in account. The wait is shown as quarantine
	# after the cancellation grace; quit and account teardown bound it from outside.
	while _cleanup_outstanding() and Services != null and Services.is_current_account(account_generation):
		await _clock.sleep_seconds(POLL_SECONDS)


## A result context this flow was not allowed to keep: a success that arrived after the
## flow moved on. Cleaned through its own handle, never through a global leave.
func _release_context(context: Variant) -> void:
	var party: PartyService = Services.party() if Services != null else null
	if party == null or context == null:
		return
	await party.leave_lobby(context)
	await party.leave_transport(context)


func mark_quarantined() -> void:
	if phase == Phase.LEAVING:
		phase = Phase.QUARANTINED
		changed.emit()


# --- Helpers ------------------------------------------------------------------

func _envelope(envelope_phase: String, ticket_id: String) -> String:
	var envelope := {
		"epoch": epoch,
		"phase": envelope_phase,
		"group": frozen_keys.duplicate(true),
	}
	if not ticket_id.is_empty():
		envelope["ticket_id"] = ticket_id
	if envelope_phase == ENVELOPE_GATHERING and not reason.is_empty():
		envelope["reason_code"] = String(reason_code)
		envelope["reason"] = reason
	return PartyService.encode_search_control(envelope)


static func entity_key(value: Variant) -> Dictionary:
	if typeof(value) != TYPE_DICTIONARY:
		return {}
	var source := value as Dictionary
	var entity_id := String(source.get("id", "")).strip_edges()
	var entity_type := String(source.get("type", "")).strip_edges()
	if entity_id.is_empty() or entity_type.is_empty():
		return {}
	return {"id": entity_id, "type": entity_type}


static func fingerprint(key: Dictionary) -> String:
	return "%s\u001f%s" % [String(key.get("id", "")), String(key.get("type", ""))]


static func _result_reason(result: Variant, fallback: String) -> String:
	if result == null:
		return fallback
	var text := String(result.reason)
	return text if not text.is_empty() else fallback


## The service's reason code for a refused profile, kept as the durable outcome code.
static func _profile_code(profile: Dictionary) -> StringName:
	var code := String(profile.get("reason_code", ""))
	return StringName(code) if not code.is_empty() else REASON_SEARCH_FAILED


## The service's player-facing reason for a refused profile.
static func _profile_text(profile: Dictionary) -> String:
	var text := String(profile.get("reason", ""))
	return text if not text.is_empty() else TEXT_UNAVAILABLE
