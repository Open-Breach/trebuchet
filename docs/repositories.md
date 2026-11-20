# The apt and dnf repositories

How the package repositories on `get.openbreach.dev` are laid out and which script builds what. The decisions behind it are in [`spec.md`](spec.md), section 4.4.

## Targets

[`targets.json`](../targets.json) is the one place that lists what Trebuchet builds for and publishes to. Everything else reads it: the build matrix of `linux-packages.yml`, the index scripts and the tests.

```json
{
  "arches": [
    { "id": "x86_64",  "deb": "amd64", "rpm": "x86_64",  "tarball": "x64" },
    { "id": "aarch64", "deb": "arm64", "rpm": "aarch64", "tarball": "arm64" }
  ],
  "targets": [
    { "id": "debian-12",    "image": "debian:12",    "format": "deb" },
    { "id": "ubuntu-24.04", "image": "ubuntu:24.04", "format": "deb" },
    { "id": "debian-13",    "image": "debian:13",    "format": "deb" },
    { "id": "ubuntu-26.04", "image": "ubuntu:26.04", "format": "deb" },
    { "id": "fedora-44",    "image": "fedora:44",    "format": "rpm" },
    { "id": "fedora-45",    "image": "fedora:45",    "format": "rpm" }
  ]
}
```

The list follows a rule, not a choice per release:

- **Fedora:** the two newest releases. Today 44 and 45.
- **Debian:** stable and oldstable. Today 13 and 12.
- **Ubuntu:** the two latest LTS releases. Today 26.04 and 24.04.

When a distro ships a release, its line is added and the line the rule no longer covers is removed, in the same change. The targets are listed oldest base first.

- `targets`: one line per distro release. `id` is `<distro>-<version>` and is the name of the apt suite or of the dnf repository; `image` is the official container image the packages are built and smoke-tested in; `format` is `deb` or `rpm`.
- `arches`: one line per architecture, with the name each package format and the tarball use for it.

A new distro release is one new line under `targets`. A release that has left the rule is one line removed: it is no longer built and its repository is no longer rebuilt or signed. What is already in the bucket for it stays there until someone deletes it by hand.

## Layout

Under `https://get.openbreach.dev/`:

```
install.sh                                            the one-line installer
keys/openbreach.gpg                                   the public key, as a keyring for apt
keys/openbreach.asc                                   the same key as text, for dnf
apt/
  dists/<suite>/Release                               one suite per deb target
  dists/<suite>/main/binary-<arch>/Packages{,.gz}     amd64 and arm64 in the same suite
  pool/<suite>/<package>_<version>_<suite>_<arch>.deb
rpm/
  <target>/<arch>/<package>-<version>-<release>.<target>.<arch>.rpm
  <target>/<arch>/repodata/repomd.xml                 one repository per target and architecture
```

The pool is kept per suite because a package is built once per distro release: `rick 1.2.3` for Debian 12 and for Ubuntu 24.04 are two different files with the same package name and version.

## File names

The packages keep the names `linux-packages.yml` gives them, from the GitHub Release into the pool:

| Format | Name | Example |
| --- | --- | --- |
| deb | `<package>_<version>_<target>_<arch>.deb` | `rick_1.2.3_ubuntu-24.04_amd64.deb` |
| rpm | `<package>-<version>-<release>.<target>.<arch>.rpm` | `rick-1.2.3-1.fedora-45.x86_64.rpm` |

The target in the name is how a file finds its suite or repository. The architecture is read from the package itself.

An app's plugin packages are named the same way, with their own package names: `rick-plugin-git_1.2.3_ubuntu-24.04_amd64.deb`, and `rick-plugins_…` for the meta package that depends on all of them ([`linux-packages.md`](linux-packages.md), *Plugins as packages*). In the pool they are packages like any other. Each depends on the app in exactly its own version, and both are pruned to their last three versions, so a plugin package always has its app beside it.

## Scripts

All of them take the root directory of a local copy of the repository and read `targets.json`. They need `jq`; the apt scripts need `dpkg-deb` and `apt-ftparchive` (package `apt-utils`), the rpm scripts `rpm` and `createrepo_c`.

