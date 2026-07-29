# ForgeCode desktop releases

Desktop packaging for ForgeCode across platforms. Release packages contain the
ForgeCode application and its local Swift/package assets only; the service
runtime is not embedded in the application or installer image.

## Layout

```text
versions.sh   shared ForgeCode application version
LICENSE       Apache 2.0
macos/        menu bar app, .dmg              (implemented)
windows/      system tray app, .msi           (planned)
linux/        systemd user service, .deb/.rpm (planned)
```

One git tag releases every platform application, so the shared application
version lives in the root `versions.sh`. Platform-specific release settings
live in each platform's own `scripts/versions.sh`.

## Versioning and runtime lifecycle

ForgeCode remains at version `0.1.0`. `versions.sh` defines
`APP_VERSION_DEFAULT`; each platform's build applies an `APP_VERSION`
environment override, which is how a release workflow can set the version from
the git tag. It must be a three-component semver such as `0.1.0` because the app
parses it strictly.

The service runtime has a separate lifecycle from desktop releases. It is first
installed when the user asks ForgeCode to run the service, then reused from its
managed runtime location. The initial install retains network, checksum,
archive, Mach-O, signature, and quarantine validation. Later cache recovery and
launch trust the current managed executable by path and minimal file safety
only, allowing `forge3` to replace itself without stale receipt hashes, versions,
sizes, or inode identity forcing a download. Cached reuse makes exactly zero
`RuntimeNetworkClient` requests. The launched public `forge3` runtime separately
has its own internal update notifier; see the macOS README for details.

ForgeCode is pre-1.0 and not a stable release.

## Building

See each platform's README. For macOS:

```sh
cd macos
swift test
scripts/package-unsigned.sh
```

macOS packaging has no remote SwiftPM dependencies, performs no service-runtime
download, and requires no runtime repository credentials. The packaging source
scanner rejects explicit network commands and remote package references. The
release verifier enforces exact app/DMG inventories, metadata, signatures,
manifest keys, and SHA-256 coverage of every app regular file, the manifest,
and final DMG. Development packages are ad-hoc signed: this detects accidental
mutation but asserts no publisher identity and is not a substitute for the
Developer ID/notarized release path.
