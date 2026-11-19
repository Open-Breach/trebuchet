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

`openbreach.gpg` is `openbreach.asc` run through `gpg --dearmor`, and the two must never drift.

To look at the key yourself:

```sh
gpg --show-keys --with-fingerprint keys/openbreach.asc
```

The private key exists only as the GitHub secret `GPG_PRIVATE_KEY`, with its passphrase in `GPG_PASSPHRASE`. A key that leaks is replaced, not just removed.