| Script | Does |
| --- | --- |
| `apt/add-packages.sh APT_ROOT FILE.deb...` | Copies each file into `pool/<suite>/`. Refuses a file for a target or architecture that `targets.json` does not list. |
| `apt/build-index.sh APT_ROOT` | Rebuilds `Packages`, `Packages.gz` and `Release` of every suite over its whole pool. |
| `apt/prune.sh APT_ROOT [KEEP]` | Deletes all but the `KEEP` highest versions of every package, per suite and architecture. Default 3. |
| `apt/sign.sh APT_ROOT PUBLIC_KEYRING` | Signs the `Release` file of every suite: `Release.gpg` and `InRelease`. |
| `rpm/add-packages.sh RPM_ROOT FILE.rpm...` | Copies each file into `<target>/<arch>/`; a `noarch` package into every architecture. Same refusals. |
| `rpm/build-index.sh RPM_ROOT` | Rebuilds `repodata/` of every repository over all of its packages. |
| `rpm/prune.sh RPM_ROOT [KEEP]` | Deletes all but the `KEEP` highest versions of every package, per repository and architecture. Default 3. |
| `rpm/sign.sh RPM_ROOT PUBLIC_KEYRING` | Signs the `repomd.xml` of every repository: `repomd.xml.asc`. |

The order is add, prune, build the index, sign. The publisher runs them in that order between a download of the pool from the bucket and an upload of the result ([`publisher.md`](publisher.md)). A target without packages still gets its empty indexes, so `apt update` and `dnf` work against it from the first publish.

## Old versions

The three highest versions of every package stay, so a downgrade by one or two releases works; older files are deleted by the prune scripts. "Highest" is the package manager's own order, `dpkg --compare-versions` for deb and rpm's comparison of epoch, version and release for rpm. A pre-release `1.3.0~rc1` is older than `1.3.0` and counts as a version of its own.

## Signing

One key signs everything, the Open-Breach key whose public half is in [`keys/`](../keys/), as `openbreach.asc` and, in binary form, as `openbreach.gpg`:

| | Signed file | Signature | The user's setting |
| --- | --- | --- | --- |
| apt | `dists/<suite>/Release` | `Release.gpg` (detached) and `InRelease` (clear-signed) | `signed-by=` on the source line |
| dnf | `repodata/repomd.xml` | `repomd.xml.asc` (detached) | `repo_gpgcheck=1` |

`Release` and `repomd.xml` carry the checksums of the indexes, and the indexes carry the checksums of the packages, so the one signature covers every package. The packages themselves are not signed; that is why the dnf repository is set up with `gpgcheck=0` and `repo_gpgcheck=1`.

The sign scripts use the secret key in gpg's keyring, `GNUPGHOME`. A passphrase comes from the environment variable `GPG_PASSPHRASE` and reaches gpg on a file descriptor, never on a command line. With more than one secret key in the keyring, `TREBUCHET_GPG_KEY` names the one to use.

Each signature is checked right away with `gpgv` against `PUBLIC_KEYRING`, the public key that users are given. A repository signed with any other key fails in the script, not on a user's machine.

Rebuilding an index deletes its old signatures, so an index is never left beside a signature that does not belong to it.

## Tests

```sh
sudo apt-get install apt-utils createrepo-c rpm jq gnupg shellcheck
tests/lint-shell.sh       # shellcheck on every script
tests/lint-workflows.sh   # actionlint on every workflow
tests/run.sh              # every tests/test-*.sh
```

`tests/fixture/build.sh` builds the fixture package, a shell script that prints its version, for every target and architecture.

| Test | Checks |
| --- | --- |
| `tests/test-index.sh` | The dry run of the index scripts: the fixture added to an empty pool and indexed, nothing signed. |
| `tests/test-keys.sh` | The committed public key: `keys/openbreach.gpg` is `keys/openbreach.asc` dearmoured, neither holds secret material, and the documentation prints the key's fingerprint. |
| `tests/test-signed-repo.sh` | The whole path with a throwaway key generated in the test: five versions added, pruned to three, indexed, signed, then verified and installed by the real `apt` and `dnf`, each in a container of its target, including a downgrade and the refusal of a wrong key. Run once with an RSA key that has a passphrase and once with an Ed25519 key that has none. Needs docker. |
| `tests/test-install-detect.sh` | Which repository `install.sh` picks, from the `os-release` of every target and of the derivatives in [`install.md`](install.md). A dry run: nothing is installed. |
| `tests/test-install.sh` | The one-liner end to end: the site as it is served (signed repositories, key, `install.sh`) on a local HTTP server, and `curl ... \| sh -s <package>` in a clean container of every target. Needs docker and the network. |
| `tests/test-publish.sh` | The publisher's steps against an S3 server on the same machine: four releases published one after the other, the bucket checked, and the one-line installer run against what the bucket holds. Needs docker, the network, the AWS CLI and moto's S3 server; see the top of the file. |

On a machine whose containers reach the network only through a proxy, `TREBUCHET_TEST_DOCKER_ARGS` adds arguments to the tests' `docker run`.

CI runs the same three commands on every push and pull request (`.github/workflows/ci.yml`). None of them needs a secret. The signing tests use keys they generate in a temporary directory and delete with it; of the real key only the public half is ever read.
