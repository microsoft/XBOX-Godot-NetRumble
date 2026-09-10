extends Node

## Facade over the Microsoft GDK and PlayFab addons for the rest of the game.
##
## Covers achievements, cloud saves, presence, voice chat and Party
## networking. The implementation is split across scripts/services/*; this file stays
## a thin, well-documented facade that the UI and gameplay code call.
##
## Two tiers, deliberately different. Multiplayer is NOT optional-online: PlayFab Party
## is the transport and PlayFab Lobby is the matchmaking, both of which need a signed-in
## PlayFabUser, so hosting and joining are gated on sign_in() succeeding (see
## PartyService and NetManager). Everything else here — achievements,
## cloud saves, presence — is best-effort and degrades to a working no-op / empty result
## when an extension is missing or a call fails, so the single-player practice match and
## the whole front end still run on an unconfigured dev machine. Those failures are
## logged with push_warning (never push_error) to keep the console readable.

signal sign_in_completed(success: bool)
signal account_state_changed()
## The step sign-in is currently on, in words fit to show the player. Forwarded from
## IdentityService and extended with the steps this facade owns, so the acquire-user
## screen can name the call it is waiting on.
signal sign_in_stage_changed(stage: String)

## Match history, newest first. Held in memory as the working copy and persisted to the
## PlayFab Game Save synced folder (`history.json`), which is the record: it follows the
## account across devices and is the only per-user protected store the console has.
##
## On desktop, where there is no synced folder, it is cached at MATCH_HISTORY_PATH so the
## Match History screen still works between runs. That file carried an owner XUID to keep
## one console user from reading another's rows; both the stamp and the console-side file
## are gone, because on console nothing is written outside the Game Save folder now and
## there is nothing left to scope. See `IdentityService.has_protected_storage()`.
const MATCH_HISTORY_PATH := "user://match_history.json"
const MATCH_HISTORY_LIMIT := 50
## Desktop cache of the lifetime achievement counters, the counterpart of
## MATCH_HISTORY_PATH and namespaced the same way. On console nothing is written here;
## the Game Save folder is the only copy.
const ACHIEVEMENT_STATS_PATH := "user://achievement_stats.json"
## Wrapper key used by files written before the store moved. Read, never written: the
## desktop cache is a bare JSON array now, and this only keeps an existing dev file from
## reading as empty.
const HISTORY_ENTRIES_KEY := "entries"

## Resolves the GDK singleton the same way the services below do, so the privilege
## cache can be invalidated from XboxUsers.user_changed.
const XboxBootstrap := preload("res://addons/godot_gdk/runtime/gdk_bootstrap.gd")

var _identity: IdentityService = null
var _achievements: AchievementService = null
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

## The working copy of the match history, newest first. Loaded from the Game Save folder
## at sign-in (or the desktop cache at boot) and written back on every append, so the
## suspend and user-removed paths can persist it synchronously without a file read.
var _history: Array[Dictionary] = []

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
	_achievements = AchievementService.new()
	_achievement_tracker = AchievementTracker.new()
	_achievement_tracker.progress_changed.connect(_on_achievement_progress)
	_game_saves = GameSaveService.new()
	# Chat is built first because PartyService drives its lifetime: a chat control only
	# exists alongside a Party network.
	_chat = ChatService.new()
	_party = PartyService.new(_chat)
	_activity = ActivityService.new()
	_privileges = PrivilegeService.new()
	_privacy = PrivacyService.new()
	_moderation = ModerationService.new()
	_social = SocialService.new()
	_profiles = ProfileService.new()
	_devices = DeviceService.new()
	# Started before sign-in, and with no user, so that a player who chose "Continue
	# Offline" is covered too: their pad dying mid-practice is the same problem. The
	# account-scoped restart happens in _warm_account_state() once there is a user.
	_devices.start(null)
	# Not account-scoped: connectivity is a property of the console, so this is started
	# once here and never restarted for a user. It reads the platform's hint, so it costs
	# nothing on a machine that cannot answer and stays optimistic there.
	_connectivity = ConnectivityService.new()
	_connectivity.start()
	# Desktop only: on console this returns nothing and the history arrives from the Game
	# Save folder once sign-in resolves.
	_history = _load_local_history()
	_achievement_tracker.apply_dict(_load_local_stats())
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
	if _social == null or _activity == null:
		return joinable
	var user: Variant = xbox_user()
	if user == null:
		return joinable

	var friends: Array[Dictionary] = await _social.friends(user)
	if friends.is_empty():
		return joinable

	var xuids := PackedStringArray()
	for friend in friends:
		xuids.append(String(friend.get("xuid", "")))

	var activities: Dictionary = await _activity.joinable_activities(user, xuids)
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
	if _activity == null:
		return ""
	return await _activity.connection_string_for_xuid(xbox_user(), xuid)


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
	if _connectivity != null and not _connectivity.is_online():
		return _connectivity.offline_reason()
	var verdict: Dictionary = await can_play_multiplayer()
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


