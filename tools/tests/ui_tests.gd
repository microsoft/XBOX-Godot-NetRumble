extends RefCounted

const FlowTests := preload("res://tools/tests/pregame_flow_tests.gd")
const Review := preload("res://tools/tests/review_lifecycle.gd")
const LeaderboardTests := preload("res://tools/tests/leaderboard_tests.gd")

## Branding registry key -> [imported source, exact 2x raster size].
const BRANDING_TEXTURES := {
	"Logo_NetRumbleTitle": ["res://assets/textures/UI/Logo/Logo_NetRumbleTitle.svg", Vector2i(1480, 318)],
	"Logo_NetRumbleMenu": ["res://assets/textures/UI/Logo/Logo_NetRumbleMenu.svg", Vector2i(980, 536)],
	"Logo_XboxMark": ["res://assets/textures/UI/Logo/Logo_XboxMark.svg", Vector2i(212, 208)],
	"Logo_XboxGlass": ["res://assets/textures/UI/Logo/Logo_XboxGlass.png", Vector2i(798, 448)],
	"Loading_ProgressRing": ["res://assets/textures/UI/Loading/Loading_ProgressRing.svg", Vector2i(336, 336)],
}
## Sidecar settings the runner preserves for every branding texture, plus the SVG-only ones.
const BRANDING_IMPORT_PARAMS := {
	"compress/mode": 0,
	"mipmaps/generate": true,
	"mipmaps/limit": -1,
	"process/fix_alpha_border": true,
	"process/premult_alpha": false,
	"process/size_limit": 0,
}
const BRANDING_SVG_IMPORT_PARAMS := {
	"svg/scale": 2.0,
	"editor/scale_with_editor_scale": false,
	"editor/convert_colors_with_editor_theme": false,
}
## Screen node path -> [texture key, logical size] for each branding TextureRect.
const TITLE_BRANDING := {
	"Branding/NetRumbleLogo": ["Logo_NetRumbleTitle", Vector2(740, 159)],
	"Branding/XboxLogo": ["Logo_XboxGlass", Vector2(400, 224)],
}
const MENU_BRANDING := {
	"NetRumbleLogo": ["Logo_NetRumbleMenu", Vector2(490, 268)],
}
const LOADING_BRANDING := {
	"RingsRoot/Ring": ["Loading_ProgressRing", Vector2(168, 168)],
	"XboxMark": ["Logo_XboxMark", Vector2(104, 104)],
}
## 16:9 from 960x540 to 4K, then 16:10 and ultrawide.
const BRANDING_WINDOWS := [
	Vector2i(960, 540), Vector2i(1280, 720), Vector2i(1366, 768), Vector2i(1600, 900),
	Vector2i(1920, 1080), Vector2i(2560, 1440), Vector2i(3840, 2160),
	Vector2i(1600, 1000), Vector2i(2560, 1080),
]
const BRANDING_ASPECT_TOLERANCE := 0.01
## Sub-pixel slack when comparing a drawn footprint with the imported pixel size.
const BRANDING_PIXEL_SLACK := 0.5
const RING_CAPTURE_ROTATION := PI / 4.0
## Straight alpha keeps partially covered wordmark edges brighter than their coverage;
## premultiplied art never exceeds its alpha there and scores about zero.
const WORDMARK_EDGE_MIN_ALPHA := 0.2
const WORDMARK_EDGE_MAX_ALPHA := 0.9
const STRAIGHT_ALPHA_MARGIN := 0.05
const MIN_WORDMARK_STRAIGHT_EDGES := 0.70
## Every channel of the Xbox mark's antialiased edge stays white instead of darkening or tinting.
const MARK_EDGE_MIN_ALPHA := 0.05
const MARK_EDGE_MAX_ALPHA := 0.95
const MARK_EDGE_WHITE := 0.95
const MIN_MARK_WHITE_EDGES := 0.95
## Seam depth of an interior pixel: max(min(left, right), min(up, down)) - alpha. Deeper
## than this soft threshold marks a translucent hairline between abutting vector shapes.
const SEAM_DEPTH_ALPHA := 0.08
const MAX_WORDMARK_SEAM_DIPS := 40
## Mip-0 pixels where a wordmark's fill meets its outline, which must stay opaque rather than
## leave a translucent seam. They are tied to the SVG geometry and must be re-derived if the
## wordmark artwork changes.
const WORDMARK_SEAM_PROBES := {
	"Logo_NetRumbleTitle": [Vector2i(1244, 255), Vector2i(1091, 255), Vector2i(755, 258),
		Vector2i(1161, 255), Vector2i(940, 252), Vector2i(316, 254)],
	"Logo_NetRumbleMenu": [Vector2i(453, 429), Vector2i(824, 449), Vector2i(663, 475),
		Vector2i(970, 475), Vector2i(268, 476), Vector2i(551, 421)],
}
const SEAM_PROBE_MIN_ALPHA := 0.90
## Root backgrounds also sweep 4:3, which only changes geometry and is never captured.
const BACKGROUND_EXTRA_WINDOWS := [Vector2i(1280, 960)]
## Source texels a 1920x1080 cover background keeps where the window is not 16:9 (logical
## 2560x1080, 1920x1200 and 1920x1440); every 16:9 window keeps the whole texture.
const BACKGROUND_CROPS := {
	Vector2i(2560, 1080): Rect2(0, 135, 1920, 810),
	Vector2i(1600, 1000): Rect2(96, 0, 1728, 1080),
	Vector2i(1280, 960): Rect2(240, 0, 1440, 1080),
}
const BACKGROUND_PIXEL_TOLERANCE := 1.0
const BACKGROUND_SCALE_TOLERANCE := 0.01
## Background art and the analytic glow share one 1920x1080 design space over a #050505 base.
const BACKGROUND_DESIGN_SIZE := Vector2(1920, 1080)
const BACKGROUND_BASE := Color(0.019607844, 0.019607844, 0.019607844, 1.0)
const WAVES_ADAPTER := "res://scripts/ui/backgrounds/waves_background.gd"
const GLOW_ADAPTER := "res://scripts/ui/backgrounds/glow_background.gd"
const GLOW_SHADER := "res://scripts/ui/backgrounds/glow.gdshader"
const SHIP_CARD_SHADER := "res://assets/ui/ship_card.gdshader"
const SHIP_PREVIEW_SHADER := "res://assets/ui/ship_preview.gdshader"
## Clearance between an Options row's edge, where its focus outline is drawn, and the row's text
## and controls.
const OPTION_ROW_MIN_LEFT_INSET := 24.0
const OPTION_ROW_MIN_RIGHT_INSET := 12.0
const UI_THEME := "res://assets/ui/netrumble.tres"
## The PC wording; on console the hint and the Options note name only View.
const MOTION_HINT_TEXT := "Ctrl+Shift+M / View pauses background motion"
const OPTIONS_MOTION_NOTE := "Ctrl+Shift+M / View pauses background motion for this session."
const MOTION_HINT_MIN_FONT_SIZE := 26
## Title-safe area: the middle 90 % of the viewport on each axis.
const TITLE_SAFE_MARGIN := 0.05
## Sub-pixel slack for a hint aligned exactly on the title-safe edge.
const TITLE_SAFE_SLACK := 0.5
## Monotonic budget for a windowed run to draw the frame a screenshot needs.
const FRAME_TIMEOUT_MSEC := 5000


class Connectivity extends ConnectivityService:
	var connected := true

	func is_online() -> bool:
		return connected


