class_name MatchmakingFlow
extends RefCounted

## One matchmaking attempt, from the staging lobby a group gathers in to the arranged
## match the service puts them in -- or, for a full group of four, to a private match played
## in that same lobby, with no search at all.
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
## player whose fresh network makes it Godot peer 1, whichever premade role it had. A private
## match keeps the group's own lobby, network and owner throughout.
##
## Not an autoload. It is created per attempt and dropped once its native cleanup has
## settled, which is what releases the lease.

## Raised whenever the phase, the durable outcome or anything the lobby draws changes.
signal changed()
## Raised once when the owned staging leave in flight answers or its deadline wins.
signal _owned_leave_settled()
## Raised once when release_native() has finished, for the callers that joined it.
signal native_release_done()

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
	# Appended, never inserted: these values cross the wire in the phase messages.
	PRIVATE_PREPARING,
}

enum Role { OWNER, GUEST }

## Staging lobby, staging and arranged Party networks, activity and roster all hold four. A
## match itself starts with the players who have arrived -- two, three or four -- and never
## waits for a fixed count; see `selected_keys`. A full group of four never searches: the
## queue takes no ticket that is already at its maximum, so once all four are ready they
## start a private match in the same lobby instead (see PRIVATE_PREPARING).
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
## A full group's private start: its freeze, lock, every member's acknowledgement and the
## checked switch of the same lobby to a private match, on one budget that never renews.
const PRIVATE_PREPARE_SECONDS := 15.0
const POLL_SECONDS := 0.1

## Search-control envelope phases. PartyService owns the encoding; these are the values.
const ENVELOPE_GATHERING := "gathering"
const ENVELOPE_FREEZING := "freezing"
const ENVELOPE_SEARCHING := "searching"
const ENVELOPE_CANCELLING := "cancelling"
const ENVELOPE_MATCHED := "matched"
const ENVELOPE_PRIVATE := "private"

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
const REASON_PRIVATE_GROUP_CHANGED := &"private_group_changed"
const REASON_PRIVATE_FAILED := &"private_start_failed"
const REASON_PRIVATE_CANCELLED := &"private_start_cancelled"

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
const TEXT_GROUP_HOST_LEFT := "The group host left or is no longer available, so the group was closed."
const TEXT_MATCH_ABANDONED := "A match was found just as the search stopped, so the group was closed."
const TEXT_MATCH_ALREADY_STARTED := "This match is already starting or in progress. Return to Matchmaking to search again."
const TEXT_MATCH_JOIN_UNPROVEN := "This match could not be joined. It may already have started. Return to Matchmaking to search again."
const TEXT_MATCH_FULL := "This match is already full. Return to Matchmaking to search again."
const TEXT_MATCH_HOST_LEFT := "The match host left before the match began."
const TEXT_GROUP_SEARCHING := "That matchmaking group has already started searching."
const TEXT_PRIVATE_GROUP_CHANGED := "The group changed, so the private match was not started. Press Ready to try again."
const TEXT_PRIVATE_FAILED := "The private match could not be started. Press Ready to try again."
const TEXT_PRIVATE_CANCELLED := "The private match was cancelled."
const TEXT_PRIVATE_NOT_STARTED := "The private match could not be started."

## Phases in which a ticket can still be searching, stopping or being let go of: a native
## match on a ticket this group already released is judged against these.
const _PRE_MATCH_PHASES := [
	Phase.GATHERING, Phase.FREEZING, Phase.CREATING_TICKET, Phase.JOINING_TICKET,
	Phase.SEARCHING, Phase.CANCELLING, Phase.RESTORING_STAGING,
]

## How a flow began. The staging role above is the ticket role only; who hosts an
## arranged session is `arranged_owner`, whichever premade role a player had.
const ENTRY_STAGING_OWNER := &"staging_owner"
const ENTRY_STAGING_GUEST := &"staging_guest"
const ENTRY_ARRANGED_REMATCH := &"arranged_rematch"
const ENTRY_PRIVATE_REMATCH := &"private_rematch"

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
## Party's reason, once its recovery of the cleanup this retired flow still holds the lease
## for has failed: that cleanup cannot finish before the title restarts. Kept apart from
## `reason`, which stays the outcome that ended the flow.
var cleanup_error := ""
## Set once this member's arranged join has succeeded and a staging-transport loss is
## expected rather than fatal. See NetManager._on_server_disconnected(). It says nothing
## about the staging *lobby*: arming does not prove this member's premade has arrived, so a
## lost lobby still ends the group until the flow's own owned leave of it has begun.
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
## owner starts the first match only once every member it starts with carries it.
var retirement_reported := false
var admission_request: JoinRequest = null
var search_deadline_msec := 0
var phase_deadline_msec := 0
var retired := false
var native_release_started := false
var native_release_finished := false
## Players the staging and arranged sessions hold, as the service validated it from the mode's
## real configuration when the flow started. A ceiling, never the number a match waits for.
var capacity := CAPACITY
## How this flow began; see ENTRY_*.
var entry_kind: StringName = ENTRY_STAGING_OWNER
## The owner's 45-second establishment budget, taken before its first awaited work.
var entry_deadline_msec := 0
## A guest has adopted the owner's current state -- from a correlated reply, a validated
## envelope or a broadcast -- and may expose Ready. The owner is its own authority.
var synced := false
## The arranged session's round: 0 for the matched game, then one more at each return.
var match_round := 0
## The players the first match starts with: chosen by the arranged host from the members
## who had arrived and were ready when it started, two to four of them, and published in the
## arranged lobby. Not the service's complete match -- later arrivals are simply not in it.
## Empty until the host selects it, and fixed from then until the first match runs.
var selected_keys: Array[Dictionary] = []
## The host's start attempt for the first match: 0 while players are still arriving, 1 once
## the set above is chosen. Published with the set so a late or stale view is told apart.
var start_generation := 0
## The arranged owner has returned to the lobby for a rematch; a guest waiting for it is
## told so by the arranged lobby, not by a message.
var host_returned := false
var last_admission_error := ""
## The play session -- the lobby, network and roster the games are played in until the group
## leaves -- once there is one: its origin (PartyService.PLAY_ORIGIN_MATCHMADE for the arranged
## lobby, PLAY_ORIGIN_PRIVATE for the group's own lobby after a private start), its lobby
## context, its identity (the service's match id, or the id this group's owner generated for a
## private match -- never one for the other) and the owner every member answers to there.
var session_origin: StringName = &""
var play_context: Variant = null
var session_id := ""
var play_owner: Dictionary = {}
## The owner's Gathering composition -- the identities of its admitted players -- and, per
## member, the Gathering epoch it last acknowledged. A member's Ready counts only while its
## acknowledgement is the current epoch: a change of who is in the group asks for new consent.
var gathering_acks: Dictionary = {}
## Members that have read and acknowledged the private start's published control: peer -> true.
var commit_acks: Dictionary = {}

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
## Lobbies and transports this flow left whose leave settled with their cleanup still owed:
## Party's recovery of them failed, and they stay fenced until the title restarts. Held for
## the same reason as the attempts, and read through Party's own quiescence query.
var _unresolved_contexts: Array = []
## The attempt this guest last told the owner it cannot join, so a refusal is sent once.
var _refused_epoch := 0
## Guest bookkeeping for the current epoch: how far it has moved, whether it acknowledged
## the freeze, which epoch it joined a ticket for and which epoch its budget belongs to.
var _stage := _STAGE_NONE
var _acked_epoch := 0
var _joined_epoch := 0
var _budget_epoch := -1
## The single state-sync request a guest may have in flight, and the deadline it was sent with.
## Its answer not taken while the owner could not be proven is noted, so a private start's member
## can ask again once -- on what is left of that same deadline.
var _sync_request_id := 0
var _sync_pending_id := 0
var _sync_sent_msec := 0
var _sync_purpose: StringName = &""
var _sync_alarm: OnlineFlowClock.Alarm = null
var _sync_deadline_msec := 0
var _sync_answer_missed := false
var _sync_reissued := false
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
## The fingerprint of the owner's Gathering composition, as last recorded.
var _composition := ""
## The epoch whose Gathering this guest last acknowledged.
var _gathering_acked_epoch := -1
## Set once the owner's private start has asked PartyService to switch the lobby: from then on
## the transaction finishes or fails within its budget, and Cancel no longer applies. A stop
## asked for meanwhile is kept for the transaction to act on after its await.
var _promoting := false
var _private_stop: Dictionary = {}
## A guest's private start: the session id it read from the owner's published control, the
## epoch it acknowledged that control for, and its own bound on the owner's preparation.
var _adopted_session_id := ""
var _commit_ack_epoch := 0
var _private_bound_alarm: OnlineFlowClock.Alarm = null
## A private start's guest: whether the private match's first STARTING has been applied here, and
## whether a message from the owner went untaken while the owner could not be proven -- the
## current state is then asked for once the owner is proven again, within this member's bound.
var initial_start_seen := false
var _private_catch_up_wanted := false
## The four a private match started with, by identity, and the session they started it under.
## Fixed at the commit and kept for as long as that session lasts, whatever the rounds after it.
var private_members: Dictionary = {}
var private_members_session := ""


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
		Phase.COMMITTING_START, Phase.PRIVATE_PREPARING,
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


## Whether the hosted-return "reopen the lobby" path may run. Only a play session's rematch
## round reopens; a staging lobby is reopened by its own restoration transaction and never by
## a screen being rebuilt mid-search.
func allows_reopen() -> bool:
	return phase == Phase.REMATCH_GATHERING


## The social activity this member should publish now. The flow's veto comes first: a
## freezing, searching, bootstrapping, privately starting or leaving session is never
## advertised, whatever the local admission gate says and even across an activity handover. A
## rematch round advertises the play session's own lobby, invite-only, whichever route made it.
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
			context = play_context
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
		"capacity": capacity,
		"selected_count": selected_keys.size(),
		"round": match_round,
		"synced": is_synced(),
		"host_returned": host_returned,
		"searching": is_searching(),
		"frozen": is_frozen(),
		"origin": String(session_origin),
		"private": is_private_route(),
		"private_outcome": reason_code in [REASON_PRIVATE_GROUP_CHANGED, REASON_PRIVATE_FAILED, REASON_PRIVATE_CANCELLED],
		"cancellable": role == Role.OWNER and (phase in [Phase.FREEZING, Phase.CREATING_TICKET, Phase.SEARCHING]
			or (phase == Phase.PRIVATE_PREPARING and not _promoting)),
		"reason": reason,
		"reason_code": String(reason_code),
		"reason_epoch": reason_epoch,
		"presented_epoch": presented_reason_epoch,
		"restoration_failed": restoration_failed,
		"cancel_unresolved": cancel_unresolved,
		"cleanup_error": cleanup_error,
	}


