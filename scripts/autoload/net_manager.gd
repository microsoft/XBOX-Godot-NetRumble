extends Node

## Host-authoritative multiplayer over PlayFab Party.
##
## The host creates a Party network and advertises its descriptor on a PlayFab lobby
## keyed by a five-character join code; clients resolve that code to the network via
## the same lobby. See PartyService for the handshake sequence.
##
## Party's PlayFabPartyPeer implements MultiplayerPeerExtension, so it plugs into
## multiplayer.multiplayer_peer like any built-in peer. Godot's high-level
## MultiplayerAPI runs on top of it, so the message layer is declarative @rpc functions
## and the bytes still travel over Party's relay infrastructure.
##
## Authority model: the host runs the simulation and is the sole source of truth for
## damage, scoring and spawning. Clients send only their own input and never author
## gameplay state directly. Any simulation output that appears on a client's screen
## arrived as a snapshot or event from the host.
##
## Reliability tiers: lobby, roster and score traffic uses reliable; per-frame ship
## input and world snapshots use unreliable_ordered. The tier for each message is set
## by the transfer_mode argument in its @rpc annotation.
##
## Mesh topology: a PlayFab Party network is a mesh, not a star. When the host leaves,
## no other peer's transport is disconnected and Godot never raises server_disconnected.
## Host departure is detected explicitly in `_on_peer_disconnected` by checking whether
## the lost peer id equals HOST_PEER_ID.
##
## Identity and trust: a roster entry's XUID arrives over the game's own RPC and is a
## claim, not a credential (XR-047). Display names shown to players come from the
## platform profile service, not from the peer. That verification, along with the rest
## of the platform's view of a session — activity, presence, recent players and chat
## policy — lives in platform_session.gd.
##
## RPC routing note: Godot resolves @rpc calls by the declaring node's scene path.
## Every @rpc entry point must stay declared on this autoload; moving any one to a
## different node changes its route and breaks the wire protocol silently at runtime.
##
## A ready account-owned save store is required for every session, including Practice.

signal roster_changed()
signal player_joined(state: PlayerState)
signal player_left(peer_id: int)
signal match_state_changed(state: NRTypes.MatchState)
signal countdown_changed(seconds_remaining: int)
## Authoritative match clock, in seconds elapsed since the match went live.
signal match_clock_received(elapsed: float)
signal game_mode_changed(mode: NRTypes.GameModeType)
## Voice-chat mesh changed (a control joined/left, or a mute flipped).
signal chat_indicators_changed()
signal chat_message_received(peer_id: int, text: String)
signal chat_text_policy_changed()
signal chat_cleared()
signal player_loaded(peer_id: int)

signal connection_succeeded()
signal connection_failed(reason: String)
signal server_disconnected()
signal host_status_changed(message: String, cancelling: bool)
## Whether the session is taking new players. Raised on every member, host and guest
## alike, so each one can retire or republish its own platform activity — an activity
## outlives the lobby that answers it, and a guest's is just as visible to its friends
## as the host's.
signal join_admission_changed(open: bool)
## The matchmaking flow started, ended, or changed phase or outcome. The lobby redraws
## from flow_snapshot(), PlatformSession re-derives the activity, and InviteRouter learns
## when a flow it waited on has finished releasing.
signal flow_changed()

# --- Simulation traffic. The world node connects to these. -------------------
signal match_created(payload: Dictionary)
signal match_starting(payload: Dictionary)
signal world_snapshot_received(payload: Dictionary)
signal ship_input_received(peer_id: int, movement: Vector2, fire: Vector2, deploy_mine: bool, sequence: int)
signal projectile_spawned_received(payload: Dictionary)
signal projectile_detonated_received(payload: Dictionary)
signal power_up_spawned_received(payload: Dictionary)
signal power_up_collected_received(payload: Dictionary)
signal ship_spawned_received(payload: Dictionary)
signal ship_destroyed_received(payload: Dictionary)
signal asteroid_split_received(payload: Dictionary)
signal score_updated_received(payload: Dictionary)
signal gameplay_event_received(event_type: NRTypes.GameplayEventType, position: Vector2)
signal match_completed_received(payload: Dictionary)

const HOST_PEER_ID := 1

## Practice bots are given peer ids counting down from here. Godot's multiplayer peer
## ids are always positive, so a negative id can never collide with a real peer, and
## anything that looks a bot up by peer id (scoring, the roster, the world's
## ship-per-peer map) works without a second code path.
const BOT_PEER_ID_BASE := -1000
## Ceiling on practice opponents; see NRConst.MAX_PRACTICE_BOTS.
const MAX_PRACTICE_BOTS := NRConst.MAX_PRACTICE_BOTS

## Shown to a peer whose connection completed after the lobby had already started.
## Phrased for the player rather than the protocol: from their side nothing failed,
## the match simply began without them.
const JOIN_REJECTED_IN_PROGRESS := "That match has already started. Ask the host for the code again once it ends."

## Peer id -> PlayerState for everyone currently in the session, host included.
var players: Dictionary = {}
var match_state: NRTypes.MatchState = NRTypes.MatchState.LOADING
var game_mode_type: NRTypes.GameModeType = NRTypes.GameModeType.DEATHMATCH
var join_code: String = ""
## Reason the last host_match attempt failed, for the UI to show. Mirrors the text
## carried by connection_failed. Joins carry their own reason on their JoinRequest.
var last_error: String = ""
## Why the session ended from under this client, for the UI to show. Set immediately
## before server_disconnected is emitted, so a screen handling that signal can say
## whether the host left or the connection dropped rather than guessing.
var last_disconnect_reason: String = ""

var _peer: MultiplayerPeer = null
var _is_offline := false

## Whether the host will admit a peer that finishes connecting right now.
##
## This cannot be derived from `match_state`, because `PLAYERS_JOINING` means two
## different things: the lobby waiting for players, and MatchDirector waiting for
## everyone to finish loading the match scene. Joins are open in the first and must be
## closed in the second, so the session tracks the answer explicitly.
##
## Opened when a lobby is entered and closed the moment the lobby commits to starting.
## Every write goes through _set_accepting_joins so the host's clients and the platform
## activity stay in step: a client that still advertises a joinable activity for a match
## that has started sends its friends into a refusal.
var _accepting_joins := false
## Why the last attempt to open or close the session to new players failed, for the
## lobby to show. Empty when the last transition succeeded.
var last_admission_error: String = ""

## Ship input packets dropped because the transport's sender id and the id inside the
## packet disagreed, plus the timestamp of the last report. See _receive_ship_input.
var _misattributed_input_count := 0
var _misattributed_input_reported_at := 0.0
const _MISATTRIBUTED_INPUT_REPORT_INTERVAL := 5.0

## The platform's view of this session — activity, presence, recent players, chat
## policy and identity verification. Held as a plain object rather than a node: see
## platform_session.gd, which is where the Xbox Requirements work lives.
var _platform: PlatformSession = null
## Set while an internal leave_match() runs as part of starting a new session, so the
## teardown does not clear an activity that is about to be republished.
var _suppress_activity_delete := false

## Why the last chat message was not sent, for the entry dialog that stays open when it
## was refused. Set by send_chat_message() on every failure it can explain (XR-018).
var last_chat_error := ""
var _chat_context := 0
var _chat_view_active := false

const _JOIN_RESULT_POLL_INTERVAL := 0.1
const _JOIN_CODE_TIMEOUT_MESSAGE := "The join attempt timed out. Please try again."

var _join_request_sequence := 0
## The join whose outcome and teardown the session currently belongs to. Set the instant
## a join starts, so a second one arriving mid-await knows it has to take the seat rather
## than share it.
var _active_join_request: JoinRequest = null
## Requests asked to stop, keyed by request id: {"outcome": JoinRequest.Outcome,
## "reason": String}. Separate from the request's own outcome because an abort is a
## request to stop, not the answer -- the answer is written once the teardown it triggers
## has finished, and until then a poll needs to be able to see that a stop was asked for.
var _join_aborts: Dictionary = {}
## Teardown after an abandoned join is single-flight: the join being replaced and the
## replacement waiting on it both arrive here, and detaching the peer or resetting local
## state twice would take down whichever session exists by the time the second one runs.
var _join_cleanup_running := false
signal _join_cleanup_finished()
## Incremented every time a transport is bound; zeroed when the session is torn down.
## Gives each session an identity, which "is there a peer?" cannot: a join that succeeds
## as the host leaves and a join into the *next* session both see a peer, and only this
## tells them apart.
var _session_generation := 0
var _session_sequence := 0
var _session_account_generation := -1
var _host_in_flight := false
var _host_attempt: Dictionary = {}
var _clock: Callable = Time.get_ticks_msec
var _account_teardown_pending := false
var _account_teardown_running := false
var _entry_epoch := 0
const ACCOUNT_NOT_READY := "Sign in and load your saved data before starting a match."
const _PREVIOUS_SESSION_FINISHING := "The previous session operation is still finishing. Please try again."
const _PREVIOUS_SEARCH_FINISHING := "The previous search is still being cancelled. Please try again in a moment."
const _ONLINE_CLEANUP_FINISHING := "The previous multiplayer operation is still finishing. Please try again."
const FLOW_BUSY := "Leave the matchmaking group before starting another match."
const MULTIPLAYER_RECOVERED_REASON := "Matchmaking stopped while multiplayer services recovered."
const _CONTEXT_RECOVERABLE_FAILURE := "The match connection reported a problem and carried on."
const _COMMIT_TIMEOUT := "The match did not start in time."
## Why a guest's join or session ended when its host could not be proven the owner of the
## lobby it joined. The title's own words, whichever entry the guest took; the two match-host
## lines are PartyService's own for an arranged lobby's owner loss, word for word.
const _HOST_LEFT_BEFORE_JOIN := "The host left or is no longer available."
const _HOST_CHANGED_BEFORE_JOIN := "The host changed before you could join the match."
const _HOST_CHANGED := "The host changed, so you left the match."
const _REMATCH_HOST_LEFT := "The match host left or is no longer available."
const _REMATCH_HOST_CHANGED := "The match host changed before you could join the rematch."
const _REMATCH_MOVED := "That rematch had already started, so it could not be joined."
const _MATCH_HOST_LEFT := "The match host left or is no longer available, so the match was closed."
const _MATCH_HOST_CHANGED := "The match host changed, so the match was closed."

## The matchmaking attempt in progress, from its staging lobby to its arranged match, or
## null. Holding one is the online-entry lease: Host, Join and Practice are refused until
## it and its native cleanup have finished, whether or not a transport is bound.
var _flow: MatchmakingFlow = null
var _flow_sequence := 0
## A staging lobby an ordinary invite or connection-string join entered, held until the
## host admits this player and a guest flow adopts it. PartyService keeps it as a scoped
## context rather than the legacy session, so every abort path has to leave it by name.
var _pending_join_context: Variant = null
var _pending_join_kind := ""
## Which destination the pending join's lobby turned out to be -- a matchmaking group
## still gathering, or an arranged or private match's rematch round -- and, for the latter,
## the match or private session, round and owner PartyService proved before Party entry.
var _pending_join_destination := ""
var _pending_join_arranged: Dictionary = {}
## The last owner phase broadcast, kept for a guest flow that is created a moment after
## the broadcast arrived: admission is answered on a poll, the phase on an RPC.
var _last_owner_phase: Dictionary = {}

## Join-result destinations PartyService reports. Opaque to everything but the policy in
## _destination_refusal().
const _DESTINATION_STAGING := "staging_gathering"
const _DESTINATION_REMATCH := "arranged_rematch"
const _DESTINATION_PRIVATE_REMATCH := "private_rematch"
const _INVITE_DESTINATION_REFUSED := "That match cannot be joined from an invitation."

# --- Session-scoped matchmaking admission -----------------------------------
#
# Everything below belongs to the bound session and is cleared, alarms first, by
# _reset_after_leave() -- which the handoff's local reset runs too -- so none of it can
# reach across the staging-to-arranged swap or into a later session.

## The staging owner's answers to guests' state requests: sender peer -> last request id.
## A peer's entry leaves with the peer, so a later member under the same id starts afresh.
var _flow_state_answers: Dictionary = {}
## The initial arranged start this host runs: every proven, compatible arrival of this match
## admitted as it comes, up to capacity, until the host chooses the players the first match
## starts with. Empty otherwise.
## {"flow_id", "match_id", "recovery_epoch", "admitted": fingerprint -> peer,
##  "selected": fingerprint -> key (empty until chosen), "generation", "commit_deadline",
##  "complete" (the choice is made and its commit under way)}
var _cohort_policy: Dictionary = {}
## Arranged-session peers connected but not yet proven: peer -> connect time.
var _arranged_candidates: Dictionary = {}
## A guest's identity request that arrived before its host could be proven the joined
## lobby's owner: the session it arrived on, or 0. Asked again on every lobby update,
## transport event and join or admission poll until the host is proven; never carried into
## another session.
var _pending_identity_session := 0
## Whose lobby this guest's session answers to, captured the moment the join bound its
## transport: {"kind", "session", "account", "context", "recovery_epoch", "owner_key",
## "match_id", "session_id", "round"}, and "proven_owner" once peer 1 has first been proven
## that lobby's owner. Kind is `hosted`, `staging`, `arranged`, `rematch` (a matchmade
## replacement), `private` (a private start's member once it is committed) or
## `private_rematch` (a private match's replacement); the context is null for a hosted lobby.
## Empty on a host, offline, and once the session ends.
var _authority_scope: Dictionary = {}
## The session whose host was disproven, so the failure is reported once.
var _authority_failed_session := 0
## True from the arranged host's activation until the first RUNNING: the first match starts
## only with the players chosen for it, and keeps every one of them through loading and the
## countdown.
var _initial_cohort_armed := false
var _cohort_alarm: OnlineFlowClock.Alarm = null
var _commit_alarm: OnlineFlowClock.Alarm = null
var _host_return_alarm: OnlineFlowClock.Alarm = null
## A matchmade guest's first STARTING, held until the host's published choice of players has
## replicated and names this player and its premade: {"flow_id", "session", "states"
## (received in order), "deadline"}. Empty otherwise. Its expiry is fixed at the first trusted
## receipt and never renewed.
var _pending_start: Dictionary = {}
var _pending_start_alarm: OnlineFlowClock.Alarm = null
## The session on which this guest's own admission completed, or 0: the fact a first start is
## followed on, since the completed request is no longer the active one. A matchmade guest's is
## its flow-owned admission to the arranged session; a group member's is its admission to the
## group, which a private start keeps -- same lobby, same session.
var _flow_admitted_session := 0
## Peers this host has refused on the current session, peer -> session: each is dropped from
## this host's peers at the end of the frame unless it was admitted or reconnected meanwhile.
var _refused_peers: Dictionary = {}


func _ready() -> void:
	Services.account_lost.connect(_on_account_lost)
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	var chat := _chat()
	if chat != null:
		if not chat.chat_changed.is_connected(_on_chat_changed):
			chat.chat_changed.connect(_on_chat_changed)
		chat.text_received.connect(_on_party_text_received)
		chat.text_policy_changed.connect(_on_text_policy_changed)
	PlayerProfile.identity_changed.connect(_on_chat_identity_changed)
	var party := _party()
	if party != null:
		# Party losing the network is the other way a session can end. The transport
		# route below only fires when a *peer* goes away; if Party itself drops the
		# network -- the relay becomes unreachable, the service fails the session, the
		# console loses its connection -- no peer disconnects and Godot reports nothing,
		# so without this the players sit in a match that can no longer send anything.
		if not party.network_lost.is_connected(_on_party_network_lost):
			party.network_lost.connect(_on_party_network_lost)
		if not party.party_failed.is_connected(_on_party_failed):
			party.party_failed.connect(_on_party_failed)
		if not party.cleanup_status_changed.is_connected(_on_party_cleanup_status):
			party.cleanup_status_changed.connect(_on_party_cleanup_status)
		# A scoped matchmaking lobby reports its own membership and property changes; the
		# flow re-reads its group and its search envelope from them. Its transport losses and
		# failures arrive on the two signals above, carrying the lobby's context.
		if not party.context_updated.is_connected(_on_context_changed):
			party.context_updated.connect(_on_context_changed)
		# A scoped lobby's own unexpected terminal loss, independent of its transport.
		if not party.context_lost.is_connected(_on_context_lost):
			party.context_lost.connect(_on_context_lost)
	# The flow re-reads its group on every roster change; that is how a ready group starts
	# a search and how a frozen one notices a player leaving or un-readying.
	roster_changed.connect(_on_roster_changed_for_flow)
	# A lease taken, retired or released changes what online entry has to wait for.
	flow_changed.connect(note_online_cleanup_changed)
	var connectivity: ConnectivityService = Services.connectivity() if Services != null else null
	if connectivity != null:
		connectivity.connectivity_changed.connect(_on_connectivity_changed)
	# Constructed last, because it connects to the signals declared above and expects
	# the services it wraps to already be reachable.
	_platform = PlatformSession.new()


func _on_chat_changed() -> void:
	chat_indicators_changed.emit()
	if _platform != null:
		_platform.apply_chat_restrictions()


func _on_text_policy_changed() -> void:
	chat_text_policy_changed.emit()


func _on_chat_identity_changed() -> void:
	_clear_match_chat()
	var chat := _chat()
	if chat != null:
		chat.invalidate_session()


# --- Session lifecycle ------------------------------------------------------

## True when this instance owns the simulation: an explicit host, or offline play.
func is_host() -> bool:
	return _session_account_is_current() and (_is_offline or (_peer != null and multiplayer.is_server()))


func _session_account_is_current() -> bool:
	return _account_is_current(_session_account_generation)


func _account_is_current(generation: int) -> bool:
	return Services != null and not Services.is_shutting_down() and Services.is_current_account(generation)


func _entry_error(allow_join_cleanup: bool = false) -> String:
	if Services == null or Services.is_shutting_down() or not Services.is_account_ready():
		return ACCOUNT_NOT_READY
	# A matchmaking flow holds the lease with or without a bound transport. Letting Host,
	# Join or Practice through here would globally replace its two lobbies and its ticket
	# without the flow ever retiring them.
	if _flow != null:
		if _flow.is_live():
			return FLOW_BUSY
		var failure := retained_cleanup_failure()
		return failure if not failure.is_empty() else _PREVIOUS_SESSION_FINISHING
	if _host_in_flight or _account_teardown_pending or (_join_cleanup_running and not allow_join_cleanup):
		return _PREVIOUS_SESSION_FINISHING
	return ""


## Why a retired group's held lease can no longer finish: Party's recovery of the native
## cleanup it waits on failed, so nothing releases it before the title restarts. Empty
## while there is no such group, or while its cleanup can still settle -- which is the only
## time "still finishing" is the truth. The lease and every refusal it causes are unchanged;
## this is what they say.
func retained_cleanup_failure() -> String:
	if _flow == null or _flow.is_live():
		return ""
	var party := _party()
	return party.recovery_error if party != null else ""


## The removal callback must not start SDK work. Detach and invalidate now; teardown
## is deferred until the process can safely pump asynchronous platform completions.
func _on_account_lost() -> void:
	_entry_epoch += 1
	_abort_host(ACCOUNT_NOT_READY)
	_platform.invalidate_account()
	# Retired before the early return below: the flow is gone the moment its account is,
	# and its native cleanup waits for the deferred teardown like everything else.
	_retire_flow(true)
	if _account_teardown_pending:
		return
	_account_teardown_pending = true
	note_online_cleanup_changed()
	_connectivity_token += 1
	var party := _party()
	if party != null:
		party.cancel_pending_join()
	if _active_join_request != null:
		_request_join_abort(_active_join_request, JoinRequest.Outcome.CANCELLED, ACCOUNT_NOT_READY)
	_detach_peer()
	_reset_after_leave(false)
	_finish_account_teardown.call_deferred()


func is_account_teardown_pending() -> bool:
	return _account_teardown_pending or _account_teardown_running


func _finish_account_teardown() -> void:
	if _account_teardown_running:
		return
	_account_teardown_running = true
	var party := _party()
	var chat := _chat()
	var flow := _flow
	# A cancel on a ticket that matched first and was never answered, or a failed leave nobody
	# else is recovering, passes to this teardown before the flow's account-bound release stops
	# watching it: this teardown's own global leave runs the recovery that discharges it.
	_claim_owed_cleanup()
	if party != null and (flow != null or _pending_join_context != null):
		# Started before anything scoped is waited on, for the reason leave_match_and_wait()
		# gives; the waits below join it.
		party.leave()
	if flow != null:
		await _release_flow(flow)
	await _release_pending_join_context()
	if party != null:
		await party.leave()
	if chat != null:
		await chat.destroy_control()
	# The last look comes after the last awaited stage. A match that landed on an old ticket,
	# or a leave that failed, while anything above was awaited still owes its cleanup, and is
	# recovered before this teardown counts as finished. Bounded by the existing single-flight
	# recovery. The final check has nothing awaited between it and the flags clearing.
	var final_passes := 0
	while _owed_cleanup_due(true) and final_passes < 2:
		final_passes += 1
		await _recover_owed_cleanup(true)
	_account_teardown_pending = false
	_account_teardown_running = false
	note_online_cleanup_changed()
	# The seat is free again: an obligation deferred to this teardown is looked at once more.
	reconcile_online_cleanup()


# --- Online cleanup that outlives its owner ------------------------------------------
#
# Two obligations can outlive whatever started them: a cancel on a ticket that matched first
# and was never answered -- a match that wins that race is normally answered at once, and then
# nothing is owed -- and a Party lobby or transport whose native leave failed with no
# group or teardown left to recover it -- for example, a late result. Both belong to the
# Multiplayer runtime, not to a flow, a session or an account. While something still holds
# the seat -- a live online session or entry, a group that is live or still draining for
# this account, an account teardown -- that owner discharges them through its own cleanup,
# and a cleanup Party already runs is waited on, never started again. Once nothing does,
# this node does, the same way: Party's existing bounded recovery, confirmed by
# multiplayer_invalidated. Online entry stays refused until the obligation is discharged,
# and says a restart is needed if that recovery fails.

signal _owed_recovery_finished()
var _owed_reconcile_queued := false
var _owed_recovery_running := false


## Something an owed obligation depends on may have changed -- the matchmaking service's
## cleanup, Party's, or what holds the seat. Read again on the next idle frame, never inside
## the callback that changed it, and recovered if it is now this node's to recover.
func reconcile_online_cleanup() -> void:
	if _owed_reconcile_queued:
		return
	_owed_reconcile_queued = true
	_reconcile_online_cleanup.call_deferred()


func _reconcile_online_cleanup() -> void:
	_owed_reconcile_queued = false
	# A teardown under way looks again itself before it counts as finished.
	if _account_teardown_pending or _account_teardown_running:
		return
	await _recover_owed_cleanup(false)


## Whether a matched ticket's unanswered cancel is owed. Level state, read from the service.
func _matchmaking_orphaned() -> bool:
	var matchmaking: MatchmakingService = Services.matchmaking() if Services != null else null
	return matchmaking != null and matchmaking.has_method("has_orphaned_matched_cancel") \
		and bool(matchmaking.call("has_orphaned_matched_cancel"))


## Whether Party holds failed-leave debt, or a recovery it still needs, with none of its own
## cleanup running to discharge it. Level state, read from the service.
func _party_idle_debt() -> bool:
	var party := _party()
	return party != null and party.has_idle_cleanup_debt()


## Whether any online session or entry is live that a runtime reset would end.
func _online_entry_live() -> bool:
	if has_session() and not _is_offline:
		return true
	if _host_in_flight and String(_host_attempt.get("reason", "")).is_empty():
		return true
	return _active_join_request != null and _active_join_request.is_pending() \
		and not _join_aborts.has(_active_join_request.id)


## Whether an owed obligation is this node's to recover now: one is owed, Party can still
## recover it, no group or staging join owns it -- a group live, or draining for this
## account -- and nothing live would be ended by the reset. Party's own cleanup already
## running is not idle debt, so it is waited on rather than claimed. An account teardown
## releases the group and staging join itself, so only what is live counts against it.
func _owed_cleanup_due(in_teardown: bool) -> bool:
	if not _matchmaking_orphaned() and not _party_idle_debt():
		return false
	var party := _party()
	if party == null or not party.recovery_error.is_empty() or not party.has_method("require_recovery"):
		return false
	if not in_teardown:
		if _flow != null and (_flow.is_live() or Services.is_current_account(_flow.account_generation)):
			return false
		if _pending_join_context != null:
			return false
	return not _online_entry_live()


## The stable reason Party logs its recovery under, for whichever obligation is owed.
func _owed_cleanup_reason() -> StringName:
	return &"matchmaking_cancel_unresolved" if _matchmaking_orphaned() else &"party_cleanup_unowned"


## Marks Party's recovery as required for an owed obligation, so the global leave that
## follows runs it. Starts nothing itself.
func _claim_owed_cleanup() -> void:
	if _owed_cleanup_due(true):
		_party().call("require_recovery", _owed_cleanup_reason())


## Runs Party's existing bounded recovery for an owed obligation until it is discharged or
## that recovery fails. Single-flight -- a second caller waits for the one running -- and
## bounded: each pass is one global leave, which joins any leave already under way, and
## there are at most two.
func _recover_owed_cleanup(in_teardown: bool) -> void:
	if _owed_recovery_running:
		await _owed_recovery_finished
		return
	_owed_recovery_running = true
	for _recovery_pass in 2:
		if not _owed_cleanup_due(in_teardown):
			break
		var party := _party()
		party.call("require_recovery", _owed_cleanup_reason())
		await party.leave()
	_owed_recovery_running = false
	_owed_recovery_finished.emit()


## Why online entry must wait on the matchmaking service's own native cleanup, or empty. A
## cancel on a ticket that matched first, still unanswered, is multiplayer cleanup -- or, once
## Party's recovery has failed, a restart -- and never a search still being cancelled.
func _matchmaking_cleanup_error() -> String:
	var matchmaking: MatchmakingService = Services.matchmaking() if Services != null else null
	if matchmaking == null or not matchmaking.has_pending_cleanup():
		return ""
	if _matchmaking_orphaned():
		reconcile_online_cleanup()
		return _online_cleanup_error()
	return _PREVIOUS_SEARCH_FINISHING


# --- Online cleanup readiness --------------------------------------------------------
#
# One reading of whether earlier online work still stands in the way of new online entry.
# `clear`: nothing does. `pending`: it can still settle -- a retired group's lease, an
# account or suspend teardown, Party's own cleanup debt or recovery, or a matchmaking
# ticket's native cleanup with no group left to own it. `restart_required`: Party's recovery
# of it has failed. Host, Join, Quick Match and a buffered invitation all read this one
# answer, so none of them spends an attempt the others would refuse. A live session or group
# is not cleanup: it is the player's current session, asked about separately.

const ONLINE_CLEANUP_CLEAR := &"clear"
const ONLINE_CLEANUP_PENDING := &"pending"
const ONLINE_CLEANUP_RESTART_REQUIRED := &"restart_required"
## Emitted, at most once a frame, after anything online_cleanup_readiness() reads may have
## changed. Level-triggered: read the readiness again rather than trusting any one emission.
signal online_cleanup_changed()
var _online_cleanup_queued := false
## The one look at the group's Gathering a cleanup notice asks for, and what it was asked for.
var _flow_wake_queued := false
var _flow_wake: Dictionary = {}


