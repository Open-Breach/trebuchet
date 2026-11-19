# Trebuchet

**Status: bootstrapping. Nothing is published yet.**

Trebuchet is the distribution repository of [Open-Breach](https://github.com/Open-Breach). Like the siege engine, it hurls packages a long way.

It does two jobs:

- **Build.** Reusable GitHub Actions workflows that every Open-Breach app calls from its own release workflow to produce its Linux, macOS and Windows packages the same way.
- **Publish.** One publisher that maintains the shared apt and dnf repositories and the Rick plugin registry on `get.openbreach.dev`.

Apps build, Trebuchet publishes.

## What it will serve

- [Rick](https://github.com/Open-Breach/rick), the file manager
- [Meeseeks](https://github.com/Open-Breach/meeseeks), the virtual second monitor for Linux
- Gossip, the Kubernetes log tail

## Where to read

- [`docs/spec.md`](docs/spec.md) is the source of truth: decisions, pipelines per platform, the plugin registry, hosting and the release flow.
- [`CLAUDE.md`](CLAUDE.md) holds the rules for agents and contributors working in this repo.

Install instructions land in `docs/install.md` once the first packages are published.

## Why this repo is public

You are asked to trust a signing key and, if you like, to run an install script. You should be able to read exactly how every package is built and published, so everything that does it lives here in the open.

No secret is ever committed to this repo. Keys and tokens live in GitHub secrets and are referenced by name only.

## Licence

Apache-2.0. The `LICENSE` file arrives with the repository skeleton.
