extends NRScreen

## Main menu screen. Layers a starfield, the NetRumble + Xbox logos, the signed-in
## gamertag, and a vertical menu list. Sign-in belongs to the acquire-user screen,
## which runs before this one; this screen only reflects the resulting identity and
## offers a way back to it. Hosting and joining are driven through NetManager.
## Menu entries: Host Match / Join Match / Practice / Match History / Options / Quit,
## with Quit desktop-only — consoles leave the title through the platform. Join Match
## opens a submenu (Join Friend / Lobby Code) in place of the top-level rows.

const _STARFIELD_SCENE := "res://scenes/gameplay/fx/starfield_background.tscn"
const _JOIN_CODE_ENTRY_SCENE := preload("res://scenes/ui/elements/nr_join_code_entry.tscn")
const _FRIEND_LIST_SCENE := preload("res://scenes/ui/elements/nr_friend_list.tscn")

## Position and size for the top-level menu column, and the wider, taller band that
## Options borrows. Options rows carry a label and a spinner value, so they need more
## width than a column of centred captions, and there are enough rows to scroll inside
## the space between the logo and the screen edge.
const _MENU_RECT := Rect2(768.0, 540.0, 384.0, 486.0)
const _OPTIONS_RECT := Rect2(610.0, 490.0, 700.0, 550.0)

## Written by tools/common.ps1 (Write-BuildStamp) on every export, and gitignored, so
## it is absent in a fresh clone and in editor runs that predate an export. Loaded by
## path behind a ResourceLoader.exists() check for that reason — the same treatment
## the starfield gets below — rather than preloaded, which would refuse to parse.
const _BUILD_INFO_SCRIPT := "res://scripts/generated/build_info.gd"

@onready var _background: Control = %Background
@onready var _xbox_logo: TextureRect = %XboxLogo
@onready var _netrumble_logo: TextureRect = %NetRumbleLogo
@onready var _gamertag_label: Label = %GamertagLabel
@onready var _menu_scroll: ScrollContainer = %MenuScroll
@onready var _menu_list: NRMenuList = %MenuList
@onready var _build_label: Label = %BuildLabel

## Whether the menu currently carries the "Sign In" row, so it can be rebuilt only
## when the identity state actually crosses that boundary.
var _sign_in_row_shown := false

## Which list is showing. The join submenu replaces the top-level menu rows in place,
## landing in exactly the same screen region. Options is handled the same way rather
## than as a pushed screen, so the player sees the rows change rather than a new screen
## sliding in.
var _in_join_menu := false
var _in_options := false

## The two rows that need a connection, and the note that says why they are dark. Held so
## connectivity can be applied in place rather than by rebuilding: a rebuild would drop
## the player's focus back to the top of the list every time the hint flickered, and on a
## controller that is far more disruptive than the two rows going grey.
var _host_row: NRButton = null
var _join_row: NRButton = null
## Always present while the top-level menu is up, empty when there is nothing to say, so
## that connectivity changing never shifts the rows around it.
var _connectivity_note: Label = null
## Bumped on every connectivity change so a stale "Connection restored" timer cannot clear
## a message that a later change put up.
var _note_token := 0
var _join_code_entry: NRJoinCodeEntry = null
## Set while Host, Lobby Code or a friend join is waiting on the privilege service, so
## an impatient double-press cannot start two platform UI round trips.
var _online_action_in_flight := false
## The Join Friend overlay is not a ScreenManager screen, so keep its duplicate guard
## here rather than teaching the global stack about one menu-specific panel.
var _friend_list: NRFriendList = null


func _init() -> void:
	allow_back = false


func _ready() -> void:
	super._ready()
	_add_starfield()

	_xbox_logo.texture = Assets.texture("Logo_Xbox")
	_netrumble_logo.texture = Assets.texture("Logo_NetRumble")

	_build_menu()
	_refresh_gamertag()
	_refresh_build_stamp()
	PlayerProfile.identity_changed.connect(_on_identity_changed)
	if Services != null and Services.connectivity() != null:
		Services.connectivity().connectivity_changed.connect(_on_connectivity_changed)

	_menu_list.call_deferred("focus_first")


## Reached when the acquire-user screen (or any other pushed screen) is popped.
func on_revealed() -> void:
	super.on_revealed()
	_refresh_gamertag()
	focus_menu_list(_menu_list)


