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
## Authority is the staging owner's until the match: guests adopt the owner's state through
## one reducer and act on their own ticket status, never on a lobby message claiming a
## match. From the arranged lobby on, authority is the arranged native owner's -- the
## player whose fresh network makes it Godot peer 1, whichever premade role it had.
##
## Not an autoload. It is created per attempt and dropped once its native cleanup has
## settled, which is what releases the lease.

## Raised whenever the phase, the durable outcome or anything the lobby draws changes.
signal changed()
## Raised once when the owned staging leave in flight answers or its deadline wins.
signal _owned_leave_settled()

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
const ENTRY_SECONDS := 45.0
const FREEZE_SECONDS := 15.0
const RESTORE_SECONDS := 15.0
const SYNC_SECONDS := 15.0
const CANCEL_GRACE_SECONDS := 5.0
const ARRANGED_JOIN_SECONDS := 30.0
const HANDOFF_SECONDS := 90.0
const OWNER_TRANSPORT_SECONDS := 30.0
const COMMIT_SECONDS := 30.0
const HOST_RETURN_SECONDS := 45.0
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
const TEXT_ENTRY_TIMEOUT := "Opening the group took too long. Please try again."
const TEXT_HOST_SILENT := "The group host did not respond."
const TEXT_OWNER_CHANGED := "The group host changed, so the group was closed."
const TEXT_PROFILE_CHANGED := "Quick Match needs the four-player Deathmatch settings."
const TEXT_MATCH_HOST_CHANGED := "The match host changed before the match began."
const TEXT_MATCH_INCOMPATIBLE := "A player in the match is running a different version of the game."
const TEXT_MATCH_MEMBER_LOST := "A player left before the match began."
const TEXT_MATCH_LATE := "The other players did not arrive in time."
const TEXT_MATCH_UNSEALED := "The match could not be locked."
const TEXT_MATCH_MISMATCH := "The match did not include this player's group."
const TEXT_HOST_DID_NOT_RETURN := "The match host did not return to the lobby."
const TEXT_ARRANGED_CHANGED := "The match lobby changed unexpectedly."
const TEXT_GROUP_NOT_RETIRED := "The previous group could not be left cleanly."
const TEXT_OLD_NETWORK_NOT_LEFT := "The previous group's connection could not be closed."

## How a flow began. The staging role above is the ticket role only; who hosts an
## arranged session is `arranged_owner`, whichever premade role a player had.
const ENTRY_STAGING_OWNER := &"staging_owner"
const ENTRY_STAGING_GUEST := &"staging_guest"
const ENTRY_ARRANGED_REMATCH := &"arranged_rematch"

## Same-epoch order of a guest's staging state. Within one attempt the owner only moves
## forward -- frozen, searching, cancelling, restoring, restored -- so an older lobby
## replication or a reordered broadcast can never move a guest back.
const _STAGE_NONE := 0
const _STAGE_FROZEN := 1
const _STAGE_SEARCHING := 2
const _STAGE_CANCELLING := 3
const _STAGE_RESTORING := 4
const _STAGE_RESTORED := 5

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
## expected rather than fatal. See NetManager._on_server_disconnected(). It says nothing
## about the staging *lobby*: arming does not prove the cohort barrier, so a lost lobby
## still ends the group until the flow's own owned leave of it has begun.
var armed := false
var staging_reset := false
## Set immediately before this flow's owned leave_lobby of its staging lobby is invoked,
## with no await in between -- the only point from which that lobby's going away is
## expected. Never during the staging owner's wait for its own guests to leave: that
## is preparation, and the lobby is still the group's. See _retire_staging().
var staging_retiring := false
## Set once this member's staging retirement is confirmed: both owned leaves returned OK on
## the current flow and PartyService reports the old context quiescent. A cleared context
## pointer or a caller timeout is not this.
var staging_retired := false
## Set once this member's `nr_staging_retired` marker is in the arranged lobby. The arranged
## owner commits the first match only once every sealed member carries it.
var retirement_reported := false
var admission_request: JoinRequest = null
var search_deadline_msec := 0
var phase_deadline_msec := 0
var retired := false
var native_release_started := false
## Players per match for this flow's mode, as the service validated it from the mode's
## real configuration when the flow started. Tickets are built from a fresh validation;
## this is what the flow was admitted with.
var match_size := CAPACITY
## How this flow began; see ENTRY_*.
var entry_kind: StringName = ENTRY_STAGING_OWNER
## The owner's 45-second establishment budget, taken before its first awaited work.
var entry_deadline_msec := 0
## A guest has adopted the owner's current state -- from a correlated reply, a validated
## envelope or a broadcast -- and may expose Ready. The owner is its own authority.
var synced := false
## The arranged session's round: 0 for the matched game, then one more at each return.
var match_round := 0
## The four arranged members the handoff sealed. The initial start admits exactly these.
var pinned_keys: Array[Dictionary] = []
## The arranged owner has returned to the lobby for a rematch; a guest waiting for it is
## told so by the arranged lobby, not by a message.
var host_returned := false
var last_admission_error := ""

var _clock: OnlineFlowClock = null
var _restoring := false
var _pending_stop: Dictionary = {}
var _progress_callback: Callable = Callable()
var _finished_callback: Callable = Callable()
## Attempts this flow has retired whose native cleanup the service still owes. A live
## ticket could still match this player, so while any of these is unresolved the group is
## neither reopened nor searched again, and a leaving flow keeps the lease.
var _unresolved_attempts: Array = []
## Scoped Party operations this flow started whose native completion is still owed after
## their caller settled -- a timeout, usually. Held for the same reason as the attempts.
var _unresolved_operations: Array = []
## The attempt this guest last told the owner it cannot join, so a refusal is sent once.
var _refused_epoch := 0
## Guest bookkeeping for the current epoch: how far it has moved, whether it acknowledged
## the freeze, which epoch it joined a ticket for and which epoch its budget belongs to.
var _stage := _STAGE_NONE
var _acked_epoch := 0
var _joined_epoch := 0
var _budget_epoch := -1
## The single state-sync request a guest may have in flight.
var _sync_request_id := 0
var _sync_pending_id := 0
var _sync_sent_msec := 0
var _sync_purpose: StringName = &""
var _sync_alarm: OnlineFlowClock.Alarm = null
## Arranged members seen connected during the handoff, so one disappearing is a loss and
## not merely incomplete replication.
var _seen_connected: Dictionary = {}
## The one owned staging leave in flight -- transport or lobby -- raced against its
## deadline alarm, so a native leave that never answers cannot hold the handoff open. The
## result is kept only until the waiting step reads it; it references the old context,
## never this flow.
var _owned_leave_token := 0
var _owned_leave_pending := false
var _owned_leave_result: Variant = null
var _owned_leave_alarm: OnlineFlowClock.Alarm = null


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