## `{"state": ONLINE_CLEANUP_*, "reason": String}`, the reason in this title's words.
func online_cleanup_readiness() -> Dictionary:
	var party := _party()
	var party_readiness: Dictionary = party.cleanup_readiness() if party != null else {}
	var party_state := StringName(party_readiness.get("state", PartyService.CLEANUP_CLEAR))
	if party_state == PartyService.CLEANUP_RESTART_REQUIRED:
		var restart := String(party_readiness.get("reason", ""))
		return _online_cleanup(ONLINE_CLEANUP_RESTART_REQUIRED,
			restart if not restart.is_empty() else party.recovery_error)
	if _flow != null and not _flow.is_live():
		return _online_cleanup(ONLINE_CLEANUP_PENDING, _PREVIOUS_SESSION_FINISHING)
	if _account_teardown_pending or _account_teardown_running:
		return _online_cleanup(ONLINE_CLEANUP_PENDING, _PREVIOUS_SESSION_FINISHING)
	if party_state == PartyService.CLEANUP_PENDING:
		# Debt nobody is working off is looked at again, so whatever reads this does not wait
		# on a recovery that no one has started.
		if party.has_idle_cleanup_debt():
			reconcile_online_cleanup()
		return _online_cleanup(ONLINE_CLEANUP_PENDING, _ONLINE_CLEANUP_FINISHING)
	if _flow == null:
		var search := _matchmaking_cleanup_error()
		if not search.is_empty():
			return _online_cleanup(ONLINE_CLEANUP_PENDING, search)
	return _online_cleanup(ONLINE_CLEANUP_CLEAR, "")


static func _online_cleanup(state: StringName, reason: String) -> Dictionary:
	return {"state": state, "reason": reason}


## Why online entry must wait, or stop, for earlier cleanup; empty once it is clear.
func _online_cleanup_refusal() -> String:
	var readiness := online_cleanup_readiness()
	if StringName(readiness.get("state", ONLINE_CLEANUP_CLEAR)) == ONLINE_CLEANUP_CLEAR:
		return ""
	return String(readiness.get("reason", ""))


## Something online_cleanup_readiness() reads may have changed: Party's or the matchmaking
## service's cleanup, the lease, or an account teardown. Announced on the next idle frame --
## never inside the callback that changed it -- once, however many changes arrived.
func note_online_cleanup_changed() -> void:
	if _online_cleanup_queued:
		return
	_online_cleanup_queued = true
	_announce_online_cleanup.call_deferred()


func _announce_online_cleanup() -> void:
	_online_cleanup_queued = false
	online_cleanup_changed.emit()


## A Party or matchmaking cleanup notice: the current group's own Gathering is looked at again,
## once, on the next idle frame -- never inside the callback that sent it -- however many notices
## arrived. A full group whose Ready was waiting only on an earlier search's cleanup can start
## then. The group is judged afresh when it runs: still this flow, its owner, gathering, on the
## same attempt, session and account, with every one of its own checks.
func note_flow_cleanup_changed() -> void:
	var flow := _flow
	if flow == null or not flow.is_current() or not flow.is_owner() or flow.phase != MatchmakingFlow.Phase.GATHERING:
		return
	_flow_wake = {
		"flow_id": flow.id,
		"epoch": flow.epoch,
		"session": _session_generation,
		"account": _session_account_generation,
	}
	if _flow_wake_queued:
		return
	_flow_wake_queued = true
	_wake_gathering_flow.call_deferred()


func _wake_gathering_flow() -> void:
	_flow_wake_queued = false
	var wake := _flow_wake
	_flow_wake = {}
	var flow := _flow
	if wake.is_empty() or flow == null or flow.id != int(wake.get("flow_id", 0)) or not flow.is_current() \
			or not flow.is_owner() or flow.phase != MatchmakingFlow.Phase.GATHERING \
			or flow.epoch != int(wake.get("epoch", -1)) or _session_generation != int(wake.get("session", -1)) \
			or _session_account_generation != int(wake.get("account", -2)) or not _session_account_is_current():
		return
	flow.on_group_changed()


func is_offline() -> bool:
	return _is_offline


func local_peer_id() -> int:
	if _is_offline or multiplayer.multiplayer_peer == null:
		return HOST_PEER_ID
	return multiplayer.get_unique_id()


func local_player() -> PlayerState:
	return players.get(local_peer_id(), null)


## Starts a local simulation using the ready account's platform-managed save store.
func start_offline() -> bool:
	var error := _entry_error()
	if not error.is_empty():
		_fail_connection(error)
		return false
	if _active_join_request != null:
		_fail_connection("A join is still finishing. Cancel it before starting Practice.")
		return false
	leave_match()
	_session_account_generation = Services.account_generation()
	_is_offline = true
	_session_sequence += 1
	_session_generation = _session_sequence
	game_mode_type = NRTypes.GameModeType.DEATHMATCH
	_register_local_player(HOST_PEER_ID)
	_set_accepting_joins(true)
	_set_match_state(NRTypes.MatchState.PLAYERS_JOINING)
	connection_succeeded.emit()
	# No activity: a practice match is not joinable, so advertising one would offer the
	# platform a session nobody can enter.
	_platform.update_presence("Practice match")
	return true


## Creates a Party network and advertises it under a fresh join code. Awaitable;
## resolves once the network is live and the lobby carries its descriptor.
func host_match(mode: NRTypes.GameModeType = NRTypes.GameModeType.DEATHMATCH) -> bool:
	last_error = ""
	var error := _entry_error()
	if not error.is_empty():
		_fail_connection(error)
		return false
	if _active_join_request != null:
		_fail_connection("A join is still finishing. Cancel it before hosting.")
		return false
	# Earlier online cleanup -- a retired group's, an account teardown's, Party's own debt or
	# recovery, or a matchmaking ticket's with no group left -- keeps every online entry closed.
	var cleanup := _online_cleanup_refusal()
	if not cleanup.is_empty():
		_fail_connection(cleanup)
		return false
	var party := _party()
	if party != null and party.is_cleanup_pending():
		_fail_connection(_online_cleanup_error())
		return false
	_host_in_flight = true
	_entry_epoch += 1
	var attempt := {
		"generation": Services.account_generation(), "epoch": _entry_epoch,
		"deadline": _now_msec() + int(NRConst.MATCH_ESTABLISHMENT_SECONDS * 1000.0),
		"reason": "", "ready": false,
	}
	_host_attempt = attempt
	_host_match(mode, attempt)
	while _host_is_current(attempt) and not attempt.ready:
		await _sleep(_JOIN_RESULT_POLL_INTERVAL)
	var hosted: bool = _host_is_current(attempt) and attempt.ready and _peer_is_connected()
	if not hosted:
		if String(attempt.reason).is_empty():
			_abort_host("The match connection ended before hosting completed.")
		host_status_changed.emit(_cleanup_message(), true)
		await _cleanup_after_join()
		last_error = String(attempt.reason)
		if party != null and not party.recovery_error.is_empty() and not last_error.contains(party.recovery_error):
			last_error += "\n" + party.recovery_error
	_host_in_flight = false
	_host_attempt = {}
	if not hosted:
		connection_failed.emit(last_error)
		return false
	var session := _session_generation
	connection_succeeded.emit()
	if not _session_account_is_current() or session != _session_generation or not _peer_is_connected():
		last_error = last_disconnect_reason if not last_disconnect_reason.is_empty() else "The match ended before hosting completed."
		return false
	_platform.publish_activity()
	_platform.update_presence("Hosting a match")
	return hosted


func _host_match(mode: NRTypes.GameModeType, attempt: Dictionary) -> void:
	if not _host_is_current(attempt):
		return
	var resolved: Dictionary = await _resolve_signed_in_user()
	if not _host_is_current(attempt):
		return
	var user: Variant = resolved.get("user")
	if user == null:
		_abort_host(String(resolved.get("error", "Could not host the match.")))
		return
	if _party() == null:
		_abort_host("The multiplayer services are unavailable in this build.")
		return

	_leave_match_internal()
	await _party().leave(false)
	if not _host_is_current(attempt):
		return

	await _platform.apply_chat_privilege(func() -> bool: return _host_is_current(attempt))
	if not _host_is_current(attempt):
		return

	var max_players := Assets.game_mode(mode).player_count
	var mode_name := String(NRTypes.GameModeType.keys()[mode])
	var result: Dictionary = await _party().host(user, max_players, mode_name, int(attempt.deadline))
	if not _host_is_current(attempt):
		return
	if not bool(result.get("ok", false)):
		_abort_host(String(result.get("error", "Could not host the match.")))
		return

	if not _bind_peer(result.get("peer")):
		_abort_host("PlayFab Party did not return a usable network peer.")
		return

	_is_offline = false
	game_mode_type = mode
	join_code = String(result.get("code", ""))

	_register_local_player(HOST_PEER_ID)
	_set_accepting_joins(true)
	_set_match_state(NRTypes.MatchState.PLAYERS_JOINING)
	attempt.ready = true


func _now_msec() -> int:
	return int(_clock.call())


func _offline_reason() -> String:
	var connectivity := Services.connectivity()
	return connectivity.offline_reason() if connectivity != null and not connectivity.is_online() else ""


func _online_cleanup_error() -> String:
	var party := _party()
	if party == null:
		return "The multiplayer services are unavailable in this build."
	if party != null and not party.recovery_error.is_empty():
		return party.recovery_error
	return _ONLINE_CLEANUP_FINISHING


func _cleanup_message() -> String:
	var party := _party()
	if party != null and party.is_cleanup_pending() and not party.cleanup_status.is_empty():
		return party.cleanup_status
	return "Cleaning up the match"


func _host_is_current(attempt: Dictionary) -> bool:
	if not _host_in_flight or _host_attempt != attempt or not String(attempt.reason).is_empty():
		return false
	if not _account_is_current(int(attempt.generation)) or int(attempt.epoch) != _entry_epoch:
		_abort_host(ACCOUNT_NOT_READY)
	elif not _offline_reason().is_empty():
		_abort_host(_offline_reason())
	elif _now_msec() >= int(attempt.deadline):
		_abort_host("Creating the match timed out. Please try again.")
	return String(attempt.reason).is_empty()


func _abort_host(reason: String) -> bool:
	if not _host_in_flight or _host_attempt.is_empty():
		return false
	if String(_host_attempt.reason).is_empty():
		_host_attempt.reason = reason
		var party := _party()
		if party != null:
			party.cancel_pending_join()
		host_status_changed.emit(_cleanup_message(), true)
	return true


func _on_party_cleanup_status(message: String) -> void:
	if _host_in_flight:
		host_status_changed.emit(message, true)
	for abort: Dictionary in _join_aborts.values():
		var request: JoinRequest = abort.request
		request.set_status(message)
	# A retired group holding the lease learns at once that Party's recovery failed, so it
	# stops asking for another and reports the restart-required reason instead.
	var failure := retained_cleanup_failure()
	if not failure.is_empty():
		_flow.note_cleanup_failed(failure)


## Opens a matchmaking group -- a public staging lobby of up to four -- with this player
## as its owner. Awaitable like host_match(); the lobby screen takes over once it returns
## true, and the group then searches for a match of two to four players the moment everyone
## in it is ready.
##
## Refused, with the reason in last_error and before anything is awaited: while matchmaking
## is unavailable; while another session, host or join holds the seat; while an earlier
## session's Party cleanup or recovery is settling; while a retired group's scoped Party work
## or an earlier ticket's cancellation is still draining; while the mode's configuration does
## not fit the matchmaking queue; and while the console is definitively offline. Then the
## lease is claimed and one 45-second budget covers everything the group's opening awaits.
func start_matchmaking(mode: NRTypes.GameModeType = NRTypes.GameModeType.DEATHMATCH) -> bool:
	last_error = ""
	if Services == null or not Services.quick_match_available():
		_fail_connection(Services.quick_match_unavailable_reason() if Services != null else ACCOUNT_NOT_READY)
		return false
	var error := _entry_error()
	if not error.is_empty():
		_fail_connection(error)
		return false
	if _active_join_request != null:
		_fail_connection("A join is still finishing. Cancel it before matchmaking.")
		return false
	# The one reading Host Match, every join and a buffered invitation share: earlier online
	# cleanup -- a retired group's, an account teardown's, Party's own debt or recovery, or a
	# ticket whose cancellation was never confirmed and may still match this player -- keeps
	# the entry closed until it has settled, or says a restart is needed once it cannot.
	var cleanup := _online_cleanup_refusal()
	if not cleanup.is_empty():
		_fail_connection(cleanup)
		return false
	# Party's own leave still running, as Host Match also refuses.
	var party := _party()
	if party != null and (party.is_cleanup_pending() or not party.recovery_error.is_empty()):
		_fail_connection(_online_cleanup_error())
		return false
	# A retired group's lobbies and transports can still be draining after its lease was
	# released -- a timed-out operation's late completion, most often. Starting a new group
	# on top of them would put two sets of scoped work in the same service.
	if party != null and party.has_owned_work():
		_fail_connection(_PREVIOUS_SESSION_FINISHING)
		return false
	var matchmaking := Services.matchmaking()
	# The mode's real configuration, read by the service, not a constant restated here:
	# a Deathmatch retuned away from four players must not quietly open rooms of four. The
	# service checks again at every ticket and at the match.
	var profile: Dictionary = matchmaking.runtime_profile(mode)
	if not bool(profile.get("ok", false)):
		var reason := String(profile.get("reason", ""))
		_fail_connection(reason if not reason.is_empty() else "Quick Match is unavailable for this game mode.")
		return false
	var offline := _offline_reason()
	if not offline.is_empty():
		_fail_connection(offline)
		return false
	# The previous session is cleared before the lease is claimed and before anything is
	# awaited, so this teardown can never reach the flow it is making room for.
	_leave_match_internal()
	var flow := _new_flow(MatchmakingFlow.Role.OWNER, mode)
	flow.capacity = int(profile.get("capacity", MatchmakingFlow.CAPACITY))
	flow.entry_deadline_msec = Services.clock().deadline_after(MatchmakingFlow.ENTRY_SECONDS)
	return await flow.start_owner()


## Starts joining the session behind a five-character join code.
##
## Returns the handle for the attempt immediately, before it has done anything, rather
## than awaiting the answer. That is deliberate: the caller needs to name *this* attempt
## while it is still running — to bind a loading screen's Cancel button to it, and to know
## afterwards whether the answer it is reading is its own. Await the outcome with
## `await NetManager.join_by_code(code).wait()`, or hold the handle and await it later.
func join_by_code(code: String) -> JoinRequest:
	return _begin_join(code, "")


## Starts joining the session behind an accepted platform invite or protocol activation,
## which carries the lobby's connection string rather than a code (XR-064 / XR-124).
## Shares its body with join_by_code so the two paths cannot drift: an invite is the
## likeliest way to arrive at a match that has already started, so it needs the same
## deadline, cancellation and admission handling and not a shortcut around them.
func join_by_invite(connection_string: String) -> JoinRequest:
	return _begin_join("", connection_string)


## Claims the join seat for a new attempt and starts driving it.
##
## Ownership is taken here, synchronously, before anything can await. A join that claimed
## its seat only after resolving sign-in would spend that time invisible, and a second
## join starting in the gap would find the seat empty and believe itself alone.
func _begin_join(code: String, connection_string: String) -> JoinRequest:
	_join_request_sequence += 1
	var request := JoinRequest.new()
	request.id = _join_request_sequence
	request.deadline_msec = _now_msec() + int(NRConst.MATCH_ESTABLISHMENT_SECONDS * 1000.0)
	var error := _entry_error(true)
	if error.is_empty() and _party() == null:
		error = _online_cleanup_error()
	if error.is_empty():
		error = _online_cleanup_refusal()
	if not error.is_empty():
		request.settle(JoinRequest.Outcome.FAILED, error)
		return request
	var previous := _active_join_request
	_active_join_request = request
	_drive_join(request, code, connection_string, previous, Services.account_generation())
	return request


## Requests that a join stop. Scoped to a handle rather than to whichever join is running,
## because the two are not the same once a join has been replaced: an old loading screen
## whose Cancel cancelled "the active join" would cancel the join that replaced it.
##
## The PlayFab addon calls already in flight may still resume later, so this only records
## the request and invalidates PartyService's join token; _drive_join owns the awaited
## teardown and the late-result guard.
func cancel_join(request: JoinRequest) -> void:
	if request == null or not request.is_pending():
		return
	_request_join_abort(request, JoinRequest.Outcome.CANCELLED, "")


## Runs one join from start to answer, under a single deadline that spans both halves of
## joining: finding and connecting to the session, and waiting for the host to admit this
## player. One budget covers both because the player is looking at one loading screen —
## and because restarting the clock after the transport attached is what let a join sit
## indefinitely against a host that was never going to answer.
func _drive_join(request: JoinRequest, code: String, connection_string: String, previous: JoinRequest, generation: int) -> void:
	if previous == null and _join_cleanup_running:
		await _join_cleanup_finished
		if _active_join_request != request:
			request.settle(JoinRequest.Outcome.SUPERSEDED)
			return
	if previous != null:
		# The join being replaced holds the peer and the Party network. Its teardown is
		# awaited before this one builds anything, so the replacement never attaches a
		# transport that the old join's cleanup is about to detach.
		_request_join_abort(previous, JoinRequest.Outcome.SUPERSEDED, "")
		await _finish_aborted_join(previous)
		if _active_join_request != request:
			# A third join arrived during that teardown and took the seat. It owns the
			# session now, so this one stops here rather than competing for it.
			request.settle(JoinRequest.Outcome.SUPERSEDED)
			return
		if _join_aborts.has(request.id):
			await _finish_aborted_join(request)
			return

	# Started, not awaited. The deadline below has to cover the connection as well as the
	# admission that follows it, and it cannot do that from behind an await on the
	# connection itself.
	if not _account_is_current(generation):
		_request_join_abort(request, JoinRequest.Outcome.CANCELLED, ACCOUNT_NOT_READY)
	elif not _party().recovery_error.is_empty():
		_request_join_abort(request, JoinRequest.Outcome.FAILED, _party().recovery_error)
	else:
		_attach_transport(request, code, connection_string, generation)

	while true:
		if not _account_is_current(generation):
			_request_join_abort(request, JoinRequest.Outcome.CANCELLED, ACCOUNT_NOT_READY)
		elif not _offline_reason().is_empty():
			_request_join_abort(request, JoinRequest.Outcome.FAILED, _offline_reason())
		elif _now_msec() >= request.deadline_msec:
			_request_join_abort(request, JoinRequest.Outcome.FAILED, _JOIN_CODE_TIMEOUT_MESSAGE)
		# Cancellation is read before the acceptance, not after it. The host's answer and
		# the player's Cancel can land between the same two polls, and a join the player
		# walked away from must not seat them because the answer arrived first.
		if _join_aborts.has(request.id):
			await _finish_aborted_join(request)
			return
		if _active_join_request != request:
			# A newer join replaced this one and has already torn it down. Stopping here
			# is the point: running the deadline out would tear down the replacement's
			# live session, which by then is the only session there is.
			request.settle(JoinRequest.Outcome.SUPERSEDED)
			return
		# The joined lobby's owner is proven again on every poll: a host's identity request
		# still waiting on it is answered once its facts replicate -- a hosted lobby's can
		# arrive with no notice this title receives -- and a lobby this join can no longer
		# be admitted through, such as one whose own connection is gone, refuses the join
		# now rather than at its deadline. The join's own deadline bounds the wait.
		_recheck_authority()
		if _join_aborts.has(request.id):
			continue
		if request.admitted:
			var consumed: bool = await _consume_admission(request)
			if consumed:
				return
		await _sleep(_JOIN_RESULT_POLL_INTERVAL)


## Builds the transport for one join, then leaves it to the host. A bound peer is not an
## answer: the host still has to admit this player, and _accept_join records that when it
## does, so nothing is settled here and the deadline goes on covering the wait.
func _attach_transport(request: JoinRequest, code: String, connection_string: String, generation: int) -> void:
	var failure := await _join(request, code, connection_string, generation)
	if failure.is_empty():
		return
	if not _is_join_current(request):
		# Abandoned mid-flight; whoever aborted it owns the answer.
		return
	_request_join_abort(request, JoinRequest.Outcome.FAILED, failure)


## Connects one join to its session. Returns an empty string once the peer is bound and
## the host has been asked to admit this player, or the reason it could not get that far.
func _join(request: JoinRequest, code: String, connection_string: String, generation: int) -> String:
	if not _is_join_current(request) or not _account_is_current(generation):
		return ""
	var resolved: Dictionary = await _resolve_signed_in_user()
	if not _is_join_current(request) or not _account_is_current(generation):
		return ""
	if resolved.get("user") == null:
		return String(resolved.get("error", "Could not join the match."))
	var user: Variant = resolved.get("user")

	_leave_match_internal()
	await _party().leave(false)
	if not _is_join_current(request) or not _account_is_current(generation):
		return ""

	await _platform.apply_chat_privilege(func() -> bool: return _is_join_current(request) and _account_is_current(generation))
	if not _is_join_current(request) or not _account_is_current(generation):
		return ""

	var result: Dictionary
	if connection_string.is_empty():
		result = await _party().join(user, code, request.deadline_msec)
	else:
		result = await _party().join_by_connection_string(user, connection_string, request.deadline_msec)
	if not _is_join_current(request) or not _account_is_current(generation):
		# A scoped lobby the join entered is not the legacy session the aborting teardown
		# leaves, so a late success releases it through its own handle.
		await _release_join_result_context(result)
		return ""
	if not bool(result.get("ok", false)):
		var error := String(result.get("error", ""))
		return error if not error.is_empty() else "Could not join the match."

	# Matchmaking lobbies are entered through this same path -- invites, activities and
	# Join Friend all carry a connection string -- and are recognized by the destination
	# PartyService classified before any Party work, never by a join code they lack.
	var kind := String(result.get("kind", ""))
	var destination := String(result.get("destination", ""))
	if not kind.is_empty() or not destination.is_empty():
		var refusal := _destination_refusal(kind, destination)
		if not refusal.is_empty():
			await _release_join_result_context(result)
			return refusal
		_pending_join_kind = kind
		_pending_join_destination = destination
		_pending_join_context = result.get("context")
		_pending_join_arranged = {}
		if destination == _DESTINATION_REMATCH:
			_pending_join_arranged = {
				"match_id": String(result.get("match_id", "")),
				"round": int(result.get("round", 0)),
				"owner_key": MatchmakingFlow.entity_key(result.get("owner_key", {})),
			}
		elif destination == _DESTINATION_PRIVATE_REMATCH:
			_pending_join_arranged = {
				"session_id": String(result.get("private_session_id", "")),
				"round": int(result.get("round", 0)),
				"owner_key": MatchmakingFlow.entity_key(result.get("owner_key", {})),
			}

	if not _bind_peer(result.get("peer")):
		# The abort this failure starts runs the join cleanup, which leaves the Party
		# session and releases a pending staging context by its own handle.
		push_warning("[Net] PlayFab Party did not return a usable network peer for the join.")
		return PartyService.JOIN_FAILED_UNKNOWN
	# Before peer 1 can send anything: the lobby this join entered, and the owner it pinned.
	var scope_kind: StringName = &"hosted"
	if _pending_join_destination == _DESTINATION_REMATCH:
		scope_kind = &"rematch"
	elif _pending_join_destination == _DESTINATION_PRIVATE_REMATCH:
		scope_kind = &"private_rematch"
	elif _pending_join_kind == PartyService.LOBBY_KIND_STAGING:
		scope_kind = &"staging"
	var pinned_owner: Dictionary = _pending_join_arranged.get("owner_key", {})
	_capture_authority_scope(scope_kind, _pending_join_context, pinned_owner,
		String(_pending_join_arranged.get("match_id", "")), int(_pending_join_arranged.get("round", 0)),
		String(_pending_join_arranged.get("session_id", "")))

	_is_offline = false
	join_code = String(result.get("code", ""))
	_set_match_state(NRTypes.MatchState.LOADING)
	return ""


## True while a join still owns the session and has not been asked to stop. A request with
## no id never claimed a seat, so it can never be current: it cannot be cancelled or timed
## out against, and must not be allowed to proceed on the strength of that.
func _is_join_current(request: JoinRequest) -> bool:
	if request == null or request.id == 0 or _active_join_request != request or _join_aborts.has(request.id):
		return false
	if not _offline_reason().is_empty():
		_request_join_abort(request, JoinRequest.Outcome.FAILED, _offline_reason())
	elif _now_msec() >= request.deadline_msec:
		_request_join_abort(request, JoinRequest.Outcome.FAILED, _JOIN_CODE_TIMEOUT_MESSAGE)
	return not _join_aborts.has(request.id)


## Turns the host's provisional acceptance into the join's answer. Returns false only while
## the host's proof is still pending, so the join's own poll asks again.
##
## Acceptance is checked against the session that exists now rather than the one that
## existed when it arrived. The two can differ — the host leaves, the network drops, a
## refusal crosses the acceptance in flight — and the session generation is what tells
## them apart, where "is there a peer?" would happily accept the next session as this one.
## The host is proven the joined lobby's owner again here too, and a rematch replacement's
## round must still be gathering: an earlier proof is not permission once either moved.
func _consume_admission(request: JoinRequest) -> bool:
	if not _is_join_current(request) or not _session_account_is_current() or not _peer_is_connected() or _session_generation == 0 or _session_generation != request.session_id or local_player() == null:
		var reason := last_disconnect_reason
		if reason.is_empty():
			reason = "The match ended before you could join it."
		_request_join_abort(request, JoinRequest.Outcome.FAILED, reason)
		await _finish_aborted_join(request)
		return true
	var verdict := _authority_verdict(true)
	if verdict == &"pending":
		return false
	if verdict != &"proven":
		# Refused through the join's own cleanup, which the next poll finishes.
		_authority_failed(verdict)
		return false
	if not request.settle(JoinRequest.Outcome.SUCCEEDED):
		return true
	# From here the session is admitted: an ordinary hosted one may outlive its lobby's own
	# connection under the host it proved. See _local_lobby_loss_verdict().
	if not _authority_scope.is_empty() and int(_authority_scope.get("session", 0)) == _session_generation:
		_authority_scope["admitted"] = true
	if _active_join_request == request:
		_active_join_request = null
	_join_aborts.erase(request.id)
	# Admitted into a matchmaking lobby: a member of the owner's gathering group, or a
	# replacement in an arranged or private match's rematch round. A flow takes over the scoped
	# lobby the join entered -- a play session's as that session, never as a staging lobby. The
	# admission is recorded for this session: a group that later starts a private match keeps
	# this lobby and session, and its first start is followed on this admission.
	if _pending_join_context != null and _flow == null:
		_flow_admitted_session = _session_generation
		if _pending_join_destination == _DESTINATION_REMATCH:
			var rematch := _new_flow(MatchmakingFlow.Role.GUEST, game_mode_type)
			rematch.start_rematch_guest(_pending_join_context,
				String(_pending_join_arranged.get("match_id", "")),
				int(_pending_join_arranged.get("round", 0)),
				_pending_join_arranged.get("owner_key", {}))
		elif _pending_join_destination == _DESTINATION_PRIVATE_REMATCH:
			var private_rematch := _new_flow(MatchmakingFlow.Role.GUEST, game_mode_type)
			private_rematch.start_private_rematch_guest(_pending_join_context,
				String(_pending_join_arranged.get("session_id", "")),
				int(_pending_join_arranged.get("round", 0)),
				_pending_join_arranged.get("owner_key", {}))
		elif _pending_join_kind == PartyService.LOBBY_KIND_STAGING:
			var flow := _new_flow(MatchmakingFlow.Role.GUEST, game_mode_type)
			flow.start_guest(_pending_join_context)
			if not _last_owner_phase.is_empty():
				flow.on_owner_phase(int(_last_owner_phase.get("epoch", 0)), int(_last_owner_phase.get("phase", 0)),
					_last_owner_phase.get("detail", {}))
		_pending_join_context = null
		_pending_join_kind = ""
		_pending_join_destination = ""
		_pending_join_arranged = {}
	# Published only now, once the join is answered and cannot still be cancelled out from
	# under it. Advertising the session on the strength of an acceptance the player was in
	# the middle of walking away from is the whole reason this is not done in _accept_join.
	connection_succeeded.emit()
	if joined_session_is_live(request):
		_platform.publish_activity()
		var presence := "In a match"
		if _flow != null and not _flow.in_play_session():
			presence = "In a matchmaking group"
		_platform.update_presence(presence)
	return true