func run(test: Node) -> void:
	print("CASE: designer UI uses production screens, isolated account saves and real input")
	var window := test.get_tree().root
	var old_size := window.size
	var old_scale_size := window.content_scale_size
	var old_scale_mode := window.content_scale_mode
	var old_scale_aspect := window.content_scale_aspect
	var old_container := ScreenManager._container
	var screens := CanvasLayer.new()
	test.add_child(screens)
	window.content_scale_size = Vector2i(1920, 1080)
	window.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	window.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
	window.size = Vector2i(1920, 1080)
	Assets.render_ui_assets = true
	ScreenManager.set_container(screens)
	await test._reset()
	_branding_textures(test)
	await _acquisition(test)
	await _main_menu(test)
	await _loading(test)
	await _practice_lobby(test)
	await _hosted_lobby(test)
	await _matchmaking_lobby(test)
	await _secondary_screens(test)
	await _overlays(test)
	await _gameplay_surfaces(test)
	ScreenManager.clear()
	await test.get_tree().process_frame
	ScreenManager.set_container(old_container)
	screens.queue_free()
	Assets.render_ui_assets = false
	window.content_scale_size = old_scale_size
	window.content_scale_mode = old_scale_mode
	window.content_scale_aspect = old_scale_aspect
	window.size = old_size


func _acquisition(test: Node) -> void:
	print("CASE: acquisition preserves Retry/Back and cannot complete its progress before saves")
	var gated_menu: Variant = ScreenManager.replace_all(ScreenManager.MAIN_MENU)
	await _settle(test)
	test._check(not gated_menu._secondary_actions.visible
		and _labels(gated_menu._menu_list).has("Sign In"),
		"unready account has no History/Leaderboards links or gameplay menu")
	var screen: Variant = ScreenManager.replace_all(ScreenManager.ACQUIRE_USER)
	await _settle(test)
	test._check(not screen._spinner.visible and not screen._menu_list.visible,
		"idle title shows the press prompt without progress or recovery choices")
	await _capture(test, "title")
	await _branding(test, screen, "title", TITLE_BRANDING)
	await _glow_background(test, screen, "title")
	await _motion_hint(test, screen, "title")
	# Nothing warms motion in this suite, so it is disabled: Ctrl+Shift+M and View are consumed
	# without pausing anything, and neither reaches the press prompt as a sign-in key.
	test._check(not UIBackgroundMotion.effective_enabled(), "background motion is disabled in this suite")
	await _key(test, KEY_M, true, true)
	await _joy(test, JOY_BUTTON_BACK)
	test._check(screen._state == screen.State.WAITING_FOR_INPUT and not Services.is_signing_in()
		and not UIBackgroundMotion.session_paused,
		"Ctrl+Shift+M and View neither pause disabled motion nor start sign-in from the title")
	await _key(test, KEY_SHIFT)
	test._check(screen._state == screen.State.WAITING_FOR_INPUT,
		"a modifier alone cannot raise the account picker")
	test._select("ui", test._folder())
	var sdk: Variant = Services._game_saves.sdk
	sdk.blocked = true
	sdk.folder_ok = false
	await _key(test, KEY_ENTER)
	test._check(screen._state == screen.State.SIGNING_IN
		and screen._spinner.visible and screen._spinner.indeterminate
		and not Services.is_account_ready(), "save preparation retains indeterminate progress and the account gate")
	test._check(not screen._detail_label.text.is_empty(), "the live sign-in stage remains visible")
	await _capture(test, "signing-in")
	sdk.released.emit()
	await _settle(test)
	test._check(screen._state == screen.State.NEEDS_INTERACTION
		and not screen._spinner.visible and not screen._detail_label.text.is_empty()
		and _labels(screen._menu_list).has("Retry") and _labels(screen._menu_list).has("Back"),
		"save failure offers recovery instead of a completed bar or menu handoff")
	_inside(test, screen._menu_list, "acquisition recovery choices")
	test._check(not screen._detail_label.get_global_rect().intersects(screen._menu_list.get_global_rect()),
		"recovery choices do not cover the failed stage/reason")
	await _capture(test, "account-error")
	sdk.folder_ok = true
	screen._menu_list.focus_first()
	await _key(test, KEY_ENTER)
	test._check(screen._state == screen.State.SIGNING_IN and not Services.is_account_ready(),
		"the real Retry button starts another save preparation without bypassing readiness")
	sdk.released.emit()
	await _settle(test)
	test._check(screen._state == screen.State.READY and Services.is_account_ready()
		and screen._spinner.visible and not screen._spinner.indeterminate
		and is_equal_approx(screen._spinner.value, 100.0),
		"only successful account/save readiness completes the progress bar")
	await _capture(test, "signed-in")
	await test.get_tree().create_timer(1.0).timeout
	test._check(ScreenManager.current_screen().scene_file_path == ScreenManager.MAIN_MENU,
		"the completed title still hands off to the real main menu")


func _main_menu(test: Node) -> void:
	print("CASE: main menu includes matchmaking and keyboard/gamepad-reachable secondary links")
	var connectivity := Connectivity.new()
	Services._connectivity = connectivity
	var menu: Variant = ScreenManager.replace_all(ScreenManager.MAIN_MENU)
	await _settle(test)
	var labels := _labels(menu._menu_list)
	test._check(labels.slice(0, 3) == ["Matchmaking", "Host Match", "Join Match"]
		and not labels.has("Leaderboards") and not labels.has("Match History"),
		"matchmaking sits above Host/Join, and History/Leaderboards are footer actions, not menu rows")
	test._check(menu._secondary_actions.visible, "ready account sees both secondary links")
	for row: Control in menu._menu_list.rows():
		_inside(test, row, "primary menu row")
		test._check((row as Button).alignment == HORIZONTAL_ALIGNMENT_LEFT, "primary captions remain left-aligned")
	menu._menu_list.focus_first()
	var focus_order: Array[Control] = menu._menu_list.rows().duplicate()
	focus_order.append(menu._leaderboards_button)
	focus_order.append(menu._history_button)
	for expected in focus_order:
		test._check(test.get_viewport().gui_get_focus_owner() == expected,
			"Tab reaches " + expected.name)
		await _key(test, KEY_TAB)
	test._check(test.get_viewport().gui_get_focus_owner() == focus_order[0],
		"the complete main-menu Tab loop wraps")
	await _joy(test, JOY_BUTTON_DPAD_RIGHT)
	test._check(test.get_viewport().gui_get_focus_owner() == menu._leaderboards_button,
		"gamepad Right reaches Leaderboards from the primary list")
	await _joy(test, JOY_BUTTON_DPAD_RIGHT)
	test._check(test.get_viewport().gui_get_focus_owner() == menu._history_button,
		"gamepad Right reaches History from Leaderboards")
	await _joy(test, JOY_BUTTON_A)
	await _settle(test)
	test._check(ScreenManager.current_screen().scene_file_path == ScreenManager.MATCH_HISTORY,
		"the real History footer button opens account-owned history")
	await _key(test, KEY_ESCAPE)
	await _settle(test)
	test._check(ScreenManager.current_screen() == menu
		and test.get_viewport().gui_get_focus_owner() == menu._history_button,
		"Back restores the footer button rather than resetting focus to matchmaking")
	menu._menu_list.focus_first()
	await _capture(test, "main-menu")
	await _branding(test, menu, "menu", MENU_BRANDING)
	await _waves_background(test, menu, "menu")
	var positions: Array[Vector2] = []
	for row: Control in menu._menu_list.rows():
		positions.append(row.global_position)
	connectivity.connected = false
	connectivity.connectivity_changed.emit(false)
	await _settle(test)
	test._check(menu._host_row.disabled and menu._join_row.disabled and menu._matchmaking_row.disabled
		and not menu._connectivity_note.text.is_empty() and menu._secondary_actions.visible,
		"offline status disables only online gameplay, not account-owned footer actions")
	for index in positions.size():
		test._check(menu._menu_list.rows()[index].global_position == positions[index],
			"connectivity does not move a menu row")
	test._check(test.get_viewport().gui_get_focus_owner() != menu._matchmaking_row,
		"connectivity moves focus off the newly disabled row")
	menu._build_options_menu()
	await _settle(test)
	test._check(menu._in_options and not menu._secondary_actions.visible,
		"Options has its own focus scope without hidden footer targets")
	_inside(test, menu._menu_scroll, "Options scroll region")
	_option_rows_inset(test, menu._menu_list, "Options")
	var motion_note: Label = null
	for note: Node in menu._menu_list.find_children("*", "Label", true, false):
		if (note as Label).text == OPTIONS_MOTION_NOTE:
			motion_note = note as Label
	test._check(motion_note != null and motion_note.focus_mode == Control.FOCUS_NONE
		and motion_note.get_global_rect().position.x >= menu._menu_scroll.get_global_rect().position.x
		and motion_note.get_global_rect().end.x <= menu._menu_scroll.get_global_rect().end.x,
		"Options names Ctrl+Shift+M / View as the session pause, within the list's width")
	await _capture(test, "options")
	await _key(test, KEY_ESCAPE)
	await _settle(test)
	test._check(not menu._in_options and menu._secondary_actions.visible,
		"Options Back preserves settings and restores the new main menu")
	Services._connectivity = null


