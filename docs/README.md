# XBOX Godot NetRumble documentation

Welcome to the documentation for [XBOX Godot NetRumble](../README.md), a complete multiplayer
XBOX game built in Godot 4 that wires every Microsoft **GDK** and **PlayFab** service into the
place a shipping title would really call it.

These pages assume a Godot developer rather than an XBOX developer. If a term is unfamiliar,
the [glossary](glossary.md) defines every XBOX, GDK and PlayFab term used here, one line each.

Pages that open with *"You do not need this page to run or learn from the sample"* are
contributor references. You can read the integration without them.

## Folder structure

```
docs/
├── README.md                  this index
├── configuration.md           registered-PC setup, sandbox and accounts, alternate run paths
├── walkthroughs.md            prerequisites, player action, API, observable outcome
├── architecture.md            platform ownership, identities, saves, lifecycle, connectivity
├── multiplayer.md             Lobby discovery, Party connect and leave, voice and typed text
├── platform-services.md       sign-in, privileges, privacy, moderation, achievements, saves
├── xr-compliance.md           each XBOX Requirement the sample has code for
├── manual-test-plan.md        integration acceptance and gameplay regression
├── addon-maintenance.md       building addons/ from the submodule and moving the pin
├── troubleshooting.md         symptom, documented cause, shortest safe fix
├── known-issues.md            the bugs we already know about, and which platform each affects
├── glossary.md                every XBOX, GDK and PlayFab term used in these pages
├── gameplay-reference.md      simulation, physics, tuning and presentation
├── protocol.md                RPCs, snapshots and reconciliation
├── achievements2017.xml       achievement definitions for the sample title
├── localization.xml           localized achievement and presence strings
└── images/                    banners and screenshots used by these pages
```

## Start here

- [**Configuration**](configuration.md): machine and account prerequisites for the primary
  demonstration (an exported, registered XBOX on PC build), the fixed sample title
  configuration, the secondary editor and custom-ID paths, and console export traps
- [**Walkthroughs**](walkthroughs.md): prerequisites, player action, API and observable
  outcome for each platform demonstration, including what failure looks like. These are
  instructions and expected observations, not recorded test results

## Platform integration

- [**Architecture**](architecture.md): the platform boundary, where `Services` owns the
  wrappers and `NetManager` consumes them, plus identities, saves, process lifecycle and
  connectivity detection
- [**Multiplayer**](multiplayer.md): PlayFab Lobby discovery, PlayFab Party as a drop-in
  Godot `MultiplayerPeer`, connection flows, voice chat and the four-message typed text
  display, and XBOX multiplayer activity for friends and invites
- [**Platform services**](platform-services.md): GDK sign-in and the exchange for a PlayFab
  identity, privileges, privacy enforcement, string verification and reporting, achievements
  and console Game Save
- [**XBOX Requirements**](xr-compliance.md): each XR the sample has code for and where that
  code is, so you can find the equivalent call site for your own title

## Building and testing

- [**Manual test plan**](manual-test-plan.md): the acceptance gate for changes to the
  multiplayer core, covering integration acceptance and secondary gameplay regression.
  Record actual results; this repository has no automated test suite for gameplay or netcode
- [**Addon maintenance**](addon-maintenance.md): `addons/` is build output, so this covers
  building it from the `external/xbox-godot-sample` submodule, moving the pin, and the
  project's `.gdextension` overrides
- [**Repository checks**](../tools/repository-checks.md): the two CI text gates, what each
  one enforces and how to run them locally before pushing

## When something goes wrong

- [**Troubleshooting**](troubleshooting.md): keyed by the symptom you can see, then the
  documented cause and the shortest safe fix
- [**Known issues**](known-issues.md): a hand-picked summary of the bugs we already know
  about, and which platform each one affects. Check it before filing a bug
- [**Glossary**](glossary.md): every XBOX, GDK and PlayFab term these pages use, defined in
  one line each

## Secondary maintainer references

Neither page is a prerequisite for demonstrating the platform integration.

- [**Gameplay reference**](gameplay-reference.md): simulation, physics, tuning and
  presentation for the 2D top-down arena that supplies the traffic and match events
- [**Protocol**](protocol.md): the wire format, RPC routing, snapshots and reconciliation,
  for contributors changing payload compatibility

## Service configuration files

These are the sample title's service definitions, kept alongside the docs for reference. They
describe configuration that lives in Partner Center, and editing them here does not change a
live title.

- `achievements2017.xml`: the achievement definitions, including gamerscore rewards and
  display order. See [achievements](platform-services.md#achievements)
- `localization.xml`: the localized achievement names, locked and unlocked descriptions, and
  the rich presence strings

## Contributing

See [CONTRIBUTING.md](../CONTRIBUTING.md) for how to propose a change, [SECURITY.md](../SECURITY.md)
for security issues and [SUPPORT.md](../SUPPORT.md) for getting help.