## The protocol token is shown beside the commit deliberately: two peers can share a
## commit and still disagree on the wire if one is running unexported local changes,
## and a mismatch here is the documented cause of a match that joins and then does
## nothing (see NRProtocol).
func _refresh_build_stamp() -> void:
	_build_label.text = "build %s  ·  protocol %s" % [
		_build_commit(), NRProtocol.version_string()]


func _build_commit() -> String:
	if not ResourceLoader.exists(_BUILD_INFO_SCRIPT):
		return "unexported"
	var info := load(_BUILD_INFO_SCRIPT) as GDScript
	if info == null:
		return "unexported"
	var constants := info.get_script_constant_map()
	var commit := String(constants.get("COMMIT", ""))
	if commit.is_empty():
		return "unexported"
	# A build made from a dirty tree is not the commit it names, and that is exactly
	# the case where two peers on the "same" hash can still disagree on the wire.
	return commit + ("+" if bool(constants.get("DIRTY", false)) else "")


func _add_starfield() -> void:
	if not ResourceLoader.exists(_STARFIELD_SCENE):
		return
	var packed := load(_STARFIELD_SCENE) as PackedScene
	if packed == null:
		return
	var starfield := packed.instantiate()
	_background.add_child(starfield)
	if starfield is Control:
		(starfield as Control).set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func _build_menu() -> void:
	_in_join_menu = false
	_in_options = false
	allow_back = false
	_apply_list_rect(_MENU_RECT)
	_sign_in_row_shown = not PlayerProfile.is_signed_in
	_menu_list.clear_rows()
	# Sign-in normally completes on the acquire-user screen before this menu is ever
	# shown, so this row only appears when the player chose to continue offline.
	if _sign_in_row_shown:
		_menu_list.add_button("Sign In", _on_sign_in)
	# Reserved unconditionally so that going offline and back only changes this row's
	# text, never the height of the list above the rows the player is aiming at.
	_connectivity_note = _menu_list.add_note("")
	# The theme's existing status-line type, the same one the lobby uses for its status
	# text, rather than a new variation that would have to be designed and maintained.
	_connectivity_note.theme_type_variation = &"LobbyStatus"
	_host_row = _menu_list.add_button("Host Match", _on_play)
	_join_row = _menu_list.add_button("Join Match", _on_join_match)
	_menu_list.add_button("Practice", _on_practice)
	_menu_list.add_button("Match History", func() -> void: ScreenManager.push(ScreenManager.MATCH_HISTORY))
	_menu_list.add_button("Options", _build_options_menu)
	# Consoles have no in-title Quit: the platform owns leaving the game, and a
	# second way out that behaves differently is exactly what certification flags.
	if not is_console():
		_menu_list.add_button("Quit", _on_quit)
	_apply_connectivity(false)


## The join submenu. Join Friend lists the friends currently in a NetRumble session
## (XR-070). It is always selectable: where the platform cannot answer — a desktop
## build, a --pf-user test client, or a build without the GDK — the list opens empty
## and says why, rather than presenting a dead row the player cannot inspect.
## Focus starts on Lobby Code so the two-tap journey (Join → Lobby Code) stays quick.
func _build_join_menu() -> void:
	_in_join_menu = true
	_forget_top_rows()
	# The top-level menu refuses Back (it is the root screen), but the submenu has
	# somewhere to go, so Back is enabled just for it.
	allow_back = true
	_menu_list.clear_rows()
	_menu_list.add_button("Join Friend", _on_join_friend)
	_menu_list.add_button("Lobby Code", _on_lobby_code)
	_menu_list.add_button("Back", _build_top_menu)
	_menu_list.call_deferred("focus_first")


## Options in place of the menu rows, rather than a screen pushed over them. The rows
## themselves are shared with the in-match pause panel (NROptionsRows), so both entry
## points offer the same settings and neither owns them.
func _build_options_menu() -> void:
	_in_join_menu = false
	_in_options = true
	_forget_top_rows()
	allow_back = true
	_apply_list_rect(_OPTIONS_RECT)
	_menu_list.clear_rows()
	NROptionsRows.populate(_menu_list)
	_menu_list.add_button("Back", _on_options_back)
	_menu_list.call_deferred("focus_first")