func _loading(test: Node) -> void:
	print("CASE: Xbox loading ring animates without rotating the badge or changing cancellation ownership")
	var loading: Variant = ScreenManager.replace_all(ScreenManager.LOADING,
		{"message": "Loading match...", "allow_cancel": true})
	await _settle(test)
	var rotation: float = loading._ring.rotation
	await test.get_tree().process_frame
	test._check(loading._ring.rotation > rotation, "the new progress ring is animated")
	test._check(is_zero_approx(loading.get_node("XboxMark").rotation), "the Xbox mark remains upright")
	_inside(test, loading._message_label, "loading caption")
	await _capture(test, "loading")
	await _branding(test, loading, "loading", LOADING_BRANDING, "RingsRoot/Ring")
	await _waves_background(test, loading, "loading")
	await _motion_hint(test, loading, "loading")
	var cancellations: Array[bool] = []
	loading.cancelled.connect(func() -> void: cancellations.append(true))
	await _key(test, KEY_ESCAPE)
	await _key(test, KEY_ESCAPE)
	test._check(cancellations == [true] and loading._cancel_button.disabled,
		"Back cancels this loading operation exactly once")
	loading.set_status("Cleaning up the previous session")
	test._check(loading._message_label.text == "Cleaning up the previous session"
		and loading._cancel_button.disabled, "cleanup still owns the loading caption and disabled cancel")


func _practice_lobby(test: Node) -> void:
	print("CASE: lobby controls retain live appearance, reserved colours, Ready and the full roster")
	ScreenManager.clear()
	await _settle(test)
	test._check(NetManager.start_offline(), "ready account enters the real practice session")
	var lobby: Variant = ScreenManager.push(ScreenManager.LOBBY)
	await _settle(test)
	test._check(lobby._ship_tab_buttons.size() == 4 and lobby._color_tab_buttons.size() == 8,
		"the selectors offer all four ships and eight colours")
	for style in 4:
		lobby._ship_tab_buttons[style].grab_focus()
		await _key(test, KEY_ENTER)
		test._check(NetManager.local_player().ship_style_id == style
			and lobby._ship_texture.texture == Assets.ship_texture(style, "Base")
			and lobby._ship_overlay.modulate == Color.WHITE,
			"ship selection updates the live preview without tinting its decals")
	var chosen := -1
	for color in 8:
		if lobby._color_tab_buttons[color].disabled:
			test._check(lobby._colors_taken_by_others().has(color), "reserved colours remain disabled")
		elif color != NetManager.local_player().ship_color_id:
			chosen = color
	if chosen >= 0:
		lobby._color_tab_buttons[chosen].grab_focus()
		await _key(test, KEY_ENTER)
		test._check(NetManager.local_player().ship_color_id == chosen
			and lobby._ship_texture.modulate == Assets.player_color(chosen),
			"colour selection updates the player and preview")
	var selected_tab: Control = lobby._color_tab_buttons[NetManager.local_player().ship_color_id]
	var tile := selected_tab.get_node("Background") as Control
	var accent := selected_tab.get_node("Accent") as Control
	test._check(tile.visible and is_equal_approx(tile.position.y + tile.size.y, accent.position.y),
		"the selected colour's tile stops where its accent strip starts, so the strip's cut corner shows the page")
	test._check(lobby._opponents_panel.visible and not lobby._join_code_panel.visible,
		"practice retains the opponent picker instead of advertising a join code")
	NetManager.bot_players()[0].is_ready = false
	lobby._ship_tab_buttons[0].grab_focus()
	await _key(test, KEY_SPACE)
	test._check(NetManager.local_player().is_ready, "Space still readies up while a ship tab has focus")
	await _key(test, KEY_SPACE)
	test._check(not NetManager.local_player().is_ready, "Space can unready without activating the selected tab")
	await _capture(test, "practice-lobby")
	for dimensions: Vector2i in [Vector2i(1280, 720), Vector2i(1600, 1000), Vector2i(2560, 1080)]:
		test.get_tree().root.size = dimensions
		await _settle(test)
		for selector: Control in [lobby._ship_tabs, lobby._color_tabs, lobby._roster_list, lobby._hint_label]:
			_inside(test, selector, "lobby layout at " + str(dimensions))
	test.get_tree().root.size = Vector2i(1920, 1080)
	await _glow_background(test, lobby, "lobby")
	_ship_card(test, lobby)
	PlayerProfile.practice_opponents = NRConst.MAX_PRACTICE_BOTS
	NetManager.sync_practice_bots(PlayerProfile.practice_opponents)
	await _settle(test)
	var visible := 0
	for row: NRRosterRow in lobby._roster_slots:
		if row.visible:
			visible += 1
			_inside(test, row, "maximum-capacity roster card")
	test._check(visible == 1 + NRConst.MAX_PRACTICE_BOTS,
		"all supported practice players fit in the roster")
	await _capture(test, "full-roster")
	ScreenManager.clear()
	await _settle(test)
	await NetManager.leave_match_and_wait()


func _hosted_lobby(test: Node) -> void:
	print("CASE: hosted lobby keeps its join code only while admission is open")
	Services._party = Review.HostParty.new(null)
	test._check(await NetManager.host_match(), "the hosted UI uses production session setup over the existing Party double")
	var lobby: Variant = ScreenManager.push(ScreenManager.LOBBY)
	await _settle(test)
	test._check(lobby._join_code_panel.visible and not lobby._opponents_panel.visible
		and not NetManager.join_code.is_empty() and lobby._join_code_label.text == NetManager.join_code,
		"hosted join code remains live in the rounded panel")
	_inside(test, lobby._join_code_panel, "hosted join code")
	await _capture(test, "hosted-lobby")
	NetManager._set_accepting_joins(false)
	await _settle(test)
	test._check(not lobby._join_code_panel.visible and not lobby._join_code_label.visible,
		"a closed hosted lobby does not advertise its code")
	NetManager._set_accepting_joins(true)
	await _settle(test)
	test._check(lobby._join_code_panel.visible, "reopening admission restores the code without rebuilding the screen")
	ScreenManager.clear()
	await _settle(test)
	await NetManager.leave_match_and_wait()
	Services._party = null


func _matchmaking_lobby(test: Node) -> void:
	print("CASE: the matchmaking lobby shows the group, rules and invite-only entry")
	var fixture := FlowTests.new()
	fixture._saved_activity = Services._activity
	await fixture._setup(test, "ui-group")
	var flow := await fixture._open_group(test)
	if flow == null:
		await fixture._teardown(test)
		return
	fixture._add_guest(2, "Squadmate")
	NetManager.players[2].ship_color_id = 1
	NetManager.players[2].ship_style_id = 1
	var lobby: Variant = ScreenManager.replace_all(ScreenManager.LOBBY)
	await _settle(test)
	test._check(not lobby._join_code_panel.visible and not lobby._opponents_panel.visible
		and NetManager.join_code.is_empty(),
		"matchmaking groups remain invite-only without a hosted room code or practice opponents")
	test._check(lobby._rules_label.text.contains("Group 2/4")
		and lobby._rules_label.text.contains("Match 2-4"),
		"rules still distinguish the matchmaking group from the eventual match")
	test._check(lobby._roster_slots[3].visible and not lobby._roster_slots[4].visible,
		"the matchmaking roster still uses its four-player capacity")
	var empty: NRRosterRow = lobby._roster_slots[3]
	test._check(empty.focus_mode == Control.FOCUS_ALL
		and is_equal_approx(empty.get_node("%NameLabel").offset_left, 15.0),
		"an invitable empty slot keeps its left-aligned caption and controller focus")
	await _capture(test, "matchmaking-lobby")
	ScreenManager.clear()
	await _settle(test)
	await fixture._teardown(test)


