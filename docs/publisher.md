# The publisher: `publish.yml`

The one workflow that changes what `get.openbreach.dev` serves. It takes the packages of an app release from its GitHub Release and puts them into the apt and dnf repositories. What those repositories look like is in [`repositories.md`](repositories.md); the decisions are in [`spec.md`](spec.md), sections 3 and 4.4.

In the same run it keeps the plugin registry: the signed list of the plugins the apps publish, with each app's latest version. What the list looks like and what an app attaches for it is in [`registry.md`](registry.md); the decisions are in the spec, section 7. This part is [switched off](#the-plugins-switch) until the repository says otherwise.

## What a run does

1. **Checks the request**: the app name, the version and the release URL.
2. **Fetches** the release's packages for that app and version, `<app>_<version>_*.deb` and `<app>-<version>-*.rpm`, and checks that each file holds the package its name says. With plugins [switched on](#the-plugins-switch), the app's plugin packages of the same version come along: `<app>-plugin-<id>` and the meta package `<app>-plugins` ([`linux-packages.md`](linux-packages.md), *Plugins as packages*). From there on they are packages like any other: the pool, the pruning and the indexes do not tell them apart.
3. **Mirrors the pool** of every target from the bucket into an empty directory.
4. **Adds** the new packages and **prunes** every package to its last three versions.
5. **Rebuilds** every apt suite and dnf repository over the whole pool and **signs** them.
6. **Syncs** to the bucket through its S3 API: the packages first, then the indexes with the signed entry points last, then the deletions.

With plugins switched on, the same run also:

