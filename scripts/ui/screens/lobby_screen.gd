extends NRScreen

## The lobby screen.
##
## lobby_screen.tscn holds the sheared background panels and section headers at fixed
## 1920x1080 offsets; this script builds the repeated widgets (ship tabs, colour tabs,
## roster rows) into the three placeholder Controls at those same offsets.
##
## There is no footer button row. Ready-up is the `toggle_ready` action and shows in
## your own roster ring, leaving is Back, voice mute is `open_voice_chat`, and the
## host's match start happens automatically once every member is ready.
##
## All lobby state is read from the NetManager autoload.

const _ROSTER_ROW_SCENE := preload("res://scenes/ui/elements/nr_roster_row.tscn")
const _PLAYER_ACTIONS_SCENE := preload("res://scenes/ui/elements/nr_player_actions.tscn")

## Console builds must name gamepad buttons the way the platform does: the face buttons
## are A/B/X/Y and the two centre buttons are View and Menu, never "Back" or "Start".
const _CONSOLE_FEATURE := "scarlett"
const _BUTTON_NAMES := {
	JOY_BUTTON_A: "A",
	JOY_BUTTON_B: "B",
	JOY_BUTTON_X: "X",
	JOY_BUTTON_Y: "Y",
	JOY_BUTTON_BACK: "View",
	JOY_BUTTON_START: "Menu",
	JOY_BUTTON_LEFT_SHOULDER: "LB",
	JOY_BUTTON_RIGHT_SHOULDER: "RB",
}

const _SHIP_STYLE_COUNT := 4
const _SHIP_TAB_SIZE := Vector2(151.25, 100.0)
const _SHIP_TAB_PITCH := 156.25
const _COLOR_TAB_SIZE := Vector2(75.0, 100.0)
const _COLOR_ACCENT_SIZE := Vector2(76.0, 16.0)
const _ROSTER_ROW_PITCH := 64.0
const _ROSTER_SLOT_MAX := 8

const _NEUTRAL := Color(0.74, 0.78, 0.78, 0.66)
const _SHIP_TAB_ALPHA_IDLE := 0.15
const _SHIP_TAB_ALPHA_HOVER := 0.45
const _SHIP_TAB_ALPHA_SELECTED := 0.65

@onready var _state_label: Label = %StateLabel
@onready var _ship_background: TextureRect = %ShipBackground
@onready var _ship_texture: TextureRect = %ShipTexture
@onready var _ship_overlay: TextureRect = %ShipOverlay
@onready var _ship_tabs: Control = %ShipTabs
@onready var _color_tabs: Control = %ColorTabs
@onready var _game_type_panel: TextureRect = %GameTypePanel
@onready var _game_type_value: Label = %GameTypeValue
@onready var _rules_panel: TextureRect = %RulesPanel
@onready var _rules_label: Label = %RulesLabel
@onready var _join_code_title: Label = %JoinCodeTitle
@onready var _join_code_panel: TextureRect = %JoinCodePanel
@onready var _join_code_label: Label = %JoinCodeLabel
## Practice-only opponent picker. It occupies the same block as the join code, which
## is meaningless in a session nobody can join, so the two are never shown together.
@onready var _opponents_title: Label = %OpponentsTitle
@onready var _opponents_panel: TextureRect = %OpponentsPanel
@onready var _opponents_value: Label = %OpponentsValue
@onready var _opponents_minus: Button = %OpponentsMinus
@onready var _opponents_plus: Button = %OpponentsPlus
@onready var _roster_list: Control = %RosterList
@onready var _hint_label: Label = %HintLabel

var _selected_style_id: int = 0
var _selected_color_id: int = 0

var _ship_tab_buttons: Array[Button] = []
var _color_tab_buttons: Array[Button] = []

## Fixed roster slots: every slot is always present and an unoccupied one reads
## "Invite To Game...". Pre-allocating them means nothing is created or freed when
## someone joins or leaves.
var _roster_slots: Array[NRRosterRow] = []
## The open player actions overlay, so a second row activation cannot stack two.
var _player_actions: NRPlayerActions = null

