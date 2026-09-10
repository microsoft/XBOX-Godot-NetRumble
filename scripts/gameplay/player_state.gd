class_name PlayerState
extends Resource

## Per-player lobby and match state.
##
## `peer_id` is the Godot multiplayer peer id and is the authoritative key used by
## NetManager. `entity_id` carries the PlayFab entity id when the player signed in
## through PlayFab, and is empty for offline/local play.
##
## `to_dict()` / `from_dict()` exist only for the RPC boundary in NetManager, where
## roster entries are sent as plain Dictionaries.

@export var display_name: String = ""
@export var entity_id: String = ""
## Xbox user id, empty for offline play, custom-id test clients and any build without
## the GDK. This arrives over the game's own RPC and is a *claim*, not a credential:
## unlike `entity_id` — which the host overwrites with Party's authenticated entity key
## — nothing about the transport vouches for it, so a modified client can put someone
## else's XUID here.
##
## ProfileService turns the claim into something usable by checking it rather than
## trusting it: PlayFab is asked which title player account owns the XUID, and the
## answer has to match the entity id Party authenticated for the same peer (XR-047).
## Only claims that survive that check reach the Xbox profile service.
##
## Anything reading this field directly is still reading an unverified value. That is
## tolerable for recent-player reporting, where the worst case is a polluted local
## recent-players list — do not treat it as proof of identity or key anything
## security-relevant on it without verifying it first.
@export var xbox_user_id: String = ""
@export var peer_id: int = 0
@export var ship_color_id: int = 0
@export var ship_style_id: int = 0
@export var in_game: bool = false
@export var score: int = 0
@export var is_ready: bool = false
## Unique id of the ship this player currently controls, 0 when not spawned.
@export var ship_id: int = 0
## True for an AI practice opponent. Bots occupy an ordinary roster slot and are
## scored like anyone else; the flag only tells the world to attach a BotController
## instead of waiting for input from a peer, and tells NetManager not to hold the
## match's loading gate open waiting for a "player" that never loads anything.
@export var is_bot: bool = false

## Local-only; deliberately not exported or replicated.
var is_local_player: bool = false


func is_valid() -> bool:
	return not display_name.is_empty()


## The name to show for this player anywhere the roster is rendered.
##
## Prefers the gamertag the platform verified for this peer (XR-047), so what other
## players read comes from the Xbox profile service rather than from the peer's own
## roster entry. Falls back to `display_name` when there is no verified answer, which
## covers bots, offline and practice matches, desktop builds without the GDK, and any
## peer whose XUID claim did not check out.
func display_label() -> String:
	if not is_bot and Services != null:
		var verified: String = Services.gamertag_for_peer(peer_id)
		if not verified.is_empty():
			return verified
	return display_name


func to_dict() -> Dictionary:
	return {
		"display_name": display_name,
		"entity_id": entity_id,
		"xbox_user_id": xbox_user_id,
		"peer_id": peer_id,
		"ship_color_id": ship_color_id,
		"ship_style_id": ship_style_id,
		"in_game": in_game,
		"score": score,
		"is_ready": is_ready,
		"ship_id": ship_id,
		"is_bot": is_bot,
	}


static func from_dict(data: Dictionary) -> PlayerState:
	var state := PlayerState.new()
	state.display_name = data.get("display_name", "")
	state.entity_id = data.get("entity_id", "")
	state.xbox_user_id = data.get("xbox_user_id", "")
	state.peer_id = int(data.get("peer_id", 0))
	state.ship_color_id = int(data.get("ship_color_id", 0))
	state.ship_style_id = int(data.get("ship_style_id", 0))
	state.in_game = bool(data.get("in_game", false))
	state.score = int(data.get("score", 0))
	state.is_ready = bool(data.get("is_ready", false))
	state.ship_id = int(data.get("ship_id", 0))
	state.is_bot = bool(data.get("is_bot", false))
	return state


func color() -> Color:
	return Assets.player_color(ship_color_id)
