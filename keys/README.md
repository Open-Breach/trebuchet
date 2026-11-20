# keys

The public keys of Open-Breach's distribution. Nothing else lives here, and no private key ever does.

## The package repositories

`openbreach.asc` and `openbreach.gpg` are the public half of the key that signs the apt `Release` files and the dnf `repomd.xml` on `get.openbreach.dev`.

- Identity: `Open-Breach Packages <packages@openbreach.dev>`, RSA 4096, no expiry.
- Fingerprint: `4EBA 5A09 2189 11BE B9E2 06E0 2A5A 0A8C E695 300A`

They are the same key in two forms:

| File | Form | Who reads it |
| --- | --- | --- |
| `openbreach.asc` | ASCII-armoured text | dnf, through `gpgkey=` |
| `openbreach.gpg` | binary keyring | apt, through `signed-by=`; a `.gpg` file has to be binary there |

`openbreach.gpg` is `openbreach.asc` run through `gpg --dearmor`, and the two must never drift. `tests/test-keys.sh` checks that on every push, along with the fingerprint above and that neither file holds anything secret.

The publisher serves both as they are, at `https://get.openbreach.dev/keys/openbreach.asc` and `https://get.openbreach.dev/keys/openbreach.gpg`, and checks every signature it makes against `openbreach.gpg`.

To look at the key yourself:

```sh
gpg --show-keys --with-fingerprint keys/openbreach.asc
```

The private key exists only as the GitHub secret `GPG_PRIVATE_KEY`, with its passphrase in `GPG_PASSPHRASE`. A key that leaks is replaced, not just removed.

## The plugin registry

`registry.pub` is the public half of the key the plugin registry's index is signed with: `https://get.openbreach.dev/registry/index.json`, whose signature stands beside it as `index.json.minisig`. It is an Ed25519 key in minisign format, separate from the key of the package repositories above, and it signs the index and nothing else. The plugin files are not signed one by one; the signed index carries their SHA-256 (`docs/spec.md` 7.5).

- Key id: `197B77080066F36E`, as the comment line of the file names it and as every signature of the key carries it.

Rick carries a copy of this file, compiled in: `crates/plugins-registry/keys/registry.pub` in `Open-Breach/rick`. A Rick checks the index against that copy and refuses a list that does not verify. Replacing the key therefore makes every installed Rick refuse the list, because none of them has the new one. So this file is never replaced without a Rick release that carries the new key first.

The private key exists only as the GitHub secret `REGISTRY_SIGNING_KEY`, the whole contents of the file `minisign -G` wrote, with its password in `REGISTRY_SIGNING_PASSWORD`. `registry/sign.sh` is the one script that reads them. It checks every signature it makes against `registry.pub` and stops when the secret is another key.

Whether the two secrets are this key can be asked at any time: the workflow *registry key* (`.github/workflows/registry-key.yml`), started by hand from the Actions tab, signs a throwaway line of text with them and verifies the signature against `registry.pub`. It publishes nothing. `tests/test-registry-key.sh` holds the file itself to its form on every push: a minisign public key whose id is the one above, and nothing secret.
