# Addon maintenance

> **You do not need this page to run or learn from the sample**, beyond the one command in
> [Building the addons](#building-the-addons), which every fresh clone needs once.

---

## Where the addons come from

`addons/` is **build output**. It is gitignored, and `tools\sync_addons.ps1` is the only thing
that writes it. The source of truth is a submodule:

| Path | What it is |
|---|---|
| `external/xbox-godot-sample` | Pinned commit of [microsoft/XBOX-Godot-Sample](https://github.com/microsoft/XBOX-Godot-Sample) |
| `tools/addon-overrides/` | The project's `.gdextension` manifests: see [The project's `.gdextension` overrides](#3-the-projects-gdextension-overrides) |
| `addons/` | Generated. Never edit, never commit |

Three addons are installed. The submodule also builds `godot_gameinput` and the C# facades;
those are not installed, because the project does not enable them.

- `godot_gdk`: GDK runtime bindings (GDExtension)
- `godot_playfab`: PlayFab Lobby, Party and title-storage bindings (GDExtension)
- `godot_gdk_editortools`: editor tools (Microsoft GDK menu, GameConfigEditor integration)

## Building the addons

```powershell
.\tools\sync_addons.ps1
```

That checks the submodule out at its pinned commit, builds it, and installs the result. It needs:

- **Visual Studio 2022**: the submodule's CMake presets target the VS 2022 generator.
- **vcpkg**: the VS vcpkg component is enough. `VCPKG_ROOT` wins if it is set.
- **A Microsoft GDK edition**: for the console redistributables described below. The highest
  installed edition is used unless `-GdkVersion` names one.

The first run is slow: vcpkg restores the GDK and PlayFab SDKs from source. Later runs reuse the
submodule's CMake binary directories and are incremental.

Useful switches:

```powershell
.\tools\sync_addons.ps1 -SkipBuild                 # reinstall from the last build
.\tools\sync_addons.ps1 -Configuration Release     # release DLLs only
.\tools\sync_addons.ps1 -Clean                     # wipe the build dirs and reconfigure
.\tools\sync_addons.ps1 -IncludeDebugSymbols       # also install the ~150 MB PDBs
.\tools\sync_addons.ps1 -SkipSubmoduleUpdate       # test an unmerged upstream branch
```

`-?` prints the full help.

---

## What the script assembles

Each installed addon is three sources merged in order.

### 1. The submodule's build output

The CMake build drops the addon DLLs and every runtime dependency into the submodule's own
`addons/<addon>/bin/`. Everything in the addon tree is then copied here **except**:

| Excluded | Why |
|---|---|
| `src/`, `CMakeLists.txt` | Build-system files, not runtime files |
| `tests_support/` | Its scripts extend `GutTest`. Without the GUT plugin installed, every parse of the project reports `Could not find base class "GutTest"` |
| `*.pdb` | ~150 MB each and gitignored. `-IncludeDebugSymbols` keeps them |
| DLLs for an unselected configuration | A `-Configuration Release` run must not install a debug DLL left in the submodule by an earlier build of a different commit |

The install is a **replace, not a merge**. The destination is deleted first, so a file removed
upstream does not survive here for the engine to load.

### 2. The GRDK console redistributables

Two DLLs the XBOX Series X|S export needs are **not** produced by the addon build. They are the
Game Core flavors of libraries the desktop build ships in Win32 form, and they are copied from an
installed Microsoft GDK edition:

| File | Source under the GDK edition directory |
|---|---|
| `libHttpClient.GDK.dll` | `GRDK\ExtensionLibraries\Xbox.LibHttpClient\Redist\x64\` |
| `Microsoft.Xbox.Services.GDK.C.Thunks.dll` | `GRDK\ExtensionLibraries\Xbox.Services.API.C\Lib\x64\Release\` |

The Release thunks are correct for both configurations: the manifests name one file, and the debug
addon links release imports.

Because the edition floats to the highest installed by default, pass `-GdkVersion` when a build
has to be reproducible:

```powershell
.\tools\sync_addons.ps1 -GdkVersion 260400
```

### 3. The project's `.gdextension` overrides
Files in `tools/addon-overrides/` are copied over the installed addons last. Only the two
GDExtension manifests are overridden, because NetRumble's differ from upstream's: they add the
`scarlett.*` library entries and the `[dependencies] scarlett.x86_64` blocks that the console
export needs. See [`tools/addon-overrides/README.md`](../tools/addon-overrides/README.md) for
details; **never** hand-edit the copies under `addons/`, which the next sync overwrites.

---

## Moving the pin

```powershell
cd external\xbox-godot-sample
git fetch origin
git checkout <sha-or-tag>
cd ..\..
.\tools\sync_addons.ps1
git add external/xbox-godot-sample
```

Then verify before committing:

1. Open the project in Godot. No parse errors, and the **Microsoft GDK** editor menu is present.
2. Diff `tools/addon-overrides/` against the submodule's manifests. If upstream added a library
   or dependency entry, fold it into the override. The override wins wholesale, so an upstream
   addition is otherwise silently dropped.
3. Export and launch on console if the change touches `godot_gdk` or `godot_playfab`. A broken
   `[dependencies]` block produces a package that terminates with `0x87E50006` before any
   GDScript runs, with nothing naming the extension.

Commit the submodule pin (`external/xbox-godot-sample`) together with any override change. There
is no other record of which upstream commit `addons/` was built from.

---

## The `GODOTCPP_TARGET` cache-variable trap

`GODOTCPP_TARGET` is a CMake **cache variable** that defaults to `template_debug`. It is not tied
to the CMake `--config` flag, so a plain `cmake --build ... --config Release` links the debug
godot-cpp into a release library. The mis-linked library loads without error and then corrupts
the heap when a release build of the engine uses it.

The submodule's `tools\build_addons.ps1` avoids this by giving Debug and Release separate
configure presets and binary directories, and `sync_addons.ps1` only selects the configuration.
Building the addons by hand is where the trap bites. The quickest way to spot the mistake:

| Build | Expected size of `godot_gdk` release `.dll` |
|---|---|
| Correct (`template_release`) | ~2.6 MB |
| Mis-linked (`template_debug` + Release config) | ~4.7 MB |

Both configurations are installed by default because the `.gdextension` manifests name both
library paths: the editor loads the debug DLL, the release export loads the release one.

---

## `Xbox*` class prefix and the `XBOX` singleton

Every script-visible addon class is prefixed `Xbox` (`XboxUser`, `XboxResult`,
`XboxAccessibility`, …). The engine singleton is registered under the name from
`gdk/runtime/singleton_name`, which this project sets to **`XBOX`**.

This rename is not cosmetic on console. A Middleware console fork for XBOX Series X|S registers
its own built-in `GDK` singleton plus `GDK`, `GDKAchievement`, `GDKError`, `GDKPackage`,
`GDKSave`, `GDKUI`, and `GDKUser` classes. Under the default addon names those collide with the
engine's built-in classes. Under `Xbox*` names the two coexist.

Services resolve the singleton through `XboxBootstrap.find_singleton()` rather than a hard-coded
global, so the name remains a project setting.
