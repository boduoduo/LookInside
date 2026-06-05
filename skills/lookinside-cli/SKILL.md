---
name: lookinside-cli
description: Use this skill when working with the LookInside command-line tool or embedding the LookinServer runtime into a host app. Trigger on requests involving `lookinside list`, `inspect`, `hierarchy`, `attrs`, `ivars`, `swiftui-debug`, `vc`, `export`, target IDs, hierarchy trees, hierarchy JSON payloads, SwiftUI view debug data, view controller queries, packaging `LookinServerDynamic`, or porting a Lookin-style integration from iOS/macOS to another platform such as Android or HarmonyOS.
---

# LookInside CLI and Integration

Use the repository's CLI to inspect live macOS, iOS Simulator, and USB-connected targets, and use the same repository to embed or package `LookinServer` for host apps.

## Quick Start

The CLI is installed at `/usr/local/bin/lookinside` (built from this repo and symlinked or copied). All commands below use `lookinside` directly — no path prefix needed.

If the binary isn't installed yet, build a release binary and link it:

```bash
swift build --product lookinside -c release
ln -sf "$(pwd)/.build/release/lookinside" /usr/local/bin/lookinside
lookinside --help   # verify
```

## OID Convention

The hierarchy tree prints each node as `ClassName#<N>/L<M>`:

- `#N` — **object OID**: the Swift/ObjC object identifier
- `L<M>` — **layer OID**: the backing CALayer identifier

| Subcommand | Which OID to pass |
|---|---|
| `swiftui-debug --oid` | **`#N`** (object OID) — must resolve to the NSHostingView/UIHostingView *object* |
| `attrs --oid` | **`L<M>`** (layer OID) — resolves to the CALayer |
| `ivars --oid` | **`L<M>`** (layer OID) |
| `vc --oid` | **either** `#N` or `L<M>` — walks up to find the hosting VC |

> ⛔ **Passing a layer OID to `swiftui-debug` silently fails** — `makeViewDebugData` is called on the backing `NSViewBackingLayer`, not the hosting view, and returns `{"className":"NSViewBackingLayer"}` with no `viewDebugData`. Always use the `#N` number for `swiftui-debug`.

Example: from `_TtGC7SwiftUI13NSHostingView...#26/L27` use `--oid 26` for `swiftui-debug`, `--oid 27` for `attrs`.

## CLI Workflow

### 1. Discover targets

Start with `list`. It is also the default subcommand.

Use text mode for quick terminal inspection:

```bash
lookinside list
```

Use JSON when you need a stable shape for docs, parsing, or follow-up automation:

```bash
lookinside list --format json
```

Useful filters:

- `--transport mac`, `--transport simulator`, or `--transport usb`
- `--name-contains <text>`
- `--bundle-id <bundle-id>`
- `--ids-only` for text mode pipelines

`targetID` values are runtime-discovered opaque strings like `mac:47170:7268387651031256382` or `simulator:47164:1774294178`.

### 2. Inspect one target

Use `inspect` to print metadata for a target returned by `list`.

```bash
lookinside inspect --target <id>
lookinside inspect --target <id> --format json
```

Prefer JSON when the user asks what fields exist or wants machine-readable output.

### 3. Fetch a live hierarchy

Use tree mode for human-readable terminal output:

```bash
lookinside hierarchy --target <id>
```

Use JSON for structured analysis:

```bash
lookinside hierarchy --target <id> --format json
```

Use `--output` when the result is too large for the terminal or the user wants an artifact:

```bash
lookinside hierarchy --target <id> --output /tmp/sample-tree.txt
```

### 4. Inspect SwiftUI hosting views (`swiftui-debug`)

Use `swiftui-debug` to extract SwiftUI's internal view-debug data (the same payload Xcode's View Debugger consumes) for any `NSHostingView` / `_UIHostingView` instance. **Works on macOS, iOS, tvOS, visionOS** as of 2025-05.

```bash
# Find a HostingView OID first — use the #N (object OID), NOT the L<M> (layer OID)
lookinside hierarchy --target <id> | grep -i hosting

# Three output modes (mutually exclusive)
lookinside swiftui-debug --target <id> --oid <hosting-oid>           # raw JSON (~50MB)
lookinside swiftui-debug --target <id> --oid <hosting-oid> --summary # flat table
lookinside swiftui-debug --target <id> --oid <hosting-oid> --items   # JSON array
```

Mode selection:

- `--summary` — humans want a single-screen view of frame / fill / corner / font / colour / text content
- `--items`   — scripts that need typed columns plus an `extras` dict for un-projected tokens
- _(no flag)_ — full Apple JSON; use only when chasing fields the parsers above don't surface (NamedColor tokens, NamedImage asset names, modifier chains, full AX tree)