## Whether players may change readiness or appearance right now. A guest that has not
## yet adopted the owner's state waits: its Ready would describe a group it cannot see.
func allows_customization() -> bool:
	if phase == Phase.GATHERING:
		return is_synced()
	return phase == Phase.REMATCH_GATHERING or phase == Phase.GAMEPLAY


## Whether this member has adopted the owner's state, from a correlated reply or a
## positive-epoch snapshot. Owners and rematch entrants start synced; an invited guest does
## not until the owner has answered.
func is_synced() -> bool:
	return synced


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
		"entry_kind": String(entry_kind),
		"arranged_host": arranged_owner,
		"capacity": CAPACITY,
		"match_size": match_size,
		"round": match_round,
		"synced": is_synced(),
		"host_returned": host_returned,
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
##
## One 45-second budget, taken by NetManager before this first await, covers all of it:
## the chat privilege, the native lobby and Party creation, activation and the descriptor.
func start_owner() -> bool:
	entry_kind = ENTRY_STAGING_OWNER
	synced = true
	if entry_deadline_msec <= 0:
		entry_deadline_msec = _clock.deadline_after(ENTRY_SECONDS)
	_set_phase(Phase.CREATING_STAGING)
	var resolved: Dictionary = await NetManager._resolve_signed_in_user()
	if not _entry_current():
		return false
	var user: Variant = resolved.get("user")
	if user == null:
		NetManager._flow_start_failed(self, String(resolved.get("error", "Could not start matchmaking.")))
		return false
	await NetManager._platform.apply_chat_privilege(_entry_still_current)
	if not _entry_current():
		return false
	var party := Services.party()
	if party == null:
		NetManager._flow_start_failed(self, TEXT_UNAVAILABLE)
		return false
	var mode_name := String(NRTypes.GameModeType.keys()[mode])
	var created: PartyService.PartyResult = await party.create_staging(
		user, CAPACITY, mode_name, account_generation, id, entry_deadline_msec)
	_hold_operation(created)
	if not is_current():
		if created != null and created.context != null:
			await _release_context(created.context)
		return false
	if _clock.has_expired(entry_deadline_msec) or _timed_out(created):
		if created != null and created.context != null:
			await _release_context(created.context)
		if is_current():
			NetManager._flow_start_failed(self, TEXT_ENTRY_TIMEOUT)
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
		staging_context, created.publication_permit, SESSION_PHASE_GATHERING, {}, {}, entry_deadline_msec)
	_hold_operation(published)
	if not is_current():
		return false
	if _timed_out(published):
		NetManager._flow_start_failed(self, TEXT_ENTRY_TIMEOUT)
		return false
	if published == null or not published.ok():
		NetManager._flow_start_failed(self, _result_reason(published, "Could not open the matchmaking lobby."))
		return false
	_set_phase(Phase.GATHERING)
	NetManager._flow_session_opened(self)
	return true


## The establishment budget still holds. Past it the entry fails -- with the resources it
## created released through their own handles -- rather than opening late.
func _entry_current() -> bool:
	if not is_current():
		return false
	if _clock.has_expired(entry_deadline_msec):
		NetManager._flow_start_failed(self, TEXT_ENTRY_TIMEOUT)
		return false
	return true


## Handed to the chat privilege check so its prompt stops mattering once the entry has.
func _entry_still_current() -> bool:
	return is_current() and not _clock.has_expired(entry_deadline_msec)


## Whether a scoped result is the service's typed deadline answer.
static func _timed_out(result: Variant) -> bool:
	return result != null and int(result.outcome) == PartyService.PartyResult.Outcome.TIMEOUT


## A guest admitted into a staging lobby through an ordinary invite, activity or
## connection-string join. The owner's lobby only admits while it is gathering, so this
## always begins there -- but it does not expose Ready until it has adopted the owner's
## actual state: the snapshot taken now, a buffered or live broadcast, or the reply to the
## state request sent here if neither settles it.
func start_guest(context: Variant) -> void:
	entry_kind = ENTRY_STAGING_GUEST
	staging_context = context
	staging_session = NetManager.session_id()
	synced = false
	_set_phase(Phase.GATHERING)
	reconcile_staging()
	if not synced:
		_request_sync(&"entry")


## A replacement invited into an arranged match's rematch lobby. It holds the arranged
## lobby as its arranged context -- never as a staging one -- joins no ticket and no
## arrangement, and is a guest of whoever hosts the arranged session now.
func start_rematch_guest(context: Variant, arranged_match_id: String, arranged_round: int, owner_key: Dictionary) -> void:
	entry_kind = ENTRY_ARRANGED_REMATCH
	arranged_context = context
	staging_context = null
	staging_session = 0
	match_id = arranged_match_id
	match_round = maxi(arranged_round, 0)
	arranged_owner_key = entity_key(owner_key)
	arranged_owner = false
	host_returned = true
	synced = true
	_set_phase(Phase.REMATCH_GATHERING)


# --- Gathering and the ready transaction -------------------------------------

## Called on every roster or lobby change. The owner starts a search the moment the exact
## admitted group is ready; during a search the same signals are how divergence is caught.
## The staging owner is the lobby's actual native owner; losing that is terminal, because a
## NONE-migration lobby does not stop another member from claiming it.
func on_group_changed() -> void:
	if not is_current() or role != Role.OWNER:
		return
	if phase in [Phase.GATHERING, Phase.FREEZING, Phase.CREATING_TICKET, Phase.SEARCHING] \
			and _staging_owner_lost():
		NetManager._flow_fail(self, TEXT_OWNER_CHANGED)
		return
	if phase == Phase.GATHERING:
		evaluate_ready()
		return
	if phase in [Phase.FREEZING, Phase.CREATING_TICKET, Phase.SEARCHING] and not _group_intact():
		_stop_search(REASON_GROUP_CHANGED, TEXT_GROUP_CHANGED)


## A replicated owner that is someone else. An owner not replicated yet is not a loss.
func _staging_owner_lost() -> bool:
	var party := Services.party()
	if party == null or staging_context == null:
		return false
	var snapshot: Dictionary = party.snapshot(staging_context)
	var owner := entity_key(snapshot.get("owner_key", {}))
	return not owner.is_empty() and not bool(snapshot.get("is_local_owner", false))


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


