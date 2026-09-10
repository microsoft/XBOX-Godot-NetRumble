# Contributing

Thank you for your interest in NetRumble. This sample exists to show how Microsoft GDK and PlayFab
integrate into a Godot game, so the bar for a change is not only "does it work" but "does it still
teach clearly".

## Contributor License Agreement

Most contributions require you to agree to a Contributor License Agreement (CLA) declaring that you
have the right to, and actually do, grant us the rights to use your contribution. For details, visit
[https://cla.opensource.microsoft.com](https://cla.opensource.microsoft.com).

When you submit a pull request, a CLA bot will automatically determine whether you need to provide a
CLA and decorate the PR appropriately (e.g., status check, comment). Simply follow the instructions
provided by the bot. You will only need to do this once across all repositories using our CLA.

This project has adopted the [Microsoft Open Source Code of Conduct](CODE_OF_CONDUCT.md).

## What makes a good change here

This is a teaching sample, so clarity is a feature and is reviewed as one.

- **Explain the platform, not the decision.** A comment should tell a reader what the GDK or PlayFab
  API requires and what breaks if they get it wrong. Prefer "`AuthenticateLocalUser` rejects a client
  whose invitation identifier differs from the host's" over "we do it this way because it was easier".
- **Do not describe the sample by comparison to other implementations.** NetRumble is the reference
  for this integration and should stand on its own. `tools/check-deport.ps1` enforces this and runs
  in CI.
- **Keep the platform boundary visible.** A reader should be able to tell at a glance whether they
  are looking at GDK code, PlayFab code, or game logic.
- **Prefer a named constant over a magic number**, especially for values that mirror a platform enum.

## Before you open a pull request

1. **Run the repository text checks.**

   ```powershell
   .\tools\check-deport.ps1 -Detailed
   .\tools\check-game-config.ps1
   ```

   [Repository checks](tools/repository-checks.md) explains what each one enforces and how to
   read a failure.

2. **Import, then run the parse check.** Build missing addons using the
   [setup instructions](README.md#quickstart-registered-xbox-on-pc). A fresh checkout has no
   import cache; `--quit` alone would run against unimported resources.

   ```powershell
   godot.exe --headless --path . --import
   godot.exe --headless --path . --quit
   ```

   Both commands must exit 0. Inspect **both outputs** for `SCRIPT ERROR`, `Parse Error`,
   `Failed to load script` and `Cannot open file`; a zero exit code alone is insufficient.
   CI runs this sequence, currently as an advisory job, alongside the two required text checks.

3. **Run the tier of [Manual test plan](docs/manual-test-plan.md) that matches your
   change.** CI checks resource import/parse, not live services. Focused fake-SDK checks can
   cover title-side races but do not replace manual gameplay, networking, sign-in, voice/text
   or lifecycle evidence. The [Walkthroughs](docs/walkthroughs.md) explain how to demonstrate
   services; they are not test results.

   A change to `net_manager.gd`, `world.gd`, `party_service.gd` or `match_director.gd` needs a
   Tier 3 two-peer run. Tier 1 alone is not sufficient for those files. Chat changes also need
   [typed-text acceptance](docs/manual-test-plan.md#typed-text-acceptance). Use registered Xbox
   accounts for privilege/privacy coverage; custom-ID on a separate dev title covers only the
   development transport/UI path. Game Save roaming needs console devices, not a desktop relaunch.

   Record what actually ran, including unavailable hardware/accounts/services as skips or blockers.
   Preserve gameplay coverage under the manual plan's secondary regression section; do not
   replace it with a platform-only smoke run.

### One trap worth knowing

Godot routes RPCs **by node path**. Moving an `@rpc` method onto a different node or a child changes
routing and breaks the protocol between peers, and it fails *silently at runtime*, so neither the
parse gate nor a single-instance run will catch it. Every `@rpc` entry point belongs on the
`NetManager` autoload. If you need to shrink that file, move the method **body** into a helper and
leave the `@rpc` declaration where it is.

## Reporting bugs and requesting features

Please open an issue. For security vulnerabilities, follow [SECURITY.md](SECURITY.md) instead. Do
not open a public issue.

## Trademarks

This project may contain trademarks or logos for projects, products, or services. Authorized use of
Microsoft trademarks or logos is subject to and must follow
[Microsoft's Trademark & Brand Guidelines](https://www.microsoft.com/en-us/legal/intellectualproperty/trademarks/usage/general).
Use of Microsoft trademarks or logos in modified versions of this project must not cause confusion
or imply Microsoft sponsorship. Any use of third-party trademarks or logos is subject to those
third-party's policies.
