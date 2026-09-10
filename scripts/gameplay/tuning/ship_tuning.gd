class_name ShipTuning
extends Resource

## Designer-tunable ship stats. Edit the `.tres` in `assets/tuning/` to retune
## without touching code.

@export_group("Movement")
## Acceleration applied per second while the stick is fully deflected.
@export var speed_max: float = 400.0
@export var velocity_max: float = 400.0
## Fraction of current velocity shed per second.
@export var velocity_decay_rate: float = 0.7
@export var rotation_per_second: float = 6.0
## Below this angular error the ship stops correcting its heading.
@export var angle_threshold: float = 0.001
## Squared speed above which the thruster sprite appears.
@export var thruster_velocity_threshold_squared: float = 100.0

@export_group("Durability")
@export var health_max: float = 25.0
@export var shield_max: float = 100.0
@export var shield_recharge_rate: float = 50.0
@export var shield_recharge_delay: float = 2.5
@export var invulnerable_timer_max: float = 4.0
@export var mass: float = 32.0
@export var radius: float = 24.0
## Ships shrink slightly once their shield is down.
@export var radius_no_shield: float = 20.0

@export_group("Weapons")
@export var weapon_fire_rate: float = 0.15
@export var fire_rate_triple_laser: float = 0.3
@export var fire_rate_rocket: float = 0.5
## Squared stick deflection required to count as "firing".
@export var fire_threshold_squared: float = 0.25
@export var mine_deploy_rate: float = 3.0

@export_group("Presentation")
@export var shield_alpha_max: float = 0.588
@export var texture_dimension: float = 64.0
@export var shield_texture_dimension: float = 162.0
@export var thruster_texture_dimension: float = 180.0
