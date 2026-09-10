class_name WeaponDefinition
extends Resource

## Everything the simulation needs to know about one of the twenty weapons.
##
## Each weapon is data: how many shots, how they are arranged, and a set of
## multipliers applied to the pooled projectile that carries them.
## `World.create_projectiles()` is a single generic routine that reads this resource
## for every trigger pull, regardless of weapon type.
##
## The multipliers are deliberately relative to the projectile's own tuning rather
## than absolute. A weapon says "twice the damage, half the range"; it does not
## restate the laser's stats, so retuning `laser_tuning.tres` still moves every
## laser-derived weapon with it.
##
## Only the projectile *pool* is a real type (laser / mine / rocket): there are three
## pools and twenty weapons, so a "plasma cannon" is a laser body with a large radius,
## a slow speed and a splash radius, and a "beam lance" is a laser body that travels
## very fast, lives briefly and pierces. Guidance is the one behaviour that cannot be
## expressed as a number on a straight-line body, so `homing_rate` is read by
## `Projectile.tick()` directly.

@export var weapon_type: NRTypes.WeaponType = NRTypes.WeaponType.LASER
@export var display_name: String = "LASER"

## Which pool the shots are drawn from. Pools are finite and sized per player, so a
## weapon that fires eight shots at once burns through the laser pool eight times as
## fast as the plain laser -- which is why the high shot-count weapons also have short
## ranges, retiring their projectiles quickly.
@export var projectile_type: NRTypes.ProjectileType = NRTypes.ProjectileType.LASER

@export_group("Volley")
## Number of projectiles per trigger pull.
@export var shot_count: int = 1
## Total arc the volley is fanned across, in radians. The shots are distributed
## evenly across it and centred on the aim direction, so a two-shot weapon with a
## spread of 0.2 puts one shot 0.1rad either side.
@export var spread: float = 0.0
## Extra random angle applied per shot, in radians. This is what makes a scatter gun
## read as a cloud rather than as a rigid fan.
@export var spread_jitter: float = 0.0
## Perpendicular spacing between shots, in pixels. Used by the wing-mounted weapons
## so their shots travel parallel rather than diverging.
@export var lateral_spacing: float = 0.0
## Distance ahead of the ship the volley is spawned at.
@export var muzzle_offset: float = 0.0

@export_group("Timing")
## Seconds between volleys. This replaces the per-weapon fire-rate fields that used
## to live on ShipTuning.
@export var fire_rate: float = 0.15
## How many volleys the pickup is good for before the ship falls back to the plain
## laser. -1 means unlimited.
@export var ammo: int = -1

@export_group("Shot multipliers")
@export var damage_scale: float = 1.0
@export var speed_scale: float = 1.0
## Scales the projectile's lifetime, which is what actually determines its range.
@export var range_scale: float = 1.0
@export var radius_scale: float = 1.0
## Splash radius in pixels. -1 inherits the projectile tuning's own value (which is
## what the rocket-derived weapons want -- rocket_tuning already specifies 128), and
## 0 disables the explosion outright. Not a scale, because most weapons derive from
## the laser, whose splash radius is zero and cannot be scaled up from.
@export var splash_radius: float = -1.0
## Extra bodies the shot passes through before dying. 0 is the normal "dies on first
## contact" behaviour.
@export var pierce: int = 0
## Times the shot reflects off the barrier instead of dying against it.
@export var bounces: int = 0
## Turn rate in radians per second used to steer towards the nearest enemy. 0 = dumb
## fire.
@export var homing_rate: float = 0.0

@export_group("Presentation")
## Tint applied to the shot. A zero alpha means "use the firing player's colour",
## which keeps shots visually tied to the ship that fired them; the exotic weapons
## override it so their shots are recognisable at a glance, since the project only
## ships three projectile textures.
@export var shot_color: Color = Color(0.0, 0.0, 0.0, 0.0)
## Multiplies the sprite scale authored in the projectile scene.
@export var sprite_scale: float = 1.0
## Radius of the PointLight2D each shot casts onto ships and asteroids. 0 leaves the
## light switched off.
@export var light_radius: float = 90.0
## Brightness of that light.
@export var light_energy: float = 1.0


## Packs the shot-affecting fields into the dictionary that rides the projectile
## spawn message.
##
## Clients never look a weapon up: they are told, per shot, exactly what the
## authority built. That keeps the two sides in step even when a client is running a
## build whose weapon table has been retuned, and it means a client only needs the
## dozen numbers that change how a shot looks and how long it lives -- damage and
## splash are resolved by the authority and arrive as detonation results.
##
## Keys are two characters because this dictionary is sent once per shot and the
## scatter-class weapons send eight at a time.
func to_shot_spec() -> Dictionary:
	return {
		"ds": damage_scale,
		"ss": speed_scale,
		"rs": range_scale,
		"xs": radius_scale,
		"sp": splash_radius,
		"pc": pierce,
		"bn": bounces,
		"hm": homing_rate,
		"gs": sprite_scale,
		"lr": light_radius,
		"le": light_energy,
		"c": shot_color.to_rgba32(),
	}