## Whether this group is on its way into, or already in, a private match: the private start
## being prepared, or a play session whose origin is private.
func is_private_route() -> bool:
	return phase == Phase.PRIVATE_PREPARING or session_origin == PartyService.PLAY_ORIGIN_PRIVATE


## Records that a member's screen has shown this epoch's outcome, so a rebuilt screen
## does not show it twice.
func mark_reason_presented(presented_epoch: int) -> void:
	presented_reason_epoch = maxi(presented_reason_epoch, presented_epoch)


## The lobby contexts this flow still holds, the play session's first so the newer resource is
## released before the one it replaced. A private match's lobby is the group's own: it is held,
## and released, once.
func held_contexts() -> Array:
	var contexts: Array = []
	for context: Variant in [play_context, arranged_context, staging_context]:
		if context != null and not contexts.has(context):
			contexts.append(context)
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
	_record_composition()
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
	_enter_matchmade_session()
	host_returned = true
	synced = true
	_set_phase(Phase.REMATCH_GATHERING)


## A replacement invited into a private match's rematch round. It holds that match's lobby as
## its play session -- never as a group's staging lobby -- joins no ticket and no arrangement,
## and is a guest of the private match's owner for the session the invitation named.
func start_private_rematch_guest(context: Variant, private_session_id: String, play_round: int, owner_key: Dictionary) -> void:
	entry_kind = ENTRY_PRIVATE_REMATCH
	play_context = context
	arranged_context = null
	staging_context = null
	staging_session = 0
	session_origin = PartyService.PLAY_ORIGIN_PRIVATE
	session_id = private_session_id
	match_round = maxi(play_round, 0)
	play_owner = entity_key(owner_key)
	host_returned = true
	synced = true
	_set_phase(Phase.REMATCH_GATHERING)


## The arranged lobby becomes the play session, identified by the service's match id.
func _enter_matchmade_session() -> void:
	play_context = arranged_context
	session_origin = PartyService.PLAY_ORIGIN_MATCHMADE
	session_id = match_id
	play_owner = arranged_owner_key.duplicate()


# --- Gathering and the ready transaction -------------------------------------

## Called on every roster or lobby change. The owner starts a search -- or, for a full group,
## a private match -- the moment the exact admitted group is ready; during either the same
## signals are how divergence is caught. In Gathering a change of who is in the group is
## recorded first, and asks for fresh consent (see _note_composition()). The staging owner is
## the lobby's actual native owner; losing that is terminal, because a NONE-migration lobby
## does not stop another member from claiming it.
func on_group_changed() -> void:
	if not is_current() or role != Role.OWNER:
		return
	if phase in [Phase.GATHERING, Phase.FREEZING, Phase.CREATING_TICKET, Phase.SEARCHING, Phase.PRIVATE_PREPARING] \
			and _staging_owner_lost():
		NetManager._flow_fail(self, TEXT_OWNER_CHANGED)
		return
	if phase == Phase.GATHERING:
		_note_composition()
		evaluate_ready()
		return
	if phase in [Phase.FREEZING, Phase.CREATING_TICKET, Phase.SEARCHING] and not _group_intact():
		_stop_search(REASON_GROUP_CHANGED, TEXT_GROUP_CHANGED)
		return
	if phase == Phase.PRIVATE_PREPARING and not _group_intact():
		_stop_private(REASON_PRIVATE_GROUP_CHANGED, TEXT_PRIVATE_GROUP_CHANGED)


## A replicated owner that is someone else. An owner not replicated yet is not a loss.
func _staging_owner_lost() -> bool:
	var party := Services.party()
	if party == null or staging_context == null:
		return false
	var snapshot: Dictionary = party.snapshot(staging_context)
	var owner := entity_key(snapshot.get("owner_key", {}))
	return not owner.is_empty() and not bool(snapshot.get("is_local_owner", false))


## The one dispatcher. Once every admitted human is ready -- each member's Ready given to the
## group as it is now -- a group of one to three freezes for a search, and a full group of four
## starts a private match in this same lobby instead: no search, no ticket and no new lobby or
## network. Nobody chooses between the two; the group's size does, here, once, and the route
## taken is never switched mid-await. A full group whose earlier search still owes native
## cleanup waits for it, and is looked at again once the service reports that cleanup changed.
func evaluate_ready() -> void:
	if role != Role.OWNER or phase != Phase.GATHERING or _restoring or restoration_failed:
		return
	if not is_current():
		return
	var group := admitted_group()
	if group.is_empty() or not _all_ready() or not _all_consented(group):
		return
	if group.size() < CAPACITY:
		_freeze(group)
		return
	if _cleanup_outstanding():
		return
	_prepare_private(group)


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


## Whether every admitted member's readiness was given to the group as it is now.
func _all_consented(group: Dictionary) -> bool:
	for peer_id: int in group:
		if not gathering_consented(peer_id):
			return false
	return true


## Whether `peer_id`'s Ready counts now. Outside the owner's Gathering every Ready is judged by
## the ordinary rules; in it, the owner's own always counts and a member's only while its last
## acknowledgement is the current epoch.
func gathering_consented(peer_id: int) -> bool:
	if role != Role.OWNER or phase != Phase.GATHERING:
		return true
	if peer_id == NetManager.local_peer_id():
		return true
	return int(gathering_acks.get(peer_id, -1)) == epoch


## Records the Gathering composition as it is now, with no new epoch: at entry, and on a return
## to Gathering whose own attempt number already asks every member for fresh consent.
func _record_composition() -> void:
	_composition = _composition_fingerprint()
	gathering_acks.clear()


## A change of who is in the gathering group -- a join, a departure, one member swapped for
## another -- asks for fresh consent. The attempt number moves on, every human is unready
## again, the change is broadcast, and a Ready counts only from a member that has acknowledged
## it: readiness given to a group of four is never consent to search with three. A member's
## lobby connection coming and going is not such a change; it only holds the start until the
## group is whole again.
func _note_composition() -> void:
	var current := _composition_fingerprint()
	if current == _composition:
		return
	# Recorded before anything is reset, so the roster updates the reset raises find no change.
	epoch += 1
	_composition = current
	gathering_acks.clear()
	NetManager._flow_reset_readiness()
	NetManager._flow_broadcast_phase(self, {})
	changed.emit()


## Who is in the group now, as one string: every admitted human's identity, sorted.
func _composition_fingerprint() -> String:
	var party := Services.party()
	var marks := PackedStringArray()
	var local_id := NetManager.local_peer_id()
	for peer_id: int in NetManager.players:
		var state: PlayerState = NetManager.players[peer_id]
		if state == null or state.is_bot:
			continue
		var key: Dictionary = {}
		if party != null:
			key = entity_key(party.local_entity_key(staging_context) if peer_id == local_id else party.entity_key_for(peer_id))
		marks.append(fingerprint(key) if not key.is_empty() else "peer:%d" % peer_id)
	marks.sort()
	return "\u001e".join(marks)


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


## A member's report to the owner for the current epoch: its acknowledgement of the group's
## Gathering composition, of a freeze, of a private start being prepared or of that start's
## published control -- or its request to stop the search.
func on_member_report(sender: int, report_epoch: int, reported_phase: int) -> void:
	if role != Role.OWNER or not is_current() or report_epoch != epoch:
		return
	if reported_phase == Phase.GATHERING:
		if phase == Phase.GATHERING and NetManager.players.has(sender):
			gathering_acks[sender] = report_epoch
		return
	if not frozen_peers.has(sender):
		return
	if reported_phase == Phase.FREEZING and phase == Phase.FREEZING:
		acks[sender] = true
	elif reported_phase == Phase.PRIVATE_PREPARING and phase == Phase.PRIVATE_PREPARING:
		acks[sender] = true
	elif reported_phase == Phase.COMMITTING_START and phase == Phase.PRIVATE_PREPARING:
		commit_acks[sender] = true
	elif reported_phase == Phase.CANCELLING:
		_stop_search(REASON_GUEST_JOIN_FAILED, TEXT_GUEST_JOIN_FAILED)


## A guest's binding Leave Group. Consent withdrawn mid-search cancels the whole ticket.
func on_member_leave(sender: int, leave_epoch: int) -> void:
	if role != Role.OWNER or not is_current() or not frozen_peers.has(sender):
		return
	if leave_epoch == epoch and is_searching():
		_stop_search(REASON_MEMBER_LEFT, TEXT_MEMBER_LEFT)


# --- Private Start: a full group plays in its own lobby ------------------------------
#
# A full group of four cannot search: the queue takes no ticket that is already at its maximum.
# Once all four are ready their owner switches the same lobby to a private match instead, as
# one transaction on a 15-second budget that never renews. The group freezes and every member
# acknowledges; the lobby is locked; everything is read again; and PartyService switches the
# lobby -- same lobby, same network, same players, no ticket -- and reads the switch back. Every
# member then reads the private match's control from the lobby and acknowledges it, and only
# then is the start committed: the lobby becomes the play session, and the first match starts
# with exactly those four through the ordinary STARTING path, on its own 30-second budget.
#
# Nothing here falls back to a search. A failure before the switch was asked for restores the
# group the way a stopped search does. Once it was asked for, only PartyService can prove the
# lobby back to the group's Gathering state; an answer it cannot prove ends the group through
# the ordinary cleanup.

