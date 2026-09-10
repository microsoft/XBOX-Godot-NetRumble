class_name ControllerDisconnectOverlay
extends CanvasLayer

## The "reconnect your controller" prompt (XR-115).
##
## Deliberately not a ScreenManager dialog, and the reason is the whole point of the
## feature: a dialog is dismissed by pressing a button, and the player has nothing to
## press it with. So this is its own CanvasLayer above the screen stack, it takes no
## input at all, and it has no focusable controls -- nothing about it can trap a player
## who is holding a dead pad. It comes down when the controller comes back, and that is
## the only way it comes down.
##
## It also does not pause anything. A networked match cannot stop because one player
## unplugged something, and having practice behave differently would mean the disconnect
## path was only ever exercised in the easy case. The simulation keeps running underneath
## in every mode; the player's ship simply stops taking input, which is already what
## happens to a ship whose owner is idle.

@onready var _message: Label = %MessageLabel


func _ready() -> void:
	# Above the Guide-driven pause too: the platform can constrain the title while this
	# is up, and the prompt has to survive it to still be there on the way back.
	process_mode = Node.PROCESS_MODE_ALWAYS
	hide()


func show_prompt() -> void:
	_message.text = "Please reconnect your controller to continue."
	show()


func hide_prompt() -> void:
	hide()
