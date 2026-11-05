extends Label

## The platform shortcut is shown only while it can pause or resume a background family.


func _enter_tree() -> void:
	if not UIBackgroundMotion.state_changed.is_connected(_sync_visibility):
		UIBackgroundMotion.state_changed.connect(_sync_visibility)
	_sync_visibility()


func _exit_tree() -> void:
	if UIBackgroundMotion.state_changed.is_connected(_sync_visibility):
		UIBackgroundMotion.state_changed.disconnect(_sync_visibility)


func _sync_visibility() -> void:
	text = "%s pauses background motion" % UIBackgroundMotion.pause_shortcut_label()
	visible = UIBackgroundMotion.shortcut_available()