#### macOS CGDrawingLayer fallback (automatic)

On macOS, SwiftUI sometimes renders text via `CGDrawingLayer` instead of emitting `display-list-item` s-expressions. When `--summary` detects no display-list items, it automatically falls back to parsing NSFont-tagged attributed-string descriptions from `viewDebugData`.

In fallback mode:
- `--summary` shows a narrower table: `TEXT / FONT / SIZE / COLOR` (no `X/Y/W/H/RADIUS/ALPHA` — position unavailable)
- `--items` JSON includes `"hasFrame": false` on each item — consumers should check this field before using coordinate fields
- The first line of `--summary` output reads `(macOS CGDrawingLayer path — position unavailable; text/font/color only)`

This affects macOS Sheet views, Sidebar list items, and any hosting view whose children render via CoreGraphics directly.

> ⛔ **Required env: `SWIFTUI_VIEW_DEBUG=287`**. SwiftUI's `makeViewDebugData` only returns useful data when this env var is set on the host app process. Xcode `Cmd+R` injects it automatically; `xcodebuildmcp` / `xcodebuild` / `simctl launch` / `open` (without `--env`) do **not**. Without it, `swiftui-debug` returns empty `viewDebugData` (length 2 = `[]`). See [Launching with SwiftUI debug enabled](#launching-with-swiftui-debug-enabled) below for per-platform launch templates.

> 📝 **iOS / tvOS / visionOS limitation**: those platforms do not emit display-list-item s-expressions inside `viewDebugData`, so `--summary` shows `TEXT / FONT / SIZE / COLOR` but lacks `X / Y / W / H / RADIUS / ALPHA`. Use `lookinside hierarchy --with-attrs` and look up the matching `CGDrawingLayer` / `ImageLayer` frames to fill in position. macOS `--summary` returns the full table when display-list items are present.

### 5. Inspect arbitrary view / layer attributes (`attrs`)

Use `attrs` to dump every introspectable attribute of a single OID — bg color, corner radius, shadow, opacity, frame, clipping, accessibility — without the SwiftUI debug detour.

```bash
lookinside attrs --target <id> --oid <oid>           # raw JSON
lookinside attrs --target <id> --oid <oid> --summary # text table
lookinside attrs --target <id> --oid <oid> --items   # JSON array
```

Pair with `ivars` (which dumps Objective-C runtime instance variables + AppKit Quick Look info) when chasing why a particular layer / view holds a value the public APIs don't expose.

### 6. Identify the current view controller (`vc`)

Use `vc` to identify which UIViewController (or NSViewController) owns the currently visible screen, or to find the VC hosting a specific view.

```bash
# Show the topmost visible (non-container) view controller
lookinside vc --target <id>

# Find the VC that hosts a specific view by OID
lookinside vc --target <id> --oid <oid>

# JSON output with parent controller chain
lookinside vc --target <id> --format json
```

Text output:
```
Filmly.SettingsViewController
  in: UINavigationController → UITabBarController
```

JSON output:
```json
{
  "className": "Filmly.SettingsViewController",
  "oid": 42,
  "memoryAddress": "0x10f43ec00",
  "parentControllers": ["UINavigationController", "UITabBarController"]
}
```

Without `--oid`, the command automatically finds the deepest non-container VC in the key window (skips UINavigationController, UITabBarController, system input controllers, etc.). With `--oid`, it walks up the view hierarchy from the specified view until it finds a node with a hosting view controller.

The `hierarchy --format json` output also includes a `hostViewController` field on each node that has one, enabling programmatic VC lookups without `vc`.

### 7. Export a reusable snapshot

Use JSON when another tool should consume the hierarchy payload:

```bash
lookinside export --target <id> --output /tmp/sample.json --format json
```

Use archive output when the snapshot should be opened later in LookInside:

```bash
lookinside export --target <id> --output /tmp/sample.lookinside
```

Format rules:

- `--format auto` infers from the file extension
- JSON exports must use `.json`
- archive exports must use `.archive`, `.lookin`, or `.lookinside`
- archive output with no extension becomes `.lookinside`

### 8. Validate against a running host app

After launching a host app that embeds `LookinServer`, use `list`, `inspect`, `hierarchy`, `attrs`, `vc`, or `swiftui-debug` from the CLI to validate the end-to-end flow.

## Launching with SwiftUI debug enabled

`swiftui-debug` only returns real data when the host app process has `SWIFTUI_VIEW_DEBUG=287` set in its environment. Xcode injects this automatically on `Cmd+R`; everywhere else you have to opt in. Templates per platform:

**macOS**:

```bash
APP=/path/to/YourApp.app
pkill -f "$(basename "$APP" .app)" 2>/dev/null
open -n -a "$APP" --env SWIFTUI_VIEW_DEBUG=287
```

