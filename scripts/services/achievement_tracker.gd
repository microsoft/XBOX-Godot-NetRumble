class_name AchievementTracker
extends RefCounted

## Lifetime achievement progress for the local player.
##
## Deliberately knows nothing about the platform or the network. It is a counter store
## plus the rules that turn those counters into a percentage per achievement, and it
## announces a change through `progress_changed`. Services owns it, feeds it, persists it
## and is the only thing that talks to the GDK on its behalf.
##
## That split is what makes offline play work. Every counter advances whether or not the
## player is signed in — practice against bots is the one mode that runs with no identity
## at all — and the reports that could not be delivered are re-sent by `resync()` once
## sign-in resolves. The service keeps the highest percentage it has seen, so replaying a
## report that already landed costs a call and changes nothing.
##
## The counters are the local player's own. Every call site reports something the local
## player did, on the machine that player is sitting at, because that is the only machine
## that can unlock anything for them: the host does not (and must not) unlock achievements
## on a client's behalf.

## Emitted whenever an achievement's completion percentage moves. Also emitted for every
## achievement with progress by `resync()`.
signal progress_changed(achievement_id: String, percent: int)

## Targets for the counting achievements. These are the numbers the published
## descriptions in `localization.xml` promise, so they are not tuning values.
const ASTEROID_TARGET := 250
const KILL_TARGET := 100
## "Full House" asks for a populated match in each mode, so a mode only counts when there
## were this many *human* players in it. Without the floor a practice match against bots
## would satisfy it in a few minutes. Deathmatch is currently the only mode, so this is
## what keeps the achievement meaning anything at all.
const FULL_HOUSE_MIN_HUMANS := 3
## A win needs someone to beat. Bots count here — the win achievements do not
## promise human opposition, and practice is a legitimate way to earn them.
const WIN_MIN_PLAYERS := 2

## Every weapon, buff and game mode there is. Read from the enums rather than written out
## so adding one moves the target with it instead of silently leaving the achievement
## reachable without the new entry. Functions rather than constants because an enum's
## size is not a constant expression.
static func weapon_count() -> int:
	return NRTypes.WeaponType.size()


static func buff_count() -> int:
	return NRTypes.BuffType.size()


static func mode_count() -> int:
	return NRTypes.GameModeType.size()


var matches_completed: int = 0
var wins: int = 0
var flawless_wins: int = 0
var kills: int = 0
var deaths: int = 0
var asteroids_destroyed: int = 0
## Bit per NRTypes.WeaponType / BuffType / GameModeType.
var weapons_fired: int = 0
var buffs_collected: int = 0
var modes_completed: int = 0

## Deaths in the match currently being played, for the flawless-win rule. Not persisted:
## it describes one match, and a match does not survive the process.
var _match_deaths: int = 0
## Set when a counter moves, cleared once Services has written the stats out.
var _dirty: bool = false
## Last percentage announced per achievement, so an unchanged one is not re-sent every
## time an unrelated counter moves. In memory only — `resync()` clears it precisely so a
## fresh session re-reports everything to a service that may have missed it.
var _reported: Dictionary = {}


# --- Gameplay reports -------------------------------------------------------

## A new match is under way. Only resets the per-match state; nothing lifetime is
## touched, and an abandoned match is left counted as whatever it reached.
func begin_match() -> void:
	_match_deaths = 0


func note_kill() -> void:
	kills += 1
	_touch()


func note_death() -> void:
	deaths += 1
	_match_deaths += 1
	_touch()


func note_weapon_fired(weapon: int) -> void:
	if weapon < 0 or weapon >= weapon_count():
		return
	var mask := weapons_fired | (1 << weapon)
	if mask == weapons_fired:
		return
	weapons_fired = mask
	_touch()


func note_buff_collected(buff: int) -> void:
	if buff < 0 or buff >= buff_count():
		return
	var mask := buffs_collected | (1 << buff)
	if mask == buffs_collected:
		return
	buffs_collected = mask
	_touch()


func note_asteroid_destroyed() -> void:
	asteroids_destroyed += 1
	_touch()


## Records a finished match from the local player's point of view.
##
## `placement` is 1-based, `player_count` counts everyone on the scoreboard including
## bots, and `human_count` counts only the peers behind them.
func note_match_completed(mode: int, placement: int, player_count: int, human_count: int) -> void:
	matches_completed += 1

	if placement == 1 and player_count >= WIN_MIN_PLAYERS:
		wins += 1
		if _match_deaths == 0:
			flawless_wins += 1

	if human_count >= FULL_HOUSE_MIN_HUMANS and mode >= 0 and mode < mode_count():
		modes_completed |= 1 << mode

	_match_deaths = 0
	_touch()


# --- Persistence ------------------------------------------------------------

func to_dict() -> Dictionary:
	return {
		"matches_completed": matches_completed,
		"wins": wins,
		"flawless_wins": flawless_wins,
		"kills": kills,
		"deaths": deaths,
		"asteroids_destroyed": asteroids_destroyed,
		"weapons_fired": weapons_fired,
		"buffs_collected": buffs_collected,
		"modes_completed": modes_completed,
	}


