class_name PlayerPalette
extends Resource

## The selectable ship tints and their display names. Replaces
## `Assets.player_color()` / `Assets.player_color_name()`.
##
## `colors` and `names` are parallel arrays; keep them the same length.

@export var colors: Array[Color] = []
@export var names: Array[String] = []


func size() -> int:
	return colors.size()


## Wraps out-of-range ids so a stale saved colour id can never crash the game.
func color_at(index: int) -> Color:
	if colors.is_empty():
		return Color.WHITE
	return colors[posmod(index, colors.size())]


func name_at(index: int) -> String:
	if names.is_empty():
		return ""
	return names[posmod(index, names.size())]
