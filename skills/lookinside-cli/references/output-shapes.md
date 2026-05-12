# LookInside CLI Output Shapes

Use this reference when documenting the CLI, explaining fields, or choosing between text and JSON output.

## `list --format json`

The CLI returns an array of discovered targets.

```json
[
  {
    "appInfoIdentifier": 1774294178,
    "appName": "MiniTerm",
    "bundleIdentifier": "wiki.qaq.MiniTerm",
    "deviceDescription": "iPhone Air",
    "osDescription": "26.3.1",
    "port": 47164,
    "serverReadableVersion": "1.2.8",
    "serverVersion": 0,
    "targetID": "simulator:47164:1774294178",
    "transport": "simulator"
  }
]
```

Field notes:

- `targetID`: runtime-discovered opaque identifier used by `inspect`, `hierarchy`, and `export`
- `transport`: `mac`, `simulator`, or `usb`
- `port`: transport port used to connect to the embedded server
- `appInfoIdentifier`: per-run app identifier exposed by LookinServer
- `bundleIdentifier`: may be empty for some macOS validation hosts or non-bundled targets

Example mac target:

```json
[
  {
    "appInfoIdentifier": 7268387651031256382,
    "appName": "ExampleHost",
    "bundleIdentifier": "",
    "deviceDescription": "Managed's Virtual Machine",
    "osDescription": "macOS 26.2.0",
    "port": 47170,
    "serverReadableVersion": "1.2.8",
    "serverVersion": 7,
    "targetID": "mac:47170:7268387651031256382",
    "transport": "mac"
  }
]
```

## `inspect --format json`

The CLI wraps target metadata with connection metadata.

```json
{
  "connectionState": "connected",
  "protocolVersion": 7,
  "target": {
    "appInfoIdentifier": 1774294178,
    "appName": "MiniTerm",
    "bundleIdentifier": "wiki.qaq.MiniTerm",
    "deviceDescription": "iPhone Air",
    "osDescription": "26.3.1",
    "port": 47164,
    "serverReadableVersion": "1.2.8",
    "serverVersion": 0,
    "targetID": "simulator:47164:1774294178",
    "transport": "simulator"
  }
}
```

## `hierarchy` tree output

Text mode prints one node per line using indentation to show nesting.

```text
- UIWindow#2 [keyWindow] frame={0, 0, 420, 912}
  - UITransitionView#11 frame={0, 0, 420, 912}
    - _UIMultiLayer#12 frame={0, 0, 420, 912}
      - UIDropShadowView#14 frame={0, 0, 420, 912}
        - UILayoutContainerView#16 frame={0, 0, 420, 912}
```

Rendering rules:

- `ClassName#oid` identifies the node
- `[keyWindow]` appears for the key window
- `hidden` appears for hidden nodes
- `alpha=<value>` appears when alpha is not `1`
- `frame={x, y, width, height}` is always included
- a quoted suffix appears when `customDisplayTitle` is present

## `hierarchy --format json`

JSON mode returns app metadata plus a recursive `displayItems` tree.

```json
{
  "app": {
    "appName": "MiniTerm",
    "bundleIdentifier": "wiki.qaq.MiniTerm",
    "deviceDescription": "iPhone Air",
    "deviceType": "0",
    "osDescription": "26.3.1",
    "osMainVersion": 26,
    "screenWidth": 420,
    "screenHeight": 912,
    "screenScale": 3,
    "serverReadableVersion": "1.2.8",
    "serverVersion": 0,
    "swiftEnabledInLookinServer": -1
  },
  "collapsedClassList": [],
  "colorAlias": {},
  "displayItems": [
    {
      "className": "UIWindow",
      "memoryAddress": "0x1045098b0",
      "oid": 2,
      "frame": { "x": 0, "y": 0, "width": 420, "height": 912 },
      "bounds": { "x": 0, "y": 0, "width": 420, "height": 912 },
      "alpha": 1,
      "isHidden": false,
      "representedAsKeyWindow": true,
      "customDisplayTitle": "",
      "children": []
    }
  ],
  "serverVersion": 7
}
```

Each display item includes:

- identity: `className`, `memoryAddress`, `oid`
- geometry: `frame`, `bounds`
- visibility: `alpha`, `isHidden`
- hierarchy metadata: `representedAsKeyWindow`, `customDisplayTitle`
- recursion: `children`

## `export`

`export --format json` writes the same payload shape as `hierarchy --format json`.

Archive output writes a serialized LookInside/Lookin document and must use one of these extensions:

- `.archive`
- `.lookin`
- `.lookinside`

If `export --format auto` is used, the CLI infers JSON vs. archive from the output extension.

## `attrs`

`attrs --target <id> --oid <oid>` returns every introspectable attribute on a single layer / view (background, corner radius, shadow, opacity, frame in absolute hosting-view coordinates, accessibility props, …). Three output modes:

- `attrs … --summary` — text table with two columns of metadata + one wide value column. Best for humans reading layer state at a glance.
- `attrs … --items` — flat JSON array; each entry is `{ "group": "v_b", "section": "v_b", "attrIdentifier": "vl_b_b", "value": "#FFFFFFFF" }`. Best for scripting.
- _(no flag)_ — full nested JSON identical to the desktop client's "All Attribute Groups" pane.

Sample summary excerpt (iOS-style attribute IDs prefix with `lb_*` for UILabel rows, `vl_*` for view-level rows; both share the `l_*` layout prefix for frame/anchor/bounds):

```text
GROUP   SECTION  ATTR ID         VALUE
c       cl_c     c_c_c           null
l       l_f      l_f_f           x=370 y=417 w=168 h=44
vl      v_b      vl_b_b          #09090AFF
vl      v_c      vl_c_r          6.00
la      lb_t     lb_t_t          "登录"
la      lb_f     lb_f_n          ".SFNS-Semibold"
la      lb_f     lb_f_s          14.00
la      lb_tc    lb_t_c          #FFFFFFFF
```

Use `attrs` when:

1. The OID is **not** a HostingView (regular UIView / NSView / CALayer / CAGradientLayer / UIImageView etc.)
2. The OID **is** a HostingView but you only need the layer-level attribute (frame, bg fill, opacity, clip radius) and not the inner SwiftUI view-debug data.

For SwiftUI hosting views' inner content (Text font / size / colour / alignment, Image asset name, RoundedRectangle radius), use `swiftui-debug` instead.

## `swiftui-debug`

`swiftui-debug --target <id> --oid <hosting-oid>` calls SwiftUI's private `makeViewDebugData` and `_accessibilitySwiftUIDebugData` selectors on a hosting view (NSHostingView on macOS, _UIHostingView on iOS / tvOS / visionOS) and returns the same data Xcode View Debugger consumes. **Cross-platform**: works on macOS, iOS, tvOS, visionOS as of commit `73aebb9`+.

### Default JSON shape

```json
{
  "className": "_TtGC7SwiftUI13NSHostingViewGVS_15ModifiedContentVCVS_19NavigationSplitCore...",
  "viewDebugData": [
    {
      "children": [/* recursive node list */],
      "properties": [
        {
          "id": 0,
          "attribute": {
            "type": "SwiftUI.NavigationPaneModifier<SwiftUI.ContainerStyleContext>",
            "readableType": "NavigationPaneModifier<ContainerStyleContext>",
            "flags": 0,
            "subattributes": [/* nested attribute graph */]
          }
        }
      ]
    }
  ],
  "viewDebugDataLength": 5094872,
  "viewDebugDataFormat": "raw",
  "accessibilityDebugData": {/* parallel AX tree */},
  "accessibilityDebugDataLength": 1037,
  "accessibilityDebugDataFormat": "json"
}
```

Field notes:

- `viewDebugDataLength`: byte size of the inline JSON payload (or the spooled file when `viewDebugDataFormat == "file"` on macOS hosts — see below). **Always check this first** as a sanity gate; `<= 100 bytes` means the host app was launched without `SWIFTUI_VIEW_DEBUG=287` and every parsed-mode call below will fail.
- `viewDebugDataFormat`:
  - `"raw"` — `viewDebugData` is the inline JSON tree (iOS / tvOS / visionOS hosts; macOS when spooling fails)
  - `"file"` — `viewDebugDataFilePath` points to the spooled JSON on disk; **this branch only fires on macOS** to avoid a NSKeyedUnarchiver bug on macOS 26 hosts when round-tripping ≥ 50 MB inline payloads
  - `"sanitized"` — best-effort dictionary form of a non-NSData return (rare)
