extends Node

## Application entry point.
##
## Responsibilities are deliberately thin: hand the screen container to ScreenManager,
## start the music, and show the first screen. Sign-in is owned by the acquire-user
## screen rather than fired off here, so the GDK account picker never has to compete
## with a live main menu for the foreground.

@onready var _screen_container: CanvasLayer = $ScreenContainer
@onready var _world_container: Node2D = $WorldContainer
@onready var _background_container: CanvasLayer = $BackgroundContainer
@onready var _controller_overlay: ControllerDisconnectOverlay = $ControllerDisconnectOverlay

## How long a close request will wait for in-flight platform calls before giving up and
## exiting anyway. Long enough for a sign-in step that is merely slow, short enough that a
## step which is never going to finish does not read as the hang this replaced.
##
## This is the budget for the whole shutdown, not for each thing waited on within it. The
## player is not waiting for a stage, they are waiting for the window to go away.
const SHUTDOWN_DRAIN_SECONDS := 8.0

## Set by the suspend handler when a session was dropped, read by the resume handler to
## decide whether the player is owed an explanation. Survives the suspend because the
## process is frozen rather than restarted -- and if the platform terminates instead of
## resuming, there is no resume to read it.
var _match_dropped_by_suspend := false
## True while the platform has the title constrained (the Guide is up, or on desktop the
## window is not focused).
var _constrained := false
## Set when a close request arrives while a platform call is still in flight, and the
## quit is deferred until it lands. See request_shutdown().
var _quit_pending := false
## When the deferred quit stops being deferred, whether the call landed or not.
var _quit_deadline_msec := 0
var _account_route_pending := false
var _save_failure_pending := ""
var _save_dialog_open := false
## Normal quit stays cancellable until the current account's final save succeeds.
## This is separate from the forced, deadline-bound platform drain.
var _shutdown_save_pending := false
var _resume_generation := -1


func _ready() -> void:
	ScreenManager.set_container(_screen_container)
	ScreenManager.set_world_containers(_world_container, _background_container)
	PlayerProfile.apply_display_settings()

	get_tree().set_auto_accept_quit(false)
	# Screens reach the shutdown sequence through this group rather than a direct
	# reference, so an in-menu Quit and a window close take the same path.
	add_to_group(&"app_root")

	AudioManager.play_music()

	# The controller prompt is owned here rather than by a screen: a pad can die during
	# any of them, and the overlay has to outlive whichever one is on top (XR-115).
	#
	# Only transitions are acted on -- there is deliberately no "no pad at boot" check.
	# A keyboard-only desktop machine has never had a controller and never loses one, and
	# raising the prompt there would put an undismissable panel over every dev session.
	# A console user who has no controller assigned is XR-112's picker, not this.
	if Services != null:
		_connect_lifecycle_signals()
		var devices := Services.devices()
		devices.controller_lost.connect(_on_controller_lost)
		devices.controller_bound.connect(_on_controller_bound)

	# Authentication and account-owned saved data must both be ready before the menu.
	ScreenManager.push(ScreenManager.ACQUIRE_USER)


func _connect_lifecycle_signals() -> void:
	Services.account_lost.connect(_on_account_lost)
	Services.save_failed.connect(_on_save_failed)
	ScreenManager.screen_pushed.connect(_on_resume_screen_pushed)


func _reset_account_dialogs() -> void:
	_shutdown_save_pending = false
	_save_failure_pending = ""
	_save_dialog_open = false


func _on_account_lost() -> void:
	_reset_account_dialogs()
	_resume_generation = -1
	_match_dropped_by_suspend = false
	# Stop the departing simulation and input immediately, without starting SDK work
	# or awaiting UI inside a deadline-bound user-removal callback.
	for container: Node in [_world_container, _screen_container]:
		for child in container.get_children():
			child.process_mode = Node.PROCESS_MODE_DISABLED
			if child is CanvasItem:
				child.hide()
	AudioManager.stop_all()
	if not _account_route_pending:
		_account_route_pending = true
		_route_after_account_loss.call_deferred()


