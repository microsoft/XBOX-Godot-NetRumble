class_name PrivilegeService
extends RefCounted

## Xbox account privilege checks (XR-045).
##
## Two privileges matter to this title: Multiplayer, without which the account may not
## host or join an online session, and Communications, without which it may not use
## voice or text chat. Both are checked before the thing they gate, and a resolvable
## denial is offered to the system resolution UI before it is reported to the player.
##
## Cross-network play is not checked. The title declares
## ActivityService.ALLOW_CROSS_PLATFORM_JOIN = true, but that declaration exists to
## restore the shell's "Join Game" affordance between Xbox console and PC GDK builds of
## *this* title, which the platform withholds unless cross-network play is declared. Both
## endpoints are still Xbox network identities signing in through XUser, so there is no
## non-Xbox participant for the CrossPlay privilege to govern. Admitting a genuinely
## non-Xbox client would change that, and would bring XR-007 with it rather than this
## privilege alone — see the reasoning on the constant itself in activity_service.gd.
##
## Privileges need a real Xbox identity in a development sandbox on a registered PC
## build or console. Calls fail open when the GDK is missing, the runtime has not
## initialized, or there is no XboxUser, as in a --pf-user desktop test client.
## An account-state change instead invalidates pending checks with a closed verdict;
## an abandoned request must never authorize the replacement account state.
##
## Addon SDK objects (XboxUser, XboxResult) are held as Variant on purpose: the
## godot_gdk classes only exist when the native library loads, so naming them in type
## positions would break parsing on a machine without the extension.

## Raw XUserPrivilege values. The addon "forwards that integer directly to the native
## XUserCheckPrivilege() call and does not bind named privilege constants"
## (addons/godot_gdk/doc_classes/XboxUsers.xml), so the title owns the numbers. They
## come from the GDK XUserPrivilege reference and are stable ABI.
const MULTIPLAYER := 254
const COMMUNICATIONS := 252

## What each privilege lets the player do, phrased to drop into the denial messages
## below. Also the label used when a privilege is logged.
const _PRIVILEGE_VERBS := {
	MULTIPLAYER: "play online",
	COMMUNICATIONS: "use voice and text chat",
}

## XUserPrivilegeDenyReason, as the addon spells it. `banned` is the one reason the
## system UI cannot resolve, so it is never offered the resolution flow.
const DENY_PURCHASE_REQUIRED := "purchase_required"
const DENY_RESTRICTED := "restricted"
const DENY_BANNED := "banned"

## privilege int -> verdict dictionary, as returned by check(). Cleared whenever the
## signed-in user or their privileges change; see Services.
var _cache: Dictionary = {}
var _cache_generation := 0


## Verdict shape shared by check() and ensure():
##   granted          - may the user do the thing? True on every fail-open path.
##   checked          - did the platform answer for the current account state? False
##                      also covers unavailable, failed, or invalidated checks.
##   reason           - XUserPrivilegeDenyReason or "state_changed" for invalidated
##                      work; empty when granted.
##   needs_resolution - the platform believes system UI could fix this.
##   message          - player-facing text, empty when granted.
static func _verdict(granted: bool, checked: bool, reason: String = "", needs_resolution: bool = false, message: String = "") -> Dictionary:
	return {
		"granted": granted,
		"checked": checked,
		"reason": reason,
		"needs_resolution": needs_resolution,
		"message": message,
	}


## The permissive verdict every fail-open path returns.
static func unchecked() -> Dictionary:
	return _verdict(true, false)


static func _invalidated() -> Dictionary:
	return _verdict(false, false, "state_changed", false,
		"Account permissions changed. Please try again.")


## Checks one privilege, answering from the cache when it can. Cached because the
## communications privilege is consulted on every session and the multiplayer privilege
## on every host and join; the cache is dropped on sign-out and whenever XboxUsers
## reports a `privileges` change, so a privilege resolved from the guide mid-session is
## picked up.
func check(user: Variant, privilege: int, use_cache: bool = true) -> Dictionary:
	if use_cache and _cache.has(privilege):
		return _cache[privilege]

	var gdk: Variant = _gdk_ready()
	if gdk == null or user == null:
		return unchecked()

	var generation := _cache_generation
	var result: Variant = await gdk.users.check_privilege_async(user, privilege)
	if generation != _cache_generation:
		return _invalidated()
	if result == null or not result.ok:
		# A failed check is not a denial: the service could be unreachable (XR-074), and
		# refusing to start a match because a privilege query timed out would be worse
		# than the risk it guards against.
		push_warning("[Privileges] Could not check privilege %d: %s" % [privilege, _reason(result)])
		return unchecked()

	var data: Dictionary = result.data if result.data is Dictionary else {}
	var granted := bool(data.get("has_privilege", true))
	var deny_reason := String(data.get("deny_reason", "")).strip_edges().to_lower()
	var needs_resolution := bool(data.get("needs_user_issue_resolution", false))
	var verdict := _verdict(
		granted,
		true,
		"" if granted else deny_reason,
		not granted and (needs_resolution or deny_reason != DENY_BANNED),
		"" if granted else describe(privilege, deny_reason),
	)
	_cache[privilege] = verdict
	return verdict


## check(), plus the remediation XR-045 asks for: a denial that the platform can resolve
## is handed to the system privilege UI, and the privilege is then re-checked. Returns
## the verdict after that second look, so a player who fixed the problem in the UI
## proceeds without having to retry the action themselves.
func ensure(user: Variant, privilege: int) -> Dictionary:
	var generation := _cache_generation
	var verdict: Dictionary = await check(user, privilege)
	if generation != _cache_generation:
		return _invalidated()
	if bool(verdict.get("granted", true)) or not bool(verdict.get("needs_resolution", false)):
		return verdict

	var gdk: Variant = _gdk_ready()
	if gdk == null or user == null:
		return verdict

	var resolved: Variant = await gdk.users.resolve_privilege_with_ui_async(user, privilege)
	if generation != _cache_generation:
		return _invalidated()
	if resolved == null or not resolved.ok:
		# Dismissing the UI lands here too, so this is a normal outcome rather than an
		# error: the prior denial stands and is reported to the player.
		push_warning("[Privileges] Privilege %d was not resolved: %s" % [privilege, _reason(resolved)])
		return verdict

	return await check(user, privilege, false)


## The last answer for a privilege without asking the platform again, or the permissive
## unchecked verdict when it has never been checked. For UI that wants to reflect a
## known denial without stalling on a service call.
func cached(privilege: int) -> Dictionary:
	return _cache.get(privilege, unchecked())


func clear_cache() -> void:
	_cache_generation += 1
	_cache.clear()


## Player-facing text for a denial. The addon returns both `deny_reason` (string) and
## `deny_reason_value` (int); the strings are matched here and anything unrecognised
## still produces a sensible sentence rather than an empty dialog.
static func describe(privilege: int, deny_reason: String) -> String:
	var verb := String(_PRIVILEGE_VERBS.get(privilege, "use this feature"))
	match deny_reason:
		DENY_PURCHASE_REQUIRED:
			return "This account needs an active Xbox subscription to %s." % verb
		DENY_RESTRICTED:
			return "This account is not allowed to %s. An adult on its family group can change that in the Xbox privacy and online safety settings." % verb
		DENY_BANNED:
			return "This account is suspended from Xbox services and cannot %s." % verb
		_:
			return "This account cannot %s right now." % verb


# --- Shared -----------------------------------------------------------------

func _gdk_ready() -> Variant:
	return PlatformAccess.gdk_ready()


func _reason(result: Variant) -> String:
	return PlatformAccess.reason(result)
