extends RefCounted


class SnapshotWorld extends Node:
	var snapshots := 0
	var ticks := 0

	func tick(_delta: float) -> void:
		ticks += 1

	func broadcast_snapshot() -> void:
		snapshots += 1


func run(test: Node) -> void:
	print("CASE: asteroid splitting stops at MEDIUM with two fragments per split")
	var world := World.new()
	var parent := Asteroid.new()
	for size in [NRTypes.AsteroidSize.HUGE, NRTypes.AsteroidSize.LARGE]:
		parent.asteroid_size = size
		var fragments := world._build_asteroid_fragments(parent)
		test._check(fragments.size() == 2, "upper asteroid tier produces two fragments")
		for fragment in fragments:
			test._check(fragment["size"] == int(size) - 1, "fragment drops exactly one size tier")
	for size in [NRTypes.AsteroidSize.MEDIUM, NRTypes.AsteroidSize.SMALL, NRTypes.AsteroidSize.TINY]:
		parent.asteroid_size = size
		test._check(world._build_asteroid_fragments(parent).is_empty(),
			"MEDIUM and smaller asteroids produce no fragments")
	parent.free()
	world.free()

	print("CASE: full snapshots run at 20 Hz without reducing simulation or input rate")
	var director := MatchDirector.new()
	var snapshot_world := SnapshotWorld.new()
	director.world = snapshot_world
	for frame in 30:
		director._handle_running(1.0 / 60.0)
	test._check(snapshot_world.snapshots == 10, "half a second produces ten full snapshots")
	test._check(snapshot_world.ticks == 30, "simulation still advances every physics tick")
	test._check(NRConst.WORLD_SNAPSHOT_HZ == 20.0 and NRConst.INPUT_SEND_HZ == 60.0,
		"snapshot rate is 20 Hz and input send rate remains 60 Hz")
	director.free()
	snapshot_world.free()
