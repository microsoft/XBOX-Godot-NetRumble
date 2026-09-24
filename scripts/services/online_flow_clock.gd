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
## Not an autoload and not a scheduler: two reads, one wait, and one-shot deadline alarms --
## each on an engine timer of its own in production, fired by the clock's own advance on a
## clock that supplies its own time. Replacing the instance while an operation holds it is
## refused by its owners, because an operation that started on one clock and finished on
## another would be measuring nothing.


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


## A one-shot callback at an absolute deadline on the clock that armed it.
##
## Its owner holds it and cancels it on every path that ends the wait. Cancelling -- or
## firing -- takes it off the clock at once and drops the callable with it: nothing is left
## waiting on the clock's time, so a retired alarm keeps nothing alive and needs no teardown
## wait. The callable must not itself hold the alarm's owner -- a method on the owner, bound
## only to plain values, never a lambda that captures it -- or the two would keep each other
## alive for as long as the alarm is armed.
class Alarm extends RefCounted:
	var deadline_msec := 0
	var _id := 0
	var _armed_msec := 0
	var _callback := Callable()
	var _armed := false
	var _clock: WeakRef = null
	var _timer: SceneTreeTimer = null
	var _on_timer := Callable()

	func is_armed() -> bool:
		return _armed

	## The earliest clock time at which this alarm may fire: its deadline, and never the
	## instant it was armed, so an already-expired deadline fires on the next wake rather
	## than inside the call that armed it.
	func due_msec() -> int:
		return maxi(deadline_msec, _armed_msec + 1)

	## Idempotent, and safe before or after the alarm fired.
	func cancel() -> void:
		_armed = false
		_callback = Callable()
		_detach()

	func _fire() -> void:
		if not _armed:
			return
		var callback := _callback
		_armed = false
		_callback = Callable()
		_detach()
		if callback.is_valid():
			callback.call()

	## Off the clock: the engine timer, if any, no longer calls back, and the clock forgets it.
	func _detach() -> void:
		if _timer != null and _on_timer.is_valid() and _timer.timeout.is_connected(_on_timer):
			_timer.timeout.disconnect(_on_timer)
		_timer = null
		_on_timer = Callable()
		var clock: Variant = _clock.get_ref() if _clock != null else null
		_clock = null
		if clock != null:
			(clock as OnlineFlowClock)._forget_alarm(_id)


## The alarms armed on this clock and not yet fired or cancelled, by id. Held strongly, so
## an armed alarm fires even if its owner let go of the handle; firing or cancelling
## removes it at once.
var _alarms: Dictionary = {}
var _last_alarm_id := 0


## Calls `callback` once, with no arguments, on the first wake of this clock at or after
## `deadline_msec`. Never inside this call: an already-expired deadline fires on the next
## wake. Nothing re-arms it; cancel() is the only other way it ends.
func alarm_at(deadline_msec: int, callback: Callable) -> Alarm:
	var alarm := Alarm.new()
	_last_alarm_id += 1
	alarm._id = _last_alarm_id
	alarm.deadline_msec = deadline_msec
	alarm._armed_msec = now_msec()
	alarm._callback = callback
	alarm._armed = true
	alarm._clock = weakref(self)
	_alarms[alarm._id] = alarm
	if _drives_alarms_by_engine():
		_start_engine_timer(alarm)
	return alarm


## alarm_at() for a deadline `seconds` from now.
func alarm_after(seconds: float, callback: Callable) -> Alarm:
	return alarm_at(deadline_after(seconds), callback)


## How many alarms armed on this clock are still waiting to fire. Cancelled and fired
## alarms are gone from the count the moment they end, which is what lets a test prove
## none was left behind.
func armed_alarm_count() -> int:
	return _alarms.size()


## When the next armed alarm on this clock may fire, or -1 when none is armed. A clock that
## supplies its own time uses it to order its alarms among its other waits.
func next_alarm_due_msec() -> int:
	var earliest := -1
	for alarm: Alarm in _alarms.values():
		var due := alarm.due_msec()
		if earliest < 0 or due < earliest:
			earliest = due
	return earliest


## Fires every alarm on this clock that is due now, earliest first. A clock that supplies
## its own time calls this whenever that time moves; the production clock never needs to,
## because each of its alarms waits on an engine timer of its own. An alarm armed while
## this runs waits for the next wake, so none ever fires inside the call that armed it.
func fire_due_alarms() -> void:
	var now_ms := now_msec()
	var due: Array[Alarm] = []
	for alarm: Alarm in _alarms.values():
		if alarm.due_msec() <= now_ms:
			due.append(alarm)
	due.sort_custom(_fires_before)
	for alarm: Alarm in due:
		alarm._fire()


## Whether this clock's alarms wait on engine timers. True for the production clock, whose
## time is the engine's. A clock that supplies its own time returns false and fires its
## alarms from its own advance through fire_due_alarms().
func _drives_alarms_by_engine() -> bool:
	return true


func _fires_before(a: Alarm, b: Alarm) -> bool:
	var a_due := a.due_msec()
	var b_due := b.due_msec()
	return a_due < b_due or (a_due == b_due and a._id < b._id)


## One engine timer per alarm, for what is left of its wait. A timer that runs out early --
## a frame-pumped timer is not exact -- starts another for the remainder rather than firing
## ahead of the deadline. With no tree to time on, the alarm stays armed and inert rather
## than spinning.
func _start_engine_timer(alarm: Alarm) -> void:
	var loop := Engine.get_main_loop() as SceneTree
	if loop == null:
		return
	var wait_msec := maxi(alarm.due_msec() - now_msec(), 1)
	var timer := loop.create_timer(float(wait_msec) / 1000.0)
	var on_timer := _on_engine_timer.bind(alarm._id)
	timer.timeout.connect(on_timer)
	alarm._timer = timer
	alarm._on_timer = on_timer


func _on_engine_timer(alarm_id: int) -> void:
	var alarm: Alarm = _alarms.get(alarm_id) as Alarm
	if alarm == null:
		return
	alarm._timer = null
	alarm._on_timer = Callable()
	if now_msec() < alarm.due_msec():
		_start_engine_timer(alarm)
		return
	alarm._fire()


func _forget_alarm(alarm_id: int) -> void:
	_alarms.erase(alarm_id)
