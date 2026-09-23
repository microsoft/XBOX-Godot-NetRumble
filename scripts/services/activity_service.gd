class_name ActivityService
extends RefCounted

## The title's platform-facing session surface: Xbox multiplayer activity, invites,
## rich presence and recent players. Everything the Xbox service needs to know about a
## NetRumble session goes through here, and nothing else in the game talks to those
## APIs directly.
##
## Why one file: none of this can be exercised on a desktop dev machine. Activities,
## invites and presence all need a registered build, a signed-in Xbox identity and a
## development sandbox, so the untestable surface is deliberately kept in one place that
## fails soft everywhere. Every method is a logged no-op when the GDK extension is
## missing, the runtime has not initialized, or there is no XboxUser — which is exactly
## the state of a --pf-user desktop test client.
##
## Covers XR-064 (joinable sessions), XR-124 (platform multiplayer join flows), XR-067
## (multiplayer session state) and the joinability half of XR-070 (friends list). XR-067 offers two routes — MPSD, or, for a title that
## has its own session-state functionality, the Multiplayer Activity Recent Player
## feature. NetRumble has its own (NetManager over PlayFab Party and Lobby), so the
## Recent Player route applies and MPSD is not needed. That is also just as well:
## godot_gdk binds no MPSD at all.

## An accepted invite or a platform join that carries a session to enter. `request` is
## `{"connection_string": String, "xuid": String}` — see _join_request_from_invite() for
## why it can be either. InviteRouter owns what happens next, including resolving an
## XUID to a connection string once there is a signed-in user to ask with.
signal join_requested(request: Dictionary)

## Only followers can join from the platform UI. The title has no matchmaking and no
## server browser, so "public" would advertise a session to people with no way to reach
## it beyond an invite they were never sent.
const JOIN_RESTRICTION := "followed"

## Whether the platform may offer this session across network boundaries.
##
## This was `false` on the reasoning that NetRumble ships only to Xbox console and PC
## GDK — both Xbox network identities signing in through XUser — so there is no
## cross-network play to declare. That was wrong in practice: with it `false`, a console
## player and a PC player of the *same* title were never offered "Join Game" on each
## other's profile cards, even though both titles could still read the other's activity
## through get_activities_async and join it from the in-game friends list. The service
## query is unfiltered; the shell's join affordance is not.
##
## This does not declare non-Xbox cross-network play and does not by itself pull in
## XR-007 — there is no non-Xbox client, and the PlayFab custom-id path is inert in
## retail builds (see IdentityService.developer_overrides_allowed). A genuinely non-Xbox
## client would bring XR-007 with it: per-user cross-network communication privileges,
## non-Xbox player identification, and Party invitations restricted to the known-Xbox
## roster when the privilege is absent.
const ALLOW_CROSS_PLATFORM_JOIN := true

## update_recent_players takes 'default', 'teammate' or 'opponent'. Every match is a
## free-for-all deathmatch, so no player is ever anyone's teammate and the roster
## carries no team assignment to distinguish the latter two with.
const ENCOUNTER_TYPE := "default"

## Query fields naming the player whose session is being entered — the host — for an
## activation that carries no connection string. A Multiplayer Activity invite names
## them `sender`; the older MPSD shapes use `senderXuid` (invite) and `joineeXuid`
## (platform join). The addon's snake_case aliases are listed too. Matched lower-cased.
##
## The local player's own XUID travels alongside as `invitedUser` / `invitedXuid` /
## `joinerXuid` and is deliberately NOT in this list: resolving an activity for
## ourselves would look up the session we are trying to join *from*, not the one we
## were invited to.
const _TARGET_XUID_KEYS: PackedStringArray = [
	"sender",
	"senderxuid",
	"sender_xuid",
	"joineexuid",
	"joinee_xuid",
]

## Keys the Lobby connection string arrives under, matched lower-cased. A Multiplayer
## Activity invite or shell join carries the host's activity connection string as
## `connectionString` — see _join_request_from_invite() for the URI shape.
const _CONNECTION_STRING_KEYS: PackedStringArray = [
	"connectionstring",
	"connection_string",
]

## True once the activation signals are hooked up, so a second construction cannot
## double-subscribe.
var _activation_connected := false
## True once this is waiting on GDK.initialized to re-attempt the subscription, so the
## retry cannot stack up either.
var _awaiting_runtime := false


