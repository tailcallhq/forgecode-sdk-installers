# ForgeCode for macOS

A menu-bar-only AppKit application that supervises a local ForgeCode WebSocket service and shows currently running root conversations in a compact native popover. The package targets macOS 13 or later and is SwiftPM-based with no remote package dependencies. The app and DMG contain no service-runtime binary.

## Prerequisites

Building and testing the app needs Xcode 15 or later (Swift 5.9, macOS 13 SDK). Semantic-version parsing and comparison are implemented locally, and the package has no dependencies or `Package.resolved` remote pins, so a clean Swift build and packaging run do not require dependency-network access.

Packaging uses only the local Swift package, packaging templates, and generated image assets. It does not download the service runtime, use a runtime cache or `Vendor` directory, or require runtime-repository credentials. A source scanner rejects remote SwiftPM pins, URLs, and explicit network-capable commands in packaging shell scripts. Packaging also unsets `FORGE_LIVE_RUNTIME_SMOKE` before tests and builds so a developer environment cannot turn a release build into a live runtime download.

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

Unsigned artifacts are written to `dist/unsigned/`; signed/notarized release artifacts are isolated under `dist/signed/`. `package-unsigned.sh` first runs `scripts/test-packaging.sh` and the mandatory Swift tests. It assembles the app and compressed DMG in staging paths, verifies them, and only then atomically publishes each final pathname. Stale app/DMG stages, manifests, checksum temporaries, and unmounted image mounts are cleaned before packaging.

The unsigned path ad-hoc signs the Mach-O executable and then the bundle, verifies that both signatures are specifically ad-hoc, and verifies the bundle seal. Ad-hoc signing supplies integrity metadata only: it carries no publisher identity, is not notarized, and does not make a downloaded app trustworthy. The signed path still replaces those signatures with the configured Developer ID identity before notarization.

Verification uses exact allowlist inventories. The app may contain only its expected directories, executable, complete `Info.plist`, exact eight-byte `PkgInfo`, valid icon, and code-signature resource; it rejects symlinks, unexpected executable bits, unresolved placeholders, additional payloads, and any runtime-named path. The mounted DMG allows only that exact app, `/Applications`, its background, and Finder layout metadata. `manifest.txt` is atomically written with exact keys and compared to the app plist, artifacts, architectures, build flavor, and signature kinds. `SHA256SUMS` contains one strict lowercase SHA-256 entry for every regular file in the app plus the manifest and final DMG; missing, duplicate, extra, unsafe, malformed, or mismatched entries fail verification.

## Install and use

Open the DMG, drag **ForgeCode** to **Applications**, then launch it. The app has no Dock icon or ordinary windows. Clicking the status icon toggles a fixed 288 × 336 pt dark, vibrant popover; clicking elsewhere or pressing **Escape** dismisses it. Global **Command-Q** remains available through the application main menu.

The popover contains:

- a tiny service header with the number of running root conversations;
- a scrollable body;
- a fixed footer with the port, **Open**, and **Refresh**.

The body shows the commands directly: a **Conversations** disclosure row followed by Run ForgeCode Service, Launch at Login and its approval path, Restart ForgeCode Service, Open Logs, Console Origin…, error details when present, and Quit ForgeCode. Nothing is hidden behind an overflow button. Opening the frontend lives solely in the footer **Open** button.

Selecting **Conversations** expands the list in place; the row summarises the current state (`3 running`, `None running`, `Connecting…`) and is inert while the service is off. A back row returns to the commands, and closing the popover always resets to the commands view.

Only root conversations whose SDK status is exactly `running` appear. Titles come from the string `variables.title`, are trimmed, and fall back to **Untitled**. Selecting a row opens that conversation in the default browser.

### Console origin

Conversation links use this default origin:

```text
https://console.forgecode.dev
```

Configure a persistent HTTP or HTTPS origin with **Console Origin…**. For local frontend development, use for example:

```text
http://127.0.0.1:5173
```

The `FORGE_CONSOLE_ORIGIN` environment variable overrides the preference when present. Origins must contain only an `http` or `https` scheme, host, optional port, and root path; credentials, non-root paths, queries, and fragments are rejected. Conversation links are built as `/c/<percent-encoded-conversation-id>`, so conversation IDs cannot inject paths, queries, or fragments.

Both **Open** and conversation links append the running backend endpoint so the frontend connects to this service automatically:

```text
https://console.forgecode.dev/?connect=127.0.0.1:9755
https://console.forgecode.dev/c/<conversation-id>?connect=127.0.0.1:9755
```

The query value always reflects the port the helper actually bound, so a fallback port such as `9755` connects without any manual configuration.

## Service and active-conversation architecture

When **Run ForgeCode Service** first requires the service, ForgeCode installs the runtime under `~/Library/Application Support/ForgeCode/runtime` if it is not already present. Before a newly downloaded runtime is activated, the installer validates the immutable HTTPS release version used for tag and artifact URL selection, checksum sidecar, archive structure, Mach-O architecture, embedded signature structure, signature class, pinned executable identity, and quarantine policy. Installed runtime directories, executables, and receipts use modes `0700`, `0700`, and `0600`. On later lookup or launch, the receipt is metadata and a candidate locator only: stale version/hash fields are allowed, and neither receipt hashes nor executable checksum, Mach-O, signature, inode, size, or original version are revalidated. The managed executable is accepted only through a safe no-symlink path with a private current-owner directory and a current-owner, regular, single-link, non-group/world-writable, owner-executable file. Parent-directory-pinned relative spawning preserves path-race protection while allowing legitimate self-replacement between launches. It then launches the installed runtime as:

```text
forge3 --log-format json ws --addr 127.0.0.1:<first-free-port-from-9753>
```

The ForgeCode installer does not poll for newer runtimes at app startup or in the background. The persisted **Run ForgeCode Service** preference is the desired state. Unexpected exits and readiness failures use bounded exponential restart backoff. Stop and app termination use bounded `TERM`, `KILL`, and child reaping, with best-effort process-group cleanup. The runtime environment is allowlisted instead of copied wholesale, and JSON-aware/text fallback redaction is applied before bounded rotating logs are stored in `~/Library/Logs/ForgeMenuBar/`.

The active app does not poll usage, extensions, models, or providers. It opens an SDK stream using a string request ID and the exact request:

```json
{
  "jsonrpc": "2.0",
  "id": "<string-id>",
  "method": "extension/xstream",
  "params": {
    "conversation_list": {
      "relation": {
        "type": "roots"
      }
    }
  }
}
```

`SdkRpcHandler<HostRequest>` reconstructs the externally tagged host request from the outer RPC method and params. Therefore the one-shot outer method is `extension`, the streaming method is `extension/xstream`, and the inner `conversation_list` tag must remain inside params exactly as shown. The client validates the initial `result.data.stream` pointer against both `extension/xstream` and `request_id`, then accepts only `extension/xstream` notifications for that request with contiguous monotonic sequence IDs. Replacement snapshots are parsed only from:

```text
params.stream.result.extension.conversation_list.conversations
```

Every snapshot is authoritative and replaces the previous active list. Stream errors, completion, malformed sequence, socket failure, and disconnect are interruptions: active rows are cleared and the app reconnects with bounded backoff while the service remains desired and running. Each subscription receives a new request ID. **Refresh** cancels the current subscription, clears its rows, and immediately creates a fresh subscription. Process and subscription generations prevent late frames from superseded work from updating current state. Deliberate stop or disable clears all conversation and stream-derived state.

A one-shot implementation using outer method `extension`, the same externally tagged `conversation_list` roots params, and the exact complete response path is retained as a tested fallback contract, but the active application uses streaming. The obsolete outer methods `conversation_list` and `conversation_list/xstream` are intentionally not accepted.

## Signed release

Create a Developer ID Application certificate and a `notarytool` keychain profile, then run:

```sh
export SIGNING_IDENTITY='Developer ID Application: Example Corp (TEAMID)'
export SIGNING_TEAM_ID='TEAMID'
export NOTARY_PROFILE='forge-menubar-notary'
scripts/release.sh
```

The release pipeline validates the universal application slices, minimum OS, dependencies, and exact runtime-free payload inventory; replaces the development seal by signing the application executable and bundle with hardened runtime; notarizes, staples, and assesses the app and DMG; compares the complete mounted app bundle; validates the `/Applications` symlink; and atomically writes and verifies the exact manifest/checksum inventory plus retained notarization logs. Real signing credentials are not needed for development: `scripts/package-unsigned.sh` runs the ad-hoc validation path.

