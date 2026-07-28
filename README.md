# ForgeCode desktop releases

Desktop packaging for ForgeCode across platforms. Each package embeds a pinned
[`forge3`](https://github.com/tailcallhq/forgecode-sdk) binary and supervises it
as a local WebSocket service.

## Layout

```text
versions.sh   shared APP_VERSION_DEFAULT and pinned FORGE3_VERSION
LICENSE       Apache 2.0
macos/        menu bar app, .dmg              (implemented)
windows/      system tray app, .msi           (planned)
linux/        systemd user service, .deb/.rpm (planned)
```

One git tag releases every platform, so the app version and the pinned `forge3`
tag live in the root `versions.sh`. Only genuinely platform-specific details —
archive filenames and their checksums — live in each platform's own
`scripts/versions.sh`.

## Versioning

`APP_VERSION` and `FORGE3_VERSION` are independent. The app is versioned on its
own timeline so a UI-only fix can ship without a server bump, and a `forge3`
bump alone does not masquerade as a new app release. Updaters compare
`APP_VERSION`, so it must increase on every published build.

`versions.sh` defines `APP_VERSION_DEFAULT`; each platform's build applies the
`APP_VERSION` environment override on top, which is how the release workflow
sets the version from the git tag. It must be a three-component semver such as
`0.1.0` — the app parses it strictly, so a two-component value would build and
then display no version at all.

ForgeCode is pre-1.0 and not a stable release.

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
