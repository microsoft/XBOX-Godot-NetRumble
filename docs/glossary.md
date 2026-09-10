# Glossary of GDK, PlayFab and XBOX terms

The other pages assume a Godot developer, not an XBOX developer. This page defines every XBOX,
GDK and PlayFab term they use, one line each, so you can read them without stopping to search.

You do not need to read this page front to back. Skim it once, then come back to it.

## Start here: the three products

| Term | Meaning |
|---|---|
| **Microsoft Game Development Kit (GDK)** | Microsoft's SDK for building games that run on XBOX consoles and on Windows. It provides sign-in, privileges, achievements, saves and packaging, and it installs the command-line tools this repository's scripts call. It is a separate download and install; it is not part of Godot. |
| **PlayFab** | Microsoft's hosted game backend, used here for identity, session discovery (Lobby), networking and voice (Party), and cloud saves. It is a separate service with its own account and its own titles, reached over the network rather than installed. |
| **XBOX services** | The online layer behind an XBOX account: gamertags, friends, privileges, privacy, achievements and presence. The GDK is how a title talks to it. |

## Certification and requirements

| Term | Meaning |
|---|---|
| **XBOX Requirement (XR)** | One of the certification rules a title must satisfy before it can ship on XBOX. Each has a number, such as XR-045. [XBOX Requirements](xr-compliance.md) maps each one to the code that addresses it. |
| **certification** | Microsoft's pre-release review of a title against the XRs. Nothing in this sample has been cert-tested. |
| **UGC** | User-generated content: anything a player authors that another player can see, such as a display name or a typed message. XR-018 governs it. |
| **SKU** | A distinct shippable variant of a title, for example an XBOX One build separate from an XBOX Series X\|S build. This sample ships one SKU. |
| **Smart Delivery** | The XBOX feature that gives a console the build made for its generation. It only applies to a title with more than one console SKU. |

## Accounts, identity and privacy

| Term | Meaning |
|---|---|
| **Microsoft account (MSA)** | The consumer account a player signs in with. An XBOX account is an MSA with XBOX services attached. |
| **`MSAAppId`** | The identifier registered for the title's Microsoft account application, declared in `MicrosoftGame.config`. It pairs with `TitleId` to identify the title at sign-in. |
| **XUID** | XBOX User ID: the stable numeric identifier for an XBOX account. The sample exchanges it for a PlayFab identity. |
| **gamertag** | The player-visible display name on the XBOX network. |
| **privilege** | A per-account permission granted by XBOX services, such as "may play multiplayer" or "may communicate with others". A title must check these rather than assume them. |
| **mute list / avoid list** | Per-account privacy lists. A muted player's voice is suppressed for you; an avoided player is one the platform keeps you apart from. Both are the platform's decision, not the title's. |
| **Guide** | The XBOX system overlay, opened with the XBOX button. Invites and profile cards are raised from it. |
| **PlayFab entity** | PlayFab's addressable identity object, identified by an entity id and an entity type. Roster and chat code resolves entity ids back to display names. |
| **Custom ID** | A PlayFab login that authenticates against a developer-supplied string instead of an XBOX account. It is the debug-only path this repository uses to run two clients on one PC, and it bypasses every XBOX check. |

## Multiplayer and communication

| Term | Meaning |
|---|---|
| **PlayFab Lobby** | The PlayFab service used here to discover a session and carry the information needed to join it. This sample uses Lobby discovery, not PlayFab Matchmaking. |
| **PlayFab Party** | The PlayFab service that provides the actual networking and voice transport. It is wrapped as a Godot `MultiplayerPeer`. |
| **Party descriptor** | The serialized handle to a Party network. A joining client reads it from the Lobby and passes it to Party to connect. |
| **chat control** | A Party object representing one player's voice and text endpoint. Each participant needs one before audio or text can flow. |
| **join code** | The short human-typed code this sample uses to find a Lobby. The UI labels it Lobby Code. |
| **XBOX multiplayer activity** | The record the title publishes so its session is joinable from the Guide and from a friend's profile. |
| **protocol activation** | Launching or waking the title through a URI, which is how accepting an invite from the Guide reaches the game. |
| **MPSD** | Multiplayer Session Directory, the XBOX service that can hold multiplayer session state. This sample does not use it; PlayFab Lobby and Party own session state instead. |

