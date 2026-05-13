# LookInside

LookInside is a macOS, iOS, tvOS, and visionOS UI inspector for debuggable apps.

This repository packages:

- the macOS inspector app in [`LookInside/`](LookInside/), [`LookInside.xcodeproj`](LookInside.xcodeproj), and [`LookInside.xcworkspace`](LookInside.xcworkspace)
- shared inspection libraries in [`Sources/`](Sources/)
- the `lookinside` command-line tool in [`Sources/LookInsideCLI`](Sources/LookInsideCLI)
- `LookinServer` CocoaPods pod at [`LookinServer.podspec`](LookinServer.podspec) for embedding the inspection runtime into host apps

LookInside is a community continuation of Lookin. Compatibility module names such as `LookinServer`, `LookinShared`, and `LookinCore` are preserved to reduce migration friction for existing integrations.

The project ships without telemetry, crash upload, or automatic update services.

## What It Does

- discover inspectable macOS targets, iOS / tvOS / visionOS simulator apps, and USB-connected devices
- inspect target metadata from the desktop app or the CLI
- fetch live UIKit / AppKit view hierarchies
- dump SwiftUI view debug data (font, color, text, frames)
- introspect runtime ivars, accessibility attributes, and visual properties (color, font, corner radius)
- export hierarchy archives for offline analysis

## Install the CLI

### Prebuilt binary

```bash
curl -fsSL https://raw.githubusercontent.com/boduoduo/LookInside/main/install.sh | bash
```

Installs to `/usr/local/bin/lookinside`. To install without `sudo`:

```bash
curl -fsSL https://raw.githubusercontent.com/boduoduo/LookInside/main/install.sh | PREFIX=~/.local bash
```

Make sure `~/.local/bin` is on your `PATH`.

### Build from source

```bash
git clone https://github.com/boduoduo/LookInside.git
cd LookInside
swift build -c release --product lookinside
.build/release/lookinside --help
```

Optionally, symlink or copy the binary to your `PATH`:

```bash
cp .build/release/lookinside /usr/local/bin/
```

### CocoaPods (LookinServer)

To embed the inspection runtime in your own app for debugging:

```ruby
# Podfile
pod 'LookinServer', '~> 1.3.0', :configurations => ['Debug']
```

### SwiftPM

Link `LookinServer` as a Swift Package Manager dependency:

```swift
// Package.swift
.package(url: "https://github.com/boduoduo/LookInside.git", from: "1.3.0"),
```

Then add `LookinServer` to your target's dependencies.

## CLI Commands

### `list` — discover inspectable apps

```bash
lookinside list
lookinside list --format json
lookinside list --transport simulator
lookinside list --transport mac
lookinside list --transport usb
lookinside list --name-contains Mini
lookinside list --ids-only
```

### `inspect` — metadata for one target

```bash
lookinside inspect --target <target-id>
lookinside inspect --target <target-id> --format json
```

### `hierarchy` — live view hierarchy

```bash
lookinside hierarchy --target <target-id>
lookinside hierarchy --target <target-id> --format json
lookinside hierarchy --target <target-id> --output /tmp/hierarchy.txt
```

### `attrs` — visual properties for a view

```bash
lookinside attrs --target <target-id> --oid 42
lookinside attrs --target <target-id> --oid 42 --format json
```

Prints frame, bounds, alpha, hidden, corner radius, shadow, font, text color, attributed text, and more for a single view by its object ID.

### `ivars` — runtime introspection

```bash
lookinside ivars --target <target-id> --oid 42
```

Dumps ivars, AppKit quick-look metadata (font / text / color), and accessibility info for any object in the hierarchy.

### `swiftui-debug` — SwiftUI view debug data

```bash
lookinside swiftui-debug --target <target-id> --oid <ns-hosting-view-oid>
lookinside swiftui-debug --target <target-id> --oid <oid> --mode summary
lookinside swiftui-debug --target <target-id> --oid <oid> --mode tree
lookinside swiftui-debug --target <target-id> --oid <oid> --mode items
```

Modes:

- `summary` — table of every text, image, and platform view with font / color / frame
- `tree` — recursive view tree with box-drawing connectors, annotated with text, asset name, and arity
- `items` — flat per-element dump with type, frame, and attributes

Works on iOS, tvOS, and visionOS.

### `export` — archive or JSON export

