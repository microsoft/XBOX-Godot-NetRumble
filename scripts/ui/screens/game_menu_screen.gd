extends NRScreen

## The in-match pause popup. Declared a popup so the gameplay screen beneath stays
## visible. Offers Resume / Options / Leave Match; both ui_back_action and
## toggle_game_menu resume.
##
## Options is not a screen: like the main menu's join submenu, it swaps the panel's rows
## in place (NROptionsRows, shared with the main menu), and while those rows are showing
## both back actions return to the pause rows rather than resuming the match.

## Panel sizes for the two row sets. Both are sized so their rows, list margins and the
## panel border fit without scrolling.
const _MENU_PANEL_SIZE := Vector2(620.0, 330.0)
const _OPTIONS_PANEL_SIZE := Vector2(780.0, 950.0)

@onready var _panel: NRMenuPanel = $MenuPanel
@onready var _menu: NRMenuList = ($MenuPanel as NRMenuPanel).menu_list()

var _in_options := false


func _init() -> void:
	is_popup = true


func _ready() -> void:
	super._ready()
	_build_menu_rows()


func _build_menu_rows() -> void:
	_in_options = false
	_panel.title = "Menu"
	_panel.panel_size = _MENU_PANEL_SIZE
	_menu.clear_rows()
	_menu.add_button("Resume", func() -> void: ScreenManager.pop())
	_menu.add_button("Options", _build_options_rows)
	_menu.add_button("Leave Match", _on_leave)
	focus_menu_list(_menu)


func _build_options_rows() -> void:
	_in_options = true
	_panel.title = "Options"
	_panel.panel_size = _OPTIONS_PANEL_SIZE
	_menu.clear_rows()
	NROptionsRows.populate(_menu)
	_menu.add_button("Back", _on_options_back)
	focus_menu_list(_menu)


## Settings apply live, so leaving the rows is what commits them.
func _on_options_back() -> void:
	NROptionsRows.save()
	_build_menu_rows()


func _on_leave() -> void:
	var confirmed: bool = await ScreenManager.show_dialog("Leave Match", "Leave the current match?", "warning", true)
	if not confirmed:
		return
	NetManager.leave_match()
	ScreenManager.replace_all(ScreenManager.MAIN_MENU)


func _unhandled_input(event: InputEvent) -> void:
	if not is_active:
		return
	if event.is_action_pressed("toggle_game_menu"):
		get_viewport().set_input_as_handled()
		if _in_options:
			_on_options_back()
		else:
			ScreenManager.pop()
		return
	super._unhandled_input(event)


## Back closes the settings rows first; only the pause rows resume the match.
func on_back_pressed() -> void:
	if _in_options:
		_on_options_back()
		return
	super.on_back_pressed()