var _transitioning: bool = false
var _countdown_text: String = ""
## Set while an awaited open/close of the session is in flight, naming which one so the
## status line can say what the lobby is doing. Also the re-entry guard for the start
## transaction: _on_roster_changed re-enters _try_auto_start on every roster signal, and
## sealing the lobby is a service round trip long enough for several.
var _admission_action: String = ""
## Set when sealing the lobby failed. Auto-start is driven off roster changes, which keep
## arriving while the failure dialog is up, so without this a host whose lock failed would
## retry against the service on every one of them.
var _start_blocked: bool = false
## Set while a recovery dialog is up, waiting on the host to choose what to do about a
## lock that would not take. _admission_action cannot cover this: it is cleared when the
## service call returns, which is the moment *before* the dialog, so a roster change
## arriving while the host reads it would start closing the lobby underneath the choice
## they are being asked to make.
var _recovering: bool = false


func _ready() -> void:
	super._ready()

	var local := NetManager.local_player()
	if local != null:
		_selected_style_id = local.ship_style_id
		_selected_color_id = local.ship_color_id
	else:
		_selected_style_id = PlayerProfile.ship_style_id
		_selected_color_id = PlayerProfile.ship_color_id

	_ship_background.texture = Assets.texture("Lobby_BackgroundSpaceship")
	_game_type_panel.texture = Assets.texture("Lobby_BackgroundGameType")
	_rules_panel.texture = Assets.texture("Lobby_BackgroundRules")
	_join_code_panel.texture = Assets.texture("Lobby_BackgroundGameType")
	_opponents_panel.texture = Assets.texture("Lobby_BackgroundGameType")

	# The roster has to be told about the saved opponent count before anything reads
	# it. Done here rather than in start_offline() so it also re-applies when a
	# practice match ends and drops the player back into this screen.
	if NetManager.is_offline():
		NetManager.sync_practice_bots(PlayerProfile.practice_opponents)

	_build_ship_tabs()
	_build_color_tabs()
	_build_roster_slots()

	_opponents_minus.pressed.connect(_step_opponents.bind(-1))
	_opponents_minus.tooltip_text = "Remove an AI opponent"
	_decorate_stepper(_opponents_minus)
	_opponents_plus.pressed.connect(_step_opponents.bind(1))
	_opponents_plus.tooltip_text = "Add an AI opponent"
	_decorate_stepper(_opponents_plus)

	NetManager.roster_changed.connect(_on_roster_changed)
	NetManager.match_state_changed.connect(_on_match_state_changed)
	NetManager.countdown_changed.connect(_on_countdown_changed)
	NetManager.connection_failed.connect(_on_connection_failed)
	NetManager.server_disconnected.connect(_on_server_disconnected)
	NetManager.chat_indicators_changed.connect(_on_chat_indicators_changed)
	# Guests see the join code and the invite slots too, and both are only honest while
	# the match is actually taking players.
	NetManager.join_admission_changed.connect(_on_join_admission_changed)

	_refresh_all()
	_on_countdown_changed(0)

	if not _ship_tab_buttons.is_empty():
		_ship_tab_buttons[_selected_style_id].call_deferred("grab_focus")

	# Arriving in the waiting lobby is what reopens a session that a match closed. A
	# freshly hosted one is already open, so this only fires on the way back from a
	# match -- or as the retry path after a reopen that failed.
	if NetManager.has_session() and NetManager.is_host() and not NetManager.is_accepting_joins():
		_reopen_joins()


## Roster rows are real focus targets so a controller can navigate to Invite and
## Player options, but once either modal surface is dismissed the next Space press is
## the lobby's Ready shortcut. Return focus to the ship selector, matching the screen's
## initial state, instead of leaving it on the row that launched the overlay.
func _restore_lobby_focus() -> void:
	var target := _lobby_focus_target()
	if NRScreen._is_focusable(target):
		target.call_deferred("grab_focus")


func _lobby_focus_target() -> Control:
	if _selected_style_id >= 0 and _selected_style_id < _ship_tab_buttons.size():
		return _ship_tab_buttons[_selected_style_id]
	if not _ship_tab_buttons.is_empty():
		return _ship_tab_buttons[0]
	return null


## Tabs draw their own textures, so the theme's button box has to be stripped or it
## renders a grey slab behind every tab. Stripping it also removes the focus box, so
## every caller pairs this with an NRFocusRing.
func _clear_button_styles(button: Button) -> void:
	for state in ["normal", "hover", "pressed", "focus", "disabled"]:
		button.add_theme_stylebox_override(state, StyleBoxEmpty.new())