## The raw --pf-user / PF_CUSTOM_ID token, or empty. Safe to call before _ready().
func custom_id_token() -> String:
	return IdentityService.resolve_custom_id_token()


## GDK (check -> silent -> UI) then PlayFab sign-in. Idempotent and safe to await from
## several callers at once. Returns false — without erroring — when it cannot complete;
## read sign_in_error() for the reason.
func sign_in() -> bool:
	if _identity.is_signed_in():
		return true

	if _signing_in:
		while _signing_in:
			await get_tree().process_frame
		return _identity.is_signed_in()

	_signing_in = true
	_set_sign_in_stage("Starting")
	var success: bool = await _identity.sign_in()
	_signing_in = false

	# The title started closing while that was in flight. It has landed, which is all the
	# shutdown path was waiting for, so stop here rather than running the rest of the
	# chain into a runtime that is on its way out.
	if _shutting_down:
		_set_sign_in_stage("")
		sign_in_completed.emit(false)
		return false

	# IdentityService loads the GDK extension and initializes the runtime on its way
	# through, so this is the first moment a singleton that was absent at boot is
	# guaranteed to have had its chance. That absence is ActivityService's one
	# unrecoverable subscription failure — it has no signal to wait on — so the retry
	# has to be driven from outside. Runs on failure too: sign-in can fail at the
	# PlayFab half long after the GDK came up.
	if _activity != null:
		_activity.ensure_activation_subscribed()

	if success:
		PlayerProfile.set_identity(_identity.display_name, _identity.entity_id, _identity.xbox_user_id)
		# Clear whatever the previous session left in memory before the cloud payload
		# lands over the top; on desktop this also re-reads the settings file.
		PlayerProfile.adopt_local_cache()
		# Pull the cloud profile so settings follow the player across devices. Best-effort:
		# stays empty when Game Saves is unavailable, leaving local settings untouched.
		_set_sign_in_stage("Syncing your saved profile")
		var cloud: Dictionary = await _game_saves.load(_identity.playfab_user)
		if not cloud.is_empty():
			PlayerProfile.apply_dict(cloud)
		# History comes from the same folder, and on console that folder is the only place
		# it was ever written. Kept behind an is_empty() guard so a desktop session where
		# Game Saves is unavailable keeps the cache it loaded at boot rather than being
		# emptied by a read that never reached a folder.
		var cloud_history: Array = await _game_saves.load_history(_identity.playfab_user)
		if not cloud_history.is_empty():
			_history = _rows_to_history(cloud_history)
			_save_local_history()
		# Achievement counters come from that folder too, but are merged rather than
		# replaced: the local copy may be ahead after a session played offline, the cloud
		# copy may be ahead after a session played on another console, and per counter the
		# higher of the two is the one that was actually earned.
		var cloud_stats: Dictionary = await _game_saves.load_stats(_identity.playfab_user)
		if not cloud_stats.is_empty():
			_achievement_tracker.merge_dict(cloud_stats)
		# Nothing earned before this point reached the service -- there was no identity to
		# award it to -- so the whole set is re-reported now that there is one.
		_achievement_tracker.resync()
		_save_achievement_stats()
		# Privileges and the privacy lists belong to the account that just signed in, so
		# anything cached for a previous one is dropped and the new answers are warmed.
		# Host/join and the chat config re-check at the point of use; this only makes
		# that check instant. It runs *after* the sign-in chain rather than alongside it:
		# Game Saves' add-user performs the initial cloud sync behind system UI, and
		# platform calls left in flight across it are one way to stall that sync.
		_warm_account_state()

	_set_sign_in_stage("")
	print("[Services] Sign-in: finished (success=%s)." % success)
	sign_in_completed.emit(success)
	return success


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
	_reset_account_state()
	var user: Variant = xbox_user()
	if user == null:
		return
	_connect_user_changed()
	# Re-seeded against the account now that there is one: the platform reports device
	# associations per user, and until this point the Godot joypad list was standing in.
	_devices.start(user)
	await _privileges.check(user, PrivilegeService.MULTIPLAYER)
	await _privileges.check(user, PrivilegeService.COMMUNICATIONS)
	await _privacy.refresh_lists(user)