## Which matchmaking destinations an ordinary join may enter, once PartyService has
## classified the lobby before any Party work. The unavailable-build fence comes first, so a
## disabled build reports that and nothing else. Then only three destinations are admitted: a
## group that is still gathering, and an arranged or a private match's rematch round. A
## bootstrapping, starting or playing match, a stale round or anything unrecognized is refused,
## however intact the credential that reached it.
func _destination_refusal(kind: String, destination: String) -> String:
	if not Services.quick_match_available():
		return Services.quick_match_unavailable_reason()
	if destination == _DESTINATION_STAGING and kind == PartyService.LOBBY_KIND_STAGING:
		return ""
	if destination == _DESTINATION_REMATCH and kind == PartyService.LOBBY_KIND_ARRANGED:
		return ""
	if destination == _DESTINATION_PRIVATE_REMATCH and kind == PartyService.LOBBY_KIND_PRIVATE:
		return ""
	return _INVITE_DESTINATION_REFUSED


## Records that a join should stop, and why. The answer is not written here: aborting
## starts a teardown, and the request keeps reporting PENDING until that teardown has
## finished, so nothing reads success out of a session still being dismantled.
func _request_join_abort(request: JoinRequest, outcome: JoinRequest.Outcome, reason: String) -> void:
	if request == null or request.id == 0 or _join_aborts.has(request.id):
		return
	if not request.is_pending():
		return
	_join_aborts[request.id] = {"outcome": outcome, "reason": reason, "request": request}
	request.set_status(_cleanup_message())
	# A matchmaking flow's admission request never reaches the global cancellation token:
	# the flow's own contexts carry their operations, and cancelling everything to stop one
	# guest's wait would cut the scoped work the flow still owns.
	if request.is_flow_owned():
		return
	# Invalidates whatever PartyService call this join left in flight. Safe even when a
	# replacement has already claimed the seat: the replacement awaits this teardown
	# before it starts a Party call of its own, so there is nothing newer to invalidate.
	var party := _party()
	if party != null:
		party.cancel_pending_join()


## Tears down an abandoned join and writes its answer. Both the join itself and the
## replacement waiting on it arrive here, which is why the teardown underneath is
## single-flight and why settling is one-shot.
func _finish_aborted_join(request: JoinRequest) -> void:
	if not request.is_pending():
		return
	var abort: Dictionary = _join_aborts.get(request.id, {})
	var outcome: JoinRequest.Outcome = abort.get("outcome", JoinRequest.Outcome.CANCELLED)
	var reason := String(abort.get("reason", ""))
	# The seat is given up before the teardown rather than after. The teardown is awaited,
	# and a join starting inside that wait has to find the seat empty — otherwise it would
	# see this dying request as the owner and take itself for a replacement of it.
	if _active_join_request == request:
		_active_join_request = null
	await _cleanup_after_join()
	var party := _party()
	if outcome != JoinRequest.Outcome.SUPERSEDED and party != null and not party.recovery_error.is_empty():
		outcome = JoinRequest.Outcome.FAILED
		if not reason.contains(party.recovery_error):
			reason = (reason + "\n" if not reason.is_empty() else "") + party.recovery_error
	_join_aborts.erase(request.id)
	if outcome == JoinRequest.Outcome.FAILED and reason.is_empty():
		reason = _JOIN_CODE_TIMEOUT_MESSAGE
	request.settle(outcome, reason)


## Clears the session an abandoned join left behind, exactly once.
##
## A replaced join and its replacement both wait on this, and so does the replaced join's
## own poll loop. Running the teardown per caller would detach the peer and reset local
## state a second time — by which point the only session those calls could reach is the
## replacement's live one.
func _cleanup_after_join() -> void:
	if _join_cleanup_running:
		await _join_cleanup_finished
		return
	_join_cleanup_running = true
	await _leave_match_for_join_abort()
	_join_cleanup_running = false
	_join_cleanup_finished.emit()


## leave_match() with the activity teardown suppressed, for the host/join paths that
## clear any previous session immediately before publishing a new one.
func _leave_match_internal() -> void:
	_suppress_activity_delete = true
	_platform.begin_activity_handover()
	leave_match()
	_platform.end_activity_handover()
	_suppress_activity_delete = false


## Answers a join that is still waiting on the host, because the session it was waiting
## for has ended. Returns true when the join now owns the outcome, which is the caller's
## cue not to raise `server_disconnected` as well: during a pending join the player is
## still on the loading screen, and two failure dialogs for one failure is one too many.
##
## Must run before the leave, so PartyService's in-flight awaits are invalidated by the
## abort rather than left to resume against a torn-down session.
func _abort_join_for_lost_session(reason: String) -> bool:
	var request := _active_join_request
	if request == null or not request.is_pending():
		return false
	# A matchmaking flow's admission request is answered by the flow's own teardown, and
	# the lost session is reported to the lobby that is already on screen.
	if request.is_flow_owned():
		return false
	_request_join_abort(request, JoinRequest.Outcome.FAILED, reason)
	return true


## The reason to show when a join did not leave the player in a live session. Prefers the
## join's own failure, then the reason the session ended underneath it.
func join_failure_reason(request: JoinRequest) -> String:
	if request != null and not request.reason.is_empty():
		return request.reason
	if not last_disconnect_reason.is_empty():
		return last_disconnect_reason
	return "Could not join the match."


## True when a join that reported success is still backed by the session it was admitted
## into.
##
## Success and the screen change it triggers are not the same instant, and the session can
## end in between — the host leaves, the network drops, a refusal crosses the acceptance in
## flight. The admitted generation is compared rather than merely looking for a peer,
## because by the time the caller checks there may well *be* a peer: a different one, from
## a session this join was never admitted to. Every caller that navigates on a successful
## join checks this immediately before it does, because opening the lobby on a session
## that is not this one is exactly the empty roster and missing join code this whole path
## exists to prevent.
func joined_session_is_live(request: JoinRequest) -> bool:
	if not _session_account_is_current() or request == null or not request.succeeded():
		return false
	return _peer_is_connected() and _session_generation != 0 and _session_generation == request.session_id and local_player() != null


func leave_match() -> void:
	# A matchmaking flow is retired first, while its transport is still bound: a guest
	# leaving mid-search tells the owner, and the flow's scoped lobbies and ticket are
	# released through their own handles rather than only by the global leave below.
	_retire_flow()
	_detach_peer()
	# Party teardown is asynchronous (clear the descriptor, leave the lobby, leave the
	# network). Local state is reset immediately so the UI never waits on the service,
	# and PartyService.host/join both re-await leave() before doing anything, so a
	# still-running teardown can't race a new session.
	var party := _party()
	if party != null:
		party.leave()
	_release_pending_join_context()
	_reset_after_leave()


## leave_match() that waits for the Party teardown instead of leaving it running.
##
## leave_match() abandons that teardown deliberately: every ordinary exit lands on a menu,
## and the menus stay responsive while the service unwinds behind them. The shutdown path is
## the one caller that cannot do that, because the statement after it stops the frame loop
## the addons pump their async completions on. Awaiting here is what keeps the frames coming
## until the teardown lands. See main.gd::_quit_now().
func leave_match_and_wait() -> void:
	var flow := _flow
	_retire_flow(true)
	_detach_peer()
	var party := _party()
	if party != null and (flow != null or _pending_join_context != null):
		# Started before anything scoped is waited on: a scoped leave may be settled only by
		# the reset this global cleanup falls back to, so waiting first could wait forever.
		# It stays the one teardown owner; the waits below join it.
		party.leave()
	if flow != null:
		await _release_flow(flow)
	if party != null:
		await party.leave()
	await _release_pending_join_context()
	# Left until the network is actually gone, matching _leave_match_for_join_abort():
	# nothing is waiting to observe the cleared state, and the activity and presence calls
	# this starts are then issued while there are still frames left to carry them.
	_reset_after_leave()


## True while anything this title owns online is still live or still unwinding: a session,
## a matchmaking flow or its quarantine, a staging lobby a join entered, stale PartyService
## results cleaning up their own handles, Party's own cleanup or recovery -- running, or owed
## with nothing yet running it -- or tickets the matchmaking service still owns. The quit path
## waits on all of it, peer or no peer, and starts the leave that works off what is owed.
func has_pending_online_work() -> bool:
	if has_session() or _flow != null or _pending_join_context != null:
		return true
	var party := _party()
	if party != null and (party.has_owned_work() or _party_cleanup_running(party) or party.has_idle_cleanup_debt()):
		return true
	var matchmaking: MatchmakingService = Services.matchmaking() if Services != null else null
	return matchmaking != null and matchmaking.has_pending_cleanup()


## Party's own cleanup is actually running: a global leave inside its grace, or the scoped
## Party/Lobby reset it falls back to. A hosted session whose leave failed leaves exactly
## this behind, with no peer, flow or scoped context to report it, and the native shutdown
## it waits on only lands while frames keep coming. Debt that nothing is running yet is not
## counted -- the drain starts the leave that works it off, rather than waiting for one -- and
## neither is a failed recovery: it is terminal until the title restarts, no wait can finish
## it, and online entry already stays refused with its restart-required reason.
func _party_cleanup_running(party: PartyService) -> bool:
	return party.is_cleanup_running()


## Leaves everything and waits, until `deadline_msec`, for the native work to settle. The
## shutdown drain: bounded by the caller's single quit budget, never renewed here.
##
## Party's own cleanup already running is waited out first. Leaving while it runs would join
## it inside PartyService.leave(), which returns only once it has finished -- and a recovery
## held on a native shutdown may never finish. If the budget runs out first, the drain stops
## there and the caller's deadline ends the quit. Debt nothing is running yet is not waited
## for: the leave started here is what works it off, and that leave is then waited for the
## same way.
func drain_online_work(deadline_msec: int) -> void:
	var party := _party()
	if party != null:
		# Debt nothing is running yet, with no session or group left to leave first, is worked
		# off now by the ordinary leave -- started, not waited for, so the wait below observes
		# it within the same deadline like any other running cleanup.
		if not has_session() and _flow == null and _pending_join_context == null \
				and party.has_idle_cleanup_debt():
			party.leave()
		await _drain_party_cleanup(party, deadline_msec)
		if _party_cleanup_running(party):
			return
	await leave_match_and_wait()
	party = _party()
	if party != null:
		await party.drain_owned_work(deadline_msec)
	var matchmaking: MatchmakingService = Services.matchmaking() if Services != null else null
	if matchmaking != null:
		await matchmaking.drain_owned_work(deadline_msec)


## Polled on the service clock -- in production the engine clock the quit budget is measured
## on -- so the wait keeps frames coming for the native shutdown and ends at the caller's
## deadline. Returns at once when no cleanup is running.
func _drain_party_cleanup(party: PartyService, deadline_msec: int) -> void:
	var clock := Services.clock()
	while _party_cleanup_running(party) and clock.now_msec() < deadline_msec:
		await clock.sleep_seconds(PartyService.POLL_INTERVAL)


func retire_activity_and_wait() -> void:
	await _platform.retire_activity_and_wait()


func _leave_match_for_join_abort() -> void:
	_detach_peer()
	var party := _party()
	if party != null:
		await party.leave()
	await _release_pending_join_context()
	_reset_after_leave()


func _detach_peer() -> void:
	# PlayFabPartyPeer.close() starts its own network leave. PartyService owns that
	# operation; detach Godot first rather than leaving the same network twice.
	_peer = null
	multiplayer.multiplayer_peer = null


func _reset_after_leave(reset_platform: bool = true) -> void:
	_connectivity_token += 1
	_clear_match_chat()
	var chat := _chat()
	if chat != null:
		chat.invalidate_session()
	if reset_platform:
		_platform.reset_after_leave(_suppress_activity_delete)
	_is_offline = false
	_session_account_generation = -1
	if reset_platform:
		_set_accepting_joins(false)
	else:
		_accepting_joins = false
	# The session is gone, so nothing may still claim to have been admitted to it. Zero is
	# never a valid generation, which makes every stale acceptance fail its check.
	_session_generation = 0
	players.clear()
	join_code = ""
	last_chat_error = ""
	last_disconnect_reason = ""
	_last_owner_phase = {}
	_clear_session_admission()
	if reset_platform:
		_set_match_state(NRTypes.MatchState.LOADING)
		roster_changed.emit()
	else:
		match_state = NRTypes.MatchState.LOADING
	# The seat is free again: an obligation deferred to this session is looked at once more.
	reconcile_online_cleanup()


## Drops every piece of matchmaking admission state that belonged to the session just
## ended -- the staging owner's state-request answers, the arranged start's admission and its
## pending candidates, a guest's joined-lobby authority scope with its pending identity
## request and its pending first start, and the admission, commit, host-return and
## pending-start alarms -- cancelling the alarms before letting go of them. The continuing
## flow's own alarms are the flow's.
func _clear_session_admission() -> void:
	for alarm: OnlineFlowClock.Alarm in [_cohort_alarm, _commit_alarm, _host_return_alarm, _pending_start_alarm]:
		if alarm != null:
			alarm.cancel()
	_cohort_alarm = null
	_commit_alarm = null
	_host_return_alarm = null
	_pending_start_alarm = null
	_pending_start = {}
	_flow_admitted_session = 0
	_refused_peers = {}
	_flow_state_answers = {}
	_cohort_policy = {}
	_arranged_candidates = {}
	_pending_identity_session = 0
	_authority_scope = {}
	_authority_failed_session = 0
	_initial_cohort_armed = false


## True while this instance is in a session of any kind — an online match or an offline
## practice match. Used by the lifecycle handler to decide whether a suspend actually
## costs the player anything.
##
## Asks `_peer` rather than `multiplayer.multiplayer_peer`, because the latter is never
## null: Godot seeds it with an OfflineMultiplayerPeer before anything has connected, so
## testing it would report a session from the moment the title boots.
func has_session() -> bool:
	return _is_offline or _peer != null


## Identity of the session in progress, or 0 when there is none. Numbers are never reused,
## so a value captured before an await and compared after it answers "is this still the
## same session?" — which has_session() cannot, having no memory of which one it meant.
## Callers that await a service round trip or a dialog and then act on the session need
## this: by the time they resume, "there is a session" and "there is *this* session" have
## come apart.
func session_id() -> int:
	return _session_generation


## Drops the current session because the title is being suspended (XR-001). Returns true
## when there was a session to drop, so the resume path knows whether to tell the player
## the match ended.
##
## This is leave_match() under a different name and a different contract, kept separate so
## the deadline constraint is stated where it applies rather than inherited by every menu
## exit. The suspend handler runs inside the platform's suspend deadline and the process is
## frozen the moment it returns, so nothing here may await: the peer is closed and all local
## state is reset synchronously, exactly as leave_match() already does, and the asynchronous
## Party teardown it starts is left to finish whenever the title runs again — or not at all,
## if the platform terminates instead of resuming. Either outcome is correct, because the
## network is going away regardless of whether this process is alive to watch it go.
func abandon_for_suspend() -> bool:
	# A matchmaking flow is interrupted by a suspend even between its staging and
	# arranged sessions, when there is no peer to report; the resume notice still owes the
	# player an explanation.
	var had_session := has_session() or (_flow != null and _flow.is_live())
	_entry_epoch += 1
	_abort_host("The game was suspended.")
	_account_teardown_pending = true
	note_online_cleanup_changed()
	if _active_join_request != null:
		_request_join_abort(_active_join_request, JoinRequest.Outcome.CANCELLED, "The game was suspended.")
	var party := _party()
	if party != null:
		party.cancel_pending_join()
	_platform.invalidate_account(true)
	# Retired synchronously; its tickets, lobbies and transport are released by the
	# deferred teardown on resume, exactly like the Party session below.
	_retire_flow(true)
	_detach_peer()
	_reset_after_leave(false)
	return had_session


func finish_suspend_teardown() -> void:
	_platform.resume_activity()
	if _account_teardown_pending:
		await _finish_account_teardown()


## Party and Lobby both require a signed-in PlayFabUser, so there is no guest path into
## multiplayer. The multiplayer privilege is checked here too, so every entry point —
## host, join by code, join by invite and a matchmaking group's opening — is covered by
## one funnel (XR-045).
##
## Returns {"user": Variant, "error": String}: a null user always carries a reason fit to
## show the player. The reason is returned rather than published, because host and join
## report failure differently — hosting emits connection_failed, while a join answers the
## one request that asked for it, and this funnel serves both.
func _resolve_signed_in_user() -> Dictionary:
	if Services == null or Services.is_shutting_down() or not Services.is_account_ready():
		return {"user": null, "error": ACCOUNT_NOT_READY}
	var generation: int = Services.account_generation()
	var user: Variant = Services.playfab_user()
	if user == null:
		return {"user": null, "error": ACCOUNT_NOT_READY}

	var denied := await _multiplayer_privilege_denial()
	if not _account_is_current(generation):
		return {"user": null, "error": ACCOUNT_NOT_READY}
	if not denied.is_empty():
		return {"user": null, "error": denied}
	return {"user": user, "error": ""}


## Blocks host and join when the account may not play online. Returns the reason it was
## refused, or an empty string when it was allowed. Services.can_play_multiplayer()
## offers the system resolution UI first, so a player who fixes the problem there carries
## straight on; only a privilege still denied afterwards becomes a failure.
func _multiplayer_privilege_denial() -> String:
	var verdict: Dictionary = await Services.can_play_multiplayer()
	if bool(verdict.get("granted", true)):
		return ""
	var reason := String(verdict.get("message", ""))
	if reason.is_empty():
		reason = "This account is not allowed to play online."
	return reason


## PlayFabPartyPeer inherits MultiplayerPeerExtension, so it is a MultiplayerPeer as far
## as Godot is concerned and drives every @rpc below.
func _bind_peer(candidate: Variant) -> bool:
	if not Services.is_account_ready() or candidate == null or not (candidate is MultiplayerPeer) \
			or candidate.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED or not _offline_reason().is_empty():
		return false
	_peer = candidate
	_session_account_generation = Services.account_generation()
	# Every session gets a number nothing else will reuse. It is what lets an acceptance
	# say which session it was an acceptance *to*, once there has been more than one.
	_session_sequence += 1
	_session_generation = _session_sequence
	multiplayer.multiplayer_peer = _peer
	return true


func _peer_is_connected() -> bool:
	return _peer != null and _peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED


func _sleep(seconds: float) -> void:
	await Services.clock().sleep_seconds(seconds)


func _party() -> PartyService:
	return Services.party() if Services != null else null


func _chat() -> ChatService:
	return Services.chat() if Services != null else null


# --- Matchmaking flow -------------------------------------------------------
#
# The flow (scripts/services/matchmaking_flow.gd) owns what a matchmaking attempt means;
# NetManager keeps what it must: the transport, the roster, the admission gate and every
# RPC. The underscored functions below are the flow's hooks into that state and are called
# only by MatchmakingFlow.

## Whether a matchmaking flow or its cleanup is still live. has_session() deliberately is
## not this: a flow holds the online-entry lease with no transport bound, between its
## staging and arranged sessions and while quarantined.
func has_online_flow() -> bool:
	return _flow != null


## Whether the current flow is still an active group, as opposed to one that has been
## retired and is only finishing its native cleanup.
func is_online_flow_live() -> bool:
	return _flow != null and _flow.is_live()


## True between binding an invited group's staging transport and the owner's admission
## turning this player into a guest member. Nothing is advertised in that gap: a guest's
## activity describes the group, and the group is not this player's yet.
func is_entering_matchmaking() -> bool:
	return _flow == null and not _pending_join_kind.is_empty()


## What the lobby draws for the current flow, or empty when there is none.
func flow_snapshot() -> Dictionary:
	return _flow.presentation() if _flow != null else {}


## The activity the current flow should publish, or empty when there is no flow.
func flow_social_snapshot() -> Dictionary:
	if _flow == null:
		return {}
	return _flow.social_snapshot(has_session() and not _is_offline and _accepting_joins)


## Players the current session holds: four for a matchmaking group or match, the game
## mode's count otherwise. The roster slots and the published activity read this one
## number, so they cannot disagree about how big the lobby is.
func session_capacity() -> int:
	if _flow != null:
		return MatchmakingFlow.CAPACITY
	var mode := Assets.game_mode(game_mode_type)
	return mode.player_count if mode != null else 0


## Whether players may change readiness or appearance now. A frozen group holds both:
## the ticket describes the group as it was at the freeze.
func can_customize() -> bool:
	return _flow == null or _flow.allows_customization()


## The owner's Cancel Search. Cancellation is confirmed by the service before the group
## is told it can ready up again.
func cancel_matchmaking_search() -> void:
	if _flow != null and _flow.is_current():
		_flow.cancel_search()


## Retries a restoration whose unlock or metadata write was not confirmed.
func retry_matchmaking_restore() -> void:
	if _flow != null and _flow.is_current():
		_flow.retry_restore()


## Records that this member's lobby has shown the current outcome once.
func mark_flow_outcome_presented(presented_epoch: int) -> void:
	if _flow != null:
		_flow.mark_reason_presented(presented_epoch)


## Ends the current flow so an accepted invite can replace it, then waits -- bounded by
## the cancellation grace -- for its native cleanup. True once online entry is safe; false
## while the old work is still quarantined, in which case the invite is kept rather than
## spent on an entry refusal.
func retire_flow_for_replacement() -> bool:
	var flow := _flow
	if flow == null:
		return true
	leave_match()
	var clock := Services.clock()
	var deadline := clock.deadline_after(MatchmakingFlow.CANCEL_GRACE_SECONDS)
	while _flow == flow and not clock.has_expired(deadline):
		await clock.sleep_seconds(MatchmakingFlow.POLL_SECONDS)
	return _flow == null


## Whether `connection_string` is exactly the credential of a lobby this account still
## holds -- the current group, arranged match or hosted session. An exact comparison of the
## opaque strings, nothing parsed or reconstructed: an invite into the lobby the player is
## already in is acknowledged rather than torn down and rejoined, and every other string is
## a different destination.
func holds_connection_string(connection_string: String) -> bool:
	if connection_string.is_empty():
		return false
	var party := _party()
	if party == null:
		return false
	if _flow != null:
		if not _flow.is_live():
			return false
		for context: Variant in _flow.held_contexts():
			if party.lobby_connection_string(context) == connection_string:
				return true
		return false
	if has_session() and not _is_offline:
		return party.lobby_connection_string() == connection_string
	return false


## The match ended and this player is back in the lobby: a flow's arranged session moves
## on to its rematch round. See MatchmakingFlow.on_returned_to_lobby().
func flow_returned_to_lobby() -> void:
	if _flow != null and _flow.is_current():
		_flow.on_returned_to_lobby()


func _new_flow(role: MatchmakingFlow.Role, mode: NRTypes.GameModeType) -> MatchmakingFlow:
	_flow_sequence += 1
	var flow := MatchmakingFlow.new(_flow_sequence, role, Services.account_generation(), _entry_epoch, mode, Services.clock())
	# Bound to the flow's id, not the flow: a connection stored on the flow's own signal that
	# held the flow would keep every retired flow alive for as long as this node lives.
	flow.changed.connect(_on_flow_changed.bind(flow.id))
	_flow = flow
	flow_changed.emit()
	return flow


func _on_flow_changed(flow_id: int) -> void:
	if _flow != null and _flow.id == flow_id:
		flow_changed.emit()


func _on_roster_changed_for_flow() -> void:
	if _flow != null:
		_flow.on_group_changed()


## Retires the current flow for good. `defer_native` leaves its SDK calls to the deferred
## teardown account loss and suspend already run; otherwise its scoped lobbies, transport
## and ticket are released now, in the background, while the lease stays held.
func _retire_flow(defer_native: bool = false) -> void:
	var flow := _flow
	if flow == null or flow.retired:
		return
	flow.retire(defer_native)
	# Its admission request, if any, is settled; the seat must not keep refusing Practice.
	if _active_join_request != null and _active_join_request.is_flow_owned():
		_join_aborts.erase(_active_join_request.id)
		_active_join_request = null
	flow_changed.emit()
	if not defer_native:
		_release_flow(flow)


## Releases a retired flow's native work and, once it has settled, the lease. Past the
## cancellation grace the flow reports itself quarantined, so the menu can say why new
## online entry is still refused. Single-flight: a later caller -- account teardown, the
## quit drain -- joins the release already under way and returns when it has finished,
## never merely because it was started.
func _release_flow(flow: MatchmakingFlow) -> void:
	if flow == null:
		return
	if flow.native_release_started:
		await flow.wait_native_release()
	else:
		_mark_flow_quarantined_after_grace(flow)
		await flow.release_native()
	if _flow == flow:
		_flow = null
		flow_changed.emit()
		# The seat is free again: an obligation deferred to this group is looked at once more.
		reconcile_online_cleanup()


func _mark_flow_quarantined_after_grace(flow: MatchmakingFlow) -> void:
	await Services.clock().sleep_seconds(MatchmakingFlow.CANCEL_GRACE_SECONDS)
	if _flow == flow:
		flow.mark_quarantined()


## The synchronous half of activating a flow transport: bind, set the session, register the
## local player and open the local gate -- or, for an arranged guest, install its fresh
## admission request. Nothing here awaits or asks PartyService anything, so a joiner who
## reaches the network the instant its descriptor is published already finds admission
## open. The caller sets the flow's phase first, so its social veto is in place before the
## registration and gate signals fire.
func _flow_activate_transport(flow: MatchmakingFlow, peer: Variant, hosting: bool) -> bool:
	if flow != _flow or not flow.is_current():
		return false
	if not _bind_peer(peer):
		return false
	_is_offline = false
	game_mode_type = flow.mode
	join_code = ""
	if hosting:
		_register_local_player(HOST_PEER_ID)
		_set_accepting_joins(true)
		_set_match_state(NRTypes.MatchState.PLAYERS_JOINING)
		# The first arranged match's admission: any proven, compatible arrival of this match, up
		# to capacity, from the first connection on. Installed here, inside the await-free
		# activation, so a peer that connects the instant the descriptor lands is already judged.
		if flow.phase == MatchmakingFlow.Phase.ADMITTING_COHORT and flow.arranged_context != null:
			_install_cohort_policy(flow)
	else:
		# Before the arranged host can send anything: the lobby this guest answers to, the
		# owner the handoff pinned and the match it was arranged for.
		_capture_authority_scope(&"arranged", flow.arranged_context, flow.arranged_owner_key,
			flow.match_id, flow.match_round)
		# Created here and nowhere earlier: no request of any kind spans the transport swap,
		# and this one can only be stamped by an acceptance on the session just bound.
		_join_request_sequence += 1
		var request := JoinRequest.new()
		request.id = _join_request_sequence
		request.flow_id = flow.id
		_active_join_request = request
		flow.install_admission_request(request)
		_set_match_state(NRTypes.MatchState.LOADING)
	return true


## The staging lobby is open and published: the owner is in a joinable group.
func _flow_session_opened(flow: MatchmakingFlow) -> void:
	if flow != _flow:
		return
	connection_succeeded.emit()
	_platform.publish_activity()
	_platform.update_presence("In a matchmaking group")


## The staging lobby never opened. Everything the attempt built is released and the reason
## reaches the menu the way a failed host does. The log gets a domain record of it, never the
## reason's own words: PartyService already logged the native side once, safely.
func _flow_start_failed(flow: MatchmakingFlow, reason: String) -> void:
	if flow != _flow:
		return
	push_warning("[Matchmaking] flow_start_failed flow=%d reason=%s" % [flow.id, _flow_end_code(reason)])
	leave_match()
	last_error = reason
	connection_failed.emit(reason)


