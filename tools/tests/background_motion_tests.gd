extends RefCounted

## UIBackgroundMotion with the real Waves and Glow adapters: covered warm-up and when it may retry,
## clocks, the re-enable ramp, pauses including suspend, the Ctrl+Shift+M / View shortcut and the
## exact static Off path.
##
## Headless has no GPU frames, so after checking that the real renderer checks never wait for one,
## the suite turns on the controller's test_force_gpu seam and plays the renderer itself by
## emitting RenderingServer.frame_post_draw; emitting nothing is a minimised window. Clocks and the
## ramp are steered with the seek seams, time_override and pauses. A running clock is only ever
## checked against bounds measured on the monotonic clock, never a fixed ceiling, so a slow or
## busy machine cannot fail the suite. A windowed UI run (-ScreenshotDirectory) instead renders the
## glow on the GPU: Off against the designer's export, and the breathing path's single rounding,
## screen-fixed noise, periodicity and hotspot range.

const MainProbe := preload("res://tools/tests/review_main.gd")
const Doubles := preload("res://tools/tests/doubles.gd")
const Review := preload("res://tools/tests/review_lifecycle.gd")
const JOIN_CODE_ENTRY := preload("res://scenes/ui/elements/nr_join_code_entry.tscn")
const WavesBackground := preload("res://scripts/ui/backgrounds/waves_background.gd")
const GlowBackground := preload("res://scripts/ui/backgrounds/glow_background.gd")
const GLOW_SHADER := "res://scripts/ui/backgrounds/glow.gdshader"
## The designer's 1920x1080 title/lobby glow export; .gdignore keeps it out of imports and exports.
const DESIGNER_GLOW := "res://tools/tests/fixtures/Background_Glow_designer.png"
const BASE := Color(0.019607844, 0.019607844, 0.019607844, 1.0)
const COVER_NAME := ^"BackgroundMotionStartupCover"
const WARM_UP_NODES := [
	^"WavesPipelineWarmUp", ^"GlowPipelineWarmUp", ^"ShipCardPipelineWarmUp", ^"ShipPreviewPipelineWarmUp",
]
## Glow breathing: a 12 s sine, strength +/-15 % and size +/-1.5 %.
const GLOW_LOOP := 12.0
const GLOW_STRENGTH := 0.15
const GLOW_SIZE := 0.015
## The re-enable ramp: a smoothstep over this much running time.
const RAMP_SECONDS := 3.0
## The Waves first-activation ease: a smoothstep over the family clock's first 3 s.
const FIRST_EASE_SECONDS := 3.0
## Overlapping Waves ramps as [family clock s, re-enable ramp s]: both part-way together, as on the
## first activation after warm-up, then each one ahead of the other.
const RAMP_OVERLAPS := [[1.5, 1.5], [1.0, 2.0], [2.0, 1.0]]
## Uniforms are compared with an independent recomputation of the same double-precision maths.
const UNIFORM_EPSILON := 0.000001
## Off glow vs the designer's export: the enforced parity bound.
const GLOW_MAX_MAE := 0.10
const GLOW_MAX_ERROR := 2
## The first breathing frame (t = 0: design strength and size, noise on) vs Off. Breathing rounds
## the design's float composite once over screen-fixed TPDF noise; Off keeps the export's staged
## truncation, so out - Off lies in [-1, 3], and each channel's mean offset is at most 1 code value.
const BREATHING_MAX_FROM_OFF := 3
const BREATHING_MEAN_FROM_OFF := 1.0
## Every pixel from this row down is outside the glow's ellipse: (1044.5 - 433.39) / 609.39 > 1.
const OUTSIDE_GLOW_FIRST_ROW := 1044
## There, the noise rounds the base's 5 to 4, 5 or 6 with a mean of 5.
const OUTSIDE_GLOW_MEAN_TOLERANCE := 0.05
## The design's glow: centre and radii in the 1920x1080 design, and the stop's colour in code
## values at 30 % alpha over the #050505 base.
const GLOW_CENTRE_X := 960.0
const GLOW_CENTRE_Y := 433.392583
const GLOW_RADIUS_X := 1338.1524
const GLOW_RADIUS_Y := 609.39245
const GLOW_STOP := [50.0, 164.0, 96.0]
const GLOW_ALPHA := 0.3
const GLOW_BASE_CODE := 5.0
## A 32x32 window on the hotspot. Its breathing range, t = 3 s (breath +1) minus t = 9 s (breath
## -1), must match that of the design's float composite.
const HOTSPOT_X := 960
const HOTSPOT_Y := 433
const HOTSPOT_HALF := 16
const HOTSPOT_RANGE_TOLERANCE := 0.25
## Monotonic budget for a windowed run to draw the frames each glow render needs.
const FRAME_TIMEOUT_MSEC := 5000


## Records, for every save write, whether background motion was already suspended.
class SuspendOrderSaves extends Doubles.Saves:
	var suspended_at_writes: Array[bool] = []

	func write_now(user: Variant, generation: int, file_name: String, data: Variant) -> Dictionary:
		suspended_at_writes.append(UIBackgroundMotion.is_suspended())
		return super.write_now(user, generation, file_name, data)


var _test: Node
## Stands in for a screen: ScreenManager hides a screen, or keeps it visible but disabled under a
## dialog, and the adapters underneath follow.
var _screen: Control


func run(test: Node) -> void:
	_test = test
	if DisplayServer.get_name() != "headless":
		await _glow_renders()
		return
	var render_ui_assets: bool = Assets.render_ui_assets
	# The Waves adapter validates the real dot atlas and strand textures.
	Assets.render_ui_assets = true
	# The suspend and resume handlers stop and restart music; the headless test audio has no player.
	var audio_script: Script = AudioManager.get_script()
	AudioManager.set_script(Review.QuietAudio)
	# No account is ready, so a resume routes to the title.
	await _test._reset()
	ScreenManager.clear()
	_screen = Control.new()
	_screen.name = "BackgroundMotionScreen"
	_screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	test.add_child(_screen)
	# Earlier suites leave the title constrained or suspended (a focus loss or a suspend without its
	# return).
	UIBackgroundMotion.set_constrained(false)
	UIBackgroundMotion.set_suspended(false)
	UIBackgroundMotion.session_paused = false
	UIBackgroundMotion.time_override = -1.0
	PlayerProfile.animate_backgrounds = true
	PlayerProfile.notify_settings_changed()
	await _frames(2)

	await _headless_never_awaits_gpu()
	UIBackgroundMotion.test_force_gpu = true
	var waves := _waves_adapter("Waves")
	var glow := _glow_adapter("Glow")
	await _timeout_stays_static(waves, glow)
	await _focus_return_restores_motion(waves, glow)
	if UIBackgroundMotion.is_warmed():
		await _time_override_pins_pose(waves, glow)
		await _off_is_exact_static(waves, glow)
		waves = await _re_enable_envelope(waves, glow)
		await _ramps_never_stack(waves, glow)
		waves = await _phase_survives_swaps(waves)
		await _constrain_freezes_pose(waves, glow)
		await _dialog_and_hide_hold_the_clock()
		await _nested_pause_reasons(waves, glow)
		await _toggle_action(waves, glow)
		await _shortcut_needs_exact_keys()
		await _suspend_freezes_motion(waves, glow)
		await _motion_hint_follows_shortcut()

	UIBackgroundMotion.test_force_gpu = false
	UIBackgroundMotion.time_override = -1.0
	UIBackgroundMotion.session_paused = false
	UIBackgroundMotion.set_constrained(false)
	UIBackgroundMotion.set_suspended(false)
	PlayerProfile.animate_backgrounds = true
	PlayerProfile.notify_settings_changed()
	test.remove_child(_screen)
	_screen.queue_free()
	Assets.render_ui_assets = render_ui_assets
	AudioManager.set_script(audio_script)
	PlayerProfile.apply_dict(PlayerProfile.to_dict())
	await _frames(1)


func _headless_never_awaits_gpu() -> void:
	print("CASE: headless startup never waits for GPU frames and leaves every background static")
	_check(not UIBackgroundMotion.is_warmed() and not UIBackgroundMotion.test_force_gpu,
		"background motion starts cold, with the real renderer checks")
	var frame := Engine.get_process_frames()
	await UIBackgroundMotion.prepare(_screen)
	_check(Engine.get_process_frames() == frame, "headless prepare() returns without awaiting a frame")
	_check(not UIBackgroundMotion.is_warmed() and not UIBackgroundMotion.effective_enabled()
		and not _has_warm_up_nodes(), "headless prepare() draws nothing and never enables motion")