## Sign-in is the one chain that cannot be stepped through on a desktop machine — the
## GDK, PlayFab and Game Saves halves only do anything on a console with a real identity
## — so it says what it is doing. The acquire-user screen shows this under the spinner,
## which turns a stalled platform call into a named one without a debugger attached.
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
	var gdk: Variant = XboxBootstrap.find_singleton()
	if gdk == null or not gdk.is_initialized():
		return
	gdk.users.user_changed.connect(_on_user_changed)
	_user_changed_connected = true


## XboxUsers reports `privileges` when the account's privileges change and
## `signed_in_again` when it is re-authenticated; both invalidate everything cached
## about the account. Other change kinds (gamertag, gamer picture) do not.
##
## `added` and `removed` are the XR-115 half. `removed` for the signed-in user is the last
## moment this title is guaranteed to run: the platform terminates a title whose user has
## signed out, so the handler commits state and does nothing else. There is deliberately no
## navigation, no Party teardown and no sign-out deferral — see persist_user_state().
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
			if _is_signed_in_user(user):
				persist_user_state()


## Whether an XboxUser from a user_changed notification is the one this title signed in
## as. Compared by XUID rather than by object identity: the notification carries the
## platform's own wrapper, which is not required to be the instance sign-in kept.
func _is_signed_in_user(user: Variant) -> bool:
	if user == null or _identity == null or _identity.xbox_user_id.is_empty():
		return false
	return String(user.xuid) == _identity.xbox_user_id


## Commits everything belonging to the signed-in user, synchronously.
##
## Called when the platform reports that user removed. Every write here is a plain file
## write with no `await` anywhere in the path, because the process may be torn down as soon
## as this returns and work queued behind an await is work that never runs. No sign-out
## deferral is taken: a deferral exists to buy time for slow teardown, and two file writes
## do not need any. Writing into the Game Save synced folder is the whole cloud story —
## the platform flushes that folder after the title closes.
func persist_user_state() -> void:
	_commit_durable_state()
	_chat.invalidate_session()
	# The identity is gone whether or not any frame renders after this, so nothing is left
	# holding a departed user's gamertag, entity id or local user handle.
	if _identity != null:
		_identity.sign_out()
	if _game_saves != null:
		_game_saves.reset()
	# The device associations were the departing account's.
	if _devices != null:
		_devices.clear()
	# So was the history. It has just been committed to their Game Save folder above, and
	# leaving it in memory would show it to whoever signs in next.
	_history.clear()
	# And so was the achievement progress, for the sharper reason: counters left in place
	# would carry on accumulating under the next account and unlock against it.
	_achievement_tracker.clear()
	PlayerProfile.set_identity("", "", "")
	print("[Services] Signed-in user was removed; state committed.")


