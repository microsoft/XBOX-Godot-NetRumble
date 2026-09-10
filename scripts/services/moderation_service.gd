class_name ModerationService
extends RefCounted

## Moderation of user generated content, and the path for reporting a player (XR-018).
##
## The only content this title lets a player author is a chat message: NRChatEntry
## captures up to 100 characters and PartyService broadcasts them. Join codes come from a
## title-owned alphabet and display names come from gamertags, both of which are already
## moderated elsewhere, so chat is the whole surface.
##
## Two halves, matching what the requirement asks for:
##
##   - Nothing reaches another player unverified. verify() runs the text through Xbox
##     Services string verification before PartyService is allowed to send it, and the
##     entry dialog stays open with the message intact so the player can rewrite it.
##   - A player can report another player. report() submits Xbox Services reputation
##     feedback, which is the reporting channel the addon binds; XGameUiShowPlayerReportUI
##     is not bound, so the title owns the reason list. show_profile_card() opens the
##     system profile card as the second, richer surface — it is where a player blocks or
##     files a report with evidence.
##
## Like PrivilegeService, none of this can be exercised on a desktop dev machine, so
## every call fails soft when the GDK is missing, uninitialized, or has no XboxUser.
##
## One deliberate asymmetry with PrivilegeService: a *failed* verification call is not
## treated as permission to send. A privilege check that cannot reach the service fails
## open, because refusing to start a match over a timed-out query is worse than the risk.
## Publishing unverified user text is the violation itself, so verification fails closed
## once the service is known to be available. The player is told to try again rather than
## told their message was offensive, because the title does not know that it was.
##
## Addon SDK objects (XboxUser, XboxResult) are held as Variant on purpose: the
## godot_gdk classes only exist when the native library loads, so naming them in type
## positions would break parsing on a machine without the extension.

## Reputation feedback types, as the addon spells them
## (addons/godot_gdk/doc_classes/XboxSocial.xml). An unknown value fails the call with
## `invalid_feedback_type`, so the reasons offered to the player are drawn from here.
const FEEDBACK_ABUSIVE_VOICE := "communications_abusive_voice"
const FEEDBACK_INAPPROPRIATE_UGC := "inappropriate_user_generated_content"
const FEEDBACK_CHEATER := "fair_play_cheater"
const FEEDBACK_UNSPORTING := "fair_play_unsporting"

## The reasons the player picks from, in the order they are shown. `type` is what the
## service is told; `label` is what the player reads.
const REPORT_REASONS: Array[Dictionary] = [
	{"type": FEEDBACK_ABUSIVE_VOICE, "label": "Abusive voice chat"},
	{"type": FEEDBACK_INAPPROPRIATE_UGC, "label": "Inappropriate messages"},
	{"type": FEEDBACK_UNSPORTING, "label": "Unsporting behavior"},
	{"type": FEEDBACK_CHEATER, "label": "Cheating"},
]

## What the player is told when their own message is held back. Kept vague on purpose:
## the service reports the first offending substring, and quoting it back is both an
## invitation to work around the filter and a way to put the objectionable text on
## screen a second time.
const _REJECTED_MESSAGE := "That message can't be sent. Please rephrase it."
const _UNVERIFIED_MESSAGE := "That message couldn't be checked right now. Please try again."


## Verdict shape returned by verify():
##   acceptable - may this text be published?
##   checked    - did the platform actually answer? False means "no GDK / no user", the
##                fail-soft path; a caller can tell "verified clean" from "not verified".
##   offending  - the first offending substring the service reported, for logs only.
##   message    - player-facing text, empty when acceptable.
static func _verdict(acceptable: bool, checked: bool, offending: String = "", message: String = "") -> Dictionary:
	return {
		"acceptable": acceptable,
		"checked": checked,
		"offending": offending,
		"message": message,
	}


## The permissive verdict every fail-soft path returns.
static func unchecked() -> Dictionary:
	return _verdict(true, false)


## Runs one player-authored string past Xbox Services string verification. Called before
## the message is handed to Party, never after: an unacceptable message must not exist on
## another player's screen even briefly.
func verify(user: Variant, text: String) -> Dictionary:
	var trimmed := text.strip_edges()
	if trimmed.is_empty():
		return _verdict(false, false)

	var gdk: Variant = _gdk_ready()
	if gdk == null or user == null:
		return unchecked()

	var result: Variant = await gdk.string_verify.verify_string_async(user, trimmed)
	if result == null or not result.ok:
		# Fail closed. See the note at the top of the file: the service is known to be
		# available here, so an unverified message is held back rather than published.
		push_warning("[Moderation] Could not verify text: %s" % _reason(result))
		return _verdict(false, false, "", _UNVERIFIED_MESSAGE)

	var data: Dictionary = result.data if result.data is Dictionary else {}
	var acceptable := bool(data.get("acceptable", false))
	var offending := String(data.get("first_offending_substring", ""))
	return _verdict(acceptable, true, offending, "" if acceptable else _REJECTED_MESSAGE)


## Reports a player through Xbox Services reputation feedback. `feedback_type` must be one
## of the REPORT_REASONS values. Returns true when the service accepted the report.
##
## Reporting is deliberately not gated on the communications privilege: an account that
## may not chat can still be on the receiving end of something worth reporting.
func report(user: Variant, target_xuid: String, feedback_type: String, reason: String = "") -> bool:
	if target_xuid.strip_edges().is_empty() or feedback_type.strip_edges().is_empty():
		return false

	var gdk: Variant = _gdk_ready()
	if gdk == null or user == null:
		# Desktop and custom-id test clients have no Xbox identity to report against.
		# Reported as a failure so the UI can say the report did not go anywhere, rather
		# than thanking the player for a report that was dropped on the floor.
		return false

	var result: Variant = await gdk.social.submit_reputation_feedback_async(
			user, target_xuid, feedback_type, reason)
	if result == null or not result.ok:
		push_warning("[Moderation] Could not submit reputation feedback: %s" % _reason(result))
		return false
	return true


## Opens the system profile card for a player. This is where Xbox itself offers blocking
## and its own reporting flow with evidence, so the title points at it rather than trying
## to reproduce it.
func show_profile_card(user: Variant, target_xuid: String) -> bool:
	if target_xuid.strip_edges().is_empty():
		return false

	var gdk: Variant = _gdk_ready()
	if gdk == null or user == null:
		return false

	var result: Variant = await gdk.game_ui.show_player_profile_card_async(user, target_xuid)
	if result == null or not result.ok:
		push_warning("[Moderation] Could not show the profile card: %s" % _reason(result))
		return false
	return true


## True when there is a platform to moderate and report through at all. The UI uses it to
## leave the report action out rather than offer one that cannot work.
func is_available(user: Variant) -> bool:
	return _gdk_ready() != null and user != null


## The label shown for a feedback type, for confirmation text.
static func describe_reason(feedback_type: String) -> String:
	for reason: Dictionary in REPORT_REASONS:
		if String(reason.get("type", "")) == feedback_type:
			return String(reason.get("label", ""))
	return ""


# --- Shared -----------------------------------------------------------------

func _gdk_ready() -> Variant:
	return PlatformAccess.gdk_ready()


func _reason(result: Variant) -> String:
	return PlatformAccess.reason(result)
