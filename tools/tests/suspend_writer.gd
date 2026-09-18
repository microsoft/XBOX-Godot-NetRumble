extends Node

const Fixture := preload("res://tools/tests/suspend_fixture.gd")


func _ready() -> void:
	var root := OS.get_environment("NR_SAVE_TEST_ROOT")
	if root.is_empty() or not OS.get_user_data_dir().replace("\\", "/").begins_with(root.replace("\\", "/") + "/"):
		_fail("child filesystem is not isolated")
		return
	var args := OS.get_cmdline_user_args()
	if args.size() != 1 or args[0] not in ["success", "partial"]:
		_fail("invalid child mode")
		return
	var folder := root.path_join("test-data/suspend-" + args[0])
	if DirAccess.make_dir_recursive_absolute(folder) != OK:
		_fail("cannot create child fixture")
		return
	AudioManager.set_script(Fixture.Review.QuietAudio)
	var fixture := Fixture.new()
	if not await fixture.open(self, folder):
		_fail("cannot prepare changed child fixture")
		return
	if args[0] == "partial":
		fixture.store.failed_files.assign(["history.json"])
	fixture.arm()
	var frame := Engine.get_process_frames()
	fixture.app.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	if not fixture.store.events.is_empty():
		_fail("Constrain unexpectedly persisted")
		return
	fixture.app.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	# No await, resume, normal quit, cleanup, or filesystem work between return and kill.
	if Engine.get_process_frames() != frame or NetManager.has_session() or fixture.app.quit_calls != 0:
		_fail("Suspend did not return synchronously through local teardown")
		return
	print("SAVE SUSPEND TEST: terminating immediately after main notification returned")
	var error := OS.kill(OS.get_process_id())
	_fail("self termination returned: %s" % error)


func _fail(message: String) -> void:
	print("SAVE TEST FAIL: ", message)
	get_tree().quit(1)


func _exit_tree() -> void:
	print("SAVE TEST FAIL: suspend child exited through normal tree teardown")