Useful individual commands are `scripts/assemble-app.sh`, `scripts/sign-app.sh`, `scripts/notarize-app.sh`, `scripts/create-dmg.sh`, `scripts/sign-dmg.sh`, `scripts/notarize-dmg.sh`, and `scripts/verify-release.sh`. `APP_VERSION`, `BUILD_NUMBER`, and `MINIMUM_MACOS_VERSION` accept numeric dot-separated plist versions only.

## Current limitations and security

- The native installer accepts only HTTPS runtime URLs at the configured release origin and limits redirects to that same host, with no credentials, explicit port, or fragment. This same-origin rule narrows redirect and credential-leak risk but does not independently authenticate every object served by a compromised origin; immutable version/tag URL selection, archive checksums, Mach-O validation, signature structure, and configured Developer ID Team ID authentication remain required controls.
- An embedded ad-hoc code signature, when present on a runtime, proves only self-consistency and is not an Apple- or publisher-backed identity. The installer retains the inspected signature class, Team Identifier, and signing identity rather than treating display-name text as provenance; checksum trust and the release origin remain security boundaries. A signed runtime is classified as Developer ID only when Security framework requirement evaluation validates the Apple generic anchor, the Developer ID intermediate certificate OID, and the Developer ID Application leaf certificate OID. Authentication repeats that supported code-signing requirement with the leaf certificate organizational unit bound to the exact explicitly configured Team Identifier. A self-signed or subject-name lookalike certificate is never Developer ID. An unset expected Team ID, missing signature Team ID, mismatch, requirement-construction failure, or requirement-evaluation failure stops before quarantine policy or installation. The production default leaves the expected Team Identifier unset, preserving the current ad-hoc artifact path while failing closed if the distribution changes to Developer ID until its Apple-issued Team Identifier is deliberately configured.
- The public runtime smoke on July 29, 2026 resolves `forge3 0.1.191` and validates installation plus cold cache recovery without an installer `--version` execution. The runtime contains its own update notifier, which is separate from the native installer. Tests assert that current-cache reuse, versioned-cache reuse, and self-updated cold recovery each issue exactly zero `RuntimeNetworkClient` requests. The desktop app neither invokes forge3's update commands nor renders its widgets, but no supported public-release environment variable or launch argument currently disables the launched runtime's own checks. Fully satisfying zero SDK/server update checks therefore requires upstream `forge3` support or a specially built runtime; this repository does not modify the SDK.
- A release cannot be notarized or assessed as Developer ID software without an installed Developer ID Application identity and a valid `notarytool` profile.
- **Temporary explicit ad-hoc runtime trust policy:** the current public `forge3` artifact is ad-hoc signed rather than Developer ID signed/notarized. After the installer validates the immutable HTTPS version/tag selection, checksum sidecar, archive safety, native Mach-O architecture, embedded signature structure, signature class, and stable single-link user-owned executable identity, it inspects quarantine. If and only if the validated signature class is ad-hoc and `com.apple.quarantine` is present, the injected pre-execution trust policy authorizes a fresh same-directory vnode. Descriptor-relative exclusive no-follow operations copy bytes from the pinned validated source vnode, preserve safe executable permissions and unrelated extended attributes, omit only quarantine, synchronize the file and directory, and atomically replace the staged basename. Before installation, the installer captures a new device/inode/size/hash identity and repeats hash, Mach-O, architecture, embedded-signature, ad-hoc-class, identity, and quarantine-absence checks; any failure prevents activation. Developer ID, other signed, unsigned, or already-unquarantined artifacts are not modified. The installer does not remove quarantine in response to runtime launch behavior because it performs no staged runtime execution. This deliberately bypasses Gatekeeper's quarantine-based first-launch assessment only for the exact checksum- and identity-validated ad-hoc artifact; HTTPS origin and checksum integrity are therefore temporary trust boundaries until upstream publishes a properly Developer ID signed and notarized runtime, at which point this exception should be removed.
- The installed runtime owns the selected port after a short bind-probe race; readiness supervision handles a lost race by stopping and retrying on the next available incremental port.
- Process-group cleanup is best effort on macOS. Descendants that deliberately escape the runtime's process group require a privileged service architecture for reliable discovery.
- Active conversations depend on the user's ForgeCode conversation-storage and execute extensions being available through the local service runtime.
- The popover is intentionally fixed at 288 × 336 pt; large active sets scroll, and long titles truncate while remaining available as tooltips.