## A guest joins the ticket the owner published, once per epoch, and only as a member of
## the frozen group for that epoch. The id arrives in the lobby envelope; the owner's phase
## broadcast only says when to look. Joining needs this epoch's budget, which only the
## owner can give -- in its broadcast or a correlated reply -- so without one it asks
## rather than inventing a fresh 600 seconds from a lobby property.
func _reconcile_guest_ticket() -> void:
	if role != Role.GUEST or not is_current() or ticket != null or _joined_epoch == epoch:
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
	if _budget_epoch != epoch or search_deadline_msec <= 0:
		_request_sync(&"ticket")
		return
	# This member joins only with a configuration the service still accepts, and never
	# while a ticket it already let go of could still match it. Either way it cannot join,
	# so it asks the owner to stop -- once per attempt.
	var profile: Dictionary = matchmaking.runtime_profile(mode)
	if not bool(profile.get("ok", false)) or _cleanup_outstanding():
		_refuse_ticket()
		return
	_joined_epoch = epoch
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


## This member cannot join the current attempt's ticket; the owner is asked to stop, once.
func _refuse_ticket() -> void:
	if _refused_epoch != epoch:
		_refused_epoch = epoch
		NetManager._flow_send_report(epoch, Phase.CANCELLING)


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


## Whether any attempt or scoped operation this flow let go of still has native cleanup
## its service owes.
func _cleanup_outstanding() -> bool:
	for index in range(_unresolved_attempts.size() - 1, -1, -1):
		var attempt: Variant = _unresolved_attempts[index]
		if attempt == null or not bool(attempt.cleanup_pending):
			_unresolved_attempts.remove_at(index)
	for index in range(_unresolved_operations.size() - 1, -1, -1):
		var operation: Variant = _unresolved_operations[index]
		if operation == null or not bool(operation.cleanup_pending):
			_unresolved_operations.remove_at(index)
	return not _unresolved_attempts.is_empty() or not _unresolved_operations.is_empty()


## Keeps the handle of a scoped operation whose caller settled while its native completion
## is still owed -- a timeout, usually -- so the lease is not released underneath it. Only
## the handle is kept, and it is polled: nothing here is stored on it.
func _hold_operation(result: Variant) -> void:
	if result == null:
		return
	var operation: Variant = result.operation
	if operation != null and bool(operation.cleanup_pending) and not _unresolved_operations.has(operation):
		_unresolved_operations.append(operation)


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
#
# One idempotent reducer adopts the staging owner's state, whatever carried it: the lobby
# snapshot taken at adoption, a native lobby change, the owner's broadcast -- live or
# buffered -- or the owner's correlated answer to this guest's own state request. Each is
# validated first: the current context and session, the lobby's native owner still being
# the transport host, the envelope schema and the epoch. Within one epoch the state only
# moves forward, so a duplicate or reordered input can neither join a ticket twice, extend
# a budget, nor reopen an older attempt.

## The staging owner's phase broadcast. A lobby message never manufactures a match: that
## comes from this member's own ticket status.
func on_owner_phase(owner_epoch: int, next_phase: int, detail: Dictionary) -> void:
	if not _reduces_staging():
		return
	# Epoch zero is the owner's initial Gathering, which only a correlated reply may
	# establish; an unsolicited broadcast never carries it.
	if owner_epoch <= 0:
		return
	_apply_owner_state(owner_epoch, next_phase, detail, _clock.now_msec())


## The owner's answer to this guest's own state request. Unmatched or stale answers are
## dropped. The budget it carries is anchored to when the request was sent, which can
## only make it shorter than the owner's.
func on_state_reply(owner_epoch: int, next_phase: int, detail: Dictionary) -> void:
	if not _reduces_staging():
		return
	var request_id := int(detail.get("request_id", 0))
	if request_id <= 0 or request_id != _sync_pending_id:
		return
	var anchor := _sync_sent_msec
	_finish_sync()
	if owner_epoch < 0:
		return
	if owner_epoch == 0:
		if next_phase == Phase.GATHERING and epoch == 0:
			_adopt_gathering(0, "", "", false)
		return
	_apply_owner_state(owner_epoch, next_phase, detail, anchor)
	# The lobby may already hold what the answer points at -- a ticket id, most often.
	reconcile_staging()


## Reduces the staging lobby's own state: its search envelope, and whether its native
## owner is still the host this guest's transport answers to.
func reconcile_staging() -> void:
	if not _reduces_staging():
		return
	var party := Services.party()
	if party == null or staging_context == null:
		return
	var snapshot: Dictionary = party.snapshot(staging_context)
	if _staging_owner_moved(party, snapshot):
		NetManager._flow_fail(self, TEXT_OWNER_CHANGED)
		return
	var envelope: Variant = snapshot.get("search_control", {})
	if typeof(envelope) != TYPE_DICTIONARY or not bool((envelope as Dictionary).get("valid", false)):
		return
	var control := envelope as Dictionary
	var control_epoch := int(control.get("epoch", 0))
	if control_epoch <= 0 or control_epoch < epoch:
		return
	match String(control.get("phase", "")):
		ENVELOPE_FREEZING:
			_adopt_freeze(control_epoch)
		ENVELOPE_SEARCHING:
			_adopt_search(control_epoch, -1, 0)
		ENVELOPE_CANCELLING:
			_adopt_cancelling(control_epoch)
		ENVELOPE_GATHERING:
			_adopt_gathering(control_epoch, String(control.get("reason_code", "")),
				String(control.get("reason", "")), false)


func _reduces_staging() -> bool:
	return role == Role.GUEST and is_current() and staging_context != null \
		and phase in [Phase.GATHERING, Phase.FREEZING, Phase.JOINING_TICKET, Phase.SEARCHING,
			Phase.CANCELLING, Phase.RESTORING_STAGING]


func _apply_owner_state(owner_epoch: int, next_phase: int, detail: Dictionary, anchor_msec: int) -> void:
	match next_phase:
		Phase.FREEZING, Phase.CREATING_TICKET:
			_adopt_freeze(owner_epoch)
		Phase.SEARCHING:
			_adopt_search(owner_epoch, int(detail.get("remaining_ms", -1)), anchor_msec)
		Phase.CANCELLING:
			_adopt_cancelling(owner_epoch)
		Phase.RESTORING_STAGING, Phase.GATHERING:
			_adopt_gathering(owner_epoch, String(detail.get("reason_code", "")),
				String(detail.get("reason", "")), next_phase == Phase.RESTORING_STAGING)


## The staging lobby's native owner is no longer the host this guest's transport answers
## to. An owner or host not replicated yet is not a move; a replicated disagreement is.
func _staging_owner_moved(party: PartyService, snapshot: Dictionary) -> bool:
	var owner := entity_key(snapshot.get("owner_key", {}))
	if owner.is_empty():
		return false
	var proof: Dictionary = party.admission_proof(staging_context, NetManager.HOST_PEER_ID)
	if not bool(proof.get("valid", false)):
		return false
	var host := entity_key(proof.get("entity_key", {}))
	return not host.is_empty() and fingerprint(host) != fingerprint(owner)