func _timeout_stays_static(waves: TextureRect, glow: ColorRect) -> void:
	print("CASE: a warm-up that sees no drawn frames (minimised start) times out to static backgrounds")
	_assert_static(waves, glow, "before the warm-up")
	var started := Time.get_ticks_usec()
	await UIBackgroundMotion.prepare(_screen)
	_check(Time.get_ticks_usec() - started >= UIBackgroundMotion.WARM_UP_TIMEOUT_USEC
		and not UIBackgroundMotion.is_warmed() and not _has_warm_up_nodes(),
		"without drawn frames the warm-up times out, removes its draws and stays cold")
	_assert_static(waves, glow, "after the warm-up timeout")
	_press_shortcut()
	_press_joy(JOY_BUTTON_BACK)
	_check(not UIBackgroundMotion.session_paused,
		"Ctrl+Shift+M and View leave the session pause alone while motion is disabled (not warmed)")

	print("CASE: after a timeout nothing starts motion cold")
	for frame in 5:
		RenderingServer.frame_post_draw.emit()
		await _frames(1)
	PlayerProfile.notify_settings_changed()
	UIBackgroundMotion.session_paused = true
	UIBackgroundMotion.session_paused = false
	UIBackgroundMotion.set_constrained(true)
	UIBackgroundMotion.set_constrained(false)
	var late := _waves_adapter("LateWaves")
	await _frames(2)
	_check(not UIBackgroundMotion.is_warmed()
		and _state(UIBackgroundMotion.WAVES) == UIBackgroundMotion.STATE_DISABLED
		and _state(UIBackgroundMotion.GLOW) == UIBackgroundMotion.STATE_DISABLED,
		"late frames, settings changes and pause toggles never warm or start motion")
	_assert_static(waves, glow, "after late frames and toggles")
	_assert_static_waves(late, "for a Waves screen shown after the timeout")
	_free(late)


func _focus_return_restores_motion(waves: TextureRect, glow: ColorRect) -> void:
	UIBackgroundMotion.seek_family_for_tests(UIBackgroundMotion.WAVES, 0.0)
	UIBackgroundMotion.seek_family_for_tests(UIBackgroundMotion.GLOW, 0.0)
	var old_container: Node = ScreenManager._container
	var app: Node = preload("res://scenes/main.tscn").instantiate()
	app.set_script(MainProbe)
	_test.add_child(app)
	# The probe skips main.gd's startup; mark that startup's (timed-out) warm-up as finished.
	app.set(&"_startup_background_prepare_complete", true)
	await _retry_needs_front_end_background(app)
	await _resume_retry_avoids_gameplay(app)
	print("CASE: after a timeout, focus (even one never preceded by a focus loss) retries under a fresh opaque cover")
	# A title launched minimised never had focus, so its focus events are FOCUS_IN with no FOCUS_OUT.
	app.notification(Node.NOTIFICATION_APPLICATION_FOCUS_IN)
	_check(not UIBackgroundMotion.is_constrained(), "a first focus leaves motion unconstrained")
	await _frames(1)
	_assert_cover(app, "the retried warm-up")
	_check(not UIBackgroundMotion.is_warmed() and _state(UIBackgroundMotion.WAVES) == UIBackgroundMotion.STATE_DISABLED,
		"the retried warm-up runs behind the cover while backgrounds stay static")
	_assert_static(waves, glow, "while the retry warms")
	await _resume_waits_for_warm_up(app)
	await _gameplay_cancels_warm_up(app)
	print("CASE: focus return after that resume retries under a fresh cover, and drawn frames complete it")
	app.notification(Node.NOTIFICATION_APPLICATION_FOCUS_IN)
	_check(not UIBackgroundMotion.is_constrained(), "focus return lifts the constrain")
	await _frames(1)
	_assert_cover(app, "the retry on focus return")
	var before_warm := Time.get_ticks_usec()
	var warmed := await _draw_until_warmed()
	_check(warmed and app.get_node_or_null(COVER_NAME) == null,
		"drawn frames complete the retried warm-up, which then removes its cover")
	_check(_running_both() and waves.material != null and waves.get_child_count() == 1
		and waves.is_processing() and glow.is_processing() and _param(glow, &"dither") == 1.0,
		"visible backgrounds animate on the warmed pipelines")
	var since := _elapsed(before_warm)
	_check(UIBackgroundMotion.time_for(UIBackgroundMotion.WAVES) <= since
		and UIBackgroundMotion.time_for(UIBackgroundMotion.GLOW) <= since,
		"the clocks start at the first visible activation; the warm-up pose never advances them")
	_check(_envelope(UIBackgroundMotion.WAVES) <= _smooth(since / RAMP_SECONDS)
		and _envelope(UIBackgroundMotion.GLOW) <= _smooth(since / RAMP_SECONDS),
		"a successful retry starts the 3 s ease-in from the design")
	var clock_since := Time.get_ticks_usec()
	var clock_from := UIBackgroundMotion.time_for(UIBackgroundMotion.WAVES)
	var ramp_from := _envelope(UIBackgroundMotion.WAVES)
	_check(await _advances(UIBackgroundMotion.WAVES, clock_from, clock_since)
		and (_envelope(UIBackgroundMotion.WAVES) > ramp_from or ramp_from == 1.0),
		"after the retry the Waves clock and its ease-in really advance")
	app.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	_check(UIBackgroundMotion.is_constrained() and _paused_both(), "focus loss freezes motion")
	# The first activation starts the Waves clock and its ramp together, so both ramps overlap here.
	var first_ease := _smooth(UIBackgroundMotion.time_for(UIBackgroundMotion.WAVES) / FIRST_EASE_SECONDS)
	_check(absf(_envelope(UIBackgroundMotion.WAVES) - first_ease) <= UNIFORM_EPSILON
		and absf(_param(waves, &"ease") - first_ease) <= UNIFORM_EPSILON,
		"on the first activation the Waves clock and ramp run together, and the frozen pose eases by one of them, not both")
	app.notification(Node.NOTIFICATION_APPLICATION_FOCUS_IN)
	await _frames(1)
	_check(not UIBackgroundMotion.is_constrained() and app.get_node_or_null(COVER_NAME) == null and _running_both(),
		"once warmed, focus return resumes motion without another covered warm-up")
	# Each resume routed the probe to the title; it goes with the probe.
	ScreenManager.clear()
	await _frames(1)
	_test.remove_child(app)
	app.queue_free()
	ScreenManager.set_container(old_container)


## A resume routes to the title or menu and then retries a failed warm-up, but the retry still
## refuses a stack that holds gameplay when it runs.
func _resume_retry_avoids_gameplay(app: Node) -> void:
	print("CASE: resume without a focus change retries a failed warm-up only off gameplay")
	var gameplay := NRScreen.new()
	gameplay.scene_file_path = ScreenManager.GAMEPLAY
	# Gameplay joins the stack as soon as resume's route lands, before the retry it schedules runs.
	var add_gameplay := func(_pushed: NRScreen) -> void:
		if not ScreenManager._stack.has(gameplay):
			ScreenManager._stack.append(gameplay)
	ScreenManager.screen_pushed.connect(add_gameplay)
	app.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	app.notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	await _frames(4)
	ScreenManager.screen_pushed.disconnect(add_gameplay)
	_check(ScreenManager.has_screen(ScreenManager.ACQUIRE_USER) and _retry_skipped(app),
		"with gameplay on the stack, the retry after resume adds no cover and starts no warm-up")
	ScreenManager._stack.erase(gameplay)
	gameplay.queue_free()
	await _frames(1)


## Resume schedules its retry only once a warm-up still in flight has finished, so it neither stacks
## a second cover nor loses the retry. The retry still checks, when it runs, that the title is not
## constrained.
func _resume_waits_for_warm_up(app: Node) -> void:
	print("CASE: resume without a focus change waits for the warm-up in flight, then retries under a fresh cover")
	app.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	app.notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	await _frames(4)
	_check(ScreenManager.has_screen(ScreenManager.ACQUIRE_USER) and UIBackgroundMotion.is_preparing()
		and _covers(app) == 1, "resume routes to the title and waits under the one cover while the earlier warm-up runs")
	_fail_warm_up(app)
	await _frames(4)
	_assert_cover(app, "the retry after resume")
	_check(UIBackgroundMotion.is_preparing() and not UIBackgroundMotion.is_warmed() and _covers(app) == 1
		and _warm_up_drawing(app), "once that warm-up fails, resume retries under a fresh cover")

	print("CASE: resume without a focus change refuses its retry while the title is still constrained")
	app.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	app.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	app.notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	await _frames(4)
	_fail_warm_up(app)
	await _frames(4)
	_check(UIBackgroundMotion.is_constrained() and _retry_skipped(app),
		"while the Guide still constrains the title, the warm-up that fails after resume is followed by no retry")