## The suspend counterpart of persist_user_state (XR-001): the same durable writes, and
## nothing else.
##
## Deliberately not persist_user_state(). A suspend does not remove the user — the account
## is still signed in and is the account the title resumes as — so signing out and dropping
## the Game Save folder here would log the player out every time they opened the Guide.
## Only the writes are wanted; the identity has to survive.
##
## Synchronous for the same reason the removed path is, only more sharply: the suspend
## handler runs inside the platform's suspend deadline and the process is frozen the moment
## it returns, so anything left behind an await or a deferred call may never run at all.
func persist_for_suspend() -> void:
	_commit_durable_state()


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
	if _identity != null:
		_identity.begin_shutdown()


## The durable writes shared by the user-removed and suspend paths. No await anywhere:
## PlayerProfile.save_settings writes a ConfigFile on desktop and only marks itself clean
## on console, and write_now() writes JSON into the already-resolved synced folder — which
## on console is the only place either of them is written.
func _commit_durable_state() -> void:
	PlayerProfile.save_settings(false)
	if _game_saves != null and _game_saves.has_folder():
		_game_saves.write_now(GameSaveService.SAVE_FILE_NAME, PlayerProfile.to_dict())
		_game_saves.write_now(GameSaveService.HISTORY_FILE_NAME, _history)
		_game_saves.write_now(GameSaveService.STATS_FILE_NAME, _achievement_tracker.to_dict())
		_achievement_tracker.clear_dirty()


func is_online() -> bool:
	return _identity != null and _identity.is_signed_in()


# --- Cloud profile ----------------------------------------------------------

## PlayFab Game Save of the profile JSON. Fire-and-forget: returns immediately and never
## blocks the caller (PlayerProfile.save_settings calls this after every local save).
func save_profile_to_cloud(data: Dictionary) -> void:
	if not is_online():
		return
	_game_saves.save(_identity.playfab_user, data)


func load_profile_from_cloud() -> Dictionary:
	if not is_online():
		return {}
	return await _game_saves.load(_identity.playfab_user)


# --- Match result -----------------------------------------------------------

## Records the finished match by appending to the local, offline-capable match history.
func report_match_result(payload: Dictionary) -> void:
	_append_match_history(payload)
	# Runs on every peer -- the host records its own result here and each client records
	# theirs on the same path -- which is exactly the property the achievement counters
	# need, since a player can only be awarded an achievement by their own console.
	_achievement_tracker.note_match_completed(
		int(payload.get("game_mode_type", -1)),
		int(payload.get("placement", 0)),
		int(payload.get("player_count", 0)),
		int(payload.get("human_count", 0)))
	_save_achievement_stats()


## The working copy, newest first. Already in memory — loaded from the Game Save folder at
## sign-in — so the Match History screen needs no read here.
func get_match_history() -> Array[Dictionary]:
	return _history


# --- Achievements -----------------------------------------------------------

## The local player's lifetime progress. Gameplay reports what the local player did
## through this; nothing else may write to it, and nothing outside this file talks to the
## GDK about achievements.
func achievement_tracker() -> AchievementTracker:
	return _achievement_tracker


func unlock_achievement(achievement_id: String) -> void:
	if not is_online():
		return
	_achievements.unlock(_identity.gdk_user, achievement_id)


## The tracker announces a percentage; this is the only thing that turns one into a
## platform call. Progress earned while signed out is kept locally and delivered by the
## resync at sign-in, so dropping it here costs nothing.
func _on_achievement_progress(achievement_id: String, percent: int) -> void:
	if not is_online():
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
	if int(payload.get("delta", 0)) <= 0:
		return
	if int(payload.get("peer_id", 0)) != NetManager.local_peer_id():
		return
	_achievement_tracker.note_kill()


func _on_match_state_for_achievements(state: NRTypes.MatchState) -> void:
	if NRTypes.has_match_state(state, NRTypes.MatchState.RUNNING):
		_achievement_tracker.begin_match()


# --- Presence ---------------------------------------------------------------

func update_presence(status: String) -> void:
	if not is_online():
		return
	_activity.set_presence(_identity.gdk_user, status)