- `accessibilityDebugData{,Length,Format}`: parallel AX tree (`makeViewDebugData`'s sibling selector). On macOS the data is always spooled to `accessibilityDebugDataFilePath`; on other platforms it is inline.

### `--summary` flat table

Plain-text table extracted from the display-list. macOS sample:

```text
ID     KIND       X     Y     W     H     ALPHA  RADIUS   CONTENT
--------------------------------------------------------------------------------
89     fill       0     0     300   223   0.00   -        #FEFFFFFF
-      image      90    3     120   120   0.00   -        img(180×180)
-      text       46    143   209   17    0.00   -        "登录即可自动同步媒体库影片数据" .SFNS-Regular 14pt #09090AFF Center lsp=8
96     fill       66    178   168   44    0.00   22.0     #09090AFF
-      text       136   192   28    17    0.00   22.0     "登录" .SFNS-Semibold 14pt #FFFFFFFF Left lsp=0
```

iOS / tvOS / visionOS sample (CGDrawingLayer-only fallback path — no display-list-item s-expressions are emitted by Apple on these platforms, so X/Y/W/H/ALPHA/RADIUS columns are unavailable):

```text
(macOS CGDrawingLayer path — position unavailable; text/font/color only)
TEXT                                FONT             SIZE   COLOR
--------------------------------------------------------------------
"Find out More"                     .SFUI-Regular    13pt   #22E569FF
"ShellGuard(TCP)"                   .SFUI-Regular    16pt   #FFFFFFFF
"Stealth(UDP)"                      .SFUI-Regular    16pt   #FFFFFFFF
"SafeShell's self-developed proto…  .SFUI-Regular    13pt   #EBEBF5AD
```

For iOS-side position / size, look up the corresponding `_TtC7SwiftUI*CGDrawingLayer` / `SwiftUI.ImageLayer` nodes via `lookinside hierarchy --with-attrs` and read the layer-level `frame` / `cornerRadius` / `backgroundColor`.

### `--items` JSON array

Same parse as `--summary` but as `[{...}, {...}]` JSON. Per-item shape:

```json
[
  {
    "identity": "96",
    "kind": "fill",
    "hasFrame": true,
    "x": 66, "y": 178, "w": 168, "h": 44,
    "opacity": 1.0,
    "cornerRadius": 22.0,
    "fillColor": "#09090AFF",
    "extras": {
      "version": "1779",
      "required": "true",
      "content-seed": "3557"
    }
  },
  {
    "identity": "",
    "kind": "text",
    "hasFrame": false,
    "x": 0, "y": 0, "w": 0, "h": 0,
    "opacity": 1.0,
    "text": "Find out More",
    "font": ".SFUI-Regular",
    "fontSize": 13,
    "fillColor": "#22E569FF",
    "alignment": "Left",
    "lineSpacing": 0
  }
]
```

`hasFrame=false` flags the iOS / tvOS / visionOS fallback path where positional fields are 0 and should not be relied upon.

### `--tree` SwiftUI-style indented tree

Just the visible view-kind tree, modifiers and layout-only nodes collapsed:

```text
VPNProtocolSelectView
└── TupleView
    ├── Spacer
    └── VStack
        ├── HStack
        │   ├── Spacer
        │   └── VStack
        │       └── Text  "Find out More"
        └── VStack
            ├── VStack
            │   └── HStack
            │       ├── Image
            │       └── VStack
            │           ├── Text
            │           └── Text
            ├── Divider
            └── VStack
                └── HStack
                    ├── Image
                    └── VStack
                        ├── Text  "SafeShell's self-developed protocol. ..."
                        └── Text  "ShellGuard(TCP)"
```

Whitelist + module-aware fallback rules in `LookInsideCLI/SwiftUIDebugSummary` decide which nodes to surface; user-defined views (any module outside `SwiftUI` / `_SwiftUI` / `Swift` / `Foundation` / `__C` / `__C_Synthesized`) are auto-included.