## A match never starts under a warm-up cover. When the lobby pushes gameplay while a retry is still
## warming, main.gd cancels the warm-up: its cover and draws leave in that same frame, and draws that
## arrive afterwards cannot complete it, so motion stays cold for a later retry over the front end.
func _gameplay_cancels_warm_up(app: Node) -> void:
	print("CASE: gameplay pushed while a retry warms cancels it at once, removing its cover and draws")
	app.notification(Node.NOTIFICATION_APPLICATION_FOCUS_IN)
	await _frames(1)
	_assert_cover(app, "the retry that gameplay interrupts")
	_check(UIBackgroundMotion.is_preparing() and _warm_up_drawing(app), "fixture: a retried warm-up is in flight")
	var gameplay := NRScreen.new()
	gameplay.scene_file_path = ScreenManager.GAMEPLAY
	# What replace_all(GAMEPLAY) does when the lobby starts the match: gameplay joins the stack and
	# screen_pushed announces it.
	ScreenManager._stack.append(gameplay)
	ScreenManager.screen_pushed.emit(gameplay)
	_check(_covers(app) == 0 and not _warm_up_in_app(app),
		"the cover and every warm-up draw leave in the frame gameplay arrives")
	for frame in UIBackgroundMotion.WARM_UP_FRAMES + 1:
		RenderingServer.frame_post_draw.emit()
	await _frames(2)
	_check(_retry_skipped(app),
		"draws that arrive afterwards cannot complete the cancelled warm-up, and no retry starts over gameplay")
	ScreenManager._stack.erase(gameplay)
	gameplay.queue_free()
	await _frames(1)


## main.gd retries a failed warm-up under its cover only while a front-end background shows and no
## gameplay is on the stack, so the cover never blacks out a match. It checks again when the
## deferred retry runs, and a post-startup attempt that finds gameplay keeps its one try for later.
func _retry_needs_front_end_background(app: Node) -> void:
	print("CASE: a failed warm-up retries under a cover only over a front-end background, never over gameplay")
	var gameplay := NRScreen.new()
	gameplay.scene_file_path = ScreenManager.GAMEPLAY
	ScreenManager._stack.append(gameplay)
	_screen.visible = false
	_check(not UIBackgroundMotion.front_end_background_visible(), "fixture: gameplay shows no front-end background")
	app.notification(Node.NOTIFICATION_APPLICATION_FOCUS_IN)
	await _frames(2)
	_check(_retry_skipped(app), "focus during gameplay adds no cover and starts no warm-up")
	app.call(&"_schedule_background_warm_up_retry", true)
	await _frames(3)
	_check(_retry_skipped(app) and app.get(&"_post_startup_background_retry_used") == false,
		"a post-startup retry during gameplay adds no cover and keeps its one attempt")
	# Even while a front-end background shows, gameplay anywhere on the stack blocks the retry.
	_screen.visible = true
	_check(UIBackgroundMotion.front_end_background_visible(), "fixture: a front-end background shows over gameplay")
	app.notification(Node.NOTIFICATION_APPLICATION_FOCUS_IN)
	await _frames(2)
	_check(_retry_skipped(app), "gameplay anywhere on the stack blocks the retry, even under a front-end background")
	ScreenManager._stack.erase(gameplay)
	# Eligible when focus schedules the retry; gameplay replaces the front end before it runs.
	app.notification(Node.NOTIFICATION_APPLICATION_FOCUS_IN)
	ScreenManager._stack.append(gameplay)
	_screen.visible = false
	await _frames(2)
	_check(_retry_skipped(app), "the retry checks again when it runs: no cover once gameplay has replaced the front end")
	ScreenManager._stack.erase(gameplay)
	gameplay.queue_free()
	_screen.visible = true
	await _frames(1)


func _time_override_pins_pose(waves: TextureRect, glow: ColorRect) -> void:
	print("CASE: time_override pins both families to one deterministic, frozen pose")
	UIBackgroundMotion.time_override = 7.5
	await _frames(3)
	var breath := sin(TAU * 7.5 / GLOW_LOOP)
	_check(_paused_both()
		and is_equal_approx(UIBackgroundMotion.time_for(UIBackgroundMotion.WAVES), 7.5)
		and is_equal_approx(UIBackgroundMotion.time_for(UIBackgroundMotion.GLOW), 7.5),
		"time_override freezes both clocks at the requested time")
	_check(is_equal_approx(_param(waves, &"t_phase"), 7.5) and is_equal_approx(_param(waves, &"ease"), 1.0)
		and waves.get_child_count() == 1 and not waves.is_processing(),
		"Waves holds the dots at the requested phase with its materials and no processing")
	_check(is_equal_approx(_param(glow, &"strength"), 1.0 + GLOW_STRENGTH * breath)
		and is_equal_approx(_param(glow, &"size_scale"), 1.0 + GLOW_SIZE * breath)
		and _param(glow, &"dither") == 1.0 and not glow.is_processing(),
		"Glow holds the breathing pose at the requested time")
	var held_strength := _param(glow, &"strength")
	var held_size := _param(glow, &"size_scale")
	UIBackgroundMotion.time_override = 7.5 + GLOW_LOOP
	_check(_param(glow, &"strength") == held_strength and _param(glow, &"size_scale") == held_size,
		"the glow's breath repeats exactly every 12 s")
	var cleared := Time.get_ticks_usec()
	UIBackgroundMotion.time_override = -1.0
	var cleared_from := UIBackgroundMotion.time_for(UIBackgroundMotion.WAVES)
	await _frames(1)
	_check(_running_both(), "clearing time_override resumes motion")
	_check(await _advances(UIBackgroundMotion.WAVES, cleared_from, cleared),
		"the family clock really moves again once the override clears")


func _off_is_exact_static(waves: TextureRect, glow: ColorRect) -> void:
	print("CASE: Animated Backgrounds Off draws the exact static design; On animates again")
	PlayerProfile.animate_backgrounds = false
	PlayerProfile.notify_settings_changed()
	_check(not UIBackgroundMotion.effective_enabled(), "Off disables background motion")
	_assert_static(waves, glow, "with Animated Backgrounds Off")
	await _frames(2)
	_assert_static(waves, glow, "two frames after Off")
	_press_shortcut()
	_check(not UIBackgroundMotion.session_paused, "Ctrl+Shift+M leaves the session pause alone while Off")
	PlayerProfile.animate_backgrounds = true
	PlayerProfile.notify_settings_changed()
	await _frames(1)
	_check(_running_both() and waves.material != null and waves.is_processing() and glow.is_processing(),
		"On animates again on the already-warmed pipelines")
	var on_since := Time.get_ticks_usec()
	var on_from := UIBackgroundMotion.time_for(UIBackgroundMotion.WAVES)
	_check(await _advances(UIBackgroundMotion.WAVES, on_from, on_since), "motion really runs again after On")


func _re_enable_envelope(waves: TextureRect, glow: ColorRect) -> TextureRect:
	print("CASE: turning motion back on eases in from the design over 3 s; pauses and swaps never restart it")
	# Long family clocks keep the Waves first-activation ease at 1, so the shader's ease is the ramp.
	UIBackgroundMotion.seek_family_for_tests(UIBackgroundMotion.WAVES, 30.0)
	UIBackgroundMotion.seek_family_for_tests(UIBackgroundMotion.GLOW, 30.0)
	PlayerProfile.animate_backgrounds = false
	PlayerProfile.notify_settings_changed()
	_check(_envelope(UIBackgroundMotion.WAVES) == 1.0 and _envelope(UIBackgroundMotion.GLOW) == 1.0,
		"disabled motion reports no active ramp")
	# Constrain freezes the ramp, so each step below reads it exactly.
	UIBackgroundMotion.set_constrained(true)
	PlayerProfile.animate_backgrounds = true
	PlayerProfile.notify_settings_changed()
	_check(_paused_both() and _envelope(UIBackgroundMotion.WAVES) == 0.0 and _envelope(UIBackgroundMotion.GLOW) == 0.0,
		"Off -> On restarts both families' ramp at 0")
	_check(_param(waves, &"ease") == 0.0 and _param(glow, &"strength") == 1.0
		and _param(glow, &"size_scale") == 1.0 and _param(glow, &"dither") == 1.0,
		"at ramp 0 the dots rest at the design frame and the glow keeps its design strength and size")
	await _wait(0.1)
	_check(_envelope(UIBackgroundMotion.WAVES) == 0.0 and _envelope(UIBackgroundMotion.GLOW) == 0.0,
		"the ramp does not advance while paused")
	UIBackgroundMotion.seek_envelope_for_tests(UIBackgroundMotion.WAVES, RAMP_SECONDS * 0.5)
	_check(is_equal_approx(_envelope(UIBackgroundMotion.WAVES), 0.5) and _envelope(UIBackgroundMotion.GLOW) == 0.0,
		"each family ramps on its own 3 s smoothstep")
	var ramp := _envelope(UIBackgroundMotion.WAVES)
	_free(waves)
	var next := _waves_adapter("RampWaves")
	_check(is_equal_approx(_envelope(UIBackgroundMotion.WAVES), ramp) and is_equal_approx(_param(next, &"ease"), ramp),
		"a screen swap keeps the ramp, and the next screen's first pose uses it")
	UIBackgroundMotion.time_override = 4.0
	var breath := sin(TAU * 4.0 / GLOW_LOOP)
	_check(_envelope(UIBackgroundMotion.WAVES) == 1.0 and _envelope(UIBackgroundMotion.GLOW) == 1.0
		and is_equal_approx(_param(glow, &"strength"), 1.0 + GLOW_STRENGTH * breath),
		"time_override shows the full, deterministic pose")
	UIBackgroundMotion.time_override = -1.0
	_check(is_equal_approx(_envelope(UIBackgroundMotion.WAVES), ramp) and _envelope(UIBackgroundMotion.GLOW) == 0.0,
		"clearing time_override resumes the stored ramp")
	var resumed := Time.get_ticks_usec()
	UIBackgroundMotion.set_constrained(false)
	await _wait(0.1)
	var progressed := _envelope(UIBackgroundMotion.WAVES)
	_check(_running_both() and progressed > ramp
		and progressed <= _smooth((RAMP_SECONDS * 0.5 + _elapsed(resumed)) / RAMP_SECONDS) + 0.000001,
		"Paused -> Running continues the ramp from where it froze instead of restarting it")
	# Off, then the sign-out reset back to On, during a running ramp: one fresh ramp, never stacked.
	UIBackgroundMotion.set_constrained(true)
	PlayerProfile.animate_backgrounds = false
	PlayerProfile.notify_settings_changed()
	PlayerProfile.reset_to_defaults()
	_check(PlayerProfile.animate_backgrounds and _envelope(UIBackgroundMotion.WAVES) == 0.0
		and _envelope(UIBackgroundMotion.GLOW) == 0.0, "a sign-out reset back to On restarts the ramp from 0")
	UIBackgroundMotion.seek_envelope_for_tests(UIBackgroundMotion.WAVES, RAMP_SECONDS)
	UIBackgroundMotion.seek_envelope_for_tests(UIBackgroundMotion.GLOW, RAMP_SECONDS)
	_check(_envelope(UIBackgroundMotion.WAVES) == 1.0 and _envelope(UIBackgroundMotion.GLOW) == 1.0,
		"the restarted ramp completes after 3 s, with nothing stacked on it")
	UIBackgroundMotion.set_constrained(false)
	await _frames(1)
	_check(_running_both() and _param(next, &"ease") == 1.0, "after the ramp the dots move at full amplitude")
	return next