func _labels(list: NRMenuList) -> Array[String]:
	var labels: Array[String] = []
	for row: Control in list.rows():
		if row is Button:
			labels.append((row as Button).text)
	return labels


func _secondary_screens(test: Node) -> void:
	print("CASE: History and Leaderboards share the Waves background, panel and focus language")
	var menu: Variant = ScreenManager.replace_all(ScreenManager.MAIN_MENU)
	await _settle(test)
	menu._history_button.grab_focus()
	await _key(test, KEY_ENTER)
	var history: Variant = ScreenManager.current_screen()
	test._check(history.scene_file_path == ScreenManager.MATCH_HISTORY,
		"the styled History page still opens from its footer")
	_assert_surface(test, history.get_node("Panel"), "History panel")
	test._check(history.get_node("Background").texture == Assets.texture("Background_Waves"),
		"History uses the Waves background")
	await _waves_background(test, history, "match-history")
	test._check(NetManager.start_offline(), "history fixture uses an isolated Practice session")
	for index in 12:
		test._check(Services.report_match_result(test._payload(index)), "record isolated UI history")
	await NetManager.leave_match_and_wait()
	history._rebuild()
	await _settle(test)
	test._check(history._list.rows().size() == 13, "all history entries and Back remain controller targets")
	for _step in 12:
		await _key(test, KEY_DOWN)
	test._check((test.get_viewport().gui_get_focus_owner() as Button).text == "Back",
		"the styled History list scrolls to its last row")
	_inside(test, history.get_node("Panel"), "History page")
	history._list.focus_first()
	await _capture(test, "match-history")
	await _key(test, KEY_ESCAPE)
	await _settle(test)
	test._check(test.get_viewport().gui_get_focus_owner() == menu._history_button,
		"History returns to its original footer focus")

	var previous := Services._leaderboards
	var board := LeaderboardTests.Leaderboards.new()
	Services._leaderboards = board
	menu._leaderboards_button.grab_focus()
	await _key(test, KEY_ENTER)
	var leaderboards: Variant = ScreenManager.current_screen()
	test._check(leaderboards.scene_file_path == ScreenManager.LEADERBOARDS
		and board.pf.leaderboards.queries.size() == 1 and leaderboards._loading,
		"the styled Leaderboards page still starts its real query contract")
	_assert_surface(test, leaderboards.get_node("Panel"), "Leaderboards panel")
	var user: Variant = Services.playfab_user()
	var entries: Array = []
	for index in 3:
		var entry: Dictionary = LeaderboardTests.new()._row(user, 90 - index * 10, "Pilot %d" % (index + 1))
		entry["rank"] = index + 1
		entries.append(entry)
	board.pf.leaderboards.queries[0].completed.emit(LeaderboardTests.new()._reply(entries))
	await _settle(test)
	test._check(not leaderboards._loading and _labels(leaderboards._list).has("Refresh"),
		"loaded rankings retain Refresh and Back")
	await _waves_background(test, leaderboards, "leaderboards")
	await _capture(test, "leaderboards")
	await _key(test, KEY_ESCAPE)
	await _settle(test)
	test._check(test.get_viewport().gui_get_focus_owner() == menu._leaderboards_button,
		"Leaderboards returns to its original footer focus")
	Services._leaderboards = previous


func _overlays(test: Node) -> void:
	print("CASE: dialog, join, friends, player actions and chat use the same rounded visual system")
	var menu: Variant = ScreenManager.replace_all(ScreenManager.MAIN_MENU)
	await _settle(test)
	for severity: String in ["default", "warning", "error"]:
		var dialog: Variant = ScreenManager.push(ScreenManager.DIALOG_BOX, {
			"title": "Match Complete" if severity == "default" else "Connection Notice",
			"message": "1. Pilot One - 5\n2. Pilot Two - 3" if severity == "default"
				else "This operation could not finish. Your account and saved profile remain unchanged.",
			"severity": severity, "show_cancel": true,
		})
		await _settle(test)
		_assert_surface(test, dialog.get_node("Center/Panel"), "dialog panel")
		test._check(dialog._ok_button.get_theme_color(&"font_focus_color") == Color.WHITE,
			"dialog focus keeps white text")
		test._check(dialog._title_bar.theme_type_variation == dialog._title_variation(),
			"severity still selects the correct title treatment")
		await _capture(test, "dialog-" + severity)
		await _key(test, KEY_ESCAPE)
		await _settle(test)
		test._check(ScreenManager.current_screen() == menu, "dialog Back restores the covered screen")

	var join: NRJoinCodeEntry = preload("res://scenes/ui/elements/nr_join_code_entry.tscn").instantiate()
	menu.add_child(join)
	await _settle(test)
	_assert_surface(test, join.get_node("Panel"), "join-code overlay")
	test._check(join._title_label.theme_type_variation == &"ModalTitle",
		"join-code heading uses shared modal typography")
	join._line_edit.text = "ab"
	join._on_text_changed(join._line_edit.text)
	test._check(join._ok_button.disabled, "the join code needs all five characters")
	join._line_edit.text = "abcde"
	join._on_text_changed(join._line_edit.text)
	test._check(join._line_edit.text == "ABCDE" and not join._ok_button.disabled,
		"a five-character code is normalized to uppercase and enables OK")
	await _capture(test, "join-code")
	join._cancel_button.grab_focus()
	await _key(test, KEY_ESCAPE)
	await _settle(test)
	test._check(not is_instance_valid(join), "join-code Back closes the overlay")

	var friends: NRFriendList = preload("res://scenes/ui/elements/nr_friend_list.tscn").instantiate()
	menu.add_child(friends)
	await _settle(test)
	_assert_surface(test, friends.get_node("Panel"), "friends overlay")
	test._check(not friends._status_label.text.is_empty(),
		"friends still explains unavailable/empty results instead of implying a service success")
	await _capture(test, "join-friend")
	friends._on_cancel()
	await _settle(test)

	var actions: NRPlayerActions = preload("res://scenes/ui/elements/nr_player_actions.tscn").instantiate()
	actions.setup(99, "Squadmate")
	menu.add_child(actions)
	await _settle(test)
	_assert_surface(test, actions.get_node("Panel"), "player-actions overlay")
	actions._build_report_reasons()
	await _settle(test)
	test._check(actions._actions.get_child_count() == ModerationService.REPORT_REASONS.size(),
		"all platform report reasons still fit the styled overlay")
	_inside(test, actions.get_node("Panel"), "report-reasons panel")
	await _capture(test, "player-actions")
	actions._on_cancel()
	await _settle(test)
	test._check(is_instance_valid(actions) and not actions._reporting,
		"report Back returns to player actions without dismissing the overlay")
	actions._on_cancel()
	await _settle(test)

	var chat: NRChatEntry = preload("res://scenes/ui/elements/nr_chat_entry.tscn").instantiate()
	menu.add_child(chat)
	await _settle(test)
	_assert_surface(test, chat.get_node("Panel"), "chat-entry overlay")
	chat._line_edit.text = "Ready for the next round?"
	await _capture(test, "chat-entry")
	chat._cancel_button.grab_focus()
	await _key(test, KEY_ESCAPE)
	await _settle(test)
	test._check(not is_instance_valid(chat), "chat Back still dismisses the entry")

	var disconnected: ControllerDisconnectOverlay = preload(
		"res://scenes/ui/controller_disconnect_overlay.tscn").instantiate()
	test.add_child(disconnected)
	disconnected.show_prompt()
	await _settle(test)
	_assert_surface(test, disconnected.get_node("Root/Center/Panel"), "controller-disconnect panel")
	test._check(disconnected.visible and disconnected._message.text.contains("reconnect"),
		"controller loss remains a non-dismissable reconnect prompt")
	await _capture(test, "controller-disconnected")
	disconnected.hide_prompt()
	disconnected.queue_free()
	await _settle(test)