func _init() -> void:
	_connect_activation()


# --- Activity ---------------------------------------------------------------

## The outcome of one activity write.
##
## "Did it work?" has four answers here and a bool carries two, which is how an unsent
## call and a confirmed one came to look alike. Only CONFIRMED may change a caller's
## record of what is advertised; only FAILED is worth retrying.
enum WriteResult {
	## The service accepted it, so what is out there is now known.
	CONFIRMED,
	## The service was asked and refused or errored. Until a later write succeeds, what is
	## actually advertised is genuinely unknown -- the call may well have landed.
	FAILED,
	## No platform or no signed-in user, so nothing was sent. This does not confirm that
	## an earlier advertisement was cleared; retry needs restored service/account access.
	UNAVAILABLE,
	## The call could not be built from what the caller supplied. Retrying the same input
	## fails the same way; only better input fixes it.
	INVALID,
}


## Publishes (or updates) the Xbox multiplayer activity for this session. Idempotent:
## a roster change is just another call with a new current_players.
##
## XR-064 requires a title using the activity to advertise joinability to keep the
## player counts, join restriction and group id up to date for as long as the activity
## is joinable, so all four move together on every call. `group_id` is shared by every
## member of a session, which is what lets the platform group them in one activity.
func set_activity(user: Variant, connection_string: String, max_players: int, current_players: int, group_id: String = "") -> WriteResult:
	var activity: Variant = _multiplayer_activity()
	if activity == null or user == null:
		return WriteResult.UNAVAILABLE
	if connection_string.is_empty():
		push_warning("[Activity] No lobby connection string; the session will not be joinable from the platform UI.")
		return WriteResult.INVALID
	var result: Variant = await activity.set_activity_async(
		user,
		connection_string,
		JOIN_RESTRICTION,
		maxi(max_players, 0),
		maxi(current_players, 0),
		group_id,
		ALLOW_CROSS_PLATFORM_JOIN,
	)
	if result == null or not result.ok:
		push_warning("[Activity] Publishing the multiplayer activity failed: %s" % _reason(result))
		return WriteResult.FAILED
	return WriteResult.CONFIRMED


## Clears the activity so the platform stops offering a session that no longer exists.
##
## Reports whether the service confirmed it. A caller that recorded a failed clear as a
## successful one would never ask again, leaving the platform advertising a match that
## has started or that the player has left.
func delete_activity(user: Variant) -> WriteResult:
	var activity: Variant = _multiplayer_activity()
	if activity == null or user == null:
		return WriteResult.UNAVAILABLE
	var result: Variant = await activity.delete_activity_async(user)
	if result == null or not result.ok:
		push_warning("[Activity] Clearing the multiplayer activity failed: %s" % _reason(result))
		return WriteResult.FAILED
	return WriteResult.CONFIRMED


## The system invite UI. The platform owns the player picker and the sending, so there
## is nothing to hand it beyond the local user — the connection string comes from the
## activity published above.
func show_invite_ui(user: Variant) -> void:
	var activity: Variant = _multiplayer_activity()
	if activity == null or user == null:
		return
	var result: Variant = await activity.show_invite_ui_async(user)
	if result == null or not result.ok:
		push_warning("[Activity] The invite UI could not be shown: %s" % _reason(result))


## The activities `xuids` are currently in, keyed by XUID (XR-070). Activities are
## per-title, so anything returned here is a NetRumble session and its connection
## string is ready for NetManager.join_by_invite().
##
## Only sessions that can actually be entered are reported: one with no connection
## string cannot be joined, and one that is full would fail at the lobby. The join
## restriction is deliberately not filtered on — "followed" is this title's own setting
## (see JOIN_RESTRICTION) and the service already withheld the activities of anyone the
## local player may not join.
func joinable_activities(user: Variant, xuids: PackedStringArray) -> Dictionary:
	var activity: Variant = _multiplayer_activity()
	if activity == null or user == null:
		return {}
	var valid := _valid_xuids(xuids)
	if valid.is_empty():
		return {}

	var result: Variant = await activity.get_activities_async(user, valid)
	if result == null or not result.ok:
		push_warning("[Activity] Reading friends' activities failed: %s" % _reason(result))
		return {}

	var activities: Dictionary = {}
	for xuid in valid:
		var info: Variant = activity.get_cached_activity(xuid)
		if info == null:
			continue
		var connection_string := String(info.get_connection_string()).strip_edges()
		if connection_string.is_empty():
			continue
		var max_players := int(info.get_max_players())
		var current_players := int(info.get_current_players())
		if max_players > 0 and current_players >= max_players:
			continue
		activities[xuid] = {
			"connection_string": connection_string,
			"current_players": current_players,
			"max_players": max_players,
			"join_restriction": String(info.get_join_restriction()),
		}
	return activities