func _ramps_never_stack(waves: TextureRect, glow: ColorRect) -> void:
	print("CASE: while the Waves first-activation ease and the re-enable ramp overlap, the lower one wins; they never multiply")
	# Constrain freezes the clocks and ramps, so each seeked pose is read exactly.
	UIBackgroundMotion.set_constrained(true)
	var waves_clock := UIBackgroundMotion.time_for(UIBackgroundMotion.WAVES)
	var glow_clock := UIBackgroundMotion.time_for(UIBackgroundMotion.GLOW)
	for overlap: Array in RAMP_OVERLAPS:
		var clock_seconds: float = overlap[0]
		var ramp_seconds: float = overlap[1]
		for family: StringName in [UIBackgroundMotion.WAVES, UIBackgroundMotion.GLOW]:
			UIBackgroundMotion.seek_family_for_tests(family, clock_seconds)
			UIBackgroundMotion.seek_envelope_for_tests(family, ramp_seconds)
		var at := "at clock %.1f s and ramp %.1f s" % [clock_seconds, ramp_seconds]
		var first := _smooth(clock_seconds / FIRST_EASE_SECONDS)
		var ramp := _smooth(ramp_seconds / RAMP_SECONDS)
		_check(_paused_both()
			and absf(UIBackgroundMotion.time_for(UIBackgroundMotion.WAVES) - clock_seconds) <= UNIFORM_EPSILON
			and absf(_envelope(UIBackgroundMotion.WAVES) - ramp) <= UNIFORM_EPSILON
			and absf(_envelope(UIBackgroundMotion.GLOW) - ramp) <= UNIFORM_EPSILON,
			"the seams hold both ramps part-way " + at)
		var applied := _param(waves, &"ease")
		_check(absf(applied - minf(first, ramp)) <= UNIFORM_EPSILON
			and absf(applied - first * ramp) > UNIFORM_EPSILON,
			"Waves eases by the lower of its two ramps, never their product, " + at)
		var breath := sin(TAU * clock_seconds / GLOW_LOOP)
		_check(absf(_param(glow, &"strength") - (1.0 + GLOW_STRENGTH * ramp * breath)) <= UNIFORM_EPSILON
			and absf(_param(glow, &"size_scale") - (1.0 + GLOW_SIZE * ramp * breath)) <= UNIFORM_EPSILON,
			"Glow, which has no first-activation ease, scales its breath by the ramp alone " + at)
	UIBackgroundMotion.seek_family_for_tests(UIBackgroundMotion.WAVES, waves_clock)
	UIBackgroundMotion.seek_family_for_tests(UIBackgroundMotion.GLOW, glow_clock)
	UIBackgroundMotion.seek_envelope_for_tests(UIBackgroundMotion.WAVES, RAMP_SECONDS)
	UIBackgroundMotion.seek_envelope_for_tests(UIBackgroundMotion.GLOW, RAMP_SECONDS)
	UIBackgroundMotion.set_constrained(false)
	await _frames(1)
	_check(_running_both() and _param(waves, &"ease") == 1.0,
		"with the long clocks and the finished ramp restored, the dots move at full amplitude again")


func _phase_survives_swaps(waves: TextureRect) -> TextureRect:
	print("CASE: each family keeps its own phase across screen swaps, without a rest-frame flash")
	var seeked := Time.get_ticks_usec()
	UIBackgroundMotion.seek_family_for_tests(UIBackgroundMotion.WAVES, 20.0)
	UIBackgroundMotion.seek_family_for_tests(UIBackgroundMotion.GLOW, 3.0)
	await _frames(2)
	_free(waves)
	_check(_state(UIBackgroundMotion.WAVES) == UIBackgroundMotion.STATE_PAUSED
		and _state(UIBackgroundMotion.GLOW) == UIBackgroundMotion.STATE_RUNNING,
		"leaving the last Waves screen holds only the Waves clock")
	var held := UIBackgroundMotion.time_for(UIBackgroundMotion.WAVES)
	await _wait(0.2)
	_check(UIBackgroundMotion.time_for(UIBackgroundMotion.WAVES) == held and _resumed_from(held, 20.0, seeked),
		"the Waves clock holds while no Waves screen is shown")
	var glow_time := UIBackgroundMotion.time_for(UIBackgroundMotion.GLOW)
	_check(glow_time > 3.0 and _resumed_from(glow_time, 3.0, seeked), "the Glow clock runs on independently")
	var added := Time.get_ticks_usec()
	var next := _waves_adapter("NextWaves")
	_check(next.material != null and _resumed_from(_param(next, &"t_phase"), held, added),
		"the next Waves screen's first pose continues the held phase, not the rest pose")
	await _frames(1)
	_check(_state(UIBackgroundMotion.WAVES) == UIBackgroundMotion.STATE_RUNNING and next.is_processing(),
		"the Waves clock runs again with the next Waves screen")
	var swap_since := Time.get_ticks_usec()
	var swap_from := UIBackgroundMotion.time_for(UIBackgroundMotion.WAVES)
	_check(await _advances(UIBackgroundMotion.WAVES, swap_from, swap_since),
		"the Waves clock really advances on the next Waves screen")
	return next


func _constrain_freezes_pose(waves: TextureRect, glow: ColorRect) -> void:
	print("CASE: constrain (focus loss or the Guide) freezes the current pose instead of going static")
	await _frames(2)
	UIBackgroundMotion.set_constrained(true)
	var held := UIBackgroundMotion.time_for(UIBackgroundMotion.WAVES)
	var glow_held := UIBackgroundMotion.time_for(UIBackgroundMotion.GLOW)
	var waves_pose := _param(waves, &"t_phase")
	var glow_pose := _param(glow, &"strength")
	await _wait(0.2)
	_check(_paused_both() and UIBackgroundMotion.time_for(UIBackgroundMotion.WAVES) == held,
		"constrain holds both clocks")
	_check(waves.material != null and waves.get_child_count() == 1 and not waves.is_processing()
		and _param(waves, &"t_phase") == waves_pose, "Waves keeps its frozen pose and materials while constrained")
	_check(_param(glow, &"dither") == 1.0 and _param(glow, &"strength") == glow_pose and not glow.is_processing(),
		"Glow keeps its frozen breathing pose while constrained")
	var resumed := Time.get_ticks_usec()
	UIBackgroundMotion.set_constrained(false)
	_check(_resumed_from(UIBackgroundMotion.time_for(UIBackgroundMotion.WAVES), held, resumed),
		"unconstrain resumes from the frozen phase without a jump")
	await _frames(1)
	_check(_running_both() and waves.is_processing() and glow.is_processing(), "motion resumes after unconstrain")
	_check(await _advances(UIBackgroundMotion.WAVES, held, resumed)
		and await _advances(UIBackgroundMotion.GLOW, glow_held, resumed),
		"both clocks really advance from their frozen phases after unconstrain")


