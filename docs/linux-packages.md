# Building Linux packages: `linux-packages.yml`

The reusable workflow an app calls from its release workflow to get its Linux packages. The decisions behind it are in [`spec.md`](spec.md), section 4; this page is how to use it.

## What a call does

For every target in [`targets.json`](../targets.json) and for x86-64 and arm64:

1. **Build**, inside the target's official container image on a runner of the matching architecture. No cross-compiling, no emulation: the package links against that distro's own libraries.
2. **Package**: a `.deb` or an `.rpm`.
3. **Tarball**: one target per architecture also makes `<app>-<version>-linux-<arch>.tar.gz` in the established layout.
4. **Smoke test**, in a fresh container of the same image: install the package with `apt` or `dnf`, run `<binary> --version`, validate the desktop entry with `desktop-file-validate`. The tarball is unpacked and tested the same way.
5. **Upload** everything as artifacts of the run, with [what the build added](#files-the-build-adds).
6. **Attach** everything to a GitHub Release of the calling repository, if the call names one and every smoke test passed.

arm64 packages are built and smoke-tested on arm64 runners, and are otherwise untested until someone with hardware reports back (spec, decision 4).

## Calling it

An example for Rick, from its release workflow:

```yaml
jobs:
  linux:
    permissions:
      contents: write        # to attach to the release; read is enough without release-tag
    uses: Open-Breach/trebuchet/.github/workflows/linux-packages.yml@main
    with:
      app: rick
      version: ${{ needs.version.outputs.version }}     # 1.2.3, the tag without its v
      desktop-file: packaging/linux/rick.desktop
      icon: assets/icons/linux/hicolor
      build-deps: |
        {
          "debian": ["libgstreamer1.0-dev", "libgstreamer-plugins-base1.0-dev"],
          "ubuntu": ["libgstreamer1.0-dev", "libgstreamer-plugins-base1.0-dev"],
          "fedora": ["gstreamer1-devel", "gstreamer1-plugins-base-devel"]
        }
      release-tag: ${{ github.ref_name }}
```

`@main` follows this repository; a commit SHA pins it. The scripts the workflow runs are taken from the same commit as the workflow file, whichever way it is referenced.

## Inputs

| Input | Mode | Default | Meaning |
| --- | --- | --- | --- |
| `app` | both | required | The package name, such as `rick`. Lowercase letters, digits, `+`, `-`, `.`. Also the first part of the tarball's name. |
| `binary` | both | `app` | The executable the package puts on the `PATH`. The smoke test runs it with `--version`. |
| `version` | both | required | `X.Y.Z`, or `X.Y.Z-rc1` for a pre-release: the tag without its leading `v`. |
| `description` | prebuilt | required there | One-line package description. A cargo build takes it from `Cargo.toml`. |
| `desktop-file` | both | none | Path of the desktop entry. Leave it out for an app without one. |
| `icon` | both | none | Path of the icon: an `.svg` file, a square `.png` file, or a `hicolor` directory in the XDG layout. |
| `runtime-deps` | both | `{}` | Runtime dependencies per distro, as JSON. See below. |
| `build` | | `cargo` | `cargo` or `prebuilt`. |
| `artifact` | prebuilt | required there | Name of the artifact of the same run that holds the prebuilt folder. |
| `exclude` | both | none | Target ids to leave out, separated by spaces or commas: `debian-12`. |
| `release-tag` | both | none | Tag of the GitHub Release to attach the files to. Empty: artifacts only. |
| `build-deps` | cargo | `{}` | Distro packages the build needs, per distro, in the shape of `runtime-deps`. Names only. |
| `build-command` | cargo | `cargo build --release --locked` | The command that builds the app, run with bash in `working-directory`. |
| `build-artifact` | cargo | none | Name of an artifact of the same run that the build needs, downloaded before `build-command`. See [Files from an earlier job](#files-from-an-earlier-job). |
| `build-artifact-path` | cargo | `.` | Where `build-artifact` is put, relative to `working-directory`. |
| `cargo-package` | cargo | `app` | The crate that carries the packaging metadata, when the repository is a workspace and the crate is not named like the package. |
| `bundle-dir` | cargo | none | A folder the build lays out, with the binary at its top level and what belongs beside it. The tarball is made from it. Without it the binary alone is the bundle. |
| `working-directory` | both | `.` | Directory of the app in the calling repository. The other paths are relative to it. |
| `maintainer` | prebuilt | the repository's owner | The package's maintainer field. |
| `runner-x64` | both | by the caller's owner, see [Runners](#runners) | Runner label for the x86-64 jobs, and for the two small jobs that plan the matrix and attach to the release. |
| `runner-arm64` | both | by the caller's owner, see [Runners](#runners) | Runner label for the arm64 jobs. |

### Dependencies per distro

`runtime-deps` and `build-deps` are JSON objects. A key is a distro (`debian`, `ubuntu`, `fedora`) or one target id (`ubuntu-24.04`); a target gets the list of its distro and the list of its own id. A key that matches no target fails the call, so a typo or a target that has been dropped does not pass silently.

```json
{
  "debian": ["gstreamer1.0-plugins-good"],
  "ubuntu": ["gstreamer1.0-plugins-good"],
  "ubuntu-24.04": ["libfoo1t64 (>= 1.2)"],
  "fedora": ["gstreamer1-plugins-good", "foo-libs >= 1.2"]
}
```

Runtime dependencies are written the way the format writes them: `name (>= 1.2)` for deb, `name >= 1.2` for rpm.

### Leaving targets out

`exclude: debian-12` builds everything but Debian 12. That is how an app whose library floor is above a target's skips it.

## A cargo build

The job installs the compiler and the `build-deps`, installs the Rust toolchain with rustup (the one `rust-toolchain.toml` pins, or stable), runs `build-command`, then packages with [`cargo-deb`](https://github.com/kornelski/cargo-deb) or [`cargo-generate-rpm`](https://github.com/cat-in-136/cargo-generate-rpm).

**The packaging metadata lives in the app's `Cargo.toml`**: which files go where, the dependencies that hold for every distro, the maintainer, the description. For a single binary with a desktop entry and an icon:

```toml
[package.metadata.deb]
depends = "$auto"
assets = [
  ["target/release/rick", "usr/bin/", "755"],
  ["packaging/linux/rick.desktop", "usr/share/applications/", "644"],
  ["assets/icons/linux/hicolor/scalable/apps/rick.svg", "usr/share/icons/hicolor/scalable/apps/", "644"],
]

[package.metadata.generate-rpm]
assets = [
  { source = "target/release/rick", dest = "/usr/bin/rick", mode = "755" },
  { source = "packaging/linux/rick.desktop", dest = "/usr/share/applications/rick.desktop", mode = "644" },
  { source = "assets/icons/linux/hicolor/scalable/apps/rick.svg", dest = "/usr/share/icons/hicolor/scalable/apps/rick.svg", mode = "644" },
]
```

What the call adds to that:

- **Version.** The package version is the call's `version`, whatever `Cargo.toml` says. `1.2.3-rc1` becomes `1.2.3~rc1`, which sorts before `1.2.3`. The deb has no revision suffix, so a plugin's `Depends: rick (= 1.2.3)` matches; the rpm's release is `1` unless the metadata sets one.
- **Library dependencies** are found per distro by the tools themselves (`$auto` in cargo-deb, `find-requires` in cargo-generate-rpm), because the build runs in the distro's own image.
- **`runtime-deps`** of the call are added to the dependencies of the metadata, for what the tools cannot see, such as plug-ins loaded at run time.

The package the tools produce has to be named like `app`; the job fails if it is not.

Two things to know about the tools:

- They build with the app's own toolchain, so a toolchain too old for them fails here.
- `cargo-generate-rpm` has no symlinks. An app that keeps its binary in a folder of its own, such as `/usr/lib/<app>/`, puts a small launcher script in `/usr/bin` instead of a link. `tests/fixture-app` shows that layout for both formats.

### A build that is more than `cargo build`

`build-command` is any command: a script of the app's repository that builds, fetches what the app bundles, and lays out a folder. It runs inside the container as root, with these variables set:

| Variable | Example |
| --- | --- |
| `TREBUCHET_TARGET` | `ubuntu-24.04` |
| `TREBUCHET_FORMAT` | `deb` |
| `TREBUCHET_ARCH` | `x86_64` or `aarch64` |
| `TREBUCHET_VERSION` | `1.2.3` |
| `TREBUCHET_TARBALL` | `true` in the one job per architecture whose build also becomes the tarball, `false` in the others |
| `TREBUCHET_DIST` | the folder the job uploads, see [Files the build adds](#files-the-build-adds) |

If the build lays out a folder, name it in `bundle-dir`: the tarball is made from that folder, and the app's `Cargo.toml` assets point into it.

### Files the build adds

The package and the tarball are written to the folder `TREBUCHET_DIST` names, and the job uploads that folder whole. A build command may put files of its own there. They travel with the package: into the job's artifact, to the smoke test, and with `release-tag` onto the release. Trebuchet passes them along and does not look at them.

- **Files that belong to one build.** Some files fit the build they were made with and no other, such as add-ons compiled against it. The tarball is such a build's output too, so they are added where `TREBUCHET_TARBALL` is `true`: once per architecture, from the same build as the tarball.
- **Names.** The files of every job end up side by side, in the release or wherever the caller gathers the artifacts. A name therefore says what the tarball's name says, the version and the architecture, or it is overwritten by its namesake from another job.
- **Plain files, at the top of the folder.** A folder inside it cannot be attached to a release.
- **No second package or tarball.** The smoke test expects one `.deb` or `.rpm` in the folder, and at most one `.tar.gz`.

```bash
if [ "$TREBUCHET_TARBALL" = true ]; then
  cp target/release/addons/*.zip "$TREBUCHET_DIST/"
fi
```

A prebuilt folder runs no build command, so it adds nothing.

### Files from an earlier job

Some files are made once for a release and belong in every package: a generated list of third-party licences, for one. A job of the caller makes them and uploads them as an artifact; the call names the artifact in `build-artifact`, and every build job downloads it before it runs `build-command`:

```yaml
jobs:
  licenses:
    runs-on: ubuntu-24.04
    steps:
      # ... generate THIRD-PARTY-LICENSES.md and third-party.json ...
      - uses: actions/upload-artifact@v7
        with:
          name: third-party-licenses
          path: |
            THIRD-PARTY-LICENSES.md
            third-party.json
  linux:
    needs: licenses
    uses: Open-Breach/trebuchet/.github/workflows/linux-packages.yml@main
    with:
      app: rick
      version: 1.2.3
      build-artifact: third-party-licenses
```

The files land in `working-directory`, or in the folder under it that `build-artifact-path` names. From there the build command copies them into the bundle, or the `Cargo.toml` assets name them directly. An artifact does not keep file modes, so a file that has to be executable is made so by the build command.

A prebuilt folder needs none of this: it is an artifact already and brings its files itself.

## A prebuilt folder

For an app that is built elsewhere in the same run, such as a Flutter build. A job of the caller uploads the folder as an artifact; the call names it:

```yaml
jobs:
  build:
    runs-on: ubuntu-24.04
    steps:
      # ... build, leaving the app in build/bundle/ ...
      - uses: actions/upload-artifact@v7
        with:
          name: bundle
          path: build/bundle/
  linux:
    needs: build
    uses: Open-Breach/trebuchet/.github/workflows/linux-packages.yml@main
    with:
      app: example
      version: 1.2.3
      description: An example app
      build: prebuilt
      artifact: bundle
      runtime-deps: |
        { "debian": ["libgtk-3-0"], "ubuntu": ["libgtk-3-0t64"], "fedora": ["gtk3"] }
```

The folder has the binary at its top level. [`nfpm`](https://nfpm.goreleaser.com) wraps it: the folder goes to `/opt/<app>/`, with a link to its binary in `/usr/bin/`, the desktop entry in `/usr/share/applications/` and the icon under `/usr/share/icons/hicolor/`. Nothing is detected: `runtime-deps` is the whole list of dependencies. A licence text the package has to carry goes into the folder.

An artifact does not keep file modes. The workflow makes the binary executable again; a folder that needs more modes kept is uploaded as a single `.tar` file inside the artifact, which the workflow unpacks.

A prebuilt folder is built once, so the same binary goes into every target's package. It has to run on the oldest of them.

## What comes out

One artifact per target and architecture, named `linux_<app>_<target>_<arch>`, with these files, and with [what the build added](#files-the-build-adds):

| File | Example |
| --- | --- |
| deb | `rick_1.2.3_ubuntu-24.04_amd64.deb` |
| rpm | `rick-1.2.3-1.fedora-45.x86_64.rpm` |
| tarball | `rick-1.2.3-linux-x64.tar.gz`, `rick-1.2.3-linux-arm64.tar.gz` |

The package names carry the target, which is how the publisher finds the suite or repository a file belongs to ([`repositories.md`](repositories.md)).

### The tarball

One per architecture, built by the first target of `targets.json` that the call does not exclude. The list starts with the oldest base, so the tarball links against the oldest glibc of the set.

```
rick-1.2.3-linux-x64/
  rick                              the binary, and whatever bundle-dir holds beside it
  share/applications/rick.desktop   from desktop-file
  share/icons/hicolor/...           from icon
```

Copying `share/` into `~/.local/share/` installs the desktop entry and the icons.

## The release

With `release-tag`, the last job attaches every file of the artifacts to that release of the calling repository, the packages, the tarballs and what the builds added:

- A release that exists for the tag, draft or published, gets the files. A file of the same name is replaced, so a re-run repairs a failed one.
- Where there is no release yet, a **draft** is created for the tag on the run's commit. Publishing it, with its title and notes, is the caller's step, once all of its platforms are attached.

The calling job needs `permissions: contents: write` for this. Nothing is attached unless every smoke test passed.

After the release is published, the app's workflow tells Trebuchet to publish the packages (spec, section 3, release flow).

## Runners

The jobs of a reusable workflow run in the repository that calls it, and that repository's owner decides where:

| Calling repository | x86-64 | arm64 |
| --- | --- | --- |
| belongs to Open-Breach | `depot-ubuntu-24.04-8` | `depot-ubuntu-24.04-arm-16` |
| belongs to anyone else | `ubuntu-24.04` | `ubuntu-24.04-arm` |

The first row is [Depot](https://depot.dev), under the labels Open-Breach's other repositories use; Depot has to be enabled for the calling repository. The second row is GitHub's own runners, so a fork of an app builds without waiting for a runner it does not have.

Two things override the table, the first for a repository and the second for one call:

- the calling repository's variables `RUNNER_LINUX_X64` and `RUNNER_LINUX_ARM64`, or the organisation's;
- the inputs `runner-x64` and `runner-arm64`:

```yaml
    with:
      runner-x64: ubuntu-24.04
      runner-arm64: ubuntu-24.04-arm
```

An input wins over a variable, and a variable over the table. An input that is passed but empty fails the call in its first job.

## Testing a change

`.github/workflows/linux-packages-test.yml` calls the workflow with the app under `tests/fixture-app`, once as a cargo build with every input and once as a prebuilt folder with the fewest. It runs when the workflow, its scripts, `targets.json` or the fixture change, and by hand from the Actions tab. It needs no secret and attaches nothing.

The test names no runners, so in a fork it runs on GitHub's runners by the rule above, with nothing to set.

The scripts are in `.github/scripts/linux-packages/` and run in any container of a target's image; `prepare.sh` holds the pinned versions of cargo-deb, cargo-generate-rpm and nfpm.
