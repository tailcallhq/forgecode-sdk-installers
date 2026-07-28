# ForgeCode for macOS

A menu-bar-only AppKit application that supervises the bundled `forge3` WebSocket service and shows currently running root conversations in a compact native popover. The package targets macOS 13 or later and remains SwiftPM-based with no external dependencies.

## Prerequisites

Building and testing the app needs only Xcode 15 or later (Swift 5.9, macOS 13 SDK). There are no external package dependencies.

Packaging additionally needs credentials, because the pinned `forge3` binaries live in a **private** repository. Provide either an authenticated `gh` CLI or a token:

```sh
gh auth login                 # or:
export GH_TOKEN=<token>       # needs 'repo' scope
```

Without credentials, `scripts/fetch-forge3.sh` fails with an explicit message. To rebuild from an already-downloaded cache, skip the network entirely:

```sh
FORGE3_OFFLINE=1 scripts/package-unsigned.sh
```

## Versioning

The app and the bundled service version independently, both set in `scripts/versions.sh`:

| Variable | Meaning |
| --- | --- |
| `APP_VERSION` | ForgeCode.app's own semver, shown as `ForgeCode 1.0.0` |
| `BUILD_NUMBER` | `CFBundleVersion`; must increase on every published build |
| `FORGE3_VERSION` | Pinned `forge3` release tag, shown as `Server 0.1.190` |

Both are overridable, so a release workflow can set `APP_VERSION`/`BUILD_NUMBER` from the git tag without disturbing the `forge3` pin. Every build records both in `dist/*/manifest.txt`.

## Build and test

```sh
swift test
swift build -c release
```

The distributable is universal (`arm64` + `x86_64`). Build an unsigned app and DMG with pinned `forge3` release binaries:

```sh
scripts/package-unsigned.sh
```

Unsigned artifacts are written to `dist/unsigned/`; signed/notarized release artifacts are isolated under `dist/signed/`. Each output directory includes `manifest.txt` and `SHA256SUMS`. The app helper is assembled at:

```text
ForgeCode.app/Contents/Helpers/forge3
```

`forge3` is pinned in `scripts/versions.sh`. The fetch and packaging scripts validate checksums, archive structure, version, architectures, minimum OS, dependencies, app/DMG payloads, signatures where configured, and guarded output removal. Packaging runs `swift test` as a mandatory step. See **Signed release** below for release credentials and verification.

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

The helper is launched explicitly as:

```text
forge3 --log-format json ws --addr 127.0.0.1:<first-free-port-from-9753>
```

The persisted **Run ForgeCode Service** preference is the desired state. Unexpected exits and readiness failures use bounded exponential restart backoff. Stop and app termination use bounded `TERM`, `KILL`, and child reaping, with best-effort process-group cleanup. The helper environment is allowlisted instead of copied wholesale, and JSON-aware/text fallback redaction is applied before bounded rotating logs are stored in `~/Library/Logs/ForgeMenuBar/`.

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

The release pipeline validates the pinned helper, universal slices, minimum OS and dependencies; assembles and signs nested code with hardened runtime; notarizes, staples, and assesses the app and DMG; compares the complete mounted app bundle; validates the `/Applications` symlink; and writes separately generated and verified manifests/checksums plus retained notarization logs. Real signing credentials are not needed for development: `scripts/package-unsigned.sh` runs the unsigned validation path.

Useful individual commands are `scripts/assemble-app.sh`, `scripts/sign-app.sh`, `scripts/notarize-app.sh`, `scripts/create-dmg.sh`, `scripts/sign-dmg.sh`, `scripts/notarize-dmg.sh`, and `scripts/verify-release.sh`. `APP_VERSION`, `BUILD_NUMBER`, and `MINIMUM_MACOS_VERSION` accept numeric dot-separated plist versions only.

## Current limitations

- A release cannot be notarized or assessed as Developer ID software without an installed Developer ID Application identity and a valid `notarytool` profile.
- The helper owns the selected port after a short bind-probe race; readiness supervision handles a lost race by stopping and retrying on the next available incremental port.
- Process-group cleanup is best effort on macOS. Descendants that deliberately escape the helper's process group require a privileged service architecture for reliable discovery.
- Active conversations depend on the user's ForgeCode conversation-storage and execute extensions being available through the local `forge3` service.
- The popover is intentionally fixed at 288 × 336 pt; large active sets scroll, and long titles truncate while remaining available as tooltips.