func _dialog_and_hide_hold_the_clock() -> void:
	print("CASE: a dialog over the screen or hiding it holds the clocks; closing resumes without a jump")
	for hidden: bool in [false, true]:
		var cause := "hiding the screen" if hidden else "a dialog over the screen"
		await _frames(1)
		if hidden:
			_screen.visible = false
		else:
			# What ScreenManager does to the screen under a dialog: still visible, not processing.
			_screen.process_mode = Node.PROCESS_MODE_DISABLED
		var held := UIBackgroundMotion.time_for(UIBackgroundMotion.WAVES)
		await _wait(0.15)
		_check(_paused_both() and UIBackgroundMotion.time_for(UIBackgroundMotion.WAVES) == held,
			cause + " holds both clocks")
		var resumed := Time.get_ticks_usec()
		if hidden:
			_screen.visible = true
		else:
			_screen.process_mode = Node.PROCESS_MODE_INHERIT
		_check(_resumed_from(UIBackgroundMotion.time_for(UIBackgroundMotion.WAVES), held, resumed),
			"ending " + cause + " resumes from the held phase without a jump")
		await _frames(1)
		_check(_running_both(), "motion runs again after " + cause)
		_check(await _advances(UIBackgroundMotion.WAVES, held, resumed),
			"the Waves clock really advances from the held phase after " + cause)


func _nested_pause_reasons(waves: TextureRect, glow: ColorRect) -> void:
	print("CASE: nested pause reasons hold motion until the last one is released")
	UIBackgroundMotion.session_paused = true
	UIBackgroundMotion.set_constrained(true)
	_screen.process_mode = Node.PROCESS_MODE_DISABLED
	var held := UIBackgroundMotion.time_for(UIBackgroundMotion.WAVES)
	PlayerProfile.animate_backgrounds = false
	PlayerProfile.notify_settings_changed()
	_assert_static(waves, glow, "when Off is chosen while paused")
	PlayerProfile.animate_backgrounds = true
	PlayerProfile.notify_settings_changed()
	_check(_paused_both() and waves.get_child_count() == 1 and _param(glow, &"dither") == 1.0
		and UIBackgroundMotion.time_for(UIBackgroundMotion.WAVES) == held,
		"turning the preference back On while still paused keeps the frozen phase")
	var releases: Array[Callable] = [
		UIBackgroundMotion.set_constrained.bind(false),
		_screen.set_process_mode.bind(Node.PROCESS_MODE_INHERIT),
		UIBackgroundMotion.set.bind(&"session_paused", false),
	]
	var resumed := 0
	for index in releases.size():
		await _wait(0.05)
		_check(_paused_both() and UIBackgroundMotion.time_for(UIBackgroundMotion.WAVES) == held,
			"motion holds while %d pause reason(s) remain" % (releases.size() - index))
		resumed = Time.get_ticks_usec()
		releases[index].call()
	_check(_resumed_from(UIBackgroundMotion.time_for(UIBackgroundMotion.WAVES), held, resumed),
		"releasing the last pause reason resumes without a jump")
	await _frames(1)
	_check(_running_both(), "motion runs once every pause reason is released")
	_check(await _advances(UIBackgroundMotion.WAVES, held, resumed),
		"the Waves clock really advances from the held phase once every reason is released")


func _toggle_action(waves: TextureRect, glow: ColorRect) -> void:
	print("CASE: Ctrl+Shift+M / View pauses and resumes motion for the session with a frozen pose")
	var profile := PlayerProfile.to_dict()
	_press_shortcut()
	_check(UIBackgroundMotion.session_paused and _paused_both(), "Ctrl+Shift+M pauses background motion")
	var held := UIBackgroundMotion.time_for(UIBackgroundMotion.WAVES)
	await _wait(0.1)
	_check(UIBackgroundMotion.time_for(UIBackgroundMotion.WAVES) == held and waves.get_child_count() == 1
		and not waves.is_processing() and _param(glow, &"dither") == 1.0 and not glow.is_processing(),
		"the Ctrl+Shift+M pause holds a frozen pose, not the static design")
	var echo := InputEventKey.new()
	echo.keycode = KEY_M
	echo.physical_keycode = KEY_M
	echo.ctrl_pressed = true
	echo.shift_pressed = true
	echo.pressed = true
	echo.echo = true
	_test.get_viewport().push_input(echo, true)
	_check(UIBackgroundMotion.session_paused, "a held Ctrl+Shift+M (key repeat) does not toggle again")
	var resumed := Time.get_ticks_usec()
	_press_joy(JOY_BUTTON_BACK)
	_check(not UIBackgroundMotion.session_paused, "View resumes background motion")
	await _frames(1)
	_check(_running_both(), "motion runs again after View")
	_check(await _advances(UIBackgroundMotion.WAVES, held, resumed), "the Waves clock really advances after View")
	_check(PlayerProfile.to_dict() == profile, "the session pause never changes account settings")
	_screen.visible = false
	_press_shortcut()
	_check(not UIBackgroundMotion.session_paused, "Ctrl+Shift+M does nothing while no UI background is visible")
	_screen.visible = true
	await _frames(1)


## The keyboard shortcut is exactly Ctrl+Shift+M: any other key or set of modifiers passes through,
## so the letter typed into a text field still reaches it.
func _shortcut_needs_exact_keys() -> void:
	print("CASE: only exactly Ctrl+Shift+M, or View, toggles the pause; typing M into the join code is unaffected")
	_press_shortcut()
	_check(UIBackgroundMotion.session_paused, "Ctrl+Shift+M toggles the session pause on")
	_press_shortcut()
	_check(not UIBackgroundMotion.session_paused, "Ctrl+Shift+M toggles the session pause off again")
	_press_joy(JOY_BUTTON_BACK)
	_check(UIBackgroundMotion.session_paused, "View toggles the session pause on")
	_press_joy(JOY_BUTTON_BACK)
	_check(not UIBackgroundMotion.session_paused, "View toggles the session pause off again")
	# Each entry: key, Ctrl, Shift, Alt.
	var near_misses := {
		"F8": [KEY_F8, false, false, false],
		"M": [KEY_M, false, false, false],
		"Shift+M": [KEY_M, false, true, false],
		"Ctrl+M": [KEY_M, true, false, false],
		"Ctrl+Shift+Alt+M": [KEY_M, true, true, true],
	}
	for combo: String in near_misses:
		var keys: Array = near_misses[combo]
		_press_key(keys[0], keys[1], keys[2], keys[3])
		_check(not UIBackgroundMotion.session_paused, combo + " does not toggle the pause")
	var entry := JOIN_CODE_ENTRY.instantiate() as Control
	_screen.add_child(entry)
	await _frames(2)
	var field := entry.find_child("LineEdit", true, false) as LineEdit
	_check(field != null and field.has_focus() and field.is_editing(), "fixture: the join-code field is focused for typing")
	_press_key(KEY_M, false, false, false, "m".unicode_at(0))
	_press_key(KEY_M, false, true, false, "M".unicode_at(0))
	_check(not UIBackgroundMotion.session_paused, "m and Shift+M in the join-code field never toggle the session pause")
	# LineEdit reports the edit on the next frame, when the entry upper-cases the code.
	await _frames(1)
	_check(field != null and field.text == "MM", "m and Shift+M type into the join-code field")
	_free(entry)
	await _frames(1)
	_check(not UIBackgroundMotion.session_paused and _running_both(),
		"after typing into the join-code field, both families still run with no session pause")