## A terminal failure once the lobby is on screen: everything is left and the screen is
## told the session ended, with the reason it shows. One domain record goes to the log --
## the flow, its role and phase, and a stable key for the reason -- never the reason's own
## text, which can carry a service's words.
func _flow_fail(flow: MatchmakingFlow, reason: String) -> void:
	if flow != _flow or flow.retired:
		return
	var message := reason if not reason.is_empty() else "The matchmaking group ended."
	push_warning("[Matchmaking] flow_ended flow=%d role=%s entry=%s phase=%d epoch=%d round=%d reason=%s" % [
		flow.id, "owner" if flow.is_owner() else "guest", String(flow.entry_kind), int(flow.phase),
		flow.epoch, flow.match_round, _flow_end_code(message)])
	leave_match()
	last_disconnect_reason = message
	server_disconnected.emit()


## The stable key a flow's terminal reason is logged under: this title's own reasons by
## name, anything else -- a service's or transport's words -- as `other`.
static func _flow_end_code(text: String) -> String:
	var codes := {
		MatchmakingFlow.TEXT_MATCH_ABANDONED: "match_abandoned",
		MatchmakingFlow.TEXT_GROUP_HOST_LEFT: "group_host_left",
		MatchmakingFlow.TEXT_OWNER_CHANGED: "group_host_changed",
		MatchmakingFlow.TEXT_HOST_SILENT: "group_host_silent",
		MatchmakingFlow.TEXT_MATCH_HOST_CHANGED: "match_host_changed",
		MatchmakingFlow.TEXT_MATCH_INCOMPATIBLE: "match_incompatible",
		MatchmakingFlow.TEXT_MATCH_MEMBER_LOST: "match_member_lost",
		MatchmakingFlow.TEXT_MATCH_LATE: "match_late",
		MatchmakingFlow.TEXT_MATCH_UNSEALED: "match_unsealed",
		MatchmakingFlow.TEXT_MATCH_MISMATCH: "match_mismatch",
		MatchmakingFlow.TEXT_HOST_DID_NOT_RETURN: "host_did_not_return",
		MatchmakingFlow.TEXT_ARRANGED_CHANGED: "arranged_changed",
		MatchmakingFlow.TEXT_GROUP_NOT_RETIRED: "group_not_retired",
		MatchmakingFlow.TEXT_OLD_NETWORK_NOT_LEFT: "old_network_not_left",
		MatchmakingFlow.TEXT_PROFILE_CHANGED: "profile_changed",
		MatchmakingFlow.TEXT_CANCELLED: "cancelled",
		MatchmakingFlow.TEXT_ENTRY_TIMEOUT: "entry_timeout",
		MatchmakingFlow.TEXT_UNAVAILABLE: "unavailable",
		_REMATCH_HOST_LEFT: "rematch_host_left",
		_REMATCH_HOST_CHANGED: "rematch_host_changed",
		_REMATCH_MOVED: "rematch_moved",
		_MATCH_HOST_LEFT: "match_host_left",
		_MATCH_HOST_CHANGED: "match_owner_changed",
		MatchmakingFlow.TEXT_MATCH_ALREADY_STARTED: "match_already_started",
		MatchmakingFlow.TEXT_MATCH_JOIN_UNPROVEN: "match_join_unproven",
		MatchmakingFlow.TEXT_MATCH_FULL: "match_full",
		MatchmakingFlow.TEXT_MATCH_HOST_LEFT: "match_host_left_before_start",
		MatchmakingFlow.TEXT_PRIVATE_NOT_STARTED: "private_not_started",
		_COMMIT_TIMEOUT: "commit_timeout",
		MULTIPLAYER_RECOVERED_REASON: "multiplayer_recovered",
	}
	return String(codes.get(text, "other"))


## A retired flow's cleanup is held by a native cancel that has not answered past the
## cancellation grace. The flow still holds the lease, so nothing else can have started and
## there is no session to protect: Party runs its bounded recovery through the ordinary leave,
## and the confirmed reset discharges the old ticket. A recovery that already failed is not
## asked for again: it is terminal until the title restarts, and the flow reports that instead.
func _flow_request_recovery(flow: MatchmakingFlow) -> void:
	if flow != _flow or not flow.retired or has_session():
		return
	var party := _party()
	if party == null or not party.has_method("require_recovery"):
		return
	if not party.recovery_error.is_empty():
		flow.note_cleanup_failed(party.recovery_error)
		return
	party.call("require_recovery", &"matchmaking_cancel_unresolved")
	party.leave()


func _flow_set_admission(open: bool) -> void:
	_set_accepting_joins(open)


## Every human in the group back to unready, replicated by the existing ready RPC.
func _flow_reset_readiness() -> void:
	if not is_host():
		return
	for peer_id: int in players.keys():
		var state: PlayerState = players.get(peer_id, null)
		if state != null and not state.is_bot and state.is_ready:
			_apply_ready_state(peer_id, false)


func _flow_broadcast_phase(flow: MatchmakingFlow, detail: Dictionary) -> void:
	if flow != _flow or _peer == null or not is_host():
		return
	_share(&"_receive_flow_phase", [flow.epoch, int(flow.phase), detail])


func _flow_send_report(epoch: int, phase: int) -> void:
	if _peer == null or is_host():
		return
	_submit_flow_ack.rpc_id(HOST_PEER_ID, epoch, phase)


func _flow_send_leave(epoch: int) -> void:
	if _peer == null or is_host():
		return
	_submit_flow_leave.rpc_id(HOST_PEER_ID, epoch)


## Sends a staging guest's correlated state request to the owner over the staging
## transport. False when there is no staging transport to send it on.
func _flow_request_state(flow: MatchmakingFlow, request_id: int, known_epoch: int) -> bool:
	if flow != _flow or _peer == null or is_host() or _session_generation == 0 \
			or _session_generation != flow.staging_session:
		return false
	_request_flow_state.rpc_id(HOST_PEER_ID, request_id, known_epoch)
	return true


## Answers one guest's state request with what the owner would broadcast now, plus the
## request's id. Only a current staging member proven on this staging transport is
## answered, only once per request id, and never on an arranged session. A private match's
## first start is the one exception after the staging lobby became the play session: see
## _private_start_request_answerable().
func _flow_answer_state_request(sender: int, request_id: int, known_epoch: int = -1) -> void:
	var flow := _flow
	if flow == null or not flow.is_current() or not flow.is_owner() or request_id <= 0:
		return
	if _session_generation == 0 or _session_generation != flow.staging_session:
		return
	if not players.has(sender) or int(_flow_state_answers.get(sender, 0)) >= request_id:
		return
	var party := _party()
	if party == null:
		return
	if flow.staging_context != null:
		var proof: Dictionary = party.admission_proof(flow.staging_context, sender)
		if not bool(proof.get("valid", false)):
			return
	elif not _private_start_request_answerable(flow, party, sender, known_epoch):
		return
	_flow_state_answers[sender] = request_id
	var state := flow.replay_state()
	var detail: Dictionary = state.get("detail", {})
	detail["request_id"] = request_id
	_receive_flow_phase.rpc_id(sender, int(state.get("epoch", 0)), int(state.get("phase", 0)), detail)


## Whether one of a private match's four may be answered about that match's first start: this
## host still hosts the private session it committed, on the same lobby and transport, and
## that first start is still under way in its first round -- at its first STARTING or loading
## after it, not cancelled or anything else; the request is for the attempt the start was
## committed in; and the sender is proven, now, on the peer it held when the group froze, the
## same player, still a connected member of the lobby with a compatible protocol. Nobody else is
## answered, and nothing after the first start has run or ended.
func _private_start_request_answerable(flow: MatchmakingFlow, party: PartyService, sender: int,
		known_epoch: int) -> bool:
	if flow.session_origin != PartyService.PLAY_ORIGIN_PRIVATE or not flow.hosts_play_session() \
			or flow.phase != MatchmakingFlow.Phase.COMMITTING_START or flow.match_round != 0 \
			or flow.play_context == null or known_epoch != flow.epoch or not initial_cohort_pending():
		return false
	if match_state != NRTypes.MatchState.STARTING and match_state != NRTypes.MatchState.PLAYERS_JOINING:
		return false
	if String(_cohort_policy.get("session_id", "")) != flow.session_id or flow.session_id.is_empty():
		return false
	var snapshot: Dictionary = party.snapshot(flow.play_context)
	if not bool(snapshot.get("is_local_owner", false)) \
			or String(snapshot.get("private_session_id", "")) != flow.session_id:
		return false
	var proof: Dictionary = party.admission_proof(flow.play_context, sender)
	if not bool(proof.get("valid", false)):
		return false
	var key := MatchmakingFlow.entity_key(proof.get("entity_key", {}))
	var mark := MatchmakingFlow.fingerprint(key)
	var admitted: Dictionary = _cohort_policy.get("admitted", {})
	if key.is_empty() or not flow.is_private_member(key) or not admitted.has(mark) or int(admitted[mark]) != sender:
		return false
	var raw_properties: Variant = proof.get("member_properties", {})
	var properties: Dictionary = raw_properties as Dictionary if typeof(raw_properties) == TYPE_DICTIONARY else {}
	var protocol := String(properties.get(MatchmakingService.PROTOCOL_MEMBER_KEY, ""))
	return not protocol.is_empty() and NRProtocol.is_compatible(protocol)


# --- Initial arranged start ------------------------------------------------------
#
# The arranged host's first match starts with the players who have arrived -- two, three or
# four -- not a fixed four and not the service's complete match, which the title never learns.
# While players are still arriving, the host admits any proven, compatible member of this
# match as it comes, up to the room's capacity. It chooses the players to start with the
# moment the members present in the arranged lobby are two to four, every one of them
# connected, admitted and done with its old group, its own frozen premade among them. From
# then the choice is fixed: admission closes, the lobby is locked, everything is read again,
# the choice is published and the match starts. A player outside the choice arrived after the
# cutoff and is refused; a chosen player lost before the first RUNNING ends the attempt, never
# a smaller match.

## Installs the first arranged match's admission on the new session: this host admitted, no
## choice made yet, the handoff's remaining budget as the deadline for enough players to arrive.
func _install_cohort_policy(flow: MatchmakingFlow) -> void:
	var admitted := {}
	var party := _party()
	if party != null:
		var local_key := MatchmakingFlow.entity_key(party.local_entity_key(flow.arranged_context))
		if not local_key.is_empty():
			admitted[MatchmakingFlow.fingerprint(local_key)] = HOST_PEER_ID
	_cohort_policy = {
		"flow_id": flow.id,
		"match_id": flow.match_id,
		"recovery_epoch": int(flow.arranged_context.recovery_epoch) if flow.arranged_context != null else -1,
		"admitted": admitted,
		"selected": {},
		"generation": 0,
		"commit_deadline": 0,
		"complete": false,
	}
	_arranged_candidates = {}
	_initial_cohort_armed = true


## Arms the arrival watchdog at the handoff's own deadline. Called by the flow right after the
## synchronous activation, so nothing starts inside that block.
func _flow_arm_cohort_deadline(flow: MatchmakingFlow) -> void:
	if flow != _flow or _cohort_policy.is_empty():
		return
	if _cohort_alarm != null:
		_cohort_alarm.cancel()
	_cohort_alarm = Services.clock().alarm_at(flow.phase_deadline_msec, _on_cohort_deadline.bind(flow.id))


func _on_cohort_deadline(flow_id: int) -> void:
	_cohort_alarm = null
	var flow := _flow
	if flow == null or flow.id != flow_id or not flow.is_current() or _cohort_policy.is_empty():
		return
	if bool(_cohort_policy.get("complete", false)):
		return
	_fail_initial_cohort(MatchmakingFlow.TEXT_MATCH_LATE)


## Records one admitted arrival. Admission completes normally, so the member can begin
## retiring its old staging resources; it chooses nothing by itself -- the choice is asked
## again.
func _record_cohort_admission(peer_id: int) -> void:
	if _cohort_policy.is_empty() or bool(_cohort_policy.get("complete", false)):
		return
	var mark := _player_fingerprint(peer_id)
	if mark.is_empty():
		return
	var admitted: Dictionary = _cohort_policy.get("admitted", {})
	admitted[mark] = peer_id
	_cohort_policy["admitted"] = admitted
	var flow := _flow
	if flow == null or not flow.is_current() or flow.phase != MatchmakingFlow.Phase.ADMITTING_COHORT:
		return
	_try_initial_commit(flow)


## The fingerprint `peer_id` was admitted under, read from the admission itself rather than
## the transport, which may no longer resolve a peer that has just left. Empty if none.
func _admitted_mark_for(peer_id: int) -> String:
	var admitted: Dictionary = _cohort_policy.get("admitted", {})
	for mark: Variant in admitted:
		if int(admitted[mark]) == peer_id:
			return String(mark)
	return ""


## The first match's commit budget, taken once, at the choice: from the first moment the
## present members could start to the first RUNNING. Never re-armed.
func _arm_commit_watchdog(flow: MatchmakingFlow) -> void:
	if _commit_alarm != null or _cohort_policy.is_empty():
		return
	var deadline := Services.clock().deadline_after(MatchmakingFlow.COMMIT_SECONDS)
	_cohort_policy["commit_deadline"] = deadline
	_commit_alarm = Services.clock().alarm_at(deadline, _on_commit_deadline.bind(flow.id))


## The first match's gate, from the choice until the first RUNNING. Every fact is read again
## from Party's authenticated transport and the native lobby, never from what was cached at
## admission: the flow, session and recovery epoch are the ones the choice was made on; the
## lobby's owner is still this host; the roster is exactly the chosen players; and every chosen
## player is natively connected and admitted under one live peer, with a fresh valid proof
## whose authenticated key is the one admitted under that peer id, a compatible protocol and
## this match's id. A member of the arranged lobby outside the choice arrived after the cutoff:
## it is never admitted and never counts here. Synchronous, over the services' cached
## snapshots, so nothing awaits on MatchDirector's start edge. A count alone never satisfies it.
## A private match's first start is judged by _private_cohort_intact() instead.
func initial_cohort_intact() -> bool:
	if _cohort_policy.is_empty() or not _peer_is_connected() or _session_generation == 0:
		return false
	if _flow != null and _flow.session_origin == PartyService.PLAY_ORIGIN_PRIVATE:
		return _private_cohort_intact()
	var flow := _flow
	if flow == null or not flow.is_current() or not flow.hosts_arranged_session() \
			or flow.id != int(_cohort_policy.get("flow_id", 0)) \
			or flow.match_id != String(_cohort_policy.get("match_id", "")):
		return false
	var party := _party()
	var context: Variant = flow.arranged_context
	if party == null or context == null:
		return false
	var epoch := int(_cohort_policy.get("recovery_epoch", -1))
	var keys: Dictionary = _cohort_policy.get("selected", {})
	var admitted: Dictionary = _cohort_policy.get("admitted", {})
	if keys.is_empty() or players.size() != keys.size():
		return false
	var snapshot: Dictionary = party.snapshot(context)
	if int(snapshot.get("recovery_epoch", -1)) != epoch or bool(snapshot.get("disconnected", false)):
		return false
	var owner := MatchmakingFlow.entity_key(snapshot.get("owner_key", {}))
	if owner.is_empty() or MatchmakingFlow.fingerprint(owner) != MatchmakingFlow.fingerprint(flow.arranged_owner_key) \
			or not bool(snapshot.get("is_local_owner", false)):
		return false
	var connected := _connected_native_marks(snapshot)
	if connected.is_empty():
		return false
	var peers := {}
	for mark: Variant in keys:
		if not connected.has(mark) or not admitted.has(mark):
			return false
		var peer_id := int(admitted[mark])
		if peers.has(peer_id) or not players.has(peer_id):
			return false
		peers[peer_id] = true
		if not _cohort_member_proven(party, context, peer_id, String(mark), epoch, flow.match_id, snapshot):
			return false
	return true


## The connected native members of an arranged snapshot, by fingerprint. Empty when any
## key appears twice: a duplicated native member is never a set anybody starts with.
static func _connected_native_marks(snapshot: Dictionary) -> Dictionary:
	var marks := {}
	var raw_members: Variant = snapshot.get("members", [])
	if typeof(raw_members) != TYPE_ARRAY:
		return marks
	for raw: Variant in raw_members as Array:
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var key := MatchmakingFlow.entity_key((raw as Dictionary).get("key", {}))
		if key.is_empty():
			continue
		var mark := MatchmakingFlow.fingerprint(key)
		if marks.has(mark):
			return {}
		if bool((raw as Dictionary).get("connected", false)):
			marks[mark] = true
	return marks


## One chosen player's fresh proof: valid on the arranged context and recovery epoch, its
## authenticated key the one admitted under that peer id, and its member properties a
## compatible nonempty protocol and this match's id.
## This host's own entry is proven from the local player and the lobby's members.
func _cohort_member_proven(party: PartyService, context: Variant, peer_id: int,
		mark: String, epoch: int, match_id: String, snapshot: Dictionary) -> bool:
	var raw_properties: Variant = null
	if peer_id == HOST_PEER_ID and is_host():
		var local_key := MatchmakingFlow.entity_key(party.local_entity_key(context))
		if local_key.is_empty() or MatchmakingFlow.fingerprint(local_key) != mark \
				or int(snapshot.get("recovery_epoch", -2)) != epoch:
			return false
		var raw_members: Variant = snapshot.get("members", [])
		if typeof(raw_members) != TYPE_ARRAY:
			return false
		for raw: Variant in raw_members as Array:
			if typeof(raw) != TYPE_DICTIONARY:
				continue
			var member := raw as Dictionary
			if MatchmakingFlow.fingerprint(MatchmakingFlow.entity_key(member.get("key", {}))) == mark \
					and bool(member.get("connected", false)):
				raw_properties = member.get("properties", {})
				break
	else:
		var proof: Dictionary = party.admission_proof(context, peer_id)
		if not bool(proof.get("valid", false)) or int(proof.get("recovery_epoch", -2)) != epoch:
			return false
		if MatchmakingFlow.fingerprint(MatchmakingFlow.entity_key(proof.get("entity_key", {}))) != mark:
			return false
		raw_properties = proof.get("member_properties", {})
	if typeof(raw_properties) != TYPE_DICTIONARY:
		return false
	var properties := raw_properties as Dictionary
	var protocol := String(properties.get(MatchmakingService.PROTOCOL_MEMBER_KEY, ""))
	return not protocol.is_empty() and NRProtocol.is_compatible(protocol) \
		and String(properties.get(PartyService.MATCH_ID_MEMBER_KEY, "")) == match_id


## The private match's first-start gate, from the commit until the first RUNNING, read afresh at
## every edge as the matchmade one is: the flow and session the commit was made on; the lobby's
## owner still this host; the roster exactly the four who readied; and each of them connected in
## the lobby, on the peer it held when the group froze, with a compatible protocol. The session is
## named by its own id -- no match id, handoff mark or retirement marker is involved.
func _private_cohort_intact() -> bool:
	var flow := _flow
	if flow == null or not flow.is_current() or not flow.hosts_play_session() \
			or flow.session_origin != PartyService.PLAY_ORIGIN_PRIVATE \
			or flow.id != int(_cohort_policy.get("flow_id", 0)) \
			or flow.session_id != String(_cohort_policy.get("session_id", "")):
		return false
	var party := _party()
	var context: Variant = flow.play_context
	if party == null or context == null:
		return false
	var epoch := int(_cohort_policy.get("recovery_epoch", -1))
	var keys: Dictionary = _cohort_policy.get("selected", {})
	var admitted: Dictionary = _cohort_policy.get("admitted", {})
	if keys.is_empty() or players.size() != keys.size():
		return false
	var snapshot: Dictionary = party.snapshot(context)
	if int(snapshot.get("recovery_epoch", -1)) != epoch or bool(snapshot.get("disconnected", false)):
		return false
	var owner := MatchmakingFlow.entity_key(snapshot.get("owner_key", {}))
	if owner.is_empty() or MatchmakingFlow.fingerprint(owner) != MatchmakingFlow.fingerprint(flow.play_owner_key()) \
			or not bool(snapshot.get("is_local_owner", false)):
		return false
	var connected := _connected_native_marks(snapshot)
	if connected.is_empty():
		return false
	var peers := {}
	for mark: Variant in keys:
		if not connected.has(mark) or not admitted.has(mark):
			return false
		var peer_id := int(admitted[mark])
		if peers.has(peer_id) or not players.has(peer_id):
			return false
		peers[peer_id] = true
		if not _private_member_proven(party, context, peer_id, String(mark), epoch, snapshot):
			return false
	return true


## One of the private match's four, read afresh from the lobby's own member facts. This host's
## own entry is proven from the local player and the lobby's members; any other from a valid
## proof on the private match's lobby and recovery epoch, for the same player on the same peer.
## Either way its member properties carry a compatible nonempty protocol. The four joined the
## group, not a match, so no match id is expected of them.
func _private_member_proven(party: PartyService, context: Variant, peer_id: int,
		mark: String, epoch: int, snapshot: Dictionary) -> bool:
	var raw_properties: Variant = null
	if peer_id == HOST_PEER_ID and is_host():
		var local_key := MatchmakingFlow.entity_key(party.local_entity_key(context))
		if local_key.is_empty() or MatchmakingFlow.fingerprint(local_key) != mark \
				or int(snapshot.get("recovery_epoch", -2)) != epoch:
			return false
		var raw_members: Variant = snapshot.get("members", [])
		if typeof(raw_members) != TYPE_ARRAY:
			return false
		for raw: Variant in raw_members as Array:
			if typeof(raw) != TYPE_DICTIONARY:
				continue
			var member := raw as Dictionary
			if MatchmakingFlow.fingerprint(MatchmakingFlow.entity_key(member.get("key", {}))) == mark \
					and bool(member.get("connected", false)):
				raw_properties = member.get("properties", {})
				break
	else:
		var proof: Dictionary = party.admission_proof(context, peer_id)
		if not bool(proof.get("valid", false)) or int(proof.get("recovery_epoch", -2)) != epoch:
			return false
		if MatchmakingFlow.fingerprint(MatchmakingFlow.entity_key(proof.get("entity_key", {}))) != mark:
			return false
		raw_properties = proof.get("member_properties", {})
	if typeof(raw_properties) != TYPE_DICTIONARY:
		return false
	var protocol := String((raw_properties as Dictionary).get(MatchmakingService.PROTOCOL_MEMBER_KEY, ""))
	return not protocol.is_empty() and NRProtocol.is_compatible(protocol)


## A chosen player known to be gone from the play session's lobby, or its owner changed: the
## prompt failure a lobby update can prove before the start edge next looks. Before the choice
## only the owner is judged here -- an arrival leaving just shrinks who is present, and this
## host's own premade is the flow's to judge. Empty when nothing known is wrong.
func _initial_cohort_known_loss(flow: MatchmakingFlow) -> String:
	var party := _party()
	if party == null or flow.play_context == null:
		return MatchmakingFlow.TEXT_ARRANGED_CHANGED
	var snapshot: Dictionary = party.snapshot(flow.play_context)
	var owner := MatchmakingFlow.entity_key(snapshot.get("owner_key", {}))
	if owner.is_empty() or MatchmakingFlow.fingerprint(owner) != MatchmakingFlow.fingerprint(flow.play_owner_key()):
		return MatchmakingFlow.TEXT_MATCH_HOST_CHANGED
	var keys: Dictionary = _cohort_policy.get("selected", {})
	if keys.is_empty():
		return ""
	var states := {}
	var raw_members: Variant = snapshot.get("members", [])
	if typeof(raw_members) == TYPE_ARRAY:
		for raw: Variant in raw_members as Array:
			if typeof(raw) != TYPE_DICTIONARY:
				continue
			var key := MatchmakingFlow.entity_key((raw as Dictionary).get("key", {}))
			if not key.is_empty():
				states[MatchmakingFlow.fingerprint(key)] = bool((raw as Dictionary).get("connected", false))
	for mark: Variant in keys:
		if not bool(states.get(mark, false)):
			return MatchmakingFlow.TEXT_MATCH_MEMBER_LOST
	return ""


## Whether the members present in the arranged lobby can start the first match now, and with
## whom: {"eligible", "keys", "problem"}. Eligible only when two to four members are present
## -- connected or not -- and every one of them is connected, admitted under a live peer with a
## fresh valid proof, on a compatible protocol with this match's id, and done with its old
## group; every player on this host's roster is one of them; this host's own frozen premade is
## all among them; and this host's own old group is retired too. A present member still
## connecting, unproven or not yet done blocks the choice: it is never left out to make the
## count pass. A present member on another protocol or match (`incompatible`) or a changed
## owner (`owner`) is final; every other problem only waits.
func _present_start_eligibility(flow: MatchmakingFlow) -> Dictionary:
	var verdict := {"eligible": false, "keys": [], "problem": &"flow"}
	if flow != _flow or not flow.is_current() or not flow.hosts_arranged_session() \
			or flow.phase != MatchmakingFlow.Phase.ADMITTING_COHORT or _cohort_policy.is_empty() \
			or bool(_cohort_policy.get("complete", false)):
		return verdict
	if Services.clock().has_expired(flow.phase_deadline_msec):
		verdict["problem"] = &"budget"
		return verdict
	var party := _party()
	var context: Variant = flow.arranged_context
	if party == null or context == null:
		return verdict
	var epoch := int(_cohort_policy.get("recovery_epoch", -1))
	var snapshot: Dictionary = party.snapshot(context)
	if bool(snapshot.get("disconnected", false)) or int(snapshot.get("recovery_epoch", -1)) != epoch:
		return verdict
	var owner := MatchmakingFlow.entity_key(snapshot.get("owner_key", {}))
	if owner.is_empty() or MatchmakingFlow.fingerprint(owner) != MatchmakingFlow.fingerprint(flow.arranged_owner_key) \
			or not bool(snapshot.get("is_local_owner", false)):
		verdict["problem"] = &"owner"
		return verdict
	if int(snapshot.get("max_members", flow.capacity)) != flow.capacity:
		verdict["problem"] = &"incompatible"
		return verdict
	var roll := flow._member_states(snapshot)
	var members: Dictionary = roll.get("members", {})
	# A key listed twice is a snapshot still settling, never a set to start with: it waits.
	if bool(roll.get("duplicate", false)):
		verdict["problem"] = &"not_ready"
		return verdict
	if members.size() > flow.capacity:
		verdict["problem"] = &"incompatible"
		return verdict
	for mark: String in members:
		if bool((members[mark] as Dictionary).get("incompatible", false)):
			verdict["problem"] = &"incompatible"
			return verdict
	if members.size() < MatchmakingService.QUEUE_MIN_MATCH_SIZE:
		verdict["problem"] = &"too_few"
		return verdict
	var admitted: Dictionary = _cohort_policy.get("admitted", {})
	for mark: String in members:
		var state: Dictionary = members[mark]
		if not bool(state.get("connected", false)) or not bool(state.get("known", false)) \
				or not bool(state.get("retired", false)) or not admitted.has(mark):
			verdict["problem"] = &"not_ready"
			return verdict
		var peer_id := int(admitted[mark])
		if not players.has(peer_id):
			verdict["problem"] = &"not_ready"
			return verdict
		if not _cohort_member_proven(party, context, peer_id, mark, epoch, flow.match_id, snapshot):
			verdict["problem"] = &"not_ready"
			return verdict
	for peer_id: int in players:
		if not members.has(_player_fingerprint(peer_id)):
			verdict["problem"] = &"not_ready"
			return verdict
	for key: Dictionary in flow.frozen_keys:
		if not members.has(MatchmakingFlow.fingerprint(key)):
			verdict["problem"] = &"premade"
			return verdict
	if not flow.staging_retired or not flow.retirement_reported:
		verdict["problem"] = &"local_retirement"
		return verdict
	var keys: Array[Dictionary] = []
	for mark: String in members:
		keys.append((members[mark] as Dictionary).get("key", {}))
	verdict["eligible"] = true
	verdict["keys"] = keys
	verdict["problem"] = &""
	return verdict


