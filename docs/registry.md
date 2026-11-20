# The plugin registry

One signed list of the plugins that Open-Breach's apps publish, with each app's latest version beside them. The decisions are in [`spec.md`](spec.md), section 7; this page is what an app has to attach to a release, what the list looks like, how to verify it, and which script does what.

The list is served at `https://get.openbreach.dev/registry/index.json`, with its signature beside it as `index.json.minisig`. The copy in the bucket is the only one. The publisher reads it, changes it and writes it back; nobody edits it by hand.

## What an app attaches to a release

An app with plugins attaches, for each platform, the plugin files and one manifest named `plugins-<platform>.json`:

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

| Field | Rule |
| --- | --- |
| `app` | The app's package name, the one the publisher is told. |
| `app_version` | The release, `X.Y.Z`: exactly the version the publisher is told. |
| `platform` | The platform as the app names its release archives, and as the manifest's file name has it. Lowercase letters, digits and `-`. |
| `id` | Unique within the manifest. Lowercase letters, digits, `.`, `_` and `-`. |
| `name` | One line of text. |
| `description` | Text. May be missing or empty. |
| `version` | The plugin's own version. |
| `api_version` | A whole number: the app's plugin interface version at this release. |
| `meta` | An object of the app's own. It is copied into the list and never read. May be missing. |
| `file` | The name of the file on the release: a plain file name. No two manifests of a release name the same file, because the files of every platform lie in one folder. |
| `size`, `sha256` | The file's size in bytes and its SHA-256, in hexadecimal. |

A release without a manifest has no plugins. It still gets its `latest`.

A file that is not on the release, or that has another size or another SHA-256 than its manifest says, stops the publisher before it writes anything. So does a manifest of another app, version or platform than the release and its file name say.

## The list

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

- **`latest`** is the app's newest release: its version and the address of its release page. Every release of any app writes it. A release that is published again after a newer one does not take it back.
- **A plugin** has its `id`, `name`, `description`, `publisher` and `meta`, and its builds. Name, description and `meta` are those of the newest release that carries the plugin. Where the manifests of one release differ, the first platform by name gives them. `publisher` is the owner of the repository the publisher runs in.
- **A build** is one file for one platform, made with one release of the app. Its file is at `plugins/<app>/<app_version>/<file>` under the same address as the list.
- **What exists, not what fits.** Which build a running app takes is the app's rule. There are no version ranges.
- **Order.** The apps stand in the order of their names, the plugins of their ids, and a plugin's builds from the oldest release to the newest. The same content is the same file, apart from `generated`.
- **An app without plugins** has `latest` and no `plugins`.
- A reader ignores what it does not know, and the publisher keeps what it does not know: a field of the list, of an app or of a plugin that a later version adds survives a run of an earlier one. `schema` goes up only for a change an old reader cannot ignore, and this publisher does not touch a list of a higher schema than its own.

### What stays and what goes

- **A build that is already in the list is left alone.** A build is the same when plugin, plugin version, app version and platform are the same. Publishing a release twice changes nothing but `generated`.
- A published file never changes. Where a release is published again with another file under the same name, the list keeps the build it has and the run says so with a warning. To replace it, the release is removed and published again.
- **Every release stays.** The list keeps the builds of every release of an app, and the bucket keeps their files, so an app of any released version still finds the plugins that were built for it. Nothing is pruned here. That is the registry's rule alone: the apt and dnf repositories keep the last three versions of a package ([`repositories.md`](repositories.md)).
- A release that is published late, after a newer one, is added where its version belongs. It does not become `latest`, and it does not give a plugin its name or description.
- A plugin that later releases no longer carry stays in the list, with the builds of the releases that carried it and the name, description and `meta` of the newest of them.
- **A release that was yanked** is removed by name, and that is the only way a build leaves the list and a file leaves the bucket. Its builds and files go. A release is known by its builds. A plugin whose last build leaves, leaves with it. If the release was the app's `latest`, `latest` goes too: the list does not know the release before it. Publishing that release again names it. [`publisher.md`](publisher.md#removing-a-release) has the steps, and what a removal does not do.