## Suspension is its own pause reason. main.gd sets it once the suspend save is done and resume
## clears only it: with no other reason, motion continues from the frozen pose without catching up
## the suspended time, while a focus loss or the session pause still holds motion until it ends too.
func _suspend_freezes_motion(waves: TextureRect, glow: ColorRect) -> void:
	print("CASE: suspend saves first, then freezes both clocks and ramps until resume, with no focus change")
	await _test._reset()
	var store := SuspendOrderSaves.new()
	Services._game_saves = store
	_test._select("background-motion-suspend", _test._folder())
	_check(await Services.sign_in(), "a ready account, so the suspend handler really saves")
	var old_container: Node = ScreenManager._container
	var app: Node = preload("res://scenes/main.tscn").instantiate()
	app.set_script(MainProbe)
	_test.add_child(app)
	var seeked := Time.get_ticks_usec()
	UIBackgroundMotion.seek_envelope_for_tests(UIBackgroundMotion.WAVES, RAMP_SECONDS * 0.5)
	UIBackgroundMotion.seek_envelope_for_tests(UIBackgroundMotion.GLOW, RAMP_SECONDS * 0.25)
	await _frames(1)
	_check(_running_both() and _envelope(UIBackgroundMotion.WAVES) < 1.0 and _envelope(UIBackgroundMotion.GLOW) < 1.0,
		"both families run, part-way up their ramps, before the suspend")
	store.suspended_at_writes.clear()
	app.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	var suspended := Time.get_ticks_usec()
	_check(store.suspended_at_writes.size() >= 3 and not store.suspended_at_writes.has(true)
		and UIBackgroundMotion.is_suspended(), "the suspend handler saves every payload before it suspends motion")
	var waves_held := UIBackgroundMotion.time_for(UIBackgroundMotion.WAVES)
	var glow_held := UIBackgroundMotion.time_for(UIBackgroundMotion.GLOW)
	var waves_ramp := _envelope(UIBackgroundMotion.WAVES)
	var glow_ramp := _envelope(UIBackgroundMotion.GLOW)
	var waves_pose := _param(waves, &"t_phase")
	var glow_pose := _param(glow, &"strength")
	_check(_paused_both() and not UIBackgroundMotion.is_constrained() and not UIBackgroundMotion.session_paused
		and waves.get_child_count() == 1 and not waves.is_processing()
		and _param(glow, &"dither") == 1.0 and not glow.is_processing(),
		"suspension alone, with no focus loss, freezes both families in their current pose")
	await _wait(0.15)
	_check(UIBackgroundMotion.time_for(UIBackgroundMotion.WAVES) == waves_held
		and UIBackgroundMotion.time_for(UIBackgroundMotion.GLOW) == glow_held
		and _param(waves, &"t_phase") == waves_pose and _param(glow, &"strength") == glow_pose,
		"neither clock nor the drawn pose moves while the title is suspended")
	_check(_envelope(UIBackgroundMotion.WAVES) == waves_ramp and _envelope(UIBackgroundMotion.GLOW) == glow_ramp,
		"neither part-way ramp moves while the title is suspended")
	var resumed := Time.get_ticks_usec()
	app.notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	_check(not UIBackgroundMotion.is_suspended()
		and _resumed_from(UIBackgroundMotion.time_for(UIBackgroundMotion.WAVES), waves_held, resumed)
		and _resumed_from(UIBackgroundMotion.time_for(UIBackgroundMotion.GLOW), glow_held, resumed),
		"resume, with no focus change, clears suspension and both clocks continue from their frozen phases")
	await _frames(1)
	_check(_running_both() and waves.is_processing() and glow.is_processing(),
		"with no other pause reason, both families run again after resume")
	_check(await _advances(UIBackgroundMotion.WAVES, waves_held, resumed)
		and await _advances(UIBackgroundMotion.GLOW, glow_held, resumed),
		"both clocks really advance after resume")
	# Each ramp ran from its seek until the suspend and again since the resume, never in between.
	var before_suspend := float(suspended - seeked) / 1000000.0
	var waves_bound := _smooth((RAMP_SECONDS * 0.5 + before_suspend + _elapsed(resumed)) / RAMP_SECONDS)
	var glow_bound := _smooth((RAMP_SECONDS * 0.25 + before_suspend + _elapsed(resumed)) / RAMP_SECONDS)
	_check(_envelope(UIBackgroundMotion.WAVES) > waves_ramp
		and _envelope(UIBackgroundMotion.WAVES) <= waves_bound + UNIFORM_EPSILON
		and _envelope(UIBackgroundMotion.GLOW) > glow_ramp
		and _envelope(UIBackgroundMotion.GLOW) <= glow_bound + UNIFORM_EPSILON,
		"both ramps continue from where the suspend froze them, without the suspended time")

	print("CASE: resume clears only suspension; the session pause and a focus loss still hold motion until focus returns")
	app.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	UIBackgroundMotion.session_paused = true
	app.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	var held := UIBackgroundMotion.time_for(UIBackgroundMotion.WAVES)
	app.notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	await _wait(0.1)
	_check(not UIBackgroundMotion.is_suspended() and UIBackgroundMotion.is_constrained()
		and UIBackgroundMotion.session_paused and _paused_both()
		and UIBackgroundMotion.time_for(UIBackgroundMotion.WAVES) == held,
		"resume leaves the focus loss and the session pause in place, so motion stays paused")
	UIBackgroundMotion.session_paused = false
	await _wait(0.05)
	_check(UIBackgroundMotion.is_constrained() and _paused_both()
		and UIBackgroundMotion.time_for(UIBackgroundMotion.WAVES) == held,
		"after resume and the end of the session pause, the focus loss alone still holds the clock")
	var focused := Time.get_ticks_usec()
	app.notification(Node.NOTIFICATION_APPLICATION_FOCUS_IN)
	await _frames(1)
	_check(not UIBackgroundMotion.is_constrained() and _running_both()
		and await _advances(UIBackgroundMotion.WAVES, held, focused),
		"focus return, the last pause reason, runs motion again from the held phase")
	# Each resume routed the probe to the sign-in screen; it goes with the probe.
	ScreenManager.clear()
	await _frames(1)
	_test.remove_child(app)
	app.queue_free()
	# The account reset below signs out. The probe must be gone by then, or its account-loss route
	# pushes the sign-in screen into whatever container is current.
	await _frames(1)
	ScreenManager.set_container(old_container)
	UIBackgroundMotion.set_suspended(false)
	UIBackgroundMotion.set_constrained(false)
	UIBackgroundMotion.session_paused = false
	await _test._reset()
	await _frames(1)


func _motion_hint_follows_shortcut() -> void:
	print("CASE: the Ctrl+Shift+M / View hint on loading and the title shows exactly while the shortcut can act")
	var old_container: Node = ScreenManager._container
	ScreenManager.set_container(_screen)
	for path: String in [ScreenManager.LOADING, ScreenManager.ACQUIRE_USER]:
		var screen: Node = ScreenManager.replace_all(path, {"message": "Loading match...", "allow_cancel": false}) \
			if path == ScreenManager.LOADING else ScreenManager.replace_all(path)
		await _frames(2)
		var label := path.get_file().get_basename()
		var hint: Label = null
		if screen != null:
			hint = screen.find_child("MotionHintLabel", true, false) as Label
		_check(hint != null and UIBackgroundMotion.shortcut_available() and hint.is_visible_in_tree()
			and hint.text == "Ctrl+Shift+M / View pauses background motion", label + " shows the hint while motion runs")
		if hint == null:
			continue
		UIBackgroundMotion.session_paused = true
		_check(hint.is_visible_in_tree(), label + " keeps the hint while paused, so Ctrl+Shift+M / View can resume")
		UIBackgroundMotion.session_paused = false
		PlayerProfile.animate_backgrounds = false
		PlayerProfile.notify_settings_changed()
		_check(not UIBackgroundMotion.shortcut_available() and not hint.is_visible_in_tree(),
			label + " hides the hint once Animated Backgrounds is Off")
		PlayerProfile.animate_backgrounds = true
		PlayerProfile.notify_settings_changed()
		_check(hint.is_visible_in_tree(), label + " shows the hint again when motion is back On")
	ScreenManager.clear()
	await _frames(2)
	ScreenManager.set_container(old_container)


