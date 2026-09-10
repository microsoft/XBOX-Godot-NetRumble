class_name PlatformSession
extends RefCounted

## Everything the Xbox platform needs to know about a multiplayer session, and
## everything the session has to ask the platform before it lets players talk.
##
## `NetManager` owns the session itself — the transport, the roster and the RPCs. This
## object owns the obligations that ride along with it, which are a separate lesson and
## a separate set of requirements:
##
## - **Discovery (XR-064 / XR-124).** An *activity* is published when the session starts,
##   kept in step with the roster, and deleted when it ends. That activity is what makes
##   "Join game" light up on a friend's profile card and in the guide.
## - **Presence (XR-067).** A short line of rich presence text describing what the player
##   is doing right now.
## - **Recent players (XR-067).** The people this player has actually played with, so the
##   platform can offer them a way to add or report each other afterwards.
## - **Communication policy (XR-045 / XR-015).** Whether this account may use chat at all,
##   and then per player, whether the local player's mute list, avoid list and privacy
##   settings allow hearing or reading them.
## - **Identity verification (XR-047).** No name reaches the screen until the platform has
##   confirmed the peer claiming it really is that person.
##
## **This whole file no-ops without the GDK or a signed-in Xbox user.** Every entry point
## returns early when the service or the user is missing, so desktop development, the
## `--pf-user` test clients and offline practice matches run through it untouched. That is
## why the requirements can be implemented unconditionally rather than behind a platform
## `if` at each call site.
##
## It is driven off `NetManager`'s own signals rather than from each place that changes
## the roster, so the platform's view of the session cannot drift out of step as new
## roster paths are added.
##
## Held by `NetManager` as a plain object rather than a node: it has no scene presence and
## must not acquire a `_process` of its own.

## Whether this session should currently be advertised as joinable — the desired state,
## not the achieved one. `_write_activity` converges the service towards it.
var _activity_published := false
## What the service is believed to have. Three values, not two, because a write that was
## sent and not confirmed leaves a real third possibility: it may have landed. Recording
## that as "not published" is what let a failed publish be followed by a retirement that
## saw nothing to clear and sent nothing at all, leaving a started match advertised.
enum _Remote { UNKNOWN, PUBLISHED, CLEARED }
var _activity_remote: _Remote = _Remote.CLEARED
## Serialization for the two activity writes. Both are service calls that take their own
## time, and issuing them as they are asked for lets an older publish complete after a
## newer retirement — leaving a joinable activity for a session that has closed or ended,
## which is exactly what sends a friend into a match they will be refused from.
var _activity_writing := false
var _activity_update_queued := false
## Set when the published activity's contents (the player count) need refreshing even
## though its published/retired state has not changed.
var _activity_dirty := false
## Backoff for writes the service refused. Bounded on purpose: an activity is an
## advertisement, and a title that retries one forever spends a player's battery on it.
const _ACTIVITY_RETRY_DELAYS: Array[float] = [1.0, 2.0, 4.0]
## Retries spent in the current episode. An episode is one thing worth asking the service
## for — this session opening, closing, or ending — and it is deliberately not restarted
## by roster refreshes, which arrive often enough to make the budget meaningless.
var _activity_retries_used := 0
## At most one timer is ever outstanding, so overlapping failures cannot multiply into
## several converging passes.
var _activity_retry_pending := false
## Set while one session is being torn down to start another; see begin_activity_handover.
var _activity_handover := false
## XUIDs already reported as recent-player encounters this session, so nobody is
## reported twice. Cleared whenever a session ends.
var _reported_xuids: Dictionary = {}
var _recent_players_dirty := false

## The communications privilege answer, resolved once before host/join, and the
## player-facing reason when it is false.
var _chat_allowed := true
var _chat_restriction := ""
## Guards the per-player privacy evaluation, which is asynchronous and driven off
## roster_changed — a burst of joins must not start a second pass mid-flight.
var _chat_policy_running := false
var _chat_policy_queued := false
var _chat_policy_generation := 0
var _chat_privilege_running := false
signal _chat_privilege_finished()