## Gives a stepper button the same translucent square plate the ship tabs use, so it
## reads as part of the sheared lobby panelling rather than as a stock grey button.
func _decorate_stepper(button: Button) -> void:
	_clear_button_styles(button)
	button.focus_mode = Control.FOCUS_ALL
	var plate := TextureRect.new()
	plate.name = "Plate"
	plate.texture = Assets.texture("Shape_Square")
	plate.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	plate.stretch_mode = TextureRect.STRETCH_SCALE
	plate.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	plate.show_behind_parent = true
	plate.modulate = Color(0.74, 0.78, 0.78, _SHIP_TAB_ALPHA_IDLE)
	button.add_child(plate)
	# A recoloured "-" or "+" glyph was the only feedback these had, which is what sent
	# a tester hunting for the player-count control.
	NRFocusRing.attach(button)


# --- Ship selector ----------------------------------------------------------

## 4 tabs of 151.25x100 with 5px spacing after the first, overlaying the top of
## the 620x552 body panel, each carrying a 64x64 silhouette centred at (76, 50).
func _build_ship_tabs() -> void:
	var square := Assets.texture("Shape_Square")
	for index in _SHIP_STYLE_COUNT:
		var tab := Button.new()
		tab.flat = true
		tab.focus_mode = Control.FOCUS_ALL
		tab.position = Vector2(index * _SHIP_TAB_PITCH, 0.0)
		tab.size = _SHIP_TAB_SIZE
		tab.mouse_filter = Control.MOUSE_FILTER_STOP
		_clear_button_styles(tab)

		var background := TextureRect.new()
		background.name = "Background"
		background.texture = square
		background.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		background.stretch_mode = TextureRect.STRETCH_SCALE
		background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		background.mouse_filter = Control.MOUSE_FILTER_IGNORE
		background.show_behind_parent = true
		tab.add_child(background)

		var silhouette := TextureRect.new()
		silhouette.name = "Silhouette"
		silhouette.texture = Assets.ship_texture(index, "Silhouette")
		silhouette.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		silhouette.stretch_mode = TextureRect.STRETCH_SCALE
		silhouette.size = Vector2(64.0, 64.0)
		silhouette.position = Vector2(76.0 - 32.0, 50.0 - 32.0)
		silhouette.pivot_offset = Vector2(32.0, 32.0)
		silhouette.rotation = 0.6
		silhouette.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tab.add_child(silhouette)

		tab.pressed.connect(_on_ship_tab_pressed.bind(index))
		tab.mouse_entered.connect(_refresh_ship_tabs)
		tab.mouse_exited.connect(_refresh_ship_tabs)
		tab.focus_entered.connect(_refresh_ship_tabs)
		tab.focus_exited.connect(_refresh_ship_tabs)
		# The alpha step alone cannot say "focused" on the tab that is also selected,
		# which is where focus starts and where a controller most needs to see it.
		NRFocusRing.attach(tab)
		_ship_tabs.add_child(tab)
		_ship_tab_buttons.append(tab)


func _on_ship_tab_pressed(index: int) -> void:
	_selected_style_id = index
	NetManager.set_local_appearance(_selected_color_id, _selected_style_id)
	_refresh_ship()
	_refresh_colors()
	_refresh_roster()


func _refresh_ship_tabs() -> void:
	for index in _ship_tab_buttons.size():
		var tab := _ship_tab_buttons[index]
		var alpha := _SHIP_TAB_ALPHA_IDLE
		if index == _selected_style_id:
			alpha = _SHIP_TAB_ALPHA_SELECTED
		elif tab.is_hovered() or tab.has_focus():
			alpha = _SHIP_TAB_ALPHA_HOVER
		var background := tab.get_node("Background") as TextureRect
		background.modulate = Color(0.74, 0.78, 0.78, alpha)


## The preview is two stacked layers: the base carries the player's colour while the
## overlay decals stay white. Only the base layer is tinted; the overlay is
## deliberately left at Color.WHITE so the decals render on top of any hull colour.
func _refresh_ship() -> void:
	_ship_texture.texture = Assets.ship_texture(_selected_style_id, "Base")
	_ship_texture.modulate = Assets.player_color(_selected_color_id)
	_ship_overlay.texture = Assets.ship_texture(_selected_style_id, "Overlay")
	_refresh_ship_tabs()


