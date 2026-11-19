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
- [`docs/install.md`](docs/install.md) is for users: how to install an app, by script or by hand, and on which distros.
- [`docs/linux-packages.md`](docs/linux-packages.md) is for an app that wants its Linux packages built: how to call `linux-packages.yml` and what to bring.
- [`docs/publisher.md`](docs/publisher.md) is for whoever runs the publisher: what starts it, its secrets, what it does to the bucket and what to do when a run fails.
- [`docs/repositories.md`](docs/repositories.md) describes the apt and dnf repositories: the target list, the layout, the scripts and how to run the tests.
- [`CLAUDE.md`](CLAUDE.md) holds the rules for agents and contributors working in this repo.

## Layout

- `.github/workflows/`: the reusable workflows and the publisher, plus this repo's own CI.
- `targets.json`: the distro releases and architectures everything is built for, in one place.
- `apt/`, `rpm/`: the scripts that build the repository indexes.
- `install.sh`: the one-line installer served from `get.openbreach.dev`.
- `registry/`: the scripts behind the plugin registry (not started).
- `keys/`: the public signing keys.
- `docs/`: the spec and the documentation.
- `tests/`: the fixture package and the tests CI runs.

To install an app, see [`docs/install.md`](docs/install.md).

## Why this repo is public

You are asked to trust a signing key and, if you like, to run an install script. You should be able to read exactly how every package is built and published, so everything that does it lives here in the open.

No secret is ever committed to this repo. Keys and tokens live in GitHub secrets and are referenced by name only.

## Runners

In a repository that belongs to Open-Breach, the workflows here run on [Depot](https://depot.dev) runners, under the labels Open-Breach's other repositories use: `depot-ubuntu-24.04-8` for x86-64 and `depot-ubuntu-24.04-arm-16` for arm64.

In anyone else's repository, a fork for instance, the same jobs run on GitHub's own `ubuntu-24.04` and `ubuntu-24.04-arm` runners without anything to set up. The repository variables `RUNNER_LINUX_X64` and `RUNNER_LINUX_ARM64` name other labels in either case.

`linux-packages.yml` follows the same rule by the owner of the repository that calls it, and takes the labels as its `runner-x64` and `runner-arm64` inputs as well ([`docs/linux-packages.md`](docs/linux-packages.md)).

## Licence

Apache-2.0, see [`LICENSE`](LICENSE).