func _init() -> void:
	# Driven off NetManager's own signals rather than each emit site, so the platform
	# view can't drift out of step with the roster as new roster paths are added.
	NetManager.roster_changed.connect(_on_roster_changed_for_activity)
	NetManager.player_joined.connect(_on_player_joined_for_activity)
	NetManager.match_state_changed.connect(_on_match_state_changed_for_activity)
	# Joinability is the other half of the activity's truth: a session that has closed to
	# newcomers must stop being offered as one, and every member advertises their own.
	NetManager.join_admission_changed.connect(_on_join_admission_changed_for_activity)
	# Same reasoning for the communication policy: every roster change re-evaluates who
	# this account is allowed to hear and read.
	NetManager.roster_changed.connect(_on_roster_changed_for_chat_policy)
	# And once more for identity: every roster change brings XUID claims that have to be
	# checked before any of them is shown to the player (XR-047).
	NetManager.roster_changed.connect(_on_roster_changed_for_profiles)
	var profiles := _profiles()
	if profiles != null and not profiles.profiles_changed.is_connected(_on_profiles_changed):
		profiles.profiles_changed.connect(_on_profiles_changed)
	Services.account_state_changed.connect(_on_chat_account_changed)
	# The activity cares about the account too, for a different reason: what the service
	# holds for a new user is nothing this has ever written, and a write refused while the
	# account was mid-change deserves another go once it settles.
	Services.account_state_changed.connect(_on_account_changed_for_activity)
	var connectivity := Services.connectivity()
	if connectivity != null:
		# Coming back online is the other genuine recovery, and the only notice of it.
		connectivity.connectivity_changed.connect(_on_connectivity_changed_for_activity)
	PlayerProfile.identity_changed.connect(_invalidate_chat_policy)


## A real recovery is a new reason to ask, so it starts a fresh episode — including after
## one that ran out of attempts. Roster churn is not a recovery and does not come through
## here, which is what keeps the budget meaning something.
func _on_account_changed_for_activity() -> void:
	_activity_retries_used = 0
	# Only reconcile when something could actually be out there. A sign-in with a
	# confirmed-clear activity and no session has nothing to disagree about, and asking
	# the service to delete an activity nobody ever published would send a needless call
	# at the title screen -- and, if it failed, open a backoff episode over nothing.
	if _activity_remote == _Remote.PUBLISHED or _activity_published:
		# Whatever the service holds for whoever is signed in now was not written from
		# here, so the previous account's confirmation says nothing about it.
		_activity_remote = _Remote.UNKNOWN
	publish_activity()


func _on_connectivity_changed_for_activity(online: bool) -> void:
	if not online:
		return
	_activity_retries_used = 0
	publish_activity()


func _activity() -> ActivityService:
	return Services.activity() if Services != null else null


func _xbox_user() -> Variant:
	return Services.xbox_user() if Services != null else null


func _profiles() -> ProfileService:
	return Services.profiles() if Services != null else null


func _party() -> PartyService:
	return Services.party() if Services != null else null


func _chat() -> ChatService:
	return Services.chat() if Services != null else null


# --- Activity and presence (XR-064 / XR-124 / XR-067) -----------------------

## Advertises the session so it can be joined from the guide, a friend's profile card
## or an invite. The connection string is the PlayFab lobby's, which
## PartyService.join_by_connection_string() consumes directly — no code lookup, so the
## platform join path skips the slowest and least reliable part of joining.
##
## Only ever advertises a session that is actually joinable. A match that has started is
## closed to newcomers, and an activity outlives the match unless something retracts it,
## so this doubles as the retraction: asked to publish for a closed or ended session, it
## takes the activity down instead.
func publish_activity() -> void:
	var joinable := _session_is_joinable()
	if joinable != _activity_published:
		# The session opened or closed. That is a new thing to ask the service for, so it
		# gets its own attempts rather than inheriting the exhaustion of the state it
		# replaced.
		_activity_published = joinable
		_activity_retries_used = 0
	_activity_dirty = _activity_dirty or _activity_published
	_write_activity()


