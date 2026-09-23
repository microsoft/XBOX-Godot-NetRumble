extends Node

## Facade over the Microsoft GDK and PlayFab addons for the rest of the game.
##
## Covers achievements, leaderboards, cloud saves, presence, voice chat and Party
## networking. The implementation is split across scripts/services/*; this file stays
## a thin, well-documented facade that the UI and gameplay code call.
##
## Authentication and all three Game Saves loads form one readiness transaction.
## No gameplay or account persistence is permitted before that transaction succeeds.

signal sign_in_completed(success: bool)
signal account_state_changed()
signal account_lost()
signal save_failed(reason: String)
signal leaderboard_submission_changed()
## The step sign-in is currently on, in words fit to show the player. Forwarded from
## IdentityService and extended with the steps this facade owns, so the acquire-user
## screen can name the call it is waiting on.
signal sign_in_stage_changed(stage: String)

const MATCH_HISTORY_LIMIT := 50

## Resolves the GDK singleton the same way the services below do, so the privilege
## cache can be invalidated from XboxUsers.user_changed.
const XboxBootstrap := preload("res://addons/godot_gdk/runtime/gdk_bootstrap.gd")

var _identity: IdentityService = null
var _achievements: AchievementService = null
var _leaderboards: LeaderboardService = null
var _matchmaking: MatchmakingService = null
## Notice ownership is separate from the service's per-entity write gate. An older
## completion cannot replace a newer attempt's notice or expose it to another session.
var _leaderboard_submission: Dictionary = {}
var _leaderboard_submission_user: Variant = null
var _leaderboard_submission_serial := 0
var _achievement_tracker: AchievementTracker = null
var _game_saves: GameSaveService = null
var _party: PartyService = null
var _chat: ChatService = null
var _activity: ActivityService = null
var _privileges: PrivilegeService = null
var _privacy: PrivacyService = null
var _moderation: ModerationService = null
var _social: SocialService = null
var _profiles: ProfileService = null
var _devices: DeviceService = null
var _connectivity: ConnectivityService = null
## One monotonic time source for every online deadline, shared by NetManager, the
## matchmaking flow, PlatformSession and the services it configures below. Initialized
## here rather than in _ready() so a Services subclass that replaces _ready() still has it.
var _clock: OnlineFlowClock = OnlineFlowClock.new()

## The current account's working copy, newest first.
var _history: Array[Dictionary] = []
var _account_generation := 0
var _ready_owner: Variant = null
var _save_error := ""

var _signing_in: bool = false
## The step sign-in is on, in words fit to show the player. Kept as state as well as a
## signal so a screen that subscribes after a step was announced still shows it.
var sign_in_stage := ""
## True once XboxUsers.user_changed is hooked up, so warming twice cannot
## double-subscribe.
var _user_changed_connected := false
## Set once the title has committed to exiting, while a platform call is still in flight.
## The call is left to land -- stranding it is what hung the title on the way out -- but
## everything queued up behind it is abandoned: there is no session left to finish setting
## up, and the profile syncs and cache warming behind it would only start fresh platform
## calls into a runtime that is about to go away.
var _shutting_down := false


func _ready() -> void:
	_identity = IdentityService.new()
	_identity.stage_changed.connect(_set_sign_in_stage)
	_identity.platform_ready.connect(_connect_user_changed)
	_achievements = AchievementService.new()
	_leaderboards = LeaderboardService.new()
	_matchmaking = MatchmakingService.new()
	_matchmaking.configure_clock(_clock)
	_achievement_tracker = AchievementTracker.new()
	_achievement_tracker.progress_changed.connect(_on_achievement_progress)
	_game_saves = GameSaveService.new()
	# Chat is built first because PartyService drives its lifetime: a chat control only
	# exists alongside a Party network.
	_chat = ChatService.new()
	_party = PartyService.new(_chat)
	_party.configure_clock(_clock)
	_activity = ActivityService.new()
	_privileges = PrivilegeService.new()
	_privacy = PrivacyService.new()
	_moderation = ModerationService.new()
	_social = SocialService.new()
	_profiles = ProfileService.new()
	_devices = DeviceService.new()
	_devices.start(null)
	# Not account-scoped: connectivity is a property of the console, so this is started
	# once here and never restarted for a user. It reads the platform's hint, so it costs
	# nothing on a machine that cannot answer and stays optimistic there.
	_connectivity = ConnectivityService.new()
	_connectivity.start()
	_connect_user_changed()
	# NetManager is autoloaded *after* this one, so it does not exist yet. Deferring puts
	# the subscription at the end of the frame, by which point every autoload is up.
	_connect_match_signals.call_deferred()


