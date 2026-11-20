# registry

Home of the scripts behind the plugin registry: they merge a release's plugins into the registry index, take a yanked release out of it, and sign it (`docs/spec.md`, section 7). The registry keeps the plugins of every release: no script here prunes. The index itself is not in this repository; it lives in the bucket.

| Script | What it does |
| --- | --- |
| `merge.sh SITE APP VERSION RELEASE_URL [INCOMING_DIR]` | Merges one release of an app into the index: its latest version, and the plugins its manifests list. |
| `remove.sh SITE REMOVED_LIST APP VERSION` | Takes one release out of the index and lists its files. |
| `sign.sh FILE` | Signs a file with the registry's minisign key, from the secrets `REGISTRY_SIGNING_KEY` and `REGISTRY_SIGNING_PASSWORD`, writes `FILE.minisig` beside it and checks the signature against `keys/registry.pub`. |
| `check.sh [--index] BASE_URL [APP [VERSION]]` | Reads a registry the way an app does and holds it to what it says: the signature, and the size and SHA-256 of every file. Changes nothing. |
| `lib.sh` | What `merge.sh` and `remove.sh` share. Sourced, not run. |

[`docs/registry.md`](../docs/registry.md) describes the index, the manifest an app attaches to a release, and how to verify the index by hand. [`keys/README.md`](../keys/README.md) says what the key is and how to check that the secrets hold it.
