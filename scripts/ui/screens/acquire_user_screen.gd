extends NRScreen

## Acquire-user screen: the title resolves an Xbox user *before* the front end becomes
## interactive, rather than signing in behind an already-live main menu.
##
## Why it is its own screen. GDK sign-in ends in XUserAddAsync with UI, which raises
## the system account picker; that needs the game in the foreground and needs an answer
## from the player. Running it underneath the main menu meant the picker competed with
## the menu for input and a failure surfaced as nothing more than a "Not signed in"
## label. Here the sign-in owns the screen, and every outcome has an explicit choice.
##
## State below includes one deliberate addition: the screen opens on a "press any key"
## prompt instead of signing in on its own. XUserAddAsync with UI raises the system
## account picker immediately, and a picker that appears unprompted over a title that
## has only just faded in reads as a glitch; requiring a press means the player has
## asked for it. SwitchUser has no equivalent — the main menu re-pushes this screen
## instead, which covers the same ground.

enum State {
	WAITING_FOR_INPUT,## Idle prompt; any key or button starts the sign-in.
	SIGNING_IN,       ## Waiting on Services.sign_in().
	NEEDS_INTERACTION,## Sign-in did not complete; the player picks what happens next.
	READY,            ## Signed in; showing the gamertag before handing over.
}

## How long the resolved gamertag stays on screen before the main menu takes over.
const _READY_DWELL_SECONDS := 0.9

## Shown until the player presses something. The account picker takes over the screen
## the moment sign-in starts, so it is raised by a deliberate press rather than thrown
## at a player who is still watching the title come up.
const _PRESS_PROMPT := "Press any key to continue"

## Shown instead when the title was launched from an invite or a platform join. The
## activation has already been buffered by InviteRouter at this point and is redeemed
## once this screen hands over, so the press the player is being asked for is the one
## that gets them into their friend's match.
const _INVITE_PROMPT := "Press any key to sign in and join your friend's match"

## How long a single sign-in step may run before the screen stops being a dead end and
## offers a way out. Sign-in has no timeout of its own on purpose — one of its steps
## waits on the player in system UI, and cancelling that would be wrong — so this does
## not abandon anything: the attempt keeps running underneath, and if it completes the
## screen carries on as though nothing happened. It exists so that a platform call that
## never returns cannot strand the player on a spinner (XR-074).
const _STALL_SECONDS := 25.0

## Keys that only qualify another key. Treating them as "any key" would start sign-in
## on the way to a shortcut the player was actually typing.
const _MODIFIER_KEYCODES: Array[int] = [
	KEY_SHIFT, KEY_CTRL, KEY_ALT, KEY_META, KEY_CAPSLOCK, KEY_NUMLOCK, KEY_SCROLLLOCK,
]

@onready var _xbox_logo: TextureRect = %XboxLogo
@onready var _netrumble_logo: TextureRect = %NetRumbleLogo
@onready var _spinner: Control = %Spinner
@onready var _status_label: Label = %StatusLabel
@onready var _detail_label: Label = %DetailLabel
@onready var _menu_list: NRMenuList = %MenuList
@onready var _animation_player: AnimationPlayer = %AnimationPlayer

var _state: State = State.WAITING_FOR_INPUT
## When the current sign-in step started, for the stall watchdog. Reset on every step,
## so a slow chain of steps is not mistaken for a stuck one.
var _stage_started_msec := 0
var _stalled := false


func _init() -> void:
	# Sign-in is the gate to everything online, so this screen is never dismissed by
	# Back; the player leaves it through one of its own menu entries.
	allow_back = false


func _ready() -> void:
	super._ready()
	# Both logos sit at the same fixed coordinates the main menu uses, so handing over
	# swaps only the region beneath them. MainMenuScreen::OnEnter does the same thing
	# with a single overlay container: the branding is up from the first frame and
	# never waits on sign-in or on title data.
	_xbox_logo.texture = Assets.texture("Logo_Xbox")
	_netrumble_logo.texture = Assets.texture("Logo_NetRumble")
	# A re-push from the main menu is itself the player choosing "Sign In", so it goes
	# straight to the picker; on first run the title waits for a press instead.
	if ScreenManager.get_stack_size() > 1:
		_acquire_user()
	else:
		_enter_waiting_for_input()


## Re-focus after a dialog (or a re-push from the main menu) uncovers the screen.
func on_revealed() -> void:
	super.on_revealed()
	if _state == State.NEEDS_INTERACTION or (_state == State.SIGNING_IN and _stalled):
		focus_menu_list(_menu_list)


func _unhandled_input(event: InputEvent) -> void:
	super._unhandled_input(event)
	if not is_active or _state != State.WAITING_FOR_INPUT:
		return
	if not _is_any_key_press(event):
		return
	get_viewport().set_input_as_handled()
	AudioManager.play_sound("MenuSelect")
	_acquire_user()


## True for a genuine press on keyboard, gamepad or mouse. Releases and key repeats are
## rejected so the press that dismissed a previous screen cannot also arm this one.
static func _is_any_key_press(event: InputEvent) -> bool:
	if event is InputEventKey:
		var key := event as InputEventKey
		return key.pressed and not key.echo and not _MODIFIER_KEYCODES.has(key.keycode)
	if event is InputEventJoypadButton:
		return (event as InputEventJoypadButton).pressed
	if event is InputEventMouseButton:
		return (event as InputEventMouseButton).pressed
	return false


