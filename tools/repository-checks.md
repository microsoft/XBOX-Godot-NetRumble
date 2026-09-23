# Repository checks

> **You do not need this page to run, export or learn from the sample.** It is for
> contributors changing repository text or package configuration, and CI runs these checks as
> required gates.

---

These repository text checks need no engine, SDK or secrets, and run as hard gates in CI
(`.github/workflows/ci.yml`). Run them locally before pushing:

```powershell
.\tools\check-deport.ps1 -Detailed     # sample voice
.\tools\check-game-config.ps1          # MicrosoftGame.config validity
```

For script/resource changes, follow with the existing Godot parse/import sequence **in order**:

```powershell
godot.exe --headless --path . --import
godot.exe --headless --path . --quit
```

Inspect both exit codes and both outputs for script/resource errors; Godot can report errors
while exiting zero. This needs built addons/importable resources and does not test registration,
Party, Xbox policy or roaming. CI's parse/import job is currently advisory; these text checks
are hard gates. See [CONTRIBUTING](../CONTRIBUTING.md) and [Manual test plan](../docs/manual-test-plan.md).

Account-save and multiplayer lifecycle changes also need the behavioral suite:

```powershell
.\tools\run-save-tests.ps1 -Godot 'C:\path\to\Godot_console.exe'
# Faster multiplayer-only iteration; the default command above includes this suite.
.\tools\run-save-tests.ps1 -Godot 'C:\path\to\Godot_console.exe' -Suite Multiplayer
```

The runner uses isolated, distinct Xbox/PlayFab identities, fake GDK XGameSaveFiles results
(including returned Signals and dictionary `{path}` data), and disposable folders, never real
user saves, and does not initialize the live platform addons. It runs the copied project's
import pass before executing production GDScript with test doubles, then removes its temporary
project. The same runner is wired into the existing Godot CI job.

`multiplayer_failure_tests.gd`, called by `save_tests.gd`, injects synchronous errors,
returned completion Signals, terminal events and stalled native operations while retaining
production PartyService host/join/attach/leave and NetManager lifecycle logic. It covers
all six event kinds, pre-bind loss, absolute 45-second establishment and shared 15-second
cleanup boundaries, scoped Party/Lobby reset, stale completions, manual retry/chat recreation,
autonomous native reset/readiness reconciliation (including partial initialization), and
actual host/code/friend/invite loading screens. Clock seams advance deadlines without
waiting real budgets. No live addon, root-runtime shutdown, machine connectivity change
or real account/save/network modification is part of these tests. Native SDK ownership
and installed-binary provenance require separate companion-addon validation.

The network double rejects leave after native destruction, including the peer-disconnect
callback preceding DESTROYED. These cases verify retained chat, zero unnecessary scoped
shutdowns, safe manual retry and exact-instance handling of late results/old notifications.
Terminal state alone still requires cleanup; real leave errors are not broadly ignored.

Cover owner changes, authoritative empty
state, failed/malformed reads without overwrite or gameplay, Retry, canceled/stale completions,
missing SDK/SCID, signed-out users, same-owner write retry, resume provider reacquisition and
transactional full reload, actual acquisition handoff with abandoned-match notice/invite
priority, resume account loss and obsolete save/Quit modal guards, failed appearance
persistence followed by Suspend, unchanged explicit
save requests and the 50-row history bound. No save requires a separate dirty-marking call.
Actual menu-button regressions cover failed Options Back with inline/deferred error dialogs,
retained values and stale-account guards. Lifecycle cases cover orphaned invite outcomes,
newer buffered claims, owner-bound activity retirement outside Suspend, shutdown readiness
revocation, shared drain timeout and serialized old/new session/account writes.
PR-feedback regressions cover delayed resume Party/chat cleanup before readiness, actual
stall Back/Quit actions, repeated resume, cold fallback initialization with early removal
subscription, cancellation at acquisition stages, and social-group ownership/single-flight
across delayed replacement-account loads.
Source checks for forbidden desktop/token
caches and migration code supplement behavior tests; they do not replace them.

Registered-PC A/B isolation, console parity and same-account roaming still require live
[manual acceptance](../docs/manual-test-plan.md#account-owned-saves-pc-and-console).
Mocked success, import success and local file presence are not runtime parity evidence.
Custom-ID authentication diagnostics cannot substitute for gameplay: without a signed-in
XboxUser, account saves cannot become ready. Do not add a shipping bypass to run tests.

## `check-deport.ps1`

NetRumble is the reference sample for GDK and PlayFab integration in Godot, so
it has to explain the platform on its own terms rather than by comparison to
any other implementation. This script fails the build when framing of that kind
appears in `scripts/`, `docs/`, `tools/` or the README. `-Detailed` lists every
hit with its file and line.

## `check-game-config.ps1`

`MicrosoftGame.config` fails quietly in both directions, which is what makes it
worth a dedicated check:

- **At runtime**, a malformed file makes GDK initialization fail: `XboxBootstrap`
  gets back an HRESULT and nothing more. The game keeps running with every
  platform service unavailable and gameplay blocked by account/save readiness, and Godot
  still exits 0, so the headless parse job cannot see it. The easy way to cause this is writing `--` inside the
  comment block as an em dash; XML forbids a double hyphen in a comment.
- **At export**, the hazards produce a mis-named binary or an aborted package
  rather than an error message.

Every rule the script enforces mirrors a hazard already documented in the
config's own comment block: well-formed XML, `TitleId` / `MSAAppId` /
`Identity` present, the PC entry first in `ExecutableList`, unique executable
ids, no `Executable` start-tag spelled inside the comment, and nothing
following the closing `</Game>` tag.