func _prepare_private(group: Dictionary) -> void:
	# Re-entry is closed by the phase itself, as for the search: it leaves GATHERING before
	# the first await, and only evaluate_ready() starts it, only from GATHERING.
	epoch += 1
	var attempt := epoch
	acks.clear()
	commit_acks.clear()
	cancel_unresolved = false
	_promoting = false
	_private_stop = {}
	frozen_peers = group.duplicate(true)
	frozen_keys.clear()
	for peer_id: int in frozen_peers:
		frozen_keys.append((frozen_peers[peer_id] as Dictionary).duplicate())
	frozen_keys.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return fingerprint(a) < fingerprint(b))
	phase_deadline_msec = _clock.deadline_after(PRIVATE_PREPARE_SECONDS)
	_clear_reason()
	_set_phase(Phase.PRIVATE_PREPARING)
	# The local gate closes before anything is awaited, and every member is told in the same
	# frame: they freeze, hold their readiness, retire their own activity and acknowledge.
	NetManager._flow_set_admission(false)
	NetManager._flow_broadcast_phase(self, {})
	var party := Services.party()
	var posted: PartyService.PartyResult = await party.post_context_update(
		staging_context, {PartyService.SEARCH_CONTROL_KEY: _envelope(ENVELOPE_PRIVATE, "")},
		{}, {}, phase_deadline_msec)
	if not _private_current(attempt):
		return
	if posted == null or not posted.ok():
		await _restore(REASON_PRIVATE_FAILED, TEXT_PRIVATE_FAILED)
		return
	var locked: PartyService.PartyResult = await party.set_context_locked(staging_context, true, phase_deadline_msec)
	if not _private_current(attempt):
		return
	if locked == null or not locked.ok() or not bool(party.snapshot(staging_context).get("membership_locked", false)):
		await _restore(REASON_PRIVATE_FAILED, TEXT_PRIVATE_FAILED)
		return
	while not _acks_complete():
		if _clock.has_expired(phase_deadline_msec):
			await _restore(REASON_PRIVATE_FAILED, TEXT_PRIVATE_FAILED)
			return
		await _clock.sleep_seconds(minf(POLL_SECONDS, _clock.remaining_seconds(phase_deadline_msec)))
		if not _private_current(attempt):
			return
	# Read again after every await: the group, its readiness, its owner, the mode's settings and
	# any ticket cleanup can all have moved while the lock and the acknowledgements were out.
	var problem := _private_problem()
	if not problem.is_empty():
		await _restore(StringName(problem.get("code", REASON_PRIVATE_FAILED)), String(problem.get("text", TEXT_PRIVATE_FAILED)))
		return
	_promoting = true
	changed.emit()
	var candidate := _new_private_session_id()
	var promoted: PartyService.PartyResult = await party.promote_staging_to_private(
		staging_context, candidate, frozen_keys, phase_deadline_msec)
	_hold_operation(promoted)
	if not _private_current(attempt):
		return
	if promoted == null or not promoted.ok():
		# The service's own code goes to the log; the players read this title's words.
		push_warning("[Matchmaking] private_start_not_switched flow=%d code=%s" % [
			id, String(promoted.reason_code) if promoted != null else "none"])
		var failed := _private_failure()
		await _restore_private(candidate, StringName(failed.get("code", REASON_PRIVATE_FAILED)), String(failed.get("text", TEXT_PRIVATE_FAILED)))
		return
	var read_back := String(promoted.private_session_id)
	if read_back != candidate:
		await _restore_private(candidate, REASON_PRIVATE_FAILED, TEXT_PRIVATE_FAILED)
		return
	# Every member reads the private match's control from the lobby and acknowledges it, inside
	# the same budget, before anything is committed.
	while not _commit_acks_complete():
		problem = _private_problem()
		if not problem.is_empty():
			await _restore_private(candidate, StringName(problem.get("code", REASON_PRIVATE_FAILED)), String(problem.get("text", TEXT_PRIVATE_FAILED)))
			return
		await _clock.sleep_seconds(minf(POLL_SECONDS, _clock.remaining_seconds(phase_deadline_msec)))
		if not _private_current(attempt):
			return
	problem = _private_problem()
	if not problem.is_empty():
		await _restore_private(candidate, StringName(problem.get("code", REASON_PRIVATE_FAILED)), String(problem.get("text", TEXT_PRIVATE_FAILED)))
		return
	_commit_private(read_back)


func _private_current(attempt: int) -> bool:
	return is_current() and epoch == attempt and phase == Phase.PRIVATE_PREPARING


## What stands between this private start and its next step, as the reason its restoration
## keeps, or empty: a stop asked for meanwhile, the group changed or no longer all ready, this
## player no longer the lobby's owner, the mode's settings refused, a ticket's cleanup still
## owed, or the budget spent.
func _private_problem() -> Dictionary:
	if not _private_stop.is_empty():
		return _private_stop
	if not _same_group(admitted_group(), frozen_peers) or not _all_ready():
		return {"code": REASON_PRIVATE_GROUP_CHANGED, "text": TEXT_PRIVATE_GROUP_CHANGED}
	if not _is_staging_owner():
		return {"code": REASON_PRIVATE_FAILED, "text": TEXT_PRIVATE_FAILED}
	var matchmaking: MatchmakingService = Services.matchmaking() if Services != null else null
	var profile: Dictionary = matchmaking.runtime_profile(mode) if matchmaking != null else {}
	if not bool(profile.get("ok", false)):
		return {"code": _profile_code(profile), "text": _profile_text(profile)}
	if int(profile.get("capacity", 0)) != CAPACITY:
		return {"code": REASON_PRIVATE_FAILED, "text": TEXT_PROFILE_CHANGED}
	if _cleanup_outstanding() or _clock.has_expired(phase_deadline_msec):
		return {"code": REASON_PRIVATE_FAILED, "text": TEXT_PRIVATE_FAILED}
	return {}


## Why a switch that did not succeed is being undone: what stood in its way, if anything did,
## or that the private match could not be started.
func _private_failure() -> Dictionary:
	var problem := _private_problem()
	if problem.is_empty():
		return {"code": REASON_PRIVATE_FAILED, "text": TEXT_PRIVATE_FAILED}
	return problem


func _commit_acks_complete() -> bool:
	var local_id := NetManager.local_peer_id()
	for peer_id: int in frozen_peers:
		if peer_id != local_id and not commit_acks.has(peer_id):
			return false
	return true


## A fresh identity for one private match: 32 lowercase hexadecimal characters from 16 random
## bytes. It names the session and never stands in for a match the service arranged.
static func _new_private_session_id() -> String:
	var random := RandomNumberGenerator.new()
	random.randomize()
	var bytes := PackedByteArray()
	bytes.resize(16)
	for index in bytes.size():
		bytes[index] = random.randi_range(0, 255)
	return bytes.hex_encode()


## The private start is committed. The group's own lobby becomes the play session -- held once,
## as the play context, and never again as a staging lobby -- identified by the id its switch
## read back, and its first match starts with exactly the four who readied.
func _commit_private(read_back: String) -> void:
	play_context = staging_context
	staging_context = null
	session_origin = PartyService.PLAY_ORIGIN_PRIVATE
	session_id = read_back
	var party := Services.party()
	play_owner = entity_key(party.local_entity_key(play_context)) if party != null else {}
	match_round = 0
	selected_keys = frozen_keys.duplicate(true)
	start_generation = 1
	host_returned = true
	_promoting = false
	_record_private_members()
	_set_phase(Phase.COMMITTING_START)
	NetManager._flow_commit_private_start(self)


## Records the four this private session started with, once, for as long as the session lasts.
func _record_private_members() -> void:
	if not private_members_session.is_empty():
		return
	private_members = {}
	for key: Dictionary in frozen_keys:
		private_members[fingerprint(key)] = true
	private_members_session = session_id


## Whether `key` is one of the four this private session started with -- for this session only.
func is_private_member(key: Dictionary) -> bool:
	return session_origin == PartyService.PLAY_ORIGIN_PRIVATE and not session_id.is_empty() \
		and private_members_session == session_id and not key.is_empty() \
		and private_members.has(fingerprint(key))


## Stops a private start that has not asked for the lobby's switch yet: the group is restored
## the way a stopped search is. Once the switch is under way the stop is only kept; the
## transaction acts on it after its await, through PartyService's own restoration.
func _stop_private(code: StringName, text: String) -> void:
	if role != Role.OWNER or not is_current() or phase != Phase.PRIVATE_PREPARING:
		return
	if _promoting:
		if _private_stop.is_empty():
			_private_stop = {"code": code, "text": text}
		return
	_restore(code, text)


## A private start whose switch was asked for but that did not commit. PartyService alone can
## prove the lobby back to the group's Gathering state -- or that it cannot -- so it is asked
## whatever the switch answered, and only its confirmed answer reopens anything: then every
## member is unready, the reason is kept, and admission and activity reopen, exactly as after a
## stopped search. An answer it cannot prove ends the group through the ordinary cleanup.
func _restore_private(candidate: String, code: StringName, text: String) -> void:
	if role != Role.OWNER or not is_current() or _restoring:
		return
	_restoring = true
	_promoting = false
	_private_stop = {}
	var restoring_epoch := epoch
	_record_reason(code, text)
	_set_phase(Phase.RESTORING_STAGING)
	NetManager._flow_broadcast_phase(self, {"reason_code": String(code), "reason": text})
	var party := Services.party()
	var restored: PartyService.PartyResult = await party.restore_private_to_gathering(
		staging_context, candidate, _envelope(ENVELOPE_GATHERING, ""), _clock.deadline_after(RESTORE_SECONDS))
	_hold_operation(restored)
	if not _restore_current(restoring_epoch):
		return
	_restoring = false
	if restored == null or not restored.ok():
		push_warning("[Matchmaking] private_start_not_restored flow=%d code=%s" % [
			id, String(restored.reason_code) if restored != null else "none"])
		NetManager._flow_fail(self, TEXT_PRIVATE_NOT_STARTED)
		return
	NetManager._flow_reset_readiness()
	restoration_failed = false
	_record_composition()
	# Gathering is set before the gate opens, so the admission signal already sees a joinable
	# phase and every activity is republished from one consistent state.
	_set_phase(Phase.GATHERING)
	NetManager._flow_set_admission(true)
	NetManager._flow_broadcast_phase(self, {"reason_code": String(code), "reason": text})


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
	spec.capacity = int(profile.get("capacity", 0))
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
	spec.capacity = int(profile.get("capacity", 0))
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
	# Kept for the attempt's whole native life, after this flow stops reading its outcome
	# too: a match that lands once the search was let go of still has to end the group.
	if attempt.has_signal("native_terminal_changed") \
			and not attempt.native_terminal_changed.is_connected(_on_native_terminal):
		attempt.native_terminal_changed.connect(_on_native_terminal)
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