## Windowed runs only: the glow drawn by the GPU at 1080p. Off must match the designer's export.
## Breathing composites the design's stops in float and rounds once over screen-fixed TPDF noise,
## so its first frame differs from Off by a few code values; its noise never moves between frames,
## its 12 s breath repeats exactly, and its hotspot keeps the design's full breathing range.
func _glow_renders() -> void:
	print("CASE: the Off glow renders the designer's 1080p export (MAE <= %.2f/255, max <= %d)" % [GLOW_MAX_MAE, GLOW_MAX_ERROR])
	var reference := Image.load_from_file(ProjectSettings.globalize_path(DESIGNER_GLOW))
	var reference_loaded := reference != null and reference.get_width() == 1920 and reference.get_height() == 1080
	_check(reference_loaded, "the designer glow fixture loads")
	if not reference_loaded:
		return
	_check(not UIBackgroundMotion.effective_enabled(), "nothing warmed motion, so the glow is in its Off state")
	var off := await _render_glow(-1.0)
	if off.is_empty():
		return
	reference.convert(Image.FORMAT_RGB8)
	var designer := _compare_frames(reference.get_data(), off)
	_check(designer["mae"] <= GLOW_MAX_MAE and designer["max"] <= GLOW_MAX_ERROR,
		"Off glow vs the designer's export: MAE %.4f/255, max %d" % [designer["mae"], designer["max"]])

	print("CASE: the first breathing frame stays within %d code values of Off, with a mean offset <= %.0f"
		% [BREATHING_MAX_FROM_OFF, BREATHING_MEAN_FROM_OFF])
	var first := await _render_glow(0.0)
	if first.is_empty():
		return
	var from_off := _compare_frames(off, first)
	var offsets: PackedFloat64Array = from_off["means"]
	_check(from_off["max"] <= BREATHING_MAX_FROM_OFF, "breathing at t = 0 vs Off: max %d" % from_off["max"])
	_check(absf(offsets[0]) <= BREATHING_MEAN_FROM_OFF and absf(offsets[1]) <= BREATHING_MEAN_FROM_OFF
		and absf(offsets[2]) <= BREATHING_MEAN_FROM_OFF,
		"breathing at t = 0 vs Off: mean offset R %+.3f, G %+.3f, B %+.3f" % [offsets[0], offsets[1], offsets[2]])
	_check_outside_glow(off, first)

	print("CASE: breathing noise is screen-fixed and the 12 s breath repeats exactly")
	var bright := await _render_glow(GLOW_LOOP * 0.25)
	var again := await _render_glow(GLOW_LOOP * 0.25)
	var next_loop := await _render_glow(GLOW_LOOP * 1.25)
	var dim := await _render_glow(GLOW_LOOP * 0.75)
	if bright.is_empty() or again.is_empty() or next_loop.is_empty() or dim.is_empty():
		return
	_check(again == bright, "two renders of the same frozen pose (t = 3 s) are pixel-identical")
	_check(next_loop == bright, "t = 15 s renders pixel-identically to t = 3 s")

	print("CASE: the hotspot still breathes over the design's full range")
	var rendered_bright := _hotspot_means(bright)
	var rendered_dim := _hotspot_means(dim)
	var design_bright := _design_hotspot_means(1.0 + GLOW_STRENGTH, 1.0 + GLOW_SIZE)
	var design_dim := _design_hotspot_means(1.0 - GLOW_STRENGTH, 1.0 - GLOW_SIZE)
	var ranges_match := true
	var ranges := PackedStringArray()
	for channel in 3:
		var rendered_range := rendered_bright[channel] - rendered_dim[channel]
		var design_range := design_bright[channel] - design_dim[channel]
		ranges_match = ranges_match and absf(rendered_range - design_range) <= HOTSPOT_RANGE_TOLERANCE
		ranges.append("%.2f/%.2f" % [rendered_range, design_range])
	_check(ranges_match, "hotspot breathing range, rendered/design (R G B): " + " ".join(ranges))


## One glow drawn by the GPU at 1920x1080 and read back as RGB8 bytes. A negative `pose_time` is the
## Off design, with the adapter on the unwarmed controller. Otherwise the adapter's preparation seam
## draws the animated pose at that time, with no clock, ramp or registration. Empty when the window
## does not draw in time.
func _render_glow(pose_time: float) -> PackedByteArray:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1920, 1080)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var glow := ColorRect.new()
	glow.color = BASE
	glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	glow.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	glow.set_script(GlowBackground)
	if pose_time >= 0.0:
		glow.set(&"preparation_time_override", pose_time)
	viewport.add_child(glow)
	_test.add_child(viewport)
	var frames_drawn := await _drawn_frames(3, FRAME_TIMEOUT_MSEC)
	var rendered: Image = viewport.get_texture().get_image() if frames_drawn else null
	_test.remove_child(viewport)
	viewport.queue_free()
	if rendered == null or rendered.get_width() != 1920 or rendered.get_height() != 1080:
		_check(false, "the GPU drew the glow (pose %.2f s) at 1920x1080 within %d ms" % [pose_time, FRAME_TIMEOUT_MSEC])
		return PackedByteArray()
	rendered.convert(Image.FORMAT_RGB8)
	return rendered.get_data()


## Byte-wise `b - a` over two RGB8 frames of the same size: the largest absolute difference, the
## mean absolute difference and each channel's mean signed difference.
static func _compare_frames(a: PackedByteArray, b: PackedByteArray) -> Dictionary:
	var worst := 0
	var total := 0
	var red := 0
	var green := 0
	var blue := 0
	for index in range(0, a.size(), 3):
		var dr := b[index] - a[index]
		var dg := b[index + 1] - a[index + 1]
		var db := b[index + 2] - a[index + 2]
		red += dr
		green += dg
		blue += db
		var magnitude := absi(dr) + absi(dg) + absi(db)
		total += magnitude
		if magnitude > worst:
			worst = maxi(worst, maxi(absi(dr), maxi(absi(dg), absi(db))))
	var pixels := float(a.size()) / 3.0
	return {
		"max": worst,
		"mae": float(total) / float(a.size()),
		"means": PackedFloat64Array([red / pixels, green / pixels, blue / pixels]),
	}


## Below the glow's ellipse, Off is exactly #050505. The breathing noise has no boundary gate, so the
## first breathing frame is not exact there: one TPDF value shared by R, G and B rounds 5 to 4, 5 or
## 6, averaging 5. That is zero mean bias, not pixel-exactness.
func _check_outside_glow(off: PackedByteArray, first: PackedByteArray) -> void:
	var exact := true
	var grey := true
	var within := true
	var total := 0
	var fours := 0
	var sixes := 0
	var start := OUTSIDE_GLOW_FIRST_ROW * 1920 * 3
	for index in range(start, off.size(), 3):
		exact = exact and off[index] == 5 and off[index + 1] == 5 and off[index + 2] == 5
		var value := first[index]
		grey = grey and first[index + 1] == value and first[index + 2] == value
		within = within and value >= 4 and value <= 6
		total += value
		if value == 4:
			fours += 1
		elif value == 6:
			sixes += 1
	var mean := float(total) / (float(off.size() - start) / 3.0)
	_check(exact, "Off is exactly #050505 below the glow")
	_check(grey and within, "below the glow, the breathing noise is one value for R, G and B, within 1 of 5")
	_check(absf(mean - GLOW_BASE_CODE) <= OUTSIDE_GLOW_MEAN_TOLERANCE and fours > 0 and sixes > 0,
		"below the glow, breathing rounds 5 to 4, 5 or 6 (mean %.3f): zero bias, not exact" % mean)


## Each channel's mean code value over the hotspot window of a 1920x1080 RGB8 frame.
static func _hotspot_means(frame: PackedByteArray) -> PackedFloat64Array:
	var sums := PackedFloat64Array([0.0, 0.0, 0.0])
	for y in range(HOTSPOT_Y - HOTSPOT_HALF, HOTSPOT_Y + HOTSPOT_HALF):
		for x in range(HOTSPOT_X - HOTSPOT_HALF, HOTSPOT_X + HOTSPOT_HALF):
			var index := (y * 1920 + x) * 3
			for channel in 3:
				sums[channel] += frame[index + channel]
	for channel in 3:
		sums[channel] /= float(4 * HOTSPOT_HALF * HOTSPOT_HALF)
	return sums


## The design's float composite over the same window, before any quantization: the stop's colour
## and alpha fall linearly to 0 at the ellipse and composite unpremultiplied over the #050505 base.
static func _design_hotspot_means(strength: float, size_scale: float) -> PackedFloat64Array:
	var sums := PackedFloat64Array([0.0, 0.0, 0.0])
	for y in range(HOTSPOT_Y - HOTSPOT_HALF, HOTSPOT_Y + HOTSPOT_HALF):
		for x in range(HOTSPOT_X - HOTSPOT_HALF, HOTSPOT_X + HOTSPOT_HALF):
			var dx := (x + 0.5 - GLOW_CENTRE_X) / (GLOW_RADIUS_X * size_scale)
			var dy := (y + 0.5 - GLOW_CENTRE_Y) / (GLOW_RADIUS_Y * size_scale)
			var r := clampf(1.0 - sqrt(dx * dx + dy * dy), 0.0, 1.0)
			var alpha := GLOW_ALPHA * r * strength
			for channel in 3:
				var stop: float = GLOW_STOP[channel]
				sums[channel] += stop * r * alpha + GLOW_BASE_CODE * (1.0 - alpha)
	for channel in 3:
		sums[channel] /= float(4 * HOTSPOT_HALF * HOTSPOT_HALF)
	return sums


func _assert_static(waves: TextureRect, glow: ColorRect, when: String) -> void:
	_assert_static_waves(waves, when)
	_check(_shader_path(glow) == GLOW_SHADER and _param(glow, &"strength") == 1.0
		and _param(glow, &"size_scale") == 1.0 and _param(glow, &"dither") == 0.0
		and glow.color.is_equal_approx(BASE) and not glow.is_processing(),
		"Glow is its undithered design state " + when)


## The Off path is the designer TextureRect alone: no material, no dot layers, no processing.
func _assert_static_waves(waves: TextureRect, when: String) -> void:
	_check(waves.material == null and waves.get_child_count() == 0 and not waves.is_processing()
		and waves.texture == Assets.texture("Background_Waves")
		and waves.expand_mode == TextureRect.EXPAND_IGNORE_SIZE
		and waves.stretch_mode == TextureRect.STRETCH_KEEP_ASPECT_COVERED,
		"Waves is the exact static TextureRect " + when)


