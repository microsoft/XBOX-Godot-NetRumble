class_name DeviceService
extends RefCounted

## Notices when the signed-in player's controller goes away and when it comes back
## (XR-115).
##
## This is the *association* half of the controller requirement and nothing more. It
## answers one question — does the player still have a pad — and it deliberately does not
## try to answer "which Godot device index is theirs", which is the question that sank the
## previous attempt (see "Controller association" in docs/platform-services.md). The
## platform speaks 64-character hex device ids, `InputEvent.device` is an unrelated
## small integer, no supported API converts between them, and the correlation the last
## implementation guessed at was wrong often enough to make the title unplayable. Knowing
## that a pad vanished never required knowing its index, so nothing here needs the mapping.
##
## Two sources feed one answer, because neither covers every machine:
##
## - `XboxUsers.device_association_changed` is the authoritative one on console. It says
##   which devices the *signed-in account* owns, which is the question XR-115 actually
##   asks — a second player's pad disconnecting is not this player's problem.
## - `Input.joy_connection_changed` is Godot's own, and it is all there is on a desktop
##   machine with no GDK. It also fires well before the platform re-pairs a device, so on
##   console it tends to be the first of the two to notice.
##
## Both collapse into `_set_has_controller()`, so one disconnect reported twice raises one
## reaction.
##
## Addon SDK objects are held as Variant for the usual reason: the godot_gdk classes only
## exist when the native library loads, so naming them in type positions would break
## parsing on a machine without the extension.

## The player had a controller and no longer does.
signal controller_lost
## The player has a controller again, after having lost one.
signal controller_bound

## Hex device ids the platform has paired with the signed-in account. Only meaningful
## when the platform reports associations at all; see `_platform_tracks_devices`.
var _device_ids: PackedStringArray = PackedStringArray()
## The signed-in user's GDK local id, or 0 for "no user". Associations are reported
## against this rather than against the XboxUser object.
var _user_local_id: int = 0
## True once the platform has told us about at least one association for this account.
## Until then the Godot joypad list is the only thing worth believing.
var _platform_tracks_devices := false
## The last answer given, so only transitions are reported. Starts false and is seeded by
## `start()`, which means a keyboard-only desktop machine -- which never has a pad and
## never loses one -- never raises the prompt.
var _has_controller := false
var _started := false


## Begins tracking for the signed-in user. Safe to call again when the account changes;
## the second call re-seeds against the new user rather than double-subscribing.
func start(user: Variant) -> void:
	_user_local_id = int(user.get_local_id()) if user != null else 0
	_device_ids = PackedStringArray()
	_platform_tracks_devices = false

	var users: Variant = _users()
	if users != null and user != null:
		var devices: Variant = users.get_devices_for_user(user)
		if devices != null:
			_device_ids = devices
			_platform_tracks_devices = not _device_ids.is_empty()

	if not _started:
		_started = true
		if users != null:
			users.device_association_changed.connect(_on_device_association_changed)
		Input.joy_connection_changed.connect(_on_joy_connection_changed)

	# Seeded silently: whatever the player has at sign-in is the baseline, and there is
	# nothing to announce about a state they are already in.
	_has_controller = _observe()


## Stops tracking. Called when the account goes away, since the associations belonged to
## it and a device list left behind would describe the previous player's hardware.
func clear() -> void:
	_user_local_id = 0
	_device_ids = PackedStringArray()
	_platform_tracks_devices = false
	_has_controller = false


func has_controller() -> bool:
	return _has_controller


## Whether the platform is answering the device question on this machine. False on
## desktop and in a build with no GDK, where the Godot joypad list stands in.
func is_platform_tracked() -> bool:
	return _platform_tracks_devices


func _on_device_association_changed(device_id: String, old_user_local_id: int, new_user_local_id: int) -> void:
	# A local id of 0 means "no user". An association moving to another account is a loss
	# for this one, which is why both ends are checked rather than just the new one.
	if _user_local_id == 0:
		return
	var index := _device_ids.find(device_id)
	if new_user_local_id == _user_local_id:
		_platform_tracks_devices = true
		if index == -1:
			_device_ids.append(device_id)
	elif old_user_local_id == _user_local_id:
		if index != -1:
			_device_ids.remove_at(index)
	else:
		return
	_set_has_controller(_observe())


func _on_joy_connection_changed(_device: int, _connected: bool) -> void:
	_set_has_controller(_observe())


## The current answer, from whichever source is credible on this machine.
##
## The platform list wins once it has ever been populated, because it is scoped to the
## account: on a console with two players, the other player's pad disconnecting is not
## this player's problem, and the raw joypad count cannot tell the difference.
func _observe() -> bool:
	if _platform_tracks_devices:
		return not _device_ids.is_empty()
	return not Input.get_connected_joypads().is_empty()


func _set_has_controller(value: bool) -> void:
	if _has_controller == value:
		return
	_has_controller = value
	if value:
		controller_bound.emit()
	else:
		controller_lost.emit()


func _users() -> Variant:
	return PlatformAccess.users()
