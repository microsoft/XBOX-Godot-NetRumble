class_name NRRosterOverlay
extends PanelContainer

## A Discord-style in-match player list (name + score + mic-state icon) shown top-left.
## Rows are rebuilt from the supplied PlayerState list. `mic_states` maps peer_id to one
## of "available"/"muted"/"talking"/"none"; "none" hides the icon.

const MAX_PLAYERS := 8
const ROW_HEIGHT := 36.0
const ICON_SIZE := 24.0
const ICON_NAME_GAP := 8.0
## A fixed score column at an absolute x offset leaves a wide empty gutter between
## short names and their scores, so instead the name and score columns are measured
## from what is actually on screen and the score follows the longest name. Names wider
## than what is left over are ellipsised rather than allowed to push the score off the
## panel. 280px (MAX_ROW_WIDTH) is the outer limit the roster may never exceed.
const MAX_ROW_WIDTH := 280.0
const NAME_SCORE_GAP := 16.0
## The score column is measured, but never narrower than a two-digit score: scores
## change constantly and a column that resized on every point would jitter the panel.
const MIN_SCORE_WIDTH := 24.0
const MAX_SCORE_WIDTH := 64.0
const FONT_SIZE := 16

## Breathing room between the panel border and the rows, so the right-aligned score
## is not flush against the panel border.
const PANEL_PADDING_X := 12.0
const PANEL_PADDING_Y := 6.0

## Row-local x of the name column, after the mic icon.
const NAME_X := ICON_SIZE + ICON_NAME_GAP
## Widest a name can ever be, i.e. against the widest possible score column.
const MAX_NAME_WIDTH := MAX_ROW_WIDTH - NAME_X - NAME_SCORE_GAP - MAX_SCORE_WIDTH

var _rows: Control = null


func _ready() -> void:
	_apply_panel_padding()
	_rows = %Rows
	_apply_rows_size(MAX_ROW_WIDTH, 0)


## Rebuilds the roster from the score-sorted player list. `mic_states` optionally maps
## peer_id -> one of "available"/"muted"/"talking"/"none".
func refresh(players: Array[PlayerState], mic_states: Dictionary = {}) -> void:
	for child in _rows.get_children():
		child.free()

	var shown := 0
	var built: Array[Control] = []
	for player in players:
		if shown >= MAX_PLAYERS:
			break
		var row := _make_row(player, String(mic_states.get(player.peer_id, "none")))
		row.position = Vector2(0.0, ROW_HEIGHT * shown)
		_rows.add_child(row)
		built.append(row)
		shown += 1

	_apply_columns(built)


## Places the score column just after the longest name in the roster, and sizes every
## row to match so the whole overlay hugs its content. Both columns are shared by all
## rows rather than measured per row: a score that shifted from row to row would not
## read as a column at all.
func _apply_columns(rows: Array[Control]) -> void:
	var name_width := 0.0
	var score_width := MIN_SCORE_WIDTH
	for row in rows:
		var name_label: Label = row.get_node("NameLabel")
		var score_label: Label = row.get_node("ScoreLabel")
		name_width = maxf(name_width, _text_width(name_label))
		score_width = maxf(score_width, _text_width(score_label))
	score_width = minf(score_width, MAX_SCORE_WIDTH)
	name_width = clampf(name_width, 0.0, MAX_ROW_WIDTH - NAME_X - NAME_SCORE_GAP - score_width)

	var row_width := NAME_X + name_width + NAME_SCORE_GAP + score_width
	for row in rows:
		row.custom_minimum_size = Vector2(row_width, ROW_HEIGHT)
		row.size = row.custom_minimum_size
		var name_label: Label = row.get_node("NameLabel")
		name_label.size = Vector2(name_width, ROW_HEIGHT)
		var score_label: Label = row.get_node("ScoreLabel")
		score_label.position = Vector2(row_width - score_width, 0.0)
		score_label.size = Vector2(score_width, ROW_HEIGHT)

	_apply_rows_size(row_width, rows.size())