# --- Identity ---------------------------------------------------------------

## PlayFab Party transport + PlayFab Lobby matchmaking. Owned here so it shares the
## signed-in PlayFabUser; NetManager drives it.
func party() -> PartyService:
	return _party


## Voice and text chat over the Party network, plus the communication policy — the
## account's chat privilege (XR-045) and the per-player privacy verdicts (XR-015) — that
## decides who may be heard and read. PartyService creates and destroys the chat control;
## NetManager supplies the verdicts and the UI reads its state from here.
func chat() -> ChatService:
	return _chat


## Xbox multiplayer activity, invites, presence and recent players. NetManager drives
## the session lifecycle and InviteRouter consumes its invite signal.
func activity() -> ActivityService:
	return _activity


## Account privilege checks (XR-045). NetManager gates host/join and the chat config on
## it; nothing else calls the privilege APIs.
func privileges() -> PrivilegeService:
	return _privileges


## Per-player communication privacy (XR-015): permissions plus the platform mute and
## avoid lists. NetManager turns its verdicts into Party mutes.
func privacy() -> PrivacyService:
	return _privacy


## String verification for player-authored chat, and the player reporting path (XR-018).
## NetManager verifies before it sends; the lobby's player actions overlay reports.
func moderation() -> ModerationService:
	return _moderation


## Service-verified gamertags for remote players (XR-047). NetManager drives it from the
## roster; PlayerState.display_label() is what reads the answers.
func profiles() -> ProfileService:
	return _profiles


## Whether the player still has a controller (XR-115). main.gd raises the reconnect
## prompt from its signals; nothing else needs to care.
func devices() -> DeviceService:
	return _devices


## Whether the console is definitively offline (XR-074). Fails open, so this only ever
## reports offline on a platform certainty; see ConnectivityService for why.
func connectivity() -> ConnectivityService:
	return _connectivity


## The verified gamertag for a peer, or an empty string when the platform has not
## confirmed one. Callers fall back to the name the peer supplied itself, which is all
## there is on desktop, for bots and for a claim that failed verification.
func gamertag_for_peer(peer_id: int) -> String:
	return _profiles.gamertag_for_peer(peer_id) if _profiles != null else ""


## The Xbox friends list (XR-070). The main menu's Join Friend row is the only caller;
## joinable_friends() below is the question it actually asks.
func social() -> SocialService:
	return _social


## True when a real friends list can be produced: a GDK build with a signed-in Xbox
## identity. The Join Friend overlay uses this to name an unavailable platform instead
## of pretending the player simply has no friends online.
func social_available() -> bool:
	return _social != null and _social.is_available(xbox_user())


## The friends who are in a NetRumble session this player can join (XR-070), as
## `{xuid, gamertag, display_name, connection_string, current_players, max_players}`
## sorted by gamertag.
##
## Two platform questions make one answer: who this player's friends are (SocialService)
## and which of them have a joinable activity for this title (ActivityService). Neither
## half is useful alone — a friends list with no joinability is a directory, and
## activities need XUIDs to ask about — so they are joined here rather than in the UI.
func joinable_friends() -> Array[Dictionary]:
	var joinable: Array[Dictionary] = []
	if not is_account_ready() or _social == null or _activity == null:
		return joinable
	var generation := _account_generation
	var user: Variant = xbox_user()
	if user == null:
		return joinable

	var friends: Array[Dictionary] = await _social.friends(user)
	if not is_current_account(generation) or friends.is_empty():
		return joinable

	var xuids := PackedStringArray()
	for friend in friends:
		xuids.append(String(friend.get("xuid", "")))

	var activities: Dictionary = await _activity.joinable_activities(user, xuids)
	if not is_current_account(generation):
		return []
	for friend in friends:
		var friend_activity: Dictionary = activities.get(String(friend.get("xuid", "")), {})
		if friend_activity.is_empty():
			continue
		var entry := friend.duplicate()
		entry.merge(friend_activity, true)
		joinable.append(entry)
	return joinable


## The lobby connection string for the session `xuid` is in, or empty. InviteRouter uses
## this to turn a platform activation — which names the host, not the session — into
## something joinable.
func connection_string_for_xuid(xuid: String) -> String:
	if not is_account_ready() or _activity == null:
		return ""
	var generation := _account_generation
	var connection: String = await _activity.connection_string_for_xuid(xbox_user(), xuid)
	return connection if is_current_account(generation) else ""


