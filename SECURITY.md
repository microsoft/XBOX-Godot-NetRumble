# Security

Microsoft takes the security of our software products and services seriously, which includes all
source code repositories managed through our GitHub organizations, which include
[Microsoft](https://github.com/microsoft), [Azure](https://github.com/Azure),
[DotNet](https://github.com/dotnet), [AspNet](https://github.com/aspnet) and
[Xamarin](https://github.com/xamarin).

If you believe you have found a security vulnerability in any Microsoft-owned repository that meets
[Microsoft's definition of a security vulnerability](https://aka.ms/security.md/definition), please
report it to us as described below.

## Reporting security issues

**Please do not report security vulnerabilities through public GitHub issues.**

Instead, please report them to the Microsoft Security Response Center (MSRC) at
[https://msrc.microsoft.com/create-report](https://aka.ms/security.md/msrc/create-report).

If you prefer to submit without logging in, send email to
[secure@microsoft.com](mailto:secure@microsoft.com). If possible, encrypt your message with our PGP
key; please download it from the
[Microsoft Security Response Center PGP Key page](https://aka.ms/security.md/msrc/pgp).

You should receive a response within 24 hours. If for some reason you do not, please follow up via
email to ensure we received your original message. Additional information can be found at
[microsoft.com/msrc](https://msrc.microsoft.com).

Please include the requested information listed below (as much as you can provide) to help us better
understand the nature and scope of the possible issue:

  * Type of issue (e.g. buffer overflow, SQL injection, cross-site scripting, etc.)
  * Full paths of source file(s) related to the manifestation of the issue
  * The location of the affected source code (tag/branch/commit or direct URL)
  * Any special configuration required to reproduce the issue
  * Step-by-step instructions to reproduce the issue
  * Proof-of-concept or exploit code (if possible)
  * Impact of the issue, including how an attacker might exploit the issue

This information will help us triage your report more quickly.

If you are reporting for a bug bounty, more complete reports can contribute to a higher bounty
award. Please visit our [Microsoft Bug Bounty Program](https://aka.ms/security.md/msrc/bounty) page
for more details about our active programs.

## Preferred languages

We prefer all communications to be in English.

## Policy

Microsoft follows the principle of
[Coordinated Vulnerability Disclosure](https://aka.ms/security.md/cvd).

---

## A note on this sample

NetRumble is a learning sample. It demonstrates platform integration patterns, not a hardened
production security posture. In particular:

- The topology is host-authoritative, and the host is trusted. Clients validate the input they send
  and the host ignores client-claimed identity in favor of the transport's authenticated peer id,
  but a compromised host is outside the threat model.
- Developer overrides (`--pf-user`, `--pf-title`) exist for local testing and are refused on console
  and in release builds. If you reuse this code, keep that guard.

Do not treat the sample's choices as a substitute for a security review of your own title.