func _gameplay_surfaces(test: Node) -> void:
	print("CASE: gameplay HUD, pause, settings and results inherit the designer palette without changing match flow")
	ScreenManager.clear()
	await _settle(test)
	var previous_world := ScreenManager.world_container
	var previous_background := ScreenManager.background_container
	var world := Node2D.new()
	var background := CanvasLayer.new()
	background.layer = -2
	test.add_child(world)
	test.add_child(background)
	ScreenManager.set_world_containers(world, background)
	test._check(NetManager.start_offline(), "HUD fixture starts production Practice with isolated ready saves")
	NetManager.sync_practice_bots(2)
	var game: Variant = ScreenManager.push(ScreenManager.GAMEPLAY)
	await _settle(test)
	test._check(game._world != null and game._roster != null
		and game.get_parent() is CanvasLayer and game._world.get_parent() == world,
		"the styled HUD uses the production canvas/world separation and the real roster")
	for panel: PanelContainer in [game.get_node("HUD/ScorePanel"), game.get_node("HUD/TimerPanel"),
			game.get_node("HUD/StatusPanel"), game._roster]:
		_assert_surface(test, panel, "HUD surface")
		_inside(test, panel, "HUD surface")
	test._check(game._health_bar.max_value == game.SHIP_TUNING.health_max
		and game._shield_bar.max_value == game.SHIP_TUNING.shield_max,
		"HUD bar ranges still come from gameplay tuning")
	game._chat_log.add_message(1, "Pilot One", "Ready for the next round?")
	game._chat_log.add_message(2, "Pilot Two", "Good game!")
	await _settle(test)
	_assert_surface(test, game._chat_log, "match chat")
	await _capture(test, "gameplay-hud")
	await _key(test, KEY_ESCAPE)
	var pause: Variant = ScreenManager.current_screen()
	test._check(pause.scene_file_path == ScreenManager.GAME_MENU,
		"the gameplay menu shortcut still opens pause")
	_assert_surface(test, pause._panel._panel, "pause panel")
	await _capture(test, "pause-menu")
	pause._build_options_rows()
	await _settle(test)
	_inside(test, pause._panel._panel, "in-match Options panel")
	_option_rows_inset(test, pause._menu, "In-match Options")
	await _capture(test, "pause-options")
	await _key(test, KEY_ESCAPE)
	test._check(ScreenManager.current_screen() == pause and not pause._in_options,
		"Options Back still returns to pause without resuming")
	await _key(test, KEY_ESCAPE)
	await _settle(test)
	test._check(ScreenManager.current_screen() == game, "pause Back still resumes gameplay")
	ScreenManager.clear()
	await _settle(test)
	await NetManager.leave_match_and_wait()
	ScreenManager.set_world_containers(previous_world, previous_background)
	world.queue_free()
	background.queue_free()
	await _settle(test)


func _assert_surface(test: Node, control: Control, description: String) -> void:
	var style := control.get_theme_stylebox(&"panel") as StyleBoxFlat
	test._check(style != null and style.corner_radius_top_left >= 12
		and style.corner_radius_bottom_left >= 12, description + " uses the shared rounded surface")


func _branding_textures(test: Node) -> void:
	print("CASE: branding imports are lossless 2x rasters with full mip chains, straight alpha and no seams")
	for key: String in BRANDING_TEXTURES:
		var path: String = BRANDING_TEXTURES[key][0]
		var size: Vector2i = BRANDING_TEXTURES[key][1]
		_assert_import_settings(test, key, path)
		var texture := Assets.texture(key)
		test._check(texture is CompressedTexture2D and texture.resource_path == path,
			key + " is the imported " + path.get_file() + " rather than a placeholder")
		if not (texture is CompressedTexture2D):
			continue
		var image := texture.get_image()
		test._check(Vector2i(texture.get_width(), texture.get_height()) == size
			and image != null and image.get_size() == size, key + " imports at exactly " + str(size))
		test._check(image != null and image.has_mipmaps() and image.get_mipmap_count() == _full_mip_chain(size),
			"%s carries its full %d-level mip chain" % [key, _full_mip_chain(size)])
	for key: String in WORDMARK_SEAM_PROBES:
		var base := _texture_base_level(key)
		if base == null:
			continue
		var raster := _wordmark_raster(base)
		var share: float = raster[0]
		var seams: int = raster[1]
		print("CASE: %s straight-alpha edge share %.3f (min %.2f), seam pixels %d (max %d)" % [
			key, share, MIN_WORDMARK_STRAIGHT_EDGES, seams, MAX_WORDMARK_SEAM_DIPS])
		test._check(share >= MIN_WORDMARK_STRAIGHT_EDGES,
			key + " keeps straight-alpha edge colour instead of premultiplied darkening")
		test._check(seams <= MAX_WORDMARK_SEAM_DIPS,
			key + " has no translucent hairlines between its fill and outline shapes")
		for point: Vector2i in WORDMARK_SEAM_PROBES[key]:
			test._check(Rect2i(Vector2i.ZERO, base.get_size()).has_point(point)
				and base.get_pixelv(point).a >= SEAM_PROBE_MIN_ALPHA,
				"%s fill/outline junction at %s keeps alpha >= %.2f" % [key, point, SEAM_PROBE_MIN_ALPHA])
	var mark := _texture_base_level("Logo_XboxMark")
	if mark != null:
		var white := _white_edge_share(mark)
		print("CASE: Logo_XboxMark white antialiased edge share %.3f (min %.2f)" % [white, MIN_MARK_WHITE_EDGES])
		test._check(white >= MIN_MARK_WHITE_EDGES, "the Xbox mark's antialiased edge stays white")


func _assert_import_settings(test: Node, key: String, path: String) -> void:
	var settings := ConfigFile.new()
	var loaded := settings.load(path + ".import") == OK
	test._check(loaded and settings.get_value("remap", "importer", "") == "texture",
		key + " keeps its repository texture import sidecar")
	var expected := BRANDING_IMPORT_PARAMS.duplicate()
	if path.get_extension() == "svg":
		expected.merge(BRANDING_SVG_IMPORT_PARAMS)
	for param: String in expected:
		var value: Variant = settings.get_value("params", param) if settings.has_section_key("params", param) else null
		test._check(typeof(value) == typeof(expected[param]) and value == expected[param],
			"%s import keeps %s=%s" % [key, param, expected[param]])


## floor(log2(longest side)): halvings until the longest side reaches one pixel.
func _full_mip_chain(size: Vector2i) -> int:
	var levels := 0
	var side := maxi(size.x, size.y) >> 1
	while side > 0:
		levels += 1
		side >>= 1
	return levels


## Mip 0 of a registry texture as RGBA8, or null when it did not import. The renderer may
## return its own image, so it is copied before the mipmaps are cleared.
func _texture_base_level(key: String) -> Image:
	var texture := Assets.texture(key)
	if not (texture is CompressedTexture2D):
		return null
	var image := texture.get_image()
	if image == null:
		return null
	var base := image.duplicate() as Image
	base.clear_mipmaps()
	if base.get_format() != Image.FORMAT_RGBA8:
		base.convert(Image.FORMAT_RGBA8)
	return base