# --- Color selector ---------------------------------------------------------

## 8 tabs of 75x100. Only the selected tab is "expanded": it shows the panel
## background plus a silhouette, with its 76x16 accent slid to the bottom.
## Unselected tabs collapse to the accent strip alone.
func _build_color_tabs() -> void:
	for color_id in Assets.player_color_count():
		var tab := Button.new()
		tab.flat = true
		tab.focus_mode = Control.FOCUS_ALL
		tab.position = Vector2(color_id * _COLOR_TAB_SIZE.x, 0.0)
		tab.size = _COLOR_TAB_SIZE
		tab.mouse_filter = Control.MOUSE_FILTER_STOP
		_clear_button_styles(tab)

		var background := TextureRect.new()
		background.name = "Background"
		background.texture = Assets.texture("Lobby_BackgroundColor")
		background.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		background.stretch_mode = TextureRect.STRETCH_SCALE
		background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		background.modulate = _NEUTRAL
		background.mouse_filter = Control.MOUSE_FILTER_IGNORE
		background.show_behind_parent = true
		tab.add_child(background)

		var silhouette := TextureRect.new()
		silhouette.name = "Silhouette"
		silhouette.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		silhouette.stretch_mode = TextureRect.STRETCH_SCALE
		silhouette.size = Vector2(64.0, 64.0)
		silhouette.position = Vector2(37.0 - 32.0, 37.0 - 32.0)
		silhouette.pivot_offset = Vector2(32.0, 32.0)
		silhouette.rotation = 0.6
		silhouette.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tab.add_child(silhouette)

		var accent := TextureRect.new()
		accent.name = "Accent"
		accent.texture = Assets.texture("Lobby_BackgroundColorSlot")
		accent.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		accent.stretch_mode = TextureRect.STRETCH_SCALE
		accent.size = _COLOR_ACCENT_SIZE
		accent.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tab.add_child(accent)

		tab.pressed.connect(_on_color_selected.bind(color_id))
		tab.mouse_entered.connect(_refresh_colors)
		tab.mouse_exited.connect(_refresh_colors)
		tab.focus_entered.connect(_refresh_colors)
		tab.focus_exited.connect(_refresh_colors)
		NRFocusRing.attach(tab)
		_color_tabs.add_child(tab)
		_color_tab_buttons.append(tab)


func _on_color_selected(color_id: int) -> void:
	if _colors_taken_by_others().has(color_id):
		return
	_selected_color_id = color_id
	NetManager.set_local_appearance(_selected_color_id, _selected_style_id)
	_refresh_ship()
	_refresh_colors()
	_refresh_roster()


func _refresh_colors() -> void:
	var taken := _colors_taken_by_others()
	for color_id in _color_tab_buttons.size():
		var tab := _color_tab_buttons[color_id]
		var selected := color_id == _selected_color_id
		var base := Assets.player_color(color_id)
		var additive := 0.0
		if selected:
			additive = 0.0
		elif tab.is_hovered() or tab.has_focus():
			additive = 0.3
		var accent_color := Color(
			minf(base.r + additive, 1.0),
			minf(base.g + additive, 1.0),
			minf(base.b + additive, 1.0),
			base.a)
		if taken.has(color_id):
			accent_color = accent_color.darkened(0.6)

		tab.disabled = taken.has(color_id)
		(tab.get_node("Background") as TextureRect).visible = selected
		var silhouette := tab.get_node("Silhouette") as TextureRect
		silhouette.visible = selected
		silhouette.texture = Assets.ship_texture(_selected_style_id, "Silhouette")
		silhouette.modulate = accent_color
		var accent := tab.get_node("Accent") as TextureRect
		var accent_y := _COLOR_TAB_SIZE.y - _COLOR_ACCENT_SIZE.y if selected else 0.0
		accent.modulate = accent_color
		accent.position = Vector2(0.0, accent_y)


func _colors_taken_by_others() -> Array[int]:
	var taken: Array[int] = []
	var local_id := NetManager.local_peer_id()
	for peer_id in NetManager.players:
		if peer_id == local_id:
			continue
		var state: PlayerState = NetManager.players[peer_id]
		if not taken.has(state.ship_color_id):
			taken.append(state.ship_color_id)
	return taken


