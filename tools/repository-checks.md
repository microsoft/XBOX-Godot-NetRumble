# Repository checks

> **You do not need this page to run, export or learn from the sample.** It is for
> contributors changing repository text or package configuration, and CI runs these checks as
> required gates.

---

Two validation scripts, both pure text analysis: no engine, no SDK, no
secrets, and both run as hard gates in CI (`.github/workflows/ci.yml`). Run
them locally before pushing:

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
Party, Xbox policy or roaming. CI's parse/import job is currently advisory; the two text checks
are hard gates. See [CONTRIBUTING](../CONTRIBUTING.md) and [Manual test plan](../docs/manual-test-plan.md).

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
  platform service unavailable, and Godot still exits 0, so the headless parse
  job cannot see it. The easy way to cause this is writing `--` inside the
  comment block as an em dash; XML forbids a double hyphen in a comment.
- **At export**, the hazards produce a mis-named binary or an aborted package
  rather than an error message.

Every rule the script enforces mirrors a hazard already documented in the
config's own comment block: well-formed XML, `TitleId` / `MSAAppId` /
`Identity` present, the PC entry first in `ExecutableList`, unique executable
ids, no `Executable` start-tag spelled inside the comment, and nothing
following the closing `</Game>` tag.
