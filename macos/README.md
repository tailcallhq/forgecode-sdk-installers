# ForgeCode for macOS

A menu-bar-only AppKit application that supervises a local ForgeCode WebSocket service and shows its status in a compact native popover. The package targets macOS 13 or later and is SwiftPM-based with no remote package dependencies; the only binary dependency is the Sparkle 2 updater framework, vendored locally as an XCFramework. The app and DMG contain no service-runtime binary.

## Prerequisites

Building and testing the app needs Xcode 15 or later (Swift 5.9, macOS 13 SDK). Semantic-version parsing and comparison are implemented locally, and the package has no remote dependencies or `Package.resolved` remote pins. Before the first build, vendor the Sparkle updater framework once:

```sh
tools/fetch-sparkle.sh
```

The script downloads a version- and SHA-256-pinned Sparkle release archive into `Vendor/Sparkle/` (gitignored) and is the only network step in the entire local workflow; after it completes, clean Swift builds and packaging runs require no dependency-network access.

Packaging uses only the local Swift package, the vendored Sparkle framework, packaging templates, and generated image assets. It does not download the service runtime, use the developer runtime cache, or require runtime-repository credentials. A source scanner rejects remote SwiftPM pins, URLs, and explicit network-capable commands in packaging shell scripts; the checksum-pinned Sparkle fetch deliberately lives outside `scripts/` in `tools/` so packaging itself stays offline. The assembled app embeds a slimmed `Sparkle.framework` (no XPC services, headers, or modules — the app is not sandboxed) at `Contents/Frameworks`. Bundle verification treats the framework as a single opaque, sealed member: it asserts the framework's presence and key executables, while the framework's internal file integrity is guaranteed by the strict deep code-signature verification and the final DMG checksum rather than a per-file inventory. Sparkle checks the appcast feed published with each GitHub release (`SUFeedURL`) and verifies downloaded updates against the EdDSA public key in `SUPublicEDKey` plus the Developer ID signature. Packaging also unsets `FORGE_LIVE_RUNTIME_SMOKE` before tests and builds so a developer environment cannot turn a release build into a live runtime download.

## Versioning

ForgeCode remains at application version `0.1.0`:

| Variable | Defined in | Meaning |
| --- | --- | --- |
| `APP_VERSION` | `../versions.sh` | ForgeCode's own semver, shown as `ForgeCode 0.1.0` |
| `BUILD_NUMBER` | `scripts/common.sh` | `CFBundleVersion`; must increase on every published build |

`APP_VERSION` and `BUILD_NUMBER` are overridable so a release workflow can set them from the application release tag. Every build records the application version, build number, minimum macOS version, build flavor, and application executable architectures in `dist/*/manifest.txt`.

The service runtime is not versioned or pinned by these packaging scripts. It is first installed when the service is needed and then reused from its managed runtime location. Initial installation performs the full download and artifact validation policy. Cached lookup, recovery, and launch make zero `RuntimeNetworkClient` requests and intentionally allow a safe current `forge3` file to differ from stale receipt version/hash/identity metadata after self-update. The launched public `forge3` process separately contains its own update notifier; see **Current limitations**.

Versions are parsed and compared with the local strict Semantic Versioning 2.0.0 implementation. A single leading `v` and surrounding whitespace are tolerated at the app boundary; all three numeric components are required, leading zeroes and malformed identifiers are rejected, prerelease precedence follows SemVer, and build metadata is ignored when comparing.

## Build and test

```sh
swift test
swift build -c release
```

The distributable is universal (`arm64` + `x86_64`). Build an unsigned app and DMG from local Swift/package assets:

```sh
scripts/package-unsigned.sh
```

Unsigned artifacts are written to `dist/unsigned/`; Developer ID-signed release artifacts are isolated under `dist/signed/`. `package-unsigned.sh` first runs `scripts/test-packaging.sh` and the mandatory Swift tests. It assembles the app and compressed DMG in staging paths, verifies them, and only then atomically publishes each final pathname. Stale app/DMG stages, manifests, checksum temporaries, and unmounted image mounts are cleaned before packaging.

The unsigned path ad-hoc signs the Mach-O executable and then the bundle, verifies that both signatures are specifically ad-hoc, and verifies the bundle seal. Ad-hoc signing supplies integrity metadata only: it carries no publisher identity, is not notarized, and does not make a downloaded app trustworthy. The signed path still replaces those signatures with the configured Developer ID identity before notarization.