## Whether any attempt, scoped operation or left context this flow let go of still has
## native cleanup its service owes.
func _cleanup_outstanding() -> bool:
	for index in range(_unresolved_attempts.size() - 1, -1, -1):
		var attempt: Variant = _unresolved_attempts[index]
		if attempt == null or not bool(attempt.cleanup_pending):
			_unresolved_attempts.remove_at(index)
	for index in range(_unresolved_operations.size() - 1, -1, -1):
		var operation: Variant = _unresolved_operations[index]
		if operation == null or not bool(operation.cleanup_pending):
			_unresolved_operations.remove_at(index)
	var party: PartyService = Services.party() if Services != null else null
	for index in range(_unresolved_contexts.size() - 1, -1, -1):
		var context: Variant = _unresolved_contexts[index]
		if context == null or party == null or party.context_is_quiescent(context):
			_unresolved_contexts.remove_at(index)
	return not _unresolved_attempts.is_empty() or not _unresolved_operations.is_empty() \
		or not _unresolved_contexts.is_empty()


## Keeps the handle of a scoped operation whose caller settled while its native completion
## is still owed -- a timeout, usually -- so the lease is not released underneath it. Only
## the handle is kept, and it is polled: nothing here is stored on it.
func _hold_operation(result: Variant) -> void:
	if result == null:
		return
	var operation: Variant = result.operation
	if operation != null and bool(operation.cleanup_pending) and not _unresolved_operations.has(operation):
		_unresolved_operations.append(operation)


## Keeps the context of a scoped leave that settled with its cleanup still owed -- the
## failed recovery that settles it leaves the context fenced -- so a leaving flow does not
## release its lease as though the leave had finished. The context is polled, not the result.
func _hold_leave(result: Variant) -> void:
	if result == null:
		return
	_hold_operation(result)
	var context: Variant = result.context
	if bool(result.cleanup_pending) and context != null and not _unresolved_contexts.has(context):
		_unresolved_contexts.append(context)


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
			_abandon_matched()
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
## already captured -- unless that ticket matched while it was held, which ends the group
## instead. Leaving stays available throughout.
func _hold_for_cleanup(code: StringName, text: String) -> void:
	var holding_epoch := epoch
	var held := _unresolved_attempts.duplicate()
	_pending_stop = {"code": code, "text": text}
	cancel_unresolved = true
	if phase != Phase.CANCELLING:
		_set_phase(Phase.CANCELLING)
		NetManager._flow_broadcast_phase(self, {})
	changed.emit()
	while _cleanup_outstanding():
		if _any_matched(held):
			_abandon_matched()
			return
		await _clock.sleep_seconds(POLL_SECONDS)
		if not is_current() or epoch != holding_epoch or phase != Phase.CANCELLING:
			return
	# A cleared cleanup flag says the ticket is safe, not that it never matched.
	if _any_matched(held):
		_abandon_matched()
		return
	_restore(code, text)


## Whether any of these attempts reached native Matched: level state, read afresh.
static func _any_matched(attempts: Array) -> bool:
	for attempt: Variant in attempts:
		if attempt != null and int(attempt.status) == MatchmakingService.STATUS_MATCHED:
			return true
	return false


## A ticket this group had already let go of -- cancelled, left, timed out or failed --
## was matched anyway. Native Matched is terminal proof, but the stop stays binding: the
## old group neither joins that match, searches again nor reopens as if nothing happened,
## because the players it matched are no longer this group's to gather. It ends here,
## with its reason; the lease stays held until the ticket's native cleanup is settled.
func _abandon_matched() -> void:
	if not is_current():
		return
	_retire_ticket()
	NetManager._flow_fail(self, TEXT_MATCH_ABANDONED)


## The service first observed a ticket's native terminal state. A match that lands on a
## ticket this group still searches with arrives as its settled outcome instead; this is
## for one it already let go of, whatever order the events came in.
func _on_native_terminal(attempt: Variant) -> void:
	if attempt == null or not is_current() or phase not in _PRE_MATCH_PHASES:
		return
	if attempt != ticket and not _unresolved_attempts.has(attempt):
		return
	if int(attempt.status) != MatchmakingService.STATUS_MATCHED:
		return
	var let_go: bool = attempt != ticket or phase == Phase.CANCELLING or not _pending_stop.is_empty() \
		or (not attempt.is_pending() and int(attempt.outcome) != MatchmakingService.Outcome.MATCHED)
	if let_go:
		_abandon_matched()


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


## The owner's Cancel. A search stops once the service confirms; a private start stops only
## while it has not yet asked for the lobby's switch -- after that it finishes or fails within
## its own budget.
func cancel_search() -> void:
	if phase == Phase.PRIVATE_PREPARING:
		if not _promoting:
			_stop_private(REASON_PRIVATE_CANCELLED, TEXT_PRIVATE_CANCELLED)
		return
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
	# decides when the lobby admits that confirmation is taking a while. A match the service
	# has already observed on this ticket ends the group here even while the cancel's own
	# answer is still outstanding -- the ticket's native status is enough, and the stop stays
	# binding -- so an answer that never comes cannot keep the group waiting on it.
	var cancelling_epoch := epoch
	var cancelling: Variant = ticket
	var grace_ends := _clock.deadline_after(CANCEL_GRACE_SECONDS)
	while is_current() and epoch == cancelling_epoch and phase == Phase.CANCELLING:
		if _any_matched([cancelling]):
			_abandon_matched()
			return
		if not cancel_unresolved and _clock.has_expired(grace_ends):
			cancel_unresolved = true
			changed.emit()
		await _clock.sleep_seconds(POLL_SECONDS)


# --- Restoration ------------------------------------------------------------

## Returns every survivor to the same staging lobby after a search stops before a match, or a
## private start stops before it asked for the lobby's switch: usable ticket metadata removed,
## everyone unready, the lobby unlocked and reopened, every member's activity restored, and
## the reason kept for the players to read. Readiness counts again only from members that
## acknowledge the restored group.
##
## Fails closed. An unconfirmed write or unlock leaves the group locked with Retry and
## Leave rather than advertising a lobby the service still refuses.
func _restore(code: StringName, text: String) -> void:
	if role != Role.OWNER or not is_current() or _restoring:
		return
	_restoring = true
	_pending_stop = {}
	_promoting = false
	_private_stop = {}
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
	_record_composition()
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
## only make it shorter than the owner's. A member following a private start also takes the
## owner's answer after the commit: see _catch_up_private_start().
func on_state_reply(owner_epoch: int, next_phase: int, detail: Dictionary) -> void:
	var private_start := _follows_private_start()
	if not _reduces_staging() and not private_start:
		return
	var request_id := int(detail.get("request_id", 0))
	if request_id <= 0 or request_id != _sync_pending_id:
		return
	var anchor := _sync_sent_msec
	_finish_sync()
	# The owner's answer is the state this member asked for: nothing more is owed to it.
	_private_catch_up_wanted = false
	if owner_epoch < 0:
		return
	if private_start and next_phase == Phase.COMMITTING_START:
		_catch_up_private_start(owner_epoch, detail)
		return
	if not _reduces_staging():
		return
	if owner_epoch == 0:
		if next_phase == Phase.GATHERING and epoch == 0:
			_adopt_gathering(0, "", "", false, true)
		return
	_apply_owner_state(owner_epoch, next_phase, detail, anchor)
	# The lobby may already hold what the answer points at -- a ticket id, most often.
	reconcile_staging()
	# An owner that answers while still preparing the private start is alive, but has not
	# finished it within this member's own bound: once that bound has passed, the private start
	# has failed. Before then this member keeps waiting on the bound it already has.
	if is_current() and phase == Phase.PRIVATE_PREPARING and next_phase == Phase.PRIVATE_PREPARING \
			and owner_epoch == epoch and _clock.has_expired(phase_deadline_msec):
		NetManager._flow_fail(self, TEXT_PRIVATE_NOT_STARTED)


## Reduces the staging lobby's own state: its search envelope, the private match control an
## owner's private start publishes in it, and whether its native owner is still the host this
## guest's transport answers to.
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
	if typeof(envelope) == TYPE_DICTIONARY and bool((envelope as Dictionary).get("valid", false)):
		var control := envelope as Dictionary
		var control_epoch := int(control.get("epoch", 0))
		if control_epoch > 0 and control_epoch >= epoch:
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
				ENVELOPE_PRIVATE:
					_adopt_private(control_epoch, control.get("group", []))
	if is_current() and phase == Phase.PRIVATE_PREPARING:
		_reconcile_private_control(party, party.snapshot(staging_context))
	_try_private_catch_up()


func _reduces_staging() -> bool:
	return role == Role.GUEST and is_current() and staging_context != null \
		and phase in [Phase.GATHERING, Phase.FREEZING, Phase.JOINING_TICKET, Phase.SEARCHING,
			Phase.CANCELLING, Phase.RESTORING_STAGING, Phase.PRIVATE_PREPARING]


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
				String(detail.get("reason", "")), next_phase == Phase.RESTORING_STAGING, true)
		Phase.PRIVATE_PREPARING:
			_adopt_private(owner_epoch, [])
		Phase.COMMITTING_START:
			_adopt_private_commit(owner_epoch, String(detail.get("session_id", "")))


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
## for the old state goes back to the service first, and a private start this guest was
## following is let go of with it.
func _begin_stage(new_epoch: int, stage: int) -> void:
	epoch = new_epoch
	_stage = stage
	_retire_ticket()
	cancel_unresolved = false
	synced = true
	_cancel_private_bound()
	_adopted_session_id = ""
	_private_catch_up_wanted = false


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
## with the reason too. A guest acknowledges a Gathering it adopts from the lobby once per
## epoch, and the owner's own Gathering for the epoch it holds every time that message arrives,
## live or in answer to its request: the lobby can bring it back to Gathering while the owner is
## still restoring, before the owner takes any acknowledgement. That acknowledgement is what lets
## its next Ready count. An earlier Ready is never sent again.
func _adopt_gathering(new_epoch: int, code: String, text: String, restoring: bool, from_owner: bool = false) -> void:
	var stage: int = _STAGE_RESTORING if restoring else _STAGE_RESTORED
	var adopted := false
	if new_epoch > epoch or (new_epoch == epoch and _stage < stage):
		_begin_stage(new_epoch, stage)
		var shown := text
		if shown.is_empty() and not code.is_empty():
			shown = MatchmakingService.reason_for_code(code)
		if not shown.is_empty() and (reason_epoch != epoch or reason != shown):
			_record_reason(StringName(code), shown)
		_set_phase(Phase.RESTORING_STAGING if restoring else Phase.GATHERING)
		adopted = true
	if restoring or not is_current() or new_epoch != epoch or phase != Phase.GATHERING:
		return
	if from_owner or (adopted and _gathering_acked_epoch != epoch):
		_gathering_acked_epoch = epoch
		NetManager._flow_send_report(epoch, Phase.GATHERING)