# --- Recent players ---------------------------------------------------------

## Records an encounter with the given players. Batches locally; call
## flush_recent_players() to push the batch to the service.
func report_recent_players(user: Variant, xuids: PackedStringArray) -> void:
	var activity: Variant = _multiplayer_activity()
	if activity == null or user == null:
		return
	var valid := _valid_xuids(xuids)
	if valid.is_empty():
		return
	var result: Variant = activity.update_recent_players(user, valid, ENCOUNTER_TYPE)
	if result == null or not result.ok:
		push_warning("[Activity] Recording recent players failed: %s" % _reason(result))


func flush_recent_players(user: Variant) -> void:
	var activity: Variant = _multiplayer_activity()
	if activity == null or user == null:
		return
	var result: Variant = await activity.flush_recent_players_async(user)
	if result == null or not result.ok:
		push_warning("[Activity] Flushing recent players failed: %s" % _reason(result))


## The service requires non-empty numeric ids and rejects the whole batch otherwise, so
## anything else is dropped here rather than turned into a failed call. Offline players
## and --pf-user test clients have no XUID at all, which is the common case.
func _valid_xuids(xuids: PackedStringArray) -> PackedStringArray:
	var valid := PackedStringArray()
	for xuid in xuids:
		var trimmed := xuid.strip_edges()
		if not trimmed.is_empty() and trimmed.is_valid_int() and not valid.has(trimmed):
			valid.append(trimmed)
	return valid


# --- Presence ---------------------------------------------------------------

## GDK rich presence. The status strings have to exist in the title's service
## configuration; an unconfigured one fails at the service, which is why this warns
## rather than errors.
func set_presence(user: Variant, status: String) -> void:
	var gdk: Variant = _gdk_ready()
	if gdk == null or user == null or status.is_empty():
		return
	var result: Variant = await gdk.presence.set_presence_async(user, status)
	if result == null or not result.ok:
		push_warning("[Activity] Set presence failed: %s" % _reason(result))


# --- Activation -------------------------------------------------------------

## Subscribes to the activation events that can bring a player into a session:
## an accepted invite, an invite still pending acceptance, and a protocol launch.
## XboxActivation owns the single native subscription and XboxMultiplayerActivity is
## fed from the same fan-out, so subscribing here once covers both.
##
## The runtime has to be up first. XboxActivation is a service on an initialized GDK,
## and this is constructed from Services._ready() — long before IdentityService gets
## around to signing in — so on the first attempt there may be nothing to subscribe to
## yet. That is why this re-arms from GDK.initialized rather than giving up: a single
## silent early return here costs the title *every* platform join and invite for the
## rest of the run, which is precisely the shape of the bug this guards against.
##
## The three ways it can fail are not the same failure and are not handled the same way:
## a runtime that is merely not up yet is waited for; a missing singleton has no signal
## to wait on and needs ensure_activation_subscribed() to come back in; and a runtime
## that is up but exposes no activation service is a dead end worth saying out loud.
func _connect_activation() -> void:
	if _activation_connected:
		return
	var gdk: Variant = _gdk()
	if gdk == null:
		# Deliberately not a retry point. GDK.initialized is the signal every other path
		# here waits on, and it lives on the singleton that is missing — there is nothing
		# to connect to. ensure_activation_subscribed() is the way back in.
		push_warning("[Activity] The GDK singleton is not registered; platform joins and invites cannot be received.")
		return
	if not gdk.is_initialized():
		_retry_when_initialized(gdk)
		return
	var activation: Variant = gdk.activation
	if activation == null:
		# Waiting on GDK.initialized would be pointless — it has already fired — so this
		# says so rather than parking on a signal that will not come again.
		push_warning("[Activity] The GDK runtime is initialized but exposes no activation service; platform joins and invites cannot be received.")
		return
	activation.invite_accepted.connect(_on_invite_accepted)
	activation.pending_invite_received.connect(_on_pending_invite_received)
	activation.protocol_activated.connect(_on_protocol_activated)
	_activation_connected = true
	# Said out loud because it is the one precondition for every platform join and
	# invite, and it can only be observed on a console in a sandbox. Its absence from
	# the log is the first thing to check when "Join" does nothing.
	print("[Activity] Subscribed to platform activation events.")