## Verifies one player-authored string before it is published. Returns a
## ModerationService verdict; `acceptable` false carries the sentence to show the player.
func verify_chat_text(text: String) -> Dictionary:
	if _moderation == null:
		return ModerationService.unchecked()
	return await _moderation.verify(xbox_user(), text)


## Files a reputation report against another player. `feedback_type` comes from
## ModerationService.REPORT_REASONS. Returns false when the report did not reach the
## service, including on every build with no Xbox identity to report against.
func report_player(target_xuid: String, feedback_type: String) -> bool:
	if _moderation == null:
		return false
	return await _moderation.report(xbox_user(), target_xuid, feedback_type)


## True when there is a platform to verify and report through. The UI hides the report
## action rather than offering one that cannot work.
func moderation_available() -> bool:
	return _moderation != null and _moderation.is_available(xbox_user())


## Whether this account may host or join an online session. Offers the system
## resolution UI on a denial and re-checks, so a player who fixes the problem there is
## not sent back to retry the action themselves. Returns a PrivilegeService verdict.
func can_play_multiplayer() -> Dictionary:
	if _privileges == null:
		return PrivilegeService.unchecked()
	return await _privileges.ensure(xbox_user(), PrivilegeService.MULTIPLAYER)


## Whether this account may use voice and text chat, resolved the same way.
func can_communicate() -> Dictionary:
	if _privileges == null:
		return PrivilegeService.unchecked()
	return await _privileges.ensure(xbox_user(), PrivilegeService.COMMUNICATIONS)


## The authoritative reason this account may not play online, empty when it may. Offers
## the system resolution UI on a privilege denial before reporting one, so active host
## and join entry points do not mistake "never checked" for "allowed" (XR-045).
##
## Connectivity is folded in here rather than checked separately so that every existing
## refusal site -- Host Match, Lobby Code, and anything added later -- covers being
## offline for free, and so the player is told the real reason rather than watching a
## connection attempt fail. Connectivity is reported first because it is the more
## fundamental problem: an account without the multiplayer privilege still cannot fix
## anything until the console is back on a network.
func resolve_multiplayer_denial_reason() -> String:
	if not is_account_ready():
		return "Sign in and load your saved data before starting a match."
	var generation := _account_generation
	if _connectivity != null and not _connectivity.is_online():
		return _connectivity.offline_reason()
	var verdict: Dictionary = await can_play_multiplayer()
	if not is_current_account(generation):
		return "The signed-in account changed. Please try again."
	if bool(verdict.get("granted", true)):
		return ""
	return String(verdict.get("message", ""))


## The cached reason this account may not play online, empty when it may or when the
## privilege has never been checked. For passive UI that wants to reflect a known denial
## without a platform round trip; active host and join entry points use
## resolve_multiplayer_denial_reason() so an unknown privilege is checked first.
##
## Connectivity is still read live because it is a cheap device hint rather than a
## privilege query, and because being offline is always a real denial for online play.
func multiplayer_denial_reason() -> String:
	if _connectivity != null and not _connectivity.is_online():
		return _connectivity.offline_reason()
	if _privileges == null:
		return ""
	var verdict: Dictionary = _privileges.cached(PrivilegeService.MULTIPLAYER)
	if bool(verdict.get("granted", true)):
		return ""
	return String(verdict.get("message", ""))


## The signed-in XboxUser, or null on a custom-id session and in a build with no GDK.
## Every platform call needs it, and its absence is the signal to skip them.
func xbox_user() -> Variant:
	return _identity.gdk_user if _identity != null else null


## The signed-in PlayFabUser, or null. Party and Lobby calls both require it.
func playfab_user() -> Variant:
	return _identity.playfab_user if _identity != null else null


## Player-facing reason the last sign-in attempt failed. Empty when it succeeded.
func sign_in_error() -> String:
	if not _save_error.is_empty():
		return _save_error
	return _identity.last_error if _identity != null else "Services are unavailable."


## True when this instance runs under a --pf-user custom-id override instead of a real
## Xbox sign-in. Used only to label the UI so a test client is never mistaken for one.
func is_custom_id_session() -> bool:
	return not IdentityService.resolve_custom_id_token().is_empty()


## The running title's Xbox sandbox, Title ID and Store ID, as
## {"sandbox_id": String, "title_id": String, "store_id": String}. Read from the GDK
## runtime, with the Store ID falling back to MicrosoftGame.config when running
## unpackaged, and IdentityService.UNKNOWN_TITLE_ID standing in for anything neither can
## supply. These identify the title and its environment rather than the player, so no
## sign-in is required.
func title_identifiers() -> Dictionary:
	if _identity == null:
		return {
			"sandbox_id": IdentityService.UNKNOWN_TITLE_ID,
			"title_id": IdentityService.UNKNOWN_TITLE_ID,
			"store_id": IdentityService.UNKNOWN_TITLE_ID,
		}
	return _identity.get_title_identifiers()


