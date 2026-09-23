# Troubleshooting NetRumble

Use this page when NetRumble fails before the walkthrough explains what happened. Each entry is
keyed by the symptom you can see, then gives the documented cause and the shortest safe fix.
For terms such as Microsoft Game Development Kit (GDK), loose registration and HRESULT, see the
[glossary](glossary.md).

## Setting up and building the addons

### Could not find base class "GutTest"

**Symptom**: Godot reports `Could not find base class "GutTest"` while parsing the project.

**Cause**: The upstream addon submodule contains `tests_support/` scripts that extend the Godot
Unit Test addon. NetRumble does not install that testing plugin, so those scripts are deliberately
excluded from `addons/` during sync.

**Fix**: Rebuild or reinstall the generated addon output with `tools\sync_addons.ps1`. Do not
copy `tests_support/` into `addons/`; see
[Addon Maintenance](addon-maintenance.md#1-the-submodules-build-output).

### 0x87E50006 before any GDScript runs after addon changes

**Symptom**: A console package launches and terminates with `0x87E50006` before any GDScript runs.

**Cause**: If this starts after moving the addon pin or changing `.gdextension` overrides, the
console `[dependencies]` block may be broken. The package can fail before anything names the
extension.

**Fix**: Diff `tools\addon-overrides\` against the submodule manifests and fold in any upstream
library or dependency additions before exporting and launching again. See
[Moving the pin](addon-maintenance.md#moving-the-pin).

## Opening the project in Godot

### 0x89240102 at GDExtension load

**Symptom**: The process is killed with `0x89240102` at GDExtension load and no other diagnostic.

**Cause**: With `AdvancedUserModel=false`, the simplified XBOX user model requires valid
`TitleId` and `MSAAppId` elements in `MicrosoftGame.config`. Omitting either identifier causes
this load-time termination.

**Fix**: Keep the committed sample identifiers unchanged, or replace the full
configuration with values for an authorized title. See
[`AdvancedUserModel=false`](configuration.md#advancedusermodelfalse-simplified-user-model) and
the [configuration checklist](configuration.md#configuration-checklist).

## Exporting and deploying

### 0x87E50006 at startup

**Symptom**: Console launch reports success, then startup terminates with:

```text
Launch result:    0x0
Terminate result: 0x87E50006
Process exit:     -2147483648 (0x80000000)
```

There is no title output, crash dump or Windows error report.

**Cause**: A console export run with `--headless` skips D3D12 shader cache baking. The export can
still report success, but the `.pck` is about 6 MB smaller and XBOX cannot compile the missing
shaders at runtime.

**Fix**: Use `tools\export.ps1` or `tools\deploy-console.ps1`, which export without `--headless`.
Check the package with `python tools\pckdiff.py scarlett_build\NetRumbleConsole.pck`; see
[Never add `--headless` to a console export](configuration.md#never-add---headless-to-a-console-export)
and [Why the export is not headless](../tools/README.md#why-the-export-is-not-headless).

### Export preset 'XBOX on PC' is not defined in export_presets.cfg

**Symptom**: A PC export or deploy fails with `Export preset 'XBOX on PC' is not defined in
export_presets.cfg`.

**Cause**: A Middleware console fork only registers the `Xbox Series X|S` export platform. Saving
`export_presets.cfg` from that editor silently deletes the `XBOX on PC` preset.

**Fix**: Restore the `XBOX on PC` preset with the standard Godot editor or from the last known
good file. See [the console-fork editor trap][console-fork-editor-trap].

[console-fork-editor-trap]: configuration.md#export-traps

### No .exe is produced at the preset's export_path

**Symptom**: The `XBOX on PC` export succeeds, but no `.exe` appears at the preset's
`export_path`.

**Cause**: This is expected for the PC preset. `dev/register_loose=true` makes the GDK export
platform stage a loose package into `build\_gdk_staging` and register that folder with `wdapp
register`; the staging folder is the deliverable.

**Fix**: Use `tools\deploy-pc.ps1 -Launch` for the primary desktop loop, or inspect and register
`build\_gdk_staging` rather than the preset `export_path`. See
[`deploy-pc.ps1`: XBOX on PC](../tools/README.md#deploy-pcps1-xbox-on-pc) and
[Running with GDK identity](configuration.md#running-with-gdk-identity).

## Signing in

### E_INVALIDARG on interactive sign-in

**Symptom**: Interactive user add returns `E_INVALIDARG`, then the game reports that XBOX sign-in
did not complete and tells you to sign in to the XBOX app.

**Cause**: NetRumble uses the simplified XBOX user model. Under that model, the platform supplies
the launching user and rejects interactive adds; sign-in has to come from
`XBOX.users.add_default_user_async()`.

**Fix**: Sign in to the XBOX app with an authorized test account, set the machine to the sample's
sandbox, then launch the registered package again. See [Sign-in](platform-services.md#sign-in)
and [`AdvancedUserModel=false`](configuration.md#advancedusermodelfalse-simplified-user-model).

## Multiplayer and the two-instance local test

### AuthenticateLocalUser: invalid argument specified

**Symptom**: Joining a Party network fails with:

```text
AuthenticateLocalUser: invalid argument specified
```

**Cause**: `PartyNetwork::AuthenticateLocalUser` rejects a client whose invitation identifier is
different from the one the host used when creating the network. Leaving
`PlayFabPartyConfig.invitation_id` empty makes the addon generate an opaque value that the client
cannot know.

**Fix**: Use the five-character join code as the Party invitation identifier on both sides. The
project already does this in `PartyService`; see
[The join code is the Party invitation id](multiplayer.md#the-join-code-is-the-party-invitation-id).

### E_PF_PLAYER_CREATION_DISABLED / 0x892357BA

**Symptom**: Debug custom-ID authentication fails with `E_PF_PLAYER_CREATION_DISABLED`
(`0x892357BA`).

**Cause**: The committed production PlayFab title does not permit custom-ID account creation.
The debug custom-ID authentication diagnostic requires a separate development PlayFab title that enables
that flow.

**Fix**: For authentication diagnostics, pass `--pf-title=<dev-title-id>` with a `--pf-user` token, or set the matching
environment variables, against a development title you control. Do not change committed title or
package identifiers. Successful custom-ID authentication still cannot enter gameplay: it lacks
the signed-in XboxUser required by XGameSaveFiles. Use registered XBOX accounts with ready saves
for Practice and multiplayer, not custom-ID as a workaround. See
[Testing prerequisites](multiplayer.md#testing-two-players-on-one-pc),
[Debug custom-ID diagnostics](configuration.md#debug-custom-id-diagnostics) and
[manual test prerequisites](manual-test-plan.md#prerequisites).

### Signed in, but save loading fails

**Symptom**: Authentication succeeds but acquisition reports a save initialization, folder or
read error and gameplay remains unavailable.

**Cause**: An authenticated PlayFab user alone is not account/save readiness. PC and console
both require a signed-in XboxUser, initialized Xbox services with the correct SCID,
successful XGameSaveFiles folder synchronization and valid reads.
Unreadable slots, invalid current-schema payloads or damage with no intact slot are errors,
not an empty account. Each logical save has a named file and an `.alt` integrity slot;
an incomplete candidate can be ignored when the other slot is intact. Both slots absent
means a new save. Do not manually replace either slot with bare JSON.

**Action**: Record the failed stage/reason and inspect registration, account/title access and
the platform sync result. After resolving the cause, choose **Retry** to reload the store;
**Back** abandons the attempt without enabling play. Do not overwrite existing saves with
defaults or copy shared/token files into the folder. Only current-format root-level PC saves
are copied into the new `NetRumble` subdirectory; historical/shared/token files are left untouched.
A custom-ID user cannot resolve this by retrying
authentication alone. See [Game Saves](platform-services.md#game-saves).

`GameSaveService` calls `GDK.game_save.get_folder_async(xbox_user)` on both platforms.
It does not use PlayFab Game Saves or require that service's onboarding. For built-in cloud
sync failures, verify the configured title/sandbox/SCID and Partner Center **Connected Storage**
setting, not PlayFab save enrollment. Microsoft's
[debugging guidance](https://learn.microsoft.com/gaming/gdk/docs/features/common/game-save/game-saves-debugging)
describes SCID/access failures including `0x80830002`; a sync dialog alone does not prove the cause.

Capture `[SavePrepare]` entry, the `GDK.game_save.get_folder_async` calling/returned/completed
lines, folder access result and exit status. Completion logs retain recognized addon error
codes and numeric HRESULTs without account identifiers, raw paths, payloads or native messages.
The game no longer opens the SDK root as a working directory. It creates a single `NetRumble`
child and uses absolute file paths. A folder failure includes `stage=create-directory` or
`stage=read`, Godot's numeric `error` and description, and a `directory_exists` check.
Record those fields when console logs are unavailable. `directory_exists=false` can mean a
missing directory or a failed attribute query, not permission to load defaults. These fields
do not expose the SDK path and are not native Windows error codes. If the child-directory
approach still fails on console, native Win32 error capture is the next diagnostic step.
Re-export before testing: the previous `stage=prepare, open_error=31` diagnostic belongs to
the old working-directory check, not the corrected path.
`[SaveLoad]` then records each logical payload's load status. A returned call still awaiting its
Signal is not a completed sync. Retry repeats a failed folder operation; there is no AddUser
session-lifetime rule in this backend. Resume invalidates the cached provider and reloads.

If an explicit Options save fails, **Back** still returns to the main-menu or pause-menu
actions and shows **Could Not Save**. Dismiss the error to use Resume/Leave or other menu
actions; current settings remain in memory for a later explicit save. This is not an
account-load bypass, and unsaved values are not guaranteed to survive termination.

**Check the packaged build before interpreting missing diagnostics.** `deploy-pc.ps1 -Launch
-SkipExport` reuses staged scripts and binaries; it cannot include new source changes. After
coordinating deployment, re-export and register without launching:

```powershell
.\tools\deploy-pc.ps1 -Configuration release -GodotExe 'C:\path\to\Godot_console.exe'
```

This command changes the staged package and registration. Omit `-SkipExport`; add `-Launch`
only when the live run is authorized. Do not change title identifiers or clear cloud saves
to work around a synchronization error.

### Progress missing after Xbox Guide Quit

**Required flow**: Constrain -> Suspend -> Terminate, with synchronous saving on Suspend.
Do not use the desktop Quit dialog or a Constrain-only test as evidence for this path.

**Action**: Establish which setting, completed-history row or lifetime counter is missing,
then compare same-account/same-console state before and after Guide Quit. Capture suspend
entry, account/store readiness, individual write outcomes and handler exit.
No suspend entry suggests an engine/notification integration issue; entry without completion
needs callback-duration/order investigation; a failed payload needs storage/readiness
diagnosis. Do not solve those failures by moving saving to Constrain or adding a timer.

The log sequence starts with `[Lifecycle] Suspend entry`, contains `[SaveCommit]`
readiness fields and ordered payload results, and ends with `[Lifecycle] Suspend exit`.
Commit outcomes distinguish `success`, `no_ready_account` and
`failed_writes`. Both commit and handler exit report `elapsed_ms`; no fixed suspend deadline
is implied by those measurements. Keep the whole block when reporting a failure.

Suspend attempts all three current payloads without dirty flags. A prior failed appearance or
settings write is retried at the next explicit save boundary even if no further value changes.
Do not add a marking call or a change-detection workaround to make persistence run.

If local state reloads but another device is stale, inspect platform cloud synchronization.
Background upload cannot persist in-memory values the title never wrote. Run the
[Guide Quit cases](manual-test-plan.md#xbox-guide-quit-and-suspend-saves) with authorized test
accounts and retain old valid data; do not erase or manually alter cloud files.