## Whether there is a live, open session for the platform to offer a joiner.
##
## Every member answers this for their own activity, host and guest alike: a guest's
## activity is just as visible to their friends as the host's, and NetManager mirrors the
## host's admission state onto every client so they all agree on the answer.
func _session_is_joinable() -> bool:
	# Mid-handover the old session is being torn down and the new one does not exist yet,
	# so the honest answer is "no" and the useful one is "wait".
	if _activity_handover:
		return _activity_published
	if _activity() == null or _xbox_user() == null:
		return false
	if _party() == null:
		return false
	# Practice is a single-machine session; advertising one offers the platform a match
	# nobody can enter.
	if NetManager.is_offline() or not NetManager.has_session():
		return false
	return NetManager.is_accepting_joins()


## Holds the activity still while NetManager tears one session down to start another.
##
## The activity is about to be republished for the new session, so retiring it in between
## would take the player out of their friends' guide for the length of a host or join and
## then put them straight back. The old `keep_activity` reset flag covered the teardown
## call; this covers the admission change that now travels with it.
func begin_activity_handover() -> void:
	_activity_handover = true


func end_activity_handover() -> void:
	_activity_handover = false


## Refreshes the advertised player count. Coalesced: eight players joining at once
## would otherwise fire eight service calls.
func _queue_activity_update() -> void:
	if not _activity_published or _activity_update_queued:
		return
	_activity_update_queued = true
	await NetManager.get_tree().create_timer(0.5).timeout
	_activity_update_queued = false
	# Half a second is long enough for the match to have started, or ended, or for the
	# player to have left it. publish_activity re-reads that rather than assuming the
	# session it was queued for is still the one in front of it.
	publish_activity()


func retire_activity() -> void:
	_activity_published = false
	# Leaving is a lifecycle transition, so it gets its own attempts. An activity that has
	# to come down should not be denied them because publishing it had used them up.
	_activity_retries_used = 0
	_write_activity()


## True while the service's view differs from what this session wants advertised, or while
## a published activity's contents have gone stale.
##
## An unknown remote state always counts as a difference. That is the point of having one:
## after a write the service did not confirm, the only safe assumption is that something
## may be out there, and the only way to find out is to ask again.
func _activity_needs_write() -> bool:
	var desired: _Remote = _Remote.PUBLISHED if _activity_published else _Remote.CLEARED
	if _activity_remote != desired:
		return true
	return _activity_published and _activity_dirty


## The single writer. One service call is in flight at a time and each pass re-reads the
## desired state when it starts, so the last state asked for is the one that ends up
## published however the requests overlapped.
func _write_activity() -> void:
	if _activity_writing:
		return
	_activity_writing = true
	while _activity_needs_write():
		var target := _activity_published
		_activity_dirty = false
		var activity := _activity()
		var user: Variant = _xbox_user()
		if activity == null or user == null:
			# Nothing can be written and nothing can have been: signed out, or a build
			# without the GDK. No retry either -- there is no service to retry against.
			_activity_remote = _Remote.CLEARED
			break
		var result := ActivityService.WriteResult.UNAVAILABLE
		if target:
			var party := _party()
			if party == null:
				_activity_published = false
				continue
			# The join code is the session's stable shared identifier — every member has
			# the same one and it lives as long as the session does, which is exactly
			# what the activity's group id is for.
			result = await activity.set_activity(
				user,
				party.lobby_connection_string(),
				_max_players(),
				NetManager.players.size(),
				NetManager.join_code)
		else:
			result = await activity.delete_activity(user)
		if _xbox_user() != user:
			# The account changed while the call was outstanding. An answer about the old
			# user's activity says nothing about the new user's, so it is not recorded --
			# and the loop converges again from whoever is signed in now.
			_activity_remote = _Remote.UNKNOWN
			continue
		if result == ActivityService.WriteResult.CONFIRMED:
			_activity_remote = _Remote.PUBLISHED if target else _Remote.CLEARED
			_activity_retries_used = 0
			continue
		if result == ActivityService.WriteResult.UNAVAILABLE:
			_activity_remote = _Remote.CLEARED
			break
		# Refused or unusable. What is out there is now unknown rather than assumed
		# absent, so the next pass has something to converge even where this one asked for
		# a delete -- which is what makes a failed publish followed by a close still send
		# one. Retrying happens on a timer, not in this loop, which would spin.
		_activity_remote = _Remote.UNKNOWN
		_activity_dirty = _activity_dirty or target
		_schedule_activity_retry(target, result)
		break
	_activity_writing = false