func _route_after_account_loss() -> void:
	_account_route_pending = false
	if Services.is_shutting_down():
		return
	_match_dropped_by_suspend = false
	ScreenManager.replace_all(ScreenManager.ACQUIRE_USER)
	AudioManager.play_music()


## Save callers keep current data on failure. Only this deferred normal-interaction
## handler presents UI; deadline-bound suspend and removal never wait for a dialog.
func _on_save_failed(reason: String) -> void:
	if Services.is_shutting_down() or not Services.is_account_ready():
		return
	if _save_failure_pending.is_empty():
		_save_failure_pending = reason
	elif not _save_failure_pending.contains(reason):
		_save_failure_pending += "\n" + reason
	if _shutdown_save_pending:
		return
	_show_save_failure.call_deferred(Services.account_generation())


func _show_save_failure(generation: int) -> void:
	if _shutdown_save_pending or _save_dialog_open or _save_failure_pending.is_empty():
		return
	if Services.is_shutting_down() or not Services.is_current_account(generation):
		return
	_save_dialog_open = true
	var reason := _save_failure_pending
	_save_failure_pending = ""
	await ScreenManager.show_dialog(
		"Could Not Save",
		"%s\n\nYour changes have not been saved. Try saving again before leaving this account." % reason,
		"error", false)
	if not Services.is_current_account(generation):
		return
	_save_dialog_open = false
	if not _save_failure_pending.is_empty():
		_show_save_failure.call_deferred(generation)


## The player's controller went away (XR-115). Nothing is paused and nothing is torn
## down: a networked match cannot stop because one player unplugged something, so the
## simulation runs on underneath and their ship simply stops taking input.
func _on_controller_lost() -> void:
	_controller_overlay.show_prompt()


func _on_controller_bound() -> void:
	_controller_overlay.hide_prompt()


## Process lifecycle, alongside the window close request (XR-001).
##
## The Xbox engine must deliver APPLICATION_PAUSED before acknowledging suspend.
## Delivery and acknowledgment timing need verification on the deployed engine.
## Focus loss alone only constrains the title; it is not a persistence trigger.
func _notification(what: int) -> void:
	match what:
		NOTIFICATION_WM_CLOSE_REQUEST:
			request_shutdown()
		NOTIFICATION_APPLICATION_PAUSED:
			_on_suspending()
		NOTIFICATION_APPLICATION_RESUMED:
			_on_resumed()
		NOTIFICATION_APPLICATION_FOCUS_OUT:
			_set_constrained(true)
		NOTIFICATION_APPLICATION_FOCUS_IN:
			_set_constrained(false)


## The suspend handler. Everything it does, it does now.
##
## Persistence cannot depend on another frame or on resume: the process may terminate
## after this handler returns. Measure the synchronous work rather than assume a budget.
func _on_suspending() -> void:
	var started_usec := Time.get_ticks_usec()
	print("[Lifecycle] Suspend entry")
	# First, because it is the only part that must survive a terminate-without-resume.
	var saved := false
	if Services != null:
		saved = Services.persist_for_suspend()
	# Then drop the session. Holding an open Party network and a bound MultiplayerPeer
	# across a suspend leaves a peer that never reconnects and an RPC storm against a
	# dead network; the match is not worth either.
	_match_dropped_by_suspend = NetManager.abandon_for_suspend()
	AudioManager.stop_all()
	print("[Lifecycle] Suspend exit save_completed=%s match_abandoned=%s elapsed_ms=%.3f" % [
		saved, _match_dropped_by_suspend, (Time.get_ticks_usec() - started_usec) / 1000.0])


## The resume handler. Unlike suspend this is not deadline-bound, so it may defer -- and
## it has to, because telling the player what happened means a dialog, and a dialog means
## awaiting them.
func _on_resumed() -> void:
	print("[Lifecycle] Resumed.")
	if Services.is_shutting_down():
		return
	Services.invalidate_saves_for_resume()
	InviteRouter.invalidate_for_resume()
	_reset_account_dialogs()
	_resume_generation = Services.account_generation()
	NetManager.finish_suspend_teardown()
	# Restarted rather than merely unmuted: the streams were playing into a device the
	# platform took away, so they are started again from a known state.
	AudioManager.play_music()
	_route_after_suspend.call_deferred(_resume_generation)
	# The constrain state is deliberately left alone. A resume arrives while the title is
	# still constrained -- the Guide is what suspended it and is still up -- so the
	# unconstrain notification is what ends the pause, not this.