# --- Game type / rules / join code ------------------------------------------

## Deathmatch is the only mode, so this panel reports the rules in force rather than
## offering a choice. The mode is still replicated from the host (NetManager.game_mode_type),
## so the display stays correct without the lobby having to assume it.
func _refresh_game_type() -> void:
	_game_type_value.text = Assets.game_mode(NetManager.game_mode_type).display_name


func _refresh_rules() -> void:
	var rules := Assets.game_mode(NetManager.game_mode_type)
	var minutes := int(rules.time_limit / 60.0)
	_rules_label.text = "Score to win: %d\nTime limit: %d min\nPlayers: %d" % [
		rules.target_score,
		minutes,
		_roster_capacity(),
	]


func _refresh_join_code() -> void:
	var code := NetManager.join_code
	_join_code_label.text = code
	# Hidden while the match is closed. The code still resolves to the lobby, but the
	# lobby will not take anyone, so showing it would invite a join that gets refused --
	# which is the confusion this whole path exists to remove.
	var has_code := not code.is_empty() and NetManager.is_accepting_joins()
	_join_code_title.visible = has_code
	_join_code_panel.visible = has_code
	_join_code_label.visible = has_code


## Practice-only opponent picker. It shares the join-code block's real estate, so it is
## only ever shown offline -- where by definition there is no join code to display.
func _refresh_opponents() -> void:
	var offline := NetManager.is_offline()
	_opponents_title.visible = offline
	_opponents_panel.visible = offline
	_opponents_value.visible = offline
	_opponents_minus.visible = offline
	_opponents_plus.visible = offline
	if not offline:
		return
	var count := NetManager.bot_count()
	_opponents_value.text = "None" if count == 0 else str(count)
	# The steppers clamp rather than wrap, so the ends of the range are disabled to
	# show the limit instead of silently doing nothing.
	_opponents_minus.disabled = count <= 0
	_opponents_plus.disabled = count >= NRConst.MAX_PRACTICE_BOTS


## Adds or removes one AI opponent. `direction` is -1 or 1.
func _step_opponents(direction: int) -> void:
	if not NetManager.is_offline():
		return
	var count := clampi(
		PlayerProfile.practice_opponents + direction, 0, NRConst.MAX_PRACTICE_BOTS)
	if count == PlayerProfile.practice_opponents:
		return
	PlayerProfile.practice_opponents = count
	PlayerProfile.mark_dirty()
	NetManager.sync_practice_bots(count)
	_refresh_opponents()
	_refresh_rules()
	_refresh_roster()
	# Disabling the button the player just pressed drops keyboard/gamepad focus on the
	# floor, so hand it to the opposite stepper -- which is always live at either end.
	if _opponents_minus.disabled and _opponents_minus.has_focus():
		_opponents_plus.grab_focus()
	elif _opponents_plus.disabled and _opponents_plus.has_focus():
		_opponents_minus.grab_focus()


# --- Roster -----------------------------------------------------------------

## Roster slots are fixed and allocated once. Refreshing only re-binds them, so
## nothing is created or freed when someone joins, leaves, or toggles ready.
func _build_roster_slots() -> void:
	for index in _ROSTER_SLOT_MAX:
		var row := _ROSTER_ROW_SCENE.instantiate() as NRRosterRow
		row.position = Vector2(0.0, index * _ROSTER_ROW_PITCH)
		row.invite_requested.connect(_on_invite_requested)
		row.actions_requested.connect(_on_player_actions_requested)
		_roster_list.add_child(row)
		_roster_slots.append(row)


## Sending an invite needs a session for the invitee to join, so the empty slots only
## become live once there is a published activity to invite them to (XR-064). Practice
## matches, desktop custom-id sessions, and builds without the GDK keep the slots as
## inert placeholders, as does a match that has closed to new players -- there is no
## activity to invite anyone to while it is shut.
func _can_invite() -> bool:
	if NetManager.is_offline() or Services == null:
		return false
	if not NetManager.is_accepting_joins():
		return false
	return Services.xbox_user() != null


func _on_invite_requested() -> void:
	if Services == null:
		return
	var activity := Services.activity()
	if activity != null:
		await activity.show_invite_ui(Services.xbox_user())
		if is_inside_tree() and is_active:
			_restore_lobby_focus()


