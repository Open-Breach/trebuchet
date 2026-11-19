# Open-Breach — Distribution Spec

Written 2026-11-18; the plugin registry (4.3, 7) worked out the same evening. Source of truth for how Open-Breach apps are packaged, published and installed on Linux, macOS and Windows. Supersedes the distribution sections of the Rick platform doc from 2026-11-09 where they differ.

## 1. Purpose and scope

One distribution path for every Open-Breach project, as long as it makes sense for the project. First consumers: **Rick** (file manager, Rust/egui, all three platforms), **Meeseeks** (virtual monitor, Rust/GTK 4, Linux only) and **Gossip** (Kubernetes log tail, Rust, CLI first). Planned fourth consumer: **flowcpt** desktop app (Flutter, closed source).

Not pursued: official Debian or Fedora inclusion (too much work for the crate count, not worth the time now), Flatpak and Snap, the Mac App Store and the Microsoft Store, Open Build Service (all builds already run on Depot; OBS's free tier is open-source-only, which would exclude flowcpt).

## 2. Decisions

1. A separate public repository, `Open-Breach/trebuchet` ("Trebuchet"), holds the reusable build workflows and owns publishing. Apps build, the distribution repo publishes.
2. All builds run in GitHub Actions on Depot runners, native x86-64 and arm64.
3. Linux: tarball, deb and rpm on every tag, for the two newest Fedora releases, Debian stable and oldstable, and the two latest Ubuntu LTS releases, x86-64 and arm64. The current list is [`targets.json`](../targets.json). Published to Open-Breach's own apt and dnf repositories on an Open-Breach domain. Arch through the AUR only. NixOS through a `flake.nix` per repo.
4. arm64 Linux builds ship from the start and are marked untested until someone reports otherwise.
5. macOS: Apple Silicon only. Signed with Developer ID, notarised, stapled, shipped as a DMG and through an Open-Breach Homebrew tap. No Sparkle.
6. Windows: unsigned for now. Inno Setup installer plus zip, published through winget. MSIX ruled out because it requires signing.
7. A plugin registry lives next to the package repos: one signed index file that lists, per app, the plugins the app's releases publish, with one download per platform. Rick is the first app with plugins. Open-Breach's own plugins only. The same index carries each app's latest version so apps can show an update notice themselves.
8. Host: Cloudflare R2 behind the custom domain `get.openbreach.dev` (domain `openbreach.dev`, DNS on Cloudflare). Decided and set up 2026-11-18; Azure Blob Storage was the alternative.
9. Closed-source apps go through the same channels; nothing in the chosen path requires an open licence.

## 3. The distribution repository

`Open-Breach/trebuchet`, named Trebuchet after the superior siege engine because it hurls packages a long way; public, Apache-2.0 for its own contents.

### Visibility and secrets

- The repo is public on purpose, for audit and transparency: users are asked to trust a signing key and to run an install script, so they must be able to read how every package is built and published. A public repo also lets any Open-Breach repository, private ones included, call its reusable workflows without access settings.
- Rule for every agent and contributor: nothing secret is ever committed to this repo, not in files, workflow definitions, logs, test fixtures or commit messages. That covers private keys, tokens, passwords, API keys, certificates, customer data and anything about flowcpt beyond its package metadata. Secrets live only in GitHub repository or organisation secrets and are referenced by name.
- A secret that lands in the history, even briefly, is treated as leaked and rotated.
- This rule goes into the repo's `CLAUDE.md` so the agent sees it on every task.

### Roles

- **Reusable workflows** that app repos call with `workflow_call`. One per platform: `linux-packages.yml`, `macos-dmg.yml`, `windows-installer.yml`, plus `aur-publish.yml` and `winget-publish.yml`. Inputs are the app name, binary name, version, desktop file and icon paths (optional, Gossip has none at first), package description, runtime dependencies per distro, and either a cargo build or a prebuilt artifact folder (flowcpt).
- **Publisher** for the shared state. One workflow, triggered by `repository_dispatch` from an app's release, that fetches the new packages from the app's GitHub Release, rebuilds the apt and dnf indexes over the whole pool, signs them, and syncs to the bucket. A `concurrency` group serialises publishes so two apps never rebuild the indexes at the same time.
- **Home of the shared files**: the scripts behind the plugin registry index, the install script, the public GPG key, the registry's public signing key, the install docs with the derivatives table, the Homebrew tap formula templates and the AUR PKGBUILD templates.

### Layout

- `.github/workflows/` — reusable workflows and the publisher.
- `apt/`, `rpm/` — scripts that build indexes (`apt-ftparchive`, `createrepo_c`) and sign them.
- `registry/` — the scripts that merge a release's plugins into the registry index, prune it and sign it. The index itself is not in the repository; it lives in the bucket (7.2).
- `install.sh` — one-line installer (see 4.5).
- `keys/` — the public GPG key of the package repositories and the public key the registry index is signed with.
- `docs/` — install instructions per platform.

### Release flow for an app

1. Developer bumps the version, updates the README, merges to `main`, pushes tag `vX.Y.Z`.
2. The app's release workflow calls the reusable workflows. Each produces its artifacts and attaches them to a GitHub Release for the tag. Guards from the Rick and Meeseeks specs stay: tagged commit on `main`, tag equals `Cargo.toml` version and README status line, desktop file validates.
3. The app's workflow sends a `repository_dispatch` to `Open-Breach/trebuchet` with the app name, version and release URL.
4. The publisher pulls the packages, republishes the repos, writes the app's latest version into the registry index and adds the release's plugins to it when the release carries any (7.4), and bumps the AUR package, Homebrew cask and winget manifest.

## 4. Linux

### 4.1 Targets

- The targets follow a rule, not a fixed list: the two newest Fedora releases, Debian stable and oldstable, and the two latest Ubuntu LTS releases; x86-64 and arm64. Six targets, twelve build jobs per app. Decided 2026-11-19.
- The current list is [`targets.json`](../targets.json), the one place the build matrix, the index scripts and the tests read.
- Derivatives use the package of the release they are based on: Mint, Pop!_OS, Zorin, elementary and KDE neon take the package of their Ubuntu LTS base; LMDE takes that of its Debian base; Nobara and Ultramarine take the Fedora package of the same release. The install docs carry the table with the current releases.
- A new release enters `targets.json` when it ships, and the release the rule no longer covers leaves it.

### 4.2 Build

- Each matrix job runs in the target distro's official container image, which `targets.json` names for each target, on a Depot runner of the matching architecture, so every package links against that distro's own glibc, GTK and GStreamer. No cross-compiling, no emulation.
- Rust apps: `cargo build --release`, then `cargo-deb` and `cargo-generate-rpm` with metadata from `Cargo.toml`. The same job also produces the tarball in the established layout (top-level folder, `share/applications`, `share/icons`), so Rick's tarball installer keeps working.
- Prebuilt-artifact apps (flowcpt): the workflow takes a folder and wraps it with `nfpm` into deb and rpm. Runtime dependencies are declared per distro in the app's call.
- Smoke test in every job: install the package in a fresh container of the same image, run the binary with `--version`, validate the desktop file with `desktop-file-validate` if present. A call may name one more command, of the app's own, that runs there after the install and again for the unpacked tarball. On arm64 this is the only test until someone has hardware.

### 4.3 Plugins as packages

- An app with plugins splits into several packages from one build. The main package (`rick`) carries the binary, what it needs beside it, and the plugins the app counts as part of every install. Every other plugin is its own package, `<app>-plugin-<id>` (`rick-plugin-git`), whose files land in the app's plugins directory beside the binary.
- Which plugins belong to the main package is the app's decision and is named in the app's call, not here. Rick's list is in its `specs/plugin-distribution.md`, section 4: sixteen plugins in the `rick` package, and on Linux nine separate ones.
- Each plugin package depends on the exact version of the main package (`Depends: rick (= X.Y.Z)` / `Requires: rick = X.Y.Z`): a Rick plugin loads only in the Rick build it was made with (7.3).
- A meta package, `<app>-plugins`, pulls in the whole set.
- The plugin packages come out of the same matrix job as the main package, so they link against the same distro libraries. They are published by the same publisher into the same pool.
- These packages are how a Rick installed from a deb or an rpm gets its plugins. The registry's downloads (7) are made from the release archives and fit the archives only; Rick does not offer them to a packaged install.

### 4.4 Repositories

- apt: one repository with one suite per Debian and Ubuntu target, named by the target's id in `targets.json`, component `main`, both architectures in the same index. Signed `Release`/`InRelease` with the Open-Breach GPG key.
- dnf: one repository per Fedora target with one directory per architecture, `repomd.xml` signed with the same key.
- Users add the repo once (the key goes in `/etc/apt/keyrings` or is imported by dnf) and then install, update and remove with their normal tools.
- The pool holds every app and every plugin. Old versions are kept for the last three releases so downgrades work, then pruned by the publisher.

### 4.5 Install script

- `install.sh` served from the distribution domain. It reads `ID` and `ID_LIKE` from `/etc/os-release`, picks the matching repo line, installs the key, adds the repo and installs the requested package. Usage: `curl -fsSL https://get.openbreach.dev/install.sh | sh -s rick`.
- The script is documentation as much as tooling: the install docs also show the manual steps and the derivatives table for people who do not pipe scripts into a shell.

### 4.6 Arch

- AUR only, no self-hosted pacman repo. Packages `rick-bin`, `meeseeks-bin`, `gossip-bin`, each a PKGBUILD that downloads the release tarball for the running architecture from GitHub, verifies the checksum and installs the files. Closed-source apps set `license=('custom')` and ship their licence text.
- The publisher pushes the updated PKGBUILD and `.SRCINFO` on every release through the AUR SSH key. Arch derivatives (Manjaro, EndeavourOS, CachyOS) use the same packages.

### 4.7 NixOS

- No binaries for Nix. Each Rust repo carries a `flake.nix` that builds the app with `buildRustPackage`, dependencies from nixpkgs. CI checks `nix build` on every push to `main`.
- Later, optional: an aggregate flake in the distribution repo exposing all apps, and a nixpkgs submission, which is realistic for Rust apps since they vendor through a single hash.

## 5. macOS

- Apple Silicon only. A universal binary is a later one-flag change if demand appears.
- Pipeline on a macOS runner: build, assemble the `.app` bundle, sign with the Developer ID Application certificate (certificate and password from repository secrets, imported into a temporary keychain), notarise with `notarytool` using an App Store Connect API key, staple, build the DMG with `create-dmg`, attach to the GitHub Release.
- Homebrew: cask in the tap `Open-Breach/homebrew-tap` (one tap for all apps). The publisher bumps the cask version and checksum on each release. A pull request to `homebrew-cask` once an app is stable.
- No Sparkle. The update notice comes from the app itself (see 7.6).

## 6. Windows

- Unsigned for now. Accepted consequence: SmartScreen shows "Windows protected your PC" on first run of each new release and the user has to click through. Revisit with Azure Trusted Signing or SignPath if Rick gains a Windows audience; nothing else in the pipeline changes when signing is added.
- Artifacts: Inno Setup installer (`rick-X.Y.Z-windows-x64-setup.exe`) with silent-install flags, Start menu entry and the opt-in Explorer integration from the Rick platform spec, plus the existing zip for people who want a portable copy.
- winget: the publisher runs `wingetcreate update` to open the manifest pull request against `microsoft/winget-pkgs`. The first submission per app is reviewed by hand; later updates are routine.
- MSIX is out because it must be signed.

## 7. Plugin registry

### 7.1 Scope

- One index for every Open-Breach app. Per app it holds the latest released version (7.6) and, for an app with plugins, the plugins its releases publish.
- Open-Breach's own plugins only. A Rick plugin is a crate of Rick's workspace and is built with Rick (7.3), so there is nothing to list from outside yet. Listing plugins built elsewhere waits for a plugin boundary in Rick that allows them.
- The publisher treats what an app says about its plugins as data. Nothing in this repository knows what a previewer is.

### 7.2 Index

- One JSON document, served at `https://get.openbreach.dev/registry/index.json`, with its signature beside it as `index.json.minisig` (7.5). The copy in the bucket is the only one; the publisher reads it, changes it and writes it back. Nobody edits it by hand.
- Shape:

```json
{
  "schema": 1,
  "generated": "2026-11-19T02:00:00Z",
  "apps": {
    "rick": {
      "latest": { "version": "0.6.0", "url": "https://github.com/Open-Breach/rick/releases/tag/v0.6.0" },
      "plugins": [
        {
          "id": "git",
          "name": "Git",
          "description": "Status badges and the Git actions of the context menu.",
          "publisher": "Open-Breach",
          "meta": { "points": ["decorator", "action"], "triggers": { "markers": [".git"] } },
          "builds": [
            {
              "version": "0.6.0",
              "app_version": "0.6.0",
              "api_version": 23,
              "platform": "linux-x64",
              "url": "https://get.openbreach.dev/plugins/rick/0.6.0/git-0.6.0-linux-x64.rkp",
              "size": 1843200,
              "sha256": "…"
            }
          ]
        }
      ]
    },
    "meeseeks": { "latest": { "version": "0.3.1", "url": "…" } }
  }
}
```

- A **plugin** has an id (unique within its app), a name, a one-line description, a publisher, and `meta`: an object the app defines and the publisher copies without reading. Rick keeps there what its plugins fill and what they are suggested for. Name, description and `meta` are those of the plugin's newest build.
- A **build** is one file for one platform: the plugin's own version, `app_version` (the release of the app it was built with), `api_version` (the app's plugin interface version at that release), the platform, the download URL, the size in bytes and the SHA-256 of the file.
- Platforms are named the way the app names its release archives. For Rick: `linux-x64`, `linux-arm64`, `macos-arm64`, `windows-x64`.
- The index says what exists. Which build fits a running app is the app's rule and is written in the app's spec. There are no version ranges.
- `schema` goes up only for a change an old reader cannot ignore. A reader ignores fields it does not know.
- Index files are served with a short `Cache-Control`; the plugin files never change once published and are served with a long one.