# --- Match history store ----------------------------------------------------
#
# `_history` is the working copy. The PlayFab Game Save synced folder is the record: it
# follows the account across devices, the platform scopes it to one user and protects it
# at rest, and on console it is the only place the history is written.
#
# Desktop has no synced folder, so it keeps a plaintext cache at MATCH_HISTORY_PATH,
# namespaced per --pf-user token exactly like the settings file so two local instances do
# not overwrite each other. That is the development configuration and holds no console
# account's data.

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
	_save_local_history()
	if is_online():
		_game_saves.save_history(_identity.playfab_user, _history)


## Path of the desktop cache, namespaced per --pf-user token. Mirrors
## PlayerProfile._resolve_settings_path(): without this every local test instance shares
## one history file and each match overwrites the others'.
func _local_history_path() -> String:
	var token := IdentityService.resolve_custom_id_token()
	if token.is_empty():
		return MATCH_HISTORY_PATH
	return "user://match_history_%s.json" % token.validate_filename()


func _load_local_history() -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	if IdentityService.has_protected_storage():
		return entries
	var path := _local_history_path()
	if not FileAccess.file_exists(path):
		return entries
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return entries
	var text := file.get_as_text()
	file.close()

	var parsed: Variant = JSON.parse_string(text)
	# Bare array is what this writes; the wrapper is what older dev files carry.
	if typeof(parsed) == TYPE_ARRAY:
		return _rows_to_history(parsed)
	if typeof(parsed) == TYPE_DICTIONARY:
		var stored: Variant = (parsed as Dictionary).get(HISTORY_ENTRIES_KEY, [])
		if typeof(stored) == TYPE_ARRAY:
			return _rows_to_history(stored)
	return entries


## Shapes raw parsed rows — from the desktop cache or the Game Save folder — into the
## dictionaries the Match History screen expects, dropping anything malformed.
func _rows_to_history(rows: Array) -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	for item in rows:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var row: Dictionary = item
		entries.append({
			"date": String(row.get("date", "")),
			"game_mode": String(row.get("game_mode", "")),
			"score": int(row.get("score", 0)),
			"placement": int(row.get("placement", 0)),
			"player_count": int(row.get("player_count", 0)),
		})
	return entries


func _save_local_history() -> void:
	if IdentityService.has_protected_storage():
		return
	var path := _local_history_path()
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_warning("[Services] Could not write match history at %s" % path)
		return
	file.store_string(JSON.stringify(_history, "\t"))
	file.close()


# --- Achievement stats store ------------------------------------------------
#
# Same two-tier arrangement as the match history, and for the same reasons: the Game Save
# synced folder is the record on console, and desktop keeps a per-token plaintext cache so
# progress survives a restart on a development machine.
#
# Written at the end of a match rather than on every counter change. A busy match moves
# the asteroid counter dozens of times a minute and none of those moments is worth a file
# write; the ones that must not be lost -- suspend and user-removed -- are covered by
# _commit_durable_state(), which writes synchronously whatever the match was doing.

func _save_achievement_stats() -> void:
	if not _achievement_tracker.is_dirty():
		return
	_achievement_tracker.clear_dirty()
	_save_local_stats()
	if is_online():
		_game_saves.save_stats(_identity.playfab_user, _achievement_tracker.to_dict())


## Path of the desktop cache, namespaced per --pf-user token like the history and the
## settings file, so two local instances do not accumulate into each other.
func _local_stats_path() -> String:
	var token := IdentityService.resolve_custom_id_token()
	if token.is_empty():
		return ACHIEVEMENT_STATS_PATH
	return "user://achievement_stats_%s.json" % token.validate_filename()


func _load_local_stats() -> Dictionary:
	if IdentityService.has_protected_storage():
		return {}
	var path := _local_stats_path()
	if not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var text := file.get_as_text()
	file.close()

	var parsed: Variant = JSON.parse_string(text)
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}


func _save_local_stats() -> void:
	if IdentityService.has_protected_storage():
		return
	var path := _local_stats_path()
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_warning("[Services] Could not write achievement stats at %s" % path)
		return
	file.store_string(JSON.stringify(_achievement_tracker.to_dict(), "\t"))
	file.close()