## The owner is preparing a private start for this epoch: this member freezes, holds its
## readiness, retires its activity and acknowledges, once. It keeps the full group's
## identities from the lobby's envelope, and bounds its own wait for the owner: past it, it
## asks the owner for its state, and silence then ends the group.
func _adopt_private(new_epoch: int, group: Variant) -> void:
	if new_epoch < epoch or (new_epoch == epoch and _stage >= _STAGE_FROZEN):
		_note_private_group(new_epoch, group)
		return
	_begin_stage(new_epoch, _STAGE_FROZEN)
	_clear_reason()
	frozen_keys.clear()
	_note_private_group(new_epoch, group)
	phase_deadline_msec = _clock.deadline_after(PRIVATE_PREPARE_SECONDS)
	_set_phase(Phase.PRIVATE_PREPARING)
	_arm_private_bound()
	if _acked_epoch != epoch:
		_acked_epoch = epoch
		NetManager._flow_send_report(epoch, Phase.PRIVATE_PREPARING)
	# The lobby may already hold the group and the owner's published control.
	reconcile_staging()


## The full group a private start is for, read from the owner's envelope for this epoch.
func _note_private_group(group_epoch: int, group: Variant) -> void:
	if group_epoch != epoch or not frozen_keys.is_empty() or typeof(group) != TYPE_ARRAY:
		return
	var keys: Array[Dictionary] = []
	for raw: Variant in group as Array:
		var key := entity_key(raw)
		if key.is_empty():
			return
		keys.append(key)
	frozen_keys.assign(keys)


## Reads the private match control the owner's switch publishes in the lobby, while this member
## is following a private start. It is taken only while the owner is proven, now, the owner of
## this lobby: until then it waits for the next change, and a known disagreement ends this
## member's attempt. A control for the first round, starting, that names this member and its
## whole group is acknowledged, once, and its session id kept. One that leaves either out ends
## this member's attempt. Nothing is taken on until the owner commits it.
func _reconcile_private_control(party: PartyService, snapshot: Dictionary) -> void:
	if role != Role.GUEST or phase != Phase.PRIVATE_PREPARING or not _adopted_session_id.is_empty():
		return
	var raw_control: Variant = snapshot.get("private_control", {})
	var control: Dictionary = raw_control as Dictionary if typeof(raw_control) == TYPE_DICTIONARY else {}
	if not bool(control.get("valid", false)) or int(control.get("round", -1)) != 0 \
			or String(control.get("phase", "")) != PartyService.ARRANGED_PHASE_STARTING \
			or int(control.get("start_generation", 0)) != 1:
		return
	if frozen_keys.is_empty():
		return
	if not NetManager._authority_trusted() or not is_current() or phase != Phase.PRIVATE_PREPARING:
		return
	var selected: Variant = control.get("selected_members", [])
	var local_key := entity_key(party.local_entity_key(staging_context))
	if local_key.is_empty() or not selection_includes(selected, [local_key]) \
			or not selection_includes(selected, frozen_keys):
		NetManager._flow_fail(self, TEXT_MATCH_MISMATCH)
		return
	_adopted_session_id = String(control.get("session_id", ""))
	if _adopted_session_id.is_empty():
		return
	if _commit_ack_epoch != epoch:
		_commit_ack_epoch = epoch
		NetManager._flow_send_report(epoch, Phase.COMMITTING_START)
	changed.emit()


## The owner committed its private start for this epoch. The session it names must be the one
## this member read from the lobby, and the owner must be proven again as it is taken; then the
## group's lobby becomes this member's play session, this session answers to its owner there,
## and the start that follows is judged as the private match's first. The commit's own budget is
## taken here, once. Nothing was taken on before this, so a restoration never has anything to undo.
func _adopt_private_commit(owner_epoch: int, committed: String) -> void:
	if role != Role.GUEST or owner_epoch != epoch or phase != Phase.PRIVATE_PREPARING:
		return
	if not NetManager._authority_trusted():
		if is_current() and phase == Phase.PRIVATE_PREPARING:
			_private_catch_up_wanted = true
		return
	if _adopted_session_id.is_empty():
		reconcile_staging()
		if not is_current() or phase != Phase.PRIVATE_PREPARING:
			return
	if committed.is_empty() or committed != _adopted_session_id:
		NetManager._flow_fail(self, TEXT_MATCH_MISMATCH)
		return
	var party := Services.party()
	var owner: Dictionary = {}
	if party != null:
		owner = entity_key(party.snapshot(staging_context).get("owner_key", {}))
	play_context = staging_context
	staging_context = null
	session_origin = PartyService.PLAY_ORIGIN_PRIVATE
	session_id = committed
	play_owner = owner
	match_round = 0
	selected_keys = frozen_keys.duplicate(true)
	start_generation = 1
	host_returned = true
	_cancel_private_bound()
	_finish_sync()
	phase_deadline_msec = _clock.deadline_after(COMMIT_SECONDS)
	_set_phase(Phase.COMMITTING_START)
	NetManager._flow_private_committed(self)


func _arm_private_bound() -> void:
	_cancel_private_bound()
	_private_bound_alarm = _clock.alarm_at(phase_deadline_msec, _on_private_bound.bind(epoch))


func _cancel_private_bound() -> void:
	if _private_bound_alarm != null:
		_private_bound_alarm.cancel()
	_private_bound_alarm = null


## This member's own bound on the owner's private start ran out with nothing committed or
## restored: it asks the owner for its state, once. An owner that does not answer ends the
## group; one that answers still preparing has not finished within the bound.
func _on_private_bound(bound_epoch: int) -> void:
	_private_bound_alarm = null
	if not is_current() or role != Role.GUEST or epoch != bound_epoch or phase != Phase.PRIVATE_PREPARING:
		return
	_private_catch_up_wanted = false
	_request_sync(&"private")


## Whether this member is a guest following its group's private start: preparing it, or its
## first match committed and not yet running.
func _follows_private_start() -> bool:
	if role != Role.GUEST or not is_current() or match_round != 0:
		return false
	return phase == Phase.PRIVATE_PREPARING \
		or (phase == Phase.COMMITTING_START and session_origin == PartyService.PLAY_ORIGIN_PRIVATE)


## A message from the owner was not taken, while this member follows a private start, because
## the owner could not be proven at that moment -- `answer_id` names the request it answered, if
## it was an answer. Until the private match's first start has been applied here, the need to ask
## the owner for its state is kept -- and acted on only once the owner is proven again, within
## this member's own bound.
func note_owner_message_missed(answer_id: int = 0) -> void:
	if _follows_private_start() and not initial_start_seen:
		_private_catch_up_wanted = true
		if answer_id > 0 and answer_id == _sync_pending_id:
			_sync_answer_missed = true
		_try_private_catch_up()


## Asks the owner for its current state, once, when a private start's message went untaken, the
## owner is proven again and this member's own bound has not passed. A request already out is
## waited for -- unless its own answer was the message not taken; then it is asked again, once,
## on what is left of its deadline (see _reissue_sync()).
func _try_private_catch_up() -> void:
	if not _private_catch_up_wanted or not _follows_private_start() or initial_start_seen:
		return
	if phase_deadline_msec <= 0 or _clock.has_expired(phase_deadline_msec):
		return
	if _sync_pending_id != 0 and (not _sync_answer_missed or _sync_reissued):
		return
	if NetManager._authority_verdict() != &"proven":
		return
	_private_catch_up_wanted = false
	if _sync_pending_id != 0:
		_reissue_sync()
	else:
		_request_sync(&"private")


## The owner's answer while this member follows a private start and the owner has committed it:
## the private match's session, its first round and start, and the match state the owner has
## reached -- the first STARTING or its loading after it, and nothing else. A member that missed
## the commit takes it now, once, exactly as it would have taken the live one; then the first
## start is applied as the live one would have been -- through this member's own admission and
## the owner proven again -- unless it already was, so an answer overtaken by the live messages
## changes nothing. A session other than the one this member read from the lobby ends its
## attempt; an answer for any other round, start or state is not taken at all.
func _catch_up_private_start(owner_epoch: int, detail: Dictionary) -> void:
	if owner_epoch != epoch:
		return
	var committed := String(detail.get("session_id", ""))
	if committed.is_empty() or int(detail.get("round", -1)) != 0 or int(detail.get("start_generation", 0)) != 1:
		return
	var reached := int(detail.get("match_state", -1))
	if reached != int(NRTypes.MatchState.STARTING) and reached != int(NRTypes.MatchState.PLAYERS_JOINING):
		return
	if phase == Phase.PRIVATE_PREPARING:
		_adopt_private_commit(owner_epoch, committed)
		if not is_current() or phase != Phase.COMMITTING_START:
			return
	elif committed != session_id:
		NetManager._flow_fail(self, TEXT_MATCH_MISMATCH)
		return
	if initial_start_seen:
		return
	NetManager._flow_catch_up_initial_start(self, reached)


## The owner's own account of its private match's first start, for one of its four that asks
## while that start is still under way: the session committed, the first round and its start
## generation, and the match state reached so far.
func private_start_reply() -> Dictionary:
	return {
		"session_id": session_id,
		"round": match_round,
		"start_generation": start_generation,
		"match_state": int(NetManager.match_state),
	}


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
	_sync_deadline_msec = _clock.deadline_after(SYNC_SECONDS)
	_sync_answer_missed = false
	_sync_reissued = false
	_sync_alarm = _clock.alarm_at(_sync_deadline_msec, _on_sync_timeout.bind(request_id))


## The owner's answer to the request still out was not taken, the owner not being provable at
## that moment. The owner proven again, the request is asked again, once, under a new id -- a
## late answer to the old id is not taken -- on what is left of the old request's own deadline,
## and never past this member's bound: no time is added. Past either, nothing is asked again and
## the old request's deadline ends the wait as it always would.
func _reissue_sync() -> void:
	if _sync_pending_id == 0 or _sync_reissued:
		return
	var deadline := mini(_sync_deadline_msec, phase_deadline_msec)
	if _sync_deadline_msec <= 0 or phase_deadline_msec <= 0 or _clock.has_expired(deadline):
		return
	_sync_request_id += 1
	var request_id := _sync_request_id
	if not NetManager._flow_request_state(self, request_id, epoch):
		return
	if _sync_alarm != null:
		_sync_alarm.cancel()
	_sync_pending_id = request_id
	_sync_sent_msec = _clock.now_msec()
	_sync_deadline_msec = deadline
	_sync_answer_missed = false
	_sync_reissued = true
	_sync_alarm = _clock.alarm_at(deadline, _on_sync_timeout.bind(request_id))


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
	elif purpose == &"private" and _follows_private_start() and not initial_start_seen:
		# The owner's private start neither committed, restored nor started here, and the
		# owner did not answer.
		NetManager._flow_fail(self, TEXT_HOST_SILENT)


