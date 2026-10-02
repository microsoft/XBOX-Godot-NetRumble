# Known issues

This sample is still being built, and some things are broken. Here is what we already know
about, in rough order of how much it will get in your way. Please check this list before you
file a bug.

This page is a hand-picked summary of the problems most likely to affect you, so it is
deliberately short. The [issue tracker][issues] is the live and complete list, and it is the
place to look if something here seems out of date.

See also: [Troubleshooting](troubleshooting.md) · [Manual test plan](manual-test-plan.md) ·
[Glossary](glossary.md)

---

## What you are most likely to hit

| What you will see | Where | Tracking |
| --- | --- | --- |
| In three-player matches, once everyone has died a few times, players start losing control of their own ship. It drifts off on its own, jitters, or gets dragged into a corner. Two-player matches are not affected. | PC and console | [#2][issue-2] |
| Quitting after a match that used voice or typed text can pause before the process closes, because the addon's chat-control teardown may not return. Leaving a match no longer waits on that call, so this is confined to exit and is capped rather than open-ended. | PC and console | [XBOX-Godot-Sample#169][issue-169] |
| Shots sometimes bounce off another player's ship instead of counting as a hit. | PC | [#3][issue-3] |
| Backing out of the lobby code screen with **B** can leave the menu unresponsive. Pressing **B** again gets you out and restores it. | Console | [#4][issue-4] |
| The ready indicator on the lobby roster is slightly too big for the circle it sits in. | PC | [#1][issue-1] |
| A full group of four does not search for a match: the queue cannot take a ticket that is already at its maximum of four. When all four are ready, the group starts a private match automatically, in the same lobby. | PC and console | [Below](#a-full-group-of-four-starts-a-private-match) |
| A matched game starts with the players who have arrived. A player who arrives after it has started cannot join that round and is returned to the menu to search again. | PC and console | [Below](#players-who-arrive-after-a-match-starts) |
| If a match is found at the very moment a search is cancelled or runs out of time, the group closes instead of joining it, and a new group can be opened once the old group's usual cleanup has finished. | PC and console | [Below](#a-match-found-just-as-a-search-stops) |

## The chat cleanup hang

This is the one to be aware of if you are evaluating the multiplayer code.

Typed text does send and display correctly: a coordinated live run exchanged messages in both
directions and the four-message display behaved as designed. What did not work was leaving. The
game asked the addon to destroy the chat control on the way out of a match and waited for that to
finish, and that wait did not return. Because a rejoin begins by awaiting the same leave, the
player was then stranded on the joining screen, and Cancel could not release them either: it
reaches that leave through the same teardown.

The sample no longer destroys the chat control when it leaves a match. A chat control belongs to
the signed-in player rather than to a match, and this title has one player for its whole lifetime,
so the control is created once and reused by every later match. A live leave and rejoin then
completed normally.

That is a way around the defect rather than a fix for it. The addon call is unchanged, and it
still runs when the title exits — bounded there by the shutdown drain, so it can delay an exit but
not hang it indefinitely. Quitting straight after a voice match has not been retested since the
change. The defect is tracked upstream in [XBOX-Godot-Sample#169][issue-169]. Do not treat forcing
an exit as a workaround.

The full technical detail, including what the coordinated run did and did not prove, is in the
[manual test plan](manual-test-plan.md#known-cleanup-blocker).

## A full group of four starts a private match

Quick Match fills Deathmatch matches of two to four players from the `godotnr_q` queue. A group of
one to three players readies up together in its lobby, and the group's owner submits one
matchmaking ticket for all of them, which PlayFab matches with other players.

A full group of four does not search. A ticket that already carries four players meets this
queue's four-player maximum, and the queue does not take it. The rule is documented in
[Configuring matchmaking queues][mm-queues]:

> If a ticket already meets the maximum requirement for a match, however, it is rejected.

Instead, when all four are ready, the group starts a private match automatically: the same lobby
and the same players, with no search, no ticket and nothing extra to press. Any change to who is in
the group sets everyone back to not ready, so readiness given by four players never starts a
search for three. After each match the group stays together for further rounds of two to four
players. See [Private Start](matchmaking.md#private-start).

If the private match cannot be started, what happens depends on how far it got, and it never
falls back to searching for a match:

- When the lobby is confirmed back as the group's own, the players still in the group are
  returned to it, unready, with the reason, and can ready up again.
- If, before the lobby was switched to the private match, the group's lobby cannot be reopened, it
  stays closed until the owner tries again or leaves.
- If the switch cannot be confirmed or undone, the group's owner leaves or is lost, or anything
  fails once the private match has been committed, the group ends with the reason, and its lobby
  and connection are cleaned up.

## Players who arrive after a match starts

A match can start with the players who have arrived. Players who arrive after it starts cannot join
that round and may need to search again.

Once PlayFab has matched a group, the matched game starts as soon as two to four of its players
are present and ready in the match's lobby. It does not wait for every player the service
matched. A player who arrives after the start is not added to that round. They are shown *"This
match is already starting or in progress. Return to Matchmaking to search again."* If the game
cannot tell why the match could not be joined, they are shown *"This match could not be joined. It
may already have started. Return to Matchmaking to search again."* Nothing else is affected: the
players already in the match carry on, and the late player can search again from
**Matchmaking**.

## A match found just as a search stops

A search that is cancelled, left or timed out can still be matched by the service in the same
moment. The cancel stays binding: the group does not join that match or reopen as if nothing had
happened, and every member is shown *"A match was found just as the search stopped, so the group
was closed."* Everyone is returned to the menu, and a new group can be opened.

The cancellation still finishes: the service reports that the match won the race, and nothing is
restarted. The group's usual cleanup of its lobby and connection then finishes, and Quick Match can
be used again after that. Only if that answer never arrives does the
game restart its multiplayer services -- never your account or your saves -- before Quick Match can
be used again. Until that finishes, which takes up to about 20 seconds, the Matchmaking row
explains that the previous session is still finishing. Signing out, or the game being suspended,
during that wait does not skip the restart: it still runs once, and the next player can use Quick
Match without restarting the game. An invitation accepted during that wait is kept and joined once
the restart has finished. If that restart of the multiplayer services itself fails, online play
stays unavailable until the game is restarted: every online option says so instead of asking you
to try again, an invitation is answered once with the same reason, and quitting still takes no
longer than usual. Practice is refused only while the group that was searching still holds that
cleanup. Once it has been let go -- after signing out or a suspend, for example -- a signed-in
player can start Practice as usual, because Practice needs no online services. See the
configuration guide for the addon revision this sample is built from.

## What is not on this list

Deliberate limits are not bugs. The sample has no host migration and no join-in-progress, Host
Match finds its sessions through PlayFab Lobby discovery rather than a matchmaking queue, and its
typed text is in-match only with no persistence. Those are design decisions, and they are explained in
[what this sample does not do](multiplayer.md#scope-and-non-goals).

Setup and build failures are not on this list either. If the game will not start, will not export
or will not sign in, start with [Troubleshooting](troubleshooting.md).

## Found something that is not here?

Please tell us. Bug reports from people outside the team are genuinely useful, and a sample that
misbehaves in someone else's hands is worth more to us as a report than as a surprise.

1. Search the [issue tracker][issues] first, in case it is already filed.
2. Check [Troubleshooting](troubleshooting.md), which covers the setup and export failures that
   come up most often.
3. If it is still unexplained, [open a new issue][new-issue].

Tell us which platform you were on, whether you were signed in to an XBOX account or running
offline, your Godot version, and anything the Godot Output panel printed. For a multiplayer
problem, say what each player saw, since the host and the client often see different things.
[SUPPORT](../SUPPORT.md) has the full list of what helps.

[issues]: https://github.com/microsoft/XBOX-Godot-NetRumble/issues
[new-issue]: https://github.com/microsoft/XBOX-Godot-NetRumble/issues/new/choose
[issue-1]: https://github.com/microsoft/XBOX-Godot-NetRumble/issues/1
[issue-2]: https://github.com/microsoft/XBOX-Godot-NetRumble/issues/2
[issue-3]: https://github.com/microsoft/XBOX-Godot-NetRumble/issues/3
[issue-4]: https://github.com/microsoft/XBOX-Godot-NetRumble/issues/4
[issue-169]: https://github.com/microsoft/XBOX-Godot-Sample/issues/169
[mm-queues]: https://learn.microsoft.com/en-us/xbox/playfab/multiplayer/matchmaking/config-queues
