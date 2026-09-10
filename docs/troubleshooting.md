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

**Symptom**: The two-instance custom-ID flow fails with `E_PF_PLAYER_CREATION_DISABLED`
(`0x892357BA`).

**Cause**: The committed production PlayFab title does not permit custom-ID account creation.
The debug custom-ID multiplayer path requires a separate development PlayFab title that enables
that flow.

**Fix**: Pass `--pf-title=<dev-title-id>` with distinct `--pf-user` values, or set the matching
environment variables, against a development title you control. Do not change committed title or
package identifiers. See
[Testing two players on one PC](multiplayer.md#testing-two-players-on-one-pc),
[Debug custom-ID multiplayer](configuration.md#debug-custom-id-multiplayer) and
[manual test prerequisites](manual-test-plan.md#prerequisites).