### 7.3 Rick's plugins

- A Rick plugin shares Rick's kernel libraries as Rust dynamic libraries, so a build of a plugin loads only in the Rick release it was built with, on the toolchain that built both. Every Rick release therefore publishes a build of every separate plugin, and a build's `app_version` is the only Rick it fits. The plugins Rick ships inside every install are not in the registry.
- The file is Rick's plugin package, an `.rkp`: a zip archive that holds the plugin's folder as it sits in the plugins directory. Rick's Extensions dialogue installs the same file from disk.
- Linux builds in the registry are the ones made with the release tarball. They fit a Rick started from that tarball (and from the AUR package, which repackages it). A Rick installed from a deb or an rpm takes its plugins from the plugin packages of 4.3.

### 7.4 Publishing plugins

- **The contract with the app.** A release that carries plugins attaches, per platform, the plugin files and one manifest named `plugins-<platform>.json`:

```json
{
  "app": "rick",
  "app_version": "0.6.0",
  "platform": "linux-x64",
  "plugins": [
    {
      "id": "git",
      "name": "Git",
      "description": "Status badges and the Git actions of the context menu.",
      "version": "0.6.0",
      "api_version": 23,
      "meta": { "points": ["decorator", "action"], "triggers": { "markers": [".git"] } },
      "file": "git-0.6.0-linux-x64.rkp",
      "size": 1843200,
      "sha256": "…"
    }
  ]
}
```