func _finish_sync() -> void:
	if _sync_alarm != null:
		_sync_alarm.cancel()
	_sync_alarm = null
	_sync_pending_id = 0
	_sync_purpose = &""
	_sync_deadline_msec = 0
	_sync_answer_missed = false
	_sync_reissued = false


## What the owner would broadcast for its current state, for a guest that asked. A private
## match's first start, once committed, is answered with the owner's own account of it (see
## private_start_reply()); NetManager answers that only for one of the four it started with.
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
		Phase.COMMITTING_START:
			if session_origin == PartyService.PLAY_ORIGIN_PRIVATE and role == Role.OWNER:
				detail = private_start_reply()
	return {"epoch": epoch, "phase": int(reported), "detail": detail}


## Lobby state moved: a newly replicated envelope may carry the ticket id this guest was
## waiting for, any member change is the owner's cue to re-check its group, and the play
## session's lobby says whether its host has returned.
func on_lobby_changed(context: Variant) -> void:
	if not is_current() or context == null:
		return
	if context == staging_context:
		if role == Role.GUEST:
			reconcile_staging()
		else:
			on_group_changed()
	elif context == play_context and session_origin == PartyService.PLAY_ORIGIN_PRIVATE:
		reconcile_private()
	elif context == arranged_context:
		reconcile_arranged()


# --- Matched handoff ------------------------------------------------------------
#
# Each member's own group first. After its own arranged join, a member arms its handling of
# the old transport going away and publishes its acknowledgement; then it waits only for its
# own frozen premade -- every one of them in the arranged lobby, connected, compatible,
# carrying this match's id and acknowledged -- never for four, a count or another ticket's
# players. Only then does it leave its old staging transport, so no group host closes that
# network under a member that has not armed. The actual arranged owner then creates the
# fresh network and publishes it with the arranged lobby still open, so matched players who
# are still on their way can come in; the lobby is locked only when the first match starts,
# around the players who had arrived by then.

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
	# from the mode's real player count, which must still be the capacity of four.
	var matchmaking: MatchmakingService = Services.matchmaking() if Services != null else null
	var profile: Dictionary = matchmaking.runtime_profile(mode) if matchmaking != null else {}
	if not bool(profile.get("ok", false)):
		NetManager._flow_fail(self, _profile_text(profile))
		return
	if int(profile.get("capacity", 0)) != capacity:
		NetManager._flow_fail(self, TEXT_PROFILE_CHANGED)
		return
	var party := Services.party()
	var properties := {
		MatchmakingService.PROTOCOL_MEMBER_KEY: NRProtocol.version_string(),
		PartyService.MATCH_ID_MEMBER_KEY: match_id,
		PartyService.MATCH_ORIGIN_MEMBER_KEY: PartyService.MATCH_ORIGIN_VALUE,
	}
	var joined: PartyService.PartyResult = await party.join_arranged(
		Services.playfab_user(), arrangement, properties, capacity, account_generation, id, phase_deadline_msec)
	_hold_operation(joined)
	if not is_current():
		if joined != null and joined.context != null:
			await _release_context(joined.context)
		return
	if joined == null or not joined.ok() or joined.context == null:
		NetManager._flow_fail(self, _arranged_join_failure_text(joined))
		return
	arranged_context = joined.context
	arranged_owner_key = {}
	arranged_owner = false
	var owner := entity_key(joined.owner_key)
	if not owner.is_empty():
		_pin_arranged_owner(party, owner)
	_seen_connected.clear()
	await _arm_handoff()


## Why this member could not enter the arranged match. A native join that failed or ran out of
## time before any lobby could be read proves nothing about why -- the match may simply have
## started without it -- so it is told that plainly; every other failure keeps its own reason.
static func _arranged_join_failure_text(joined: Variant) -> String:
	var code: StringName = joined.reason_code if joined != null else &""
	if joined == null or code in [&"arranged_join_failed", &"arranged_join_timeout"]:
		return TEXT_MATCH_JOIN_UNPROVEN
	return _result_reason(joined, "The match could not be joined.")


## Pins the first valid native owner of the arranged lobby. Its creator of the fresh
## network is whoever this is -- staging owner or staging guest alike.
func _pin_arranged_owner(party: PartyService, owner: Dictionary) -> void:
	arranged_owner_key = owner.duplicate()
	var local_key := entity_key(party.local_entity_key(arranged_context))
	arranged_owner = not local_key.is_empty() and fingerprint(owner) == fingerprint(local_key)


## Arms intentional old-transport loss handling before announcing readiness, then waits for
## this member's own frozen premade in the arranged lobby. Only then does it deliberately
## retire its staging transport. Nothing here waits for a count or another ticket's players.
func _arm_handoff() -> void:
	# The premade, transport and admission budget: 90 seconds from this member's own arranged
	# success, separate from the 30 the join itself had. For the arranged owner it also bounds
	# the wait for enough players to start.
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
	var premade_ready: bool = await _await_premade()
	if not premade_ready:
		return
	await switch_transport()


func _arming_current() -> bool:
	return is_current() and phase == Phase.ARMING_HANDOFF


## Waits, within the handoff budget, for this member's own frozen premade and the pinned owner
## in the arranged lobby, while the flow is still in `expected` -- the arming, the transport
## switch reading them again after one of its awaits, or a guest whose joined network is already
## its session, before its admission is taken. Incomplete replication waits; a known loss, a
## changed or departed owner, an incompatible member or a match already starting without this
## member is final at once.
func _await_premade(expected: Phase = Phase.ARMING_HANDOFF) -> bool:
	var verdict := _premade_verdict()
	while verdict == &"waiting":
		if _clock.has_expired(phase_deadline_msec):
			NetManager._flow_fail(self, TEXT_MATCH_LATE)
			return false
		await _clock.sleep_seconds(minf(POLL_SECONDS, _clock.remaining_seconds(phase_deadline_msec)))
		if not is_current() or phase != expected:
			return false
		verdict = _premade_verdict()
	if verdict != &"ready":
		NetManager._flow_fail(self, _cohort_failure_text(verdict))
		return false
	return true


## This member's own frozen premade and the arranged lobby's pinned owner, and nothing about a
## count or about any other group.
##
## Ready: every key of the frozen premade -- this member's among them -- is present,
## connected, carrying a compatible protocol, this match's id and this match's
## acknowledgement; and the pinned owner is still the owner, present, connected and carrying a
## compatible protocol and this match's id. What has not replicated yet is waiting. Final at
## once: a premade member or the owner seen connected and then gone or disconnected, a changed
## owner, a present member of any group on another protocol or match, a wrong capacity, and an
## owner control showing this match already starting without this member or past its first
## round.
func _premade_verdict() -> StringName:
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
	if int(snapshot.get("max_members", capacity)) != capacity:
		return &"incompatible"
	if _start_control_excludes_self(party, snapshot):
		return &"late"
	# A key listed twice is a snapshot still settling: it is never a set anybody starts with,
	# and the budget bounds the wait.
	var roll := _member_states(snapshot)
	if bool(roll.get("duplicate", false)):
		return &"waiting"
	var members: Dictionary = roll.get("members", {})
	if members.size() > capacity:
		return &"incompatible"
	for mark: String in members:
		if bool((members[mark] as Dictionary).get("incompatible", false)):
			return &"incompatible"
	var incomplete := owner.is_empty() or arranged_owner_key.is_empty()
	if not arranged_owner_key.is_empty():
		var owner_mark := fingerprint(arranged_owner_key)
		var owner_state: Dictionary = members.get(owner_mark, {})
		if owner_state.is_empty() or not bool(owner_state.get("connected", false)):
			if _seen_connected.has(owner_mark):
				return &"owner_lost"
			incomplete = true
		else:
			_seen_connected[owner_mark] = true
			if not bool(owner_state.get("known", false)):
				incomplete = true
	for key: Dictionary in frozen_keys:
		var mark := fingerprint(key)
		var state: Dictionary = members.get(mark, {})
		if state.is_empty() or not bool(state.get("connected", false)):
			if _seen_connected.has(mark):
				return &"member_lost"
			incomplete = true
			continue
		_seen_connected[mark] = true
		if not bool(state.get("known", false)) or not bool(state.get("acknowledged", false)):
			incomplete = true
	return &"waiting" if incomplete else &"ready"


## The arranged lobby's native members by fingerprint -- `{"members": {mark: state},
## "duplicate": bool}` -- each with its connection, whether its protocol and match id are known
## and compatible, and the two handoff marks. A key listed twice sets `duplicate`: a duplicated
## native member is never a set anybody starts with.
func _member_states(snapshot: Dictionary) -> Dictionary:
	var states := {}
	var raw_members: Variant = snapshot.get("members", [])
	if typeof(raw_members) != TYPE_ARRAY:
		return {"members": states, "duplicate": false}
	for raw: Variant in raw_members as Array:
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var member := raw as Dictionary
		var key := entity_key(member.get("key", {}))
		if key.is_empty():
			continue
		var mark := fingerprint(key)
		if states.has(mark):
			return {"members": {}, "duplicate": true}
		var raw_properties: Variant = member.get("properties", {})
		var properties: Dictionary = raw_properties as Dictionary if typeof(raw_properties) == TYPE_DICTIONARY else {}
		var protocol := String(properties.get(MatchmakingService.PROTOCOL_MEMBER_KEY, ""))
		var member_match := String(properties.get(PartyService.MATCH_ID_MEMBER_KEY, ""))
		states[mark] = {
			"key": key,
			"connected": bool(member.get("connected", false)),
			"known": not protocol.is_empty() and not member_match.is_empty(),
			"incompatible": (not protocol.is_empty() and not NRProtocol.is_compatible(protocol))
				or (not member_match.is_empty() and member_match != match_id),
			"acknowledged": String(properties.get(PartyService.HANDOFF_READY_MEMBER_KEY, "")) == match_id,
			"retired": String(properties.get(PartyService.STAGING_RETIRED_MEMBER_KEY, "")) == match_id,
		}
	return {"members": states, "duplicate": false}