## One pass over mip 0 returning [share of partially covered pixels whose brightest channel
## stays above their coverage, interior pixels whose seam depth exceeds the threshold].
## Thresholds are converted once to 8-bit channel units.
func _wordmark_raster(base: Image) -> Array:
	var data := base.get_data()
	var width := base.get_width()
	var height := base.get_height()
	var stride := width * 4
	var edge_low := WORDMARK_EDGE_MIN_ALPHA * 255.0
	var edge_high := WORDMARK_EDGE_MAX_ALPHA * 255.0
	var margin := STRAIGHT_ALPHA_MARGIN * 255.0
	var depth := SEAM_DEPTH_ALPHA * 255.0
	var edges := 0
	var straight := 0
	var seams := 0
	for y in height:
		var interior_row := y > 0 and y < height - 1
		var offset := y * stride
		for x in width:
			var alpha: int = data[offset + 3]
			if alpha > edge_low and alpha < edge_high:
				edges += 1
				if maxi(maxi(data[offset], data[offset + 1]), data[offset + 2]) > alpha + margin:
					straight += 1
			# min(left, right) or min(up, down) exceeding alpha + depth is a seam pixel.
			if interior_row and x > 0 and x < width - 1:
				var seam_floor := alpha + depth
				if ((data[offset - 1] > seam_floor and data[offset + 7] > seam_floor)
						or (data[offset - stride + 3] > seam_floor and data[offset + stride + 3] > seam_floor)):
					seams += 1
			offset += 4
	return [float(straight) / edges if edges > 0 else 0.0, seams]


func _white_edge_share(base: Image) -> float:
	var data := base.get_data()
	var edge_low := MARK_EDGE_MIN_ALPHA * 255.0
	var edge_high := MARK_EDGE_MAX_ALPHA * 255.0
	var white := MARK_EDGE_WHITE * 255.0
	var edges := 0
	var whites := 0
	for offset in range(0, data.size(), 4):
		var alpha: int = data[offset + 3]
		if alpha > edge_low and alpha < edge_high:
			edges += 1
			if mini(mini(data[offset], data[offset + 1]), data[offset + 2]) >= white:
				whites += 1
	return float(whites) / edges if edges > 0 else 0.0


## Branding on a real screen: production textures on mipmapped keep-aspect logos at every
## supported window. Only window size and layout change, so this also runs headlessly;
## screenshot runs additionally require each capture at exactly the requested size.
func _branding(test: Node, screen: Control, name: String, contract: Dictionary, spinner_path := "") -> void:
	print("CASE: %s branding stays sharp, undistorted and on screen from 960x540 to 3840x2160" % name)
	var logos: Array[TextureRect] = []
	var sizes: Array[Vector2] = []
	for path: String in contract:
		var key: String = contract[path][0]
		var source: String = BRANDING_TEXTURES[key][0]
		var label := name + " " + path
		var logo := screen.get_node_or_null(path) as TextureRect
		test._check(logo != null and logo.texture != null and logo.texture == Assets.texture(key)
			and logo.texture.resource_path == source, label + " shows the production " + source.get_file())
		if logo == null or logo.texture == null:
			continue
		test._check(logo.texture_filter == CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS,
			label + " filters linearly between its mipmaps")
		test._check(logo.expand_mode == TextureRect.EXPAND_IGNORE_SIZE
			and logo.stretch_mode == TextureRect.STRETCH_KEEP_ASPECT_CENTERED,
			label + " fits its art in a fixed logical rect without distortion")
		logos.append(logo)
		sizes.append(contract[path][1])
	var spinner: TextureRect = null
	if not spinner_path.is_empty():
		spinner = screen.get_node_or_null(spinner_path) as TextureRect
		# Hold the animation so captures are reproducible; every size is also checked turned.
		screen.set_process(false)
		if spinner != null:
			spinner.rotation = 0.0
	var window := test.get_tree().root
	for dimensions: Vector2i in BRANDING_WINDOWS:
		window.size = dimensions
		await _settle(test)
		var suffix := "%dx%d" % [dimensions.x, dimensions.y]
		for index in logos.size():
			_assert_branding_fit(test, logos[index], sizes[index], "%s %s at %s" % [name, logos[index].name, suffix])
		await _capture(test, "branding-%s-%s" % [name, suffix], dimensions)
		if spinner != null and logos.has(spinner):
			spinner.rotation = RING_CAPTURE_ROTATION
			_assert_branding_fit(test, spinner, sizes[logos.find(spinner)],
				"%s turned %s at %s" % [name, spinner.name, suffix])
			await _capture(test, "branding-%s-ring45-%s" % [name, suffix], dimensions)
			spinner.rotation = 0.0
	window.size = Vector2i(1920, 1080)
	if not spinner_path.is_empty():
		screen.set_process(true)
	await _settle(test)


## Logical size, viewport containment of the (possibly turned) rect, the aspect of the
## physically drawn art, and a footprint never larger than the imported pixels.
func _assert_branding_fit(test: Node, logo: TextureRect, size: Vector2, label: String) -> void:
	var canvas := logo.get_global_transform_with_canvas()
	test._check(logo.size == size, label + " keeps its logical size")
	test._check(test.get_viewport().get_visible_rect().encloses(canvas * Rect2(Vector2.ZERO, logo.size)),
		label + " stays in the viewport")
	var art := logo.texture.get_size()
	var fitted := logo.size
	if art.aspect() > fitted.aspect():
		fitted.y = fitted.x / art.aspect()
	else:
		fitted.x = fitted.y * art.aspect()
	var drawn := fitted * (test.get_viewport().get_final_transform() * canvas).get_scale()
	test._check(absf(drawn.aspect() / art.aspect() - 1.0) <= BRANDING_ASPECT_TOLERANCE,
		label + " draws at its texture aspect")
	test._check(drawn.x <= art.x + BRANDING_PIXEL_SLACK and drawn.y <= art.y + BRANDING_PIXEL_SLACK,
		label + " is never magnified past its imported pixels")


## Waves screens use the designer TextureRect with the motion adapter. Until motion
## is warmed and enabled (never in this suite) it is that TextureRect alone: no material, no dots.
func _waves_background(test: Node, screen: Control, name: String) -> void:
	var background := screen.get_node_or_null("Background") as TextureRect
	test._check(background != null and _script_path(background) == WAVES_ADAPTER,
		name + " Background is the Waves TextureRect with the motion adapter")
	if background != null and not UIBackgroundMotion.effective_enabled():
		test._check(background.material == null and background.get_child_count() == 0,
			name + " Waves Background draws only its static texture while motion is off")
	await _background(test, screen, name, "Background_Waves")


## Title and lobby draw the design's radial glow in code: a full-rect, input-transparent #050505
## ColorRect with the glow adapter's analytic shader and no PNG. The shader samples the same
## centred 1920x1080 cover crop that the textured backgrounds keep.
func _glow_background(test: Node, screen: Control, name: String) -> void:
	print("CASE: %s glow is drawn in code and covers 16:9, 16:10, 4:3 and ultrawide windows" % name)
	var background := screen.get_node_or_null("Background") as ColorRect
	test._check(background != null and _script_path(background) == GLOW_ADAPTER,
		name + " Background is a ColorRect with the analytic glow adapter")
	if background == null:
		return
	test._check(background.color.is_equal_approx(BACKGROUND_BASE)
		and background.mouse_filter == Control.MOUSE_FILTER_IGNORE
		and background.anchor_left == 0.0 and background.anchor_top == 0.0
		and background.anchor_right == 1.0 and background.anchor_bottom == 1.0,
		name + " glow is a full-rect, input-transparent #050505 base")
	var glow_material := background.material as ShaderMaterial
	test._check(glow_material != null and glow_material.shader != null
		and glow_material.shader.resource_path == GLOW_SHADER, name + " glow uses the analytic shader")
	test._check(not FileAccess.get_file_as_string(screen.scene_file_path).contains("Background_Glow")
		and not _draws_texture_from(screen, "Background_Glow"), name + " uses no Glow PNG")
	var window := test.get_tree().root
	for dimensions: Vector2i in BRANDING_WINDOWS + BACKGROUND_EXTRA_WINDOWS:
		window.size = dimensions
		await _settle(test)
		var label := "%s glow at %dx%d" % [name, dimensions.x, dimensions.y]
		var canvas := background.get_global_transform_with_canvas()
		var covered := (canvas * Rect2(Vector2.ZERO, background.size)).grow(BACKGROUND_PIXEL_TOLERANCE)
		test._check(covered.encloses(test.get_viewport().get_visible_rect()), label + " covers the whole viewport")
		var expected: Rect2 = BACKGROUND_CROPS.get(dimensions, Rect2(Vector2.ZERO, BACKGROUND_DESIGN_SIZE))
		var region := _glow_region(glow_material)
		test._check(_rect_near(region, expected, BACKGROUND_PIXEL_TOLERANCE),
			"%s samples design region %s (expected %s)" % [label, region, expected])
	window.size = Vector2i(1920, 1080)
	await _settle(test)