- **What the publisher does**, inside the same run and the same concurrency lock as the package repositories: for each manifest of the release it downloads the files the manifest names, checks size and SHA-256 against the manifest, uploads each file to `plugins/<app>/<app_version>/<file>` in the bucket, and adds a build to the index. A build that is already in the index under the same plugin, version and platform is left alone, so a publisher run can be repeated. A file that fails its check stops the run before anything is written.
- **Pruning.** The index keeps the builds of the app's last three releases, like the package pool (4.4). Builds of older releases leave the index and their files leave the bucket. A release that is yanked is removed by a manual publisher run that names it.
- A plugin that no later release carries leaves the index when its last build is pruned.
- The index is written and signed last, after every file is in place, so a reader never sees an entry whose file is missing.

### 7.5 Signing

- The index is signed with a dedicated Ed25519 key in minisign format, separate from the GPG key of the package repositories. The signature is `index.json.minisig`.
- Private key and its password are the repository secrets `REGISTRY_SIGNING_KEY` and `REGISTRY_SIGNING_PASSWORD`. The public key is committed as `keys/registry.pub`. An app that reads the registry compiles that public key in and refuses an index whose signature does not verify.
- The plugin files are not signed one by one. The signed index carries their SHA-256, and the app checks every download against it.
- A key that leaks is replaced: new key pair, new `keys/registry.pub`, and a release of every app that compiles the key in. Apps released before that keep refusing the newly signed index, which is the point.
- Serge generates the key pair. No workflow, agent or contributor creates or sees the private key.