## The arranged owner's control, decoded, when it is this match's own; otherwise empty.
func _match_control(snapshot: Dictionary) -> Dictionary:
	var raw_control: Variant = snapshot.get("arranged_control", {})
	if typeof(raw_control) != TYPE_DICTIONARY:
		return {}
	var control := raw_control as Dictionary
	if not bool(control.get("valid", false)) or String(control.get("match_id", "")) != match_id:
		return {}
	return control


## Whether the owner's control says this match is already under way without this member: its
## first start chosen without it, or the session already past its first round. Either way the
## member arrived after the cutoff and joins nothing.
func _start_control_excludes_self(party: PartyService, snapshot: Dictionary) -> bool:
	var control := _match_control(snapshot)
	if control.is_empty():
		return false
	if int(control.get("round", 0)) > 0:
		return true
	if String(control.get("phase", "")) != PartyService.ARRANGED_PHASE_STARTING:
		return false
	var local_key := entity_key(party.local_entity_key(arranged_context))
	return not selection_includes(control.get("selected_members", []), [local_key])


## Whether every one of `keys` is in the selected set `selected`, compared as fingerprints.
static func selection_includes(selected: Variant, keys: Array) -> bool:
	if typeof(selected) != TYPE_ARRAY:
		return false
	var marks := {}
	for raw: Variant in selected as Array:
		var key := entity_key(raw)
		if not key.is_empty():
			marks[fingerprint(key)] = true
	if marks.is_empty():
		return false
	for raw: Variant in keys:
		var key := entity_key(raw)
		if key.is_empty() or not marks.has(fingerprint(key)):
			return false
	return true


static func _cohort_failure_text(verdict: StringName) -> String:
	match verdict:
		&"owner_changed":
			return TEXT_MATCH_HOST_CHANGED
		&"owner_lost":
			return TEXT_MATCH_HOST_LEFT
		&"incompatible":
			return TEXT_MATCH_INCOMPATIBLE
		&"member_lost":
			return TEXT_MATCH_MEMBER_LOST
		&"premade_missing":
			return TEXT_MATCH_MISMATCH
		&"lost":
			return TEXT_ARRANGED_CHANGED
		&"late":
			return TEXT_MATCH_ALREADY_STARTED
	return TEXT_MATCH_LATE


## An involuntary loss of the old staging transport after arming. The local session ends
## now, but the replacement network is still prepared only once this member's own premade and
## the pinned owner are ready in the arranged lobby.
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
##
## Nothing is dismantled until this member's own premade and the pinned owner are ready (see
## _premade_verdict()), read again at that last moment; and they are read again after every
## await -- the old network's leave, the privilege check, and the replacement network's own
## creation or join. The owner's network becomes its session only while they still hold; a
## guest's joined network is taken on in the join's own step (see _take_joined_network()). An
## old transport that already went on its own changes nothing about that.
func switch_transport() -> void:
	if not is_current():
		return
	if not staging_reset:
		var premade_ready: bool = await _await_premade()
		if not premade_ready or not is_current():
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
		var still_armed: bool = await _await_premade(Phase.SWITCHING_TRANSPORT)
		if not still_armed:
			return
	# The platform reset cleared the previous session's communications verdict; it is
	# resolved again before any network exists, exactly as hosting and joining do.
	await NetManager._platform.apply_chat_privilege(_handoff_still_current)
	if not is_current():
		return
	var still_ready: bool = await _await_premade(Phase.SWITCHING_TRANSPORT)
	if not still_ready:
		return
	var user: Variant = Services.playfab_user()
	var prepared: PartyService.PartyResult = null
	if arranged_owner:
		var slice := mini(phase_deadline_msec, _clock.deadline_after(OWNER_TRANSPORT_SECONDS))
		prepared = await party.prepare_transport(arranged_context, user, slice)
	else:
		prepared = await party.join_transport(arranged_context, user, phase_deadline_msec)
	_hold_operation(prepared)
	if not is_current():
		return
	if prepared == null or not prepared.ok():
		NetManager._flow_fail(self, _result_reason(prepared, "The match network could not be reached."))
		return
	if not arranged_owner:
		await _take_joined_network(prepared.peer)
		return
	# The arranged lobby kept moving while the network was created. A handoff that stops here
	# uses nothing it got -- no peer, no descriptor -- and the flow's own cleanup leaves that
	# network. Nobody can reach it before its descriptor is published, so it can wait here.
	var network_ready: bool = await _await_premade(Phase.SWITCHING_TRANSPORT)
	if not network_ready:
		return
	# Copied before activation: nothing inside the synchronous block below may ask
	# PartyService anything.
	var permit := prepared.publication_permit
	var peer: Variant = prepared.peer
	_enter_matchmade_session()
	_set_phase(Phase.ADMITTING_COHORT)
	if not NetManager._flow_activate_transport(self, peer, true):
		NetManager._flow_fail(self, "PlayFab Party did not return a usable network peer.")
		return
	NetManager._flow_arm_cohort_deadline(self)
	# The descriptor goes out last, with the round's owner control in the same checked
	# batch, into a lobby still open: matched players still on their way can come in, and
	# the lobby is locked only when the first match starts.
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


## A guest's joined network becomes its session in the same step as the join itself: the
## host's connection is announced right after, and a network taken on any later would never
## hear of it. So this member's own premade and the pinned owner are read once, at once. A known
## loss ends the handoff with nothing of the network used, and the flow's own cleanup leaves
## it. Anything still settling is waited for -- within the handoff budget -- once the network
## is this member's session and before its admission is taken.
func _take_joined_network(peer: Variant) -> void:
	var verdict := _premade_verdict()
	if verdict != &"ready" and verdict != &"waiting":
		NetManager._flow_fail(self, _cohort_failure_text(verdict))
		return
	_enter_matchmade_session()
	_set_phase(Phase.ADMITTING_COHORT)
	if not NetManager._flow_activate_transport(self, peer, false):
		NetManager._flow_fail(self, "PlayFab Party did not return a usable network peer.")
		return
	if verdict == &"waiting":
		var settled: bool = await _await_premade(Phase.ADMITTING_COHORT)
		if not settled:
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
		# The host's identity request, if its proof was still pending, is asked again on
		# every poll as well as on every lobby update, inside this phase's own deadline.
		NetManager._settle_pending_authority()
		if not is_current() or request != admission_request or not request.is_pending():
			return
		# So is a first start already held for this guest: it waits for this admission.
		NetManager._flow_reconcile_pending_start(self)
		if not is_current() or request != admission_request:
			return
		if request.admitted:
			# Still waiting only while the host's proof settles; otherwise answered either way.
			if NetManager._consume_flow_admission(self, request):
				if is_current() and request.succeeded():
					await _retire_staging()
				return
		if _clock.has_expired(phase_deadline_msec):
			NetManager._flow_fail(self, "The match could not be joined in time.")
			return
		await _clock.sleep_seconds(minf(POLL_SECONDS, _clock.remaining_seconds(phase_deadline_msec)))


# --- Initial start, gameplay and rematches --------------------------------------

## The arranged host has chosen the players the first match starts with -- the members who had
## arrived and were ready -- and closed its admission. The start is then one checked
## transaction on the commit budget taken at that choice: the lobby is locked; after the lock
## the chosen players, the owner and the session are read again; the choice is published in
## the arranged lobby; and only then does NetManager start the match through the ordinary
## STARTING path. A chosen player lost, or the lock or the publication not confirmed, ends the
## attempt. The choice is never recalculated into a smaller one, and its budget never renews.
func begin_initial_commit(deadline_msec: int) -> void:
	if not is_current() or not arranged_owner or phase != Phase.ADMITTING_COHORT or selected_keys.is_empty():
		return
	_set_phase(Phase.COMMITTING_START)
	var party := Services.party()
	var locked: PartyService.PartyResult = await party.set_context_locked(arranged_context, true, deadline_msec)
	_hold_operation(locked)
	if not _committing_current():
		return
	if locked == null or not locked.ok() or not bool(party.snapshot(arranged_context).get("membership_locked", false)):
		NetManager._flow_fail(self, _result_reason(locked, TEXT_MATCH_UNSEALED))
		return
	var problem := NetManager._initial_commit_problem(self)
	if problem != &"":
		NetManager.fail_initial_cohort(NetManager._commit_problem_text(problem))
		return
	var control := PartyService.encode_arranged_control(
		match_id, match_round, PartyService.ARRANGED_PHASE_STARTING, start_generation, selected_keys)
	if control.is_empty():
		NetManager._flow_fail(self, TEXT_MATCH_UNSEALED)
		return
	var published: PartyService.PartyResult = await party.post_context_update(
		arranged_context, control, {}, {}, deadline_msec)
	_hold_operation(published)
	if not _committing_current():
		return
	if published == null or not published.ok():
		NetManager._flow_fail(self, _result_reason(published, TEXT_MATCH_UNSEALED))
		return
	NetManager._flow_start_initial_match(self)


func _committing_current() -> bool:
	return is_current() and phase == Phase.COMMITTING_START


## NetManager's match state moved. STARTING commits an initial start or begins a hosted
## rematch round; RUNNING is where the first match's hold on its chosen players ends.
func on_match_state(state: NRTypes.MatchState) -> void:
	if not is_current():
		return
	if NRTypes.has_match_state(state, NRTypes.MatchState.STARTING):
		if phase == Phase.ADMITTING_COHORT:
			_set_phase(Phase.COMMITTING_START)
		elif phase == Phase.REMATCH_GATHERING:
			_set_phase(Phase.GAMEPLAY)
		elif phase == Phase.COMMITTING_START and role == Role.GUEST \
				and session_origin == PartyService.PLAY_ORIGIN_PRIVATE and match_round == 0:
			initial_start_seen = true
			_private_catch_up_wanted = false
	elif NRTypes.has_match_state(state, NRTypes.MatchState.RUNNING):
		if phase == Phase.COMMITTING_START:
			_set_phase(Phase.GAMEPLAY)


