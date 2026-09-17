class_name MatchmakingService
extends RefCounted

## PlayFab Matchmaking (Quick Match): ticket creation and arranged-lobby entry.
##
## Scaffolding only. The search and arranged-join flow is deliberately absent because
## it cannot be written correctly yet: the addon hardcodes the arranged-join
## configuration, so a matched lobby is always capacity 8 while Party and admission use
## the game mode's capacity. Shrinking it after join reintroduces the capacity race this
## design exists to avoid, so the feature stays switched off rather than shipping a path
## that half works. See docs/matchmaking.md and XBOX-Godot-Sample#177.
##
## What is here is the part that is correct today and answers one question the menu
## needs: may Quick Match run on this build, and if not, why. That check is what turns
## the feature on when the addon gains the fields, and what makes a stale addon fail
## with an explanation instead of silently matching players into a lobby sized 8.

## Queue configured for this title. Held as a constant for the same reason
## LeaderboardService holds its board name: one place to change, none at the call sites.
##
## User-confirmed deployment fact. Its *configuration* — total size, relaxation rules,
## timeout — is NOT verified, and the fixed-cohort design depends on it being fixed-size
## and non-relaxing. Confirm the queue definition in Game Manager before enabling.
const QUEUE_NAME := "godotnr_q"

## Member-property key carrying the wire protocol version into an arranged lobby.
##
## The hosted path publishes the protocol as a lobby *search* property, which an
## arranged join cannot set. Member properties are the one bag that can be supplied at
## arranged-join time, so on that path the version travels per-member instead: a guest
## checks the owner's value, and the owner checks each remote member.
const PROTOCOL_MEMBER_KEY := "nr_protocol"

## Search budget before giving up. A local expiry is not the same answer as the service
## reporting no match, and the two must not be reported as one.
const SEARCH_TIMEOUT_SECONDS := 120

## Provisional until the queue definition is confirmed; the cohort gate is exact, so a
## relaxing or differently sized queue would strand players rather than start short.
##
## Deliberately not duplicated here as a number: the cohort must equal the game mode's
## `player_count` (an exported field a designer can retune), so the gate reads it from
## Assets when it lands rather than risking two sources that quietly disagree.

## Arranged-join capabilities the addon must expose before a matched lobby can be created
## the way this title needs it. Each entry lists the property names that would satisfy one
## capability; the first is the name the upstream request pins.
##
## Capacity is listed twice on purpose. The addon spells the same concept two ways today —
## `PlayFabLobbyConfig` binds `max_players` while `PlayFabLobbyUpdateConfig` uses
## `max_member_count` — so accepting either keeps this probe from reporting "blocked"
## against an addon that actually shipped the capability under the other spelling.
const REQUIRED_JOIN_CONFIG_CAPABILITIES := [
	["max_member_count", "max_players"],
	["access_policy"],
	["owner_migration_policy"],
]

const _JOIN_CONFIG_CLASS := "PlayFabLobbyJoinConfig"

## A property the join config is known to expose today. If this is missing, the probe is
## looking at the wrong class rather than an addon that is merely too old — which is the
## difference between "wait for the upstream change" and "this code needs updating".
## XBOX-Godot-Sample#177 may land as a dedicated arranged-join config instead of fields on
## this one; if it does, `_JOIN_CONFIG_CLASS` is the single line to change.
const _JOIN_CONFIG_SENTINEL := "member_properties"

## The probe walks a class registration that cannot change while the process runs, and
## the menu asks repeatedly while gating its rows.
var _missing_properties_cache: PackedStringArray = []
var _missing_properties_cached := false


## Whether Quick Match may run on this build. False today, by design.
func is_available() -> bool:
	return availability_reason().is_empty()


## Empty when Quick Match may run; otherwise the reason, in words fit to show a player.
##
## Ordered cheapest first, and deliberately reports the *addon* gap before anything a
## player could act on: a build that cannot arrange a lobby correctly will not be fixed
## by signing in.
func availability_reason() -> String:
	var pf: Variant = _playfab()
	if pf == null:
		return "Matchmaking needs the PlayFab extension, which this build does not have."
	if not _join_config_recognised():
		return "Matchmaking is unavailable: this build cannot inspect the PlayFab lobby join configuration."
	if missing_join_config_properties().size() > 0:
		return "This build's PlayFab addon cannot configure a matched lobby, so Quick Match is unavailable."
	return ""


## False when the probe cannot see a property the join config is known to expose, which
## means it is inspecting the wrong class rather than an addon that is merely too old.
func _join_config_recognised() -> bool:
	if not ClassDB.class_exists(_JOIN_CONFIG_CLASS):
		return false
	for property: Dictionary in ClassDB.class_get_property_list(_JOIN_CONFIG_CLASS, false):
		if String(property.get("name", "")) == _JOIN_CONFIG_SENTINEL:
			return true
	return false


## Arranged-join settings the installed addon does not expose. Empty means the addon is
## new enough for Quick Match.
##
## Probed rather than assumed so that moving the submodule pin switches the feature on
## without a code change here, and so an older pin fails loudly instead of matching
## players into a lobby whose capacity does not match the game mode.
func missing_join_config_properties() -> PackedStringArray:
	if _missing_properties_cached:
		return _missing_properties_cache.duplicate()

	var missing := PackedStringArray()
	if not ClassDB.class_exists(_JOIN_CONFIG_CLASS):
		for capability: Array in REQUIRED_JOIN_CONFIG_CAPABILITIES:
			missing.append(String(capability[0]))
	else:
		var present := {}
		for property: Dictionary in ClassDB.class_get_property_list(_JOIN_CONFIG_CLASS, false):
			present[String(property.get("name", ""))] = true
		for capability: Array in REQUIRED_JOIN_CONFIG_CAPABILITIES:
			var satisfied := false
			for name: String in capability:
				if present.has(name):
					satisfied = true
					break
			if not satisfied:
				missing.append(String(capability[0]))

	_missing_properties_cache = missing
	_missing_properties_cached = true
	return missing.duplicate()


## One line naming the blocking dependency, for logs and the setup guide. Not shown to
## players: it names an upstream issue they cannot act on.
func blocking_dependency() -> String:
	if not _join_config_recognised():
		return "Could not inspect %s. The probe may be naming the wrong class; see XBOX-Godot-Sample#177." % _JOIN_CONFIG_CLASS
	var missing := missing_join_config_properties()
	if missing.size() == 0:
		return ""
	return "Arranged-lobby initialization is not configurable in the installed addon (%s). Blocked on XBOX-Godot-Sample#177; missing: %s." % [
		_JOIN_CONFIG_CLASS, ", ".join(missing)]


func _playfab() -> Variant:
	return PlatformAccess.playfab()