## Waits for the runtime the subscription needs. The signal lives on the singleton, not
## on the runtime, so connecting to it before initialize() is safe.
##
## Guarded on the connection itself rather than on _awaiting_runtime alone: the flag is
## cleared before _connect_activation() re-runs, so a second failed attempt would
## otherwise try to connect a callable that is already connected and be refused.
func _retry_when_initialized(gdk: Variant) -> void:
	_awaiting_runtime = true
	if not gdk.initialized.is_connected(_on_runtime_initialized):
		gdk.initialized.connect(_on_runtime_initialized)


func _on_runtime_initialized() -> void:
	_awaiting_runtime = false
	_connect_activation()


## Re-attempts the subscription after something that may have loaded the extension or
## started the runtime. Services calls this once sign-in has been through
## IdentityService, which loads and initializes the GDK on its way past; that is the
## only route back from a boot where the singleton was not registered yet, because that
## is the one failure with no signal to wait on. Cheap and idempotent — it returns
## immediately once subscribed.
func ensure_activation_subscribed() -> void:
	_connect_activation()


func _on_invite_accepted(invite: Dictionary) -> void:
	var request := _join_request_from_invite(invite)
	_log_activation("Accepted invite", invite, request)
	_emit_join_request(request, "an accepted invite")


## A pending invite has to be accepted before it becomes a join. Accepting re-raises it
## through invite_accepted, so this hands off rather than joining directly.
func _on_pending_invite_received(invite: Dictionary) -> void:
	_log_activation("Pending invite", invite, _join_request_from_invite(invite))
	var gdk: Variant = _gdk()
	if gdk == null:
		return
	var uri := String(invite.get("raw_uri", ""))
	if uri.is_empty():
		push_warning("[Activity] A pending invite carried no URI to accept; ignoring it.")
		return
	var result: Variant = gdk.activation.accept_pending_invite(uri)
	if result == null or not result.ok:
		push_warning("[Activity] Accepting a pending invite failed: %s" % _reason(result))


## Protocol launches carry the same query shape as an invite URI, so they route through
## the same parser. This is the platform join path: the guide's "Join Game" on a
## friend's card arrives here, as does a desktop launch with the URI on the command line.
func _on_protocol_activated(uri: String) -> void:
	var request := _join_request_from_uri(uri)
	_log_activation("Protocol activation", {"raw_uri": uri}, request)
	_emit_join_request(request, "a platform join")


func _emit_join_request(request: Dictionary, description: String) -> void:
	if request.is_empty():
		# Never silent. An activation the title cannot read is indistinguishable from one
		# it never received, and the two have entirely different causes.
		push_warning("[Activity] Ignoring %s: it named neither a connection string nor a host XUID." % description)
		return
	join_requested.emit(request)