## Waits out the backoff, then converges again. Bounded, and silent when it runs out.
func _schedule_activity_retry(target: bool, result: ActivityService.WriteResult) -> void:
	if _activity_retry_pending:
		return
	if result != ActivityService.WriteResult.FAILED:
		# INVALID means the input was unusable, not that the service is struggling.
		# Retrying it on a timer would spend the budget without ever sending anything
		# different; only a real state change produces input worth sending.
		return
	if _activity_retries_used >= _ACTIVITY_RETRY_DELAYS.size():
		# Out of attempts. The unresolved state is kept rather than papered over, and the
		# next lifecycle transition starts a fresh episode and converges it. No dialog:
		# the membership lock and the host's admission check are what actually keep an
		# unwanted joiner out, so a stale entry in a friend's guide is untidy, not unsafe.
		# The message names the operation and the count and nothing else -- a connection
		# string or an account identifier in a log is not the player's to leak.
		push_warning("[Activity] %s did not complete after %d attempts; the platform's view of this session is out of date." % [
			"Publishing the activity" if target else "Clearing the activity",
			_ACTIVITY_RETRY_DELAYS.size() + 1,
		])
		return
	var delay := _ACTIVITY_RETRY_DELAYS[_activity_retries_used]
	_activity_retries_used += 1
	_activity_retry_pending = true
	await NetManager.get_tree().create_timer(delay).timeout
	_activity_retry_pending = false
	# Converged from current state rather than replayed: the session may have opened,
	# closed or ended while the timer ran, and the write that matters now is for the state
	# that exists now.
	_write_activity()


func update_presence(status: String) -> void:
	if Services != null:
		Services.update_presence(status)


func _max_players() -> int:
	var mode := Assets.game_mode(NetManager.game_mode_type)
	return mode.player_count if mode != null else 0


func _on_roster_changed_for_activity() -> void:
	_queue_activity_update()


## Someone arriving mid-match has been played with, so they count as an encounter. In
## the lobby they do not: a player who joins and leaves before the match starts was
## never actually played with. Anyone who arrives during STARTING is already covered by
## the sweep on the RUNNING transition below.
func _on_player_joined_for_activity(state: PlayerState) -> void:
	if NetManager.match_state == NRTypes.MatchState.RUNNING:
		_report_recent_players([state])


func _on_match_state_changed_for_activity(state: NRTypes.MatchState) -> void:
	if state != NRTypes.MatchState.RUNNING:
		return
	var mode := Assets.game_mode(NetManager.game_mode_type)
	update_presence("Playing %s" % (mode.display_name if mode != null else "NetRumble"))
	# The match is now genuinely being played, so everyone present has been encountered.
	_report_recent_players(NetManager.players.values())


## The session opened or closed to newcomers. Publishing re-reads joinability, so this
## republishes on an open and retires on a close without having to decide which.
func _on_join_admission_changed_for_activity(_open: bool) -> void:
	publish_activity()


## Records an encounter with each of the given players, skipping the local player,
## anyone already reported this session, and anyone with no XUID (offline play, and
## every --pf-user desktop test client). The service call itself is coalesced.
func _report_recent_players(states: Array) -> void:
	var activity := _activity()
	var user: Variant = _xbox_user()
	if activity == null or user == null or NetManager.is_offline():
		return
	var local_id := NetManager.local_peer_id()
	var batch := PackedStringArray()
	for state in states:
		if state == null or state.peer_id == local_id:
			continue
		var xuid := String(state.xbox_user_id).strip_edges()
		if xuid.is_empty() or _reported_xuids.has(xuid):
			continue
		_reported_xuids[xuid] = true
		batch.append(xuid)
	if batch.is_empty():
		return
	activity.report_recent_players(user, batch)
	_queue_recent_players_flush()


