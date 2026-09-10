class_name Barrier
extends StaticBody2D

## Defines the rectangular world bounds. The four walls are repeat-tiled
## [Sprite2D]s plus thick [RectangleShape2D] colliders on the `walls` layer, so
## ships and asteroids bounce off them through the physics engine. Projectiles are
## killed on contact instead of bouncing.

## How far the wall colliders extend outside the play area. Thick walls make
## tunnelling impossible without continuous collision detection.
const WALL_THICKNESS := 400.0

var _left: float = 0.0
var _top: float = 0.0
var _right: float = 0.0
var _bottom: float = 0.0
var _cap_animation: AnimationPlayer = null


func setup(width: int, height: int) -> void:
	_cap_animation = $CapAnimation
	_left = 0.0
	_top = 0.0
	_right = float(width)
	_bottom = float(height)
	_layout()
	_configure_cap_animation()


func update(_delta: float) -> void:
	pass


func set_simulation_running(running: bool) -> void:
	if _cap_animation != null:
		_cap_animation.active = running


func get_top() -> float:
	return _top


func get_bottom() -> float:
	return _bottom


func get_left() -> float:
	return _left


func get_right() -> float:
	return _right


func get_width() -> float:
	return _right - _left


func get_height() -> float:
	return _bottom - _top


func _layout() -> void:
	# Region rects are in texture space, so wall length is divided by the sprite
	# scale. texture_repeat tiles the texture across the oversized region.
	var inv_scale := 1.0 / NRConst.BARRIER_END_SCALE
	var mid_x := (_left + _right) * 0.5
	var mid_y := (_top + _bottom) * 0.5
	_layout_wall($Walls/Top, Vector2(mid_x, _top), get_width() * inv_scale, true)
	_layout_wall($Walls/Bottom, Vector2(mid_x, _bottom), get_width() * inv_scale, true)
	_layout_wall($Walls/Left, Vector2(_left, mid_y), get_height() * inv_scale, false)
	_layout_wall($Walls/Right, Vector2(_right, mid_y), get_height() * inv_scale, false)

	# All four corners get a cap sprite.
	var corners := [
		Vector2(_left, _top),
		Vector2(_right, _top),
		Vector2(_left, _bottom),
		Vector2(_right, _bottom),
	]
	var caps := $EndCaps.get_children()
	for i in caps.size():
		caps[i].position = corners[i]
		caps[i].rotation = randf_range(0.0, TAU)

	_layout_colliders()


## Four slabs sitting just outside the play area. Half the thickness overlaps the
## boundary line so a body is pushed back in rather than resting on the edge.
func _layout_colliders() -> void:
	var half := WALL_THICKNESS * 0.5
	var width := get_width()
	var height := get_height()
	var mid_x := (_left + _right) * 0.5
	var mid_y := (_top + _bottom) * 0.5

	_layout_collider($ColliderTop, Vector2(mid_x, _top - half), Vector2(width + WALL_THICKNESS, WALL_THICKNESS))
	_layout_collider($ColliderBottom, Vector2(mid_x, _bottom + half), Vector2(width + WALL_THICKNESS, WALL_THICKNESS))
	_layout_collider($ColliderLeft, Vector2(_left - half, mid_y), Vector2(WALL_THICKNESS, height + WALL_THICKNESS))
	_layout_collider($ColliderRight, Vector2(_right + half, mid_y), Vector2(WALL_THICKNESS, height + WALL_THICKNESS))


func _layout_collider(collision_shape: CollisionShape2D, centre: Vector2, size: Vector2) -> void:
	collision_shape.position = centre
	var rect := collision_shape.shape as RectangleShape2D
	if rect != null:
		rect.size = size


func _layout_wall(sprite: Sprite2D, centre: Vector2, length: float, horizontal: bool) -> void:
	var tex_size := sprite.texture.get_size()
	sprite.position = centre
	if horizontal:
		sprite.region_rect = Rect2(0.0, 0.0, length, tex_size.y)
	else:
		sprite.region_rect = Rect2(0.0, 0.0, tex_size.x, length)


func _configure_cap_animation() -> void:
	if _cap_animation == null:
		return
	var animation := Animation.new()
	animation.length = TAU / NRConst.BARRIER_ROTATION_SPEED
	animation.loop_mode = Animation.LOOP_LINEAR
	var caps := $EndCaps.get_children()
	for i in caps.size():
		var cap := caps[i] as Node2D
		var track := animation.add_track(Animation.TYPE_VALUE)
		animation.track_set_path(track, NodePath("EndCaps/%s:rotation" % cap.name))
		animation.track_set_interpolation_type(track, Animation.INTERPOLATION_LINEAR)
		animation.value_track_set_update_mode(track, Animation.UPDATE_CONTINUOUS)
		animation.track_insert_key(track, 0.0, cap.rotation)
		animation.track_insert_key(track, animation.length, cap.rotation + TAU)
	var library := AnimationLibrary.new()
	library.add_animation("spin", animation)
	if _cap_animation.has_animation_library(""):
		_cap_animation.remove_animation_library("")
	_cap_animation.add_animation_library("", library)
	_cap_animation.play("spin")