## The match ended and this player is back in the lobby. The play session's host opens the
## next round -- its reopen publishes the rematch phase and confirms the unlock before it takes
## anyone -- while a guest waits, at most 45 seconds, for the host to have done so, and may
## leave at any moment. Matchmade or private, the session is the same one it played in.
func on_returned_to_lobby() -> void:
	if not is_current() or phase != Phase.GAMEPLAY or play_context == null:
		return
	if hosts_play_session():
		match_round += 1
		host_returned = true
		_set_phase(Phase.REMATCH_GATHERING)
		return
	host_returned = false
	changed.emit()
	if session_origin == PartyService.PLAY_ORIGIN_PRIVATE:
		reconcile_private()
	else:
		reconcile_arranged()
	if not host_returned:
		NetManager._flow_wait_for_host_return(self)


## Reduces the arranged lobby: its native owner, and the round, phase and first-match choice the
## owner publishes. The owner leaving or changing is terminal in every arranged phase. Before
## the first match starts, one of this member's own premade known gone ends its attempt, host
## or guest; and a guest the owner's published choice leaves out arrived after the cutoff.
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
	if phase == Phase.ADMITTING_COHORT and _premade_member_lost(snapshot):
		NetManager._flow_fail(self, TEXT_MATCH_MEMBER_LOST)
		return
	if arranged_owner:
		return
	var raw_control: Variant = snapshot.get("arranged_control", {})
	var control: Dictionary = raw_control as Dictionary if typeof(raw_control) == TYPE_DICTIONARY else {}
	if not bool(control.get("valid", false)):
		return
	if String(control.get("match_id", "")) != match_id:
		NetManager._flow_fail(self, TEXT_ARRANGED_CHANGED)
		return
	if phase == Phase.ADMITTING_COHORT:
		if _start_control_excludes_self(party, snapshot):
			NetManager._flow_fail(self, TEXT_MATCH_ALREADY_STARTED)
			return
		NetManager._flow_reconcile_pending_start(self)
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


## Whether a member of this member's own frozen premade, once seen connected in the arranged
## lobby, is gone or disconnected now. A key listed twice is a snapshot still settling, not a
## loss: it is judged again on the next update, and the budget bounds the wait.
func _premade_member_lost(snapshot: Dictionary) -> bool:
	var roll := _member_states(snapshot)
	if bool(roll.get("duplicate", false)):
		return false
	var members: Dictionary = roll.get("members", {})
	for key: Dictionary in frozen_keys:
		var mark := fingerprint(key)
		if not _seen_connected.has(mark):
			continue
		var state: Dictionary = members.get(mark, {})
		if state.is_empty() or not bool(state.get("connected", false)):
			return true
	return false


## Reduces a private match's own lobby: its native owner, and the round and phase its owner
## publishes. The owner leaving or changing is terminal. A guest waiting for the first match
## reads its published start again; a guest back from a match learns from the round control
## that the owner has opened the next round. A control naming another session means the lobby
## is no longer this match's.
func reconcile_private() -> void:
	if not is_current() or play_context == null or session_origin != PartyService.PLAY_ORIGIN_PRIVATE:
		return
	if phase not in [Phase.COMMITTING_START, Phase.GAMEPLAY, Phase.REMATCH_GATHERING]:
		return
	var party := Services.party()
	if party == null:
		return
	var snapshot: Dictionary = party.snapshot(play_context)
	var owner := entity_key(snapshot.get("owner_key", {}))
	if not owner.is_empty() and not play_owner.is_empty() and fingerprint(owner) != fingerprint(play_owner):
		NetManager._flow_fail(self, TEXT_MATCH_HOST_CHANGED)
		return
	if role == Role.OWNER:
		return
	var raw_control: Variant = snapshot.get("private_control", {})
	var control: Dictionary = raw_control as Dictionary if typeof(raw_control) == TYPE_DICTIONARY else {}
	if not bool(control.get("valid", false)):
		return
	if String(control.get("session_id", "")) != session_id:
		NetManager._flow_fail(self, TEXT_ARRANGED_CHANGED)
		return
	if phase == Phase.COMMITTING_START:
		NetManager._flow_reconcile_pending_start(self)
		_try_private_catch_up()
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


## The play session host's lobby admission for a rematch round, as one checked transaction:
## the owner-published phase first -- so an invite read after it is admitted or refused on
## the right side -- then the lock. Reopening publishes the rematch phase and confirms the
## unlock; closing publishes gameplay and confirms the lock. A matchmade session publishes its
## own round control, a private one PartyService's private round control for its session; the
## local gate is NetManager's. A refusal is told in this title's words: the service's own are
## for its log.
func set_rematch_open(open: bool) -> bool:
	last_admission_error = ""
	if not is_current() or not hosts_play_session() or play_context == null or phase != Phase.REMATCH_GATHERING:
		last_admission_error = "The match can only be reopened between rounds."
		return false
	var party := Services.party()
	var deadline := _clock.deadline_after(RESTORE_SECONDS)
	var target: String = PartyService.ARRANGED_PHASE_REMATCH if open else PartyService.ARRANGED_PHASE_GAMEPLAY
	var posted: PartyService.PartyResult = null
	if session_origin == PartyService.PLAY_ORIGIN_PRIVATE:
		posted = await party.set_private_round_control(play_context, session_id, match_round, target, deadline)
	else:
		posted = await party.post_context_update(
			play_context, PartyService.encode_arranged_control(match_id, match_round, target), {}, {}, deadline)
	_hold_operation(posted)
	if not is_current() or phase != Phase.REMATCH_GATHERING:
		last_admission_error = "The match has ended."
		return false
	if posted == null or not posted.ok():
		last_admission_error = "The match could not be updated."
		return false
	var locked: PartyService.PartyResult = await party.set_context_locked(play_context, not open, deadline)
	_hold_operation(locked)
	if not is_current() or phase != Phase.REMATCH_GATHERING:
		last_admission_error = "The match has ended."
		return false
	if locked == null or not locked.ok():
		last_admission_error = "The match could not be updated."
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


## Whether the bound session is the flow's play session, whichever route made it: the arranged
## lobby from its admissions on, or the group's own lobby from a private start's commit on.
func in_play_session() -> bool:
	if play_context == null:
		return false
	if phase == Phase.ADMITTING_COHORT:
		return session_origin == PartyService.PLAY_ORIGIN_MATCHMADE
	return phase in [Phase.COMMITTING_START, Phase.GAMEPLAY, Phase.REMATCH_GATHERING]


## Whether this instance hosts the play session: the arranged native owner of a matchmade one,
## the group's own owner of a private one.
func hosts_play_session() -> bool:
	if not in_play_session():
		return false
	if session_origin == PartyService.PLAY_ORIGIN_PRIVATE:
		return role == Role.OWNER
	return arranged_owner


## The owner every member of the play session answers to.
func play_owner_key() -> Dictionary:
	if session_origin == PartyService.PLAY_ORIGIN_PRIVATE:
		return play_owner.duplicate()
	return arranged_owner_key.duplicate()


## Whether this member is a guest waiting for its play session's first match to start: a
## matchmade guest while the arranged host admits and chooses, or a private start's guest from
## the owner's preparation until that match runs.
func awaits_initial_start() -> bool:
	if role == Role.OWNER and phase == Phase.PRIVATE_PREPARING:
		return false
	if hosts_play_session() or match_round != 0:
		return false
	if phase == Phase.ADMITTING_COHORT:
		return session_origin == PartyService.PLAY_ORIGIN_MATCHMADE and not arranged_owner
	if phase == Phase.PRIVATE_PREPARING:
		return role == Role.GUEST
	return phase == Phase.COMMITTING_START and role == Role.GUEST \
		and session_origin == PartyService.PLAY_ORIGIN_PRIVATE


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
	_cancel_private_bound()
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
			_hold_leave(left_lobby)
			var left_transport: PartyService.PartyResult = await party.leave_transport(context)
			_hold_leave(left_transport)
	# A retired ticket or scoped operation the service has not finished with could still
	# act for this player, so the lease -- and with it every online entry -- is held until
	# the service reports it safe, for as long as this is the signed-in account. The wait is
	# shown as quarantine after the cancellation grace; quit and account teardown bound it
	# from outside. Once Party's recovery of it has failed, the lease stays held but nothing
	# more is asked of Party: the flow reports the restart that failure requires.
	var orphaned_since := -1
	while _cleanup_outstanding() and Services != null and Services.is_current_account(account_generation):
		var failure := _cleanup_failure()
		if not failure.is_empty():
			note_cleanup_failed(failure)
		else:
			orphaned_since = _recover_orphaned_cancel(orphaned_since)
		await _clock.sleep_seconds(POLL_SECONDS)
	native_release_finished = true
	native_release_done.emit()


## Returns once the release already under way has finished; at once if it has. For the
## callers that join a release another started.
func wait_native_release() -> void:
	if native_release_finished or not native_release_started:
		return
	await native_release_done


## Party's reason its recovery failed, or empty. Terminal until the title restarts.
func _cleanup_failure() -> String:
	var party: PartyService = Services.party() if Services != null else null
	return party.recovery_error if party != null else ""


## Party's recovery of the cleanup this retired flow still waits on has failed. The lease
## stays held -- nothing that cleanup guarded is safe yet -- and the reason it cannot finish
## is kept for the flow's snapshot and every refusal the lease causes. `reason` is left as
## the outcome that ended the flow.
func note_cleanup_failed(failure: String) -> void:
	if failure.is_empty() or cleanup_error == failure:
		return
	cleanup_error = failure
	changed.emit()


## A cancel that lost its race to a match is normally answered at once, and then nothing is
## owed. One that is not answered would hold the lease for good. That is native cleanup
## trouble, not a search still being cancelled: once it has stood for the cancellation grace,
## with this flow's own lobbies and transports already released, Party's bounded recovery
## resets the Party and Lobby runtime -- never PlayFab itself, the account or its saves -- and
## the confirmed reset discharges the old ticket. Asked again at the same pace for as long as
## it stands, until Party reports that its recovery failed. Returns when the current stand
## began, or -1 while nothing is orphaned.
func _recover_orphaned_cancel(since_msec: int) -> int:
	var orphaned := false
	for attempt: Variant in _unresolved_attempts:
		if attempt != null and bool(attempt.native_terminal) and bool(attempt.cancel_in_flight) \
				and int(attempt.status) == MatchmakingService.STATUS_MATCHED:
			orphaned = true
			break
	if not orphaned:
		return -1
	var now := _clock.now_msec()
	if since_msec < 0:
		return now
	if now - since_msec < int(CANCEL_GRACE_SECONDS * 1000.0):
		return since_msec
	NetManager._flow_request_recovery(self)
	return now


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
