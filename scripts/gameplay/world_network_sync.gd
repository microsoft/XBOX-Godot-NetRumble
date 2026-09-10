class_name WorldNetworkSync
extends RefCounted

## The replication layer: what the host puts on the wire each tick, and what every
## client does when it arrives.
##
## NetRumble is **host-authoritative**. One peer simulates the match and the others
## display it, so this file has two halves that describe the same wire format from
## opposite ends:
##
## - [method broadcast_snapshot] and [method _snapshot_entry] run only on the host and
##   define the schema — the compact `"px"/"py"/"h"/"s"/"w"/"b"` keys.
## - The `_on_*_received` handlers run only on clients and are the readers of that same
##   schema, plus the one-shot events (a projectile spawned, a power-up collected, a
##   ship destroyed) that are too rare to be worth putting in every snapshot.
##
## Every handler starts by returning early when [member World.is_authority] is true. The
## host is already the source of these facts — it applied them when it simulated them —
## so a host that also *applied* its own broadcasts would double-count them.
##
## Two things are worth understanding before changing anything here:
##
## **Remote objects are interpolated, the local ship is reconciled.** A remote ship has
## no local simulation worth preserving, so it is eased toward the host's copy at
## [constant SNAPSHOT_LERP]. The local ship is different: it is predicted every frame
## from the player's own input, and snapping it onto the host's copy 30 times a second
## would make the controls feel like they were fighting back. [method
## _reconcile_local_ship] therefore nudges rather than sets, and only takes the host's
## state outright when prediction has diverged too far to close smoothly.
##
## **Health is never predicted.** Damage is resolved by the host for every ship, the
## local one included, so health, shield and buffs are taken from the snapshot verbatim.
## Position is a prediction; health is a fact.
##
## The world simulation itself lives in world.gd. This object holds a reference to it
## and asks it to do things; it owns no game state beyond the outgoing snapshot counter.

## How far a remote object is eased toward the host's copy each snapshot. Interpolating
## rather than snapping hides the 30 Hz snapshot cadence and ordinary jitter.
const SNAPSHOT_LERP := 0.35
## The same idea for the local ship, but gentler, because the player is watching their
## own prediction and a hard correction reads as input lag.
const LOCAL_SNAPSHOT_LERP := 0.12
## Past this much divergence, easing would take visibly too long and the local ship is
## moved onto the host's copy outright.
const LOCAL_SNAPSHOT_SNAP_DISTANCE := 250.0
## Facing is driven straight from the stick, so it is only corrected once it has drifted
## further than this.
const LOCAL_SNAPSHOT_ROTATION_TOLERANCE := deg_to_rad(25.0)

## The keys each inbound message must carry before any part of it is read.
##
## Direct indexing is reasonable for traffic where host and client agree on the shape,
## and until now that agreement was assumed rather than checked. The realistic way it
## breaks is version skew -- two peers on different builds, which is an ordinary thing
## to happen to a sample developers are meant to fork and modify. The failure was also
## asymmetric in the worst direction: indexing a key that is not there raises "Invalid
## access to property or key" on the *receiver*, so the peer that did nothing wrong is
## the one that falls over, while the peer that sent the bad message plays on.
##
## Validating once on receipt lets the handlers below keep indexing directly, which is
## what makes them readable as a statement of the wire format.
const SNAPSHOT_OBJECT_KEYS: PackedStringArray = ["id", "px", "py", "vx", "vy", "rot"]
const PROJECTILE_SPAWNED_KEYS: PackedStringArray = [
	"id", "projectile_type", "owner_id", "px", "py", "vx", "vy", "rot"]
const PROJECTILE_DETONATED_KEYS: PackedStringArray = ["id", "px", "py"]
const POWER_UP_SPAWNED_KEYS: PackedStringArray = ["id", "power_up_type", "px", "py"]
const POWER_UP_COLLECTED_KEYS: PackedStringArray = ["id", "collector_id", "power_up_type"]
const SHIP_SPAWNED_KEYS: PackedStringArray = ["ship_id", "px", "py"]
const SHIP_DESTROYED_KEYS: PackedStringArray = ["ship_id"]

