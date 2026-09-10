# Build, export & deploy scripts

> **This page is for running, exporting and deploying the sample.** You do not need the
> repository checks unless you are changing files for a contribution; CI runs those gates and
> they are documented in [Repository checks](repository-checks.md).

PowerShell wrappers around the things you actually do with a NetRumble build:
**build the addons** (`sync_addons.ps1`, needed once per clone), then
**register and launch it on this PC** (`wdapp register` / `wdapp launch`) or **push it to a devkit**
(`xbapp deploy`).

Run them from anywhere; they resolve the repository root from their own
location.

```powershell
.\tools\sync_addons.ps1               # build addons\ from the submodule (needed once)
.\tools\deploy-pc.ps1 -Launch         # export + verify registration + registered launch
.\tools\deploy-console.ps1            # export for Scarlett + xbapp deploy
.\tools\export.ps1 -Target both       # export only, no deployment
```

Every export/deploy script takes `-Configuration debug|release` (default
`release`) and `-Clean`. All of them support `-?` for full help.

Before the PC sequence, obtain authorized sample title access and an XBOX test account for
**XDKS.1**, verify the machine sandbox, and sign in to the XBOX app. Sandbox changes require
administrator privileges and affect the whole machine; the scripts do not perform them.
See [configuration prerequisites](../docs/configuration.md#requirements) and the canonical
[capability matrix](../README.md#what-works-where).

---

## `sync_addons.ps1`: build the addons

`addons/` is gitignored build output, and this is the only thing that writes
it. A fresh clone cannot load the project's GDExtensions until it runs.

```powershell
.\tools\sync_addons.ps1                            # build Debug + Release, install both
.\tools\sync_addons.ps1 -SkipBuild                 # reinstall from the last build
.\tools\sync_addons.ps1 -Configuration Release     # release DLLs only
```

It builds the `external\xbox-godot-sample` submodule, installs the runtime
files here, adds the two GRDK console redistributables the XBOX export needs
from an installed Microsoft GDK, and finally copies the project's own
`.gdextension` manifests from `tools\addon-overrides\` over the result.

Requires Visual Studio 2022, vcpkg (the VS component is enough) and a Microsoft
GDK edition. Full detail, including how to move the submodule pin, is in
[docs/addon-maintenance.md](../docs/addon-maintenance.md).

---

## Why you need this at all

Running the project out of the editor initializes the GDK, but the process is
not a registered package, so there is no package identity. Sign-in, achievements,
multiplayer invites and protocol activation all need one. That
means exporting, even for a quick desktop test.

For offline/editor exploration, run `godot.exe --path .` after addon setup and choose
Continue Offline. Debug custom-ID multiplayer is a separate path requiring a **development
PlayFab title** that permits account creation; it bypasses XBOX checks and does not test Game Save.
See [two-instance setup](../docs/multiplayer.md#testing-two-players-on-one-pc).

---

## `deploy-pc.ps1`: XBOX on PC

Uses the `XBOX on PC` preset in `export_presets.cfg`, which the `godot_gdk`
addon registers as an export platform.

That platform stages a loose package into `build\_gdk_staging` and, because the
preset sets `dev/register_loose=true`, finishes by running
`wdapp register` on it. **No `.exe` is produced at the preset's `export_path`**.
The staging folder is the deliverable. The script exports, then confirms the
registration landed in `wdapp list`, and only runs `wdapp register` itself if it
did not.

```powershell
.\tools\deploy-pc.ps1 -Launch                  # primary sample path (release)
.\tools\deploy-pc.ps1 -Configuration debug -Launch
.\tools\deploy-pc.ps1 -SkipExport              # re-register the existing staging folder
.\tools\deploy-pc.ps1 -Unregister              # remove the registration
```

Once registered the game is launchable from the Start menu and the XBOX app, or
with `-Launch`, which resolves the registered package's AUMID and calls `wdapp launch`.
The script confirms registration, not sign-in, sandbox authorization or service reachability;
use the [Walkthroughs](../docs/walkthroughs.md) to observe those outcomes.

Godot binary resolution: `-GodotExe` → `$env:GODOT_BIN` → `$env:GODOT` →
`godot` / `godot4` on `PATH`.

## `deploy-console.ps1`: XBOX Series X|S

Uses the `Xbox Series X|S` preset. The export produces a loose layout in
`scarlett_build\`: executable, `.pck`, GDK/PlayFab DLLs, `gameos.xvd` and the
staged `MicrosoftGame.config`. `xbapp deploy` syncs that folder to the devkit
and registers the apps declared in the config it finds at the folder root.

```powershell
.\tools\deploy-console.ps1                                 # default console
.\tools\deploy-console.ps1 -ConsoleAddress 192.168.1.42
.\tools\deploy-console.ps1 -SkipExport -SyncExact -Launch
```

- **A Middleware console fork is required.** The `Xbox Series X|S` export
  platform is absent from a stock Godot, so the export fails immediately.
  Resolution order: `-ConsoleGodotExe` → `$env:GODOT_CONSOLE`. Set
  `GODOT_CONSOLE` to the console fork's `godot.windows.editor.x86_64.exe` so you
  do not have to pass the path each time.
- **Target console.** Omit `-ConsoleAddress` to use the default console set with
  `xbconnect`.
- **`-SyncExact`** passes `/S`, deleting files on the console that are absent
  from the local layout. Slower, but leaves nothing stale behind remotely.
- The script warns when the layout contains an `.exe` that
  `MicrosoftGame.config` does not declare, because `xbapp deploy` copies the
  whole folder. `-Clean` rebuilds the layout from scratch (and re-stages the
  ~330 MB `gameos.xvd`).

## `export.ps1`: export without deploying

```powershell
.\tools\export.ps1 -Target pc|console|both [-Configuration debug|release] [-Clean]
```

Note that `-Target pc` still registers, because that is what the preset's
`dev/register_loose` option does during export.

### The build stamp

Every export first writes `scripts/generated/build_info.gd` with the commit it is
building from, and the main menu renders it bottom-right beside the wire protocol
version:

```text
build 1439685d+  ·  protocol 1.1
```

A trailing `+` means the tree was dirty, so the build is not exactly the commit it
names. Both parts matter when comparing peers: incompatible RPC sets can otherwise connect
with an empty roster or misrouted traffic. The current Lobby compatibility check refuses a
missing/mismatched protocol before Party join; see
[protocol version](../docs/protocol.md#protocol-version) and `scripts\gameplay\nr_protocol.gd`.

The file is gitignored. It describes the build rather than the source, so committing
it would dirty the tree on every export and be wrong for every build but the last.
Nothing preloads it. A clone that has never exported shows `unexported`.

`-Import` forces a `godot --headless --import` pass first; it happens
automatically when `.godot\` is missing.

### Why the export is not headless

`export.ps1` runs Godot **without** `--headless`, so a Godot window flashes up
during the export. This is deliberate and must not be "optimized" away.

Godot bakes precompiled D3D12 shader blobs (`.d3d12xs.cache`) into the `.pck`
at export time, and that step only runs when a RenderingDevice exists. Under
`--headless` it is skipped silently. The export still reports success, and
nothing in the log mentions shaders. The only visible symptom is a `.pck` about
6 MB smaller (~7.9 MB instead of ~13.8 MB).

XBOX cannot compile shaders at runtime, so such a package is terminated by Game
Core during startup, before any GDScript runs:

```
Launch result:    0x0
Terminate result: 0x87E50006
Process exit:     -2147483648 (0x80000000)
```

with no title output, no crash dump, and no Windows error report. To check a
package quickly, compare `.pck` sizes, or confirm the shader cache is present:

```powershell
# should print a few hundred .d3d12xs.cache entries, not zero
python tools\pckdiff.py scarlett_build\NetRumbleConsole.pck
```

Both debug and release are affected; this is unrelated to build configuration.

## `common.ps1`

Shared helpers, dot-sourced by the others. Nothing in it builds anything. It
locates tooling and reads the two files that define what a NetRumble package is,
so no script hard-codes a name that lives in them:

- `export_presets.cfg` → preset names, export paths, options
- `MicrosoftGame.config` → package identity, executable names, AUMID suffixes

The GDK bin directory is resolved the same way the `godot_gdk_editortools`
addon does it: `$env:GDK_BIN` → `%GameDK%\bin` →
`C:\Program Files (x86)\Microsoft GDK\bin`.

---

## Repository checks

The repository text checks for contribution review live in
[Repository checks](repository-checks.md). CI runs them as required gates before changes can
merge.

---

## Related tooling

`addons\godot_gdk_editortools\gdkpkg.cmd` is a lower-level runner from the GDK
addon with verbs for `makepkg` packaging (`pack`, `genmap`, `validate`), package
installation (`install`, `uninstall`), and the sandbox (`sandbox`). Reach for it
when you need a real `.msixvc` rather than the loose-registration dev loop these
scripts drive.

```powershell
addons\godot_gdk_editortools\gdkpkg.cmd --help
```
