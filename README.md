# ForgeCode desktop releases

Desktop packaging for ForgeCode across platforms. Each package embeds a pinned
[`forge3`](https://github.com/tailcallhq/forgecode-sdk) binary and supervises it
as a local WebSocket service.

## Layout

```text
versions.sh   pinned FORGE3_VERSION, from which APP_VERSION derives
LICENSE       Apache 2.0
scripts/      release automation shared by every platform
macos/        menu bar app, .dmg              (implemented)
windows/      system tray app, .msi           (planned)
linux/        systemd user service, .deb/.rpm (planned)
```

One git tag releases every platform, so the pinned `forge3` tag lives in the
root `versions.sh`. Only genuinely platform-specific details — archive
filenames and their checksums — live in each platform's own `scripts/versions.sh`.

## Versioning

**There is one version, and it is the SDK's.** The desktop app releases 1:1
with `forge3`:

```text
SDK v0.1.191  ->  ForgeCode 0.1.191  ->  ForgeCode-0.1.191.dmg  ->  tag v0.1.191
```

`APP_VERSION_DEFAULT` is *derived* from `FORGE3_VERSION` in `versions.sh` and is
never edited by hand — set `FORGE3_VERSION` and everything follows. The app has
no independent version, so it cannot drift from the server it embeds: "which
`forge3` am I running?" is answerable from the app version alone, and a
released SDK can never sit unshipped behind a stale app number.

| Value | Source | Meaning |
| --- | --- | --- |
| `FORGE3_VERSION` | `versions.sh` | The pinned `forge3` tag — the single source of truth |
| `APP_VERSION` | derived | `FORGE3_VERSION` without the `v`, shown as `Version 0.1.190` |
| `BUILD_NUMBER` | `scripts/common.sh` | `CFBundleVersion`, set from the CI run number |

`BUILD_NUMBER` is deliberately *not* the version. Sparkle requires
`CFBundleVersion` to increase monotonically across every published build, and a
tag-derived value alone cannot guarantee that if a tag is ever deleted and
re-released; the CI run number always increases.

`APP_VERSION` may be overridden in the environment for local experiments. It
must be a three-component semver such as `0.1.190` — the app parses it
strictly, so a two-component value would build and then display no version at
all.

ForgeCode is pre-1.0 and not a stable release.

## Release pipeline

Fully automatic from the moment a human publishes an SDK release. Nothing ships
unless a complete, verified package was built first.

```text
  forgecode-sdk                       forgecode-sdk-macos (this repo)
  ─────────────                       ──────────────────────────────
  push to main
       │
       ▼
  release-drafter
  drafts vX.Y.Z
       │
  human publishes  ──[repository_dispatch: sdk-released]──┐
  (the draft is      RELEASES_DISPATCH_TOKEN              │
   now a release)                                         │
                                                          ▼
                                              sdk-released.yml
                                              ├─ validate tag  ^v\d+\.\d+\.\d+$
                                              ├─ release exists & published?
                                              ├─ already tagged? → exit 0
                                              ├─ pin version + checksums
                                              ├─ swift test
                                              └─ package-unsigned.sh  ← the gate
                                                     │            │
                                                 green│            │red
                                                     ▼            ▼
                                          commit + push      open an issue,
                                          tag vX.Y.Z         ship nothing
                                          (REPO_PUSH_TOKEN)
                                                     │
                                          [tag push event]
                                                     ▼
                                              release.yml
                                              ├─ tag == versions.sh?
                                              ├─ sign + notarize, or unsigned
                                              └─ publish GitHub release
                                                 DMG + SHA256SUMS + manifest.txt
```

The tag is pushed with `REPO_PUSH_TOKEN` rather than the default
`GITHUB_TOKEN` because GitHub does not raise workflow events for pushes made
with `GITHUB_TOKEN` — the tag would land and `release.yml` would never run.

That token is supplied to the push command through an ephemeral git credential
helper, not through `actions/checkout`'s `token:` input. Every checkout in this
repository sets `persist-credentials: false`, so no credential is written to
`.git/config`. This matters because these jobs build third-party SwiftPM
dependencies and *execute the `forge3` binary they just downloaded*; a
persisted write-scoped token would turn a compromised SDK release asset into
write access to this repository.

A bump is only accepted if it **strictly advances** the currently pinned
`FORGE3_VERSION` (`sort -V`). Anyone able to mint a `repository_dispatch` could
otherwise replay a genuine *older* release: every other gate would pass, `main`
would be committed backwards, and the resulting release — being the newest
published one — would become `latest` and serve users an older `forge3`. A
deliberate rollback or backfill requires a manual run with
`allow_rollback: true`, which is honoured for `workflow_dispatch` only and can
never be set from a dispatch payload.

### Required secrets

| Secret | Repository | Purpose |
| --- | --- | --- |
| `FORGE3_FETCH_TOKEN` | this repo | Fine-grained PAT / App token with **Contents: read** on `tailcallhq/forgecode-sdk`. Exported as `GH_TOKEN` to download the pinned archives, which are in a private repo. The default `GITHUB_TOKEN` is scoped to this repo and cannot read them. |
| `REPO_PUSH_TOKEN` | this repo | Fine-grained PAT with **Contents: write** on `tailcallhq/forgecode-sdk-macos` only — no other repository, no other permission. Pushes the bump commit and tag so the tag push *triggers* `release.yml`. Injected only into the push step, via a credential helper, never persisted to disk. |
| `RELEASES_DISPATCH_TOKEN` | `tailcallhq/forgecode-sdk` | Fine-grained PAT with **Contents: write** on this repo, used to send the `repository_dispatch`. |

Signing is not yet configured, so releases are currently **unsigned** and
Gatekeeper will block them on first launch. Once the Developer ID certificate
exists, adding these switches `release.yml` to the signed path automatically.
It is all-or-nothing: set every one of them, or none. A partial set fails the
run immediately rather than dying halfway through certificate import, and
rather than silently shipping an unsigned DMG from a repo that meant to sign.

| Secret | Purpose |
| --- | --- |
| `SIGNING_IDENTITY` | Developer ID Application identity name |
| `SIGNING_CERTIFICATE_P12` / `SIGNING_CERTIFICATE_PASSWORD` | base64 `.p12` and its password, imported into a temporary keychain |
| `KEYCHAIN_PASSWORD` | password for that temporary keychain |
| `NOTARY_PROFILE` | `notarytool` profile name |
| `NOTARY_APPLE_ID` / `NOTARY_TEAM_ID` / `NOTARY_PASSWORD` | notarization credentials |

### Manual re-run

Which workflow to re-run depends on how far the release got.

**The tag was never pushed** (checksum resolution, tests or packaging failed —
the failure issue says which). Run the **forge3 released** workflow manually
with the tag, e.g. `v0.1.191`. It is idempotent: if the tag already exists here
it exits cleanly without doing anything.

**The tag was pushed but `release.yml` failed** (build or publish broke after
tagging). Re-running **forge3 released** will *not* help — its idempotency
guard sees the tag and exits. Re-run the failed **Release** run itself, or
dispatch it fresh with `gh workflow run release.yml --ref v0.1.191`.

**A release was skipped entirely.** Two bumps can be in flight at once at most:
a concurrency group holds one running plus one pending run, so if a third SDK
release is published while one is building and another is queued, the middle
one is cancelled and never bumped. It fails quietly — a cancelled run never
reaches the step that files an issue. Recover it with a manual **forge3
released** run; since it no longer advances the pin, it needs
`allow_rollback: true`.

## Building

See each platform's README. For macOS:

```sh
cd macos
swift test
scripts/package-unsigned.sh
```

Packaging downloads the pinned `forge3` from a private repository and therefore
needs an authenticated `gh` CLI or a `GH_TOKEN`/`GITHUB_TOKEN` with `repo`
scope. See `macos/README.md` for details and the offline rebuild path.