var _world: World
## Monotonic counter stamped on every outgoing snapshot. Clients drop anything not newer
## than the last frame they applied, so a reordered packet cannot rewind the world.
var _snapshot_frame: int = 0


func _init(world: World) -> void:
	_world = world
	NetManager.world_snapshot_received.connect(_on_world_snapshot_received)
	NetManager.projectile_spawned_received.connect(_on_projectile_spawned_received)
	NetManager.projectile_detonated_received.connect(_on_projectile_detonated_received)
	NetManager.power_up_spawned_received.connect(_on_power_up_spawned_received)
	NetManager.power_up_collected_received.connect(_on_power_up_collected_received)
	NetManager.ship_spawned_received.connect(_on_ship_spawned_received)
	NetManager.ship_destroyed_received.connect(_on_ship_destroyed_received)
	NetManager.asteroid_split_received.connect(_on_asteroid_split_received)
	NetManager.gameplay_event_received.connect(_on_gameplay_event_received)
	NetManager.match_created.connect(_on_match_created)
	NetManager.match_starting.connect(_on_match_starting)


# --- Outbound: the host describes the world ---------------------------------

## Build a world snapshot and send it. MatchDirector drives this on its own 30 Hz
## schedule through World.broadcast_snapshot(), so nothing here keeps a timer.
func broadcast_snapshot() -> void:
	if not _world.is_authority:
		return
	_snapshot_frame += 1

	var objects: Array[Dictionary] = []
	for ship in _world.ships.values():
		objects.append(_snapshot_entry(ship as Ship, true))
	for asteroid in _world.asteroids.values():
		objects.append(_snapshot_entry(asteroid as GameObject, false))

	NetManager.broadcast_world_snapshot({"frame": _snapshot_frame, "objects": objects})


## One object's row in a snapshot, and therefore the definition of the wire format.
## Keys are short because this goes out 30 times a second for every ship and asteroid
## in the match.
func _snapshot_entry(obj: GameObject, is_ship: bool) -> Dictionary:
	var entry := {
		"id": obj.unique_id,
		"px": obj.position.x,
		"py": obj.position.y,
		"vx": obj.velocity.x,
		"vy": obj.velocity.y,
		"rot": obj.rotation,
	}
	if is_ship:
		var s := obj as Ship
		entry["h"] = s.health
		entry["s"] = s.shield
		entry["w"] = int(s.primary_weapon)
		# Buffs change how a ship moves and whether it can be hit, so clients have to
		# be told about them or their prediction diverges for the whole duration.
		entry["b"] = s.buff_state()
	return entry


# --- Inbound: clients apply it ----------------------------------------------

## True when every key the handler is about to index is present.
##
## A malformed message is dropped and logged rather than partially applied: half a
## projectile is worse than none, and the log is what turns "the other player is
## invisible" into "we are on different builds". See the key lists above for why this
## check exists at all.
func _accepts(payload: Dictionary, required: PackedStringArray, kind: String) -> bool:
	for key in required:
		if not payload.has(key):
			push_warning(
				"[Sync] Dropped a malformed '%s' message: no '%s'. The sender is most "
				% [kind, key]
				+ "likely running a different build.")
			return false
	return true