## What an activation is actually asking for, as
## `{"connection_string": String, "xuid": String}`; empty when it asks for nothing
## usable.
##
## A Multiplayer Activity invite — sent from the title or the shell — and a shell "Join
## Game" both carry the host's Lobby connection string in the activation URI:
##
##     console: ms-xbl-<titleId>://inviteAccept?invitedUser=<xuid>&sender=<xuid>&connectionString=<cs>
##     PC:      ms-xbl-multiplayer://inviteAccept?invitedUser=<xuid>&sender=<xuid>&connectionString=<cs>
##
## A PlayFab Lobby connection string looks like `cv2:<lobby id>|<n>|kv1:<base64 key>`,
## and a base64 key carries `+`, `/` and `=`. Lobby join needs it byte for byte, so it
## is read out of `raw_uri` and percent-decoded exactly once, by _percent_decode().
## The addon's pre-parsed fields cannot be trusted with it: the addon runs every value
## through String.uri_decode(), which turns `+` into a space and mangles lowercase
## escapes such as `%3a`. Those fields are the fallback only for a payload that has no
## `raw_uri`, and are used as given rather than decoded a second time.
##
## An activation with no connection string — the older MPSD `activityHandleJoin` /
## `inviteHandleAccept` shapes — names the host by XUID instead, and InviteRouter
## resolves that from their published activity.
static func _join_request_from_invite(invite: Dictionary) -> Dictionary:
	var request := _join_request_from_uri(String(invite.get("raw_uri", "")))
	if not request.is_empty():
		return request
	var fields: Dictionary = {}
	for key: Variant in invite:
		var value: Variant = invite[key]
		if typeof(value) == TYPE_STRING:
			fields[String(key).to_lower()] = value
	return _join_request_from_fields(fields)


static func _join_request_from_uri(uri: String) -> Dictionary:
	return _join_request_from_fields(_query_fields(uri))


## Picks the join out of already-decoded, lower-cased fields: a connection string when
## there is one, otherwise the host's XUID.
static func _join_request_from_fields(fields: Dictionary) -> Dictionary:
	for key in _CONNECTION_STRING_KEYS:
		var value := String(fields.get(key, "")).strip_edges()
		if not value.is_empty():
			return {"connection_string": value, "xuid": ""}
	for key in _TARGET_XUID_KEYS:
		var xuid := String(fields.get(key, "")).strip_edges()
		if not xuid.is_empty() and xuid.is_valid_int():
			return {"connection_string": "", "xuid": xuid}
	return {}


## The URI's query as lower-cased key -> value decoded once. Keys are folded because
## the platform spells them in camelCase. A value is everything after the key's first
## `=`, so a base64 key's `=` padding survives. The first occurrence of a key wins.
static func _query_fields(uri: String) -> Dictionary:
	var query_start := uri.find("?")
	if query_start < 0:
		return {}
	var fields: Dictionary = {}
	for pair: String in uri.substr(query_start + 1).split("&", false):
		var equals := pair.find("=")
		if equals <= 0:
			continue
		var key := pair.substr(0, equals).strip_edges().to_lower()
		if not fields.has(key):
			fields[key] = _percent_decode(pair.substr(equals + 1)).strip_edges()
	return fields


## RFC 3986 percent-decoding, one pass. Not String.uri_decode(), which is form
## decoding: it turns `+` into a space and drops the `%` of a lowercase escape, and
## either one corrupts a Lobby connection string. Here `+` stays `+`, hex digits match
## in either case, and a `%` that does not start a valid escape is kept as written.
## Decoding is done on UTF-8 bytes, so a multi-byte escape comes back as one character.
static func _percent_decode(value: String) -> String:
	if not value.contains("%"):
		return value
	var source := value.to_utf8_buffer()
	var decoded := PackedByteArray()
	var index := 0
	while index < source.size():
		var byte := source[index]
		if byte == 0x25 and index + 2 < source.size():
			var high := _hex_digit(source[index + 1])
			var low := _hex_digit(source[index + 2])
			if high >= 0 and low >= 0:
				decoded.append(high * 16 + low)
				index += 3
				continue
		decoded.append(byte)
		index += 1
	return decoded.get_string_from_utf8()


static func _hex_digit(byte: int) -> int:
	if byte >= 0x30 and byte <= 0x39:
		return byte - 0x30
	if byte >= 0x41 and byte <= 0x46:
		return byte - 0x41 + 10
	if byte >= 0x61 and byte <= 0x66:
		return byte - 0x61 + 10
	return -1


## The lobby connection string for the session `xuid` is currently in, or empty when
## there is none to be had. This is the second half of a platform join that names only
## the host — the older MPSD activation shapes — rather than carrying the connection
## string itself: their published activity is what says how to reach them.
##
## Unlike joinable_activities() this does not drop a full session — an invite the player
## explicitly accepted deserves a real attempt and a real error from the lobby, not a
## silent refusal here.
func connection_string_for_xuid(user: Variant, xuid: String) -> String:
	var activity: Variant = _multiplayer_activity()
	if activity == null or user == null:
		return ""
	var valid := _valid_xuids(PackedStringArray([xuid]))
	if valid.is_empty():
		push_warning("[Activity] Cannot resolve a session for XUID '%s': it is not a valid id." % xuid)
		return ""

	var result: Variant = await activity.get_activities_async(user, valid)
	if result == null or not result.ok:
		push_warning("[Activity] Looking up the host's activity failed: %s" % _reason(result))
		return ""

	var info: Variant = activity.get_cached_activity(valid[0])
	if info == null:
		push_warning("[Activity] XUID %s has no activity for this title; the session has probably ended." % valid[0])
		return ""
	return String(info.get_connection_string()).strip_edges()


