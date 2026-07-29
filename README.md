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
runtime installation location. Cached installer reuse means exactly zero
`RuntimeNetworkClient` requests: no manifest, archive, checksum, startup, or
background installer request is made after a valid installation exists. Runtime
versions, archives, checksums, manifests, and download credentials are therefore
not packaging inputs. Separately, the launched public `forge3` runtime has its
own internal update notifier. That known SDK limitation is not installer
traffic; see the macOS README for details and the accepted same-origin download
and ad-hoc-signature trust boundaries.

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