## Replaces the counters wholesale. Used for the boot read and again when the cloud copy
## arrives at sign-in, so anything malformed reads as zero rather than propagating.
func apply_dict(data: Dictionary) -> void:
	matches_completed = int(data.get("matches_completed", 0))
	wins = int(data.get("wins", 0))
	flawless_wins = int(data.get("flawless_wins", 0))
	kills = int(data.get("kills", 0))
	deaths = int(data.get("deaths", 0))
	asteroids_destroyed = int(data.get("asteroids_destroyed", 0))
	weapons_fired = int(data.get("weapons_fired", 0))
	buffs_collected = int(data.get("buffs_collected", 0))
	modes_completed = int(data.get("modes_completed", 0))


## The cloud copy and the local copy are the same player's progress reached from two
## places, and either can be the further along: the local one after a session played
## offline, the cloud one after a session played on another console. Merging per counter
## keeps whichever is, rather than letting a stale read undo earned progress.
func merge_dict(data: Dictionary) -> void:
	matches_completed = maxi(matches_completed, int(data.get("matches_completed", 0)))
	wins = maxi(wins, int(data.get("wins", 0)))
	flawless_wins = maxi(flawless_wins, int(data.get("flawless_wins", 0)))
	kills = maxi(kills, int(data.get("kills", 0)))
	deaths = maxi(deaths, int(data.get("deaths", 0)))
	asteroids_destroyed = maxi(asteroids_destroyed, int(data.get("asteroids_destroyed", 0)))
	weapons_fired |= int(data.get("weapons_fired", 0))
	buffs_collected |= int(data.get("buffs_collected", 0))
	modes_completed |= int(data.get("modes_completed", 0))


## Zeroes everything, for when the signed-in user goes away and the next player must not
## inherit their progress.
func clear() -> void:
	apply_dict({})
	_match_deaths = 0
	_reported.clear()
	_dirty = false


func is_dirty() -> bool:
	return _dirty


func clear_dirty() -> void:
	_dirty = false


# --- Progress ---------------------------------------------------------------

## Re-announces every achievement that has any progress, forgetting what was already
## sent. Called once sign-in resolves: everything earned before there was an identity to
## earn it against has to be delivered, and there is no way to ask the service what it
## already knows without paying for a full read.
func resync() -> void:
	_reported.clear()
	_publish()


## Percentage complete for one achievement id, 0-100.
func percent_for(achievement_id: String) -> int:
	match achievement_id:
		AchievementService.ACHIEVEMENT_FIRST_MATCH:
			return _milestone(matches_completed)
		AchievementService.ACHIEVEMENT_FIRST_DEATH:
			return _milestone(deaths)
		AchievementService.ACHIEVEMENT_FIRST_KILL:
			return _milestone(kills)
		AchievementService.ACHIEVEMENT_MATCH_WON:
			return _milestone(wins)
		AchievementService.ACHIEVEMENT_FLAWLESS_WIN:
			return _milestone(flawless_wins)
		AchievementService.ACHIEVEMENT_ALL_WEAPONS:
			return _ratio(_bit_count(weapons_fired), weapon_count())
		AchievementService.ACHIEVEMENT_ALL_BUFFS:
			return _ratio(_bit_count(buffs_collected), buff_count())
		AchievementService.ACHIEVEMENT_ASTEROIDS:
			return _ratio(asteroids_destroyed, ASTEROID_TARGET)
		AchievementService.ACHIEVEMENT_ALL_MODES:
			return _ratio(_bit_count(modes_completed), mode_count())
		AchievementService.ACHIEVEMENT_CENTURION:
			return _ratio(kills, KILL_TARGET)
	return 0


## Every id this tracker has a rule for, in the display order the config declares.
static func achievement_ids() -> PackedStringArray:
	return PackedStringArray([
		AchievementService.ACHIEVEMENT_FIRST_MATCH,
		AchievementService.ACHIEVEMENT_FIRST_DEATH,
		AchievementService.ACHIEVEMENT_FIRST_KILL,
		AchievementService.ACHIEVEMENT_MATCH_WON,
		AchievementService.ACHIEVEMENT_FLAWLESS_WIN,
		AchievementService.ACHIEVEMENT_ALL_WEAPONS,
		AchievementService.ACHIEVEMENT_ALL_BUFFS,
		AchievementService.ACHIEVEMENT_ASTEROIDS,
		AchievementService.ACHIEVEMENT_ALL_MODES,
		AchievementService.ACHIEVEMENT_CENTURION,
	])


func _touch() -> void:
	_dirty = true
	_publish()


## Announces the achievements whose percentage has moved since the last announcement.
## Nothing at 0% is sent: it says nothing the service does not already assume, and it
## would mean ten calls on the first frame of every session.
func _publish() -> void:
	for achievement_id in achievement_ids():
		var percent := percent_for(achievement_id)
		if percent <= 0:
			continue
		if int(_reported.get(achievement_id, -1)) >= percent:
			continue
		_reported[achievement_id] = percent
		progress_changed.emit(achievement_id, percent)


## A do-it-once achievement: any progress at all completes it.
static func _milestone(count: int) -> int:
	return 100 if count > 0 else 0


static func _ratio(count: int, target: int) -> int:
	if target <= 0:
		return 0
	return clampi(int(floor(float(count) * 100.0 / float(target))), 0, 100)


## Population count. The collection achievements track "which ones" in a bitmask, and
## their progress is "how many of them", which is the number of bits set.
static func _bit_count(mask: int) -> int:
	var count := 0
	var bits := mask
	while bits != 0:
		bits &= bits - 1
		count += 1
	return count