## GDK (check -> silent -> UI) then PlayFab sign-in. Idempotent and safe to await from
## several callers at once. Returns false — without erroring — when it cannot complete;
## read sign_in_error() for the reason.
func sign_in() -> bool:
	if _shutting_down:
		return false
	if is_account_ready():
		return true
	var generation := _account_generation
	if _signing_in:
		while _signing_in:
			await get_tree().process_frame
		return is_current_account(generation)
	if _ready_owner != null:
		cancel_sign_in()
		generation = _account_generation
	_signing_in = true
	_save_error = ""
	_set_sign_in_stage("Starting")
	var success := await _prepare_account(generation)
	_signing_in = false
	_set_sign_in_stage("")
	success = success and is_current_account(generation)
	sign_in_completed.emit(success)
	return success


func _prepare_account(generation: int) -> bool:
	if not await _wait_for_session_teardown(generation):
		return false
	if not _identity.is_signed_in():
		var authenticated: bool = await _identity.sign_in()
		if not _attempt_current(generation) or not authenticated:
			return false
	if not _attempt_current(generation):
		return false
	_connect_user_changed()
	if _activity != null:
		_activity.ensure_activation_subscribed()
	var user: Variant = xbox_user()
	if user == null or not user.signed_in or playfab_user() == null:
		_save_error = "Game Saves requires a signed-in Xbox account. Custom-ID authentication cannot start gameplay."
		return false
	_set_sign_in_stage("Syncing your saved data")
	var prepared := await _game_saves.prepare(user, generation)
	if not await _wait_for_session_teardown(generation):
		return false
	if not _attempt_current(generation) or user != xbox_user() or not user.signed_in:
		return false
	if prepared.status != GameSaveService.Status.OK:
		_save_error = String(prepared.reason)
		return false
	var staged: Dictionary = {}
	for file_name: String in [GameSaveService.SAVE_FILE_NAME, GameSaveService.HISTORY_FILE_NAME, GameSaveService.STATS_FILE_NAME]:
		var read_started := Time.get_ticks_msec()
		print("[SaveLoad] reading %s" % file_name)
		var loaded := _game_saves.read(user, generation, file_name)
		print("[SaveLoad] read %s status=%s elapsed_ms=%d" % [file_name, GameSaveService.Status.keys()[loaded.status], Time.get_ticks_msec() - read_started])
		if loaded.status not in [GameSaveService.Status.OK, GameSaveService.Status.MISSING]:
			_save_error = String(loaded.reason)
			return false
		staged[file_name] = loaded.data
	if not _attempt_current(generation) or user != xbox_user() or not user.signed_in:
		return false
	# Nothing may observe a ready account until every payload has passed validation.
	_clear_player_state()
	_history = _rows_to_history(staged[GameSaveService.HISTORY_FILE_NAME])
	_achievement_tracker.apply_dict(staged[GameSaveService.STATS_FILE_NAME])
	PlayerProfile.apply_dict(staged[GameSaveService.SAVE_FILE_NAME])
	PlayerProfile.apply_display_settings()
	PlayerProfile.set_identity(_identity.display_name, _identity.entity_id, _identity.xbox_user_id)
	if not _attempt_current(generation) or user != xbox_user() or not user.signed_in:
		return false
	_ready_owner = user
	print("[SaveLoad] account ready; resyncing achievement reports")
	_achievement_tracker.resync()
	print("[SaveLoad] warming account services")
	_warm_account_state()
	print("[SaveLoad] account preparation completed")
	return is_current_account(generation)


func _wait_for_session_teardown(generation: int) -> bool:
	if NetManager.is_account_teardown_pending():
		_set_sign_in_stage("Finishing the previous session")
	while NetManager.is_account_teardown_pending():
		if not _attempt_current(generation):
			return false
		await get_tree().process_frame
	return _attempt_current(generation)


func _attempt_current(generation: int) -> bool:
	return generation == _account_generation and not _shutting_down


func account_generation() -> int:
	return _account_generation


func is_account_ready() -> bool:
	return not _shutting_down and _ready_owner != null and _identity != null and _ready_owner == xbox_user() \
		and playfab_user() != null \
		and xbox_user() != null and xbox_user().signed_in \
		and _game_saves.is_bound(_ready_owner, _account_generation)