## The one decision that may start the first match. Idempotent, and asked again whenever an
## arrival is admitted or leaves, this host's own staging retirement completes or the arranged
## lobby moves. Anything not yet true waits: the watchdogs, not this decision, end a wait that
## runs out. A present member on another protocol or match, or a changed owner, ends it now.
func _try_initial_commit(flow: MatchmakingFlow) -> void:
	if flow != _flow or not flow.is_current() or flow.phase != MatchmakingFlow.Phase.ADMITTING_COHORT:
		return
	if _cohort_policy.is_empty() or bool(_cohort_policy.get("complete", false)):
		return
	var eligibility := _present_start_eligibility(flow)
	match StringName(eligibility.get("problem", &"")):
		&"incompatible":
			_fail_initial_cohort(MatchmakingFlow.TEXT_MATCH_INCOMPATIBLE)
			return
		&"owner":
			_fail_initial_cohort(MatchmakingFlow.TEXT_MATCH_HOST_CHANGED)
			return
	if not bool(eligibility.get("eligible", false)):
		return
	_begin_initial_commit(flow, eligibility.get("keys", []))


## What still stands between the chosen players and the first match's start, or empty:
## `flow` for a flow or session that is no longer this start's, `budget` for a spent commit
## budget, `owner` for an arranged lobby whose owner is no longer this host, `cohort` for a
## chosen player not freshly proven, `local_retirement` for this host's own staging
## retirement not confirmed and reported, `markers` for a chosen player whose staging
## retirement the arranged lobby does not show.
func _initial_commit_problem(flow: MatchmakingFlow) -> StringName:
	if flow != _flow or not flow.is_current() or not flow.hosts_play_session() \
			or not _initial_cohort_armed or _cohort_policy.is_empty():
		return &"flow"
	var clock := Services.clock()
	var commit_deadline := int(_cohort_policy.get("commit_deadline", 0))
	if commit_deadline <= 0 or clock.has_expired(commit_deadline):
		return &"budget"
	if _initial_cohort_known_loss(flow) == MatchmakingFlow.TEXT_MATCH_HOST_CHANGED:
		return &"owner"
	if not initial_cohort_intact():
		return &"cohort"
	# A private match is the group's own lobby: there is no old group to have left.
	if flow.session_origin == PartyService.PLAY_ORIGIN_PRIVATE:
		return &""
	if not flow.staging_retired or not flow.retirement_reported:
		return &"local_retirement"
	if not _cohort_retirement_reported(flow):
		return &"markers"
	return &""


## Whether every chosen player -- this host included -- is connected in the arranged lobby and
## carries this match's staging-retirement marker, which each member writes itself only after
## its own old staging lobby and transport were left and quiescent.
func _cohort_retirement_reported(flow: MatchmakingFlow) -> bool:
	var party := _party()
	if party == null or flow.arranged_context == null or flow.match_id.is_empty():
		return false
	var reported := {}
	var raw_members: Variant = party.snapshot(flow.arranged_context).get("members", [])
	if typeof(raw_members) != TYPE_ARRAY:
		return false
	for raw: Variant in raw_members as Array:
		if typeof(raw) != TYPE_DICTIONARY or not bool((raw as Dictionary).get("connected", false)):
			continue
		var key := MatchmakingFlow.entity_key((raw as Dictionary).get("key", {}))
		var raw_properties: Variant = (raw as Dictionary).get("properties", {})
		if key.is_empty() or typeof(raw_properties) != TYPE_DICTIONARY:
			continue
		if String((raw_properties as Dictionary).get(PartyService.STAGING_RETIRED_MEMBER_KEY, "")) == flow.match_id:
			reported[MatchmakingFlow.fingerprint(key)] = true
	var keys: Dictionary = _cohort_policy.get("selected", {})
	for mark: Variant in keys:
		if not reported.has(mark):
			return false
	return not keys.is_empty()


static func _commit_problem_text(problem: StringName) -> String:
	match problem:
		&"cohort":
			return MatchmakingFlow.TEXT_MATCH_MEMBER_LOST
		&"owner":
			return MatchmakingFlow.TEXT_MATCH_HOST_CHANGED
		&"local_retirement", &"markers":
			return MatchmakingFlow.TEXT_GROUP_NOT_RETIRED
		&"budget":
			return _COMMIT_TIMEOUT
	return MatchmakingFlow.TEXT_MATCH_LATE


## This host's own staging retirement is confirmed and reported: the start decision is asked
## again.
func _flow_staging_retired(flow: MatchmakingFlow) -> void:
	if flow == _flow and flow.hosts_arranged_session():
		_try_initial_commit(flow)


## Whether the play session's first match still holds its chosen players -- true from the
## arranged host's activation, or a private start's commit, until that match first runs.
func initial_cohort_pending() -> bool:
	return _initial_cohort_armed and _flow != null and _flow.hosts_play_session()


## The first match reached RUNNING with its chosen players intact. From here departures and
## later rounds follow the ordinary hosted rules.
func consume_initial_cohort() -> void:
	if not _initial_cohort_armed:
		return
	_initial_cohort_armed = false
	if _commit_alarm != null:
		_commit_alarm.cancel()
	_commit_alarm = null
	_cohort_policy = {}
	_arranged_candidates = {}


## The first match cannot start with the players chosen for it. It is cancelled, not started
## with fewer, and the whole flow ends with the reason.
func fail_initial_cohort(reason: String) -> void:
	_fail_initial_cohort(reason)


func _fail_initial_cohort(reason: String) -> void:
	var flow := _flow
	_initial_cohort_armed = false
	if flow != null:
		_flow_fail(flow, reason)


## The choice, reached only through the one decision above, and the start of its commit. In
## one synchronous step the players are fixed with start generation 1; the 30-second commit
## budget is taken now -- at the first moment the present members could start, never at an
## assumed fourth arrival; admission closes; the arrival watchdog is dropped; and the chosen
## players are readied once by the host itself -- the public ready and appearance mutators stay
## closed while the group is frozen. The flow then locks, reads everything again, publishes the
## choice and starts, on that one budget.
func _begin_initial_commit(flow: MatchmakingFlow, keys: Array) -> void:
	if _cohort_policy.is_empty() or bool(_cohort_policy.get("complete", false)) \
			or flow.phase != MatchmakingFlow.Phase.ADMITTING_COHORT \
			or keys.size() < MatchmakingService.QUEUE_MIN_MATCH_SIZE:
		return
	var selected := {}
	var chosen: Array[Dictionary] = []
	for raw: Variant in keys:
		var key := MatchmakingFlow.entity_key(raw)
		if key.is_empty():
			return
		selected[MatchmakingFlow.fingerprint(key)] = key
		chosen.append(key)
	_cohort_policy["selected"] = selected
	_cohort_policy["generation"] = 1
	_cohort_policy["complete"] = true
	flow.selected_keys = chosen
	flow.start_generation = 1
	if _cohort_alarm != null:
		_cohort_alarm.cancel()
	_cohort_alarm = null
	_arm_commit_watchdog(flow)
	_set_accepting_joins(false)
	for peer_id: int in players.keys():
		_apply_ready_trusted(peer_id, true)
	flow.begin_initial_commit(int(_cohort_policy.get("commit_deadline", 0)))


func _on_commit_deadline(flow_id: int) -> void:
	_commit_alarm = null
	var flow := _flow
	if flow == null or flow.id != flow_id or not flow.is_current() or not _initial_cohort_armed:
		return
	_fail_initial_cohort(_COMMIT_TIMEOUT)


## Readiness set by the host on a player's behalf, outside the public mutators: only the
## initial commit uses it, once.
func _apply_ready_trusted(peer_id: int, is_ready: bool) -> void:
	var state: PlayerState = players.get(peer_id, null)
	if state == null or state.is_ready == is_ready:
		return
	state.is_ready = is_ready
	if not _is_offline:
		_share(&"_receive_ready_state", [peer_id, is_ready])
	roster_changed.emit()


## The commit's lock is confirmed, the chosen players and owner read again and the choice
## published: the match starts through the ordinary STARTING path every screen already follows.
func _flow_start_initial_match(flow: MatchmakingFlow) -> void:
	if flow != _flow or not flow.is_current():
		return
	var problem := _initial_commit_problem(flow)
	if problem != &"":
		_fail_initial_cohort(_commit_problem_text(problem))
		return
	set_match_state(NRTypes.MatchState.STARTING)


# --- A private match's first start ------------------------------------------------------
#
# A full group's private start commits on the group's own lobby, session and roster: nobody is
# admitted and nothing is handed off. Its first match starts with exactly the four who readied
# -- through the same first-start gate a matchmade match uses, the same loading and countdown,
# and a 30-second budget taken at the commit -- and loses any one of them only by ending.

## The owner's private start is committed. The four who readied become the first match's
## players, admitted under the peers they already hold; the commit is broadcast with the
## session's id, ahead of the start itself on the same ordered channel; and the match starts.
func _flow_commit_private_start(flow: MatchmakingFlow) -> void:
	if flow != _flow or not flow.is_current() or not flow.hosts_play_session():
		return
	_install_private_policy(flow)
	_arm_commit_watchdog(flow)
	_flow_broadcast_phase(flow, {"session_id": flow.session_id})
	for peer_id: int in players.keys():
		_apply_ready_trusted(peer_id, true)
	_flow_start_initial_match(flow)


## The private start's first-match policy: its four, admitted under the peers they held when the
## group froze, fixed from now until that match runs. No arrival is judged; there are none.
func _install_private_policy(flow: MatchmakingFlow) -> void:
	var admitted := {}
	var selected := {}
	for raw_peer: Variant in flow.frozen_peers:
		var key := MatchmakingFlow.entity_key(flow.frozen_peers[raw_peer])
		if key.is_empty():
			continue
		var mark := MatchmakingFlow.fingerprint(key)
		admitted[mark] = int(raw_peer)
		selected[mark] = key
	_cohort_policy = {
		"flow_id": flow.id,
		"origin": PartyService.PLAY_ORIGIN_PRIVATE,
		"match_id": "",
		"session_id": flow.session_id,
		"recovery_epoch": int(flow.play_context.recovery_epoch) if flow.play_context != null else -1,
		"admitted": admitted,
		"selected": selected,
		"generation": 1,
		"commit_deadline": 0,
		"complete": true,
	}
	_arranged_candidates = {}
	_initial_cohort_armed = true


## A private start's guest has taken the owner's commit: the group's lobby is now its play
## session, and this session answers to the same owner there, for this private match. A first
## start already held is looked at again.
func _flow_private_committed(flow: MatchmakingFlow) -> void:
	if flow != _flow or not flow.is_current() or is_host():
		return
	var pinned := MatchmakingFlow.entity_key(_authority_scope.get("proven_owner", {}))
	if pinned.is_empty():
		pinned = flow.play_owner_key()
	_capture_authority_scope(&"private", flow.play_context, pinned, "", 0, flow.session_id)
	_flow_reconcile_pending_start(flow)


# --- A guest's first start --------------------------------------------------------

## Whether a trusted match state must wait for, or is refused by, the host's published choice
## of players for the first match. Only a guest's first start in a play session is judged --
## matchmade or private -- and everything else passes. The start is followed only once that
## choice is this session's current start and names this player and its whole frozen group,
## this session's own admission has completed, and the host is proven, now, the owner of the
## lobby this guest joined. Until then one pending start is kept, with any later state queued
## behind it, and its expiry is fixed now, at the first trusted receipt: the earlier of the
## phase deadline and this receipt plus the commit budget. Nothing received later renews it,
## and neither does the admission completing. A choice that leaves this player or its group out
## is refused at once.
func _hold_initial_start(state: NRTypes.MatchState) -> bool:
	var flow := _flow
	if not _pending_start.is_empty():
		if flow == null or int(_pending_start.get("flow_id", 0)) != flow.id \
				or int(_pending_start.get("session", 0)) != _session_generation:
			_clear_pending_start()
			return false
		var queued: Array = _pending_start.get("states", [])
		queued.append(int(state))
		_pending_start["states"] = queued
		return true
	if flow == null or not flow.is_current() or not flow.awaits_initial_start():
		return false
	if not NRTypes.has_match_state(state, NRTypes.MatchState.STARTING) \
			and not NRTypes.has_match_state(state, NRTypes.MatchState.RUNNING):
		return false
	match _flow_start_verdict(flow):
		&"included":
			if _authority_trusted():
				_adopt_start_choice(flow)
				return false
			if _flow != flow or not flow.is_current():
				return true
		&"excluded":
			_flow_fail(flow, MatchmakingFlow.TEXT_MATCH_ALREADY_STARTED)
			return true
		&"premade_excluded":
			_flow_fail(flow, MatchmakingFlow.TEXT_MATCH_MISMATCH)
			return true
	var clock := Services.clock()
	var deadline := mini(flow.phase_deadline_msec, clock.deadline_after(MatchmakingFlow.COMMIT_SECONDS))
	_pending_start = {
		"flow_id": flow.id,
		"session": _session_generation,
		"states": [int(state)],
		"deadline": deadline,
	}
	_pending_start_alarm = clock.alarm_at(deadline, _on_pending_start_deadline.bind(flow.id))
	return true


## The host's published choice as this guest reads it now: `included` when it is this match's
## current first start, it names this player and its whole frozen premade, and this session's
## own admission has completed; `excluded` or `premade_excluded` when it leaves either out; and
## `pending` while no current choice has replicated or the admission has not completed. Being
## named in the choice is not being admitted: a second connection for a chosen player, one this
## host never admitted, never follows the start. A control for another match or round is judged
## where the lobby is reduced. A private start's control is judged by _private_start_verdict().
func _flow_start_verdict(flow: MatchmakingFlow) -> StringName:
	if flow.is_private_route():
		return _private_start_verdict(flow)
	var party := _party()
	if party == null or flow.arranged_context == null:
		return &"pending"
	var snapshot: Dictionary = party.snapshot(flow.arranged_context)
	var raw_control: Variant = snapshot.get("arranged_control", {})
	var control: Dictionary = raw_control as Dictionary if typeof(raw_control) == TYPE_DICTIONARY else {}
	if not bool(control.get("valid", false)) or String(control.get("match_id", "")) != flow.match_id \
			or int(control.get("round", -1)) != 0 \
			or String(control.get("phase", "")) != PartyService.ARRANGED_PHASE_STARTING \
			or int(control.get("start_generation", 0)) <= 0:
		return &"pending"
	var selected: Variant = control.get("selected_members", [])
	var local_key := MatchmakingFlow.entity_key(party.local_entity_key(flow.arranged_context))
	if not MatchmakingFlow.selection_includes(selected, [local_key]):
		return &"excluded"
	if not MatchmakingFlow.selection_includes(selected, flow.frozen_keys):
		return &"premade_excluded"
	if not _flow_admission_complete(flow):
		return &"pending"
	return &"included"


## A private start's published control as this guest reads it now: `included` when it is this
## group's first start -- round 0, starting, generation 1 -- for the session the owner committed,
## naming this player and its whole group, the commit has been taken, and this member's own
## admission to the group was on the session bound now; `excluded` or `premade_excluded` when
## it leaves either out; `pending` otherwise.
func _private_start_verdict(flow: MatchmakingFlow) -> StringName:
	var party := _party()
	var context: Variant = flow.play_context if flow.play_context != null else flow.staging_context
	if party == null or context == null:
		return &"pending"
	var raw_control: Variant = party.snapshot(context).get("private_control", {})
	var control: Dictionary = raw_control as Dictionary if typeof(raw_control) == TYPE_DICTIONARY else {}
	if not bool(control.get("valid", false)) or int(control.get("round", -1)) != 0 \
			or String(control.get("phase", "")) != PartyService.ARRANGED_PHASE_STARTING \
			or int(control.get("start_generation", 0)) != 1:
		return &"pending"
	if not flow.session_id.is_empty() and String(control.get("session_id", "")) != flow.session_id:
		return &"pending"
	var selected: Variant = control.get("selected_members", [])
	var local_key := MatchmakingFlow.entity_key(party.local_entity_key(context))
	if not MatchmakingFlow.selection_includes(selected, [local_key]):
		return &"excluded"
	if not MatchmakingFlow.selection_includes(selected, flow.frozen_keys):
		return &"premade_excluded"
	if flow.session_origin != PartyService.PLAY_ORIGIN_PRIVATE or not _flow_admission_complete(flow):
		return &"pending"
	return &"included"


## Whether this guest's own admission to the play session completed on the session bound now,
## not merely accepted or named somewhere. A matchmade guest's is its flow-owned request,
## answered and taken on this session. A private start's guest was admitted to the group's own
## lobby and session, which the private match keeps: that admission, taken on this same
## session, is its admission here.
func _flow_admission_complete(flow: MatchmakingFlow) -> bool:
	if _session_generation == 0 or _flow_admitted_session != _session_generation:
		return false
	if flow.session_origin == PartyService.PLAY_ORIGIN_PRIVATE:
		return flow.staging_session == _session_generation
	var request := flow.admission_request
	return request != null and request.succeeded() and request.session_id == _session_generation


## Takes the host's published choice as this guest's view of the players the first match
## starts with.
func _adopt_start_choice(flow: MatchmakingFlow) -> void:
	var party := _party()
	var is_private: bool = flow.session_origin == PartyService.PLAY_ORIGIN_PRIVATE
	var context: Variant = flow.play_context if is_private else flow.arranged_context
	if party == null or context == null:
		return
	var raw_control: Variant = party.snapshot(context).get("private_control" if is_private else "arranged_control", {})
	var control: Dictionary = raw_control as Dictionary if typeof(raw_control) == TYPE_DICTIONARY else {}
	var chosen: Array[Dictionary] = []
	var raw_selected: Variant = control.get("selected_members", [])
	if typeof(raw_selected) == TYPE_ARRAY:
		for raw: Variant in raw_selected as Array:
			var key := MatchmakingFlow.entity_key(raw)
			if not key.is_empty():
				chosen.append(key)
	flow.selected_keys = chosen
	flow.start_generation = int(control.get("start_generation", 0))
	flow.changed.emit()


## This guest's first start is looked at again: on a lobby change, on its admission poll and
## the moment that admission -- or a private start's commit -- is taken. A choice that leaves
## this player or its group out is refused at once, whether or not a start has arrived. Once
## the choice names both and the admission has completed, a held start and the states queued
## behind it are applied in the order they arrived -- but only after the host is proven, again,
## the owner of the lobby this guest joined. A known disagreement ends the attempt first and
## applies nothing.
func _flow_reconcile_pending_start(flow: MatchmakingFlow) -> void:
	if flow != _flow or not flow.is_current() or not flow.awaits_initial_start():
		return
	match _flow_start_verdict(flow):
		&"pending":
			return
		&"excluded":
			_clear_pending_start()
			_flow_fail(flow, MatchmakingFlow.TEXT_MATCH_ALREADY_STARTED)
			return
		&"premade_excluded":
			_clear_pending_start()
			_flow_fail(flow, MatchmakingFlow.TEXT_MATCH_MISMATCH)
			return
	if _pending_start.is_empty() or int(_pending_start.get("flow_id", 0)) != flow.id:
		return
	if int(_pending_start.get("session", 0)) != _session_generation:
		_clear_pending_start()
		return
	if not _authority_trusted():
		return
	if _flow != flow or not flow.is_current() or _pending_start.is_empty():
		return
	_adopt_start_choice(flow)
	var queued: Array = _pending_start.get("states", [])
	_clear_pending_start()
	for raw: Variant in queued:
		if _flow != flow or not flow.is_current():
			return
		_set_match_state(int(raw) as NRTypes.MatchState)


## A private start's guest catching up, from the owner's answer to its own request, on a first
## start whose live message it did not take: the first STARTING, then -- when the owner has
## already reached it -- the owner's loading state, in that order. Each goes through the gate a
## live one takes: this member's own admission on this session and the owner proven again, with
## a start not yet decidable held under the same fixed deadline. An answer naming any other state
## applies nothing, and a first start already applied or held here is not applied a second time.
func _flow_catch_up_initial_start(flow: MatchmakingFlow, reached: int) -> void:
	if flow != _flow or not flow.is_current() or is_host() or flow.initial_start_seen \
			or not _pending_start.is_empty() or not flow.awaits_initial_start():
		return
	if reached != int(NRTypes.MatchState.STARTING) and reached != int(NRTypes.MatchState.PLAYERS_JOINING):
		return
	if not _authority_trusted():
		return
	var states: Array[int] = [int(NRTypes.MatchState.STARTING)]
	if reached == int(NRTypes.MatchState.PLAYERS_JOINING):
		states.append(reached)
	for state: int in states:
		if _flow != flow or not flow.is_current():
			return
		if _hold_initial_start(state as NRTypes.MatchState):
			continue
		_set_match_state(state as NRTypes.MatchState)


func _on_pending_start_deadline(flow_id: int) -> void:
	_pending_start_alarm = null
	var flow := _flow
	if _pending_start.is_empty() or flow == null or flow.id != flow_id \
			or int(_pending_start.get("flow_id", 0)) != flow_id:
		return
	_clear_pending_start()
	if flow.is_current():
		_flow_fail(flow, MatchmakingFlow.TEXT_MATCH_LATE)


func _clear_pending_start() -> void:
	if _pending_start_alarm != null:
		_pending_start_alarm.cancel()
	_pending_start_alarm = null
	_pending_start = {}


# --- Rematch host return -------------------------------------------------------

## A rematch guest back in the lobby before its host: it waits at most 45 seconds for the
## arranged lobby to say the host has returned, and may leave at any moment meanwhile.
func _flow_wait_for_host_return(flow: MatchmakingFlow) -> void:
	if flow != _flow or not flow.is_current():
		return
	if _host_return_alarm != null:
		_host_return_alarm.cancel()
	_host_return_alarm = Services.clock().alarm_after(
		MatchmakingFlow.HOST_RETURN_SECONDS, _on_host_return_deadline.bind(flow.id))


func _flow_host_returned(flow: MatchmakingFlow) -> void:
	if flow != _flow:
		return
	if _host_return_alarm != null:
		_host_return_alarm.cancel()
	_host_return_alarm = null


func _on_host_return_deadline(flow_id: int) -> void:
	_host_return_alarm = null
	var flow := _flow
	if flow == null or flow.id != flow_id or not flow.is_current() or flow.host_returned:
		return
	_flow_fail(flow, MatchmakingFlow.TEXT_HOST_DID_NOT_RETURN)


# --- Lobby loss and service recovery --------------------------------------------

## A scoped lobby was lost unexpectedly -- not left, and not recovered. Every lobby the flow
## still holds is the flow's: the arranged lobby is the match, and the staging lobby is the
## group until the flow's own retirement of it has begun. That holds after arming too --
## arming proves nothing about who the match starts with, and its exception belongs to the old
## Party transport alone (see _on_context_transport_lost). A retirement under way is the old group
## going on purpose, and PartyService reports no loss for a lobby it is leaving.
func _on_context_lost(reason: String, context: Variant) -> void:
	var message: String = reason if not reason.is_empty() else "The matchmaking lobby closed."
	var flow := _flow
	if flow != null and flow.is_current() and context != null:
		if context == flow.play_context or context == flow.arranged_context:
			_flow_fail(flow, message)
			return
		if context == flow.staging_context:
			if not flow.staging_retiring:
				_flow_fail(flow, message)
			return
	if context != null and context == _pending_join_context:
		_on_server_disconnected(message, false)


## A confirmed Multiplayer shutdown: every lobby and ticket of the old runtime is gone. The
## flow is retired synchronously and starts no Party call inside this emission; its native
## release and the screens' notice follow once the recovery has returned. Services then
## lets the matchmaking service discharge the old tickets.
func on_multiplayer_invalidated(_recovery_epoch: int) -> void:
	var flow := _flow
	if flow == null or flow.retired:
		return
	var notify := has_session() or flow.is_live()
	_retire_flow(true)
	_finish_invalidated_flow.call_deferred(flow, notify)


func _finish_invalidated_flow(flow: MatchmakingFlow, notify: bool) -> void:
	if flow == _flow and not flow.native_release_started:
		_detach_peer()
		_reset_after_leave()
		_release_flow(flow)
	if notify:
		last_disconnect_reason = MULTIPLAYER_RECOVERED_REASON
		server_disconnected.emit()


## The arranged guest was admitted on the session bound for it. Consumed on the flow's own
## deadline, and checked against the session that exists now, like any other acceptance --
## the host proven the arranged lobby's owner again, not taken on an earlier proof. Returns
## false only while that proof is still pending, so the flow's poll asks again.
func _consume_flow_admission(flow: MatchmakingFlow, request: JoinRequest) -> bool:
	if flow != _flow or request != _active_join_request:
		return true
	if not _session_account_is_current() or not _peer_is_connected() or _session_generation == 0 \
			or _session_generation != request.session_id or local_player() == null:
		_flow_fail(flow, "The match ended before you could join it.")
		return true
	var verdict := _authority_verdict(true)
	if verdict == &"pending":
		return false
	if verdict != &"proven":
		_authority_failed(verdict)
		return true
	if not request.settle(JoinRequest.Outcome.SUCCEEDED):
		return true
	_active_join_request = null
	_join_aborts.erase(request.id)
	_flow_admitted_session = _session_generation
	flow_changed.emit()
	# A first start that arrived before this admission completed is looked at now.
	_flow_reconcile_pending_start(flow)
	return true


## The staging-to-arranged handoff's local session end.
##
## A bare detach is not enough: the roster, the verified-name cache and the session identity
## would all go on describing a transport that no longer exists, and with no peer bound
## local_peer_id() falls back to 1 -- which on a staging guest resolves local_player() to
## the old host. So the old session is ended completely, synchronously and before anything
## is awaited: the leave/reset core of _leave_match_internal() without its global Party
## leave and without its activity hold. PartyService contexts and the flow's own identity,
## epochs and lease are not touched; the flow leaves the old staging transport through its
## context next, and the new roster is rebuilt only from the new transport.
##
## `_suppress_activity_delete` only avoids a redundant retirement and a presence flicker --
## the flow retired the activity when it froze. It is not the handover hold and never keeps
## a searching activity published.
func _end_local_session_for_handoff(flow: MatchmakingFlow) -> bool:
	if flow != _flow or not flow.is_current() or not flow.armed:
		push_warning("[Net] The matchmaking handoff was not armed; the session was not reset.")
		return false
	if flow.phase != MatchmakingFlow.Phase.ARMING_HANDOFF and flow.phase != MatchmakingFlow.Phase.SWITCHING_TRANSPORT:
		push_warning("[Net] The matchmaking handoff reset was requested outside the handoff.")
		return false
	if _active_join_request != null:
		push_warning("[Net] A join request is still pending; the matchmaking handoff cannot reset the session.")
		return false
	if _platform.wants_activity():
		push_warning("[Net] The matchmaking activity was not retired before the handoff.")
		return false
	# The reset retires any offline grace for the session it ends; a grace belongs to the
	# flow, matched by id, and the flow is continuing, so its token is carried across.
	var connectivity_token := _connectivity_token
	_suppress_activity_delete = true
	_detach_peer()
	_reset_after_leave()
	_suppress_activity_delete = false
	_connectivity_token = connectivity_token
	return true


## Whether a transport loss is the armed member's old staging transport going away, which
## the handoff expects, rather than a session ending.
func _flow_expects_staging_loss() -> bool:
	return _flow != null and _flow.is_current() and _flow.armed \
		and _flow.phase == MatchmakingFlow.Phase.ARMING_HANDOFF \
		and _session_generation != 0 and _session_generation == _flow.staging_session


