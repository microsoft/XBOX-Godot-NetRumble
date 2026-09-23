class_name OnlineFlowClock
extends RefCounted

## The one source of time for every online deadline: the matchmaking search, the handoff
## budgets, Party descriptor/property/lock waits, offline grace and activity backoff.
##
## A deadline that spans two services only means something if both measure it the same
## way. NetManager, the matchmaking flow, PartyService, MatchmakingService and
## PlatformSession therefore all read time from the single instance Services owns. The
## harness swaps in a fake before any work starts, which is how a 600-second search can be
## crossed without the suite sleeping for ten minutes; production keeps the monotonic
## engine clock and the frame-pumped timers the title has always used.
##
## Not an autoload and not a scheduler: two reads and one wait. Replacing the instance
## while an operation holds it is refused by its owners, because an operation that started
## on one clock and finished on another would be measuring nothing.


## Milliseconds on a monotonic clock. Values from two processes are never comparable --
## each console's clock starts at its own boot -- so a budget crosses the wire as time
## remaining, never as an absolute deadline.
func now_msec() -> int:
	return Time.get_ticks_msec()


## Waits at least `seconds`. Frame-pumped, so platform completions keep arriving while it
## waits. Returns at once when there is no scene tree to wait on.
func sleep_seconds(seconds: float) -> void:
	var loop := Engine.get_main_loop() as SceneTree
	if loop == null:
		return
	await loop.create_timer(maxf(seconds, 0.0)).timeout


## The absolute deadline `seconds` from now.
func deadline_after(seconds: float) -> int:
	return now_msec() + int(round(maxf(seconds, 0.0) * 1000.0))


## Seconds left before `deadline_msec`, never negative.
func remaining_seconds(deadline_msec: int) -> float:
	return maxf(0.0, float(deadline_msec - now_msec()) / 1000.0)


## True once the deadline has been reached. Equality counts as expired, so a check made
## exactly on the boundary never grants one more wait.
func has_expired(deadline_msec: int) -> bool:
	return now_msec() >= deadline_msec