## Printed for every activation: the payload's shape is the difference between a join
## that works and one that is silently dropped, and it can only be observed on
## hardware. The summary line says how the platform escaped the URI and what the
## parser made of it, which is what to read first when an invite does not land.
func _log_activation(kind: String, invite: Dictionary, request: Dictionary) -> void:
	for line: String in _activation_log_lines(kind, invite, request):
		print(line)


## The lines _log_activation prints. No value from the payload appears in them: the
## Lobby connection string is the credential join_lobby_async accepts, its kv1 segment
## being the lobby's key, and XUIDs identify players. Keys, their order and each value's
## length are what tell one activation shape from another, and those are kept.
static func _activation_log_lines(kind: String, invite: Dictionary, request: Dictionary) -> PackedStringArray:
	var uri := String(invite.get("raw_uri", ""))
	var shape := ""
	if uri.is_empty():
		var keys := PackedStringArray()
		for key: Variant in invite:
			keys.append(str(key))
		shape = "URI: (none); payload keys: %s" % (", ".join(keys) if not keys.is_empty() else "(none)")
	else:
		shape = "URI: " + _redacted_uri(uri)
	return PackedStringArray([
		"[Activity] %s %s" % [kind, shape],
		"[Activity] %s parsed: %s" % [kind, _describe_activation(uri, request)],
	])


## The URI with every query value replaced by its length, as in
## `ms-xbl-7C84AA93://inviteAccept?invitedUser=<16 chars>&sender=<16 chars>&connectionString=<N chars>`.
static func _redacted_uri(uri: String) -> String:
	var query_start := uri.find("?")
	if query_start < 0:
		return uri
	var pairs := PackedStringArray()
	for pair: String in uri.substr(query_start + 1).split("&"):
		var equals := pair.find("=")
		pairs.append(pair if equals < 0 else "%s=<%d chars>" % [pair.left(equals), pair.length() - equals - 1])
	return uri.left(query_start + 1) + "&".join(pairs)


## One line on how an activation URI was escaped and what the parser took from it. A
## lowercase escape has a lowercase hex digit in either place (`%3a`, `%aB`, `%Ab`);
## String.uri_decode() decodes none of them.
static func _describe_activation(uri: String, request: Dictionary) -> String:
	var lowercase_escapes := RegEx.create_from_string("%(?:[0-9A-Fa-f][a-f]|[a-f][0-9A-Fa-f])")
	var summary := "percent escapes %s, lowercase escapes %s, '+' %s" % [
		"yes" if uri.contains("%") else "no",
		"yes" if lowercase_escapes.search(uri) != null else "no",
		"yes" if uri.contains("+") else "no",
	]
	var connection_string := String(request.get("connection_string", ""))
	if not connection_string.is_empty():
		return "%s -> connection string (%d chars)" % [summary, connection_string.length()]
	var xuid := String(request.get("xuid", ""))
	if not xuid.is_empty():
		return "%s -> host XUID (%d digits)" % [summary, xuid.length()]
	return "%s -> nothing usable" % summary


# --- Shared -----------------------------------------------------------------

## The multiplayer activity service, or null when the GDK is absent or asleep. Every
## public method funnels through here so a machine without the extension — every
## desktop dev machine — takes a silent early return rather than erroring.
func _multiplayer_activity() -> Variant:
	var gdk: Variant = _gdk_ready()
	return gdk.multiplayer_activity if gdk != null else null


func _gdk_ready() -> Variant:
	return PlatformAccess.gdk_ready()


func _gdk() -> Variant:
	return PlatformAccess.gdk()


func _reason(result: Variant) -> String:
	return PlatformAccess.reason(result)
