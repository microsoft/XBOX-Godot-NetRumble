class_name NRProtocol
extends RefCounted

## The version of the multiplayer wire contract this build speaks.
##
## Two builds that disagree here cannot play together, and the failure is silent
## unless something checks. Godot identifies an @rpc method on the wire by an *index*
## into the declaring node's RPC list rather than by name, so adding, removing or
## renaming any @rpc in net_manager.gd shifts the index of every method after it.
## Peers built either side of such a change stay connected and keep sending each
## other traffic that lands on the wrong handler or on none at all. What a player
## sees is a match that joins successfully and then does nothing: no roster, no
## ships, no error.
##
## That is the failure this class exists to turn into a sentence.
##
## The version is deliberately two independent parts, because there are two
## independent ways to break compatibility and neither implies the other:
##
##   WIRE_VERSION    the shape of the dictionaries inside the messages -- the
##                   snapshot entry keys in docs/protocol.md, the roster payload,
##                   anything read by key out of a Dictionary argument.
##
##   RPC_SET_VERSION the set and order of the @rpc methods themselves, which is
##                   what determines the indices described above.
##
## Renaming a snapshot key from "px" to "posx" changes no method name and so cannot
## move an index; adding one @rpc changes every index and touches no payload schema.
## Bumping a single number for both would be lying about one of them.

## Bump when any replicated payload's schema changes: a key added, removed, renamed
## or repurposed in a Dictionary that crosses the wire. See docs/protocol.md.
const WIRE_VERSION := 1

## Bump when the @rpc method set on NetManager changes in any way -- one added, one
## removed, one renamed, or the signature of an existing one altered.
##
## This is a hand-maintained number today and that is its weakness: this check exists
## because nobody remembers to think about protocol compatibility while adding an RPC,
## and a constant they must remember to bump has the same problem. The intended
## replacement is a hash derived from the sorted @rpc method names at startup, which
## would move automatically with the thing it describes and need no discipline at all.
## That is deferred, not abandoned -- `version_string()` already renders this part as
## an opaque token so the hash can replace it without changing the wire format or any
## of the comparison logic.
const RPC_SET_VERSION := 2

## Lobby search property the host advertises `version_string()` under.
##
## PlayFab only indexes its reserved search keys, so this has to be one of them.
## string_key1 and string_key2 are already taken by the join code and the game mode
## (see PartyService).
const LOBBY_KEY := "string_key3"


## The full version token, as published and compared.
##
## Rendered as two dot-separated parts rather than one number so RPC_SET_VERSION can
## become a derived hash later without the format changing shape.
static func version_string() -> String:
	return "%d.%s" % [WIRE_VERSION, RPC_SET_VERSION]


## Whether a version token from somewhere else can play with this build.
##
## Exact equality, and an empty token is never compatible. Empty is the important
## case: it is what a build from before this check existed looks like, because it
## publishes no version at all. Treating "absent" as "fine" would let through the
## exact mismatch this was written for, so absence is a mismatch.
static func is_compatible(other: String) -> bool:
	return not other.is_empty() and other == version_string()


## The player-facing explanation of a refused join.
##
## Phrased from the joining player's side in both places it is used, so the same
## sentence works whether the client noticed the mismatch on the lobby or the host
## noticed it during the handshake.
##
## Three shapes rather than one, because the first thing anyone asks is which of the
## two builds is the stale one, and an absent version answers that precisely: only a
## build older than this check publishes nothing. Naming the stale side turns the
## message into something a player can act on instead of a bare refusal.
static func mismatch_message(match_version: String, peer_version: String) -> String:
	const ADVICE := "Both players need to be on the same build."
	if match_version.is_empty():
		return "That match is running an older version of the game (yours is %s). %s" % [
			_describe(peer_version), ADVICE]
	if peer_version.is_empty():
		return "Your copy of the game is older than that match (the match is on %s). %s" % [
			match_version, ADVICE]
	return "That match is running a different version of the game (match %s, you %s). %s" % [
		match_version, peer_version, ADVICE]


## Renders a version for display, including the absent case. A peer that publishes no
## version predates this check, so there is no number to show for it.
static func _describe(version: String) -> String:
	return version if not version.is_empty() else "an older build"