## Packaging, identity on disk, and the console

| Term | Meaning |
|---|---|
| **`MicrosoftGame.config`** | The GDK manifest at the repository root declaring package identity, the executables, the XBOX services identifiers and the Store identity. A malformed file disables every platform service at runtime without an obvious error. |
| **package identity** | The Windows-level identity an installed app has, which XBOX sign-in requires. Running the project from the Godot editor does not give it package identity. |
| **loose registration** | Registering an exported build directory with Windows so it gains package identity without being packed into an installer. It is the fast development loop; `dev/register_loose` on the PC preset turns it on. |
| **registered build** | An export that has been through loose registration or installation, so Windows knows it as an app. XBOX sign-in needs one. |
| **MSIXVC** | The packaged container format a GDK title ships in on PC. The loose-registration development loop skips producing one. |
| **XVD** | XBOX Virtual Disk, the console-side container format. `gameos.xvd` is the console OS image included in a console package. |
| **AUMID** | Application User Model ID, the Windows identifier for an installed app's entry point. `wdapp launch <AUMID>` starts a registered build by it. |
| **Game Core** | The operating system and runtime the GDK targets, on both XBOX consoles and Windows. |
| **Scarlett** | The platform name for the XBOX Series X\|S generation. It appears in export paths and build directory names. |
| **devkit** | An XBOX console licensed and configured for development. Console deployment requires one; it is not something a retail console can be turned into. |
| **sandbox** | An isolated XBOX services environment, so development traffic never touches retail data. This sample uses the shared **XDKS.1** sandbox. Switching sandboxes is machine-wide and requires administrator rights. |
| **Partner Center** | Where a title's Store and XBOX services identifiers are provisioned, and where achievements are published. The values committed here already exist; pointing the sample at your own title means replacing them with yours. |
| **Store ID** | The Microsoft Store identifier for the product, in the `<StoreId>` element. |
| **`TitleId`** | The XBOX services identifier for the title, in the `<TitleId>` element. It is not the same thing as the PlayFab title id. |

## GDK command-line tools

These ship with the GDK. The scripts in [`tools/`](../tools/README.md) call them for you.

| Tool | What it does |
|---|---|
| **`wdapp`** | Registers, lists and launches GDK apps on Windows. The PC deploy script uses it to register a loose build and start it. |
| **`xbapp`** | The console equivalent: deploys a build to a devkit and launches it. |
| **`xbconnect`** | Connects the development PC to a devkit. |
| **`makepkg`** | Builds a submission package from an export. |

## Godot and this repository

| Term | Meaning |
|---|---|
| **GDExtension** | Godot's native extension mechanism. The GDK and PlayFab addons are GDExtensions, which is why a standard Godot build can load them with no custom engine. |
| **`MultiplayerPeerExtension`** | The Godot base class for supplying a custom network transport. `PlayFabPartyPeer` derives from it, so ordinary Godot RPCs work unchanged over PlayFab Party. |
| **Middleware console fork** | A fork of Godot that can export to **XBOX Series X\|S**. Stock Godot has no such export platform. |
| **`XBOX` singleton** | The name this project gives the GDK addon's autoloaded singleton, set by `runtime/singleton_name` in `project.godot`. Code reaches it through `find_singleton()` rather than a hard-coded global. |
| **GUT** | Godot Unit Test, a third-party Godot testing addon. Scripts under `tests_support/` extend its `GutTest` base class. |
| **D3D12** | Direct3D 12, the graphics API the GDK targets. It is why the export step cannot run headless: the shader cache has to be built with a real device. |
| **`HRESULT`** | A 32-bit Windows result code. GDK and PlayFab calls return them, which is why failures in these docs appear as hexadecimal values such as `0x87E50006`. |
