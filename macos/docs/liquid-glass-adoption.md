# Liquid Glass adoption for the menu bar popover

Status: **implemented.** This document records the decision and the research
behind it. The plan below is what was built; `MenuBackdrop.swift` and the
backend branches in `MenuRenderer.swift` are the result.

## Problem

The popover backdrop is an `NSVisualEffectView` with `material = .menu`
(`PopoverController.buildRootView` in `Sources/ForgeMenuBar/MenuRenderer.swift`).
On macOS 26, `NSVisualEffectView` is *not* deprecated but it also does *not*
render Liquid Glass: `.menu`, `.popover`, and `.hudWindow` keep the legacy
frosted blur. The panel therefore looks like a macOS 15 menu sitting next to
system popovers that have adopted the new material, which is the visual
mismatch this work fixes.

The goal is for the panel to match the system's own menu bar popovers (the
volume/Control Center surfaces) on macOS 26, while continuing to look exactly as
it does today on macOS 13–15.

## Decision: build against the macOS 26 SDK, branch with `#available`

Two ways to reach `NSGlassEffectView` from a package whose deployment target is
macOS 13 were considered.

| | A. macOS 26 SDK + `#available` | B. `NSClassFromString` + KVC |
| --- | --- | --- |
| OS version gate | runtime | runtime |
| Symbol exists? | **compile time** (weak-linked) | runtime, silent |
| Property names/types | **compile time** | stringly-typed |
| `style = .regular` | typed enum | guess the raw value |
| Typo in `"cornerRadius"` | build error | silently does nothing |

Both are runtime-gated — a single binary spanning macOS 13 to 26 leaves no other
option. The real difference is that **B deletes the compile-time check** rather
than moving it.

**Path A is chosen.** B was rejected because a failed
`setValue(_:forKey:)` does not throw: the failure mode is a transparent panel
with invisible text, on exactly the OS being targeted, in a signed and notarized
artifact that cannot be reproduced on an older development machine. B is also
invisible to the existing `validate_macho` guardrail (below), and would be
rewritten as soon as the toolchain moved anyway.

### Backward compatibility

Build SDK and deployment target are independent. The already-shipping binary
reads:

```
LC_BUILD_VERSION
  minos 13.0     <- deployment target, from Package.swift .macOS(.v13)
  sdk   15.2     <- build SDK
```

Raising the SDK does not raise `minos`. `NSGlassEffectView` carries availability
metadata, so it is weak-linked: on macOS 13 the symbol resolves to null and
`#available` guarantees it is never touched. No dyld failure. Glass lives inside
AppKit, so no new dylib appears and the `otool -L` allowlist in `validate_macho`
is unaffected.

`scripts/common.sh` already enforces the invariant — `validate_macho` reads
per-arch `minos` and fails the build if it exceeds `MINIMUM_MACOS_VERSION`:

```
version_le "$minos" "$MINIMUM_MACOS_VERSION" || fail "$binary ($arch) requires macOS $minos, above declared $MINIMUM_MACOS_VERSION"
```

So an SDK bump that silently dragged the deployment target upward breaks the
release rather than shipping a binary that will not launch on macOS 13.

## API constraints

`NSGlassEffectView` (macOS 26.0+) exposes `contentView`, `cornerRadius`,
`style` (`.regular` / `.clear`), and `tintColor`. Note `effectIsInteractive`
is **macOS 27**, not 26, and is not usable here.

1. **Content must go through `contentView`.** Apple: "only guarantees the
   `contentView` will be placed inside the glass effect; arbitrary subviews
   aren't guaranteed specific behavior with regard to z-order." The glass view
   must not sit behind content as a sibling.
2. **Corner rounding must use `cornerRadius`.** Not `layer.cornerRadius`, not
   `masksToBounds`, not `maskImage`. Glass samples a region *larger* than
   itself; layer masking clips that sampling region and destroys the
   refraction. `maskImage` remains correct on the `NSVisualEffectView` path.
3. **Glass cannot sample glass.** One glass surface per popover; ordinary
   controls inside it. `NSGlassEffectContainerView` exists to merge *sibling*
   glass views and is not needed for a single backdrop.
4. **`.regular` is the correct style** — the HIG names popovers explicitly.
   `.clear` is for floating over photo/video content.
5. The window must stay `isOpaque = false` with `backgroundColor = .clear`, and
   the shadow must come from `window.hasShadow`. `MenuPanel` already satisfies
   this.

`NSPopover` was reconsidered and rejected again: it picks up system glass for
free, but still forces the callout arrow and would cost the
`.canJoinAllSpaces` / `.fullScreenAuxiliary` collection behavior and the custom
Escape / Command-Q key handling that motivated the borderless panel originally.

`NSHostingView` + SwiftUI `.glassEffect` was also rejected. It is the only route
to *interactive* glass on macOS 26, but this panel has no interactive glass
surfaces, and `NSHostingView` inside a `.nonactivatingPanel` has first-responder
quirks that would fight `MenuPanel.canBecomeKey`.

## What was implemented

### 1. A `MenuBackdrop` factory

