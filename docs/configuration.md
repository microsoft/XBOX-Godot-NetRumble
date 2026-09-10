# Configuration: GDK, PlayFab and sandbox setup

The primary demonstration is an **exported, registered XBOX on PC build**. This page covers
its machine/account prerequisites, fixed sample configuration, secondary editor/custom-ID
paths and console export traps. For environment capabilities, use the
[README matrix](../README.md#what-works-where), not the presence of a loaded addon.

See also: [Architecture](architecture.md) · [Multiplayer](multiplayer.md) ·
[Platform Services](platform-services.md)

---

## Requirements

- **Godot 4.6 or later** (standard build; the GDK addons are GDExtensions; no custom engine
  build needed). Tested with 4.6.2. `project.godot` declares the `4.6` feature tag, so 4.6 is
  this project's floor; the bundled GDExtensions declare a `compatibility_minimum` of 4.5, which
  is a different and lower claim.
  Exporting to XBOX Series X|S additionally requires a Middleware console fork.
- **Windows**: the GDK/PlayFab addons load only on Windows. Sign-in, multiplayer and
  achievements additionally need registered package identity, the PC in the **XDKS.1**
  sandbox, authorized access to that title/sandbox and a corresponding XBOX test account
  signed in to the XBOX app.
- **Visual Studio 2022** with the vcpkg component, plus an installed **Microsoft GDK**, to build
  the addons. `addons/` is not committed; see [Addon maintenance](addon-maintenance.md).
- **Export support for the chosen Godot build** and GDK PC tooling (`wdapp`) on the deployment
  machine. The console path additionally requires a Middleware console fork and an authorized
  devkit.

---

## Before you start

Three things are provisioned separately, and each one gates the next. A gap at step 1 usually
surfaces later as a confusing failure at step 3, so it is worth walking them in order.

| Step | What you need | Where it comes from | What it unlocks |
| --- | --- | --- | --- |
| 1 | Microsoft GDK and Visual Studio 2022 | Installed on your own machine | Building `addons/`, package registration, deployment |
| 2 | A PlayFab title | A PlayFab account, a separate service with its own sign-in | Lobby, matchmaking and achievement plumbing |
| 3 | An XBOX title and sandbox authorization | Partner Center, through ID@XBOX or an existing publishing agreement | XBOX sign-in, friends, invites, XDKS.1 access |

Steps 1 and 2 you can complete yourself today. Step 3 you cannot: it rests on a commercial
relationship with XBOX, and cloning this repository does not grant one. See
[what works without the full set](#what-works-without-the-full-set) before planning around it.

### 1. Install the Microsoft GDK

The GDK is a standalone SDK download. It does not ship with Godot, and it is not what `addons/`
contains: `addons/` holds GDExtension wrappers that are compiled *against* the GDK, which is why
building them needs it present locally.

1. Install **Visual Studio 2022** with the native desktop development workload and the
   **vcpkg** component.
2. Install the GDK from [aka.ms/gdkdl](https://aka.ms/gdkdl), or take a specific version from
   [github.com/microsoft/GDK/releases](https://github.com/microsoft/GDK/releases). Install it
   after Visual Studio so its build integration registers.
3. Open a *new* terminal and confirm the result:

   ```powershell
   $env:GameDK
   wdapp /?
   ```

   The first should print an install path and the second should resolve. If either fails, the
   GDK is not installed or the terminal predates the install.

Reference material: [Microsoft GDK on Learn](https://learn.microsoft.com/en-us/gaming/gdk/).

### 2. Get a PlayFab account and title

PlayFab is a separate hosted backend with its own portal, account and title identifiers. An XBOX
or Partner Center account does not create one for you, and a PlayFab title id is a different
thing from an XBOX title id.

Work through the
[Game Manager quickstart](https://learn.microsoft.com/en-us/xbox/playfab/live-service-management/gamemanager/quickstart)
to create a studio and a title. Background reading:
[PlayFab documentation](https://learn.microsoft.com/en-us/gaming/playfab/).

You do **not** need your own title for the primary XBOX path; the committed sample title serves
it. You need one for the custom-ID path below, and for any game of your own.

### 3. Get XBOX title and sandbox access

The XBOX half (sign-in, friends, invites and achievements against the live service) needs a
title provisioned in Partner Center and your machine authorized for its sandbox. This sample
runs in **XDKS.1**, a shared sample sandbox whose access you must already hold. With no XBOX
publishing relationship yet, start at [ID@XBOX](https://www.xbox.com/en-US/developers/id). For
the switch itself, see [Set the sandbox to XDKS.1](#set-the-sandbox-to-xdks1).

### A development PlayFab title for custom-ID testing

The [debug custom-ID path](#debug-custom-id-multiplayer) signs in two local instances without
XBOX. The committed sample title refuses it and returns `0x892357BA`
(`E_PF_PLAYER_CREATION_DISABLED`), because client-side account creation is disabled there. A
title you own can permit it.

1. Create a second title in Game Manager, kept separate from anything you ship.
2. In that title's **Settings → API Features**, enable the option that lets clients create
   player accounts. This is what `LoginWithCustomID` needs when it creates a player on first
   use. See
   [anonymous login](https://learn.microsoft.com/en-us/xbox/playfab/identity/player-identity/platform-specific-authentication/anonymous-login)
   for what that flow is and what it trades away.
3. Pass the title id at launch, without editing any committed file:

   ```powershell
   godot.exe --path . -- --pf-title=<dev-title-id> --pf-user=alice
   ```

Keep this title out of your shipping path. It exists so two windows on one desk can reach the
same lobby, and it deliberately relaxes an account-creation control to do that.

### Running the PowerShell scripts

The `tools/` scripts are unsigned `.ps1` files. A default Windows configuration refuses to run
them, and copies extracted from a downloaded zip carry a mark-of-the-web block on top of that.
Either start a session that permits them:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\deploy-pc.ps1 -Launch
```

or clear both conditions once for this working copy:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
Get-ChildItem .\tools\*.ps1 | Unblock-File
```

`-Scope Process` lasts only for that terminal, which is the smaller change of the two. Clone
with `git` instead of downloading a zip, and the `Unblock-File` step is unnecessary.

### What works without the full set

| You have | You can run |
| --- | --- |
| Godot only, addons not built | Editor exploration and **Continue Offline** practice mode |
| Steps 1 and 2 | The above, plus the two-instance custom-ID lobby on your own development title |
| Steps 1, 2 and 3 | The full demonstration: XBOX sign-in, friends, invites, achievements |

Achievement definitions must match the service side. The ten ids this sample reports, and the
conditions that unlock them, are listed in
[Platform services](platform-services.md#achievements).

---

## Running

First verify the [sandbox/account setup](#set-the-sandbox-to-xdks1). The repository does not
grant service access, and registration does not create a sandbox test account.
From a clone with submodules initialized, build the addons and launch a registered package:

```powershell
.\tools\sync_addons.ps1
.\tools\deploy-pc.ps1 -Launch
```

`sync_addons.ps1` also initializes a missing submodule checkout. The deploy script exports,
verifies registration and launches the registered AUMID. Check the acquire-user screen's stage
and outcome, then follow the [Walkthroughs](walkthroughs.md). Keep the committed title/package
identifiers unchanged.

### Editor and offline exploration

After addon setup, open the folder in Godot and press F5, or run:

```powershell
godot.exe --path .
```

Choose **Continue Offline** for Practice. GDK initialization may succeed here, but F5/direct
project launch is not a registered process and does not demonstrate XBOX sign-in or invites.
No online session is offered without a PlayFab identity.

### Debug custom-ID multiplayer

Use the [two-instance instructions](multiplayer.md#testing-two-players-on-one-pc) with distinct
`--pf-user` tokens and `--pf-title=<dev-title-id>` (or `PF_CUSTOM_ID` / `PF_TITLE_ID`).
This requires a **separate development PlayFab title** permitting custom-ID creation; the
committed sample title does not. Overrides affect runtime settings in debug desktop/editor
builds only, never console or exported release builds. Do not edit committed identifiers to
enable this path.

This is Party/Lobby/UI development coverage, **not XBOX policy coverage**: XBOX sign-in,
privilege/privacy checks and string verification are bypassed, and XBOX friends/invites,
achievement reporting and Game Save roaming are unavailable. Desktop caches remain local.

---

## Running with GDK identity

`MicrosoftGame.config` is committed at the project root, the location the GDK addon and its
samples expect, so the GDK initializes when you press F5 or run `godot.exe --path .`.

Sign-in additionally needs a **registered** build, which means exporting, and the PC in the
**XDKS.1** sandbox; see [Set the sandbox to XDKS.1](#set-the-sandbox-to-xdks1). Both presets are
committed in `export_presets.cfg` (`XBOX on PC` and `Xbox Series X|S`), and `tools/` wraps the
export and deployment steps for each:

```powershell
# PC: export, then `wdapp register` the loose package so it has an identity.
.\tools\deploy-pc.ps1 -Launch

# Console: export, then `xbapp deploy` the layout to the devkit.
.\tools\deploy-console.ps1 -ConsoleAddress 192.168.1.42
```

Both take `-Configuration debug|release` (default `release`), `-Clean`, `-SkipExport`, and
`-Launch`. `.\tools\export.ps1 -Target both` omits a separate deployment step, but the PC
preset still registers during export because `dev/register_loose` is enabled. See
[tools/README.md](../tools/README.md) for the full set. The console preset needs a Middleware
console fork; point `$env:GODOT_CONSOLE` or `-ConsoleGodotExe` at it.

The underlying commands, if you prefer to drive them by hand:

```powershell
# Console: the preset's export path pins the executable name.
godot.exe --path . --export-release "Xbox Series X|S" scarlett_build\NetRumbleConsole.exe

# PC: the exe name comes from MicrosoftGame.config, not from this path.
godot.exe --path . --export-release "XBOX on PC" build\NetRumblePC.exe
```

The PC preset sets `dev/register_loose`, so it skips MSIXVC packaging and instead runs
`wdapp register` on `build\_gdk_staging`; that staging folder, not the `export_path`, is the
deliverable. Export also stages the config and the `storelogos/` tiles next to the `.exe`.
`deploy-pc.ps1` checks `wdapp list`, registers explicitly if needed, and uses `wdapp launch`
with the resolved AUMID for `-Launch`. Running a loose executable directly is not this launch path.

---

## Export traps

### Never add `--headless` to a console export

Godot bakes the precompiled D3D12 shader blobs into the `.pck` at export time, and that step only
runs when a `RenderingDevice` exists. Under `--headless` the step is skipped silently; the export
reports success, but the `.pck` comes out approximately 6 MB smaller, and the title is terminated
at startup by Game Core with exit code `0x87E50006` (process exit `0x80000000`) with no output,
no crash dump and no error report.

Verify the shader cache made it in:

```powershell
python tools\pckdiff.py scarlett_build\NetRumbleConsole.pck
```

### Close the console-fork editor before touching `export_presets.cfg`

A Middleware console fork only registers the `Xbox Series X|S` platform. Saving
`export_presets.cfg` from that editor silently deletes the `XBOX on PC` preset.

Check `git diff export_presets.cfg` if a PC export suddenly reports an undefined preset.

### Discard the `config/features` downgrade after a console export

A Middleware console fork is built on Godot 4.5.x, so any export it runs rewrites
`project.godot` with `config/features=PackedStringArray("4.5", ...)`, dropping this
project's 4.6 floor. The same pass also reorders the `[input]` actions and drops
`playfab/runtime/initialize_on_startup=false` (that is the addon's registered default,
so the omission is harmless).

Inspect `git diff -- project.godot` after a console export. Remove only the unintended
exporter edits, preserving existing worktree changes; do not reset the entire file.

---

## `MicrosoftGame.config` explained

Two fields are easy to mis-configure, and both fail in ways that do not name the field:

### `AdvancedUserModel=false` (simplified user model)

This is the simplified user model, which the platform recommends for most titles. The advanced
model is for titles that let the signed-in user change mid-session without a restart; this title
closes instead (XR-115), so it gains nothing from the advanced model.

**The simplified model requires valid `TitleId` and `MSAAppId` elements.** Omit either and the
process is killed with `0x89240102` at GDExtension load with no other diagnostic.

One code consequence: the simplified model supplies the launching user and rejects interactive
adds with `E_INVALIDARG`. Sign-in must come from `XBOX.users.add_default_user_async()`.
`IdentityService`'s interactive fallback is unavailable under this model.

### `Executable` entries

The two `Executable` entries must match the exported `.exe` names: `NetRumblePC.exe` (`PC`) and
`NetRumbleConsole.exe` (`Scarlett`). Having two entries means no hand-editing between a PC and a
console export.

**The PC entry must stay first.** The GDK "XBOX on PC" export platform derives the staged
executable name by regex-searching the raw file text for the first `Executable` element's `Name`
attribute, and that search is not XML-aware; it reads comments too. Consequences:

- The PC entry must be first in `ExecutableList`.
- Never write an `Executable` start-tag with a `Name` attribute inside a comment in this file:
  the regex will pick it up as the executable name.

---

## PlayFab and GDK initialization settings

Two `project.godot` settings look similar and mean opposite things:

```ini
[playfab]
runtime/initialize_on_startup = false   ; must stay false

[gdk]
runtime/initialize_on_startup = true    ; correct
```

**`[playfab] runtime/initialize_on_startup=false`**: must stay `false`.
`IdentityService._ensure_playfab()` applies the `--pf-title` command-line override *before*
calling `PlayFab.initialize()`, because the title id is read from `ProjectSettings` at init time.
If PlayFab self-initialized at startup the override would arrive too late. The title owns the
moment of initialization.

**`[gdk] runtime/initialize_on_startup=true`**: correct. The GDK has no equivalent pre-init
override, so self-initialization is fine.

---

## Lobby search properties

The join code is written to `string_key1` and the game mode to `string_key2`; the Party
descriptor lives in the lobby's (non-searchable) `party_descriptor` property. No title-side setup
is needed for these properties. `string_key3` additionally carries the sample protocol version.
PlayFab's lobby search index is **eventually consistent** and `FindLobbies` is rate-limited.
`PartyService._find_lobby_connection_string()` performs a **single lookup**; failure leaves
the code editable for an explicit retry. The code-join operation times out after 45 seconds.
See [connection flows](multiplayer.md#connection-flows). No Matchmaking queue/ticket setup is used.

---

## Configuration checklist
The registered sample uses the committed configuration below; **do not change these values**
for the demonstration. XBOX authentication and achievement definitions must agree with the
sample's provisioned services. The debug custom-ID path is the deliberate exception: it uses a
runtime override for a separate development PlayFab title, not a replacement package identity.

| Setting | File | Value |
|---|---|---|
| PlayFab title id | `project.godot`, `[playfab]` → `runtime/title_id` | `1A9AB9` |
| Package identity name | `MicrosoftGame.config`, `Identity/@Name` | `41336MicrosoftATG.NetRumble2` |
| XBOX services title id | `MicrosoftGame.config`, `<TitleId>` | `76B1590E` |
| MSA app id | `MicrosoftGame.config`, `<MSAAppId>` | `0000000044264AE3` |
| Store id | `MicrosoftGame.config`, `<StoreId>` | `9PN64QJC8BKL` |

> The **XBOX services** `TitleId` and the **PlayFab** title id (`runtime/title_id`) are separate
> identifiers for separate services. Do not conflate them.

> There is **no** title identifier in `export_presets.cfg`.

### Set the sandbox to XDKS.1

The title is provisioned in the **XDKS.1** development sandbox, and
XBOX test accounts only authenticate against the sandbox they were created in, so the machine
must be in the same sandbox or sign-in fails. Obtain authorized sample title/sandbox access and
an appropriate test account first. Two registered players need distinct XBOX accounts on separate
machines (or PC/console); a second process on one PC does not supply a second XBOX identity.

**On PC**, use [`XblPCSandbox.exe`][pc-sandbox], the GDK's PC sandbox switcher. Open **Microsoft
GDK Command Prompts** from the Start menu (pick the newest GDK version) and run:

```cmd
XblPCSandbox /get
XblPCSandbox /set XDKS.1
```

Run `/set` only with the machine owner's authorization; it needs **administrator privileges**
and is **machine-wide**. It restarts the XBOX Live
Auth Manager and affects every signed-in user on the PC, not just this project. `/get` does not.
Record the previous sandbox before changing it and restore that value when finished;
`XblPCSandbox /retail` is appropriate only if the prior state was retail.
After setup, sign in to the XBOX app with the sandbox test account before registered launch.

**On a devkit**, use [`xbconfig`][sandboxes] from the same GDK command prompt, then reboot:

```cmd
xbconfig sandboxid
xbconfig sandboxid=XDKS.1
xbreboot
```

Sandbox ids are case-sensitive.
The repository's scripts do not provision accounts/services or prove those services are reachable.
Treat unavailable title access, accounts or hardware as blocked walkthroughs, not successful setup.

[pc-sandbox]: https://learn.microsoft.com/en-us/gaming/gdk/docs/tools/tools-services/live-pc-sandbox-switcher
[sandboxes]: https://learn.microsoft.com/en-us/gaming/gdk/docs/services/fundamentals/sandboxes/live-setting-up-sandboxes

### Store tiles

Store tiles live in `storelogos/` (carrying a `.gdignore` so Godot doesn't import them as game
textures).
