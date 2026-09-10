class_name ConnectivityService
extends RefCounted

## Answers one question for the rest of the title: is this console definitively offline
## (XR-074)?
##
## Built on the addon's `XboxNetworking` wrapper around `XNetworkingGetConnectivityHint`
## and `XNetworkingRegisterConnectivityHintChanged`. The hint is device-wide and costs
## nothing to read, which is what makes it usable *before* an attempt rather than only as
## an explanation afterwards.
##
## [b]This deliberately fails open, and that is the whole design.[/b] The addon documents
## `network_initialized` as the only authoritative field and warns that the rest is a
## best-effort hint that "must not be treated as a reachability test for a specific
## endpoint". So this reports offline only when the platform is certain -- the network
## stack is not initialised, or the level is an explicit `NONE` -- and treats everything
## else, including `UNKNOWN`, as "let the player try".
##
## The asymmetry is deliberate. A false "offline" locks a player with a working connection
## out of online play with no recourse, which is a worse defect than the one being fixed.
## A false "online" costs one failed attempt that the existing failure handling already
## turns into a dialog and a trip back to the main menu. Given a hint that is explicitly
## documented as approximate, the only safe direction to be wrong in is optimistic.
##
## `LOCAL_ACCESS` and `CONSTRAINED_INTERNET_ACCESS` are therefore treated as online even
## though PlayFab almost certainly cannot be reached through either. They are the cases
## the hint is least reliable about -- a captive portal is explicitly "not guaranteed to be
## detected" -- and being wrong about them costs a dialog rather than a lockout.
##
## Nothing here is a substitute for `PartyService.network_lost`. This is the proactive
## half; that is the backstop for a loss this never sees, and both end up in the same
## place.
##
## Addon SDK objects are held as Variant for the usual reason: the godot_gdk classes only
## exist when the native library loads, so naming them in type positions would break
## parsing on a machine without the extension.

## The answer changed. Carries the new value so a handler need not re-query.
signal connectivity_changed(online: bool)

## Mirrors `XboxNetworking.ConnectivityLevelHint`. Declared locally rather than read off
## the class so this file still parses in a build with no GDExtension.
const LEVEL_UNKNOWN := 0
const LEVEL_NONE := 1
const LEVEL_LOCAL_ACCESS := 2
const LEVEL_INTERNET_ACCESS := 3
const LEVEL_CONSTRAINED_INTERNET_ACCESS := 4

## The last answer given. Starts optimistic so that a machine which never reports a hint
## -- desktop, or a build with no GDK -- behaves exactly as it did before this existed.
var _online := true
## Whether the platform is actually answering. False on desktop and in a build with no
## GDK, and the reason the menu says nothing about connectivity there rather than
## claiming everything is fine.
var _supported := false
## The most recent hint, kept for diagnostics and for the reason string.
var _hint: Dictionary = {}
var _started := false


## Begins tracking. Safe to call more than once; the second call re-seeds without
## double-subscribing.
func start() -> void:
	var networking: Variant = _networking()
	if networking == null:
		# No GDK on this machine. Stay optimistic and silent.
		_supported = false
		_online = true
		return

	_supported = true

	if not _started:
		_started = true
		networking.connectivity_hint_changed.connect(_on_hint_changed)

	# Seeded silently: whatever the machine reports now is the baseline, and there is
	# nothing to announce about a state the player is already in. The addon also replays
	# the current hint through the signal shortly after GDK.initialize(), so this only
	# matters for the window before that arrives.
	var result: Variant = networking.get_connectivity_hint()
	if result != null and result.is_ok():
		_hint = result.data
		_online = _evaluate(_hint)


## Whether online play is worth offering. True whenever the platform is not certain the
## answer is no.
func is_online() -> bool:
	return _online


## Whether the platform answers the connectivity question on this machine. The menu uses
## this to stay quiet rather than assert "connected" where it cannot know.
func is_supported() -> bool:
	return _supported


## The most recent hint, or an empty dictionary. Diagnostics only.
func hint() -> Dictionary:
	return _hint


## Why online play is unavailable, or an empty string when it is available. Phrased for
## the player, and distinguishes "no network at all" from "the network is up but reports
## no connectivity", because those need different things done about them.
func offline_reason() -> String:
	if _online:
		return ""
	if not bool(_hint.get("network_initialized", true)):
		return "This console is not connected to a network."
	return "This console has no internet connection."


func _on_hint_changed(hint: Dictionary) -> void:
	_hint = hint
	_supported = true
	_set_online(_evaluate(hint))


## The gate. See the class comment for why this only ever reports offline on a certainty.
func _evaluate(hint: Dictionary) -> bool:
	if not bool(hint.get("network_initialized", true)):
		return false
	return int(hint.get("connectivity_level", LEVEL_UNKNOWN)) != LEVEL_NONE


func _set_online(value: bool) -> void:
	if _online == value:
		return
	_online = value
	connectivity_changed.emit(value)


func _networking() -> Variant:
	var gdk: Variant = PlatformAccess.gdk_ready()
	return gdk.networking if gdk != null else null
