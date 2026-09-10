class_name PowerUpDefinition
extends Resource

## Describes one collectible pickup.
##
## Pickups come in three flavours -- weapons, timed buffs and instant restores -- so
## the definition carries a `kind` that says which of the payload fields is meaningful.
##
## The project ships exactly three power-up textures and there are thirty-two pickups.
## Every definition picks one of the three textures as its silhouette and supplies a
## `tint` and a short `label`, which `PowerUp` draws over the sprite. A player reads
## the colour at a glance and the label when they are close enough for it to matter.

@export var power_up_type: NRTypes.PowerUpType = NRTypes.PowerUpType.DOUBLE_LASER
@export var kind: NRTypes.PickupKind = NRTypes.PickupKind.WEAPON
@export var display_name: String = ""
@export var texture: Texture2D = null

@export_group("Payload")
## Meaningful when `kind` is WEAPON.
@export var weapon_granted: NRTypes.WeaponType = NRTypes.WeaponType.DOUBLE_LASER
## Meaningful when `kind` is BUFF.
@export var buff_granted: NRTypes.BuffType = NRTypes.BuffType.RAPID_FIRE
@export var buff_duration: float = 12.0
## Meaningful when `kind` is RESTORE. Applied on top of the collector's current
## values and clamped to their maxima by Ship.
@export var restore_health: float = 0.0
@export var restore_shield: float = 0.0
## Relative likelihood of this pickup being chosen when a drop spawns.
@export var spawn_weight: float = 1.0

@export_group("Body")
@export var radius: float = 20.0

@export_group("Presentation")
## Sprite tint, and the colour of the light the pickup casts.
@export var tint: Color = Color.WHITE
## Two or three characters drawn across the pickup so it is identifiable without
## dedicated art.
@export var label: String = ""
@export var rotation_speed: float = 2.0
@export var pulse_amplitude: float = 0.1
@export var pulse_rate: float = 0.1
@export var light_radius: float = 110.0