What this adds to the list and to the bucket with every release is in [`publisher.md`](publisher.md#what-grows).

## Verifying the list

The list is signed with a dedicated Ed25519 key in [minisign](https://jedisct1.github.io/minisign/) format. Its public half is [`keys/registry.pub`](../keys/registry.pub); [`keys/README.md`](../keys/README.md) says more about the key. To verify by hand:

```sh
curl -fsSLO https://get.openbreach.dev/registry/index.json
curl -fsSLO https://get.openbreach.dev/registry/index.json.minisig
minisign -Vm index.json -p keys/registry.pub
```

The plugin files are not signed one by one. The signed list carries the size and the SHA-256 of each, and an app checks every download against them:

```sh
jq -r '.apps.rick.plugins[].builds[] | "\(.sha256)  \(.url)"' index.json
```

An app that reads the registry compiles the public key in and refuses a list whose signature does not verify. The signature is the kind minisign makes today, over the file's hash. The legacy kind is never made: Rick's client refuses it.

`registry/check.sh` does all of the above in one go, from a checkout of this repository:

```sh
registry/check.sh https://get.openbreach.dev              # the list, and every file it names
registry/check.sh https://get.openbreach.dev rick 0.6.0   # the list, and the files of one release
registry/check.sh --index https://get.openbreach.dev      # the list alone
```

## How it is published

The publisher, `publish.yml`, runs the scripts below in the same run in which it publishes the release's packages: [`publisher.md`](publisher.md) has the steps, the switch that turns the registry on, and what to do when a run fails.

## Scripts

All in `registry/`. They need `jq`; `sign.sh` needs `minisign` 0.10 or newer. `SITE` is a local copy of what is served: the list is `SITE/registry/index.json`, and the plugin files are under `SITE/plugins/`.

| Script | Does |
| --- | --- |
| `merge.sh SITE APP VERSION RELEASE_URL [INCOMING_DIR]` | Merges one release into the list. Checks every file the manifests in `INCOMING_DIR` name, adds the builds that are new, copies their files to `SITE/plugins/<app>/<version>/` and writes `latest`. Without `INCOMING_DIR`, or without a manifest in it, only `latest`. |
| `remove.sh SITE REMOVED_LIST APP VERSION` | Takes one release out of the list. Appends the paths of its files to `REMOVED_LIST`. A release the list has nothing of is an error. |
| `sign.sh FILE` | Signs with the key of the secrets `REGISTRY_SIGNING_KEY` and `REGISTRY_SIGNING_PASSWORD`, writes `FILE.minisig`, and checks the signature against `keys/registry.pub`. |
| `check.sh [--index] BASE_URL [APP [VERSION]]` | Reads a registry as an app does: fetches the list and its signature, verifies them against `keys/registry.pub`, downloads the files the list names and compares each with its size and SHA-256. Changes nothing. |

`merge.sh` reads two settings from the environment: `REGISTRY_BASE_URL`, the address `SITE` is served at, by default `https://get.openbreach.dev`; and `REGISTRY_PUBLISHER`, by default the owner of the repository the workflow runs in.

No script prunes: `merge.sh` only adds, and `remove.sh` is the one that takes anything out.

A script that fails leaves the list as it was. A path in `REMOVED_LIST` is always a file inside `plugins/<app>/<version>/` of the build it belonged to; a build whose address points anywhere else stops the script, and nothing is named for deletion.

## Testing a change

`tests/test-registry.sh` runs the scripts on releases of a made-up app, which `tests/fixture/plugins.sh` writes: a first release, the same release again, more releases with the first one still there, a release that comes late, a plugin that later releases drop, files and manifests that are wrong, an app without plugins, and releases that are removed. It signs with a throwaway key made in the test and verifies with `minisign`. `tests/test-registry-key.sh` covers `sign.sh`. `tests/test-publish.sh` runs the publisher's steps against a bucket on the same machine and reads the result with `check.sh`: after four releases the first one's packages are pruned from the repositories, and its plugins are still listed and served. None of them uses the real key.
