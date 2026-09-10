class_name AchievementService
extends RefCounted

## GDK achievement unlocks. Wraps GDK.achievements.update_achievement_async, which maps
## to XblAchievementsManagerUpdateAchievement on the underlying Xbox service.
##
## Achievement ids ("1", "2", …) are the AchievementId strings from
## docs/achievements2017.xml. Reporting 100 unlocks the achievement immediately; anything
## below records progress the service retains for the player, so incremental achievements
## need only report the current position — they do not need to count toward their target
## in the title's own save data.
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


func unlock(user: Variant, achievement_id: String) -> void:
	update_progress(user, achievement_id, 100)


## Records how far along an achievement is, unlocking it at 100.
##
## The service keeps the highest percentage it has been told about, so a report that is
## behind the recorded one is harmless rather than a rollback. That is what lets progress
## earned offline — which never reaches here — be caught up by a single report once the
## player is signed in again, without the title having to know what the service already
## has.
func update_progress(user: Variant, achievement_id: String, percent: int) -> void:
	if achievement_id.is_empty():
		return

	var gdk: Variant = _gdk()
	if gdk == null or user == null:
		return

	var clamped := clampi(percent, 0, 100)
	var result: Variant = await gdk.achievements.update_achievement_async(user, achievement_id, clamped)
	if result == null or not result.ok:
		push_warning("[Services] Achievement progress (%s -> %d%%) failed: %s"
			% [achievement_id, clamped, _reason(result)])


func _gdk() -> Variant:
	return PlatformAccess.gdk()


func _reason(result: Variant) -> String:
	return PlatformAccess.reason(result)