func is_current_account(generation: int) -> bool:
	return _attempt_current(generation) and is_account_ready()


## XGameSaveFiles releases its provider on suspend; resume must resolve and load again.
func invalidate_saves_for_resume() -> void:
	_account_generation += 1
	_ready_owner = null
	_game_saves.reset()
	_clear_leaderboard_submission()
	account_state_changed.emit()


func _clear_player_state() -> void:
	_clear_leaderboard_submission()
	_history.clear()
	_achievement_tracker.clear()
	PlayerProfile.reset_to_defaults()
	PlayerProfile.set_identity("", "", "")


func cancel_sign_in() -> void:
	_account_generation += 1
	_ready_owner = null
	_save_error = ""
	_game_saves.reset()
	_identity.sign_out()
	_clear_player_state()
	_reset_account_state(false)
	if _chat != null:
		_chat.invalidate_session()
		_chat.set_chat_allowed(false)
		_chat.clear_chat_restrictions()
	if _devices != null:
		_devices.clear()
	account_state_changed.emit()
	account_lost.emit()


## Warms the privilege cache and the privacy lists for the signed-in account, and
## subscribes to the platform's own change notification so a privilege resolved from the
## guide mid-session is picked up. Fire-and-forget: nothing waits on it, and every call
## inside no-ops without a GDK or an XboxUser.
##
## The calls are awaited one at a time rather than issued together. Warming is
## background work with nobody waiting on the result, so it has nothing to gain from
## overlapping, and keeping one platform call in flight at a time keeps it clear of
## whatever the player is actually doing.
func _warm_account_state() -> void:
	if not is_account_ready() or _shutting_down:
		return
	var generation := _account_generation
	_reset_account_state()
	var user: Variant = xbox_user()
	if user == null:
		return
	_connect_user_changed()
	# Re-seeded against the account now that there is one: the platform reports device
	# associations per user, and until this point the Godot joypad list was standing in.
	_devices.start(user)
	await _privileges.check(user, PrivilegeService.MULTIPLAYER)
	if not is_current_account(generation):
		return
	await _privileges.check(user, PrivilegeService.COMMUNICATIONS)
	if not is_current_account(generation):
		return
	await _privacy.refresh_lists(user)


## The acquire-user screen names the platform call currently in progress.
## Empty means no step is in progress.
func _set_sign_in_stage(stage: String) -> void:
	sign_in_stage = stage
	if not stage.is_empty():
		print("[Services] Sign-in: %s." % stage.to_lower())
	sign_in_stage_changed.emit(stage)


func _reset_account_state(notify: bool = true) -> void:
	if _privileges != null:
		_privileges.clear_cache()
	if _privacy != null:
		_privacy.clear_cache()
	# The social graph is started for one account; a group left behind would keep
	# reporting the previous player's friends.
	if _social != null:
		_social.clear()
	# Verified gamertags were proven with the departing account's credentials.
	if _profiles != null:
		_profiles.clear()
	if notify:
		account_state_changed.emit()


func _connect_user_changed() -> void:
	if _user_changed_connected:
		return
	var gdk: Variant = _user_events_gdk()
	if gdk == null or not gdk.is_initialized():
		return
	gdk.users.user_changed.connect(_on_user_changed)
	_user_changed_connected = true


func _user_events_gdk() -> Variant:
	return XboxBootstrap.find_singleton()


## XboxUsers reports `privileges` when the account's privileges change and
## `signed_in_again` when it is re-authenticated; both invalidate everything cached
## about the account. Other change kinds (gamertag, gamer picture) do not.
##
## Removal invalidates synchronously; surviving processes defer teardown/navigation.
func _on_user_changed(user: Variant, change_kind: String) -> void:
	match change_kind:
		"privileges", "signed_in_again":
			_reset_account_state()
		"added":
			# A user re-added after a system-level switch is the account this title is
			# signed in as, so its cached answers are stale rather than absent.
			if _is_signed_in_user(user):
				_reset_account_state()
				_warm_account_state()
		"removed":
			_reset_account_state(false)
			if _is_signed_in_user(user) or _signing_in:
				persist_user_state()


## Whether an XboxUser from a user_changed notification is the one this title signed in
## as. Compared by XUID rather than by object identity: the notification carries the
## platform's own wrapper, which is not required to be the instance sign-in kept.
func _is_signed_in_user(user: Variant) -> bool:
	if user == null or _identity == null or _identity.xbox_user_id.is_empty():
		return false
	return String(user.xuid) == _identity.xbox_user_id


