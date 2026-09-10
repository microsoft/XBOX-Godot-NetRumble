class_name AsteroidTuning
extends Resource

## Designer-tunable asteroid stats, shared by every asteroid size.

@export_group("Movement")
@export var velocity_initial_min: float = 32.0
@export var velocity_initial_max: float = 96.0
## Asteroids stop decaying once they drop below this speed.
@export var velocity_min_threshold: float = 25.0
@export var velocity_decay_rate: float = 0.15
@export var velocity_mass_ratio_to_rotation_scalar: float = 0.0017

@export_group("Size")
## Radii per NRTypes.AsteroidSize tier, smallest first. Each tier is roughly 1.6x the
## one below it, which keeps a split visibly a step down without the fragments
## shrinking to specks after two generations.
@export var radius_tiny: float = 14.0
@export var radius_small: float = 24.0
@export var radius_medium: float = 40.0
@export var radius_large: float = 64.0
@export var radius_huge: float = 96.0
## Health and mass are both derived from the radius.
@export var radius_health_ratio: float = 1.5
@export var radius_mass_ratio: float = 0.5

@export_group("Splitting")
## Fragments a destroyed asteroid breaks into. The tier below is spawned, so a HUGE
## rock ultimately yields split_count^4 TINY fragments -- keep this low.
@export var split_count: int = 2
## Fragments are pushed apart from the parent's centre at this speed, on top of
## whatever momentum the parent had.
@export var split_speed_min: float = 60.0
@export var split_speed_max: float = 140.0
## Fragments start this far out from the parent's centre, as a fraction of the space
## the parent's radius leaves around the child. Below 1.0 they begin overlapping and
## the solver blows them apart much harder than the split velocity intends.
@export var split_spawn_spread: float = 1.15
## Randomness added to each fragment's launch angle, in radians, so a split does not
## look like a mechanical rosette.
@export var split_angle_jitter: float = 0.5

@export_group("Damage")
@export var momentum_damage_scalar: float = 0.007

@export_group("Presentation")
## Radius, in texels, of the rock painted inside the asteroid textures. The art does
## not reach the texture's edge, so the sprite is scaled from this rather than from
## half the texture's width -- that is what keeps the drawn rock the same size as the
## collision circle instead of dwarfing it.
@export var texture_radius: float = 117.0
@export var textures: Array[Texture2D] = []


## Radius for an `NRTypes.AsteroidSize`, falling back to the smallest tier.
func radius_for(size: NRTypes.AsteroidSize) -> float:
	match size:
		NRTypes.AsteroidSize.SMALL:
			return radius_small
		NRTypes.AsteroidSize.MEDIUM:
			return radius_medium
		NRTypes.AsteroidSize.LARGE:
			return radius_large
		NRTypes.AsteroidSize.HUGE:
			return radius_huge
		_:
			return radius_tiny


## The tier a destroyed asteroid of `size` breaks into, or -1 when it is the terminal
## tier and simply disappears.
static func split_size_for(size: NRTypes.AsteroidSize) -> int:
	if int(size) <= int(NRTypes.AsteroidSize.TINY):
		return -1
	return int(size) - 1


func texture_for(variation: int) -> Texture2D:
	if textures.is_empty():
		return null
	return textures[posmod(variation, textures.size())]
