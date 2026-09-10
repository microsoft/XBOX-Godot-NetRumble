class_name GameModeConfig
extends Resource

## A selectable game mode. Replaces the nested `GAME_MODES` dictionary that used to
## live in `nr_const.gd`, so player counts and score targets are editable in the
## inspector.

@export var mode_type: NRTypes.GameModeType = NRTypes.GameModeType.DEATHMATCH
@export var display_name: String = "Deathmatch"

@export_group("Rules")
@export var player_count: int = 4
@export var target_score: int = 5
## Match length in seconds.
@export var time_limit: float = 600.0