## Invalidates the removed account without attempting another save or SDK operation.
func persist_user_state() -> void:
	# Removal is already too late to begin a write against that user's handle.
	# Normal changes and suspend commit while the binding is still valid.
	cancel_sign_in()


## Commits current data while the account's folder is still usable (XR-001).
##
## Deliberately not persist_user_state(). A suspend does not remove the user — the account
## is still signed in and is the account the title resumes as — so signing out and dropping
## the Game Save folder here would log the player out every time they opened the Guide.
## Only the writes are wanted; the identity has to survive.
##
## Synchronous for the same reason the removed path is, only more sharply: the suspend
## handler runs inside the platform's suspend deadline and the process is frozen the moment
## it returns, so anything left behind an await or a deferred call may never run at all.
func persist_for_suspend() -> bool:
	return _commit_durable_state()


## Whether a sign-in is in flight, and therefore whether a platform call is outstanding
## that the shutdown path has to let land before it stops the frame loop.
func is_signing_in() -> bool:
	return _signing_in


## Whether the title is on its way out. Read by anything that would otherwise react to a
## sign-in result that only resolved because the title is closing.
func is_shutting_down() -> bool:
	return _shutting_down


## Marks the title as on its way out, so the sign-in chain unwinds at its next opportunity
## instead of carrying on into the profile sync and cache warming behind it.
##
## Deliberately does not cancel anything. The call already in flight is left alone to land
## on its own -- taking it away mid-flight is the failure mode this exists to avoid.
func begin_shutdown() -> void:
	_shutting_down = true
	_clear_leaderboard_submission()
	if _signing_in:
		_account_generation += 1
		_game_saves.reset()
	if _identity != null:
		_identity.begin_shutdown()


## Attempt every payload independently; failed writes leave the working copy available for retry.
func _commit_durable_state() -> bool:
	var started_usec := Time.get_ticks_usec()
	var ready := is_account_ready()
	var bound := _game_saves != null and _game_saves.is_bound(_ready_owner, _account_generation)
	print("[SaveCommit] entry ready=%s store_bound=%s" % [ready, bound])
	var profile_ok := _commit_payload("profile", ready, PlayerProfile.save_settings)
	var history_ok := _commit_payload("history", ready, _save_history)
	var stats_ok := _commit_payload("stats", ready, _save_achievement_stats)
	var saved := profile_ok and history_ok and stats_ok
	var result := "success" if saved else "failed_writes"
	if not ready:
		result = "no_ready_account"
	print("[SaveCommit] exit result=%s elapsed_ms=%.3f" % [
		result, (Time.get_ticks_usec() - started_usec) / 1000.0])
	return saved


func _commit_payload(category: String, ready: bool, commit: Callable) -> bool:
	if not ready:
		print("[SaveCommit] payload=%s action=skipped reason=no_ready_account" % category)
		return false
	print("[SaveCommit] payload=%s action=attempt" % category)
	var saved: bool = commit.call()
	print("[SaveCommit] payload=%s result=%s" % [category, "success" if saved else "error"])
	return saved


func is_online() -> bool:
	return _identity != null and _identity.is_signed_in()


# --- Cloud profile ----------------------------------------------------------

func save_profile(data: Dictionary) -> bool:
	return _write_save(GameSaveService.SAVE_FILE_NAME, data)


func _write_save(file_name: String, data: Variant) -> bool:
	var reason := "Sign in and load your saved data before saving."
	if is_account_ready():
		var written := _game_saves.write_now(_ready_owner, _account_generation, file_name, data)
		if written.status == GameSaveService.Status.OK:
			return true
		reason = String(written.reason)
	push_warning("[Services] %s" % reason)
	save_failed.emit(reason)
	return false


# --- Match result -----------------------------------------------------------

## Records a finished match for the ready account, including identified Practice.
func report_match_result(payload: Dictionary) -> bool:
	if not is_account_ready() or _shutting_down:
		push_warning("[Services] Match result rejected: the account is not ready.")
		return false
	var generation := _account_generation
	var online_match := not NetManager.is_offline()
	_append_match_history(payload)
	# Runs on every peer -- the host records its own result here and each client records
	# theirs on the same path -- which is exactly the property the achievement counters
	# need, since a player can only be awarded an achievement by their own console.
	_achievement_tracker.note_match_completed(
		int(payload.get("game_mode_type", -1)),
		int(payload.get("placement", 0)),
		int(payload.get("player_count", 0)),
		int(payload.get("human_count", 0)))
	var history_ok := _save_history()
	var stats_ok := _save_achievement_stats()
	# Practice stays local even when signed in. Queuing/uploading must not hold the
	# results flow, so this standalone coroutine call deliberately ignores its result.
	if is_current_account(generation) and online_match:
		@warning_ignore("return_value_discarded", "missing_await")
		submit_leaderboard_score(int(payload["score"]))
	return history_ok and stats_ok