## The panel wraps Rows, so its size has to follow the roster actually listed. Sizing it
## for MAX_PLAYERS regardless left an empty bordered box hanging below the roster in
## every match that was not full. An empty roster hides the panel's own background
## rather than drawing a bare border; self_modulate is used instead of `visible`
## because the screen owns that, driven by the show-roster setting.
func _apply_rows_size(row_width: float, shown: int) -> void:
	_rows.custom_minimum_size = Vector2(row_width, ROW_HEIGHT * float(shown))
	_rows.size = _rows.custom_minimum_size
	# A Control outside a Container never shrinks on its own when its minimum size
	# drops, so the panel has to be told to re-fit or it keeps the largest roster's box.
	reset_size()
	self_modulate.a = 1.0 if shown > 0 else 0.0


func _make_row(player: PlayerState, mic_state: String) -> Control:
	var row := Control.new()
	row.custom_minimum_size = Vector2(MAX_ROW_WIDTH, ROW_HEIGHT)
	row.size = row.custom_minimum_size
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var mic := TextureRect.new()
	mic.name = "Mic"
	mic.texture = _mic_texture(mic_state)
	mic.position = Vector2(0.0, (ROW_HEIGHT - ICON_SIZE) * 0.5)
	mic.size = Vector2(ICON_SIZE, ICON_SIZE)
	mic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	mic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	mic.visible = mic_state != "none"
	mic.modulate = _palette_color(&"dialog_title_error", Color.RED) if mic_state == "muted" \
		else _palette_color(&"neutral", Color(0.74, 0.78, 0.78, 0.66))
	row.add_child(mic)
	_fit_icon_to_source(mic)

	var name_label := Label.new()
	name_label.name = "NameLabel"
	name_label.text = player.display_label()
	name_label.position = Vector2(NAME_X, 0.0)
	# Final width comes from _apply_columns once every name in the roster is measured.
	name_label.size = Vector2(MAX_NAME_WIDTH, ROW_HEIGHT)
	name_label.clip_text = true
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_label.add_theme_font_size_override("font_size", FONT_SIZE)
	row.add_child(name_label)

	var score_label := Label.new()
	score_label.name = "ScoreLabel"
	score_label.text = str(player.score)
	# The score column is finalised in _apply_columns, once the roster is measured.
	score_label.position = Vector2(MAX_ROW_WIDTH - MAX_SCORE_WIDTH, 0.0)
	score_label.size = Vector2(MAX_SCORE_WIDTH, ROW_HEIGHT)
	score_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	score_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	score_label.add_theme_font_size_override("font_size", FONT_SIZE)
	score_label.theme_type_variation = &"AccentLabel"
	row.add_child(score_label)
	return row


## Replaces the theme's panel margins with the roster's own padding, so the content is
## inset from the border by a known amount rather than whatever the shared style says.
func _apply_panel_padding() -> void:
	var panel: StyleBox = get_theme_stylebox("panel")
	if panel == null:
		return
	var padded_panel: StyleBox = panel.duplicate() as StyleBox
	padded_panel.content_margin_left = PANEL_PADDING_X
	padded_panel.content_margin_top = PANEL_PADDING_Y
	padded_panel.content_margin_right = PANEL_PADDING_X
	padded_panel.content_margin_bottom = PANEL_PADDING_Y
	add_theme_stylebox_override("panel", padded_panel)


## Width the row's name actually needs. Label.get_minimum_size() reports no width once
## clip_text is on, so the font is asked directly.
func _text_width(label: Label) -> float:
	var font: Font = label.get_theme_font(&"font")
	if font == null:
		return 0.0
	return font.get_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, FONT_SIZE).x


func _fit_icon_to_source(mic: TextureRect) -> void:
	var source_size := Vector2(ICON_SIZE, ICON_SIZE)
	if mic.texture != null:
		source_size = mic.texture.get_size()
	mic.size = source_size
	mic.scale = Vector2(ICON_SIZE / source_size.x, ICON_SIZE / source_size.y)


func _palette_color(color_name: StringName, fallback: Color) -> Color:
	if has_theme_color(color_name, &"NRPalette"):
		return get_theme_color(color_name, &"NRPalette")
	return fallback


func _mic_texture(state: String) -> Texture2D:
	match state:
		"muted":
			return Assets.texture("Microphone_Muted")
		"talking":
			return Assets.texture("Microphone_Talking")
		_:
			return Assets.texture("Microphone_Available")