func _release_join_result_context(result: Dictionary) -> void:
	var context: Variant = result.get("context")
	var party := _party()
	if context == null or party == null:
		return
	await party.leave_lobby(context)
	await party.leave_transport(context)


func _release_pending_join_context() -> void:
	var context: Variant = _pending_join_context
	_pending_join_context = null
	_pending_join_kind = ""
	_pending_join_destination = ""
	_pending_join_arranged = {}
	var party := _party()
	if context == null or party == null:
		return
	await party.leave_lobby(context)
	await party.leave_transport(context)


## A scoped matchmaking transport went down. The armed member's old staging transport is
## expected to; any other context the flow holds ending ends the flow with its reason; a
## staging lobby joined but not yet adopted ends like any other join.
func _on_context_transport_lost(context: Variant, reason: String) -> void:
	var message := reason if not reason.is_empty() else "The match connection was lost."
	if _flow != null and _flow.is_current():
		if context == _flow.staging_context and _flow.armed:
			# The retired staging transport. Expected once the handoff is armed; before the
			# local reset it is also the cue to end the old session early.
			if _flow.phase == MatchmakingFlow.Phase.ARMING_HANDOFF:
				_flow.on_armed_staging_loss()
			return
		if context in _flow.held_contexts():
			_flow_fail(_flow, message)
			return
	if context != null and context == _pending_join_context:
		_on_server_disconnected(message)


## A recoverable failure on a matchmaking context. PartyService has already logged the one
## safe record of it, so nothing more is logged here -- least of all the service's own words,
## which can carry anything -- and what is kept for the player is this title's text. The
## session carries on; the terminal cases arrive as transport losses instead.
func _on_context_failed(_context: Variant, _message: String) -> void:
	if _flow == null and not has_session():
		return
	last_error = _CONTEXT_RECOVERABLE_FAILURE


func _on_context_changed(context: Variant) -> void:
	# A first start this guest is holding is replayed from this lobby's update below. A known
	# loss of the host it answers to is settled first, so nothing is ever replayed under it.
	if not _pending_start.is_empty() and context != null and not _authority_scope.is_empty() \
			and context == _authority_scope.get("context"):
		_recheck_authority()
	if _flow != null:
		_flow.on_lobby_changed(context)
	# A notice about the lobby a guest joined is where its host is proven again, with or
	# without a flow: an identity request still waiting is answered once proven, and a known
	# disagreement ends the attempt or the session now rather than at peer 1's next message.
	if context != null and not _authority_scope.is_empty() and context == _authority_scope.get("context"):
		_recheck_authority()
	var flow := _flow
	if flow == null or context == null or context != flow.play_context:
		return
	# A play-session peer waiting on replication is judged again whenever its lobby moves.
	if not _arranged_candidates.is_empty():
		for peer_id: int in _arranged_candidates.keys():
			_consider_arranged_candidate(peer_id)
	# The host of the first match fails a known loss at once rather than at the next start
	# edge, and otherwise asks the commit decision again: a retirement marker may have landed.
	if _flow == flow and flow.is_current() and is_host() and initial_cohort_pending():
		var loss := _initial_cohort_known_loss(flow)
		if not loss.is_empty():
			_fail_initial_cohort(loss)
			return
		_try_initial_commit(flow)


# --- Voice chat -------------------------------------------------------------

## Microphone state for one player, as a ChatService.ChatIndicator. Offline and
## practice sessions have no Party mesh, so every player reads back NONE and the
## roster draws no microphone icon for those players.
func chat_indicator_for(peer_id: int) -> int:
	var party := _party()
	var chat := _chat()
	if _is_offline or party == null or chat == null or not party.has_network():
		return ChatService.ChatIndicator.NONE
	var entity_key: Dictionary = _platform.entity_key_for(peer_id)
	if entity_key.is_empty():
		return ChatService.ChatIndicator.NONE
	return chat.chat_indicator_for(entity_key)


func is_voice_muted() -> bool:
	var chat := _chat()
	return chat.is_self_muted() if chat != null else true


## Toggles the local microphone. Voice starts muted, so this is how a player opts in.
func toggle_voice_mute() -> void:
	if not _session_account_is_current():
		return
	var party := _party()
	var chat := _chat()
	if party == null or chat == null or not party.has_network() or not _platform.is_chat_allowed():
		return
	await chat.toggle_self_muted()


# --- Chat policy (XR-045 / XR-015) ------------------------------------------
#
# The rules themselves -- the communications privilege, the mute and avoid lists, and
# the per-player privacy permissions -- live in platform_session.gd. What stays here is
# the API the lobby roster and chat UI call, because they ask NetManager about a peer
# and should not have to know which layer answers.

## Whether this session has voice and text chat at all.
func is_chat_allowed() -> bool:
	return _session_account_is_current() and _platform.is_chat_allowed()


## Player-facing reason chat is unavailable, empty when it is available.
func chat_restriction_reason() -> String:
	return _platform.chat_restriction_reason()


## True when the player may mute or unmute this peer themselves. A voice the platform
## already silenced is not theirs to lift, and the local player is not mutable at all.
func can_mute_peer(peer_id: int) -> bool:
	return _session_account_is_current() and _platform.can_mute_peer(peer_id)


func is_peer_muted(peer_id: int) -> bool:
	return _platform.is_peer_muted(peer_id)


## True when the platform silenced this player's voice, so the roster can say why a row
## it will not let the player unmute is muted anyway.
func is_peer_voice_restricted(peer_id: int) -> bool:
	return _platform.is_peer_voice_restricted(peer_id)


## Mutes or unmutes one player for the local player only; the lobby roster drives it.
func toggle_peer_mute(peer_id: int) -> void:
	if not _session_account_is_current():
		return
	await _platform.toggle_peer_mute(peer_id)

## Single funnel for hosting failures so the reason is both broadcast and retrievable;
## screens that await host_match read NetManager.last_error afterwards. Joins do not come
## through here — each one answers the request that asked for it.
func _fail_connection(reason: String) -> void:
	last_error = reason
	push_warning("[Net] %s" % reason)
	connection_failed.emit(reason)


func _register_local_player(peer_id: int) -> void:
	var state := PlayerState.new()
	state.peer_id = peer_id
	state.display_name = PlayerProfile.display_name
	state.entity_id = PlayerProfile.entity_id
	state.xbox_user_id = PlayerProfile.xbox_user_id
	state.ship_color_id = PlayerProfile.ship_color_id
	state.ship_style_id = PlayerProfile.ship_style_id
	state.is_local_player = true
	players[peer_id] = state
	roster_changed.emit()


# --- Practice opponents -----------------------------------------------------

## Brings the roster's bot count to `count`, adding or removing NPC opponents as
## needed. Offline only: bots are a practice-mode feature, and introducing one into a
## networked session would put a ship on the host that no client has ever been told
## about.
##
## Bots are created ready and loaded. Both flags gate the match start -- the lobby
## waits on `everyone_ready()` and MatchDirector waits on every player's `in_game` --
## and a bot has nothing to ready up or load, so leaving them false would simply hang
## the practice match forever.
func sync_practice_bots(count: int) -> void:
	if not _session_account_is_current() or not _is_offline:
		return

	var wanted := clampi(count, 0, MAX_PRACTICE_BOTS)
	var existing := bot_players()

	for index in range(wanted, existing.size()):
		players.erase(existing[index].peer_id)

	for index in range(existing.size(), wanted):
		var state := PlayerState.new()
		state.peer_id = BOT_PEER_ID_BASE - index
		state.display_name = _bot_display_name(index)
		state.is_bot = true
		state.is_ready = true
		state.in_game = true
		state.ship_style_id = index % 4
		state.ship_color_id = _free_ship_color()
		players[state.peer_id] = state

	roster_changed.emit()


func bot_players() -> Array[PlayerState]:
	var bots: Array[PlayerState] = []
	for state: PlayerState in players.values():
		if state.is_bot:
			bots.append(state)
	bots.sort_custom(func(a: PlayerState, b: PlayerState) -> bool: return a.peer_id > b.peer_id)
	return bots


func bot_count() -> int:
	return bot_players().size()


## Picks a hull colour nobody in the roster is using yet, so the player can always
## tell which ship is theirs. Falls back to a wrap-around once the palette runs out.
func _free_ship_color() -> int:
	var taken: Array[int] = []
	for state: PlayerState in players.values():
		taken.append(state.ship_color_id)
	var palette_size := maxi(Assets.player_color_count(), 1)
	for color_id in palette_size:
		if not taken.has(color_id):
			return color_id
	return players.size() % palette_size


const _BOT_NAMES: PackedStringArray = [
	"Vega", "Rigel", "Altair", "Mira", "Antares", "Deneb", "Polaris",
]


func _bot_display_name(index: int) -> String:
	if index < _BOT_NAMES.size():
		return _BOT_NAMES[index]
	return "Bot %d" % (index + 1)


# --- Session admission ------------------------------------------------------

## True while the session would admit a newcomer: it is in a lobby rather than in or
## part-way into a match. Host-authoritative — a client's copy tracks the host's, and it
## uses it only to decide whether to advertise its own session as joinable.
func is_accepting_joins() -> bool:
	return _accepting_joins


## Seals the session against newcomers before a match starts. Awaitable; returns true
## only when the PlayFab lobby confirmed the lock.
##
## Two things close a match and both are load-bearing. The host's own gate closes, which
## turns away a peer whose connection is already in flight, and the lobby's membership is
## locked, which stops anyone finding the session in the first place. The gate alone is
## what produced the bug this exists for: a latecomer still found the lobby, still joined
## it, still built a Party network, and only then met a refusal — arriving as a
## disconnection on a client that had already recorded the join as a success.
##
## Fails closed. The local gate shuts before the service call and stays shut whatever the
## service says, so an unconfirmed lock never starts a match the lobby is still
## advertising; the caller offers a retry instead.
func close_joins() -> bool:
	return await _set_joins_open(false)


## Reopens the session to newcomers once the host is back in the waiting lobby.
## Awaitable; returns true only when the PlayFab lobby confirmed the unlock.
##
## The local gate opens only after the service does, which is the opposite order to
## close_joins and for the same reason: every window where the two disagree should err
## towards refusing a newcomer rather than advertising a join that will be refused.
func open_joins() -> bool:
	return await _set_joins_open(true)


func _set_joins_open(open: bool) -> bool:
	last_admission_error = ""
	var generation := _session_account_generation
	var session := _session_generation
	if not _session_account_is_current():
		last_admission_error = ACCOUNT_NOT_READY
		return false
	if not is_host():
		last_admission_error = "Only the host can open or close the match."
		return false
	# Practice runs on one machine with no lobby to lock, so the local gate is all of it.
	if _is_offline:
		_set_accepting_joins(open)
		return true
	if not has_session():
		last_admission_error = "The match has ended."
		return false
	# A matchmaking group's play session is its own scoped lobby -- an arranged one, or the
	# group's own after a private start: the flow publishes the round's phase and confirms the
	# lock or unlock through it, never the legacy lobby.
	if _flow != null and _flow.hosts_play_session():
		return await _set_rematch_open(open, generation, session)
	if not open:
		_set_accepting_joins(false)
	var party := _party()
	if party == null:
		last_admission_error = "PlayFab Party is unavailable in this build."
		return false
	var result: Dictionary = await party.set_lobby_locked(not open)
	if not _account_is_current(generation) or _session_generation != session:
		return false
	if not bool(result.get("ok", false)):
		last_admission_error = String(result.get("error", "The match could not be updated."))
		push_warning("[Net] Lobby admission update failed: %s" % last_admission_error)
		return false
	# The session can end while the service is thinking. A late unlock must not reopen a
	# lobby this instance has already left.
	if not has_session():
		last_admission_error = "The match has ended."
		return false
	if open:
		_set_accepting_joins(true)
	return true


## _set_joins_open() for a matchmaking group's play session. The local gate closes before the
## service call and opens only after it, exactly as for a hosted match; in between the flow
## publishes the round's phase and confirms the lock or unlock.
func _set_rematch_open(open: bool, generation: int, session: int) -> bool:
	var flow := _flow
	if not open:
		_set_accepting_joins(false)
	var changed: bool = await flow.set_rematch_open(open)
	if not _account_is_current(generation) or _session_generation != session or flow != _flow:
		return false
	if not changed:
		last_admission_error = flow.last_admission_error
		if last_admission_error.is_empty():
			last_admission_error = "The match could not be updated."
		# PartyService logged the native side once; this is only the title's own step.
		push_warning("[Matchmaking] rematch_admission_failed flow=%d open=%s" % [flow.id, open])
		return false
	if not has_session():
		last_admission_error = "The match has ended."
		return false
	if open:
		_set_accepting_joins(true)
	return true


## The single writer for the admission gate. Everything that changes it comes through
## here so the two things that depend on it cannot be forgotten: the host's clients need
## the new state to retire or republish their own platform activities, and this instance
## needs it to do the same with its own.
func _set_accepting_joins(open: bool) -> void:
	if _accepting_joins == open:
		return
	_accepting_joins = open
	if is_host() and _peer != null:
		_share(&"_receive_join_admission", [open])
	join_admission_changed.emit(open)


## The host's admission state, mirrored onto a client. A guest publishes its own Xbox
## activity, so it has to know when the match stopped taking players -- otherwise its
## friends keep seeing a joinable session and keep being refused by it.
@rpc("authority", "call_remote", "reliable")
func _receive_join_admission(open: bool) -> void:
	if not _session_account_is_current() or is_host() or not _authority_trusted():
		return
	_set_accepting_joins(open)


## The host has admitted this player: they are on its authoritative roster, they hold the
## roster and mode it replayed first, and the session is theirs to enter.
##
## This -- not the transport attaching -- is what a successful join means. Party connects a
## client to the mesh before the host has looked at it, and the host may still turn it away
## for a match already in progress or an incompatible build. A join resolved on the
## transport alone therefore reported success for sessions the player was never admitted
## to, and the refusal arrived while the loading screen was still up, too late to change an
## answer that had already been recorded. That is what left a refused player looking at a
## lobby with no roster and no join code.
##
## Recorded, not answered. The join's own poll consumes this a moment later, after it has
## checked that the player has not cancelled in the meantime and that the session is still
## there — so nothing here emits success, publishes an activity or opens a lobby. Only a
## host proven, now, the owner of the lobby this guest joined can admit it. The host sends
## this only after this guest's identity, which already needed that proof, so one arriving
## before it is dropped rather than kept for later.
@rpc("authority", "call_remote", "reliable")
func _accept_join() -> void:
	if not _session_account_is_current() or is_host():
		return
	var request := _active_join_request
	if request == null or not request.is_pending() or request.admitted:
		return
	if _join_aborts.has(request.id):
		return
	if _peer == null or _session_generation == 0 or local_player() == null:
		return
	var verdict := _authority_verdict()
	if verdict == &"pending":
		return
	if verdict != &"proven":
		_authority_failed(verdict)
		return
	# The host only accepts while it is open, so this doubles as the client's first read
	# of the admission state -- before any _receive_join_admission has had cause to fire.
	_set_accepting_joins(true)
	request.session_id = _session_generation
	request.admitted = true


# --- Matchmaking flow RPCs ------------------------------------------------------
#
# Declared here, like every other RPC, because Godot routes an RPC by the declaring node's
# path. Their meaning lives in MatchmakingFlow. Adding them changed the RPC set, which is
# why NRProtocol.RPC_SET_VERSION moved with them.

## The staging owner's phase for the current attempt -- FREEZING, SEARCHING, CANCELLING,
## RESTORING_STAGING, GATHERING, or a private start's PRIVATE_PREPARING and its commit,
## COMMITTING_START, with the private session's id -- with the durable outcome and, while
## searching, the milliseconds of search budget left. A reply to this guest's own state request
## carries that request's id and is reduced as the answer, not as a broadcast; to one of a
## private match's four while its first start is under way, the answer also carries that start's
## round, start generation and the match state the owner has reached. Staging-scoped: an
## arranged session's host never speaks for a premade's own attempts. A message not taken while
## the owner cannot be proven is noted, for a private start's member to ask about again. See
## MatchmakingFlow.on_owner_phase() and on_state_reply().
@rpc("authority", "call_remote", "reliable")
func _receive_flow_phase(epoch: int, phase: int, detail: Dictionary) -> void:
	if not _session_account_is_current() or is_host():
		return
	if not _authority_trusted():
		_note_owner_message_missed(int(detail.get("request_id", 0)))
		return
	if _flow != null and _session_generation != _flow.staging_session:
		return
	var copy := detail.duplicate(true)
	if int(copy.get("request_id", 0)) > 0:
		if _flow != null:
			_flow.on_state_reply(epoch, phase, copy)
		return
	_last_owner_phase = {"epoch": epoch, "phase": phase, "detail": copy}
	if _flow != null:
		_flow.on_owner_phase(epoch, phase, copy)


## A member's report to the staging owner for the current attempt. FREEZING acknowledges
## the freeze over the authenticated transport; CANCELLING asks the owner to stop the
## search because this member could not join the owner's ticket.
## GATHERING acknowledges the group as it is now, which is what lets that member's next Ready
## count; PRIVATE_PREPARING and COMMITTING_START acknowledge a private start and its control.
@rpc("any_peer", "call_remote", "reliable")
func _submit_flow_ack(epoch: int, phase: int) -> void:
	if not is_host() or _flow == null:
		return
	_flow.on_member_report(multiplayer.get_remote_sender_id(), epoch, phase)


## A guest's binding Leave Group, sent before it disconnects so the owner cancels the
## group's ticket instead of mistaking the departure for a transport fault.
@rpc("any_peer", "call_remote", "reliable")
func _submit_flow_leave(epoch: int) -> void:
	if not is_host() or _flow == null:
		return
	_flow.on_member_leave(multiplayer.get_remote_sender_id(), epoch)


## A staging guest asking the owner for its current state, correlated by `request_id` and
## answered through _receive_flow_phase to that guest alone. `known_epoch` is the attempt
## the guest last adopted; the answer is the owner's current state either way, except that a
## private match's first start is answered only for the attempt it was committed in.
@rpc("any_peer", "call_remote", "reliable")
func _request_flow_state(request_id: int, known_epoch: int) -> void:
	if not is_host() or _flow == null:
		return
	_flow_answer_state_request(multiplayer.get_remote_sender_id(), request_id, known_epoch)


# --- Peer plumbing ----------------------------------------------------------

func _on_peer_connected(peer_id: int) -> void:
	if not is_host():
		# The host reaching this guest's transport can be what settles its proof.
		if peer_id == HOST_PEER_ID:
			_settle_pending_authority()
		return
	# A connection is judged afresh: an earlier refusal under this id no longer applies.
	_refused_peers.erase(peer_id)
	# A play session proves each peer on the transport's own facts before any RPC reaches it:
	# a first-match arrival as a compatible member of this match, a rematch replacement by its
	# protocol, a unique identity and -- for a private match -- this session's id. A private
	# match admits nobody outside its rematch rounds: any other peer meets its closed gate.
	if _flow != null and (_flow.hosts_arranged_session()
			or (_flow.hosts_play_session() and _flow.phase == MatchmakingFlow.Phase.REMATCH_GATHERING)):
		if not _arranged_candidates.has(peer_id):
			_arranged_candidates[peer_id] = Services.clock().now_msec()
		_consider_arranged_candidate(peer_id)
		return
	_greet_peer(peer_id)


## The players shared session updates go to: every admitted remote player -- on this host's
## roster and connected -- and nobody else. A peer still waiting for admission, or one this host
## refused, hears none of them. Empty unless hosting an online session.
func _admitted_recipients() -> Array[int]:
	var recipients: Array[int] = []
	if _peer == null or _is_offline or not is_host():
		return recipients
	var connected := multiplayer.get_peers()
	var local := local_peer_id()
	for peer_id: int in players.keys():
		if peer_id != local and connected.has(peer_id):
			recipients.append(peer_id)
	return recipients


## Sends one shared session update -- `method` with `args` -- to each admitted player, with the
## method's own delivery settings, exactly as a broadcast would reach them. The welcome, the
## replay and acceptance, and refusals go to one peer by id instead.
func _share(method: StringName, args: Array = []) -> void:
	for peer_id: int in _admitted_recipients():
		callv(&"rpc_id", [peer_id, method] + args)


## The ordinary welcome: the gate's answer, then the mode and the identity request. The roster
## reaches the newcomer only once it is admitted, whole and current (see _admit_identity()), so a
## player who leaves before then is never shown to it. Everything here assumes the peer speaks
## this build's protocol.
func _greet_peer(peer_id: int) -> void:
	# A match in progress does not take newcomers. Admitting one used to put a player
	# on the roster who had no ship, no spawn and no scene loaded, which then leaked
	# into everything that walks `players`: the roster count, the loading barrier in
	# MatchDirector._handle_players_loading, everyone_ready(), the score-limit check
	# and last-player-standing. Turning them away here is what keeps all of those
	# honest, so the check belongs at the door rather than in each of them.
	if not _accepting_joins:
		_refuse_peer(peer_id, _closed_session_refusal_text())
		return
	# The newcomer joined after the mode was chosen, so the mode is sent to it now.
	_receive_game_mode.rpc_id(peer_id, int(game_mode_type))
	_request_player_identity.rpc_id(peer_id)


## What a peer is told when it reaches this host while the session takes nobody: a hosted
## match's own advice about its room code, or -- for a matchmaking group or match, which has
## no room code -- that it is already searching or already under way. A private match, and a
## group already preparing one, is under way the same way a matchmade match is.
func _closed_session_refusal_text() -> String:
	if _flow == null:
		return JOIN_REJECTED_IN_PROGRESS
	if _flow.in_arranged_session() or _flow.in_play_session() \
			or _flow.phase == MatchmakingFlow.Phase.PRIVATE_PREPARING:
		return MatchmakingFlow.TEXT_MATCH_ALREADY_STARTED
	return MatchmakingFlow.TEXT_GROUP_SEARCHING


## Turns one peer away for good on this session. A peer known to speak this build's messages
## is first told why, in one message to it alone; it then stops being one of this host's peers at
## the end of the frame, so it hears nothing more of the session. Its own client still ends its
## attempt on that refusal or its own deadline. An admitted player is never removed here --
## including the one a second connection for the same player duplicates -- and neither is
## this host itself.
func _refuse_peer(peer_id: int, reason: String = "") -> void:
	if not is_host() or _peer == null or peer_id == HOST_PEER_ID or peer_id == local_peer_id():
		return
	_arranged_candidates.erase(peer_id)
	if not reason.is_empty():
		_reject_join.rpc_id(peer_id, reason)
	if players.has(peer_id):
		return
	_refused_peers[peer_id] = _session_generation
	_drop_refused_peer.call_deferred(peer_id, _session_generation, _peer)


## The deferred end of a refusal: only on the same session and transport, only for a peer still
## refused -- not reconnected and judged afresh meanwhile -- still connected, and never on the
## roster.
func _drop_refused_peer(peer_id: int, session: int, transport: Variant) -> void:
	if int(_refused_peers.get(peer_id, 0)) != session:
		return
	_refused_peers.erase(peer_id)
	if session != _session_generation or transport != _peer or _peer == null or not is_host():
		return
	if peer_id == HOST_PEER_ID or peer_id == local_peer_id() or players.has(peer_id):
		return
	if not multiplayer.get_peers().has(peer_id):
		return
	_peer.disconnect_peer(peer_id)


## Judges one play-session peer on the transport's own facts. Proven: it is greeted the
## ordinary way. Not provable yet: it waits, sent nothing, for the next change of its lobby,
## within the budget this session gives an arrival (see _candidate_wait_expired()). Anything
## else is turned away for good (see _refuse_arranged_candidate()): an arbitrary peer cannot
## end the match for everyone, and it stops hearing anything of the session.
func _consider_arranged_candidate(peer_id: int) -> void:
	if not _arranged_candidates.has(peer_id):
		return
	var flow := _flow
	if flow == null or not flow.hosts_play_session() or _peer == null:
		return
	var verdict := _arranged_candidate_verdict(flow, peer_id)
	if verdict == &"pending" or verdict == &"proven":
		# A wait that ran out admits nothing, even if the membership has just been proven.
		if _candidate_wait_expired(flow, peer_id):
			verdict = &"expired"
	if verdict == &"pending":
		return
	_arranged_candidates.erase(peer_id)
	if verdict == &"proven":
		_greet_peer(peer_id)
		return
	_refuse_arranged_candidate(peer_id, verdict)


## Whether an arranged-session peer has waited too long for its membership to be proven: past
## the first match's own arrival budget while that match is being put together, or past the
## ordinary join budget, from its first connection, once it has run.
func _candidate_wait_expired(flow: MatchmakingFlow, peer_id: int) -> bool:
	var clock := Services.clock()
	if not _cohort_policy.is_empty():
		return clock.has_expired(flow.phase_deadline_msec)
	var since := int(_arranged_candidates.get(peer_id, clock.now_msec()))
	return clock.now_msec() - since >= int(NRConst.MATCH_ESTABLISHMENT_SECONDS * 1000.0)


## One arranged-session peer this host will not admit. A compatible peer that arrived after
## the first match's players were chosen, or once the match is full, is told so; nothing is
## sent to any other, which may not even route this build's messages. Each is then removed
## from this host's peers (see _refuse_peer()).
func _refuse_arranged_candidate(peer_id: int, verdict: StringName) -> void:
	match verdict:
		&"late":
			_refuse_peer(peer_id, MatchmakingFlow.TEXT_MATCH_ALREADY_STARTED)
		&"full":
			_refuse_peer(peer_id, MatchmakingFlow.TEXT_MATCH_FULL)
		_:
			push_warning("[Net] Not admitting arranged peer %d: %s." % [peer_id, verdict])
			_refuse_peer(peer_id)


## The transport's facts about one play-session peer, compared with what this session admits.
## `proven`, `pending`, `late`, `full`, `outsider`, `duplicate` or `incompatible`. While the
## first matchmade match's players are still arriving, any proven, compatible member of this
## match is admitted, up to capacity; once they are chosen, only a chosen player is. A private
## match's peer must belong to this private session (see _private_session_member()).
func _arranged_candidate_verdict(flow: MatchmakingFlow, peer_id: int) -> StringName:
	var party := _party()
	if party == null or flow.play_context == null:
		return &"pending"
	var proof: Dictionary = party.admission_proof(flow.play_context, peer_id)
	var key := MatchmakingFlow.entity_key(proof.get("entity_key", {}))
	if bool(proof.get("pending", false)) or (key.is_empty() and not bool(proof.get("valid", false))):
		return &"pending"
	if not bool(proof.get("valid", false)):
		return &"outsider"
	var raw_properties: Variant = proof.get("member_properties", {})
	var properties: Dictionary = raw_properties as Dictionary if typeof(raw_properties) == TYPE_DICTIONARY else {}
	var protocol := String(properties.get(MatchmakingService.PROTOCOL_MEMBER_KEY, ""))
	if protocol.is_empty():
		return &"pending"
	if not NRProtocol.is_compatible(protocol):
		return &"incompatible"
	var mark := MatchmakingFlow.fingerprint(key)
	for existing_id: int in players:
		if existing_id != peer_id and _player_fingerprint(existing_id) == mark:
			return &"duplicate"
	if flow.session_origin == PartyService.PLAY_ORIGIN_PRIVATE \
			and not _private_session_member(flow, party, key, properties):
		return &"incompatible"
	if _cohort_policy.is_empty():
		return &"proven"
	if String(properties.get(PartyService.MATCH_ID_MEMBER_KEY, "")) != String(_cohort_policy.get("match_id", "")):
		return &"incompatible"
	var admitted: Dictionary = _cohort_policy.get("admitted", {})
	if admitted.has(mark) and int(admitted[mark]) != peer_id:
		return &"duplicate"
	var selected: Dictionary = _cohort_policy.get("selected", {})
	if not selected.is_empty():
		return &"proven" if selected.has(mark) else &"late"
	if not admitted.has(mark) and admitted.size() >= flow.capacity:
		return &"full"
	return &"proven"