## The working copy, newest first. Already in memory — loaded from the Game Save folder at
## sign-in — so the Match History screen needs no read here.
func get_match_history() -> Array[Dictionary]:
	if not is_account_ready():
		return []
	return _history.duplicate(true)


# --- Leaderboards -----------------------------------------------------------

## The live top ten, with status kept separate from an empty board. No cached history
## is substituted when PlayFab cannot answer.
func get_leaderboard() -> Dictionary:
	if not is_account_ready():
		return LeaderboardService.failure(
			"The account is not ready.", "Sign in and load your saved data to view leaderboards.")
	if _leaderboards == null:
		return LeaderboardService.failure(
			"Leaderboard service is unavailable.", "Leaderboards are unavailable right now.")
	var user: Variant = playfab_user()
	var generation := _account_generation
	if user != null and _connectivity != null and not _connectivity.is_online():
		return LeaderboardService.failure(
			_connectivity.offline_reason(), "Connect to the internet to view leaderboards.")

	var result: Dictionary = await _leaderboards.get_top_entries(user)
	# Sign-out during the query would otherwise show another account's board.
	if not is_current_account(generation) or user != playfab_user():
		return LeaderboardService.failure(
			"The PlayFab session changed during the query.", "Sign-in changed - reopen leaderboards.")
	return result


## Gameplay starts this without awaiting; a caller investigating the result can await
## its own outcome without consulting mutable last-error state.
func submit_leaderboard_score(score: int) -> Dictionary:
	if not is_account_ready():
		return LeaderboardService.score_failure("Sign in and load your saved data before submitting a score.")
	var user: Variant = playfab_user()
	var generation := _account_generation
	_leaderboard_submission_serial += 1
	var serial := _leaderboard_submission_serial
	_leaderboard_submission_user = user
	_leaderboard_submission = {
		"ok": false,
		"pending": true,
		"attempted": false,
		"skipped": false,
		"message": "Score %d pending: queued, checking published best, or uploading." % score,
	}
	leaderboard_submission_changed.emit()

	var result: Dictionary = await _submit_leaderboard_score(user, generation, score)
	if not is_current_account(generation) or user != playfab_user():
		return LeaderboardService.score_failure("Sign-in changed during leaderboard submission.")
	if serial == _leaderboard_submission_serial:
		_leaderboard_submission = result
		leaderboard_submission_changed.emit()
	return result


func _submit_leaderboard_score(user: Variant, generation: int, score: int) -> Dictionary:
	if _leaderboards == null:
		return LeaderboardService.score_failure("Leaderboard service is unavailable.")
	if user == null:
		return LeaderboardService.score_failure("Sign in to submit a score.")
	if not is_current_account(generation) or user != playfab_user():
		return LeaderboardService.score_failure("The account is no longer ready; no new submission was started.")
	if _connectivity != null and not _connectivity.is_online():
		return LeaderboardService.score_failure(_connectivity.offline_reason())
	var account_current := func() -> bool:
		return is_current_account(generation) and user == playfab_user()
	return await _leaderboards.submit_score(user, score, account_current)


## An accepted update, skipped update and observed readback are different outcomes.
func get_leaderboard_submission() -> Dictionary:
	if not is_account_ready() or _leaderboard_submission_user != playfab_user():
		return {}
	return _leaderboard_submission.duplicate()


func _clear_leaderboard_submission() -> void:
	_leaderboard_submission_serial += 1
	_leaderboard_submission_user = null
	_leaderboard_submission.clear()
	if _leaderboards != null:
		_leaderboards.invalidate_pending_submissions()
	leaderboard_submission_changed.emit()


# --- Matchmaking ------------------------------------------------------------

## PlayFab Matchmaking (Quick Match). Present but switched off until the matchmaking flow
## is complete: MatchmakingService reports it unavailable, and NetManager.start_matchmaking()
## and staging-lobby joins both refuse while it does. See scripts/services/matchmaking_service.gd.
func matchmaking() -> MatchmakingService:
	return _matchmaking


## Whether a Quick Match row should offer to run. False on this build.
func quick_match_available() -> bool:
	return _matchmaking != null and _matchmaking.is_available()