## Starts reducing a newer attempt, or a later stage of the current one: any ticket held
## for the old state goes back to the service first.
func _begin_stage(new_epoch: int, stage: int) -> void:
	epoch = new_epoch
	_stage = stage
	_retire_ticket()
	cancel_unresolved = false
	synced = true


func _adopt_freeze(new_epoch: int) -> void:
	if new_epoch < epoch or (new_epoch == epoch and _stage >= _STAGE_FROZEN):
		return
	_begin_stage(new_epoch, _STAGE_FROZEN)
	_clear_reason()
	_set_phase(Phase.FREEZING)
	if _acked_epoch != epoch:
		_acked_epoch = epoch
		NetManager._flow_send_report(epoch, Phase.FREEZING)


func _adopt_search(new_epoch: int, remaining_ms: int, anchor_msec: int) -> void:
	if new_epoch < epoch:
		return
	if new_epoch > epoch:
		# The freeze itself was missed; the owner is past acknowledgements by now.
		_begin_stage(new_epoch, _STAGE_NONE)
		_clear_reason()
	if _stage > _STAGE_SEARCHING:
		return
	if remaining_ms >= 0:
		_anchor_budget(anchor_msec, remaining_ms)
	if _stage < _STAGE_SEARCHING:
		_stage = _STAGE_SEARCHING
		synced = true
		if ticket == null:
			_set_phase(Phase.JOINING_TICKET)
	_reconcile_guest_ticket()


func _adopt_cancelling(new_epoch: int) -> void:
	if new_epoch != epoch or _stage == _STAGE_NONE or _stage >= _STAGE_CANCELLING:
		return
	_stage = _STAGE_CANCELLING
	_set_phase(Phase.CANCELLING)


## A restoration, or a restored group. The retained outcome travels with it, so a guest
## that never obtained a ticket -- or missed every message of the attempt -- is restored
## with the reason too.
func _adopt_gathering(new_epoch: int, code: String, text: String, restoring: bool) -> void:
	var stage: int = _STAGE_RESTORING if restoring else _STAGE_RESTORED
	if new_epoch < epoch or (new_epoch == epoch and _stage >= stage):
		return
	_begin_stage(new_epoch, stage)
	var shown := text
	if shown.is_empty() and not code.is_empty():
		shown = MatchmakingService.reason_for_code(code)
	if not shown.is_empty() and (reason_epoch != epoch or reason != shown):
		_record_reason(StringName(code), shown)
	_set_phase(Phase.RESTORING_STAGING if restoring else Phase.GATHERING)


## The owner's remaining budget, anchored locally. A later copy of the same epoch's budget
## can only shorten it; a new epoch replaces it.
func _anchor_budget(anchor_msec: int, remaining_ms: int) -> void:
	var candidate := anchor_msec + maxi(remaining_ms, 0)
	if _budget_epoch != epoch or search_deadline_msec <= 0:
		search_deadline_msec = candidate
		_budget_epoch = epoch
	else:
		search_deadline_msec = mini(search_deadline_msec, candidate)


## Asks the owner for its current state: one request in flight at a time, answered or
## abandoned within 15 seconds. Not a heartbeat -- it is sent on entry, and when a ticket
## appears without a budget to join it with.
func _request_sync(purpose: StringName) -> void:
	if role != Role.GUEST or not is_current() or _sync_pending_id != 0:
		return
	_sync_request_id += 1
	var request_id := _sync_request_id
	if not NetManager._flow_request_state(self, request_id, epoch):
		return
	_sync_pending_id = request_id
	_sync_sent_msec = _clock.now_msec()
	_sync_purpose = purpose
	_sync_alarm = _clock.alarm_after(SYNC_SECONDS, _on_sync_timeout.bind(request_id))


func _on_sync_timeout(request_id: int) -> void:
	if request_id != _sync_pending_id:
		return
	var purpose := _sync_purpose
	_finish_sync()
	if not is_current():
		return
	if not synced:
		# An entering guest never exposed Ready; without the owner's state it has no group.
		NetManager._flow_fail(self, TEXT_HOST_SILENT)
	elif purpose == &"ticket" and phase in [Phase.JOINING_TICKET, Phase.SEARCHING] and ticket == null:
		_refuse_ticket()


func _finish_sync() -> void:
	if _sync_alarm != null:
		_sync_alarm.cancel()
	_sync_alarm = null
	_sync_pending_id = 0
	_sync_purpose = &""


## What the owner would broadcast for its current state, for a guest that asked.
func replay_state() -> Dictionary:
	var reported := phase
	var detail := {}
	match phase:
		Phase.CREATING_TICKET:
			reported = Phase.FREEZING
		Phase.SEARCHING:
			detail["remaining_ms"] = maxi(0, search_deadline_msec - _clock.now_msec())
		Phase.RESTORING_STAGING, Phase.GATHERING:
			if not reason.is_empty():
				detail["reason_code"] = String(reason_code)
				detail["reason"] = reason
	return {"epoch": epoch, "phase": int(reported), "detail": detail}


## Lobby state moved: a newly replicated envelope may carry the ticket id this guest was
## waiting for, any member change is the owner's cue to re-check its group, and the
## arranged lobby says whether its host has returned.
func on_lobby_changed(context: Variant) -> void:
	if not is_current() or context == null:
		return
	if context == staging_context:
		if role == Role.GUEST:
			reconcile_staging()
		else:
			on_group_changed()
	elif context == arranged_context:
		reconcile_arranged()


# --- Matched handoff ------------------------------------------------------------
#
# Two barriers, in this order. The cohort barrier: the match's full member count connected
# in the arranged lobby, every member compatible and carrying this match's id, this
# member's own premade among them, and every member's acknowledgement -- published only
# after its own arranged join, once it had armed its old-transport-loss handling. Only then
# does the actual arranged owner lock the lobby, and only a confirmed lock over the same set
# and owner seals the handoff. Nobody tears a transport down before the seal, so no staging
# host leaves Party while a member could still take that for a failure, and a later matched
# caller is never locked out by an early lock.

## A match. From here every failure is terminal: a partly dispersed group cannot be put
## back together, so the players are returned to the menu with the reason.
func _on_matched(attempt: Variant) -> void:
	match_id = String(attempt.match_id)
	arrangement = String(attempt.arrangement)
	# Copied first; then the attempt goes back to the service. A matched ticket is natively
	# terminal, so retiring it cancels nothing.
	_retire_ticket()
	_finish_sync()
	_set_phase(Phase.MATCHED)
	if role == Role.OWNER and staging_context != null:
		Services.party().post_context_update(staging_context, {PartyService.SEARCH_CONTROL_KEY: _envelope(ENVELOPE_MATCHED, "")}, {}, {}, _clock.deadline_after(ARRANGED_JOIN_SECONDS))
	_join_arranged()