## Whether a private match's peer belongs to this private session. A replacement carries the
## session's id in its own lobby entry, exactly as its invitation wrote it. One of the four the
## session started with joined the group before there was a session to name, so its entry may
## carry no id at all -- accepted only for one of those four, for this session, while this host
## still owns the lobby and the lobby is this session's open round. An id naming any other
## session is never accepted, whoever carries it.
func _private_session_member(flow: MatchmakingFlow, party: PartyService, key: Dictionary,
		properties: Dictionary) -> bool:
	if properties.has(PartyService.PRIVATE_SESSION_ID_KEY):
		return String(properties.get(PartyService.PRIVATE_SESSION_ID_KEY, "")) == flow.session_id
	if not flow.is_private_member(key) or flow.phase != MatchmakingFlow.Phase.REMATCH_GATHERING \
			or flow.play_context == null:
		return false
	var snapshot: Dictionary = party.snapshot(flow.play_context)
	if not bool(snapshot.get("is_local_owner", false)) or bool(snapshot.get("membership_locked", true)) \
			or String(snapshot.get("private_session_id", "")) != flow.session_id:
		return false
	var owner := MatchmakingFlow.entity_key(snapshot.get("owner_key", {}))
	if owner.is_empty() or MatchmakingFlow.fingerprint(owner) != MatchmakingFlow.fingerprint(flow.play_owner_key()):
		return false
	var raw_control: Variant = snapshot.get("private_control", {})
	var control: Dictionary = raw_control as Dictionary if typeof(raw_control) == TYPE_DICTIONARY else {}
	return bool(control.get("valid", false)) and String(control.get("session_id", "")) == flow.session_id \
		and String(control.get("phase", "")) == PartyService.ARRANGED_PHASE_REMATCH \
		and int(control.get("round", -1)) == flow.match_round


## The authenticated identity behind a roster entry, as a fingerprint: the local player's
## own key, or what Party's transport says a remote peer is.
func _player_fingerprint(peer_id: int) -> String:
	var party := _party()
	if party == null:
		return ""
	var key: Dictionary = {}
	if peer_id == local_peer_id():
		var context: Variant = null
		if _flow != null:
			context = _flow.play_context if _flow.play_context != null else _flow.arranged_context
		key = MatchmakingFlow.entity_key(party.local_entity_key(context))
	else:
		key = MatchmakingFlow.entity_key(party.entity_key_for(peer_id))
	if key.is_empty():
		return ""
	return MatchmakingFlow.fingerprint(key)


## Tells a peer the host will not have it and why. The client treats this exactly like
## any other end of session, so the reason lands in the same dialog as a host departure
## rather than needing a rejection path of its own.
@rpc("authority", "call_remote", "reliable")
func _reject_join(reason: String) -> void:
	# Only the joined lobby's proven owner may turn this guest away.
	if not _authority_trusted():
		return
	# A refusal is never the expected loss of an armed handoff's old transport.
	_on_server_disconnected(reason, false)


## A peer left while the first arranged match is still being put together. A chosen player
## ends the attempt, and true is returned; so does one of this host's own frozen premade. Any
## other admitted arrival is simply no longer present: its admission is forgotten, the ordinary
## departure runs, and the start decision is asked again. False lets the ordinary departure run.
func _initial_start_departure(peer_id: int) -> bool:
	var flow := _flow
	var mark := _admitted_mark_for(peer_id)
	var selected: Dictionary = _cohort_policy.get("selected", {})
	if not selected.is_empty():
		if selected.has(mark):
			_fail_initial_cohort(MatchmakingFlow.TEXT_MATCH_MEMBER_LOST)
			return true
		return false
	if mark.is_empty() or flow == null:
		return false
	for key: Dictionary in flow.frozen_keys:
		if MatchmakingFlow.fingerprint(key) == mark:
			_fail_initial_cohort(MatchmakingFlow.TEXT_MATCH_MEMBER_LOST)
			return true
	var admitted: Dictionary = _cohort_policy.get("admitted", {})
	admitted.erase(mark)
	_cohort_policy["admitted"] = admitted
	_try_initial_commit.call_deferred(flow)
	return false


func _on_peer_disconnected(peer_id: int) -> void:
	if _peer == null:
		return
	_arranged_candidates.erase(peer_id)
	_refused_peers.erase(peer_id)
	# A staging guest's replay dedup leaves with it: Party can seat a later member under the
	# same peer id, and that member's first request must not read as a duplicate.
	_flow_state_answers.erase(peer_id)
	# A chosen player leaving before the first match runs is the end of that match: it never
	# starts with fewer than it chose -- Godot has no authority migration. Before the choice
	# an arrival leaving only shrinks who is present, unless it was one of this host's own
	# premade; a peer outside the choice was never admitted.
	if is_host() and _initial_cohort_armed and _initial_start_departure(peer_id):
		return
	# Only an admitted player's departure is anyone else's business: a peer that was never
	# admitted -- still waiting, or turned away -- leaves no trace on the roster.
	var was_admitted := players.has(peer_id)
	if was_admitted:
		players.erase(peer_id)
		player_left.emit(peer_id)
		roster_changed.emit()
	if is_host():
		if was_admitted:
			_share(&"_receive_player_left", [peer_id])
		return

	# The host going away is the end of the session, and this is the only notice of it
	# a client gets. A Party network is a mesh rather than a star, so the host leaving
	# does not disconnect anybody else's transport: the peer stays CONNECTED, Godot never
	# raises `server_disconnected`, and without this the clients sit in a match with no
	# authority -- no snapshots, no scoring, no way for it to ever end.
	#
	# Routed through the transport rather than an "I am leaving" RPC from the host on
	# purpose. This one signal covers every way a host can vanish: leaving from the menu,
	# being suspended by the platform, crashing, or dropping off the network. An RPC only
	# covers the first.
	if peer_id == HOST_PEER_ID:
		_on_server_disconnected("The host left the match.")


func _on_connected_to_server() -> void:
	if not _session_account_is_current():
		return
	# Registers the identity _submit_player_identity is about to send. The join is not
	# resolved here: the transport attaching says nothing about whether the host will
	# have this player. See _accept_join.
	_register_local_player(multiplayer.get_unique_id())
	_settle_pending_authority()


func _on_connection_failed() -> void:
	if _abort_host("Connection to host failed.") or _abort_join_for_lost_session("Connection to host failed."):
		return
	# A matchmaking transport that failed to connect ends the flow through its own
	# teardown; nulling the peer alone would leave both lobbies joined behind a lobby
	# screen that never hears about it.
	if _flow != null and _flow.is_current() and _peer != null:
		_flow_fail(_flow, "Connection to the match host failed.")
		return
	_detach_peer()
	_fail_connection("Connection to host failed.")


## The session is over and this instance is not the one that ended it.
##
## `_peer` is the re-entry guard: both the host's departure and a genuine transport drop
## can reach here for the same session, and the screens must not be told twice.
##
## `transport_loss` is false for a refusal or a sustained-offline end, which are never the
## old staging transport going away as an armed matchmaking handoff expects.
func _on_server_disconnected(reason: String = "", transport_loss: bool = true) -> void:
	var message := reason if not reason.is_empty() else "You were disconnected from the match."
	# An armed matchmaking member losing its captured staging transport: the handoff ends
	# the old session locally and carries on, rather than leaving both lobbies and sending
	# the player to the menu. Only that transport, only once armed -- and checked first,
	# because no host or join attempt can be establishing while a handoff is armed.
	if transport_loss and _flow_expects_staging_loss():
		_flow.on_armed_staging_loss()
		return
	if _abort_host(message):
		return
	if _abort_join_for_lost_session(message):
		return
	if _peer == null:
		return
	# A full leave, not just a local reset. The Party network and the PlayFab lobby are
	# still joined at this point, and the activity is still advertised -- the host going
	# away does not retract any of that -- so without this the player returns to the menu
	# still in a dead session and still shown to their friends as playing in it.
	leave_match()
	# Set after the leave, because the leave is what clears the previous session's reason.
	last_disconnect_reason = message
	server_disconnected.emit()


## The Party network is gone and is not coming back. Ends the session the same way a host
## departure does, so there is one route out of a dead match rather than one per cause.
##
## Reaches every participant, host included: `_on_server_disconnected` is not host-gated,
## and a host whose network died has no session left either. Its `_peer` guard swallows
## the duplicate when Party reports both a state change and a destroy for the same loss,
## and makes this a no-op when the player already left under their own steam.
##
## `context` is the scoped matchmaking lobby whose transport went down -- so an expected
## staging loss can be told apart from an arranged one -- or null for the one hosted or
## code-joined session.
func _on_party_network_lost(reason: String, context: Variant = null) -> void:
	if context != null:
		_on_context_transport_lost(context, reason)
		return
	_on_server_disconnected(reason)


## A Party operation failed without the network going down. Recorded rather than acted on:
## the addon raises this for state-change batches that fail recoverably, so ending the
## match here would drop players over errors the session survives. The terminal cases
## arrive as `network_lost` instead.
func _on_party_failed(message: String, context: Variant = null) -> void:
	if context != null:
		_on_context_failed(context, message)
		return
	if not has_session() and _flow == null:
		return
	# PartyService has already logged the one safe record of it. The service's own words can
	# carry anything, so nothing more is logged here, and what is kept for the player is this
	# title's text, as for a matchmaking context.
	last_error = _CONTEXT_RECOVERABLE_FAILURE


## How long the console must stay offline before an online match is ended (XR-074).
##
## The hint is device-wide and can flap -- a brief interface change, a transient radio
## drop -- over intervals a Party network rides out without losing a packet the player
## would notice. Ending a match the instant it goes low would be a regression against the
## reactive handling rather than an improvement on it, so the loss has to persist.
const _CONNECTIVITY_GRACE_SECONDS := 8.0

## Bumped on every connectivity change so a grace period that has been overtaken -- by
## the connection coming back, or by the match ending some other way -- cannot fire.
var _connectivity_token := 0


## The console's connectivity changed. Only an *online* match is at stake: a practice
## match is entirely local, and ending one because the console dropped off the network
## would be nonsense.
##
## This is the proactive route out of a dead match. `PartyService.network_lost` remains
## the backstop, and either may win: whichever arrives first ends the session and the
## other is swallowed by the `_peer` guard in `_on_server_disconnected()`.
func _on_connectivity_changed(online: bool) -> void:
	_connectivity_token += 1
	if not online:
		var reason := _offline_reason()
		if reason.is_empty():
			reason = "This console has no internet connection."
		if _abort_host(reason) or _abort_join_for_lost_session(reason):
			return
		# A group still opening fails at once, like a host attempt: nothing is established
		# yet for the offline grace to protect.
		if _flow != null and _flow.is_current() and _flow.phase == MatchmakingFlow.Phase.CREATING_STAGING:
			_flow_start_failed(_flow, reason)
			return
	if online or _is_offline:
		return
	# A matchmaking flow is online work even with no peer bound -- between its staging and
	# arranged sessions -- so its grace starts here too.
	var flow_id := _flow.id if _flow != null and _flow.is_live() else 0
	if _peer == null and flow_id == 0:
		return
	_end_match_if_still_offline(_connectivity_token, flow_id)


func _end_match_if_still_offline(token: int, flow_id: int = 0) -> void:
	var deadline := _now_msec() + int(_CONNECTIVITY_GRACE_SECONDS * 1000.0)
	while _now_msec() < deadline:
		if token != _connectivity_token or _is_offline or (_peer == null and not _flow_live_by_id(flow_id)):
			return
		await _sleep(_JOIN_RESULT_POLL_INTERVAL)
	# Re-checked rather than trusted: the token catches a reported change, and the live
	# query catches the case where the grace period simply outlasted the problem. The flow
	# is matched by id, not by peer or session: a grace that began before the transport
	# swap still belongs to the same attempt after it.
	if token != _connectivity_token or _is_offline:
		return
	var flow_live := _flow_live_by_id(flow_id)
	if _peer == null and not flow_live:
		return
	var connectivity: ConnectivityService = Services.connectivity() if Services != null else null
	if connectivity == null or connectivity.is_online():
		return
	if flow_live:
		# Sustained offline ends the attempt in every phase, armed or not: an expected
		# staging-transport loss is not an outage, and an outage is not expected.
		_flow_fail(_flow, connectivity.offline_reason())
		return
	_on_server_disconnected(connectivity.offline_reason(), false)


## Whether the flow a grace period was started for is still the live one, matched by id so
## the grace survives the flow's own transport swap.
func _flow_live_by_id(flow_id: int) -> bool:
	return flow_id != 0 and _flow != null and _flow.id == flow_id and _flow.is_live()


# --- Roster RPCs ------------------------------------------------------------

## Identity goes only to a host proven, now, the current owner of the lobby this guest
## joined -- whichever entry reached it, with or without a matchmaking flow. What cannot be
## proven yet is kept as this session's pending request -- nothing is sent -- and asked
## again on every lobby update, transport event and join poll; a known disagreement ends
## the attempt. The join's own deadline bounds the wait.
@rpc("authority", "call_remote", "reliable")
func _request_player_identity() -> void:
	if not _session_account_is_current() or is_host():
		return
	_pending_identity_session = _session_generation
	_settle_pending_authority()


func _send_local_identity() -> void:
	var state := local_player()
	if state == null:
		# The host's request can arrive before Godot raises connected_to_server on this
		# client, and the join now waits on the reply this sends -- so a silent return
		# here would cost the player the whole join deadline. The identity comes from the
		# local profile either way, so it is built now rather than waited for.
		_register_local_player(multiplayer.get_unique_id())
		state = local_player()
	if state == null:
		return
	_submit_player_identity.rpc_id(HOST_PEER_ID, state.to_dict(), NRProtocol.version_string())


# --- Joined-lobby authority -------------------------------------------------
#
# A guest trusts peer 1 only as the current native owner of the lobby it joined: a hosted
# lobby, a matchmaking group's staging lobby, an arranged match's lobby for its first game
# or for a rematch replacement. One scope and one proof serve all of them, before a flow
# exists as much as after. Hosts and offline play are their own authority.

## Records, the moment a guest binds its transport and before peer 1 can send anything,
## whose lobby the new session answers to: the joined lobby's context (null for a hosted
## lobby), the owner the join pinned, and for a play session's lobby the match -- or private
## session -- and round it was entered for, with the account and recovery identity they were
## captured under. A private start's members are scoped again the same way when it commits.
func _capture_authority_scope(kind: StringName, context: Variant, owner_key: Dictionary, match_id: String,
		match_round: int, private_session_id: String = "") -> void:
	var party := _party()
	var proof: Dictionary = party.joined_owner_proof(context, HOST_PEER_ID) if party != null else {}
	_authority_scope = {
		"kind": kind,
		"session": _session_generation,
		"account": _session_account_generation,
		"context": context,
		"recovery_epoch": int(proof.get("recovery_epoch", -1)),
		"owner_key": MatchmakingFlow.entity_key(owner_key),
		"match_id": match_id,
		"session_id": private_session_id,
		"round": match_round,
	}
	_authority_failed_session = 0
	_pending_identity_session = 0


## Whether peer 1 is, right now, the current native owner of the lobby this guest joined.
## `proven` only for a valid proof on the current context and recovery
## epoch, peer 1's authenticated key the pinned owner, the lobby's owner still that key,
## with a compatible protocol and, for an arranged lobby, this match's id. `pending` while
## PartyService has not replicated the facts; otherwise a known disagreement --
## `owner_changed` for another owner or none, `incompatible` for another protocol or match,
## `moved` for a rematch that has already begun, `lost` for a lobby, owner, transport,
## account or session that is gone. `for_admission` adds the rematch round the replacement
## was invited into, which must still be gathering. The first proven owner is kept for the
## session: from then on, a lobby with no owner has lost it rather than not replicated it yet.
## A private match's lobby is judged by its own session id instead of a match id.
func _authority_verdict(for_admission: bool = false) -> StringName:
	if _is_offline or is_host():
		return &"proven"
	var scope := _authority_scope
	if scope.is_empty() or _session_generation == 0 or int(scope.get("session", 0)) != _session_generation \
			or int(scope.get("account", -1)) != _session_account_generation or not _session_account_is_current():
		return &"lost"
	var party := _party()
	if party == null:
		return &"lost"
	var proof: Dictionary = party.joined_owner_proof(scope.get("context"), HOST_PEER_ID)
	if int(proof.get("recovery_epoch", -1)) != int(scope.get("recovery_epoch", -1)):
		return &"lost"
	var proven_owner := MatchmakingFlow.entity_key(scope.get("proven_owner", {}))
	var reason_code := String(proof.get("reason_code", ""))
	var pending := bool(proof.get("pending", false))
	# A lobby that shows no owner after this session has had one has lost its host. That is
	# known, whatever the lobby's own connection says now, so it is settled first.
	if pending and reason_code == "owner_pending" and not proven_owner.is_empty():
		return &"owner_changed"
	# This process's own lobby connection is gone. Nothing it shows can change any further,
	# so nothing waits on it -- and a disagreement it shows was reported before this.
	if not bool(proof.get("local_lobby_connected", true)) and (pending or reason_code == "local_lobby_disconnected"):
		return _local_lobby_loss_verdict(scope, proof, proven_owner)
	if pending:
		return &"pending"
	if not bool(proof.get("valid", false)):
		return _authority_refusal(reason_code)
	var owner := MatchmakingFlow.entity_key(proof.get("owner_key", {}))
	var host := MatchmakingFlow.entity_key(proof.get("peer_key", {}))
	if owner.is_empty() or host.is_empty() or MatchmakingFlow.fingerprint(host) != MatchmakingFlow.fingerprint(owner):
		return &"owner_changed"
	var pinned := MatchmakingFlow.entity_key(scope.get("owner_key", {}))
	if not pinned.is_empty() and MatchmakingFlow.fingerprint(owner) != MatchmakingFlow.fingerprint(pinned):
		return &"owner_changed"
	var kind := StringName(scope.get("kind", &""))
	if kind == &"private" or kind == &"private_rematch":
		# A private match is named by its own session id, never by an empty match id.
		if String(proof.get("play_origin", "")) != String(PartyService.PLAY_ORIGIN_PRIVATE) \
				or String(proof.get("private_session_id", "")) != String(scope.get("session_id", "")):
			return &"incompatible"
	else:
		var match_id := String(scope.get("match_id", ""))
		if not match_id.is_empty() and String(proof.get("match_id", "")) != match_id:
			return &"incompatible"
	if for_admission and (kind == &"rematch" or kind == &"private_rematch"):
		if String(proof.get("phase", "")) != PartyService.ARRANGED_PHASE_REMATCH \
				or int(proof.get("round", -1)) != int(scope.get("round", -1)):
			return &"moved"
	if proven_owner.is_empty():
		scope["proven_owner"] = owner
	return &"proven"


## The joined lobby's own connection is gone while Party runs on. That lobby can no longer
## prove anything, so it authorizes nothing new: a join not yet admitted is refused at once,
## and every matchmaking lobby -- staging or arranged -- is lost, as it always was. The one
## exception is an ordinary hosted, code or invite session already admitted: its match goes
## on over Party under the host this session proved -- whether or not a host was known when
## the lobby was joined -- for as long as peer 1 is still that host. That is continuity for a
## session already established, never a fresh proof of the lobby, and nothing is re-pinned: a
## lobby that reconnects is proven in full again.
func _local_lobby_loss_verdict(scope: Dictionary, proof: Dictionary, proven_owner: Dictionary) -> StringName:
	if StringName(scope.get("kind", &"")) != &"hosted" or not bool(scope.get("admitted", false)) or proven_owner.is_empty():
		return &"lost"
	var host := MatchmakingFlow.entity_key(proof.get("peer_key", {}))
	if host.is_empty():
		return &"lost"
	if MatchmakingFlow.fingerprint(host) != MatchmakingFlow.fingerprint(proven_owner):
		return &"owner_changed"
	var captured := MatchmakingFlow.entity_key(proof.get("captured_owner_key", {}))
	if not captured.is_empty() and MatchmakingFlow.fingerprint(captured) != MatchmakingFlow.fingerprint(proven_owner):
		return &"owner_changed"
	return &"proven"


## PartyService's stable reason for a disproven owner, in this title's verdicts. Anything
## else it reports -- a lobby, transport, owner or membership that is gone -- is a loss.
static func _authority_refusal(reason_code: String) -> StringName:
	match reason_code:
		"owner_changed", "owner_peer_mismatch":
			return &"owner_changed"
		"owner_protocol_mismatch", "owner_match_mismatch", "arranged_control_invalid", "private_control_invalid":
			return &"incompatible"
	return &"lost"


## The words for a disproven host: a join still waiting to be admitted says it could not be
## joined; an admitted session says its match was closed or left.
static func _authority_refusal_text(verdict: StringName, kind: StringName, admitted: bool) -> String:
	if verdict == &"incompatible":
		return MatchmakingFlow.TEXT_MATCH_INCOMPATIBLE
	match kind:
		&"arranged", &"rematch", &"private", &"private_rematch":
			if admitted:
				return _MATCH_HOST_LEFT if verdict == &"lost" else _MATCH_HOST_CHANGED
			if kind == &"arranged" or kind == &"private":
				return MatchmakingFlow.TEXT_MATCH_MEMBER_LOST if verdict == &"lost" else MatchmakingFlow.TEXT_MATCH_HOST_CHANGED
			if verdict == &"moved":
				return _REMATCH_MOVED
			return _REMATCH_HOST_LEFT if verdict == &"lost" else _REMATCH_HOST_CHANGED
		&"staging":
			return MatchmakingFlow.TEXT_GROUP_HOST_LEFT if verdict == &"lost" else MatchmakingFlow.TEXT_OWNER_CHANGED
	if verdict == &"lost":
		return _HOST_LEFT_BEFORE_JOIN
	return _HOST_CHANGED if admitted else _HOST_CHANGED_BEFORE_JOIN


## Whether a message from peer 1 may act on this session now. Always for a host and
## offline play. For a guest, only while peer 1 proves itself, at this message, the current
## owner of the lobby this guest joined -- before admission and after it alike, so an owner
## that changes or goes is caught at the very next message whether or not any notice of it
## arrived, on a hosted lobby as much as a scoped one. A pending proof drops the message --
## before admission the host sends the roster and mode once this guest has answered -- and
## a known disagreement ends the attempt or the session, once, with its reason.
func _authority_trusted() -> bool:
	if _is_offline or is_host():
		return true
	var verdict := _authority_verdict()
	if verdict == &"proven":
		return true
	if verdict != &"pending":
		_authority_failed(verdict)
	return false


## A message from peer 1 was not taken because peer 1 could not be proven the owner at that
## moment -- `answer_id` names this guest's request it answered, if it was an answer. A private
## start's member keeps, within its own bound, the need to ask for what it missed once the owner
## is proven again; nothing it did not take is ever applied.
func _note_owner_message_missed(answer_id: int = 0) -> void:
	if _flow != null and not is_host():
		_flow.note_owner_message_missed(answer_id)


## Answers the identity request the host sent before it could be proven, once the proof
## settles, on the session it arrived on and no other.
func _settle_pending_authority() -> void:
	if _pending_identity_session == 0:
		return
	if _pending_identity_session != _session_generation or not _session_account_is_current() or is_host():
		_pending_identity_session = 0
		return
	var verdict := _authority_verdict()
	if verdict == &"pending":
		return
	_pending_identity_session = 0
	if verdict != &"proven":
		_authority_failed(verdict)
		return
	_send_local_identity()


## Proves the joined lobby's owner again on a notice about that lobby or its transport: an
## identity request still waiting is answered once proven, and a known disagreement ends the
## attempt or the session now rather than at peer 1's next message.
func _recheck_authority() -> void:
	if _pending_identity_session != 0:
		_settle_pending_authority()
		return
	if _is_offline or is_host() or _session_generation == 0 or _authority_scope.is_empty():
		return
	var verdict := _authority_verdict()
	if verdict != &"proven" and verdict != &"pending":
		_authority_failed(verdict)


## Ends the attempt or session whose host could not be proven, once per session, with a
## reason this title owns. A join still waiting is refused through its own cleanup, so
## nothing is published or adopted; a flow's attempt or session ends the flow; an admitted
## hosted session ends like any other lost host.
func _authority_failed(verdict: StringName) -> void:
	if _session_generation == 0 or _authority_failed_session == _session_generation:
		return
	_authority_failed_session = _session_generation
	_pending_identity_session = 0
	var flow := _flow
	var request := _active_join_request
	var admitted := request == null or not request.is_pending()
	var text := _authority_refusal_text(verdict, StringName(_authority_scope.get("kind", &"")), admitted)
	if not admitted and not request.is_flow_owned():
		_request_join_abort(request, JoinRequest.Outcome.FAILED, text)
		return
	if flow != null and flow.is_current():
		_flow_fail(flow, text)
		return
	_on_server_disconnected(text, false)


@rpc("any_peer", "call_remote", "reliable")
func _submit_player_identity(data: Dictionary, protocol: String) -> void:
	if not is_host():
		return
	_admit_identity(multiplayer.get_remote_sender_id(), data, protocol)


## The host's decision on one peer's identity submission: the body of
## _submit_player_identity(), with the sender the transport authenticated.
func _admit_identity(sender: int, data: Dictionary, protocol: String) -> void:
	if not is_host():
		return
	# A play session proves the peer again now, before anything is sent back: the session, the
	# transport's own facts and the first match's choice can all have moved since it was
	# greeted, and a peer on a different protocol must not be answered with RPCs at all. A
	# proof that has gone back to pending is greeted again once it settles. A private match
	# judges peers only in its rematch rounds; otherwise its closed gate answers below.
	if _flow != null and (_flow.hosts_arranged_session()
			or (_flow.hosts_play_session() and _flow.phase == MatchmakingFlow.Phase.REMATCH_GATHERING)):
		var verdict := _arranged_candidate_verdict(_flow, sender)
		if verdict == &"proven" and not NRProtocol.is_compatible(protocol):
			verdict = &"incompatible"
		if (verdict == &"pending" or verdict == &"proven") and _arranged_candidates.has(sender) \
				and _candidate_wait_expired(_flow, sender):
			verdict = &"expired"
		if verdict == &"pending":
			if not _arranged_candidates.has(sender):
				_arranged_candidates[sender] = Services.clock().now_msec()
			return
		if verdict != &"proven":
			_refuse_arranged_candidate(sender, verdict)
			return
	# Second line of defence on the protocol version. PartyService already refused this
	# peer on the lobby if it read a mismatch there, so anything arriving here either
	# skipped that path or is running a build old enough not to have it. Best-effort by
	# nature -- a mismatch is exactly what stops RPCs routing correctly, so this check
	# depends on the thing it is checking for. It costs nothing and catches the cases
	# where the method indices still happen to line up.
	if not NRProtocol.is_compatible(protocol):
		push_warning("[Net] Rejecting peer %d: peer protocol '%s', local protocol '%s'." % [
			sender, protocol, NRProtocol.version_string()])
		_refuse_peer(sender, NRProtocol.mismatch_message(NRProtocol.version_string(), protocol))
		return
	# The lobby can commit to starting between the identity request going out and this
	# reply coming back. Re-checking here closes that window: without it the newcomer
	# lands on the roster a moment after the door shut, which is the exact state the
	# gate exists to prevent.
	if not _accepting_joins:
		_refuse_peer(sender, _closed_session_refusal_text())
		return
	var state := PlayerState.from_dict(data)
	state.peer_id = sender
	state.ship_color_id = _first_free_color(sender, state.ship_color_id)
	# Trust Party's authenticated entity key over the one the client claimed in its
	# identity RPC: taking the key from the transport rather than the message means a
	# client cannot present someone else's entity id.
	var party := _party()
	if party != null:
		var key: Dictionary = party.entity_key_for(sender)
		var authenticated := String(key.get("id", ""))
		if not authenticated.is_empty():
			state.entity_id = authenticated
	# A retried identity submission re-states an admission rather than making a second
	# one. The roster entry is refreshed either way, but player_joined announces an
	# arrival and must only fire for a genuine one.
	var already_admitted := players.has(sender)
	players[sender] = state

	# The roster reaches the newcomer here, whole and current, and never with the greeting: a
	# player who left meanwhile is one it was never shown. The mode goes again too -- the
	# newcomer acts on nothing this host sends until it has proven this host the owner of the
	# lobby it joined, so the greeting's copy may have been dropped -- ahead of the acceptance
	# that resolves its join.
	for existing_id: int in players:
		if existing_id != sender:
			_receive_roster_entry.rpc_id(sender, (players[existing_id] as PlayerState).to_dict())
	_receive_game_mode.rpc_id(sender, int(game_mode_type))
	# Fan the newcomer out to every peer, including back to themselves so their
	# possibly-reassigned colour sticks.
	_share(&"_receive_roster_entry", [state.to_dict()])
	# Sent last, once the newcomer holds the roster and mode this replayed to it: the
	# acknowledgement is what resolves their join, and it should not resolve into a lobby
	# there is nothing yet to draw. See _accept_join.
	_accept_join.rpc_id(sender)
	if not already_admitted:
		player_joined.emit(state)
	roster_changed.emit()
	if not _cohort_policy.is_empty():
		_record_cohort_admission(sender)