Verification uses exact allowlist inventories. The app may contain only its expected directories, executable, complete `Info.plist`, exact eight-byte `PkgInfo`, valid icon, and code-signature resource; it rejects symlinks, unexpected executable bits, unresolved placeholders, additional payloads, and any runtime-named path. The mounted DMG allows only that exact app, `/Applications`, its background, its volume icon, and Finder layout metadata. `manifest.txt` is atomically written with exact keys and compared to the app plist, artifacts, architectures, build flavor, and signature kinds. `SHA256SUMS` contains one strict lowercase SHA-256 entry for every regular file in the app plus the manifest and final DMG; missing, duplicate, extra, unsafe, malformed, or mismatched entries fail verification.

## Install and use

Open the DMG, drag **ForgeCode** to **Applications**, then launch it. The app has no Dock icon or ordinary windows. Clicking the status icon toggles a fixed 288 × 336 pt dark, vibrant popover; clicking elsewhere or pressing **Escape** dismisses it. Global **Command-Q** remains available through the application main menu.

The popover contains:

- a tiny service header with the current service state and the **Open** button;
- a scrollable body.

The body shows the commands directly: Launch at Login and its approval path, error details when present, and Quit. Nothing is hidden behind an overflow button. Opening the frontend lives solely in the header **Open** button.

The service is not a user-facing toggle. It starts with the app and stops when the app quits, so there is no Run or Restart command; quitting and reopening ForgeCode restarts it.

### Console origin

The **Open** link uses this default origin:

```text
https://console.forgecode.dev
```

Set the `FORGE_CONSOLE_ORIGIN` environment variable to override it. For local frontend development, use for example:

```text
FORGE_CONSOLE_ORIGIN=http://127.0.0.1:5173
```

There is no persisted origin preference and no in-app editor; the environment variable is the only override. Origins must contain only an `http` or `https` scheme, host, optional port, and root path; credentials, non-root paths, queries, and fragments are rejected.

**Open** appends the running backend endpoint so the frontend connects to this service automatically:

```text
https://console.forgecode.dev/?connect=127.0.0.1:9755
```

The query value always reflects the port the helper actually bound, so a fallback port such as `9755` connects without any manual configuration.

## Service architecture

When the app launches and first requires the service, ForgeCode installs the runtime under `~/Library/Application Support/ForgeCode/forge3` if it is not already present by downloading and running forge3's upstream cargo-dist shell installer from `https://install.forgecode.dev/server` via `/bin/sh`. The app is a thin wrapper: it sets `FORGE3_INSTALL_DIR` to that fixed directory (binary lands at `<dir>/bin/forge3`), `FORGE3_NO_MODIFY_PATH=1` so no shell rc files are touched, and `FORGE3_PRINT_QUIET=1`. The managed install still writes forge3's receipt at `~/.config/forge3/forge3-receipt.json` so forge3's own axoupdater-based self-update keeps working. The installer script is fully trusted: the app performs no checksum, signature, or Mach-O verification. As the only Gatekeeper workaround, `com.apple.quarantine` is best-effort removed from the installed binary. Set `FORGE_UPDATE_INSTALLER_URL` to override the installer script source (e.g. a local `http://127.0.0.1:9877/install.sh`). The app locates the binary by the exact path `<dir>/bin/forge3` and launches it as:

```text
forge3 --log-format json ws --addr 127.0.0.1:<first-free-port-from-9753>
```

### Running a locally built runtime (debug builds only)

Set `FORGE_RUNTIME_BINARY` to an absolute path to launch your own `forge3` instead of running the upstream installer. No download or install step runs:

```text
FORGE_RUNTIME_BINARY=/path/to/forge3 .build/debug/ForgeMenuBar
```

This is compiled out of release builds — `DeveloperRuntimeOverride.resolve` returns `nil` unconditionally when `DEBUG` is not defined, so a shipped app cannot be redirected to an arbitrary binary. An unset variable is ignored; a variable that is set but does not point at an executable regular file fails loudly rather than silently falling back to running the installer. The override must be an absolute path to an executable regular file and reports version `0.0.0` so it never registers as an upgrade.

