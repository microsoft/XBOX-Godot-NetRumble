class_name PlatformAccess
extends RefCounted

## Shared accessors for the two native extensions every service talks to.
##
## The GDK and PlayFab both live behind GDExtension singletons that only exist once the
## native library has loaded. On a machine without them — any non-Windows development
## box, and any build where the addons were not shipped — every accessor here returns
## null, and the services above are written to degrade rather than fail when it does.
## That is what lets Practice mode run on a clean clone with no platform at all.
##
## Everything is held and returned as Variant on purpose. Naming an addon class in a
## type position would make the file fail to parse where the extension is absent, which
## is precisely the case these helpers exist to handle.
##
## Services keep thin private wrappers (`_gdk()`, `_playfab()`, `_reason()`) that call
## into here, so each service still reads top-to-bottom without a jump, while the
## behaviour lives in one place.

## Reached through the script rather than the `XboxBootstrap` autoload so these helpers
## resolve in any context, including tools and tests that run without the autoload list.
const GdkBootstrap := preload("res://addons/godot_gdk/runtime/gdk_bootstrap.gd")


## The GDK singleton, whether or not its runtime has been initialized.
##
## Prefer gdk_ready() for anything that actually calls the platform: a loaded but
## uninitialized GDK returns errors from every call rather than failing cleanly.
static func gdk() -> Variant:
	return GdkBootstrap.find_singleton()


## The GDK singleton, but only once its runtime is up. Returns null otherwise, so a
## caller can treat "no GDK on this machine" and "GDK not started yet" identically —
## which is almost always what a service wants, because both mean the same thing to the
## player.
static func gdk_ready() -> Variant:
	var singleton: Variant = gdk()
	if singleton == null or not singleton.is_initialized():
		return null
	return singleton


## The GDK user manager, or null when the runtime is not up.
static func users() -> Variant:
	var singleton: Variant = gdk_ready()
	return singleton.users if singleton != null else null


## The PlayFab singleton, whether or not it has been initialized.
##
## PlayFab is initialized explicitly by IdentityService rather than on startup, because
## the title id has to be settled before the first call reads it from ProjectSettings.
static func playfab() -> Variant:
	return Engine.get_singleton("PlayFab") if Engine.has_singleton("PlayFab") else null


## Human-readable reason from an addon result object.
##
## A null result means the extension itself is absent — a different failure from a call
## that ran and was refused, and one that reads differently to a player. Callers that
## surface this text directly pass their own wording for that case.
static func reason(result: Variant, unavailable: String = "extension unavailable") -> String:
	return String(result.message) if result != null else unavailable