The bare `private let backdrop = NSVisualEffectView()` is replaced by a type that
returns either backend and reports which one is active, so the call sites that
need to differ (corner radius, hover highlight) can ask.

`MenuBackdrop.makeRoot(content:)` returns the panel root, and
`MenuBackdrop.Backend.active` reports which material is in play so the call
sites that must follow it — corner radius and the row highlight — branch on one
place instead of repeating the availability check.

`roundedMask(radius:)` moved out of `PopoverController` into `MenuBackdrop`,
since it is now only meaningful on the fallback path.

### 2. Restructured `buildRootView()`

`backdrop` used to *be* the root, with `scrollView` added onto it as a sibling —
which constraint 1 forbids. The hierarchy is now:

```
root (NSGlassEffectView | NSVisualEffectView)
└── contentView   <- plain NSView container
    └── scrollView
        └── document -> bodyStack
```

The body is built first and handed to `MenuBackdrop.makeRoot(content:)`, and the
`widthAnchor` constraint moved from the root onto the body — the glass view
derives its geometry from `contentView`.

### 3. `roundedMask(radius:)` applies to the fallback only

Still needed for `NSVisualEffectView`; never applied on the glass path.

### 4. Corner radius varies by backend

`16` on glass, `10` on the legacy path, via `MenuBackdrop.cornerRadius`. The
`PopoverController.cornerRadius` constant is gone.

### 5. Reworked hover highlight

`CommandRowView.draw(_:)` filled `NSColor.controlAccentColor` fully opaque. The
in-code rationale — a translucent wash looked washed out over
`NSVisualEffectView` — inverts over real glass, where macOS 26 uses a softer
fill with more inset and a larger radius. Glass now uses
`.selectedContentBackgroundColor` at `radius: 8` and `dx: 7`, with
`.selectedMenuItemTextColor` for the label; the legacy path keeps the opaque
accent at `radius: 6` and `dx: 5`.

### 6. Adopted `prefersCompactControlSizeMetrics`

Set on `CommandRowView`. macOS 26 makes small/mini controls taller; Apple names
"complex inspectors and popovers" as the motivating case. `CommandRowView.height`
is pinned at 22pt and `toggleSwitch.controlSize` is `.mini` specifically to fit
it, so without this the `NSSwitch` overflows the row. **This was likely already
affecting shipped builds on macOS 26** — see the CI note below.

Still outstanding: the 22pt row height and the 171pt→220pt `contentWidth` were
both measured from `NSMenu` on macOS 14 and should be re-measured on 26. The
screenshot artifact is the means to check them.

### 7. Build configuration

- **Do not** add `UIDesignRequiresCompatibility`. It is the opt-*out* key (same
  name on macOS, Boolean, ignored from macOS 27 onward); absence means the new
  design.
- `MINIMUM_MACOS_VERSION` / `LSMinimumSystemVersion` stay at `13.0`.
- `.macOS(.v13)` in `Package.swift` stays.
- `README.md` "Prerequisites" claimed Xcode 15 / macOS 13 SDK; updated to
  Xcode 26, since the app target no longer compiles against an older SDK.

## CI

`actions/runner-images` now maps `macos-latest` to **macOS 26 arm64**, with
Xcode 26.6 as default and macOS SDKs 26.0–26.5 installed. `macos-14` is
deprecated.

CI is therefore **already building against a macOS 26 SDK**, which has two
consequences:

- Path A needs no runner change to become possible; `NSGlassEffectView` will
  compile today.
- Standard AppKit components in the popover are *already* rendering with macOS
  26 metrics for users on 26, so item 6 is a live issue rather than a
  hypothetical one.

Pinning is still worth doing, for stability rather than enablement:
`runs-on: macos-26` plus an explicit `xcode-select` is now set in
`.github/workflows/ci.yml` and in both `release.yml` build jobs, so CI and
release cannot silently drift onto a future default (Xcode 27 images already
exist in preview).

## Verification

### Local builds now require macOS 26

Note a consequence: `swift test` builds **every** target, including
`ForgeMenuBar`, so it fails on a host older than macOS 26 even though the tests
themselves only cover `ForgeMenuCore`. `swift build --target ForgeMenuCore`
still works anywhere. This was a deliberate trade for the compile-time symbol
checking that path A buys.

### Reviewing the appearance

The visual result cannot be judged from source, from the unit tests, or on a
host that cannot boot macOS 26. Both materials need reviewing, since the app
supports macOS 13+ and most of that range sees the fallback.

Screenshot capture on CI is tracked separately so that scaffolding stays out of
the shipping target.

Both paths still need checking -- glass on macOS 26, and the unchanged
`NSVisualEffectView` appearance on macOS 13-15.

## References

- <https://developer.apple.com/documentation/appkit/nsglasseffectview>
- <https://developer.apple.com/documentation/appkit/nsglasseffectcontainerview>
- <https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass>
- <https://developer.apple.com/design/human-interface-guidelines/materials>
- <https://developer.apple.com/videos/play/wwdc2025/310/> — Build an AppKit app with the new design
- <https://developer.apple.com/documentation/bundleresources/information-property-list/uidesignrequirescompatibility>
- <https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md>