func _on_world_snapshot_received(payload: Dictionary) -> void:
	if _world.is_authority:
		return
	var frame := int(payload.get("frame", 0))
	if frame <= _world.last_world_data_frame:
		return
	_world.last_world_data_frame = frame

	var local_id := _world.local_ship.unique_id if _world.local_ship != null else -1
	for od in payload.get("objects", []):
		# One bad entry drops itself rather than the whole snapshot: the rest of the
		# world is still describable, and at 30 Hz discarding every frame that carries
		# one unreadable object would stop the match dead.
		if typeof(od) != TYPE_DICTIONARY or not _accepts(od, SNAPSHOT_OBJECT_KEYS, "snapshot object"):
			continue
		var id := int(od["id"])
		var obj := _world.game_objects.get(id, null) as GameObject
		if obj == null:
			continue
		var target_position := Vector2(od["px"], od["py"])
		var target_velocity := Vector2(od["vx"], od["vy"])
		var target_rotation := float(od["rot"])
		if id == local_id:
			_reconcile_local_ship(target_position, target_velocity, target_rotation)
		else:
			obj.velocity = target_velocity
			obj.teleport(
				obj.position.lerp(target_position, SNAPSHOT_LERP),
				lerp_angle(obj.rotation, target_rotation, SNAPSHOT_LERP))
		if obj is Ship:
			# Damage is resolved by the host for every ship, the local one included,
			# so health/shield are taken verbatim rather than predicted.
			var s := obj as Ship
			s.health = od.get("h", s.health)
			s.shield = od.get("s", s.shield)
			s.set_primary_weapon_networked(int(od.get("w", int(s.primary_weapon))) as NRTypes.WeaponType)
			s.apply_buff_state(od.get("b", {}))


## The local ship is predicted locally rather than interpolated, so it is nudged
## toward the host's copy instead of being dragged onto it every snapshot. Without
## any correction at all the two simulations drift apart for the rest of the match:
## the player sees themselves where they predicted, everyone else sees the host's
## version somewhere else entirely.
func _reconcile_local_ship(target_position: Vector2, target_velocity: Vector2, target_rotation: float) -> void:
	var local_ship := _world.local_ship
	if local_ship == null:
		return
	if local_ship.position.distance_to(target_position) > LOCAL_SNAPSHOT_SNAP_DISTANCE:
		# Prediction is too far gone to close smoothly (a missed collision, a respawn
		# or a stall); take the host's state outright.
		local_ship.teleport(target_position, target_rotation)
		local_ship.velocity = target_velocity
		return
	local_ship.velocity = local_ship.velocity.lerp(target_velocity, LOCAL_SNAPSHOT_LERP)
	# Facing is driven directly by the stick, so it is left alone until it has drifted
	# far enough to matter -- pulling on it every snapshot makes turning feel laggy.
	var new_rotation := local_ship.rotation
	if absf(angle_difference(local_ship.rotation, target_rotation)) > LOCAL_SNAPSHOT_ROTATION_TOLERANCE:
		new_rotation = lerp_angle(local_ship.rotation, target_rotation, LOCAL_SNAPSHOT_LERP)
	local_ship.teleport(
		local_ship.position.lerp(target_position, LOCAL_SNAPSHOT_LERP),
		new_rotation)


func _on_projectile_spawned_received(payload: Dictionary) -> void:
	if _world.is_authority:
		return
	if not _accepts(payload, PROJECTILE_SPAWNED_KEYS, "projectile_spawned"):
		return
	var type := int(payload["projectile_type"]) as NRTypes.ProjectileType
	var id := int(payload["id"])
	var projectile := _world.game_objects.get(id, null) as Projectile
	if projectile == null:
		projectile = _world.create_projectile_instance(type)
		projectile.set_world(_world)
		projectile.unique_id = id
		_world.game_objects[id] = projectile
		_world.add_child(projectile)

	projectile.activate_from_authority(
		int(payload["owner_id"]),
		Vector2(payload["px"], payload["py"]),
		Vector2(payload["vx"], payload["vy"]),
		payload["rot"],
		payload.get("spec", {}))
	_world.active_projectiles[id] = projectile


