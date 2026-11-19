# The publisher: `publish.yml`

The one workflow that changes what `get.openbreach.dev` serves. It takes the packages of an app release from its GitHub Release and puts them into the apt and dnf repositories. What those repositories look like is in [`repositories.md`](repositories.md); the decisions are in [`spec.md`](spec.md), sections 3 and 4.4.

## What a run does

1. **Checks the request**: the app name, the version and the release URL.
2. **Fetches** the release's packages for that app and version, `<app>_<version>_*.deb` and `<app>-<version>-*.rpm`, and checks that each file holds the package its name says.
3. **Mirrors the pool** of every target from the bucket into an empty directory.
4. **Adds** the new packages and **prunes** every package to its last three versions.
5. **Rebuilds** every apt suite and dnf repository over the whole pool and **signs** them.
6. **Syncs** to the bucket through its S3 API: the packages first, then the indexes with the signed entry points last, then the deletions.

It also puts `install.sh` and the two files of the public key, `keys/openbreach.gpg` and `keys/openbreach.asc`, into the bucket on every run, from the commit the workflow runs at.

One publish runs at a time (`concurrency: publish`). A running publish is never cancelled, and requests that arrive meanwhile wait in line, up to 100 of them.

## What starts it

**An app's release workflow**, after its release is published, with a `repository_dispatch` of type `release`:

```sh
gh api repos/Open-Breach/trebuchet/dispatches \
  -f event_type=release \
  -f 'client_payload[app]=rick' \
  -f 'client_payload[version]=1.2.3' \
  -f 'client_payload[release_url]=https://github.com/Open-Breach/rick/releases/tag/v1.2.3'
```

The token for it is a fine-grained token with *Contents: read and write* on this repository only, kept in the app's repository as the secret `TREBUCHET_DISPATCH_TOKEN`. GitHub has no narrower permission for sending a dispatch.

**By hand**, from the Actions tab, *publish*, *Run workflow*:

- with app, version and release URL: the same as a dispatch. This is how to repeat a publish that failed.
- with all three empty: a republish. Nothing is fetched; the repositories are pruned, rebuilt and signed as they are, and `install.sh` and the key are uploaded again. This is the first run on an empty bucket, and the run after a change to `install.sh`, to `targets.json` or to the key.

Only the workflow on the default branch publishes; a manual run from another branch does nothing.

## What a request has to be

| | Rule |
| --- | --- |
| app | A package name: lowercase letters, digits, `+`, `-`, `.`. |
| version | `X.Y.Z`. A pre-release such as `1.2.3-rc1` is refused: the repositories have one channel, and a pre-release in it would reach every user as an update. |
| release URL | `https://github.com/<owner>/<repository>/releases/tag/<tag>`, with `<owner>` the owner of this repository. Releases of anyone else are refused. |

The release has to be published and readable with this repository's own token, so it is a public repository's. A draft cannot be fetched.

A package for a target that [`targets.json`](../targets.json) does not list fails the run: the app was built with an older or newer Trebuchet than the one publishing.

## Secrets and variables

| Name | Kind | Used for |
| --- | --- | --- |
| `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY` | secret | The bucket-scoped API token, as S3 credentials. |
| `R2_ENDPOINT` | secret | The bucket's S3 endpoint, `https://<account>.r2.cloudflarestorage.com`. |
| `R2_BUCKET` | variable | The bucket's name. |
| `GPG_PRIVATE_KEY` | secret | The armoured secret key, the output of `gpg --export-secret-keys --armor <key>`. |
| `GPG_PASSPHRASE` | secret | Its passphrase. Not set when the key has none. |
| `RUNNER_LINUX_X64` | variable | Another runner label than the default. Not set here: the publisher runs on Depot's `depot-ubuntu-24.04-8`, the label Open-Breach's other repositories use. In a copy of this repository under another owner the default is GitHub's `ubuntu-24.04`. |

Each secret is passed to the one step that needs it. The signing key is imported into a directory of the run, used, and deleted before anything is uploaded. No step prints a secret, and the scripts never put one on a command line.

The key in `GPG_PRIVATE_KEY` has to be the one whose public half is committed under `keys/`. The run checks that twice: when it imports the key, and again on every signature it makes. It also stops if `keys/openbreach.gpg` and `keys/openbreach.asc` are not the same key.

## The bucket

```
install.sh
keys/openbreach.gpg, keys/openbreach.asc
apt/dists/<suite>/...        Cache-Control: public, max-age=60
apt/pool/<suite>/*.deb       no Cache-Control
rpm/<target>/<arch>/*.rpm    no Cache-Control
rpm/<target>/<arch>/repodata/...   Cache-Control: public, max-age=60
```

Index files keep their names while their content changes with every publish, so they are cached for a minute at most. Nothing is purged from the CDN.

What the publisher deletes:

- a package file, only when pruning removed that very file in this run;
- inside `dists/<suite>/` and `repodata/`, whatever the new index no longer has. These directories are rebuilt whole every time.

It never deletes by comparing the pool with the bucket, and it never touches the directories of a target that is not in `targets.json`. A distro release that was dropped keeps its last repository until someone removes it from the bucket by hand.

The files of an index are uploaded one after the other, the signed entry points last. A client that reads the repository in the middle of that can get an index without its matching signature and report a signature or checksum error; the next `apt update` or `dnf` run is past it.

## When a run fails

Nothing a failed run leaves behind needs cleaning up before the next one: every run starts from the bucket's pool and an empty directory.

| The run stopped at | What happened | What to do |
| --- | --- | --- |
| request | The request was refused; the message says why. | Fix the sender, or run by hand with the right values. |
| fetch | The release has no packages for that app and version, or is not readable. | Check the release; then run by hand. |
| signing key | The secret is missing, or is not the published key. | Fix the secret or `keys/openbreach.gpg`; then run by hand. |
| add, prune, index and sign | A package for an unknown target, a wrong passphrase. | As the message says; the bucket is untouched. |
| sync to the bucket | Credentials, or the network. Packages may be up while the index is the old one. | Run again by hand with the same values. Uploading twice is harmless. |

## Testing a change

`tests/test-publish.sh` runs steps 3 to 6 against an S3 server on the same machine, with a throwaway key that takes the path of the real one (an armoured export in `GPG_PRIVATE_KEY`, imported into an empty gpg home). It publishes four releases of the fixture, checks the bucket, and lets the one-line installer install from what the bucket holds in a container of every target. It also covers the request check. See the top of the file for what it needs.

Not covered by any test, because they need the real thing: fetching from a GitHub Release (`fetch.sh`), and R2 itself.
