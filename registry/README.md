# registry

Home of the scripts behind the plugin registry: they merge a release's plugins into the registry index, prune it and sign it (`docs/spec.md`, section 7). The index itself is not in this repository; it lives in the bucket.

| Script | What it does |
| --- | --- |
| `sign.sh FILE` | Signs a file with the registry's minisign key, from the secrets `REGISTRY_SIGNING_KEY` and `REGISTRY_SIGNING_PASSWORD`, writes `FILE.minisig` beside it and checks the signature against `keys/registry.pub`. |

The scripts that merge and prune come next. `keys/README.md` says what the key is and how to check that the secrets hold it.