Debug environment variables are forwarded from the app's environment to the forge3 child process: `FORGE_UPDATE_CURRENT_VERSION`, `FORGE_UPDATE_MANIFEST_URL`, `FORGE_UPDATE_INSTALLER_URL`, `FORGE_CONSOLE_ORIGIN`, and `FORGE3_API_KEY`.

Because a GUI launch from Finder or Dock does not inherit your shell environment, this variable — like `FORGE_CONSOLE_ORIGIN` — is only visible when the executable is launched directly from a terminal.

The app does not poll for newer runtimes at startup or in the background and performs no explicit update checks. forge3 self-updates by re-running its installer in place and exiting; the app simply restarts the binary whenever it exits (an exit status of `75` on the first attempt restarts immediately, which is how a self-update is picked up). The app's own lifetime is the desired state: the service is started at launch and stopped on termination. Unexpected exits and readiness failures use bounded exponential restart backoff. forge3 is spawned in its own process group; stop and app termination use bounded `TERM`, `KILL`, and child reaping against that group so no orphan processes survive the app. The runtime environment is allowlisted instead of copied wholesale, and JSON-aware/text fallback redaction is applied before bounded rotating logs are stored in `~/Library/Logs/ForgeMenuBar/`.

The active app does not poll usage, extensions, models, or providers. Readiness and health are probed with a single one-shot `rpc.discover` request per lifecycle: a successful round trip marks the service ready, and `result.data.complete["rpc.discover"].info.version` supplies the server version shown in the header. Failures inside the readiness window retry on a short poll interval; persistent failure fails the lifecycle and triggers a supervised restart. Process and probe generations prevent late responses from superseded work from updating current state. Stopping the service clears all service-derived state.

## Signed release

Create a Developer ID Application certificate, then run the local build/sign stage:

```sh
export SIGNING_IDENTITY='Developer ID Application: Example Corp (TEAMID)'
export SIGNING_TEAM_ID='TEAMID'
scripts/release.sh
```

The release pipeline validates the universal application slices, minimum OS, dependencies, and exact runtime-free payload inventory; replaces the development seal by signing the application executable and bundle with hardened runtime; creates and signs the DMG; compares the complete mounted app bundle; validates the `/Applications` symlink; and atomically writes and verifies the exact manifest/checksum inventory. CI submits only the signed DMG from Linux with pinned `rcodesign`, waits for Apple acceptance, then returns to macOS to staple and comprehensively validate the final DMG before uploading it and the optional final appcast to the draft release. Real signing credentials are not needed for development: `scripts/package-unsigned.sh` runs the ad-hoc validation path.

Useful individual commands are `scripts/assemble-app.sh`, `scripts/sign-app.sh`, `scripts/create-dmg.sh`, `scripts/sign-dmg.sh`, `scripts/staple-dmg.sh`, and `scripts/verify-release.sh`. `APP_VERSION`, `BUILD_NUMBER`, and `MINIMUM_MACOS_VERSION` accept numeric dot-separated plist versions only.

## Current limitations and security

- The runtime is installed by downloading and executing forge3's upstream cargo-dist shell installer. The app performs no checksum, signature, Mach-O, or launch-security verification of the installer or the resulting binary — the installer script and the machine are fully trusted. Trust rests entirely on the HTTPS origin serving the installer script (`https://install.forgecode.dev/server`, overridable via `FORGE_UPDATE_INSTALLER_URL` for testing).
- As the only Gatekeeper workaround, the app best-effort removes `com.apple.quarantine` from the installed `forge3` binary. The installer script itself is executed via `/bin/sh` (interpreted, not a Gatekeeper-assessed Mach-O launch).
- The app performs no explicit runtime update checks. forge3 self-updates by re-running its own installer and replacing its binary in place, then exiting; the app relaunches on exit. This is the entire update mechanism from the app's perspective and is fully separate from the app's own Sparkle-based self-updates.
- A release cannot be notarized or assessed as Developer ID software without an installed Developer ID Application identity and a valid `notarytool` profile.
- The installed runtime owns the selected port after a short bind-probe race; readiness supervision handles a lost race by stopping and retrying on the next available incremental port.
- Process-group cleanup is best effort on macOS. Descendants that deliberately escape the runtime's process group require a privileged service architecture for reliable discovery.
- The popover is intentionally fixed in size; overflowing content scrolls, and long text truncates while remaining available as tooltips.