### 7.6 Update notice

- `apps.<app>.latest` carries the version and the release URL of the app's newest release; the publisher writes it on every release of any app. Rick, Meeseeks and Gossip check it (opt-out in settings) and show a small notice in About when a newer version exists. On Linux the notice says to update through the package manager; on macOS and Windows it links to the download. No in-app installer.

## 8. Hosting and domain

- Decided: Cloudflare R2 behind a custom domain (free tier covers the expected volume, no egress fees, CDN included, requires the domain's DNS on Cloudflare). Azure Blob Storage was the alternative and is not pursued.
- Set up 2026-11-18: domain `openbreach.dev` registered on Cloudflare, bucket created (standard class, automatic location), custom domain `get.openbreach.dev` attached and active, bucket-scoped API token with Object Read and Write created. The bucket is reached only through the custom domain; the r2.dev address stays off.
- Secrets in Trebuchet: `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_ENDPOINT`; the bucket name as the repository variable `R2_BUCKET`.
- Everything under one domain: apt and dnf repos, the install script, the public key, the plugin index, and release downloads mirrored from GitHub if ever needed.
- GitHub Releases stay the primary home of the raw artifacts; the bucket holds the repos and the index.

## 9. Signing and secrets — Serge's checklist

- GPG key for the apt and dnf repositories; public key in the distribution repo, private key in the distribution repo's secrets.
- Registry signing key (7.5): a minisign key pair made with `minisign -G -p registry.pub -s registry.key`; `registry.pub` committed as `keys/registry.pub`, the contents of `registry.key` as the secret `REGISTRY_SIGNING_KEY`, its password as `REGISTRY_SIGNING_PASSWORD`.
- AUR account and SSH key, in the distribution repo's secrets.
- Apple: Developer ID Application certificate exported as `.p12`, its password, and an App Store Connect API key for notarisation, in each Mac-building app repo's secrets or in an organisation secret.
- GitHub token with permission to open pull requests against `winget-pkgs` and to push to the Homebrew tap.
- R2 API token scoped to the one bucket, read and write, for the publisher.
- Depot: GitHub app enabled for the distribution repo and every consuming repo; arm64 runner labels configured.
- Done: `openbreach.dev` on Cloudflare, bucket created, `get.openbreach.dev` attached.

## 10. Per-app notes

- **Rick**: already ships tarballs for Linux x64 and arm64, macOS arm64 and Windows x64, and already has the tarball installer. Adds deb, rpm, AUR, flake, DMG with notarisation, Inno Setup, winget, and the plugin registry (7.3). Plugins split into packages as in 4.3. Rick's side of the registry — what fits, how a plugin is installed, when one is suggested — is `specs/plugin-distribution.md` in the Rick repository.
- **Meeseeks**: Linux only. Keeps its tarball and README-as-release-notes workflow; adds deb, rpm, AUR and flake through the same reusable workflow. arm64 is new and untested. The GTK 4.14 floor stays: Meeseeks leaves out, with `exclude` in its call, every target in `targets.json` whose release ships an older GTK, until the floor is revisited or that release leaves the list.
- **Gossip**: CLI first, so no desktop file or icon initially; the workflow treats those as optional. Gets deb, rpm, AUR, flake, Homebrew formula (not cask) and winget. When the GUI lands, the desktop entry and icon are added to the same call.
- **flowcpt** (planned): Flutter desktop build, closed source, private repo. Calls the public reusable workflow with a prebuilt artifact folder; runtime dependencies (GTK 3 and the Flutter Linux stack) declared in the call; licence text shipped in the package instead of Apache-2.0. Not in the plugin registry.

## 11. Open items

- Whether the root `openbreach.dev` gets a project website later (the packages live under `get.openbreach.dev`).
- Exact dnf repo layout for future Fedora versions (one repo per version versus `$releasever` substitution).
- Whether the install script also handles AUR helpers on Arch or just points to the AUR page.
- Meeseeks on Debian 12 once a GTK floor decision is revisited.
- Listing plugins that are not built in Rick's workspace (7.1). Needs a plugin boundary in Rick that survives a Rick release: a stable ABI or the WASM host.
- Whether the registry keeps more than the last three releases of an app's plugins (7.4), for users who stay on an old Rick.

## 12. Next steps

1. Done 2026-11-18: `Open-Breach/trebuchet` created with this document as `docs/spec.md`.
2. Generate the GPG key, create the AUR account, confirm Apple credentials, enable Depot.
3. Implement `linux-packages.yml` and the publisher first, test them with Rick, then Meeseeks and Gossip.
4. Add the AUR, Homebrew and winget publish steps.
5. Add the macOS and Windows reusable workflows for Rick.
6. Add `flake.nix` to each Rust repo.
7. Add the plugin registry: the publisher's side here (7.4, 7.5) and the plugin packages (4.3); Rick's side in the Rick repository.
8. Done 2026-11-18: domain, bucket, custom domain and token. Remaining: put the token into Trebuchet's secrets.