## Why Quick Match cannot run, in words fit to show a player. Empty when it can.
func quick_match_unavailable_reason() -> String:
	if _matchmaking == null:
		return "Matchmaking is unavailable in this build."
	return _matchmaking.availability_reason()


# --- Time ---------------------------------------------------------------------

## The shared online clock. See OnlineFlowClock.
func clock() -> OnlineFlowClock:
	return _clock


## Replaces the shared clock and hands it to whichever Party and matchmaking services are
## installed now. Only the harness does this, before any online work starts; a service
## refuses a replacement while its own work is live, so an operation never changes clocks
## half-way through.
func use_clock(clock: OnlineFlowClock) -> void:
	if clock == null:
		return
	_clock = clock
	if _party != null:
		_party.configure_clock(clock)
	if _matchmaking != null:
		_matchmaking.configure_clock(clock)


# --- Achievements -----------------------------------------------------------

## The local player's lifetime progress. Gameplay reports what the local player did
## through this; nothing else may write to it, and nothing outside this file talks to the
## GDK about achievements.
func achievement_tracker() -> AchievementTracker:
	return _achievement_tracker if is_account_ready() and not _shutting_down else null


func unlock_achievement(achievement_id: String) -> void:
	if not is_account_ready() or _shutting_down:
		return
	_achievements.unlock(_identity.gdk_user, achievement_id)


## Only progress owned by the ready account may reach the achievement service.
func _on_achievement_progress(achievement_id: String, percent: int) -> void:
	if not is_account_ready() or _shutting_down:
		return
	_achievements.update_progress(_identity.gdk_user, achievement_id, percent)


## Subscribes to the two match-wide facts the tracker cannot see for itself. Everything
## else it counts is reported by the world, which is the only thing that knows which ship
## belongs to the local player.
##
## Deferred out of _ready() because NetManager autoloads after this service.
func _connect_match_signals() -> void:
	if NetManager == null:
		return
	if not NetManager.score_updated_received.is_connected(_on_score_updated_for_achievements):
		NetManager.score_updated_received.connect(_on_score_updated_for_achievements)
	if not NetManager.match_state_changed.is_connected(_on_match_state_for_achievements):
		NetManager.match_state_changed.connect(_on_match_state_for_achievements)


## A kill is the only thing that awards a point, and the award is broadcast to every peer
## with the peer it belongs to — which makes this the one place a client can learn it got
## a kill. Deaths cost a point instead, but only when nobody else caused them, so they are
## counted from the local ship's destruction rather than from here.
func _on_score_updated_for_achievements(payload: Dictionary) -> void:
	if not is_account_ready() or _shutting_down:
		return
	if int(payload.get("delta", 0)) <= 0:
		return
	if int(payload.get("peer_id", 0)) != NetManager.local_peer_id():
		return
	_achievement_tracker.note_kill()


func _on_match_state_for_achievements(state: NRTypes.MatchState) -> void:
	if not is_account_ready() or _shutting_down:
		return
	if NRTypes.has_match_state(state, NRTypes.MatchState.RUNNING):
		_achievement_tracker.begin_match()


# --- Presence ---------------------------------------------------------------

func update_presence(status: String) -> void:
	if not is_account_ready():
		return
	_activity.set_presence(_identity.gdk_user, status)


# --- Account-owned history and counters --------------------------------------

func _append_match_history(payload: Dictionary) -> void:
	_history.push_front({
		"date": Time.get_datetime_string_from_system(false, true),
		"game_mode": String(payload.get("game_mode", "")),
		"score": int(payload.get("score", 0)),
		"placement": int(payload.get("placement", 0)),
		"player_count": int(payload.get("player_count", 0)),
	})
	if _history.size() > MATCH_HISTORY_LIMIT:
		_history.resize(MATCH_HISTORY_LIMIT)


## Rows have already passed current-schema validation.
func _rows_to_history(rows: Array) -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	for item in rows:
		var row: Dictionary = item
		entries.append({
			"date": String(row.get("date", "")),
			"game_mode": String(row.get("game_mode", "")),
			"score": int(row.get("score", 0)),
			"placement": int(row.get("placement", 0)),
			"player_count": int(row.get("player_count", 0)),
		})
		if entries.size() == MATCH_HISTORY_LIMIT:
			break
	return entries


func _save_history() -> bool:
	return _write_save(GameSaveService.HISTORY_FILE_NAME, _history)


func _save_achievement_stats() -> bool:
	return _write_save(GameSaveService.STATS_FILE_NAME, _achievement_tracker.to_dict())
