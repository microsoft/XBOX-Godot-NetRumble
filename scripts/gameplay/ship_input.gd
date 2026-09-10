class_name ShipInput
extends RefCounted

## Per-ship input snapshot.
##
## A single instance drives the local ship every frame (process_local_input); remote
## ships receive their state over the wire (update_remote_input). Movement and fire
## directions are expressed in screen space where up is -Y, matching Godot's 2D
## convention.

## Legitimate input is an analog stick (<= 1) plus un-normalized digital keys
## (<= sqrt(2)); anything past this bound is treated as synthetic and clamped.
const MAX_INPUT_MAGNITUDE := 4.0

## Seconds the authority keeps acting on a remote player's last input before
## treating them as idle. Input arrives on an unreliable channel, so silence means
## the peer stalled or dropped -- without this their ship keeps thrusting in the
## last direction it heard about and sails off across the map.
const REMOTE_INPUT_TIMEOUT := 1.0

var movement_direction: Vector2 = Vector2.ZERO
var fire_direction: Vector2 = Vector2.ZERO
var deploy_mine_pressed: bool = false
## True while the last local frame aimed with the mouse rather than the right stick /
## fire keys. The HUD reads this to decide whether to draw the aiming reticle, so the
## reticle appears the moment the mouse is used and gets out of the way for a pad.
var using_mouse_aim: bool = false

var _can_deploy_mine: bool = true
var _last_remote_input_sequence: int = 0
var _time_since_remote_input: float = 0.0


## `mouse_aim` is the world-space direction from this ship to the mouse cursor while
## the `click` action is held, or Vector2.ZERO otherwise. World computes it because
## resolving the cursor to world space needs the ship's position and the gameplay
## camera, neither of which this class can see.
##
## Mouse aim wins over the stick when present: holding the button is an unambiguous
## "shoot there", whereas the stick may just be resting off-centre.
func process_local_input(mouse_aim: Vector2 = Vector2.ZERO) -> void:
	# Deploy-mine is a one-frame event: clear it each frame so it is true only on the
	# press edge, otherwise a single press would deploy mines forever.
	deploy_mine_pressed = false

	movement_direction = Input.get_vector("move_left", "move_right", "move_up", "move_down")

	using_mouse_aim = not mouse_aim.is_zero_approx()
	if using_mouse_aim:
		fire_direction = mouse_aim
	else:
		fire_direction = Input.get_vector("fire_left", "fire_right", "fire_up", "fire_down")

	_handle_mine_deploy_input()


func update_remote_input(movement: Vector2, fire: Vector2, deploy: bool, sequence: int) -> void:
	# Remote input is attacker-controlled. A non-finite vector reaches the velocity clamp
	# as INF, where INF * (max / INF) yields NAN and poisons every snapshot built from it,
	# so drop the packet rather than apply it.
	if not _is_finite(movement) or not _is_finite(fire):
		return

	if sequence > _last_remote_input_sequence:
		movement_direction = _clamp_magnitude(movement)
		fire_direction = _clamp_magnitude(fire)
		_last_remote_input_sequence = sequence
		_time_since_remote_input = 0.0

	deploy_mine_pressed = deploy_mine_pressed or deploy


## Ages the last input received for a remote player and drops it once the peer has
## gone quiet. Called by the authority for every ship it does not own locally.
func tick_remote_input(delta: float) -> void:
	if movement_direction.is_zero_approx() and fire_direction.is_zero_approx():
		return
	_time_since_remote_input += delta
	if _time_since_remote_input >= REMOTE_INPUT_TIMEOUT:
		movement_direction = Vector2.ZERO
		fire_direction = Vector2.ZERO


func reset_mine_input() -> void:
	deploy_mine_pressed = false
	_can_deploy_mine = true


## Drops everything the ship was being told to do when it died.
##
## A dead ship is inactive and therefore never ticked, so neither `process_local_input`
## nor `tick_remote_input` runs for it and whatever it was holding at the moment of
## death stays latched. Without this the ship comes back from its respawn already
## thrusting -- and, for a player who was firing as they died, already shooting -- in
## the direction it was killed in.
##
## `_last_remote_input_sequence` is deliberately left alone: the sender's counter keeps
## climbing across the respawn, and rewinding the receiver's would make every packet
## still in flight look newer than it is.
func reset() -> void:
	movement_direction = Vector2.ZERO
	fire_direction = Vector2.ZERO
	using_mouse_aim = false
	_time_since_remote_input = 0.0
	reset_mine_input()


func _handle_mine_deploy_input() -> void:
	if Input.is_action_pressed("deploy_mine"):
		if _can_deploy_mine:
			deploy_mine_pressed = true
			_can_deploy_mine = false
	else:
		_can_deploy_mine = true


static func _is_finite(value: Vector2) -> bool:
	return is_finite(value.x) and is_finite(value.y)


static func _clamp_magnitude(value: Vector2) -> Vector2:
	var length_squared := value.length_squared()
	if length_squared <= MAX_INPUT_MAGNITUDE * MAX_INPUT_MAGNITUDE:
		return value
	return value * (MAX_INPUT_MAGNITUDE / sqrt(length_squared))