func _join_arranged() -> void:
	_set_phase(Phase.JOINING_ARRANGED)
	phase_deadline_msec = _clock.deadline_after(ARRANGED_JOIN_SECONDS)
	# Revalidated now rather than trusted from the start: the arranged lobby is configured
	# from the mode's real player count, which must still be the queue's four.
	var matchmaking: MatchmakingService = Services.matchmaking() if Services != null else null
	var profile: Dictionary = matchmaking.runtime_profile(mode) if matchmaking != null else {}
	if not bool(profile.get("ok", false)):
		NetManager._flow_fail(self, _profile_text(profile))
		return
	if int(profile.get("player_count", 0)) != match_size:
		NetManager._flow_fail(self, TEXT_PROFILE_CHANGED)
		return
	var party := Services.party()
	var properties := {
		MatchmakingService.PROTOCOL_MEMBER_KEY: NRProtocol.version_string(),
		PartyService.MATCH_ID_MEMBER_KEY: match_id,
		PartyService.MATCH_ORIGIN_MEMBER_KEY: PartyService.MATCH_ORIGIN_VALUE,
	}
	var joined: PartyService.PartyResult = await party.join_arranged(
		Services.playfab_user(), arrangement, properties, match_size, account_generation, id, phase_deadline_msec)
	_hold_operation(joined)
	if not is_current():
		if joined != null and joined.context != null:
			await _release_context(joined.context)
		return
	if joined == null or not joined.ok() or joined.context == null:
		NetManager._flow_fail(self, _result_reason(joined, "The match could not be joined."))
		return
	arranged_context = joined.context
	arranged_owner_key = {}
	arranged_owner = false
	var owner := entity_key(joined.owner_key)
	if not owner.is_empty():
		_pin_arranged_owner(party, owner)
	_seen_connected.clear()
	await _arm_handoff()


## Pins the first valid native owner of the arranged lobby. Its creator of the fresh
## network is whoever this is -- staging owner or staging guest alike.
func _pin_arranged_owner(party: PartyService, owner: Dictionary) -> void:
	arranged_owner_key = owner.duplicate()
	var local_key := entity_key(party.local_entity_key(arranged_context))
	arranged_owner = not local_key.is_empty() and fingerprint(owner) == fingerprint(local_key)


## Arms intentional old-transport loss handling before announcing readiness, then waits for
## the cohort barrier, the owner's lock and the seal. Only then does anyone deliberately
## retire the staging transport.
func _arm_handoff() -> void:
	# The cohort, transport and admission budget: 90 seconds from this member's own
	# arranged success, separate from the 30 the join itself had.
	phase_deadline_msec = _clock.deadline_after(HANDOFF_SECONDS)
	# Armed before the acknowledgement exists: once another member can read it, this
	# member already treats its old staging transport going away as expected.
	armed = true
	_set_phase(Phase.ARMING_HANDOFF)
	var party := Services.party()
	var ready_post: PartyService.PartyResult = await party.post_context_update(
		arranged_context, {}, {}, {PartyService.HANDOFF_READY_MEMBER_KEY: match_id}, phase_deadline_msec)
	_hold_operation(ready_post)
	if not _arming_current():
		return
	if ready_post == null or not ready_post.ok():
		NetManager._flow_fail(self, _result_reason(ready_post, "The match could not be prepared."))
		return
	var cohort_ready: bool = await _await_cohort(false)
	if not cohort_ready:
		return
	if arranged_owner:
		var locked: PartyService.PartyResult = await party.set_context_locked(arranged_context, true, phase_deadline_msec)
		_hold_operation(locked)
		if not _arming_current():
			return
		if locked == null or not locked.ok():
			NetManager._flow_fail(self, _result_reason(locked, TEXT_MATCH_UNSEALED))
			return
		# Rechecked after the await: what was sealed must be the set and owner proven.
		var verdict := _cohort_verdict(false)
		if verdict != &"ready":
			NetManager._flow_fail(self, _cohort_failure_text(verdict))
			return
	else:
		var sealed: bool = await _await_cohort(true)
		if not sealed:
			return
	pinned_keys = _cohort_keys()
	await switch_transport()


func _arming_current() -> bool:
	return is_current() and phase == Phase.ARMING_HANDOFF


## Waits, within the handoff budget, for the cohort barrier -- and with `sealed`, the
## owner's confirmed lock on top of it. Incomplete replication waits; a known loss, a
## changed owner or an incompatible value is final at once.
func _await_cohort(sealed: bool) -> bool:
	var verdict := _cohort_verdict(sealed)
	while verdict == &"waiting":
		if _clock.has_expired(phase_deadline_msec):
			NetManager._flow_fail(self, TEXT_MATCH_LATE)
			return false
		await _clock.sleep_seconds(minf(POLL_SECONDS, _clock.remaining_seconds(phase_deadline_msec)))
		if not _arming_current():
			return false
		verdict = _cohort_verdict(sealed)
	if verdict != &"ready":
		NetManager._flow_fail(self, _cohort_failure_text(verdict))
		return false
	return true