## Settings apply live, so leaving the rows is what commits them.
func _on_options_back() -> void:
	NROptionsRows.save()
	_build_top_menu()


## Returns from a submenu to the top-level list.
func _build_top_menu() -> void:
	_build_menu()
	_menu_list.call_deferred("focus_first")


## Drops the top-level row references before another list replaces them. `clear_rows()`
## frees the nodes, so holding them would leave `_apply_connectivity()` writing to rows
## that are on their way out.
func _forget_top_rows() -> void:
	_host_row = null
	_join_row = null
	_connectivity_note = null


## Moves and resizes the scrolling list band. Options rows do not fit the narrow column
## the top-level captions use, and the scroll position has to reset or a list swapped in
## while scrolled would open part-way down.
func _apply_list_rect(rect: Rect2) -> void:
	_menu_scroll.offset_left = rect.position.x
	_menu_scroll.offset_top = rect.position.y
	_menu_scroll.offset_right = rect.position.x + rect.size.x
	_menu_scroll.offset_bottom = rect.position.y + rect.size.y
	_menu_scroll.set_deferred("scroll_vertical", 0)


## Hosts an online match. The privilege check is a real platform round trip at the
## button press, not a cache read, so an account whose answer was never warmed cannot
## slip into the network path as "unknown, assumed allowed" (XR-045).
func _on_play() -> void:
	if _online_action_in_flight:
		return
	_online_action_in_flight = true

	ScreenManager.push(ScreenManager.LOADING, {"message": "Checking online permissions"})
	var denial := await _multiplayer_denial()
	if not denial.is_empty():
		ScreenManager.pop()
		await _offer_practice("Cannot Host", denial)
		_online_action_in_flight = false
		return
	ScreenManager.pop()

	ScreenManager.push(ScreenManager.LOADING, {"message": "Creating match"})
	var hosted: bool = await NetManager.host_match(NRTypes.GameModeType.DEATHMATCH)
	ScreenManager.pop()
	if not hosted:
		await _offer_practice("Cannot Host", NetManager.last_error)
		_online_action_in_flight = false
		return
	_refresh_gamertag()
	_online_action_in_flight = false
	ScreenManager.push(ScreenManager.LOBBY, {"option": "host"})


## The reason this account may not play online after giving the platform a chance to
## answer and, for resolvable denials, to fix it in system UI. Empty includes the
## deliberate XR-074 fail-open paths, where the service could not answer at all.
func _multiplayer_denial() -> String:
	if Services == null:
		return "Online services are unavailable in this build."
	return await Services.resolve_multiplayer_denial_reason()


## Applies the current connectivity state to the top-level rows.
##
## Host and Join go dark rather than disappearing, so the menu keeps its shape and the
## player can see that online play exists and is simply unavailable right now. Practice is
## untouched: it is the whole reason the offline case is still worth showing a menu for.
##
## Only the two rows that need a connection are gated. Match History reads from a cache
## and reports its own failures, and Options is local.
##
## `announce` is false while building, because a menu that opens saying "Connection
## restored" is announcing a state the player never saw change.
func _apply_connectivity(announce: bool) -> void:
	if not is_instance_valid(_host_row) or not is_instance_valid(_connectivity_note):
		return
	var connectivity: ConnectivityService = Services.connectivity() if Services != null else null
	# A machine with no GDK never reports a hint, and `is_online()` stays true there, so
	# this reduces to the pre-existing behaviour on desktop.
	var online: bool = connectivity == null or connectivity.is_online()

	_host_row.disabled = not online
	_join_row.disabled = not online
	# The neighbours are explicit paths, so the wrap has to be recomputed or focus would
	# still route through the rows that just went dark.
	_menu_list.refresh_focus_wrap()

	_note_token += 1
	if not online:
		_connectivity_note.text = "No connection - online play unavailable"
	elif announce:
		_connectivity_note.text = "Connection restored"
		_clear_note_later(_note_token)
	else:
		_connectivity_note.text = ""

	# Focus cannot be left on a row that just became unselectable: on a controller there
	# is no pointer to recover with, and nothing would respond.
	if not online:
		var focused := get_viewport().gui_get_focus_owner()
		if focused == _host_row or focused == _join_row:
			_menu_list.call_deferred("focus_first")


