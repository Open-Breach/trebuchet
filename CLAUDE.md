# Trebuchet

Trebuchet is the public distribution repository of Open-Breach. It holds reusable GitHub Actions workflows that build Linux, macOS and Windows packages for Open-Breach apps, and the publisher that maintains the apt and dnf repositories and the plugin registry on `get.openbreach.dev`.

`docs/spec.md` is the source of truth. Read it before any task.

## Rules

- This repo is public. Nothing secret is ever committed: not in files, workflows, logs, test fixtures or commit messages. That covers private keys, tokens, passwords, API keys, certificates, customer data and anything about flowcpt beyond its package metadata.
- Secrets are referenced by name from GitHub secrets only. A leaked secret is rotated, not just deleted.
- Workflows stay generic across apps. Nothing here may know about one app beyond the examples in `docs/`.
- Workflows must run on fallback GitHub-hosted runners without Depot, so a contributor can test them.
- Scripts are POSIX sh or bash and shellcheck clean. Workflows pass actionlint.
- Keep `docs/` in step with any behaviour change in the same pull request.
- Ask in the issue when the spec does not answer a question. Do not invent.