## update_recent_players batches locally; flush_recent_players_async is the service
## call. Draining on a short timer means an eight-player match start costs one flush.
func _queue_recent_players_flush() -> void:
	if _recent_players_dirty:
		return
	_recent_players_dirty = true
	await NetManager.get_tree().create_timer(2.0).timeout
	flush_recent_players()


func flush_recent_players() -> void:
	if not _recent_players_dirty:
		return
	_recent_players_dirty = false
	var activity := _activity()
	var user: Variant = _xbox_user()
	if activity != null and user != null:
		activity.flush_recent_players(user)


# --- Chat policy (XR-045 / XR-015) ------------------------------------------
#
# Two gates, resolved in different places because they answer different questions.
# The communications *privilege* is a property of the account and is settled once per
# session, before the Party network exists, so a denial can keep voice and text out of
# the network configuration entirely. The privacy *permissions*, mute list and avoid
# list are per-player and are re-evaluated whenever the roster changes.

## Whether this session has voice and text chat at all.
func is_chat_allowed() -> bool:
	return _chat_allowed


## Player-facing reason chat is unavailable, empty when it is available.
func chat_restriction_reason() -> String:
	return _chat_restriction


## True when the player may mute or unmute this peer themselves. A voice the platform
## already silenced is not theirs to lift, and the local player is not mutable at all.
## A text-only restriction leaves the player audible, so it leaves them mutable.
func can_mute_peer(peer_id: int) -> bool:
	var party := _party()
	var chat := _chat()
	if NetManager.is_offline() or party == null or chat == null or not party.has_network() \
			or not _chat_allowed:
		return false
	if peer_id == NetManager.local_peer_id():
		return false
	var entity_key: Dictionary = entity_key_for(peer_id)
	return not entity_key.is_empty() and not chat.is_peer_voice_restricted(entity_key)


func is_peer_muted(peer_id: int) -> bool:
	var chat := _chat()
	if chat == null:
		return false
	var entity_key: Dictionary = entity_key_for(peer_id)
	return not entity_key.is_empty() and chat.is_peer_muted(entity_key)


## True when the platform silenced this player's voice, so the roster can say why a row
## it will not let the player unmute is muted anyway.
func is_peer_voice_restricted(peer_id: int) -> bool:
	var chat := _chat()
	if chat == null:
		return false
	var entity_key: Dictionary = entity_key_for(peer_id)
	return not entity_key.is_empty() and chat.is_peer_voice_restricted(entity_key)


## Mutes or unmutes one player for the local player only. This is the caller
## ChatService.set_peer_muted() never had; the lobby roster drives it.
func toggle_peer_mute(peer_id: int) -> void:
	if not can_mute_peer(peer_id):
		return
	var chat := _chat()
	var entity_key: Dictionary = entity_key_for(peer_id)
	await chat.set_peer_muted(entity_key, not chat.is_peer_muted(entity_key))
	NetManager.chat_indicators_changed.emit()


## Resolves the communications privilege for this session and hands the answer to
## ChatService before PartyService builds the network config. Denied chat means the
## network is created with voice and text off and no chat control at all, rather than a
## player sitting muted in a live mesh.
func apply_chat_privilege() -> void:
	if _chat_privilege_running:
		await _chat_privilege_finished
		return
	_chat_privilege_running = true
	_chat_allowed = false
	_chat_restriction = "Chat permissions have not been resolved."
	var chat := _chat()
	if chat != null:
		chat.set_chat_allowed(false)
	if Services != null and chat != null:
		var identity: Variant = Services.playfab_user()
		while true:
			var generation := _chat_policy_generation
			var verdict: Dictionary = await Services.can_communicate()
			if generation != _chat_policy_generation:
				if Services.playfab_user() != identity:
					_chat_restriction = "The signed-in account changed. Rejoin to use chat."
					break
				# The caller must await the replacement verdict, not mistake an
				# abandoned request for a completed privilege check.
				continue
			_chat_allowed = bool(verdict.get("granted", false))
			_chat_restriction = "" if _chat_allowed else String(verdict.get("message", ""))
			if not _chat_allowed and _chat_restriction.is_empty():
				_chat_restriction = "This account is not allowed to use voice and text chat."
			chat.set_chat_allowed(_chat_allowed)
			break
	if not _chat_allowed:
		print("[Net] Chat disabled for this session: %s" % _chat_restriction)
	_chat_privilege_running = false
	_chat_privilege_finished.emit()