## Puts the player back somewhere that makes sense after a suspend took their match away.
func _route_after_suspend(generation: int) -> void:
	if Services.is_shutting_down() or _account_route_pending or generation != Services.account_generation():
		return
	if not Services.is_account_ready():
		ScreenManager.replace_all(ScreenManager.ACQUIRE_USER)
		return
	ScreenManager.replace_all(ScreenManager.MAIN_MENU)


func _on_resume_screen_pushed(screen: NRScreen) -> void:
	if _resume_generation < 0 or screen.scene_file_path != ScreenManager.MAIN_MENU:
		return
	var generation := _resume_generation
	_resume_generation = -1
	var match_dropped := _match_dropped_by_suspend
	_match_dropped_by_suspend = false
	if match_dropped:
		_show_resume_notice.call_deferred(screen, generation)


func _show_resume_notice(screen: NRScreen, generation: int) -> void:
	if not Services.is_current_account(generation) or not is_instance_valid(screen) \
			or ScreenManager.current_screen() != screen:
		return
	# An invite accepted while the title was suspended is why the player came back. It
	# redeems off the screen change above, and it is a better answer to "what now" than a
	# dialog about a match they have already moved on from, so it gets the front end.
	if InviteRouter.has_pending_invite():
		return
	await ScreenManager.show_dialog(
		"Match Ended",
		"The match was left when the game was suspended.",
		"default",
		false,
	)


## Constrain and unconstrain. The match keeps its phase and its place in the roster; it
## simply stops advancing, so nothing here is broadcast to the other peers and nothing
## here is written to PlayerProfile -- opening the Guide is not a settings change.
func _set_constrained(constrained: bool) -> void:
	if _constrained == constrained:
		return
	_constrained = constrained
	AudioManager.set_system_muted(constrained)
	# Reached through the group for the same reason the shutdown path is: there is at most
	# one director, it exists only while a match does, and main.gd should not have to know
	# which screen is currently holding it.
	get_tree().call_group(&"match_director", &"set_externally_paused", constrained)


## Read by a MatchDirector built while the title is already constrained, whose own
## constrain notification fired before it existed.
func is_constrained() -> bool:
	return _constrained


## The single shutdown path. Reached both by the window close request and by the
## Quit menu item on platforms that offer one, so settings are always persisted and
## the match is always left cleanly before the process goes away.
##
## Quitting while a platform call is still in flight is what hung the title on the way out
## (#16). Both addons pump their async completions once per process frame, so stopping the
## frame loop is what strands a call that has not landed yet -- and the runtime then tears
## down waiting on a completion that can no longer arrive. Cancelling it is one answer;
## this is the other, and the one that does not depend on the call being cancellable: keep
## the frames coming until it lands, and quit on the far side of it.
func request_shutdown() -> void:
	# Repeated close requests cannot accept a failed save on the player's behalf.
	if _shutdown_save_pending:
		return
	# Asked twice. The player is done waiting, and a close button that ignores the second
	# press is the same bug wearing a different hat.
	if _quit_pending:
		_quit_immediately()
		return

	if Services != null and Services.is_account_ready():
		var generation := Services.account_generation()
		_shutdown_save_pending = true
		while not Services.persist_for_suspend():
			var reason := _save_failure_pending
			_save_failure_pending = ""
			var retry := await ScreenManager.show_dialog(
				"Could Not Save",
				"%s\n\nYour changes have not been saved. Retry saving before quitting, or go back to the game." % reason,
				"error", true, "Retry", "Back")
			# Account removal also releases the guard. A stale dialog must not quit a
			# replacement account or release that account's own pending quit.
			if not Services.is_current_account(generation):
				return
			if not retry:
				_shutdown_save_pending = false
				return
		_shutdown_save_pending = false
		_save_failure_pending = ""
	if Services != null:
		Services.begin_shutdown()
	if Services != null and Services.is_signing_in():
		# Unwinds the sign-in chain at its next opportunity rather than letting it run on
		# into the post-sign-in work, so the wait is only as long as the call already in
		# flight and not the whole pipeline behind it.
		_arm_drain_deadline()
		if not Services.sign_in_completed.is_connected(_on_shutdown_drain_finished):
			Services.sign_in_completed.connect(_on_shutdown_drain_finished, CONNECT_ONE_SHOT)
		# Nothing is put on screen for the wait. The sign-in screen is already up and
		# already spinning, which reads as "working" rather than "hung", and a closing
		# notice on top of it would only be there long enough to flicker.
		return

	_quit_now()


