class_name ProjectileTuning
extends Resource

## Designer-tunable projectile stats. One `.tres` instance per projectile type
## (`laser.tres`, `rocket.tres`, `mine.tres`) rather than one class per weapon.

@export var projectile_type: NRTypes.ProjectileType = NRTypes.ProjectileType.LASER

@export_group("Body")
@export var mass: float = 0.5
@export var radius: float = 4.0
@export var velocity: float = 640.0
@export var health: float = 1.0
## Seconds before the projectile expires on its own.
@export var duration: float = 5.0

@export_group("Damage")
@export var damage_amount: float = 20.0
## Zero means a direct hit only, with no area-of-effect falloff.
@export var damage_radius: float = 0.0
@export var can_damage_owner: bool = false

@export_group("Drift")
## Mine-only: fraction of velocity shed per second until the mine anchors.
@export var drag_per_second: float = 0.0
## Mine-only: squared speed below which the mine anchors in place.
@export var minimum_velocity_squared: float = 0.0
## Mine-only: constant spin, in radians per second.
@export var rotation_speed: float = 0.0

@export_group("Presentation")
@export var texture: Texture2D = null
## Extra sprite rotation, for art that is not drawn nose-up. The body itself always
## faces the direction the projectile travels.
@export var sprite_rotation: float = 0.0