- **Fetches the release's plugins**: the manifests `plugins-<platform>.json` and the files they name. A release without a manifest has no plugins.
- **Reads the registry's index** from the bucket and **verifies** it against `keys/registry.pub`. An index that does not verify stops the run: the publisher signs what it writes, so it only continues a list its key has signed.
- **Merges** the release into the index, with every plugin file checked against the size and the SHA-256 its manifest gives, writes the app's `latest` and **signs** the index. A release only adds: the registry keeps the builds of every release, and their files ([`registry.md`](registry.md), *What stays and what goes*). All of this happens before the first upload of the run, packages included: a file that is wrong leaves the bucket untouched.
- **Syncs the registry** after the packages: the new plugin files, then `registry/index.json` and its signature. Nothing is deleted. Only a run that [removes a release](#removing-a-release) deletes files, and it does so after the index is up.
- **Reads the registry as an app does**, from `get.openbreach.dev`: the index verifies against `keys/registry.pub`, and every plugin file of the release downloads with the size and the SHA-256 the index names. This is `registry/check.sh`, which anyone can run.

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
- with all three empty: a republish. Nothing is fetched; the repositories are pruned, rebuilt and signed as they are, and `install.sh` and the key are uploaded again. This is the first run on an empty bucket, and the run after a change to `install.sh`, to `targets.json` or to the key. The registry is not touched.
- with app and version, and *remove* ticked: the release leaves the plugin registry. This is for a release that was yanked; [Removing a release](#removing-a-release) says what the run does, what it leaves, and what to do after it.

Only the workflow on the default branch publishes; a manual run from another branch does nothing.

## Removing a release

A release that was yanked is taken out of the plugin registry by hand: *publish*, *Run workflow*, with the app, the version and *remove* ticked. No other run takes a build out of the registry: a release only adds.

What the run does:

- The release's builds leave the index, and the new index is signed and uploaded. After that the release's files are deleted from `plugins/<app>/<version>/`. A plugin that no other release carries leaves the index with its last build.
- An app of the removed version then finds no plugin for itself in the registry.
- If the release was the app's `latest`, the index names no latest release afterwards, and the run says so in a warning. The index does not know the release before it.

What it leaves, and what to do then:

- **The release's deb and rpm files stay in the apt and dnf repositories.** A removal touches the registry and nothing else. The packages of the release, the app's own and its plugin packages, are served until three newer versions have pushed them out of the pool ([`repositories.md`](repositories.md)).
- **Publish the previous release again**, by hand, with its app, its version and its release URL. That names it as `latest` again. Its builds are in the index already and are left alone. Until then the registry announces no version of the app, so nobody is told of an update.
- **The cure for a bad release is a new version with the fix.** A removal takes the release back from nobody who has it: an app that was updated keeps running, a package manager does not go back by itself, and the packages stay in the repositories. It only stops the registry from announcing the release and from offering its plugins. What reaches the users is the next version.

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
| `REGISTRY_SIGNING_KEY` | secret | The registry's minisign secret key: the whole contents of the file `minisign -G` wrote. |
| `REGISTRY_SIGNING_PASSWORD` | secret | Its password. Not set when the key was made without one. |
| `PUBLISH_PLUGINS` | variable | `true` switches plugins on: the plugin registry, and the plugin packages in the repositories. Anything else, or nothing: off. |
| `RUNNER_LINUX_X64` | variable | Another runner label than the default. Not set here: the publisher runs on Depot's `depot-ubuntu-24.04-8`, the label Open-Breach's other repositories use. In a copy of this repository under another owner the default is GitHub's `ubuntu-24.04`. |

Each secret is passed to the one step that needs it. The signing key is imported into a directory of the run, used, and deleted before anything is uploaded. No step prints a secret, and the scripts never put one on a command line.

The key in `GPG_PRIVATE_KEY` has to be the one whose public half is committed under `keys/`. The run checks that twice: when it imports the key, and again on every signature it makes. It also stops if `keys/openbreach.gpg` and `keys/openbreach.asc` are not the same key.

The key in `REGISTRY_SIGNING_KEY` has to be the one whose public half is `keys/registry.pub`. `registry/sign.sh` checks every signature it makes against that file and stops when the secret is another key. It writes the secret to a file only inside its own run and deletes it when it ends. The workflow *registry key* asks the same question without publishing anything ([`keys/README.md`](../keys/README.md)).

### The plugins' switch

Everything a run does for plugins happens only where the repository variable `PUBLISH_PLUGINS` is `true`. Without it the run publishes the app's own packages as before and says in a notice that plugins are switched off. It then neither fetches a manifest, nor uses the registry's key, nor writes `registry/` or `plugins/` in the bucket, and it leaves the app's plugin packages on the release: none goes into the apt and dnf repositories. A run that asks to remove a release fails while the switch is off.

Switching it on is one setting: *Settings*, *Secrets and variables*, *Actions*, *Variables*, `PUBLISH_PLUGINS` = `true`. The next release then starts the index and brings its plugin packages. A release that was published while the switch was off gets its plugins published by running the publisher for it again, by hand.

Before the first run with the switch on:

1. Start the workflow *registry key* by hand. It has to pass: the two secrets are then the key of `keys/registry.pub`.
2. Set `PUBLISH_PLUGINS` to `true`.
3. Publish a release, or run the publisher by hand for one that is out. The run's last step reads the registry back from `get.openbreach.dev`.
4. From a checkout, `registry/check.sh https://get.openbreach.dev` reads the whole list and every file it names, with the committed key.

Switching it off again stops the next run from touching the registry. It takes nothing back: what was published stays served until it is removed.

The switch is there to stay. It is how a copy of this repository under another owner publishes its packages without a registry and without a registry key.

## The bucket

```
install.sh
keys/openbreach.gpg, keys/openbreach.asc
apt/dists/<suite>/...        Cache-Control: public, max-age=60
apt/pool/<suite>/*.deb       no Cache-Control
rpm/<target>/<arch>/*.rpm    no Cache-Control
rpm/<target>/<arch>/repodata/...   Cache-Control: public, max-age=60
registry/index.json, registry/index.json.minisig     Cache-Control: public, max-age=60
plugins/<app>/<version>/<file>     Cache-Control: public, max-age=31536000, immutable
```

Index files keep their names while their content changes with every publish, so they are cached for a minute at most. Nothing is purged from the CDN. A plugin file never changes once it is published, and says so.

What the publisher deletes:

- a package file, only when pruning removed that very file in this run;
- inside `dists/<suite>/` and `repodata/`, whatever the new index no longer has. These directories are rebuilt whole every time;
- a plugin file, only in a run that [removes a release](#removing-a-release) from the registry, and then only that release's files. Publishing a release never deletes one: the registry keeps the plugin files of every release. Only a file inside `plugins/<app>/<version>/` is ever deleted this way.

It never deletes by comparing the pool with the bucket, and it never touches the directories of a target that is not in `targets.json`. A distro release that was dropped keeps its last repository until someone removes it from the bucket by hand.

The files of an index are uploaded one after the other, the signed entry points last. A client that reads the repository in the middle of that can get an index without its matching signature and report a signature or checksum error; the next `apt update` or `dnf` run is past it.

The registry's index and its signature are two files as well, uploaded one after the other, and each may sit in a cache for up to a minute. An app that reads in that time can get a list with the signature of the one before. It then refuses the list, keeps the last one that verified, and asks again later. The plugin files are in place before the index names them, and a file that left the index is deleted only after the new index is up.

A plugin file that a failed run uploaded, and that no index names, stays in the bucket. The next run for the same release uploads it again and names it.

### What grows

The package repositories stay the size of three versions of every package. The registry does not: every release of an app with plugins adds its builds to the index and its files to the bucket, and nothing but a removal takes them away.

| | Per release | For Rick, per release |
| --- | --- | --- |
| The index | One build per plugin file, about 400 bytes each as the file is written. | 38 builds: nine plugins on each of the two Linux platforms, ten on macOS and ten on Windows. About 15 KB, about 2 KB compressed. |
| The bucket | The release's plugin files, under `plugins/<app>/<version>/`. | The nine files of one Linux x64 build measured 14.8 MB. The four platforms together come to roughly 60 MB; macOS, Windows and Linux arm64 are not measured. |

A run does not get slower with it. It downloads the index and never the plugin files that are published already, uploads the new files only, and its last step reads back the files of the one release. `registry/check.sh <address>` without an app is what grows: it downloads every file of every release, so name the app and the version to check one.

The run's summary gives the number of builds in the index and its size in bytes. The reader sets the one ceiling: Rick's client takes an index of up to 16 MiB, which at 15 KB a release is more than a thousand releases.

## When a run fails

Nothing a failed run leaves behind needs cleaning up before the next one: every run starts from the bucket's pool and an empty directory.

| The run stopped at | What happened | What to do |
| --- | --- | --- |
| request | The request was refused; the message says why. | Fix the sender, or run by hand with the right values. |
| fetch | The release has no packages for that app and version, or is not readable. | Check the release; then run by hand. |
| signing key | The secret is missing, or is not the published key. | Fix the secret or `keys/openbreach.gpg`; then run by hand. |
| add, prune, index and sign | A package for an unknown target, a wrong passphrase. | As the message says; the bucket is untouched. |
| fetch the release's plugins | A manifest names a file the release does not have, or the release is not readable. | Fix the release; then run by hand. The bucket is untouched. |
| registry: merge and sign | See the three rows below. The bucket is untouched in each. | |
| | A plugin file has another size or SHA-256 than its manifest says, or a manifest is of another app, version or platform. | Fix the release; then run by hand. |
| | The secrets are not the key of `keys/registry.pub`, or the password is wrong. | Fix the secrets; the workflow *registry key* tells when they are right. Then run by hand. |
| | The index in the bucket does not verify against `keys/registry.pub`. Something other than this publisher wrote it, or the key was replaced. | Find out which. To start over, delete `registry/index.json` and its signature from the bucket and run the publisher by hand for every release whose plugins the registry held, oldest first. The index keeps every release, so that is all of them, of every app; each run uploads the release's plugin files again as they are. |
| sync to the bucket | Credentials, or the network. Packages may be up while the index is the old one. | Run again by hand with the same values. Uploading twice is harmless. |
| sync the registry to the bucket | The same. Plugin files may be up while the index is the old one, which names none of them. | Run again by hand with the same values. |
| read the registry as an app does | What `get.openbreach.dev` serves is not what was uploaded: a cache, or the domain. | Run `registry/check.sh https://get.openbreach.dev` a minute later. If it still fails, the message names the file. |

## Testing a change

`tests/test-publish.sh` runs steps 3 to 6 against an S3 server on the same machine, with a throwaway key that takes the path of the real one (an armoured export in `GPG_PRIVATE_KEY`, imported into an empty gpg home). It publishes four releases of the fixture, checks the bucket, and lets the one-line installer install from what the bucket holds in a container of every target. The fourth release prunes the first one's packages and leaves its plugins: the bucket holds the plugin files of all four, and the index names them. It also covers the request check. See the top of the file for what it needs.

It also runs `fetch.sh` and `fetch-plugins.sh` against a stand-in for `gh` that answers from a folder: the app's packages of the version and nothing else, and its plugin packages only where plugins are switched on.

The same test runs the registry's steps with every one of those releases, with a throwaway minisign key that takes the path of the real one. It checks what the bucket holds and with which headers, repeats a release, and sees a run stop with the bucket untouched for a wrong plugin file, for secrets that are another key, for an index that does not verify and for a bucket that does not answer. It publishes an app without plugins, removes a release and sees only that release's files go, and fetches a release's plugins through a stand-in for `gh`. Then it serves the bucket's content on the same machine and reads it with `registry/check.sh`, and sees a list with one byte changed, a list signed with another key and a changed plugin file refused.

Not covered by any test, because they need the real thing: GitHub's own answers to `fetch.sh` and `fetch-plugins.sh`, R2 itself, and `get.openbreach.dev`.