func _waves_adapter(node_name: String) -> TextureRect:
	var waves := TextureRect.new()
	waves.name = node_name
	waves.texture = Assets.texture("Background_Waves")
	waves.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	waves.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	waves.mouse_filter = Control.MOUSE_FILTER_IGNORE
	waves.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	waves.set_script(WavesBackground)
	_screen.add_child(waves)
	return waves


func _glow_adapter(node_name: String) -> ColorRect:
	var glow := ColorRect.new()
	glow.name = node_name
	glow.color = BASE
	glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	glow.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	glow.set_script(GlowBackground)
	_screen.add_child(glow)
	return glow


## Plays the renderer for an in-flight warm-up: one drawn frame per process frame.
func _draw_until_warmed() -> bool:
	for frame in 30:
		if UIBackgroundMotion.is_warmed():
			return true
		RenderingServer.frame_post_draw.emit()
		await _frames(1)
	return UIBackgroundMotion.is_warmed()


func _has_warm_up_nodes() -> bool:
	for path: NodePath in WARM_UP_NODES:
		if _screen.get_node_or_null(path) != null:
			return true
	return false


## True when main.gd added no retry cover and no warm-up runs or remains anywhere in the app, so
## motion is still cold.
func _retry_skipped(app: Node) -> bool:
	if app.get_node_or_null(COVER_NAME) != null or UIBackgroundMotion.is_preparing() or UIBackgroundMotion.is_warmed():
		return false
	return not _warm_up_in_app(app)


## True while any warm-up draw is anywhere in the app's tree.
func _warm_up_in_app(app: Node) -> bool:
	for path: NodePath in WARM_UP_NODES:
		if app.find_child(String(path), true, false) != null:
			return true
	return false


## The warm-up covers main.gd has in place; a second one would take a generated name.
func _covers(app: Node) -> int:
	var count := 0
	for child: Node in app.get_children():
		if child is CanvasLayer and String(child.name).contains(String(COVER_NAME)):
			count += 1
	return count


## Ends the warm-up in flight as a failure on its next frame, as if its draws never reached the
## screen: the controller only counts frames while its warm-up nodes stay visible.
func _fail_warm_up(app: Node) -> void:
	var warm_up := app.find_child(String(WARM_UP_NODES[0]), true, false) as CanvasItem
	_check(warm_up != null, "fixture: a warm-up is in flight")
	if warm_up != null:
		warm_up.hide()


## True while a warm-up's Waves draw is in the app and visible, as a newly started warm-up's is.
func _warm_up_drawing(app: Node) -> bool:
	var warm_up := app.find_child(String(WARM_UP_NODES[0]), true, false) as CanvasItem
	return warm_up != null and warm_up.is_visible_in_tree()


## True once RenderingServer reports `count` drawn frames, false when `timeout_msec` passes on the
## monotonic clock first. It never awaits frame_post_draw itself, so a window that stops drawing
## fails the case instead of hanging the suite, and the counter is always disconnected.
func _drawn_frames(count: int, timeout_msec: int) -> bool:
	var drawn := [0]
	var counter := func() -> void: drawn[0] += 1
	RenderingServer.frame_post_draw.connect(counter)
	var deadline := Time.get_ticks_msec() + timeout_msec
	while drawn[0] < count and Time.get_ticks_msec() < deadline:
		await _test.get_tree().process_frame
	RenderingServer.frame_post_draw.disconnect(counter)
	return drawn[0] >= count


## The cover must really hide the warm-up: an effectively visible, opaque #050505 rect over the
## whole viewport, on a canvas layer above every background and warm-up draw.
func _assert_cover(app: Node, label: String) -> void:
	var layer := app.get_node_or_null(COVER_NAME) as CanvasLayer
	var cover: ColorRect = null
	if layer != null:
		for child: Node in layer.get_children():
			if child is ColorRect:
				cover = child as ColorRect
	_check(layer != null and cover != null, label + " adds its cover")
	if layer == null or cover == null:
		return
	var covered := cover.get_global_transform_with_canvas() * Rect2(Vector2.ZERO, cover.size)
	_check(layer.visible and cover.is_visible_in_tree()
		and covered.encloses(cover.get_viewport().get_visible_rect()),
		label + " cover is effectively visible over the whole viewport")
	_check(cover.color.is_equal_approx(BASE) and cover.color.a == 1.0 and _effective_alpha(cover) == 1.0,
		label + " cover is opaque #050505")
	var hidden: Array[Node] = _test.get_tree().get_nodes_in_group(UIBackgroundMotion.BACKGROUND_GROUP)
	for path: NodePath in WARM_UP_NODES:
		var warm_up := app.find_child(String(path), true, false)
		if warm_up != null:
			hidden.append(warm_up)
	var above := not hidden.is_empty()
	for node: Node in hidden:
		above = above and layer.layer > _canvas_layer_of(node)
	_check(above, label + " cover is ordered above every background and warm-up draw")


## The CanvasLayer index a node draws on; 0 is the viewport's default canvas.
func _canvas_layer_of(node: Node) -> int:
	var parent := node.get_parent()
	while parent != null and not parent is Viewport:
		if parent is CanvasLayer:
			return (parent as CanvasLayer).layer
		parent = parent.get_parent()
	return 0


func _effective_alpha(item: CanvasItem) -> float:
	var alpha := item.self_modulate.a
	var node: Node = item
	while node is CanvasItem:
		alpha *= (node as CanvasItem).modulate.a
		node = node.get_parent()
	return alpha


func _envelope(family: StringName) -> float:
	return UIBackgroundMotion.envelope_for(family)


static func _smooth(x: float) -> float:
	var t := clampf(x, 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


func _elapsed(since_usec: int) -> float:
	return float(Time.get_ticks_usec() - since_usec) / 1000000.0


## A clock that resumed from `held` no earlier than `since_usec` may have gained at most the real
## time measured since then: no fixed ceiling, so scheduling delays cannot fail it.
func _resumed_from(value: float, held: float, since_usec: int) -> bool:
	return value >= held and value <= held + _elapsed(since_usec) + 0.000001


## A running family's clock really moves: after a short real wait it is strictly past `from` (read
## no earlier than `since_usec`), and it gained no more than the real time measured since then.
func _advances(family: StringName, from: float, since_usec: int) -> bool:
	await _wait(0.05)
	var now := UIBackgroundMotion.time_for(family)
	return now > from and now <= from + _elapsed(since_usec) + 0.000001


func _state(family: StringName) -> int:
	return UIBackgroundMotion.state_for(family)


func _running_both() -> bool:
	return _state(UIBackgroundMotion.WAVES) == UIBackgroundMotion.STATE_RUNNING \
		and _state(UIBackgroundMotion.GLOW) == UIBackgroundMotion.STATE_RUNNING


func _paused_both() -> bool:
	return _state(UIBackgroundMotion.WAVES) == UIBackgroundMotion.STATE_PAUSED \
		and _state(UIBackgroundMotion.GLOW) == UIBackgroundMotion.STATE_PAUSED


func _param(item: CanvasItem, parameter: StringName) -> float:
	var shader_material := item.material as ShaderMaterial
	if shader_material == null:
		return NAN
	var value: Variant = shader_material.get_shader_parameter(parameter)
	if value is float or value is int:
		return float(value)
	return NAN


func _shader_path(item: CanvasItem) -> String:
	var shader_material := item.material as ShaderMaterial
	if shader_material == null or shader_material.shader == null:
		return ""
	return shader_material.shader.resource_path


## A press and release of `key` with the given modifiers, as a keyboard reports them; `unicode` is
## the character the press types, or 0.
func _press_key(key: Key, ctrl := false, shift := false, alt := false, unicode := 0) -> void:
	var event := InputEventKey.new()
	event.keycode = key
	event.physical_keycode = key
	event.ctrl_pressed = ctrl
	event.shift_pressed = shift
	event.alt_pressed = alt
	event.unicode = unicode
	event.pressed = true
	_test.get_viewport().push_input(event, true)
	var release := event.duplicate() as InputEventKey
	release.pressed = false
	_test.get_viewport().push_input(release, true)


## The keyboard pause shortcut, Ctrl+Shift+M.
func _press_shortcut() -> void:
	_press_key(KEY_M, true, true)


func _press_joy(button: JoyButton) -> void:
	var event := InputEventJoypadButton.new()
	event.button_index = button
	event.pressed = true
	_test.get_viewport().push_input(event, true)
	var release := event.duplicate() as InputEventJoypadButton
	release.pressed = false
	_test.get_viewport().push_input(release, true)


func _free(node: Node) -> void:
	node.get_parent().remove_child(node)
	node.queue_free()


func _frames(count: int) -> void:
	for frame in count:
		await _test.get_tree().process_frame


func _wait(seconds: float) -> void:
	await _test.get_tree().create_timer(seconds).timeout


func _check(condition: bool, description: String) -> void:
	_test._check(condition, description)