## Per-player actions (XR-015 mute, XR-018 report). The row only reports the request:
## NetManager owns which actions are possible for this player, and the overlay is what
## presents them — a report needs a reason, so it cannot be a one-press row activation.
func _on_player_actions_requested(peer_id: int) -> void:
	if _player_actions != null:
		return
	var state: PlayerState = NetManager.players.get(peer_id)
	if state == null:
		return
	_player_actions = _PLAYER_ACTIONS_SCENE.instantiate()
	_player_actions.setup(peer_id, state.display_label())
	_player_actions.set_restore_focus(_lobby_focus_target())
	_player_actions.closed.connect(_on_player_actions_closed)
	add_child(_player_actions)


func _on_player_actions_closed() -> void:
	_player_actions = null
	_refresh_roster()


## Practice is a single-machine session nobody can join, so the roster collapses to the
## local player plus whatever AI opponents have been configured.
func _roster_capacity() -> int:
	if NetManager.is_offline():
		return clampi(1 + NetManager.bot_count(), 1, _ROSTER_SLOT_MAX)
	return clampi(Assets.game_mode(NetManager.game_mode_type).player_count, 1, _ROSTER_SLOT_MAX)


func _refresh_roster() -> void:
	var players := NetManager.sorted_players()
	var capacity := _roster_capacity()
	var invitable := _can_invite()
	for index in _roster_slots.size():
		var row := _roster_slots[index]
		row.visible = index < capacity
		row.set_invitable(invitable)
		var state: PlayerState = players[index] if index < players.size() else null
		row.set_actions_context(
			state != null and (NetManager.can_mute_peer(state.peer_id)
					or NetManager.can_report_player(state.peer_id)),
			state != null and NetManager.is_peer_muted(state.peer_id),
			state != null and NetManager.is_peer_voice_restricted(state.peer_id),
		)
		row.set_state(state)


# --- Ready / start ----------------------------------------------------------

func _toggle_ready() -> void:
	var local := NetManager.local_player()
	if local == null:
		return
	NetManager.set_local_ready(not local.is_ready)
	_refresh_roster()
	_refresh_status()


## There is no Start Match button: the host starts as soon as every member is ready.
## An online lobby of one is guarded so readying up alone does not immediately launch
## the match, but a practice session is meant to be solo and starts the moment the
## local player is ready.
##
## Starting is a transaction rather than a single call, because the match must be closed
## to newcomers *before* it starts and closing is a service round trip. Broadcasting
## STARTING first would leave the lobby advertised and its join code live for the whole
## match, which is how a latecomer reached a session that had already begun.
func _try_auto_start() -> void:
	if _transitioning or _start_blocked or _recovering or not _admission_action.is_empty() or not NetManager.is_host():
		return
	if not _can_start():
		return

	# Captured before the first await. Everything below is about *this* session, and by
	# the time a service call and a dialog have both returned there may well be another
	# one -- which has_session() would answer for just as readily.
	var session := NetManager.session_id()
	_admission_action = "closing"
	_refresh_status()
	var sealed: bool = await NetManager.close_joins()
	_admission_action = ""
	if not _still_hosting(session):
		return
	if not sealed:
		# Fail closed: the match does not start. Joins are already shut locally, so the
		# lobby is safe to sit in while the host decides what to do about it.
		_start_blocked = true
		_refresh_all()
		_recovering = true
		var retry: bool = await ScreenManager.show_dialog(
			"Could Not Start Match",
			"%s\n\nThe match was not started. Other players cannot join it part-way through, so it will not begin until this succeeds." % NetManager.last_admission_error,
			"error", true, "Try Again", "Stay In Lobby")
		_recovering = false
		# The session can end while the dialog is up -- and the answer arrives all the
		# same. Neither button may act on a session that is no longer the one it was
		# raised for; _on_server_disconnected owns that case and has already routed it.
		if not _still_hosting(session):
			return
		if not retry:
			# Staying means going back to a lobby that takes players. Without this the
			# host would sit in one that is closed, with no join code and no invites, and
			# nothing left to reopen it. _start_blocked stays set, so reopening cannot
			# turn straight round and retry the start that just failed.
			_reopen_joins()
			return
		_start_blocked = false
		if not _can_start():
			# What the lobby was closed for went away while the dialog was up -- the last
			# other player left, or un-readied. Retrying the start would return without
			# doing anything and leave the lobby shut with nothing to reopen it.
			_refresh_all()
			_reopen_joins()
			return
		_try_auto_start()
		return
	# Readiness and the roster both move freely while the lobby is being sealed, so the
	# conditions are re-checked against the session that is actually about to start.
	if not _can_start():
		_refresh_all()
		_reopen_joins()
		return
	NetManager.set_match_state(NRTypes.MatchState.STARTING)
	_go_to_gameplay()


