class_name NROptionsRows

## The Options settings rows: Graphics / Audio / Gameplay / Online & Social /
## Accessibility. Controls are not represented — input mapping lives in project.godot
## and is not rebindable, so there is nothing to configure there.
##
## All settings pages share the same structure — a label, a spinner or slider per
## setting — so splitting them into separate screens would multiply scenes without
## adding anything. Four of the pages carry only one setting, so reaching a single
## toggle would cost two navigations if each were its own screen.
##
## Instead, these rows are appended straight into whichever NRMenuList opened them —
## the main menu's list or the in-match pause panel's — so Options is a mode of the
## menu the player is already in rather than a screen of its own. The rows inherit the
## host list's look, and the host keeps its own background.
##
## Settings apply live (each row writes straight to PlayerProfile and marks it dirty);
## `save()` is what the host calls when the player leaves the rows.


## Appends every settings row to `list`. The host adds its own Back row afterwards, so
## Back is always last regardless of who opened the list.
static func populate(list: NRMenuList) -> void:
	list.add_header("Graphics")
	list.add_bool_spinner("Fullscreen", PlayerProfile.fullscreen, func(value: bool) -> void:
		PlayerProfile.fullscreen = value
		PlayerProfile.mark_dirty()
		PlayerProfile.apply_display_settings())

	# AudioManager pulls master/music/sfx out of PlayerProfile on mark_dirty(), so the
	# mixer follows these rows immediately rather than on save.
	list.add_header("Audio")
	list.add_percent_spinner("Master Volume", PlayerProfile.master_volume, func(value: float) -> void:
		PlayerProfile.master_volume = value
		PlayerProfile.mark_dirty())
	list.add_percent_spinner("Music Volume", PlayerProfile.music_volume, func(value: float) -> void:
		PlayerProfile.music_volume = value
		PlayerProfile.mark_dirty())
	list.add_percent_spinner("Sound Effects Volume", PlayerProfile.sfx_volume, func(value: float) -> void:
		PlayerProfile.sfx_volume = value
		PlayerProfile.mark_dirty())
	list.add_percent_spinner("Voice Chat Volume", PlayerProfile.voice_chat_volume, func(value: float) -> void:
		PlayerProfile.voice_chat_volume = value
		PlayerProfile.mark_dirty())

	list.add_header("Gameplay")
	# 0.05 steps give the gamepad twenty notches across the range, which lands on the
	# round intervals players will look for (every 5s, 10s, 30s, a minute) without
	# making the bar feel coarse.
	list.add_slider(
		"Power-Up Frequency",
		0.0, 1.0, 0.05,
		PlayerProfile.power_up_frequency,
		func(value: float) -> void:
			PlayerProfile.power_up_frequency = value
			PlayerProfile.mark_dirty(),
		NROptionsRows._format_power_up_frequency)
	list.add_bool_spinner("Show Roster Overlay", PlayerProfile.show_roster_overlay, func(value: bool) -> void:
		PlayerProfile.show_roster_overlay = value
		PlayerProfile.mark_dirty())


## Renders the Power-Up Frequency slider's readout. The raw 0..1 value means nothing to
## a player, so the row shows the interval it buys. The matching cap on uncollected
## pickups moves with the same slider but is left off the readout: it is a consequence
## of the setting rather than a second thing to choose, and spelling both out made the
## row wider than the options panel.
static func _format_power_up_frequency(value: float) -> String:
	return "Every %ds" % roundi(NRConst.power_up_spawn_interval(value))


## Persists anything the live rows changed. Called by the host when the rows are left.
static func save() -> void:
	if PlayerProfile.has_pending_changes():
		PlayerProfile.save_settings()
