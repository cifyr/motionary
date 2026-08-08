# Security

## Scope

Motionary is a personal, source-available project. It has no server, no accounts
and no telemetry. Builds are installed to your own device by you.

It does make one network request: the icon picker in Motionary Studio queries the
public [Iconify](https://iconify.design) API to search and download icon SVGs.
Icons are rasterised locally and cached in the app group, so the **widget
extension never makes a network request**.

## Reporting a vulnerability

Open a GitHub security advisory on this repository, or a normal issue if the
problem is not sensitive.

Please do not open a public issue for anything that could be exploited against
someone else's device or data. Give it a few days for a first response.

## What is worth reporting

- Anything that lets untrusted input from a clip, a design archive or an Iconify
  response run code, escape a sandbox, or write outside the app group.
- Anything that causes the app or the extension to read or transmit data it has
  no reason to touch.
- Dependency or toolchain issues that affect anyone building this.

## What is not

- The seven-day expiry of free provisioning. That is Apple's.
- Trademarked names and marks referenced by the app catalogue or by brand icon
  sets; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
- The fact that designs must be compiled on a Mac. That is a platform
  constraint — see [docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md).
