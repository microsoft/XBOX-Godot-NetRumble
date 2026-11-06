class_name AchievementService
extends RefCounted

## GDK achievement unlocks. Wraps GDK.achievements.update_achievement_async, which maps
## to XblAchievementsManagerUpdateAchievement on the underlying Xbox service.
##
## Achievement ids ("1", "2", …) are the AchievementId strings from
## docs/achievements2017.xml. Local counters are persisted by Services. Reports first
## query Xbox's cache so resynchronizing saved counters does not submit progress that
## Xbox already has, which Achievements Manager rejects.
##
## The ids are the AchievementId values in `docs/achievements2017.xml`, which is the
## config imported into Partner Center. Nothing here may be renumbered on its own: an id
## is the only thing tying a rule to the name, description and gamerscore the service
## already published for it.

## One-off achievements, each unlocked in full by a single unlock() call.
const ACHIEVEMENT_FIRST_MATCH := "1"    ## Finish your first match.
const ACHIEVEMENT_FIRST_DEATH := "2"    ## Get destroyed for the first time.
const ACHIEVEMENT_FIRST_KILL := "3"     ## Destroy your first enemy ship.
const ACHIEVEMENT_MATCH_WON := "4"      ## Win a match.
const ACHIEVEMENT_FLAWLESS_WIN := "5"   ## Win a match without being destroyed once.

## Incremental achievements, reported as a percentage as they progress.
const ACHIEVEMENT_ALL_WEAPONS := "6"    ## Fire every weapon at least once.
const ACHIEVEMENT_ALL_BUFFS := "7"      ## Collect every buff power-up at least once.
const ACHIEVEMENT_ASTEROIDS := "8"      ## Destroy 250 asteroids.
const ACHIEVEMENT_ALL_MODES := "9"      ## Complete a match in every game mode.
const ACHIEVEMENT_CENTURION := "10"     ## Destroy 100 enemy ships.

const _REDUNDANT_PROGRESS_HRESULTS := [0x8000FFFF, 0x80070057, 0x8007139F]

## One queue per XboxUser; concurrent reports retain the highest requested percentage.
var _pending: Dictionary = {}
var _generation := 0


func invalidate_pending_reports() -> void:
	_generation += 1
	_pending.clear()


func unlock(user: Variant, achievement_id: String) -> void:
	update_progress(user, achievement_id, 100)


## Records how far along an achievement is, unlocking it at 100.
##
## Equal/lower progress is a no-op only when confirmed by the Xbox cache. Failed reads
## or writes remain warnings; the persisted counters can be resynchronized later.
func update_progress(user: Variant, achievement_id: String, percent: int) -> void:
	if achievement_id.is_empty():
		return

	var gdk: Variant = _gdk()
	if gdk == null or user == null:
		return

	var clamped := clampi(percent, 0, 100)
	if clamped == 0:
		return
	if _pending.has(user):
		var queued: Dictionary = _pending[user]
		queued[achievement_id] = maxi(int(queued.get(achievement_id, 0)), clamped)
		return

	var pending: Dictionary = {achievement_id: clamped}
	_pending[user] = pending
	var generation := _generation
	await _flush_progress(gdk.achievements, user, pending, generation)
	if generation == _generation:
		_pending.erase(user)


func _flush_progress(achievements: Variant, user: Variant, pending: Dictionary, generation: int) -> void:
	while not pending.is_empty():
		var query: Variant = await achievements.query_player_achievements_async(user)
		if generation != _generation:
			return
		if query == null or not query.ok:
			_warn("[Services] Reading achievement progress failed: %s" % _reason(query))
			return
		var cached: Array = achievements.get_cached_achievements(user)

		var batch := pending.duplicate()
		pending.clear()
		for achievement_id: String in batch:
			var percent := maxi(int(batch[achievement_id]), int(pending.get(achievement_id, 0)))
			pending.erase(achievement_id)
			var recorded := _recorded_percent(cached, achievement_id)
			if recorded < 0:
				_warn("[Services] Achievement %s is missing from Xbox's cache; verify the title and sandbox configuration."
					% achievement_id)
				continue
			if recorded >= percent:
				continue

			var result: Variant = await achievements.update_achievement_async(user, achievement_id, percent)
			if generation != _generation:
				return
			if result != null and result.ok:
				continue
			var redundant := await _confirmed_redundant_update(achievements, user, achievement_id, percent, result)
			if generation != _generation:
				return
			if redundant:
				continue
			_warn("[Services] Achievement progress (%s -> %d%%) failed: %s"
				% [achievement_id, percent, _reason(result)])


func _confirmed_redundant_update(
		achievements: Variant, user: Variant, achievement_id: String, percent: int, result: Variant) -> bool:
	if result == null or String(result.code) != "achievement_update_submit_failed" \
			or not _REDUNDANT_PROGRESS_HRESULTS.has(int(result.hresult) & 0xFFFFFFFF):
		return false
	# Another device can advance Xbox's state between our query and submission.
	var query: Variant = await achievements.query_player_achievements_async(user)
	return query != null and query.ok \
		and _recorded_percent(achievements.get_cached_achievements(user), achievement_id) >= percent


func _recorded_percent(achievements: Array, achievement_id: String) -> int:
	for achievement: Variant in achievements:
		if achievement != null and String(achievement.id) == achievement_id:
			return 100 if achievement.unlocked else int(achievement.progress_percent)
	return -1


func _warn(message: String) -> void:
	push_warning(message)


func _gdk() -> Variant:
	return PlatformAccess.gdk()


func _reason(result: Variant) -> String:
	return PlatformAccess.reason(result)
