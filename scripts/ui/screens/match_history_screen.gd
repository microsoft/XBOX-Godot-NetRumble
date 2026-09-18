extends NRScreen

## The local player's recent matches.
##
## Every row comes from `Services.get_match_history()`, which is already in memory —
## the history is loaded from the Game Save folder at sign-in — so this screen never
## touches storage itself and works offline.

@onready var _list: NRMenuList = %MenuList


func _ready() -> void:
	super._ready()
	Services.account_lost.connect(_on_account_lost)
	_rebuild()


func _on_account_lost() -> void:
	_list.clear_rows()


## Rebuilds the whole list so there is a single NRMenuList and focus wrap-around stays
## correct. Services supplies a synchronous deep snapshot for the ready account.
func _rebuild() -> void:
	_list.clear_rows()
	if not Services.is_account_ready():
		_list.add_note("Sign in and load your saved data to view match history.")
		_list.add_button("Back", on_back_pressed)
		focus_menu_list(_list)
		return

	var rows := _load_rows()
	for row in rows:
		# Entries stay focusable buttons even though they do nothing: focus is what
		# scrolls the ScrollContainer on a gamepad, so unfocusable rows would be
		# unreachable once a list runs past one screenful.
		_list.add_button(row, Callable())
	if rows.is_empty():
		_list.add_note("No match history yet.")
	_list.add_button("Back", on_back_pressed)
	focus_menu_list(_list)


func _load_rows() -> PackedStringArray:
	var rows := PackedStringArray()
	var matches: Variant = Services.get_match_history()
	if not (matches is Array):
		return rows
	for entry in matches as Array:
		rows.append(_format_match(entry))
	return rows


## Services stores match rows as date/game_mode/score/placement/player_count. The screen
## shows what the store actually holds; `winner` and `time` are not recorded, so they
## are omitted rather than printing placeholder text for every entry.
func _format_match(entry: Dictionary) -> String:
	var parts := PackedStringArray()
	var date := str(entry.get("date", ""))
	if not date.is_empty():
		parts.append(date)
	var mode := str(entry.get("game_mode", ""))
	if not mode.is_empty():
		parts.append(mode)
	parts.append("Score %d" % int(entry.get("score", 0)))
	var placement := int(entry.get("placement", 0))
	var players := int(entry.get("player_count", 0))
	if placement > 0 and players > 0:
		parts.append("%s of %d" % [_ordinal(placement), players])
	return " - ".join(parts)


func _ordinal(value: int) -> String:
	# 11-13 are the exception to the 1st/2nd/3rd suffix rule.
	if value % 100 >= 11 and value % 100 <= 13:
		return "%dth" % value
	match value % 10:
		1:
			return "%dst" % value
		2:
			return "%dnd" % value
		3:
			return "%drd" % value
	return "%dth" % value