## True when this screen may still act on `session` as its host.
##
## Three things have to hold together and each covers a different way of going stale: the
## screen still being in the tree, this flow not having handed the player somewhere else,
## and the session still being the one the flow started against. A live session under a
## different number is someone else's, and is_host() alone would wave it through --
## Godot's seeded offline peer reports as a server even with no session at all.
func _still_hosting(session: int) -> bool:
	if not is_inside_tree() or _transitioning:
		return false
	return NetManager.session_id() == session and NetManager.has_session() and NetManager.is_host()


## The host is back in the waiting lobby, so the match takes players again.
##
## Only a confirmed unlock opens it. A lobby the host believes is open but the service
## still has locked would show a join code that every joiner is refused with, which is
## indistinguishable from the bug this replaced -- so a failure stays closed and says so.
func _reopen_joins() -> void:
	if _transitioning or _recovering or not _admission_action.is_empty():
		return
	if not NetManager.has_session() or not NetManager.is_host():
		return
	var session := NetManager.session_id()
	_admission_action = "opening"
	_refresh_status()
	var opened: bool = await NetManager.open_joins()
	_admission_action = ""
	if not _still_hosting(session):
		return
	if opened:
		# Players may have readied up while the unlock was in flight, and nothing else
		# will look again until the next roster change.
		_on_roster_changed()
		return
	_refresh_all()
	_recovering = true
	var retry: bool = await ScreenManager.show_dialog(
		"Match Still Closed",
		"%s\n\nNobody can join this match until it reopens." % NetManager.last_admission_error,
		"error", true, "Try Again", "Leave Match")
	_recovering = false
	if not _still_hosting(session):
		# The session ended behind the dialog. Leaving a match that is already gone would
		# push a second route to the menu over the one the disconnect handler took.
		return
	if retry:
		_reopen_joins()
	else:
		_leave_to_menu()


## Whether the match can begin: enough players, and all of them ready.
##
## Readiness is also the barrier that holds the next round until everyone is back. The
## match reset un-readies every human player, and readying up is a lobby shortcut, so a
## player still reading the results screen cannot satisfy this.
func _can_start() -> bool:
	if not NetManager.has_session():
		return false
	if not NetManager.is_offline() and NetManager.players.size() < 2:
		return false
	return NetManager.everyone_ready()


func _leave_to_menu() -> void:
	if _transitioning:
		return
	_transitioning = true
	NetManager.leave_match()
	ScreenManager.replace_all(ScreenManager.MAIN_MENU)


func _go_to_gameplay() -> void:
	if _transitioning:
		return
	_transitioning = true
	ScreenManager.replace_all(ScreenManager.GAMEPLAY)


# --- Status / hint ----------------------------------------------------------

func _refresh_status() -> void:
	if not _countdown_text.is_empty():
		_state_label.text = _countdown_text
		_state_label.visible = true
		return
	var local := NetManager.local_player()
	if _admission_action == "closing":
		_state_label.text = "Closing the match to new players\u2026"
	elif _admission_action == "opening":
		_state_label.text = "Reopening the match to new players\u2026"
	elif _start_blocked:
		_state_label.text = "The match could not be started. Press Ready to try again."
	elif local != null and not local.is_ready:
		_state_label.text = "Press Ready when you are set"
	elif NetManager.is_offline():
		_state_label.text = "Starting practice match\u2026"
	elif not NetManager.is_accepting_joins() and NetManager.is_host():
		_state_label.text = "This match is closed to new players"
	elif NetManager.players.size() < 2:
		_state_label.text = "Waiting for players\u2026"
	elif not NetManager.everyone_ready():
		_state_label.text = "Waiting for all players to ready up\u2026"
	else:
		_state_label.text = "Starting match\u2026"
	_state_label.visible = true