func _invalidate_chat_policy() -> void:
	_chat_policy_generation += 1
	_chat_policy_running = false
	_chat_policy_queued = false
	var chat := _chat()
	if chat != null:
		chat.invalidate_text_policy()


func _on_chat_account_changed() -> void:
	_invalidate_chat_policy()
	var chat := _chat()
	if chat == null:
		return
	var party := _party()
	var in_session := party != null and party.has_network() and NetManager.has_session()
	# This fires when the account's privileges change or it is re-authenticated, not when
	# a different player takes over -- the platform terminates the title when the signed-in
	# user is removed. What is new is that a retained chat control can be sitting at the
	# menu with no session around it, and a chat privilege withdrawn there has to reach it
	# (XR-045) rather than wait for the next match to notice.
	if not in_session and not chat.has_control():
		return
	var generation := _chat_policy_generation
	await apply_chat_privilege()
	if generation != _chat_policy_generation:
		return
	if not _chat_allowed:
		await chat.destroy_control()
	elif in_session:
		apply_chat_restrictions()


func _on_roster_changed_for_chat_policy() -> void:
	apply_chat_restrictions()


## Evaluates every remote player against the platform mute list, avoid list and the
## communicate_using_voice / communicate_using_text permissions, then pushes the verdict
## into ChatService. Serialized: a roster change arriving mid-pass queues one more pass
## rather than racing it, so eight players joining at once costs one evaluation.
func apply_chat_restrictions() -> void:
	var party := _party()
	var chat := _chat()
	var user: Variant = _xbox_user()
	if NetManager.is_offline() or party == null or chat == null or not party.has_network() \
			or not _chat_allowed:
		return
	if Services == null:
		return
	var active_keys: Array[Dictionary] = []
	for state: PlayerState in NetManager.players.values():
		if state != null and state.peer_id != NetManager.local_peer_id():
			var key := party.entity_key_for(state.peer_id)
			if not key.is_empty():
				active_keys.append(key)
	chat.retain_text_peers(active_keys)
	if _chat_policy_running:
		_chat_policy_queued = true
		return
	var privacy := Services.privacy()
	var platform_privacy := privacy != null and privacy.is_available(user)

	_chat_policy_running = true
	var generation := _chat_policy_generation
	var local_id := NetManager.local_peer_id()
	var xuids := PackedStringArray()
	var peers: Array[Dictionary] = []
	for state: PlayerState in NetManager.players.values():
		if state == null or state.peer_id == local_id:
			continue
		var entity_key: Dictionary = party.entity_key_for(state.peer_id)
		if entity_key.is_empty():
			continue
		var xuid := String(state.xbox_user_id).strip_edges()
		peers.append({"peer_id": state.peer_id, "entity_key": entity_key, "xuid": xuid})
		if platform_privacy and not xuid.is_empty() and not xuids.has(xuid):
			xuids.append(xuid)

	var verdicts: Dictionary = {}
	if not xuids.is_empty():
		verdicts = await privacy.evaluate(user, xuids)
		if generation != _chat_policy_generation:
			return
		if verdicts.is_empty():
			_chat_policy_queued = true
	for peer: Dictionary in peers:
		if generation != _chat_policy_generation:
			return
		var peer_id: int = peer["peer_id"]
		var entity_key: Dictionary = peer["entity_key"]
		if not NetManager.players.has(peer_id) or party.entity_key_for(peer_id) != entity_key:
			continue
		var verdict: Dictionary = verdicts.get(peer["xuid"], {})
		# Custom-ID clients still admit only authenticated roster peers. Xbox sessions
		# need a completed text verdict; an absent XUID or failed query grants no text.
		await chat.set_peer_restrictions(
			entity_key,
			not platform_privacy or bool(verdict.get("voice", false)),
			not platform_privacy or bool(verdict.get("text", false)),
		)

	if generation != _chat_policy_generation:
		return
	_chat_policy_running = false
	if _chat_policy_queued:
		_chat_policy_queued = false
		apply_chat_restrictions()


