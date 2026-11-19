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
- [`docs/repositories.md`](docs/repositories.md) describes the apt and dnf repositories: the target list, the layout, the scripts and how to run the tests.
- [`CLAUDE.md`](CLAUDE.md) holds the rules for agents and contributors working in this repo.

## Layout

- `.github/workflows/`: the reusable workflows and the publisher, plus this repo's own CI.
- `targets.json`: the distro releases and architectures everything is built for, in one place.
- `apt/`, `rpm/`: the scripts that build the repository indexes.
- `registry/`: the scripts behind the plugin registry (not started).
- `keys/`: the public signing keys.
- `docs/`: the spec and the documentation.
- `tests/`: the fixture package and the tests CI runs.

Install instructions land in `docs/install.md` once the first packages are published.

## Why this repo is public

You are asked to trust a signing key and, if you like, to run an install script. You should be able to read exactly how every package is built and published, so everything that does it lives here in the open.

No secret is ever committed to this repo. Keys and tokens live in GitHub secrets and are referenced by name only.

## Runners

In a repository that belongs to Open-Breach, the workflows here run on [Depot](https://depot.dev) runners, under the label Open-Breach's other repositories use: `depot-ubuntu-24.04-8`.

In anyone else's repository, a fork for instance, the same jobs run on GitHub's own `ubuntu-24.04` runner without anything to set up. The repository variable `RUNNER_LINUX_X64` names another label in either case.

## Licence

Apache-2.0, see [`LICENSE`](LICENSE).