## The cohort barrier, and with `sealed` the confirmed lock too.
##
## Ready: the arranged lobby holds exactly this match's member count, every member
## connected, compatible and carrying this match's id, every acknowledgement published,
## this member's own frozen premade among them, and the pinned owner still the owner and a
## member. What has not replicated yet is waiting; a member seen and then gone, a changed
## owner, a wrong capacity or an incompatible value is final.
func _cohort_verdict(sealed: bool) -> StringName:
	var party := Services.party()
	if party == null or arranged_context == null:
		return &"lost"
	var snapshot: Dictionary = party.snapshot(arranged_context)
	if bool(snapshot.get("disconnected", false)):
		return &"lost"
	var owner := entity_key(snapshot.get("owner_key", {}))
	if not owner.is_empty():
		if arranged_owner_key.is_empty():
			_pin_arranged_owner(party, owner)
		elif fingerprint(owner) != fingerprint(arranged_owner_key):
			return &"owner_changed"
	if int(snapshot.get("max_members", match_size)) != match_size \
			or int(snapshot.get("expected_count", match_size)) != match_size:
		return &"incompatible"
	var raw_members: Variant = snapshot.get("members", [])
	if typeof(raw_members) != TYPE_ARRAY:
		return &"waiting"
	var present := {}
	var incomplete := owner.is_empty()
	for raw: Variant in raw_members as Array:
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var member := raw as Dictionary
		var key := entity_key(member.get("key", {}))
		if key.is_empty():
			continue
		var mark := fingerprint(key)
		present[mark] = key
		if not bool(member.get("connected", false)):
			if _seen_connected.has(mark):
				return &"member_lost"
			incomplete = true
			continue
		_seen_connected[mark] = true
		var raw_properties: Variant = member.get("properties", {})
		var properties: Dictionary = raw_properties as Dictionary if typeof(raw_properties) == TYPE_DICTIONARY else {}
		var protocol := String(properties.get(MatchmakingService.PROTOCOL_MEMBER_KEY, ""))
		var member_match := String(properties.get(PartyService.MATCH_ID_MEMBER_KEY, ""))
		if (not protocol.is_empty() and not NRProtocol.is_compatible(protocol)) \
				or (not member_match.is_empty() and member_match != match_id):
			return &"incompatible"
		if protocol.is_empty() or member_match.is_empty() \
				or String(properties.get(PartyService.HANDOFF_READY_MEMBER_KEY, "")) != match_id:
			incomplete = true
	for seen: Variant in _seen_connected:
		if not present.has(seen):
			return &"member_lost"
	if present.size() > match_size:
		return &"incompatible"
	if present.size() < match_size or incomplete:
		return &"waiting"
	if not present.has(fingerprint(arranged_owner_key)):
		return &"owner_changed"
	for key: Dictionary in frozen_keys:
		if not present.has(fingerprint(key)):
			return &"premade_missing"
	if sealed and not bool(snapshot.get("membership_locked", false)):
		return &"waiting"
	return &"ready"


## The connected arranged members' full keys, in fingerprint order: the set the initial
## start admits exactly.
func _cohort_keys() -> Array[Dictionary]:
	var keys: Array[Dictionary] = []
	var party := Services.party()
	if party == null or arranged_context == null:
		return keys
	var snapshot: Dictionary = party.snapshot(arranged_context)
	var raw_members: Variant = snapshot.get("members", [])
	if typeof(raw_members) != TYPE_ARRAY:
		return keys
	for raw: Variant in raw_members as Array:
		if typeof(raw) != TYPE_DICTIONARY or not bool((raw as Dictionary).get("connected", false)):
			continue
		var key := entity_key((raw as Dictionary).get("key", {}))
		if not key.is_empty():
			keys.append(key)
	keys.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return fingerprint(a) < fingerprint(b))
	return keys


static func _cohort_failure_text(verdict: StringName) -> String:
	match verdict:
		&"owner_changed":
			return TEXT_MATCH_HOST_CHANGED
		&"incompatible":
			return TEXT_MATCH_INCOMPATIBLE
		&"member_lost":
			return TEXT_MATCH_MEMBER_LOST
		&"premade_missing":
			return TEXT_MATCH_MISMATCH
		&"lost":
			return TEXT_ARRANGED_CHANGED
	return TEXT_MATCH_LATE


## The arranged owner's own member protocol is this build's, read from the lobby before
## any Party entry rather than discovered through RPCs that depend on it.
func _arranged_owner_compatible(party: PartyService) -> bool:
	var snapshot: Dictionary = party.snapshot(arranged_context)
	var raw_members: Variant = snapshot.get("members", [])
	if typeof(raw_members) != TYPE_ARRAY or arranged_owner_key.is_empty():
		return false
	for raw: Variant in raw_members as Array:
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var member := raw as Dictionary
		if fingerprint(entity_key(member.get("key", {}))) != fingerprint(arranged_owner_key):
			continue
		var raw_properties: Variant = member.get("properties", {})
		if typeof(raw_properties) != TYPE_DICTIONARY:
			return false
		return NRProtocol.is_compatible(String((raw_properties as Dictionary).get(MatchmakingService.PROTOCOL_MEMBER_KEY, "")))
	return false


## An involuntary loss of the old staging transport after arming. The local session ends
## now, but the replacement network is still prepared only once the seal is reached.
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
	# The old transport is left before the replacement exists, and only a current OK answer
	# counts: a replacement is never created or published on the assumption that a failed or
	# unanswered old-network leave succeeded.
	if staging_context != null:
		var left: PartyService.PartyResult = await _owned_leave(staging_context, true, phase_deadline_msec)
		if not is_current():
			return
		if left == null or not left.ok():
			NetManager._flow_fail(self, _result_reason(left, TEXT_OLD_NETWORK_NOT_LEFT))
			return
	# The platform reset cleared the previous session's communications verdict; it is
	# resolved again before any network exists, exactly as hosting and joining do.
	await NetManager._platform.apply_chat_privilege(_handoff_still_current)
	if not is_current():
		return
	var user: Variant = Services.playfab_user()
	var prepared: PartyService.PartyResult = null
	if arranged_owner:
		var slice := mini(phase_deadline_msec, _clock.deadline_after(OWNER_TRANSPORT_SECONDS))
		prepared = await party.prepare_transport(arranged_context, user, slice)
	else:
		if not _arranged_owner_compatible(party):
			NetManager._flow_fail(self, TEXT_MATCH_INCOMPATIBLE)
			return
		prepared = await party.join_transport(arranged_context, user, phase_deadline_msec)
	_hold_operation(prepared)
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
		NetManager._flow_arm_cohort_deadline(self)
		# The descriptor goes out last, with the round's owner control in the same checked
		# batch, into a lobby already locked with exactly the cohort inside.
		var published: PartyService.PartyResult = await party.publish_transport(
			arranged_context, permit, PartyService.ARRANGED_PHASE_BOOTSTRAP,
			PartyService.encode_arranged_control(match_id, match_round, PartyService.ARRANGED_PHASE_BOOTSTRAP),
			{}, phase_deadline_msec)
		_hold_operation(published)
		if not is_current():
			return
		if published == null or not published.ok():
			NetManager._flow_fail(self, _result_reason(published, "The match could not be opened."))
			return
		await _retire_staging()
		return
	await _drive_admission()


func _handoff_still_current() -> bool:
	return is_current() and not _clock.has_expired(phase_deadline_msec)