> When passing both `--env` and `--args`, **`--env` must come first**, otherwise the `KEY=VAL` is misinterpreted as an App argv.

**iOS Simulator**:

```bash
xcrun simctl terminate "$SIM_ID" "$BUNDLE" 2>/dev/null
SIMCTL_CHILD_SWIFTUI_VIEW_DEBUG=287 xcrun simctl launch "$SIM_ID" "$BUNDLE"
```

> The `SIMCTL_CHILD_<NAME>` prefix is `simctl`'s officially-supported way to forward an env var to the launched app. Plain `--setenv` doesn't propagate to the SwiftUI runtime.

**iOS / tvOS / visionOS USB device** (requires `devicectl`, iOS 17+):

```bash
xcrun devicectl device process launch \
    --device "$DEVICE_UDID" \
    --terminate-existing \
    --environment-variables '{"SWIFTUI_VIEW_DEBUG":"287"}' \
    "$BUNDLE"
```

After launch, run a self-check before relying on `swiftui-debug` output:

```bash
TARGET=$(lookinside list --ids-only | head -1)
HOSTING_OID=$(lookinside hierarchy --target "$TARGET" --format json \
    | python3 -c '
import json,sys
d=json.load(sys.stdin)
def f(n):
    if "HostingView" in n.get("className",""): print(n.get("oid")); sys.exit(0)
    for c in n.get("children",[]): f(c)
for i in d.get("displayItems",[]): f(i)
' | head -1)
LEN=$(lookinside swiftui-debug --target "$TARGET" --oid "$HOSTING_OID" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("viewDebugDataLength",0))')
[ "$LEN" -gt 1000 ] && echo "✅ ready ($LEN bytes)" \
                   || echo "❌ FAIL ($LEN bytes) — check SWIFTUI_VIEW_DEBUG=287 was set"
```

`viewDebugDataLength <= 100` ⇒ env wasn't set. Restart the app with the correct launch command.

## Embedding and Porting `LookinServer`

For Apple-platform host apps you control, prefer normal source or framework integration and call `LookinServerStart()` once during startup.

Use `bash Scripts/package-lookinserver.sh` when you need packaged artifacts instead of a direct SwiftPM/Xcode integration. The script produces a `LookinServer.xcframework` plus per-SDK `LookinServer.dylib` outputs under `build/lookinserver/`.

Treat the packaged dylib as an advanced developer path. It can be useful in controlled environments that support runtime code injection into the target process, but this skill should not assume that injection is portable, review-safe, or allowed on stock devices or store builds.

For Android, HarmonyOS, or other non-Apple ports, keep the protocol and output compatibility where it helps, but reimplement the platform adapters. The UIKit/AppKit-specific categories in `Sources/LookinServer/Server/Category` are not directly portable.

Preserve compatibility names such as `LookinServer`, `LookinShared`, and `LookinCore` when it reduces migration friction for existing hosts or tooling.

## References

Read [output-shapes.md](references/output-shapes.md) when the user asks what the data looks like, wants example snippets for docs, or needs to know which fields exist in JSON output (incl. `swiftui-debug` payload structure).

Read [integration-porting.md](references/integration-porting.md) when the user is embedding `LookinServer` into an open-source host, packaging the dynamic library, or moving a Lookin-style integration from iOS/macOS to Android, HarmonyOS, or another platform.

Full CLI reference (Chinese): [docs/cli.md](../../docs/cli.md) — has the complete subcommand matrix, `swiftui-debug` mode comparison, per-platform launch templates, and known-issue troubleshooting.

## Troubleshooting

- If live discovery is flaky, re-run `lookinside list` immediately before `inspect`, `hierarchy`, `attrs`, `vc`, or `swiftui-debug`.
- Expect hierarchy JSON to be large; write it to a file when you only need a sample or want to inspect it incrementally.
- **`swiftui-debug` returns `viewDebugDataLength: 2 bytes` (= empty `[]`)**: the host app was launched without `SWIFTUI_VIEW_DEBUG=287`. Restart with the launch template above. This is the single most common failure mode and unrelated to the OID, target connectivity, or LLDB attachment.
- **`swiftui-debug` returns `LookinErr_Inner -401` on iOS / tvOS / visionOS**: the embedded `LookinServer` predates the cross-platform support (commit `73aebb9` and later). Update the host's `LookinServer` pod / SwiftPM dependency to a build that includes the iOS / tvOS / visionOS code path.
- If the client rejects a target because of version compatibility, update the embedded `LookinServer` integration from this repository before changing the desktop app or CLI assumptions.
- For cross-platform ports, ship read-only inspection first, then add editing or screenshot fidelity work after the hierarchy transport is stable.
