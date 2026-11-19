# Open-Breach — Distribution Spec

Written 2026-11-18. Source of truth for how Open-Breach apps are packaged, published and installed on Linux, macOS and Windows. Supersedes the distribution sections of the Rick platform doc from 2026-11-09 where they differ.

## 1. Purpose and scope

One distribution path for every Open-Breach project, as long as it makes sense for the project. First consumers: **Rick** (file manager, Rust/egui, all three platforms), **Meeseeks** (virtual monitor, Rust/GTK 4, Linux only) and **Gossip** (Kubernetes log tail, Rust, CLI first). Planned fourth consumer: **flowcpt** desktop app (Flutter, closed source).

Not pursued: official Debian or Fedora inclusion (too much work for the crate count, not worth the time now), Flatpak and Snap, the Mac App Store and the Microsoft Store, Open Build Service (all builds already run on Depot; OBS's free tier is open-source-only, which would exclude flowcpt).

## 2. Decisions

1. A separate public repository, `Open-Breach/trebuchet` ("Trebuchet"), holds the reusable build workflows and owns publishing. Apps build, the distribution repo publishes.
2. All builds run in GitHub Actions on Depot runners, native x86-64 and arm64.
3. Linux: tarball, deb and rpm on every tag, for Debian 12, Ubuntu 24.04 and Fedora 41, x86-64 and arm64. Published to Open-Breach's own apt and dnf repositories on an Open-Breach domain. Arch through the AUR only. NixOS through a `flake.nix` per repo. The distro versions are to be confirmed, see 4.1 and 11.
4. arm64 Linux builds ship from the start and are marked untested until someone reports otherwise.
5. macOS: Apple Silicon only. Signed with Developer ID, notarised, stapled, shipped as a DMG and through an Open-Breach Homebrew tap. No Sparkle.
6. Windows: unsigned for now. Inno Setup installer plus zip, published through winget. MSIX ruled out because it requires signing.
7. A Rick plugin registry lives next to the package repos: an index file listing Open-Breach's own plugins with per-platform downloads. Third-party listings later, if at all. The same index carries latest-version information so apps can show an update notice themselves.
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
- **Home of the shared files**: the plugin registry index, the install script, the public GPG key, the install docs with the derivatives table, the Homebrew tap formula templates and the AUR PKGBUILD templates.

### Layout

- `.github/workflows/` — reusable workflows and the publisher.
- `apt/`, `rpm/` — scripts that build indexes (`apt-ftparchive`, `createrepo_c`) and sign them.
- `registry/` — plugin index source and the script that regenerates it.
- `install.sh` — one-line installer (see 4.5).
- `keys/` — public GPG key.
- `docs/` — install instructions per platform.

### Release flow for an app

1. Developer bumps the version, updates the README, merges to `main`, pushes tag `vX.Y.Z`.
2. The app's release workflow calls the reusable workflows. Each produces its artifacts and attaches them to a GitHub Release for the tag. Guards from the Rick and Meeseeks specs stay: tagged commit on `main`, tag equals `Cargo.toml` version and README status line, desktop file validates.
3. The app's workflow sends a `repository_dispatch` to `Open-Breach/trebuchet` with the app name, version and release URL.
4. The publisher pulls the packages, republishes the repos, regenerates the registry index if the app is a Rick plugin, and bumps the AUR package, Homebrew cask and winget manifest.

## 4. Linux

### 4.1 Targets

- Debian 12, Ubuntu 24.04, Fedora 41; x86-64 and arm64. Six build jobs per app.
- To confirm before the first build: these versions were named on 2026-11-18 without checking their release status. See the first open item in 11.
- Derivatives use the base distro's package: Mint 22, Pop!_OS, Zorin, elementary and KDE neon take the Ubuntu 24.04 package; LMDE takes Debian 12; Nobara and Ultramarine take the Fedora package.
- New distro versions are added as a matrix entry when they ship; old ones are dropped when the distro drops them.

### 4.2 Build

- Each matrix job runs in the target distro's official container image (`debian:12`, `ubuntu:24.04`, `fedora:41`) on a Depot runner of the matching architecture, so every package links against that distro's own glibc, GTK and GStreamer. No cross-compiling, no emulation.
- Rust apps: `cargo build --release`, then `cargo-deb` and `cargo-generate-rpm` with metadata from `Cargo.toml`. The same job also produces the tarball in the established layout (top-level folder, `share/applications`, `share/icons`), so Rick's tarball installer keeps working.
- Prebuilt-artifact apps (flowcpt): the workflow takes a folder and wraps it with `nfpm` into deb and rpm. Runtime dependencies are declared per distro in the app's call.
- Smoke test in every job: install the package in a fresh container of the same image, run the binary with `--version`, validate the desktop file with `desktop-file-validate` if present. On arm64 this is the only test until someone has hardware.

### 4.3 Plugins as packages (Rick)

- The Rick core package carries the lean binary and the built-in previewers. Every plugin is its own package, `rick-plugin-<name>`, installed into Rick's plugin directory.
- Each plugin package depends on the exact matching `rick` version (`Depends: rick (= X.Y.Z)` / `Requires: rick = X.Y.Z`), because a plugin built against another binary may not load.
- A `rick-plugins` meta package pulls in the whole set.
- Plugin packages are built by the plugin repo's own release workflow through the same reusable workflow and published by the same publisher.

### 4.4 Repositories

- apt: one repository with one suite per base distro (`debian-12`, `ubuntu-24.04`), component `main`, both architectures in the same index. Signed `Release`/`InRelease` with the Open-Breach GPG key.
- dnf: one repository per Fedora version with one directory per architecture, `repomd.xml` signed with the same key.
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
- No Sparkle. The update notice comes from the app itself (see 7.3).

## 6. Windows

- Unsigned for now. Accepted consequence: SmartScreen shows "Windows protected your PC" on first run of each new release and the user has to click through. Revisit with Azure Trusted Signing or SignPath if Rick gains a Windows audience; nothing else in the pipeline changes when signing is added.
- Artifacts: Inno Setup installer (`rick-X.Y.Z-windows-x64-setup.exe`) with silent-install flags, Start menu entry and the opt-in Explorer integration from the Rick platform spec, plus the existing zip for people who want a portable copy.
- winget: the publisher runs `wingetcreate update` to open the manifest pull request against `microsoft/winget-pkgs`. The first submission per app is reviewed by hand; later updates are routine.
- MSIX is out because it must be signed.

## 7. Plugin registry

### 7.1 Scope

- Lists Open-Breach's own Rick plugins only. No third-party submissions for now; a second index source can be added to Rick later without changing the format.

### 7.2 Index

- One JSON document, `registry/index.json`, served from the distribution domain. For every plugin: id, name, one-line description, list of versions, and for each version the compatible Rick version range plus one download per platform (`linux-x86_64`, `linux-aarch64`, `macos-aarch64`, `windows-x86_64`) with URL and SHA-256.
- Rick's Extensions screen fetches the index, shows what is installed, available and updatable, and installs into the user's plugin directory. On Linux, plugins installed from a package are shown as managed by the package manager and are not touched.
- The publisher regenerates the index from the plugin releases; nobody edits it by hand.

### 7.3 Update notice

- The index also carries a `latest` entry per app with version and release URL. Rick, Meeseeks and Gossip check it on start (opt-out in settings) and show a small notice in About when a newer version exists. On Linux the notice says to update through the package manager; on macOS and Windows it links to the download. No in-app installer.

## 8. Hosting and domain

- Decided: Cloudflare R2 behind a custom domain (free tier covers the expected volume, no egress fees, CDN included, requires the domain's DNS on Cloudflare). Azure Blob Storage was the alternative and is not pursued.
- Set up 2026-11-18: domain `openbreach.dev` registered on Cloudflare, bucket created (standard class, automatic location), custom domain `get.openbreach.dev` attached and active, bucket-scoped API token with Object Read and Write created. The bucket is reached only through the custom domain; the r2.dev address stays off.
- Secrets in Trebuchet: `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_ENDPOINT`; the bucket name as the repository variable `R2_BUCKET`.
- Everything under one domain: apt and dnf repos, the install script, the public key, the plugin index, and release downloads mirrored from GitHub if ever needed.
- GitHub Releases stay the primary home of the raw artifacts; the bucket holds the repos and the index.

## 9. Signing and secrets — Serge's checklist

- GPG key for the apt and dnf repositories; public key in the distribution repo, private key in the distribution repo's secrets.
- AUR account and SSH key, in the distribution repo's secrets.
- Apple: Developer ID Application certificate exported as `.p12`, its password, and an App Store Connect API key for notarisation, in each Mac-building app repo's secrets or in an organisation secret.
- GitHub token with permission to open pull requests against `winget-pkgs` and to push to the Homebrew tap.
- R2 API token scoped to the one bucket, read and write, for the publisher.
- Depot: GitHub app enabled for the distribution repo and every consuming repo; arm64 runner labels configured.
- Done: `openbreach.dev` on Cloudflare, bucket created, `get.openbreach.dev` attached.

## 10. Per-app notes

- **Rick**: already ships tarballs for Linux x64 and arm64, macOS arm64 and Windows x64, and already has the tarball installer. Adds deb, rpm, AUR, flake, DMG with notarisation, Inno Setup, winget, and the plugin registry. Plugins split into packages as in 4.3.
- **Meeseeks**: Linux only. Keeps its tarball and README-as-release-notes workflow; adds deb, rpm, AUR and flake through the same reusable workflow. arm64 is new and untested. The Ubuntu 24.04 GTK 4.14 floor stays; Debian 12 ships GTK 4.8, so Meeseeks skips the Debian 12 target until the GTK floor allows it.
- **Gossip**: CLI first, so no desktop file or icon initially; the workflow treats those as optional. Gets deb, rpm, AUR, flake, Homebrew formula (not cask) and winget. When the GUI lands, the desktop entry and icon are added to the same call.
- **flowcpt** (planned): Flutter desktop build, closed source, private repo. Calls the public reusable workflow with a prebuilt artifact folder; runtime dependencies (GTK 3 and the Flutter Linux stack) declared in the call; licence text shipped in the package instead of Apache-2.0. Not in the plugin registry.

## 11. Open items

- Target distro versions (4.1), to settle before the first build. Checked 2026-11-18: Fedora 41 has been end-of-life since December 2025; Fedora 43 (until 1 December 2026), 44 and 45 are the supported releases. Debian 13 is the current stable and Debian 12 is in LTS until June 2028. Ubuntu 26.04 LTS exists alongside 24.04 LTS. Every version reference in 2, 4 and 10 follows this decision.
- Whether the root `openbreach.dev` gets a project website later (the packages live under `get.openbreach.dev`).
- Exact dnf repo layout for future Fedora versions (one repo per version versus `$releasever` substitution).
- Whether the install script also handles AUR helpers on Arch or just points to the AUR page.
- Meeseeks on Debian 12 once a GTK floor decision is revisited.
- Registry format details: version range syntax and how Rick treats a plugin whose compatible range excludes the running version.

## 12. Next steps

1. Done 2026-11-18: `Open-Breach/trebuchet` created with this document as `docs/spec.md`.
2. Generate the GPG key, create the AUR account, confirm Apple credentials, enable Depot.
3. Implement `linux-packages.yml` and the publisher first, test them with Rick, then Meeseeks and Gossip.
4. Add the AUR, Homebrew and winget publish steps.
5. Add the macOS and Windows reusable workflows for Rick.
6. Add `flake.nix` to each Rust repo.
7. Add the plugin registry index and the Extensions-screen integration in Rick.
8. Done 2026-11-18: domain, bucket, custom domain and token. Remaining: put the token into Trebuchet's secrets.