func _enter_waiting_for_input() -> void:
	_state = State.WAITING_FOR_INPUT
	_stop_waiting_animation()
	# The activation can arrive after this screen is already up, so the prompt follows
	# InviteRouter rather than being decided once.
	if not InviteRouter.pending_invite_changed.is_connected(_on_pending_invite_changed):
		InviteRouter.pending_invite_changed.connect(_on_pending_invite_changed)
	_status_label.text = _INVITE_PROMPT if InviteRouter.has_pending_invite() else _PRESS_PROMPT
	_detail_label.text = ""
	_menu_list.clear_rows()
	_menu_list.visible = false


func _on_pending_invite_changed() -> void:
	if _state != State.WAITING_FOR_INPUT:
		return
	_status_label.text = _INVITE_PROMPT if InviteRouter.has_pending_invite() else _PRESS_PROMPT


## One attempt at the whole GDK -> PlayFab chain. Services.sign_in() is idempotent and
## re-entrancy guarded, so retrying is always safe.
func _acquire_user() -> void:
	_enter_signing_in()
	var success: bool = await Services.sign_in()
	if not is_inside_tree():
		return
	# The title is closing, and this only resolved because the shutdown path waited for it
	# to. Whatever it came back with is not news the player is staying to read, and the
	# quit is already queued for the end of this frame -- so putting "Not signed in" up now
	# would only flash it on the way out.
	if Services.is_shutting_down():
		return
	if success:
		_enter_ready()
	else:
		_enter_needs_interaction(Services.sign_in_error())


func _enter_signing_in() -> void:
	_state = State.SIGNING_IN
	_stalled = false
	_stage_started_msec = Time.get_ticks_msec()
	_status_label.text = "Signing in"
	# Sign-in is a chain of platform calls, several of which take seconds and one of
	# which waits on the player in system UI. Naming the current step is the difference
	# between "it is working" and "it is stuck", and on a console with no debugger
	# attached it is the only diagnosis available.
	_detail_label.text = Services.sign_in_stage
	if not Services.sign_in_stage_changed.is_connected(_on_sign_in_stage_changed):
		Services.sign_in_stage_changed.connect(_on_sign_in_stage_changed)
	_menu_list.clear_rows()
	_menu_list.visible = false
	_spinner.visible = true
	_animation_player.play("spin")


func _on_sign_in_stage_changed(stage: String) -> void:
	if _state != State.SIGNING_IN or stage.is_empty():
		return
	_detail_label.text = stage
	# Progress, so the watchdog starts again rather than counting the whole chain.
	_stage_started_msec = Time.get_ticks_msec()


## Watches for a sign-in step that stops making progress. The attempt is left running —
## it may still complete, and _acquire_user() takes over again if it does — so this only
## adds a way out.
func _process(_delta: float) -> void:
	if _state != State.SIGNING_IN or _stalled:
		return
	# The title is already closing and is only waiting for the call in flight to land.
	# Offering a way out of a wait the player has already ended would put the stall prompt
	# on screen purely to have it taken away again.
	if Services.is_shutting_down():
		return
	if Time.get_ticks_msec() - _stage_started_msec < int(_STALL_SECONDS * 1000.0):
		return
	_stalled = true
	_status_label.text = "Still signing in"
	var stage := _detail_label.text
	_detail_label.text = "%s is taking longer than expected.\nYou can keep waiting, or continue without signing in." % (
		stage if not stage.is_empty() else "Sign-in")
	_menu_list.clear_rows()
	_menu_list.add_button("Try Again", _on_try_again)
	_menu_list.add_button("Continue Offline", _on_continue_offline)
	if not is_console():
		_menu_list.add_button("Quit", _on_quit)
	_menu_list.visible = true
	focus_menu_list(_menu_list)


func _enter_needs_interaction(reason: String) -> void:
	_state = State.NEEDS_INTERACTION
	_stalled = false
	_stop_waiting_animation()
	_status_label.text = "Not signed in"
	_detail_label.text = reason if not reason.is_empty() else "Sign-in did not complete."
	_menu_list.clear_rows()
	_menu_list.add_button("Try Again", _on_try_again)
	_menu_list.add_button("Continue Offline", _on_continue_offline)
	if not is_console():
		_menu_list.add_button("Quit", _on_quit)
	_menu_list.visible = true
	focus_menu_list(_menu_list)


func _enter_ready() -> void:
	_state = State.READY
	_stalled = false
	_stop_waiting_animation()
	_menu_list.clear_rows()
	_menu_list.visible = false
	var suffix := ""
	# Make a --pf-user test client obvious so it is never mistaken for a real Xbox
	# sign-in while debugging a Party session.
	if Services.is_custom_id_session():
		suffix = "  (test user)"
	_status_label.text = "Signed in as %s%s" % [PlayerProfile.display_name, suffix]
	_detail_label.text = ""
	await get_tree().create_timer(_READY_DWELL_SECONDS).timeout
	if is_inside_tree():
		_hand_off()


func _stop_waiting_animation() -> void:
	_animation_player.stop()
	_spinner.visible = false


## Leaves the screen. On first run this screen *is* the stack, so it becomes the main
## menu; when the main menu re-pushed it to sign in later, it simply pops back.
func _hand_off() -> void:
	if ScreenManager.get_stack_size() > 1:
		ScreenManager.pop()
	else:
		ScreenManager.replace_all(ScreenManager.MAIN_MENU)


func _on_try_again() -> void:
	_acquire_user()


## Practice mode needs no identity, so offline is a real choice rather than a dead end.
func _on_continue_offline() -> void:
	# Choosing offline is the player declining the invite that brought them here, not
	# deferring it: an activation kept past this point can only be redeemed by a sign-in
	# much later, which would pull them into a match without them asking again.
	InviteRouter.decline_pending_invite()
	_hand_off()


func _on_quit() -> void:
	var confirmed: bool = await ScreenManager.show_dialog("Quit", "Exit NetRumble?", "warning", true)
	if confirmed:
		quit_game()
