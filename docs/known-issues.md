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

## What is not on this list

Deliberate limits are not bugs. The sample has no host migration and no join-in-progress, it uses
PlayFab Lobby discovery instead of matchmaking queues, and its typed text is in-match only with no
persistence. Those are design decisions, and they are explained in
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