## Clears the restored notice after a moment. Guarded by the token so a connectivity
## change during the wait wins over this timer rather than being wiped by it.
func _clear_note_later(token: int) -> void:
	await get_tree().create_timer(3.0).timeout
	if token != _note_token or not is_instance_valid(_connectivity_note):
		return
	_connectivity_note.text = ""


## Connectivity changed while the menu is up. A submenu is left alone for the same reason
## an identity change is: Options holds unsaved edits, and backing out of either rebuilds
## the top-level rows from the current state anyway. The join submenu checks the live
## connectivity/privilege state again when the player chooses a join path.
func _on_connectivity_changed(_online: bool) -> void:
	if _in_options or _in_join_menu:
		return
	_apply_connectivity(true)


## Single-machine practice match. The one path that needs no PlayFab sign-in, kept so
## the game is still playable when Party or the GDK is unavailable.
func _on_practice() -> void:
	NetManager.start_offline()
	ScreenManager.push(ScreenManager.LOBBY, {"option": "host"})


## Party and Lobby both require a signed-in PlayFabUser, so an online failure is a dead
## end rather than something to silently downgrade. Offer practice explicitly instead.
func _offer_practice(title: String, reason: String) -> void:
	var message := reason
	if message.is_empty():
		message = "Online play is unavailable."
	message += "\n\nPlay a practice match offline instead?"
	var practice: bool = await ScreenManager.show_dialog(title, message, "warning", true)
	if practice:
		_on_practice()


## Opens the join submenu rather than the code entry directly, giving the player the
## choice between a friend join and a code join.
func _on_join_match() -> void:
	_build_join_menu()


func _on_lobby_code() -> void:
	if _online_action_in_flight:
		return
	_online_action_in_flight = true

	ScreenManager.push(ScreenManager.LOADING, {"message": "Checking online permissions"})
	var denial := await _multiplayer_denial()
	ScreenManager.pop()
	_online_action_in_flight = false
	if not denial.is_empty():
		await ScreenManager.show_dialog("Cannot Join", denial, "error", false)
		return
	var entry := _JOIN_CODE_ENTRY_SCENE.instantiate() as NRJoinCodeEntry
	entry.title = "Enter Join Code"
	add_child(entry)
	_join_code_entry = entry
	entry.tree_exited.connect(func() -> void:
		if _join_code_entry == entry:
			_join_code_entry = null
	)
	entry.submitted.connect(_on_join_code_submitted)


## The friends list (XR-070). Unlike Lobby Code this opens unconditionally: the list is
## its own answer. An account that cannot play online, or a build with no platform to
## ask, gets an empty list saying so and backs out with Cancel or B — which is less in
## the way than a modal refusal in front of a screen the player has not seen yet. The
## list still makes the authoritative privilege check before it offers any rows.
func _on_join_friend() -> void:
	if is_instance_valid(_friend_list):
		return
	var list := _FRIEND_LIST_SCENE.instantiate() as NRFriendList
	_friend_list = list
	add_child(list)
	list.join_requested.connect(_on_friend_join_requested)
	list.closed.connect(_on_friend_list_closed.bind(list))


func _on_friend_list_closed(list: NRFriendList) -> void:
	if _friend_list == list:
		_friend_list = null


## A friend's activity carries a lobby connection string rather than a five-character
## code, so this joins the way an accepted invite does (InviteRouter._join) and lands
## the player in the same lobby a typed code would.
func _on_friend_join_requested(connection_string: String) -> void:
	if _online_action_in_flight:
		return
	_online_action_in_flight = true

	var checking := ScreenManager.push(ScreenManager.LOADING, {"message": "Checking online permissions"})
	var denial := await _multiplayer_denial()
	ScreenManager.remove(checking)
	if not denial.is_empty():
		_online_action_in_flight = false
		await ScreenManager.show_dialog("Cannot Join", denial, "error", false)
		return

	var loading := ScreenManager.push(ScreenManager.LOADING, {"message": "Joining match"})
	var request := NetManager.join_by_invite(connection_string)
	await request.wait()
	# Named rather than popped: an invite accepted while this was waiting would have
	# pushed its own loading screen above, and popping there takes down the replacement's
	# screen instead of this one.
	ScreenManager.remove(loading)
	_online_action_in_flight = false
	# Another join replaced this one, and owns the screen and the outcome. Nothing is
	# shown here -- not even a failure -- because from the player's side nothing failed.
	if request.was_superseded():
		return
	# Success and this navigation are not the same instant: the host can leave, or the
	# network drop, in between. Opening the lobby on a session that has already ended is
	# what showed a joiner an empty roster and no join code.
	if not NetManager.joined_session_is_live(request):
		if not request.was_cancelled():
			await ScreenManager.show_dialog("Join Failed", NetManager.join_failure_reason(request), "error", false)
		return
	_refresh_gamertag()
	ScreenManager.replace_all(ScreenManager.LOBBY, {"option": "join", "code": NetManager.join_code})