## Design-space rectangle the glow shader samples: cover_xform maps UV to UV * xy + zw, in
## fractions of the design size.
func _glow_region(glow_material: ShaderMaterial) -> Rect2:
	if glow_material == null:
		return Rect2()
	var cover: Variant = glow_material.get_shader_parameter(&"cover_xform")
	if not (cover is Vector4):
		return Rect2()
	var xform: Vector4 = cover
	return Rect2(xform.z * BACKGROUND_DESIGN_SIZE.x, xform.w * BACKGROUND_DESIGN_SIZE.y,
		xform.x * BACKGROUND_DESIGN_SIZE.x, xform.y * BACKGROUND_DESIGN_SIZE.y)


## The PDF's ship card is drawn in code behind the clipped preview Panel. The Panel keeps the ship
## sprites, its clipping and its outline; its theme fill is the opaque fallback without the shader.
func _ship_card(test: Node, lobby: Control) -> void:
	print("CASE: lobby ship card is the design's opaque rounded card drawn in code behind the clipped preview")
	var card := lobby.get_node_or_null("%ShipBackground") as NRShipCard
	test._check(card != null and card.clip_contents and card.theme_type_variation == &"LobbyShipPreview"
		and card.mouse_filter == Control.MOUSE_FILTER_IGNORE,
		"the preview Panel keeps its clipping, theme variation and input transparency")
	if card == null:
		return
	var fill := card.get_node_or_null("ShipCardFill") as ColorRect
	test._check(fill != null and card.get_child(0) == fill and fill.show_behind_parent
		and fill.mouse_filter == Control.MOUSE_FILTER_IGNORE
		and card.get_node_or_null("ShipTexture") != null and card.get_node_or_null("ShipOverlay") != null,
		"the card fill draws behind the Panel, which still hosts and clips the ship sprites")
	if fill == null:
		return
	var fill_material := fill.material as ShaderMaterial
	test._check(card.is_shader_fill() and fill.visible and fill_material != null and fill_material.shader != null
		and fill_material.shader.resource_path == SHIP_CARD_SHADER, "the card fill uses the ship card shader")
	if fill_material != null:
		var rect_size: Variant = fill_material.get_shader_parameter(&"rect_size")
		test._check(rect_size is Vector2 and card.size.is_equal_approx(rect_size)
			and fill_material.get_shader_parameter(&"corner_radius") == 12.0
			and fill_material.get_shader_parameter(&"aa_size") == 1.0
			and fill_material.get_shader_parameter(&"corner_detail") == 8.0,
			"the card shader takes the card size and the outline's corner settings")
	test._check(fill.position.is_equal_approx(Vector2(-0.5, -0.5)) and fill.size.is_equal_approx(card.size + Vector2.ONE),
		"the fill reaches half the anti-aliasing ramp past the Panel, whose clip trims it with the outline")
	var outline := card.get_theme_stylebox(&"panel") as StyleBoxFlat
	test._check(outline != null and not outline.draw_center
		and outline.border_color.is_equal_approx(Color(1, 1, 1, 0.15))
		and outline.border_width_left == 1 and outline.border_width_top == 1
		and outline.border_width_right == 1 and outline.border_width_bottom == 1
		and outline.corner_radius_top_left == 0 and outline.corner_radius_top_right == 0
		and outline.corner_radius_bottom_left == 12 and outline.corner_radius_bottom_right == 12,
		"over the shader fill the Panel draws only the design's white 0.15, 1 px outline with 12 px bottom corners")
	var theme := load(UI_THEME) as Theme
	var theme_style: StyleBoxFlat = null
	if theme != null:
		theme_style = theme.get_stylebox(&"panel", &"LobbyShipPreview") as StyleBoxFlat
	test._check(theme_style != null and theme_style.draw_center and theme_style.bg_color.is_equal_approx(BACKGROUND_BASE),
		"the theme's own card style stays an opaque #050505 fallback fill")
	card.use_shader = false
	var fallback := card.get_theme_stylebox(&"panel") as StyleBoxFlat
	test._check(not card.is_shader_fill() and not fill.visible and fill.material == null
		and fallback != null and fallback.draw_center and fallback.bg_color.a == 1.0,
		"without the shader the card keeps the opaque theme fill")
	card.use_shader = true
	test._check(card.is_shader_fill() and fill.visible, "the shader fill returns when it is available")
	var sprites_smoothed := true
	for layer_name: String in ["ShipTexture", "ShipOverlay"]:
		var layer := card.get_node_or_null(layer_name) as TextureRect
		var layer_material := layer.material as ShaderMaterial if layer != null else null
		sprites_smoothed = sprites_smoothed and layer_material != null and layer_material.shader != null \
			and layer_material.shader.resource_path == SHIP_PREVIEW_SHADER
	test._check(sprites_smoothed, "both enlarged ship layers draw through the ship preview shader")


## Spinner and slider rows inset their text and controls from the row's edge, where the focus
## outline is drawn, and the slider row leaves its value room even in the narrower in-match panel.
func _option_rows_inset(test: Node, list: NRMenuList, label: String) -> void:
	var rows := 0
	var inset := true
	var values_fit := true
	for row: Control in list.rows():
		if not (row is NRSpinner or row is NRSlider):
			continue
		rows += 1
		var bounds := row.get_global_rect()
		var content := row.get_node("Row") as HBoxContainer
		var first := content.get_child(0) as Control
		var last := content.get_child(content.get_child_count() - 1) as Control
		inset = inset and first.get_global_rect().position.x >= bounds.position.x + OPTION_ROW_MIN_LEFT_INSET \
			and last.get_global_rect().end.x <= bounds.end.x - OPTION_ROW_MIN_RIGHT_INSET
		var value := row.get_node("%ValueLabel") as Label
		var needed := value.get_theme_font(&"font").get_string_size(value.text, HORIZONTAL_ALIGNMENT_LEFT, -1,
			value.get_theme_font_size(&"font_size")).x
		values_fit = values_fit and needed <= value.size.x + 0.5
	test._check(rows > 0 and inset, label + " rows keep their text and controls inside the focus outline")
	test._check(rows > 0 and values_fit, label + " row values fit without clipping")


func _script_path(node: Object) -> String:
	var script := node.get_script() as Script
	return script.resource_path if script != null else ""


func _draws_texture_from(root: Node, needle: String) -> bool:
	for node: Node in root.find_children("*", "TextureRect", true, false):
		var texture := (node as TextureRect).texture
		if texture != null and texture.resource_path.contains(needle):
			return true
	return false


## A screen's root background covers every supported window, 4:3 included, with uniformly
## scaled texels from a centred crop of its art. Layout only, so this also runs headlessly.
func _background(test: Node, screen: Control, name: String, key: String) -> void:
	print("CASE: %s background covers 16:9, 16:10, 4:3 and ultrawide windows without distortion" % name)
	var background := screen.get_node_or_null("Background") as TextureRect
	test._check(background != null and background.texture != null, name + " has a textured root Background")
	if background == null or background.texture == null:
		return
	var window := test.get_tree().root
	for dimensions: Vector2i in BRANDING_WINDOWS + BACKGROUND_EXTRA_WINDOWS:
		window.size = dimensions
		await _settle(test)
		_assert_background_cover(test, background, key, dimensions,
			"%s Background at %dx%d" % [name, dimensions.x, dimensions.y])
	window.size = Vector2i(1920, 1080)
	await _settle(test)


