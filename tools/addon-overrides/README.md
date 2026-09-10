# `.gdextension` overrides

`tools\sync_addons.ps1` installs `addons\` from the
`external\xbox-godot-sample` submodule, then copies everything in this
directory over the result. Files here win over upstream's.

Only the two GDExtension manifests are overridden.

## Why they differ from upstream

Upstream's manifests declare Windows libraries only. NetRumble also exports to
XBOX Series X|S, which a Middleware console fork of Godot exposes as the
`scarlett` platform. Two additions are needed for that export:

- **`scarlett.debug.x86_64` / `scarlett.release.x86_64` library entries.**
  They point at the same DLLs as the Windows entries (Game Core is Windows),
  but without them the console export finds no library for its platform and the
  extension never loads.

- **A `[dependencies] scarlett.x86_64` block.** Godot copies the files named
  here into the exported package. Only the GDK/PlayFab redistributables the
  console needs are listed, including the two GRDK-flavored DLLs
  (`libHttpClient.GDK.dll`, `Microsoft.Xbox.Services.GDK.C.Thunks.dll`) that
  `sync_addons.ps1` takes from an installed Microsoft GDK edition rather than
  from the addon build.

Neither addition has a desktop effect, so a mistake here shows up only on
console, as a package that launches and terminates with `0x87E50006` before any
GDScript runs, with no message naming the extension. That is the reason these
files are kept under version control here instead of being edited in `addons\`,
which is gitignored build output that every sync overwrites.

## The `.uid` files

Godot assigns each `.gdextension` a UID on first import. Pinning them here keeps
that identity stable across syncs. The addon `.gd.uid` files are deliberately
*not* pinned: nothing in the project references addon scripts by UID, so letting
the editor regenerate them costs nothing.

## Changing an override

Edit the file here, then reinstall without a rebuild:

```powershell
.\tools\sync_addons.ps1 -SkipBuild
```

## `.gdignore`

This directory holds a second copy of two `.gdextension` manifests, UIDs and
all. Without `.gdignore` the editor indexes them, reports a duplicate UID
against the real copy under `addons\`, and tries to load them as extensions in
their own right. `.gdignore` keeps the directory out of the resource
filesystem; `sync_addons.ps1` reads it from disk and does not care.