```bash
lookinside export --target <target-id> --output /tmp/sample.lookinside
lookinside export --target <target-id> --output /tmp/sample.json --format json
```

## Build the macOS App

```bash
bash Scripts/sync-derived-source.sh
xcodebuild -skipMacroValidation -project LookInside.xcodeproj -scheme LookInside -configuration Debug -derivedDataPath /tmp/LookInsideDerivedData CODE_SIGNING_ALLOWED=NO build
```

The sync step refreshes [`LookInside/DerivedSource`](LookInside/DerivedSource) from shared sources in [`Sources/`](Sources/).

## Example Output

### `list --format json`

```json
[
  {
    "appInfoIdentifier": 1774294178,
    "appName": "MiniTerm",
    "bundleIdentifier": "wiki.qaq.MiniTerm",
    "deviceDescription": "iPhone Air",
    "osDescription": "26.3.1",
    "port": 47164,
    "serverReadableVersion": "1.3.0",
    "serverVersion": 7,
    "targetID": "simulator:47164:1774294178",
    "transport": "simulator"
  }
]
```

### `hierarchy` tree

```text
- UIWindow#2 [keyWindow] frame={0, 0, 420, 912}
  - UITransitionView#11 frame={0, 0, 420, 912}
    - UILayoutContainerView#16 frame={0, 0, 420, 912}
      - UINavigationTransitionView#30 frame={0, 0, 420, 912}
        - UIViewControllerWrapperView#32 frame={0, 0, 420, 912}
          - UIView#34 frame={0, 0, 420, 912}
            - UICollectionView#37 frame={0, 0, 420, 912}
```

### `swiftui-debug --mode summary`

```text
TEXT
  "Welcome"           SF-Pro, 20.0pt, #000000, bold
  "Tap to begin"      SF-Pro, 14.0pt, #888888
IMAGE
  "star.fill"         systemImage, 24×24
PLATFORM
  NavigationStack     {0, 0, 390, 844}
```

## Skill

A Claude Code skill for the CLI and host integration workflow is available at [`skills/lookinside-cli`](skills/lookinside-cli).

```bash
mkdir -p ~/.claude/skills
ln -sfn "$PWD/skills/lookinside-cli" ~/.claude/skills/lookinside-cli
```

## Project Notes

- `ReactiveObjC` is vendored under [`LookInside/ReactiveObjC`](LookInside/ReactiveObjC)
- `Peertalk` is vendored under [`Sources/LookinCore/Peertalk`](Sources/LookinCore/Peertalk) with preserved MIT notice in [`Resources/Licenses/Peertalk.txt`](Resources/Licenses/Peertalk.txt)
- `ShortCocoa` is vendored under [`LookInside/ShortCocoa`](LookInside/ShortCocoa) and distributed on the same GPL-3.0 basis as upstream Lookin; see [`Resources/Licenses/ShortCocoa.md`](Resources/Licenses/ShortCocoa.md)
- shared runtime code lives in [`Sources/LookinCore`](Sources/LookinCore) and [`Sources/LookinServerBase`](Sources/LookinServerBase)
- the macOS app builds mirrored copies from [`LookInside/DerivedSource`](LookInside/DerivedSource) — make shared-source changes in [`Sources/`](Sources/) then sync

## License

GPL-3.0. See [`LICENSE`](LICENSE) and preserved third-party notices in [`Resources/Licenses/`](Resources/Licenses/).

Bundled components:

- `ReactiveObjC`: MIT, see [`Resources/Licenses/ReactiveObjC.md`](Resources/Licenses/ReactiveObjC.md)
- `Peertalk`: MIT, see [`Resources/Licenses/Peertalk.txt`](Resources/Licenses/Peertalk.txt)
- `LookinServer`: MIT, see [`Resources/Licenses/LookinServer.txt`](Resources/Licenses/LookinServer.txt)
- `ShortCocoa`: GPL-3.0 in this distribution, see [`Resources/Licenses/ShortCocoa.md`](Resources/Licenses/ShortCocoa.md)
- `Lookin` upstream client code: GPL-3.0, see [`Resources/Licenses/LookinClient.txt`](Resources/Licenses/LookinClient.txt)

## Acknowledgements

LookInside is derived from upstream Lookin work and maintains compatibility with that ecosystem.

Primary upstream references:

- `CocoaUIInspector/Lookin`
- `QMUI/LookinServer`