@rpc("authority", "call_remote", "reliable")
func _receive_roster_entry(data: Dictionary) -> void:
	if not _authority_trusted():
		return
	if not _session_account_is_current():
		return
	var state := PlayerState.from_dict(data)
	state.is_local_player = state.peer_id == local_peer_id()
	players[state.peer_id] = state
	roster_changed.emit()


@rpc("authority", "call_remote", "reliable")
func _receive_player_left(peer_id: int) -> void:
	if not _authority_trusted():
		return
	if players.has(peer_id):
		players.erase(peer_id)
		player_left.emit(peer_id)
		roster_changed.emit()


## Colours are unique per lobby; fall back to the first unused slot on collision.
func _first_free_color(peer_id: int, preferred: int) -> int:
	var taken: Array[int] = []
	for id in players:
		if id != peer_id:
			taken.append((players[id] as PlayerState).ship_color_id)
	if not taken.has(preferred):
		return preferred
	for i in Assets.player_color_count():
		if not taken.has(i):
			return i
	return preferred


# --- Lobby actions ----------------------------------------------------------

func set_local_ready(is_ready: bool) -> void:
	if not _session_account_is_current():
		return
	# A frozen matchmaking group holds readiness: the ticket was built from it.
	if not can_customize():
		return
	var state := local_player()
	if state == null:
		return
	state.is_ready = is_ready
	if is_host():
		_apply_ready_state(local_peer_id(), is_ready)
	else:
		_submit_ready_state.rpc_id(HOST_PEER_ID, is_ready)
	roster_changed.emit()


@rpc("any_peer", "call_remote", "reliable")
func _submit_ready_state(is_ready: bool) -> void:
	if not is_host():
		return
	_apply_ready_state(multiplayer.get_remote_sender_id(), is_ready)


func _apply_ready_state(peer_id: int, is_ready: bool) -> void:
	var state: PlayerState = players.get(peer_id, null)
	if state == null:
		return
	# While a matchmaking group is frozen an unready still lands -- it is a player
	# withdrawing consent, and it stops the search -- but a ready changes nothing: the
	# sender's own view is set back to the readiness this host holds for it.
	if is_ready and _flow != null and _flow.is_frozen():
		if not _is_offline and peer_id != local_peer_id():
			_receive_ready_state.rpc_id(peer_id, peer_id, state.is_ready)
		return
	# A gathering member's Ready counts only for the group as it is now: one given before the
	# member acknowledged the latest change of who is in it is refused, and its own view is
	# corrected. An unready always lands.
	if is_ready and _flow != null and not _flow.gathering_consented(peer_id):
		if not _is_offline:
			_share(&"_receive_ready_state", [peer_id, false])
		return
	state.is_ready = is_ready
	if not _is_offline:
		_share(&"_receive_ready_state", [peer_id, is_ready])
	roster_changed.emit()


@rpc("authority", "call_remote", "reliable")
func _receive_ready_state(peer_id: int, is_ready: bool) -> void:
	if not _authority_trusted():
		return
	var state: PlayerState = players.get(peer_id, null)
	if state == null:
		return
	state.is_ready = is_ready
	roster_changed.emit()


func set_local_appearance(color_id: int, style_id: int) -> void:
	if not _session_account_is_current():
		return
	if not can_customize():
		return
	var state := local_player()
	if state == null:
		return
	state.ship_color_id = color_id
	state.ship_style_id = style_id
	PlayerProfile.ship_color_id = color_id
	PlayerProfile.ship_style_id = style_id
	PlayerProfile.save_settings()
	if is_host():
		_apply_appearance(local_peer_id(), color_id, style_id)
	else:
		_submit_appearance.rpc_id(HOST_PEER_ID, color_id, style_id)
	roster_changed.emit()


@rpc("any_peer", "call_remote", "reliable")
func _submit_appearance(color_id: int, style_id: int) -> void:
	if not is_host():
		return
	_apply_appearance(multiplayer.get_remote_sender_id(), color_id, style_id)


func _apply_appearance(peer_id: int, color_id: int, style_id: int) -> void:
	var state: PlayerState = players.get(peer_id, null)
	if state == null:
		return
	# The authoritative guard, not just the lobby's disabled selectors: a frozen group's
	# appearance is held on the host whatever a client sends.
	if not can_customize():
		return
	state.ship_color_id = color_id
	state.ship_style_id = style_id
	if not _is_offline:
		_share(&"_receive_appearance", [peer_id, color_id, style_id])
	roster_changed.emit()


@rpc("authority", "call_remote", "reliable")
func _receive_appearance(peer_id: int, color_id: int, style_id: int) -> void:
	if not _authority_trusted():
		return
	var state: PlayerState = players.get(peer_id, null)
	if state == null:
		return
	state.ship_color_id = color_id
	state.ship_style_id = style_id
	roster_changed.emit()


## Called by the gameplay screen once its scene is built and the world is ready.
## MatchDirector waits for every player's in_game flag before leaving PLAYERS_JOINING.
func report_local_player_loaded() -> void:
	if not _session_account_is_current():
		return
	if is_host():
		_apply_player_loaded(local_peer_id())
	else:
		var state := local_player()
		if state != null:
			state.in_game = true
		_submit_player_loaded.rpc_id(HOST_PEER_ID)


@rpc("any_peer", "call_remote", "reliable")
func _submit_player_loaded() -> void:
	if not is_host():
		return
	_apply_player_loaded(multiplayer.get_remote_sender_id())


func _apply_player_loaded(peer_id: int) -> void:
	var state: PlayerState = players.get(peer_id, null)
	if state == null or state.in_game:
		return
	state.in_game = true
	if not _is_offline:
		_share(&"_receive_player_loaded", [peer_id])
	player_loaded.emit(peer_id)
	roster_changed.emit()


@rpc("authority", "call_remote", "reliable")
func _receive_player_loaded(peer_id: int) -> void:
	if not _authority_trusted():
		return
	var state: PlayerState = players.get(peer_id, null)
	if state == null:
		return
	state.in_game = true
	player_loaded.emit(peer_id)
	roster_changed.emit()


## Returns every player to their pre-match state. The host calls this when a match
## tears down, so the lobby a player lands back in looks exactly like the one they
## started from.
##
## Three fields survive a match and all three have to go: in_game gates the next
## match's loading barrier, is_ready gates whether the lobby starts a match at all,
## and score is compared against the game mode's target to decide when a match is
## won. Leaving any of them set makes the second match of a session behave nothing
## like the first — a lobby everyone is already "ready" in starts a match nobody
## asked for, which the stale scores then end on its first tick.
##
## Bots keep in_game and is_ready. They have no scene to load and no button to press,
## so they are created already loaded and already ready; clearing their flags would
## strand MatchDirector at the loading barrier and leave a practice lobby that can
## never reach everyone_ready() again. Their scores do reset, because bots are ranked
## on the scoreboard alongside human players.
func reset_for_next_match() -> void:
	if not _session_account_is_current():
		return
	_apply_match_reset()
	if not _is_offline:
		_share(&"_receive_match_reset", [])


## Clients cannot derive this locally: a client never sees the match end as a state
## change it owns, and is_ready and score are both drawn in its roster. The host
## replicates the reset so every peer's lobby agrees.
@rpc("authority", "call_remote", "reliable")
func _receive_match_reset() -> void:
	if not _authority_trusted():
		return
	_apply_match_reset()


func _apply_match_reset() -> void:
	for state: PlayerState in players.values():
		state.in_game = state.is_bot
		state.is_ready = state.is_bot
		state.score = 0
	# Deliberately does not reopen the session. Resetting scores and readiness is a
	# roster edit every peer applies the moment the match ends; admission is a service
	# state only the host owns, and only once it is actually back in the waiting lobby --
	# players read the results screen at their own pace, and a lobby that reopened here
	# would take newcomers while everyone else was still looking at final scores. The
	# lobby unlocks it on arrival instead (LobbyScreen._reopen_joins).
	#
	# Clearing readiness is also what holds the next match: a player still on the results
	# screen cannot ready up, and everyone_ready() is a precondition of starting, so the
	# round cannot begin again until every current player is back in the lobby.
	roster_changed.emit()


func begin_match_chat() -> int:
	_clear_match_chat()
	_chat_view_active = true
	return _chat_context


func is_match_chat_current(context: int) -> bool:
	return _chat_view_active and context == _chat_context


func end_match_chat(context: int) -> void:
	if is_match_chat_current(context):
		_clear_match_chat()


func _clear_match_chat() -> void:
	_chat_context += 1
	_chat_view_active = false
	chat_cleared.emit()


func chat_unavailable_reason() -> String:
	if not _chat_view_active or _is_offline or _peer == null:
		return "Text chat is available only in an online match."
	if not _session_account_is_current():
		return "Sign in to use text chat."
	if not _platform.is_chat_allowed():
		return _platform.chat_restriction_reason()
	var chat := _chat()
	if chat == null or not chat.has_control():
		return "Text chat is unavailable. Leave and rejoin the session to try again."
	return ""


func can_read_chat_from(peer_id: int) -> bool:
	if not chat_unavailable_reason().is_empty() or not players.has(peer_id):
		return false
	if peer_id == local_peer_id():
		return true
	var party := _party()
	return party != null and _chat().can_exchange_text(party.entity_key_for(peer_id))


func _on_party_text_received(entity_key: Dictionary, text: String) -> void:
	if not chat_unavailable_reason().is_empty():
		return
	var party := _party()
	if party == null:
		return
	for state: PlayerState in players.values():
		if party.entity_key_for(state.peer_id) != entity_key:
			continue
		if state.peer_id != local_peer_id() and can_read_chat_from(state.peer_id):
			chat_message_received.emit(state.peer_id, text)
		return
	push_warning("[Net] Ignored text from a sender outside the current roster.")


## Party carries text separately from RPCs. A voice mute does not deny typed text:
## the text privacy verdict independently controls both recipients and ReceiveText.
## Returns false when the message could not be sent, which keeps the entry dialog open.
##
## The message is verified before it is sent, never after (XR-018). A message the
## platform will not accept never becomes a packet, and last_chat_error carries the
## sentence the dialog shows the player.
func send_chat_message(message: String) -> bool:
	last_chat_error = ""
	if not ChatService.valid_text(message):
		return _chat_failed("Messages must contain between 1 and %d characters." % ChatService.MAX_MESSAGE_LENGTH)
	var trimmed := message.strip_edges()
	var unavailable := chat_unavailable_reason()
	if not unavailable.is_empty():
		return _chat_failed(unavailable)
	var chat := _chat()
	var context := _chat_context
	var verdict: Dictionary = await Services.verify_chat_text(trimmed)
	if not is_match_chat_current(context):
		return _chat_failed("The match ended before the message could be sent.")
	if not bool(verdict.get("acceptable", false)):
		var reason := String(verdict.get("message", ""))
		return _chat_failed(reason if not reason.is_empty() else "The message could not be verified. Please try again.")
	unavailable = chat_unavailable_reason()
	if not unavailable.is_empty():
		return _chat_failed(unavailable)
	if not await chat.send_chat_text(trimmed):
		return _chat_failed(chat.last_text_error)
	if not is_match_chat_current(context):
		return _chat_failed("The match ended while the message was being sent.")
	# Party sends to remote controls only. This confirms submission, not delivery.
	chat_message_received.emit(local_peer_id(), trimmed)
	return true


func _chat_failed(reason: String) -> bool:
	last_chat_error = reason
	push_warning("[Net] %s" % reason)
	return false


## Files a reputation report against one player (XR-018). The peer is resolved to an XUID
## here rather than in the UI, so the reporting surface never has to handle identity.
## Returns false when the report did not reach the service, including when the player has
## no XUID to report — a desktop custom-id session, or a peer that reported none.
func report_player(peer_id: int, feedback_type: String) -> bool:
	if not _session_account_is_current():
		return false
	var generation := _session_account_generation
	var state: PlayerState = players.get(peer_id)
	if state == null:
		return false
	var xuid := String(state.xbox_user_id).strip_edges()
	if xuid.is_empty():
		return false
	var reported: bool = await Services.report_player(xuid, feedback_type)
	return _account_is_current(generation) and reported


## Opens the system profile card for one player, which is where Xbox offers blocking and
## its own reporting flow. False when there is no XUID or no platform to show it on.
func show_player_profile(peer_id: int) -> bool:
	if not _session_account_is_current():
		return false
	var generation := _session_account_generation
	var state: PlayerState = players.get(peer_id)
	if state == null:
		return false
	var xuid := String(state.xbox_user_id).strip_edges()
	if xuid.is_empty():
		return false
	var moderation := Services.moderation()
	if moderation == null:
		return false
	var shown: bool = await moderation.show_profile_card(Services.xbox_user(), xuid)
	return _account_is_current(generation) and shown


## True when this player can be reported: there is an Xbox identity to report from and an
## XUID to report against. The player actions overlay hides the action otherwise, rather
## than offering one that silently goes nowhere.
func can_report_player(peer_id: int) -> bool:
	if not _session_account_is_current() or _is_offline or peer_id == local_peer_id():
		return false
	if not Services.moderation_available():
		return false
	var state: PlayerState = players.get(peer_id)
	return state != null and not String(state.xbox_user_id).strip_edges().is_empty()


func everyone_ready() -> bool:
	if players.is_empty():
		return false
	for id in players:
		if not (players[id] as PlayerState).is_ready:
			return false
	return true


# --- Match state ------------------------------------------------------------

func set_match_state(state: NRTypes.MatchState) -> void:
	if not is_host():
		return
	# Committing to a start closes the local gate. Only STARTING does this: MatchDirector
	# also reports PLAYERS_JOINING once the gameplay scene is up, and that is the loading
	# barrier rather than a return to the lobby.
	#
	# A backstop, not the closure that matters. LobbyScreen._try_auto_start has already
	# awaited close_joins() and confirmed the lobby is locked before reaching here, and
	# this only makes sure a state set from anywhere else cannot leave the gate open.
	# Joins reopen from LobbyScreen._reopen_joins when the host returns.
	if state == NRTypes.MatchState.STARTING:
		_set_accepting_joins(false)
	_set_match_state(state)
	if not _is_offline:
		_share(&"_receive_match_state", [int(state)])


func _set_match_state(state: NRTypes.MatchState) -> void:
	if match_state == state:
		return
	match_state = state
	# The flow first: an arranged session's phase follows the match it is playing, and the
	# screens reading it below should see the phase that goes with this state.
	if _flow != null:
		_flow.on_match_state(state)
	match_state_changed.emit(state)


@rpc("authority", "call_remote", "reliable")
func _receive_match_state(state: int) -> void:
	if not _authority_trusted():
		_note_owner_message_missed()
		return
	if _hold_initial_start(state as NRTypes.MatchState):
		return
	_set_match_state(state as NRTypes.MatchState)


func broadcast_countdown(seconds_remaining: int) -> void:
	countdown_changed.emit(seconds_remaining)
	if is_host() and not _is_offline:
		_share(&"_receive_countdown", [seconds_remaining])


@rpc("authority", "call_remote", "reliable")
func _receive_countdown(seconds_remaining: int) -> void:
	if not _authority_trusted():
		return
	countdown_changed.emit(seconds_remaining)


## The match clock is host-owned: clients advance their own copy between updates and
## snap to this value, so the HUD timer can't sit frozen (or drift) on a client.
func broadcast_match_clock(elapsed: float) -> void:
	if is_host() and not _is_offline:
		_share(&"_receive_match_clock", [elapsed])


@rpc("authority", "call_remote", "unreliable_ordered")
func _receive_match_clock(elapsed: float) -> void:
	if not _authority_trusted():
		return
	match_clock_received.emit(elapsed)


# --- Game mode --------------------------------------------------------------

## The mode decides the time limit and target score, so clients have to be told
## about it or their HUD timer and win conditions disagree with the host's.
##
## Deathmatch is currently the only mode, so nothing calls this: the host fixes the
## mode in host_match() and a joining peer is told once, in the connect handshake
## (see _receive_game_mode.rpc_id in the peer-connected path). The setter is kept
## because it is the piece a second mode needs — it is the pattern for replicating
## any host-authoritative match setting that can change while players sit in the
## lobby, and _apply_game_mode's game_mode_changed signal is what a UI would listen
## to in order to redraw the rules panel on every peer at once.
func set_game_mode(mode: NRTypes.GameModeType) -> void:
	if not _session_account_is_current():
		return
	_apply_game_mode(mode)
	if is_host() and not _is_offline:
		_share(&"_receive_game_mode", [int(mode)])


@rpc("authority", "call_remote", "reliable")
func _receive_game_mode(mode: int) -> void:
	if not _authority_trusted():
		return
	_apply_game_mode(mode as NRTypes.GameModeType)


func _apply_game_mode(mode: NRTypes.GameModeType) -> void:
	if game_mode_type == mode:
		return
	game_mode_type = mode
	game_mode_changed.emit(mode)
	roster_changed.emit()


# --- Simulation traffic -----------------------------------------------------
#
# Host -> clients broadcasts. Each is a no-op on clients; the world node calls them
# only when it holds authority.

func broadcast_match_created(payload: Dictionary) -> void:
	match_created.emit(payload)
	if is_host() and not _is_offline:
		_share(&"_receive_match_created", [payload])


@rpc("authority", "call_remote", "reliable")
func _receive_match_created(payload: Dictionary) -> void:
	if not _authority_trusted():
		return
	match_created.emit(payload)


func broadcast_match_starting(payload: Dictionary) -> void:
	match_starting.emit(payload)
	if is_host() and not _is_offline:
		_share(&"_receive_match_starting", [payload])


@rpc("authority", "call_remote", "reliable")
func _receive_match_starting(payload: Dictionary) -> void:
	if not _authority_trusted():
		return
	match_starting.emit(payload)


func broadcast_world_snapshot(payload: Dictionary) -> void:
	if is_host() and not _is_offline:
		_share(&"_receive_world_snapshot", [payload])


@rpc("authority", "call_remote", "unreliable_ordered")
func _receive_world_snapshot(payload: Dictionary) -> void:
	if not _authority_trusted():
		return
	world_snapshot_received.emit(payload)


## Clients push input to the host. On the host this short-circuits into the same
## signal the RPC raises, so the simulation has one code path for all players.
##
## The packet names its own sender, which is not as redundant as it looks. Everything
## downstream keys a player's ship off whichever peer the transport says a packet came
## from, and input is the only message that arrives INPUT_SEND_HZ times a second per
## player on an unreliable channel — so it is both the most exposed to the transport
## attributing a packet to the wrong peer and the one where doing so is most visible,
## because the result is a player's ship flying on somebody else's stick.
func send_ship_input(movement: Vector2, fire: Vector2, deploy_mine: bool, sequence: int) -> void:
	if not _session_account_is_current():
		return
	if is_host():
		ship_input_received.emit(local_peer_id(), movement, fire, deploy_mine, sequence)
	else:
		_receive_ship_input.rpc_id(
			HOST_PEER_ID, local_peer_id(), movement, fire, deploy_mine, sequence
		)


## The claimed id is checked against the transport's sender id rather than replacing it,
## and a packet the two disagree about is dropped.
##
## Dropping is deliberately the answer to both ways they can disagree. A client that
## lies about who it is only ever silences itself, so the claim stays a checksum and
## never becomes a credential — this keeps the same "trust the transport, not the
## client" rule the identity handshake follows. And when it is the transport that got
## it wrong, the cost is one frame of input on a channel that resends the player's
## entire input state INPUT_SEND_HZ times a second, where honouring the mismatch would
## instead hand their ship to another player until the next packet landed.
@rpc("any_peer", "call_remote", "unreliable_ordered")
func _receive_ship_input(
	claimed_peer_id: int,
	movement: Vector2,
	fire: Vector2,
	deploy_mine: bool,
	sequence: int
) -> void:
	if not is_host():
		return
	var sender := multiplayer.get_remote_sender_id()
	if claimed_peer_id != sender:
		_note_misattributed_input(sender, claimed_peer_id)
		return
	ship_input_received.emit(sender, movement, fire, deploy_mine, sequence)


## Records a dropped input packet and reports the running total at most once every
## _MISATTRIBUTED_INPUT_REPORT_INTERVAL seconds.
##
## Counted rather than logged one at a time: these arrive at INPUT_SEND_HZ per player,
## so a transport that has started mis-attributing in earnest would otherwise bury
## every other message in the log. A non-zero total here is the evidence that separates
## a transport-level attribution fault from a gameplay bug.
func _note_misattributed_input(sender_peer_id: int, claimed_peer_id: int) -> void:
	_misattributed_input_count += 1
	var now := Time.get_ticks_msec() / 1000.0
	if now - _misattributed_input_reported_at < _MISATTRIBUTED_INPUT_REPORT_INTERVAL:
		return
	_misattributed_input_reported_at = now
	push_warning(
		(
			"[NetManager] Dropped %d ship input packet(s) that did not agree on their "
			+ "sender. Most recent: transport reported peer %d, packet claimed peer %d."
		)
		% [_misattributed_input_count, sender_peer_id, claimed_peer_id]
	)


func broadcast_projectile_spawned(payload: Dictionary) -> void:
	if is_host() and not _is_offline:
		_share(&"_receive_projectile_spawned", [payload])


@rpc("authority", "call_remote", "reliable")
func _receive_projectile_spawned(payload: Dictionary) -> void:
	if not _authority_trusted():
		return
	projectile_spawned_received.emit(payload)


func broadcast_projectile_detonated(payload: Dictionary) -> void:
	if is_host() and not _is_offline:
		_share(&"_receive_projectile_detonated", [payload])


@rpc("authority", "call_remote", "reliable")
func _receive_projectile_detonated(payload: Dictionary) -> void:
	if not _authority_trusted():
		return
	projectile_detonated_received.emit(payload)


func broadcast_power_up_spawned(payload: Dictionary) -> void:
	if is_host() and not _is_offline:
		_share(&"_receive_power_up_spawned", [payload])


@rpc("authority", "call_remote", "reliable")
func _receive_power_up_spawned(payload: Dictionary) -> void:
	if not _authority_trusted():
		return
	power_up_spawned_received.emit(payload)


func broadcast_power_up_collected(payload: Dictionary) -> void:
	if is_host() and not _is_offline:
		_share(&"_receive_power_up_collected", [payload])


@rpc("authority", "call_remote", "reliable")
func _receive_power_up_collected(payload: Dictionary) -> void:
	if not _authority_trusted():
		return
	power_up_collected_received.emit(payload)


func broadcast_ship_spawned(payload: Dictionary) -> void:
	if is_host() and not _is_offline:
		_share(&"_receive_ship_spawned", [payload])


@rpc("authority", "call_remote", "reliable")
func _receive_ship_spawned(payload: Dictionary) -> void:
	if not _authority_trusted():
		return
	ship_spawned_received.emit(payload)


func broadcast_ship_destroyed(payload: Dictionary) -> void:
	if is_host() and not _is_offline:
		_share(&"_receive_ship_destroyed", [payload])


@rpc("authority", "call_remote", "reliable")
func _receive_ship_destroyed(payload: Dictionary) -> void:
	if not _authority_trusted():
		return
	ship_destroyed_received.emit(payload)


## Announces that an asteroid broke apart: the rock's id plus the full description of
## every fragment it threw off. Reliable, because unlike a snapshot this cannot be
## re-derived -- a client that misses it keeps a rock nobody else has and never learns
## about the fragments, which the snapshot stream then silently skips.
func broadcast_asteroid_split(payload: Dictionary) -> void:
	if is_host() and not _is_offline:
		_share(&"_receive_asteroid_split", [payload])


@rpc("authority", "call_remote", "reliable")
func _receive_asteroid_split(payload: Dictionary) -> void:
	if not _authority_trusted():
		return
	asteroid_split_received.emit(payload)


func broadcast_score_updated(payload: Dictionary) -> void:
	_apply_score(payload)
	if is_host() and not _is_offline:
		_share(&"_receive_score_updated", [payload])


@rpc("authority", "call_remote", "reliable")
func _receive_score_updated(payload: Dictionary) -> void:
	if not _authority_trusted():
		return
	_apply_score(payload)


func _apply_score(payload: Dictionary) -> void:
	var peer_id := int(payload.get("peer_id", 0))
	var state: PlayerState = players.get(peer_id, null)
	if state != null:
		state.score = int(payload.get("score", state.score))
	score_updated_received.emit(payload)
	roster_changed.emit()


func broadcast_gameplay_event(event_type: NRTypes.GameplayEventType, position: Vector2) -> void:
	if is_host() and not _is_offline:
		_share(&"_receive_gameplay_event", [int(event_type), position])


@rpc("authority", "call_remote", "unreliable")
func _receive_gameplay_event(event_type: int, position: Vector2) -> void:
	if not _authority_trusted():
		return
	gameplay_event_received.emit(event_type as NRTypes.GameplayEventType, position)


func broadcast_match_completed(payload: Dictionary) -> void:
	match_completed_received.emit(payload)
	if is_host() and not _is_offline:
		_share(&"_receive_match_completed", [payload])


@rpc("authority", "call_remote", "reliable")
func _receive_match_completed(payload: Dictionary) -> void:
	if not _authority_trusted():
		return
	match_completed_received.emit(payload)


# --- Helpers ----------------------------------------------------------------

## Roster order: humans first (by peer id, so the host leads), then bots. Bots carry
## negative peer ids to stay clear of Godot's id space, so a plain numeric sort would
## push them above the local player.
func sorted_players() -> Array[PlayerState]:
	var list: Array[PlayerState] = []
	for id in players:
		list.append(players[id])
	list.sort_custom(func(a: PlayerState, b: PlayerState) -> bool:
		if a.is_bot != b.is_bot:
			return b.is_bot
		# Bot ids count *downwards* from BOT_PEER_ID_BASE, so they need the opposite
		# comparison to keep the first-spawned bot at the top of the block.
		if a.is_bot:
			return a.peer_id > b.peer_id
		return a.peer_id < b.peer_id)
	return list


func players_by_score() -> Array[PlayerState]:
	var list := sorted_players()
	list.sort_custom(func(a: PlayerState, b: PlayerState) -> bool: return a.score > b.score)
	return list