## The PlayFab entity key for a peer: Party's authenticated one where it exists, and the
## roster's replicated entity id otherwise (a player whose chat control has not reached
## the mesh yet still needs a key to carry a verdict).
func entity_key_for(peer_id: int) -> Dictionary:
	var party := _party()
	if party == null:
		return {}
	var entity_key: Dictionary = party.entity_key_for(peer_id)
	if not entity_key.is_empty():
		return entity_key
	var state: PlayerState = NetManager.players.get(peer_id, null)
	if state == null or String(state.entity_id).is_empty():
		return {}
	return {"id": state.entity_id, "type": "title_player_account"}


# --- Identity verification (XR-047) -----------------------------------------

## Repaints wherever the roster is drawn once a verification pass has changed what a
## player is called. Re-entry is safe: the pass this triggers finds every claim already
## resolved, changes nothing and emits nothing.
func _on_profiles_changed() -> void:
	NetManager.roster_changed.emit()


func _on_roster_changed_for_profiles() -> void:
	refresh_player_profiles()


## Hands ProfileService the identity claims for every remote player: Party's
## authenticated entity key paired with the XUID that peer says it is (XR-047).
##
## Only Party's key is passed, never the roster's replicated `entity_id`. The two are
## normally the same value — the host overwrites the roster copy with Party's — but the
## roster copy arrives over the game's own RPC, so verifying against it would just be
## asking the host to vouch for itself. Taking it from the transport is what lets every
## machine reach its own verdict.
##
## The local player is skipped: its name already comes from its own signed-in Xbox
## identity, so there is nothing to check and no round trip worth spending.
func refresh_player_profiles() -> void:
	var profiles := _profiles()
	var party := _party()
	if profiles == null or party == null or NetManager.is_offline() or not party.has_network():
		return
	if Services == null or not profiles.is_available(Services.playfab_user(), _xbox_user()):
		return

	var local_id := NetManager.local_peer_id()
	var claims: Array[Dictionary] = []
	for state: PlayerState in NetManager.players.values():
		if state == null or state.is_bot or state.peer_id == local_id:
			continue
		var entity_key: Dictionary = party.entity_key_for(state.peer_id)
		var entity_id := String(entity_key.get("id", "")).strip_edges()
		var xuid := String(state.xbox_user_id).strip_edges()
		if entity_id.is_empty() or xuid.is_empty():
			continue
		claims.append({"peer_id": state.peer_id, "entity_id": entity_id, "xuid": xuid})

	profiles.resolve(Services.playfab_user(), _xbox_user(), claims)


# --- Session teardown -------------------------------------------------------

## Returns every platform obligation to its between-sessions state. `keep_activity` is
## set only when NetManager is leaving one session to immediately start another, so the
## activity that is about to be republished is not deleted and re-created in between.
func reset_after_leave(keep_activity: bool) -> void:
	_invalidate_chat_policy()
	# Any encounters from the match just left would otherwise never reach the service,
	# and a short match could end before the coalescing timer drains.
	flush_recent_players()
	_reported_xuids.clear()
	if not keep_activity:
		retire_activity()
		update_presence("In the menus")
	# The privilege answer belongs to the session that just ended; the next host or join
	# resolves it again before the network exists.
	_chat_allowed = true
	_chat_restriction = ""
	_chat_policy_queued = false
	# Verified names are proven per session and peer ids are reused, so a name must not
	# outlive the peer it was proven for.
	var profiles := _profiles()
	if profiles != null:
		profiles.clear_session()