## Retires this member's old staging lobby as a checked, bounded operation.
##
## The group's staging owner leaves last. PlayFab clears a lobby's owner field when its
## owner leaves, and every member still inside would rightly read that as the group's owner
## lost. So a staging guest leaves at once, and the staging owner first waits for every
## other connected member to go -- whatever its arranged role. That wait is preparation,
## not retirement: the lobby is still the group's, so an unexpected loss meanwhile ends the
## flow, and a wait that outlives the handoff budget fails rather than leaving anyway.
##
## Retirement begins at the owned leave_lobby call itself -- `staging_retiring` is set
## immediately before it, with no await between -- and PartyService stops watching the
## lobby before its native leave. It is complete only when that call returned OK on the
## current flow and PartyService reports the old context quiescent; then this member tells
## the arranged lobby so. Anything short of that ends the initial handoff first, and the
## captured cleanup stays owned for the ordinary terminal recovery.
func _retire_staging() -> bool:
	var context: Variant = staging_context
	if context == null:
		return staging_retired
	var party := Services.party()
	if party == null:
		NetManager._flow_fail(self, TEXT_GROUP_NOT_RETIRED)
		return false
	var deadline := phase_deadline_msec
	if role == Role.OWNER:
		while _staging_others_connected(party, context):
			if _clock.has_expired(deadline):
				NetManager._flow_fail(self, TEXT_GROUP_NOT_RETIRED)
				return false
			await _clock.sleep_seconds(minf(POLL_SECONDS, _clock.remaining_seconds(deadline)))
			if not is_current() or staging_context != context:
				return false
		if not bool(party.snapshot(context).get("is_local_owner", false)):
			NetManager._flow_fail(self, TEXT_OWNER_CHANGED)
			return false
	if not is_current() or staging_context != context:
		return false
	if _clock.has_expired(deadline):
		NetManager._flow_fail(self, TEXT_GROUP_NOT_RETIRED)
		return false
	staging_retiring = true
	var left: PartyService.PartyResult = await _owned_leave(context, false, deadline)
	if not is_current():
		return false
	if left == null or not left.ok():
		NetManager._flow_fail(self, _result_reason(left, TEXT_GROUP_NOT_RETIRED))
		return false
	while not party.context_is_quiescent(context):
		if _clock.has_expired(deadline):
			NetManager._flow_fail(self, TEXT_GROUP_NOT_RETIRED)
			return false
		await _clock.sleep_seconds(minf(POLL_SECONDS, _clock.remaining_seconds(deadline)))
		if not is_current():
			return false
	staging_context = null
	staging_retired = true
	return await _report_staging_retired()


## Writes this member's own `nr_staging_retired` marker -- this match's id -- into the
## arranged lobby, through the checked member update. A failed post fails the handoff: the
## arranged owner would otherwise wait for a marker that is never coming.
func _report_staging_retired() -> bool:
	var party := Services.party()
	if party == null or arranged_context == null:
		NetManager._flow_fail(self, TEXT_GROUP_NOT_RETIRED)
		return false
	var posted: PartyService.PartyResult = await party.post_context_update(
		arranged_context, {}, {}, {PartyService.STAGING_RETIRED_MEMBER_KEY: match_id}, phase_deadline_msec)
	_hold_operation(posted)
	if not is_current():
		return false
	if posted == null or not posted.ok():
		NetManager._flow_fail(self, _result_reason(posted, TEXT_GROUP_NOT_RETIRED))
		return false
	retirement_reported = true
	NetManager._flow_staging_retired(self)
	return true


## One owned leave of the captured staging `context` -- its transport or its lobby -- on
## `deadline_msec`. An alarm ends the wait if the native leave never answers; its late
## answer is still the service's to clean up. Returns the typed result, or null when the
## deadline or this flow's retirement came first.
func _owned_leave(context: Variant, transport: bool, deadline_msec: int) -> PartyService.PartyResult:
	_settle_owned_leave(null)
	_owned_leave_token += 1
	var token := _owned_leave_token
	_owned_leave_pending = true
	_owned_leave_alarm = _clock.alarm_at(deadline_msec, _on_owned_leave_deadline.bind(token))
	_run_owned_leave(context, transport, token)
	if _owned_leave_pending:
		await _owned_leave_settled
	var result: PartyService.PartyResult = _owned_leave_result as PartyService.PartyResult
	_owned_leave_result = null
	return result


func _run_owned_leave(context: Variant, transport: bool, token: int) -> void:
	var party := Services.party()
	var left: PartyService.PartyResult = null
	if party != null and context != null:
		if transport:
			left = await party.leave_transport(context)
		else:
			left = await party.leave_lobby(context)
	if token == _owned_leave_token and _owned_leave_pending:
		_settle_owned_leave(left)


func _on_owned_leave_deadline(token: int) -> void:
	if token == _owned_leave_token and _owned_leave_pending:
		_settle_owned_leave(null)


## Ends the owned leave in flight with `result`, once: the alarm is dropped and the waiting
## step resumed. Harmless when nothing is in flight.
func _settle_owned_leave(result: Variant) -> void:
	if _owned_leave_alarm != null:
		_owned_leave_alarm.cancel()
	_owned_leave_alarm = null
	if not _owned_leave_pending:
		return
	_owned_leave_pending = false
	_owned_leave_result = result
	_owned_leave_settled.emit()


## Whether any other member is still connected in the staging lobby.
func _staging_others_connected(party: PartyService, context: Variant) -> bool:
	if party == null or context == null:
		return false
	var local := entity_key(party.local_entity_key(context))
	if local.is_empty():
		return false
	var snapshot: Dictionary = party.snapshot(context)
	for raw: Variant in snapshot.get("members", []):
		if typeof(raw) != TYPE_DICTIONARY or not bool((raw as Dictionary).get("connected", false)):
			continue
		var key := entity_key((raw as Dictionary).get("key", {}))
		if not key.is_empty() and fingerprint(key) != fingerprint(local):
			return true
	return false


## Installed by NetManager inside the guest's activation block, immediately after the
## new peer binds. No request of any kind spans the transport swap.
func install_admission_request(request: JoinRequest) -> void:
	admission_request = request


## Waits for the arranged owner to admit this guest, on this phase's own deadline rather
## than the 45-second ordinary join budget, and never through the ordinary join driver's
## global teardown. Once admitted, the old staging lobby is retired.
func _drive_admission() -> void:
	var request := admission_request
	while request != null and request.is_pending():
		if not is_current() or request != admission_request:
			return
		if request.admitted:
			NetManager._consume_flow_admission(self, request)
			if is_current() and request.succeeded():
				await _retire_staging()
			return
		if _clock.has_expired(phase_deadline_msec):
			NetManager._flow_fail(self, "The match could not be joined in time.")
			return
		await _clock.sleep_seconds(minf(POLL_SECONDS, _clock.remaining_seconds(phase_deadline_msec)))


# --- Initial start, gameplay and rematches --------------------------------------