func _on_join_code_submitted(code: String) -> void:
	if _online_action_in_flight:
		return
	_online_action_in_flight = true

	var checking := ScreenManager.push(ScreenManager.LOADING, {"message": "Checking online permissions"})
	var denial := await _multiplayer_denial()
	ScreenManager.remove(checking)
	if not denial.is_empty():
		_online_action_in_flight = false
		await ScreenManager.show_dialog("Cannot Join", denial, "error", false)
		if is_instance_valid(_join_code_entry):
			_join_code_entry.refocus_code()
		return

	var loading := ScreenManager.push(ScreenManager.LOADING, {
		"message": "Joining %s" % code.to_upper(),
		"allow_cancel": true,
	})
	var request := NetManager.join_by_code(code)
	# LoadingScreen declares `cancelled`, but screens carry no class_name (they are
	# referenced by scene path), so the signal is looked up by name on the base type.
	# Bound to this request: Cancel on this screen must stop the join this screen was
	# raised for, and not whichever join happens to be running when it is pressed.
	if loading != null and loading.has_signal("cancelled"):
		loading.connect(&"cancelled", func() -> void: NetManager.cancel_join(request))
	await request.wait()
	ScreenManager.remove(loading)
	_online_action_in_flight = false
	if request.was_superseded():
		return
	if not NetManager.joined_session_is_live(request):
		# A cancellation is not a failure: the player asked for it, so the code entry
		# simply comes back editable with no dialog in front of it.
		if not request.was_cancelled():
			await ScreenManager.show_dialog("Join Failed", NetManager.join_failure_reason(request), "error", false)
		if is_instance_valid(_join_code_entry):
			_join_code_entry.refocus_code()
		return
	_refresh_gamertag()
	ScreenManager.replace_all(ScreenManager.LOBBY, {"option": "join", "code": code.to_upper()})


## Returns to the acquire-user screen so a later sign-in still gets the account
## picker on a screen of its own rather than on top of a live menu.
func _on_sign_in() -> void:
	ScreenManager.push(ScreenManager.ACQUIRE_USER)


## Back only ever fires while a submenu is open, since the top-level menu is the root
## screen and disables it.
func on_back_pressed() -> void:
	if _in_options:
		_on_options_back()
	elif _in_join_menu:
		_build_top_menu()


func _on_quit() -> void:
	var confirmed: bool = await ScreenManager.show_dialog("Quit", "Exit NetRumble?", "warning", true)
	if confirmed:
		quit_game()


func _refresh_gamertag() -> void:
	if PlayerProfile.is_signed_in:
		var suffix := ""
		# Make a --pf-user test client obvious so it is never mistaken for a real
		# Xbox sign-in while debugging a Party session.
		if Services != null and Services.has_method("is_custom_id_session") and Services.is_custom_id_session():
			suffix = "  (test user)"
		_gamertag_label.text = PlayerProfile.display_name + suffix
	else:
		_gamertag_label.text = "Not signed in"


## Keeps the "Sign In" row in step with the identity state without rebuilding (and
## re-focusing) the menu on every unrelated profile change. A submenu is left alone:
## backing out of one rebuilds the top-level rows from the current identity anyway, and
## swapping the list out from under the player would drop unsaved Options edits.
func _on_identity_changed() -> void:
	_refresh_gamertag()
	if _in_options or _in_join_menu:
		return
	if _sign_in_row_shown == PlayerProfile.is_signed_in:
		_build_menu()
		_menu_list.call_deferred("focus_first")