func _on_projectile_detonated_received(payload: Dictionary) -> void:
	if _world.is_authority:
		return
	if not _accepts(payload, PROJECTILE_DETONATED_KEYS, "projectile_detonated"):
		return
	var id := int(payload["id"])
	var projectile := _world.game_objects.get(id, null) as Projectile
	if projectile != null:
		projectile.teleport(Vector2(payload["px"], payload["py"]))
		_world.remove_object(id)
	_world.apply_projectile_detonation_results(payload.get("hits", []))


func _on_power_up_spawned_received(payload: Dictionary) -> void:
	if _world.is_authority:
		return
	if not _accepts(payload, POWER_UP_SPAWNED_KEYS, "power_up_spawned"):
		return
	var id := int(payload["id"])
	var power_up := _world.power_ups.get(id, null) as PowerUp
	if power_up == null:
		return
	power_up.assign_type(int(payload["power_up_type"]) as NRTypes.PowerUpType)
	power_up.teleport(Vector2(payload["px"], payload["py"]))
	power_up.is_active = true
	power_up.start()
	_world.active_power_ups[id] = power_up
	_world.free_power_ups.erase(power_up)


func _on_power_up_collected_received(payload: Dictionary) -> void:
	if _world.is_authority:
		return
	if not _accepts(payload, POWER_UP_COLLECTED_KEYS, "power_up_collected"):
		return
	var power_up := _world.power_ups.get(int(payload["id"]), null) as PowerUp
	if power_up != null:
		_world.retire_power_up(power_up)
	var collector := _world.get_ship_by_id(int(payload["collector_id"]))
	if collector != null:
		# The pickup's payload is re-derived from its type rather than being spelled
		# out in the message: both peers read the same PickupLibrary, and sending the
		# type alone keeps the message the same size whichever of the three kinds it
		# turns out to be.
		_world.apply_pickup(
			PickupLibrary.get_definition(int(payload["power_up_type"]) as NRTypes.PowerUpType),
			collector)


func _on_ship_spawned_received(payload: Dictionary) -> void:
	if _world.is_authority:
		return
	if not _accepts(payload, SHIP_SPAWNED_KEYS, "ship_spawned"):
		return
	var ship := _world.get_ship_by_id(int(payload["ship_id"]))
	if ship == null:
		return
	_world.respawn_ship(ship, Vector2(payload["px"], payload["py"]))


func _on_ship_destroyed_received(payload: Dictionary) -> void:
	if _world.is_authority:
		return
	if not _accepts(payload, SHIP_DESTROYED_KEYS, "ship_destroyed"):
		return
	var ship := _world.get_ship_by_id(int(payload["ship_id"]))
	if ship != null:
		_world.note_local_ship_destroyed(ship)
		ship.die()


func _on_asteroid_split_received(payload: Dictionary) -> void:
	if _world.is_authority:
		return
	var parent := _world.asteroids.get(int(payload.get("id", 0)), null) as Asteroid
	if parent != null:
		parent.is_active = false
	for fragment in payload.get("fragments", []):
		_world.spawn_asteroid_fragment(fragment)
	_world.remove_object(int(payload.get("id", 0)))
	_world.note_asteroid_destroyed(int(payload.get("peer_id", -1)))
	_world.play_local_event(
		NRTypes.GameplayEventType.ASTEROID_IMPACT,
		Vector2(payload.get("px", 0.0), payload.get("py", 0.0)))


func _on_gameplay_event_received(event_type: NRTypes.GameplayEventType, position: Vector2) -> void:
	if _world.is_authority:
		return
	_world.play_local_event(event_type, position)


## The one-time world construction messages. The building itself is the mirror image of
## the host's own setup, so it stays in world.gd next to it; only the "am I a client?"
## gate belongs here.
func _on_match_created(payload: Dictionary) -> void:
	if _world.is_authority:
		return
	_world.apply_match_created(payload)


func _on_match_starting(payload: Dictionary) -> void:
	if _world.is_authority:
		return
	_world.apply_match_starting(payload)