## Practice has no Party mesh, so the voice hint is dropped rather than advertising a
## mute toggle that does nothing. An account without the communications privilege loses
## it for the same reason: there is no chat control to mute (XR-045).
func _refresh_hint() -> void:
	var ready_prompt := _prompt_for(&"toggle_ready")
	var leave_prompt := _prompt_for(&"ui_back_action")
	if NetManager.is_offline() or not NetManager.is_chat_allowed():
		_hint_label.text = "%s Ready    %s Leave" % [ready_prompt, leave_prompt]
		return
	_hint_label.text = "%s Ready    %s %s    %s Leave" % [
		ready_prompt,
		_prompt_for(&"open_voice_chat"),
		"Unmute" if NetManager.is_voice_muted() else "Mute",
		leave_prompt,
	]


## Reads the prompt out of the InputMap instead of hardcoding it, so a rebind can never
## leave the hint lying. Console builds name the gamepad button, everything else the key.
func _prompt_for(action: StringName) -> String:
	var console := OS.has_feature(_CONSOLE_FEATURE)
	for event in InputMap.action_get_events(action):
		if console and event is InputEventJoypadButton:
			return _BUTTON_NAMES.get(event.button_index, "")
		if not console and event is InputEventKey:
			return "[%s]" % OS.get_keycode_string(event.keycode)
	return ""


# --- NetManager signal handlers ---------------------------------------------

func _on_roster_changed() -> void:
	_refresh_all()
	_try_auto_start()


func _on_join_admission_changed(_open: bool) -> void:
	_refresh_all()


## Every lobby panel is derived from NetManager state, so one refresh entry point
## keeps the signal handlers from having to know which panels each change touches.
func _refresh_all() -> void:
	_refresh_ship()
	_refresh_colors()
	_refresh_game_type()
	_refresh_rules()
	_refresh_join_code()
	_refresh_opponents()
	_refresh_roster()
	_refresh_status()
	_refresh_hint()


func _on_chat_indicators_changed() -> void:
	_refresh_roster()
	_refresh_hint()


func _on_match_state_changed(state: NRTypes.MatchState) -> void:
	if NRTypes.has_match_state(state, NRTypes.MatchState.STARTING) \
			or NRTypes.has_match_state(state, NRTypes.MatchState.RUNNING):
		_go_to_gameplay()


func _on_countdown_changed(seconds_remaining: int) -> void:
	if seconds_remaining > 0:
		_countdown_text = "Match starting in %d\u2026" % seconds_remaining
	else:
		_countdown_text = ""
	_refresh_status()


func _on_connection_failed(reason: String) -> void:
	_return_to_menu_with_dialog("Connection Failed", reason)


func _on_server_disconnected() -> void:
	_return_to_menu_with_dialog("Disconnected", NetManager.last_disconnect_reason)


func _return_to_menu_with_dialog(title: String, message: String) -> void:
	if _transitioning:
		return
	_transitioning = true
	await ScreenManager.show_dialog(title, message, "error", false)
	ScreenManager.replace_all(ScreenManager.MAIN_MENU)


# --- Input / leave ----------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if not is_active:
		return
	# The player actions overlay is a modal child of this screen rather than a screen of
	# its own, so the lobby's own shortcuts stand down while it is open — otherwise
	# picking a report reason would also ready the player up.
	if _player_actions != null:
		return
	if event.is_action_pressed("toggle_ready"):
		get_viewport().set_input_as_handled()
		# Readiness is frozen while the match is being opened or closed: the start
		# transaction re-reads it after the lock lands, and letting it move underneath
		# an in-flight decision is what that re-read exists to catch.
		if not _admission_action.is_empty():
			return
		# Pressing Ready again is the way out of a failed start: the host asked for the
		# match to begin, so the attempt is live again.
		_start_blocked = false
		_toggle_ready()
		_try_auto_start()
		return
	if event.is_action_pressed("open_voice_chat") and NetManager.is_chat_allowed():
		get_viewport().set_input_as_handled()
		NetManager.toggle_voice_mute()
		_refresh_hint()
		return
	super._unhandled_input(event)


func on_back_pressed() -> void:
	if _transitioning:
		return
	var confirmed: bool = await ScreenManager.show_dialog("Leave Match", "Leave the current match?", "warning", true)
	if not confirmed:
		return
	_leave_to_menu()
