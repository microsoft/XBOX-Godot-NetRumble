class_name GameplayEventLibrary
extends Resource

## Editor-authored mapping from GameplayEventType to one-shot effect scenes.
## Assign entries in the Inspector; `World.emit_gameplay_event` looks up and
## instantiates the matching scene at the event position.

@export var effects: Dictionary[int, PackedScene] = {}
