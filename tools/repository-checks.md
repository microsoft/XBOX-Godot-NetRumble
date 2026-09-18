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

Account-save changes also need the focused behavioral suite:

```powershell
.\tools\run-save-tests.ps1 -Godot 'C:\path\to\Godot_console.exe'
```

The runner uses isolated, distinct Xbox/PlayFab identities, fake GDK XGameSaveFiles results
(including returned Signals and dictionary `{path}` data), and disposable folders, never real
user saves, and does not initialize the live platform addons. It runs the copied project's
import pass before executing production GDScript with test doubles, then removes its temporary
project. The same runner is wired into the existing Godot CI job.

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
