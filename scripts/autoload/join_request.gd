class_name JoinRequest
extends RefCounted

## One attempt to join a match, from the press of a button to the lobby opening or a
## dialog explaining why it did not.
##
## Joining is not one operation but two — reaching the session, then being admitted to it
## — spread across several awaits, any of which the player can walk away from and any of
## which a newer join can replace. NetManager used to answer all of that with a bool and a
## handful of fields on the autoload: `last_error`, `last_join_was_cancelled`. Shared
## state cannot say *which* join it is describing, and that is precisely the question when
## two of them overlap. An invite accepted while a code join was still on the loading
## screen would set the shared flag, and the code join's own waiter would read it and
## report the replacement's outcome as its own.
##
## So each attempt carries its own answer. The handle is returned the moment the join
## starts rather than when it finishes, which is what lets the screen that owns the
## attempt bind its Cancel button to *that* attempt instead of to whichever one happens to
## be running by the time the button is pressed.
##
## RefCounted rather than a Dictionary so the outcome is typed and so the object stays
## alive exactly as long as someone holds it: a superseded attempt's waiter still owns its
## handle and still reads a truthful answer out of it after the session has moved on.

## Raised once, when the attempt reaches a terminal outcome. Use wait(), which also
## covers an attempt that finished before the caller got round to awaiting it.
signal finished()

enum Outcome {
	## Still running: connecting, or waiting on the host to admit this player.
	PENDING,
	## The host admitted this player and the session is theirs to enter.
	SUCCEEDED,
	## The player asked for it to stop. Not a failure, and shows no error.
	CANCELLED,
	## Another join replaced this one. The replacement owns the outcome, so this shows
	## nothing at all -- neither an error nor a screen change.
	SUPERSEDED,
	## It did not work, and `reason` says why in words fit to show the player.
	FAILED,
}

## Monotonic, never reused, and never zero. Identifies this attempt in NetManager's
## bookkeeping for as long as it is running.
var id: int = 0
var outcome: Outcome = Outcome.PENDING
## Player-facing explanation, set only for FAILED.
var reason: String = ""
## The session generation this attempt was admitted into, or 0 when it never was.
## NetManager.joined_session_is_live() checks it against the current session, so a success
## that arrived just before the host left cannot be mistaken for a session to enter.
var session_id: int = 0
## The host has accepted this player, but the attempt has not been answered yet.
##
## Provisional on purpose. Acceptance arrives on an RPC and the outcome is read on a poll,
## so the two are never the same instant, and a Cancel landing in between must still win:
## a player who asked to stop should not be seated because the answer overtook them. The
## poll consumes this, checks the session is still there, and only then settles.
var admitted := false


func is_pending() -> bool:
	return outcome == Outcome.PENDING


func succeeded() -> bool:
	return outcome == Outcome.SUCCEEDED


## True when nothing should be shown to the player: they cancelled it themselves, or
## another join replaced it and owns whatever is on screen now.
func is_silent() -> bool:
	return outcome == Outcome.CANCELLED or outcome == Outcome.SUPERSEDED


func was_cancelled() -> bool:
	return outcome == Outcome.CANCELLED


func was_superseded() -> bool:
	return outcome == Outcome.SUPERSEDED


## Awaits the outcome, returning self so the result can be read in the same statement.
## Safe to call after the attempt has already finished, which an await on `finished`
## alone would not be -- that would wait for a signal that has already been raised.
func wait() -> JoinRequest:
	if outcome == Outcome.PENDING:
		await finished
	return self


## Records the terminal outcome. Only the first call takes effect: an attempt that has
## already been answered keeps the answer it was given, so a late callback cannot rewrite
## a cancellation into a success or a failure into silence.
func settle(result: Outcome, message: String = "") -> bool:
	if outcome != Outcome.PENDING:
		return false
	outcome = result
	reason = message
	finished.emit()
	return true