func _assert_background_cover(test: Node, background: TextureRect, key: String, dimensions: Vector2i,
		label: String) -> void:
	test._check(background.texture == Assets.texture(key), label + " shows the registry's " + key)
	test._check(background.expand_mode == TextureRect.EXPAND_IGNORE_SIZE, label + " ignores its texture size")
	test._check(background.stretch_mode == TextureRect.STRETCH_KEEP_ASPECT_COVERED,
		label + " crops with KEEP_ASPECT_COVERED instead of stretching")
	# Node rect and visible rect are both in the screens layer's canvas space.
	var canvas := background.get_global_transform_with_canvas()
	var covered := (canvas * Rect2(Vector2.ZERO, background.size)).grow(BACKGROUND_PIXEL_TOLERANCE)
	test._check(covered.encloses(test.get_viewport().get_visible_rect()), label + " covers the whole viewport")
	var screen_scale := (test.get_viewport().get_final_transform() * canvas).get_scale()
	test._check(absf(screen_scale.x / screen_scale.y - 1.0) <= BACKGROUND_SCALE_TOLERANCE,
		label + " has a uniform effective transform scale")
	var region := _background_region(background)
	var texel_scale := screen_scale * background.size / region.size
	test._check(absf(texel_scale.x / texel_scale.y - 1.0) <= BACKGROUND_SCALE_TOLERANCE,
		label + " draws its texels at a uniform scale")
	var texture_size := background.texture.get_size()
	var off_centre := (region.position * 2.0 + region.size - texture_size).abs()
	test._check(maxf(off_centre.x, off_centre.y) <= BACKGROUND_PIXEL_TOLERANCE,
		label + " crops a centred source region")
	var expected: Rect2 = BACKGROUND_CROPS.get(dimensions, Rect2(Vector2.ZERO, texture_size))
	test._check(_rect_near(region, expected, BACKGROUND_PIXEL_TOLERANCE),
		"%s keeps source texels %s (expected %s)" % [label, region, expected])


## Source rectangle a full-rect background samples, mirroring Godot's TextureRect drawing in
## scene/gui/texture_rect: SCALE samples the whole texture, while KEEP_ASPECT_COVERED scales by
## max(size / texture) and samples size / scale texels offset by |texture * scale - size| / scale / 2.
func _background_region(background: TextureRect) -> Rect2:
	var texture_size := background.texture.get_size()
	if background.stretch_mode != TextureRect.STRETCH_KEEP_ASPECT_COVERED:
		return Rect2(Vector2.ZERO, texture_size)
	var cover := maxf(background.size.x / texture_size.x, background.size.y / texture_size.y)
	return Rect2(((texture_size * cover - background.size) / cover).abs() / 2.0, background.size / cover)


func _rect_near(actual: Rect2, expected: Rect2, tolerance: float) -> bool:
	var start := (actual.position - expected.position).abs()
	var finish := (actual.end - expected.end).abs()
	return maxf(maxf(start.x, start.y), maxf(finish.x, finish.y)) <= tolerance


func _settle(test: Node) -> void:
	await test.get_tree().process_frame
	await test.get_tree().process_frame


func _key(test: Node, key: Key, ctrl := false, shift := false) -> void:
	var event := InputEventKey.new()
	event.keycode = key
	event.physical_keycode = key
	event.ctrl_pressed = ctrl
	event.shift_pressed = shift
	event.pressed = true
	test.get_viewport().push_input(event, true)
	event = event.duplicate()
	event.pressed = false
	test.get_viewport().push_input(event, true)
	await _settle(test)


func _joy(test: Node, button: JoyButton) -> void:
	var event := InputEventJoypadButton.new()
	event.button_index = button
	event.pressed = true
	test.get_viewport().push_input(event, true)
	event = event.duplicate()
	event.pressed = false
	test.get_viewport().push_input(event, true)
	await _settle(test)


func _inside(test: Node, control: Control, description: String) -> void:
	test._check(test.get_viewport().get_visible_rect().encloses(control.get_global_rect()), description + " stays in the viewport")


## True once RenderingServer reports `count` drawn frames, false when `timeout_msec` passes on the
## monotonic clock first. It never awaits frame_post_draw itself, so a window that stops drawing
## fails the case instead of hanging the suite, and the counter is always disconnected.
func _drawn_frames(test: Node, count: int, timeout_msec: int) -> bool:
	var drawn := [0]
	var counter := func() -> void: drawn[0] += 1
	RenderingServer.frame_post_draw.connect(counter)
	var deadline := Time.get_ticks_msec() + timeout_msec
	while drawn[0] < count and Time.get_ticks_msec() < deadline:
		await test.get_tree().process_frame
	RenderingServer.frame_post_draw.disconnect(counter)
	return drawn[0] >= count


## Acquisition and loading name the session pause shortcut in a hint that takes no input, stays
## legible over the animated backdrop and sits inside title-safe at every window shape. The hint
## shows only while the shortcut can act; nothing warms motion in this suite, so it is hidden here.
func _motion_hint(test: Node, screen: Control, name: String) -> void:
	print("CASE: %s motion hint names Ctrl+Shift+M / View in its MotionHint style inside title-safe" % name)
	var hint := screen.find_child("MotionHintLabel", true, false) as Label
	test._check(hint != null and hint.text == MOTION_HINT_TEXT
		and UIBackgroundMotion.pause_shortcut_label() == "Ctrl+Shift+M / View"
		and hint.mouse_filter == Control.MOUSE_FILTER_IGNORE and hint.focus_mode == Control.FOCUS_NONE,
		name + " names the PC shortcut, Ctrl+Shift+M / View, without taking input or focus")
	test._check(hint != null and not UIBackgroundMotion.shortcut_available() and not hint.is_visible_in_tree(),
		name + " hides the motion hint while the shortcut cannot act (motion disabled)")
	if hint == null:
		return
	test._check(hint.theme_type_variation == &"MotionHint" and _opaque_in_tree(hint)
		and hint.get_theme_color(&"font_color").a == 1.0
		and hint.get_theme_font_size(&"font_size") >= MOTION_HINT_MIN_FONT_SIZE,
		"%s motion hint uses MotionHint: opaque text of at least %d px with no translucent modulate"
			% [name, MOTION_HINT_MIN_FONT_SIZE])
	var window := test.get_tree().root
	for dimensions: Vector2i in BRANDING_WINDOWS:
		window.size = dimensions
		await _settle(test)
		var viewport_rect := test.get_viewport().get_visible_rect()
		var inset := viewport_rect.size * TITLE_SAFE_MARGIN
		var safe := viewport_rect.grow_individual(-inset.x, -inset.y, -inset.x, -inset.y)
		test._check(safe.grow(TITLE_SAFE_SLACK).encloses(hint.get_global_rect()),
			"%s motion hint stays inside the 90 %% title-safe area at %dx%d" % [name, dimensions.x, dimensions.y])
	window.size = Vector2i(1920, 1080)
	await _settle(test)


## True when neither the item nor any CanvasItem above it is translucent.
func _opaque_in_tree(item: CanvasItem) -> bool:
	if item.self_modulate.a < 1.0:
		return false
	var node: Node = item
	while node is CanvasItem:
		if (node as CanvasItem).modulate.a < 1.0:
			return false
		node = node.get_parent()
	return true


func _capture(test: Node, name: String, expected_size := Vector2i.ZERO) -> void:
	var folder := OS.get_environment("NR_UI_SCREENSHOT_ROOT")
	if folder.is_empty():
		return
	if not await _drawn_frames(test, 1, FRAME_TIMEOUT_MSEC):
		test._check(false, "a frame was drawn for screenshot %s within %d ms" % [name, FRAME_TIMEOUT_MSEC])
		return
	var image := test.get_viewport().get_texture().get_image()
	if image == null or image.is_empty():
		test._check(false, "rendered screenshot exists: " + name)
		return
	if expected_size != Vector2i.ZERO:
		test._check(image.get_size() == expected_size,
			"screenshot %s renders the requested %s window (got %s)" % [name, expected_size, image.get_size()])
	test._check(image.save_png(folder.path_join(name + ".png")) == OK, "write UI screenshot: " + name)