## The arranged host has admitted exactly the sealed four, so the start is committed: the
## lobby's lock is confirmed again and the set and owner rechecked before NetManager starts
## the match through the ordinary STARTING path.
func begin_initial_commit(deadline_msec: int) -> void:
	if not is_current() or not arranged_owner or phase != Phase.ADMITTING_COHORT:
		return
	_set_phase(Phase.COMMITTING_START)
	var party := Services.party()
	var locked: PartyService.PartyResult = await party.set_context_locked(arranged_context, true, deadline_msec)
	_hold_operation(locked)
	if not is_current() or phase != Phase.COMMITTING_START:
		return
	if locked == null or not locked.ok():
		NetManager._flow_fail(self, _result_reason(locked, TEXT_MATCH_UNSEALED))
		return
	var verdict := _cohort_verdict(false)
	if verdict != &"ready":
		NetManager._flow_fail(self, _cohort_failure_text(verdict))
		return
	NetManager._flow_start_initial_match(self)


## NetManager's match state moved. STARTING commits an initial start or begins a hosted
## rematch round; RUNNING is where the first match's exact-cohort requirement ends.
func on_match_state(state: NRTypes.MatchState) -> void:
	if not is_current():
		return
	if NRTypes.has_match_state(state, NRTypes.MatchState.STARTING):
		if phase == Phase.ADMITTING_COHORT:
			_set_phase(Phase.COMMITTING_START)
		elif phase == Phase.REMATCH_GATHERING:
			_set_phase(Phase.GAMEPLAY)
	elif NRTypes.has_match_state(state, NRTypes.MatchState.RUNNING):
		if phase == Phase.COMMITTING_START:
			_set_phase(Phase.GAMEPLAY)


## The match ended and this player is back in the lobby. The arranged host opens the next
## round -- its reopen publishes the rematch phase and confirms the unlock before it takes
## anyone -- while a guest waits, at most 45 seconds, for the host to have done so, and may
## leave at any moment.
func on_returned_to_lobby() -> void:
	if not is_current() or phase != Phase.GAMEPLAY or arranged_context == null:
		return
	if arranged_owner:
		match_round += 1
		host_returned = true
		_set_phase(Phase.REMATCH_GATHERING)
		return
	host_returned = false
	changed.emit()
	reconcile_arranged()
	if not host_returned:
		NetManager._flow_wait_for_host_return(self)


## Reduces the arranged lobby: its native owner, and the round and phase the owner
## publishes. The owner leaving or changing is terminal in every arranged phase.
func reconcile_arranged() -> void:
	if not is_current() or arranged_context == null:
		return
	if phase not in [Phase.ADMITTING_COHORT, Phase.COMMITTING_START, Phase.GAMEPLAY, Phase.REMATCH_GATHERING]:
		return
	var party := Services.party()
	if party == null:
		return
	var snapshot: Dictionary = party.snapshot(arranged_context)
	var owner := entity_key(snapshot.get("owner_key", {}))
	if not owner.is_empty() and not arranged_owner_key.is_empty() \
			and fingerprint(owner) != fingerprint(arranged_owner_key):
		NetManager._flow_fail(self, TEXT_MATCH_HOST_CHANGED)
		return
	if arranged_owner:
		return
	var raw_properties: Variant = snapshot.get("properties", {})
	if typeof(raw_properties) != TYPE_DICTIONARY:
		return
	var control: Dictionary = PartyService.decode_arranged_control(raw_properties as Dictionary)
	if not bool(control.get("valid", false)):
		return
	if String(control.get("match_id", "")) != match_id:
		NetManager._flow_fail(self, TEXT_ARRANGED_CHANGED)
		return
	var control_round := int(control.get("round", 0))
	if control_round < match_round:
		return
	if String(control.get("phase", "")) != PartyService.ARRANGED_PHASE_REMATCH \
			or phase not in [Phase.GAMEPLAY, Phase.REMATCH_GATHERING]:
		return
	match_round = control_round
	if host_returned and phase == Phase.REMATCH_GATHERING:
		return
	host_returned = true
	_set_phase(Phase.REMATCH_GATHERING)
	changed.emit()
	NetManager._flow_host_returned(self)


## The arranged host's lobby admission for a rematch round, as one checked transaction:
## the owner-published phase first -- so an invite read after it is admitted or refused on
## the right side -- then the lock. Reopening publishes the rematch phase and confirms the
## unlock; closing publishes gameplay and confirms the lock. The local gate is NetManager's.
func set_rematch_open(open: bool) -> bool:
	last_admission_error = ""
	if not is_current() or not arranged_owner or arranged_context == null or phase != Phase.REMATCH_GATHERING:
		last_admission_error = "The match can only be reopened between rounds."
		return false
	var party := Services.party()
	var deadline := _clock.deadline_after(RESTORE_SECONDS)
	var target: String = PartyService.ARRANGED_PHASE_REMATCH if open else PartyService.ARRANGED_PHASE_GAMEPLAY
	var posted: PartyService.PartyResult = await party.post_context_update(
		arranged_context, PartyService.encode_arranged_control(match_id, match_round, target), {}, {}, deadline)
	_hold_operation(posted)
	if not is_current() or phase != Phase.REMATCH_GATHERING:
		last_admission_error = "The match has ended."
		return false
	if posted == null or not posted.ok():
		last_admission_error = _result_reason(posted, "The match could not be updated.")
		return false
	var locked: PartyService.PartyResult = await party.set_context_locked(arranged_context, not open, deadline)
	_hold_operation(locked)
	if not is_current() or phase != Phase.REMATCH_GATHERING:
		last_admission_error = "The match has ended."
		return false
	if locked == null or not locked.ok():
		last_admission_error = _result_reason(locked, "The match could not be updated.")
		return false
	return true


## Whether this instance hosts the flow's arranged session: the arranged native owner,
## which created the fresh network, whatever its premade role was.
func hosts_arranged_session() -> bool:
	return arranged_owner and in_arranged_session()


## Whether the bound session is the flow's arranged one.
func in_arranged_session() -> bool:
	return arranged_context != null and phase in [
		Phase.ADMITTING_COHORT, Phase.COMMITTING_START, Phase.GAMEPLAY, Phase.REMATCH_GATHERING]


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
	_finish_sync()
	# A retired flow waits on nothing: an owned staging leave still in flight resumes its
	# waiter now, and its late answer stays the service's to clean up.
	_settle_owned_leave(null)
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
	_finish_sync()
	_retire_ticket()
	var party: PartyService = Services.party() if Services != null else null
	if party != null:
		for context: Variant in held_contexts():
			var left_lobby: PartyService.PartyResult = await party.leave_lobby(context)
			_hold_operation(left_lobby)
			var left_transport: PartyService.PartyResult = await party.leave_transport(context)
			_hold_operation(left_transport)
	# A retired ticket or scoped operation the service has not finished with could still
	# act for this player, so the lease -- and with it every online entry -- is held until
	# the service reports it safe, for as long as this is the signed-in account. The wait is
	# shown as quarantine after the cancellation grace; quit and account teardown bound it
	# from outside.
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