## The in-flight call landed, so there is nothing left to strand.
func _on_shutdown_drain_finished(_success: bool) -> void:
	if _quit_pending:
		_quit_now()


## Watches the deferred quit's deadline. A call that never lands must not turn a deferred
## quit into a permanent one -- waiting forever is the hang, just with better manners.
func _process(_delta: float) -> void:
	if not _quit_pending:
		return
	if Time.get_ticks_msec() >= _quit_deadline_msec:
		print("[Lifecycle] Shutdown drain timed out after %.1fs; exiting anyway." % SHUTDOWN_DRAIN_SECONDS)
		_quit_immediately()


## Defers the quit and starts the clock on it, if the clock is not already running.
##
## Called once per thing that has to be waited for -- the sign-in chain unwinding, then the
## Party teardown that leaving a match starts. Those happen one after the other, and an
## earlier version gave each its own full drain on that basis. That measured the wrong
## thing: waiting the whole budget twice made a close request take twice as long as the
## constant says it can, which is the ~15s exit of #40. A later caller therefore joins the
## deadline already running instead of pushing it back, so the budget is spent across the
## shutdown rather than renewed by each stage of it.
func _arm_drain_deadline() -> void:
	if _quit_pending:
		return
	_quit_pending = true
	_quit_deadline_msec = Time.get_ticks_msec() + int(SHUTDOWN_DRAIN_SECONDS * 1000.0)


## The orderly exit: silence the audio, leave the match, then stop the frame loop.
##
## Leaving a match is asynchronous -- clearing the advertised descriptor, leaving the lobby
## and leaving the Party network are three round trips through the service -- so it is
## awaited here rather than started and walked away from. The ordinary leave_match() does
## walk away from it, deliberately; this is the one caller that must not, because the next
## statement stops the frame loop. Both addons pump their async completions once per
## process frame, so quitting the moment the teardown starts strands it, and the runtime
## then tears down waiting on a completion that can no longer arrive. That is the hang of
## #16 reached from the match path rather than the sign-in one, and it is why the drain
## covers both.
##
## The chat control is destroyed here rather than by the leave, because it is per-user and
## deliberately outlives the match -- so quitting from the menu still has one to clean up
## even though there is no session. It goes inside the same drain: the whole point of
## bounding it is that an exit must not be able to hang on it.
func _quit_now() -> void:
	AudioManager.stop_all()
	if NetManager.is_account_teardown_pending():
		_arm_drain_deadline()
		NetManager.finish_suspend_teardown()
		while NetManager.is_account_teardown_pending():
			await get_tree().process_frame
			if not _quit_pending:
				return
	if NetManager.has_session():
		_arm_drain_deadline()
		await NetManager.leave_match_and_wait()
		# The deadline may have run out while the teardown was still going, in which case
		# the frame loop is already stopping and there is nothing left to do here.
		if not _quit_pending:
			return
	else:
		NetManager.leave_match()
	_arm_drain_deadline()
	await NetManager.retire_activity_and_wait()
	if not _quit_pending:
		return
	var chat := Services.chat() if Services != null else null
	if chat != null and chat.has_control():
		_arm_drain_deadline()
		await chat.destroy_control()
		if not _quit_pending:
			return
	_quit_immediately()


## Stops the frame loop, which is the act that makes any still-pending platform call unable
## to finish. Only reached once there is nothing left worth waiting for, or once the drain
## deadline has judged that waiting longer is worse than stranding the call.
func _quit_immediately() -> void:
	_quit_pending = false
	get_tree().quit()
