# LookInside CLI 使用手册

## 概述

`lookinside` 命令行工具可以发现、查看和导出 debug 目标 App 的视图层级、属性和 SwiftUI 内部结构。

### 子命令一览

| 命令 | 功能 |
|------|------|
| `list` | 列出当前可 inspect 的目标 App |
| `inspect` | 查看单个目标的元信息 |
| `hierarchy` | 获取实时视图层级树 |
| `export` | 导出层级数据为 archive 或 JSON 文件 |
| `attrs` | 获取指定 Layer 的全部属性（text/color/font/cornerRadius 等） |
| `ivars` | 导出运行时 ivar、AppKit quick-look 和 AX 信息 |
| `swiftui-debug` | 提取 NSHostingView 内部的 SwiftUI 视图树和属性 |

---

## `list` — 列出目标 App

```bash
lookinside list
lookinside list --format json
lookinside list --transport mac
lookinside list --bundle-id com.example.app
lookinside list --name-contains "爆米花"
lookinside list --ids-only
```

| 选项 | 说明 |
|------|------|
| `--format` | 输出格式：`text`（默认）/ `json` |
| `--transport` | 按传输方式过滤：`mac` / `simulator` / `usb` |
| `--bundle-id` | 精确匹配 bundle identifier |
| `--name-contains` | App 名称模糊匹配 |
| `--ids-only` | 仅输出 target ID |

---

## `inspect` — 查看目标元信息

```bash
lookinside inspect --target <target>
lookinside inspect --target <target> --format json
```

输出包括：App 名称、bundle ID、设备名、macOS 版本、lookinServer 版本、是否启用 SwiftUI 支持等。

---

## `hierarchy` — 获取视图层级

```bash
lookinside hierarchy --target <target>
lookinside hierarchy --target <target> --format json
lookinside hierarchy --target <target> --with-attrs
lookinside hierarchy --target <target> --output /tmp/tree.txt
```

| 选项 | 说明 |
|------|------|
| `--format` | `tree`（默认，缩进文本树）/ `json` |
| `--with-attrs` | 在每个节点附加完整属性组（需 `--format json`） |
| `--output` | 写入文件而非 stdout |

层级树中每个节点显示：
- 类名（如 `_TtGC7SwiftUI13NSHostingView...` 或 `NSTextField`）
- OID（`#N`）和 Layer OID（`/LN`）
- `frame={x, y, w, h}`
- `hidden` / `alpha=N.NN`（如有）

---

## `export` — 导出层级数据

```bash
lookinside export --target <target> --output /tmp/hierarchy.json
lookinside export --target <target> --output /tmp/hierarchy.lookin
lookinside export --target <target> --output /tmp/hierarchy.lookin --format archive
```

| 选项 | 说明 |
|------|------|
| `--output` | 目标文件路径 |
| `--format` | `auto`（根据扩展名推断）/ `json` / `archive` |

- **archive 格式**（`.lookin`）：可用 LookInside macOS App 打开，含截图和完整属性
- **JSON 格式**（`.json`）：纯文本，适合脚本处理和版本管理

---

## `attrs` — 获取 Layer 属性

```bash
lookinside attrs --target <target> --oid <layerOID>
lookinside attrs --target <target> --oid <layerOID> --summary
lookinside attrs --target <target> --oid <layerOID> --items
```

| 选项 | 说明 |
|------|------|
| `--oid` | Layer OID（来自 `lookinside hierarchy` 的 `/LN` 编号） |
| `-s, --summary` | 扁平摘要表格 |
| `--items` | JSON 数组格式 |

返回的属性包括：frame、backgroundColor、alpha、hidden、cornerRadius、border、shadow、font、textColor、image 等（具体取决于 Layer 类型）。

> **注意**：只能获取 Layer 的属性，不是 View 的属性。SwiftUI 视图的属性请用 `swiftui-debug`。

---

## `ivars` — 导出运行时信息

```bash
lookinside ivars --target <target> --oid <oid>
```

| 选项 | 说明 |
|------|------|
| `--oid` | 对象 OID（来自 `lookinside hierarchy` 的 `#N` 编号） |

输出包括：
- ObjC Runtime ivars（名称、类型、值）
- AppKit quick-look 值（font、text、color）
- Accessibility 信息（role、label、value）

适用于探查 `attrs` 无法获取属性的 SwiftUI 桥接视图。

---

## SwiftUI 调试能力

`lookinside swiftui-debug` 通过调用 `-[NSHostingView makeViewDebugData]` / `-[_UIHostingView makeViewDebugData]` 和 `-[…HostingView _accessibilitySwiftUIDebugData]`（与 Xcode View Debugger 相同的私有 selector）提取目标 App 中 SwiftUI 视图的完整内部信息。**支持 macOS / iOS / tvOS / visionOS** 全部 Apple 平台。

### 使用方法

```bash
# 先找到 NSHostingView 的 OID
lookinside hierarchy --target <target> | grep -i hosting

# 三种输出模式（互斥）
lookinside swiftui-debug --target <target> --oid <oid>            # 默认：原始 JSON
lookinside swiftui-debug --target <target> --oid <oid> --tree     # 视图树
lookinside swiftui-debug --target <target> --oid <oid> --summary  # 扁平属性表
lookinside swiftui-debug --target <target> --oid <oid> --items    # 属性 JSON
```

### 输出模式

| 模式 | 标志 | 输出 |
|------|------|------|
| 默认 | _(无)_ | 完整的 Apple `makeViewDebugData` JSON 原始数据（含 image asset name、NamedColor token、modifier chain 等全部字段） |
| `--tree` | `-t` | SwiftUI 风格的缩进视图树，修饰符/布局包装节点折叠，「看到的即源码中的视图结构」 |
| `--summary` | `-s` | 扁平表格：逐绘制 primitive 展示 frame、颜色、字体、文本内容、圆角等 |
| `--items` | | 与 `--summary` 相同的解析结果，但输出为结构化 JSON 数组（含 `extras` 字典保存未投射的低级 token，适合脚本消费） |

### `--tree` 视图树

#### 支持的节点类型

**布局容器**
`VStack` `HStack` `ZStack` `LazyVStack` `LazyHStack` `LazyVGrid` `LazyHGrid` `Grid` `GridRow`

**分组 / 列表**
`Group` `Section` `Form` `List` `Table` `ScrollView` `ScrollViewReader`

**导航**
`NavigationStack` `NavigationView` `NavigationSplitView` `NavigationLink` `TabView`

**几何**
`GeometryReader` `Spacer` `Divider` `EmptyView` `AnyView`

**形状**
`Shape` `Rectangle` `RoundedRectangle` `Circle` `Capsule` `Ellipse` `Path`

**文本 / 标签**
`Text` `Label`

**图片 / 颜色**
`Image` `Color`

**交互控件**
`Button` `Toggle` `Picker` `Slider` `Stepper` `Menu`

**输入**
`TextField` `SecureField` `TextEditor`

**选择器**
`DatePicker` `ColorPicker` `Link`

**指示器**
`ProgressView` `ResolvedProgressView`

**内部结构**（保留以完整表达视图树的真实形状）
`ForEach` `TupleView` `_ConditionalContent` `_OverlayModifier` `ViewLeafView`

**导航骨架**（NavigationSplitView / NavigationStack 列级别定位锚点）
`NavigationSplitCore` `_NavigationSplitReader` `NavigationStackCore` `StatefulNavigationStackChildren` `ExplicitStack` `StackSubstructure` `VariadicViewForest` `_VariadicView` `ColumnView` `SidebarStyleContext` `ContainerStyleContext`

**平台桥接**（标记 SwiftUI → AppKit/UIKit 的交接点，或嵌套 NSHostingView）
`PlatformViewRepresentableAdaptor` `DraggingDestinationView` `AppKitPlatformViewHost`

**用户自定义视图**
自动检测：凡 module 不属于 `SwiftUI` / `_SwiftUI` / `Swift` / `Foundation` / `__C` / `__C_Synthesized` 的视图类型自动露出，无需手动添加到白名单。

#### 节点注解

| 节点类型 | 注解内容 |
|---------|---------|
| `Text` | `"实际文本内容" 14pt` |
| `Image` | `asset="图标名称"` |
| `Color` | `rgba(r,g,b,a)` 或 `name="NamedColor"` |
| Stack（VStack / HStack / ZStack） | `(N items)` — TupleView 中的子元素数量 |
| `ProgressView` | `(indeterminate)` |

Example:

```
NavigationSplitView
├── ColumnView
│   └── VStack
│       ├── Text  "请使用" 14pt
│       ├── Text  "手机端网易爆米花" 14pt
│       └── Text  "扫码登录或扫码下载网易爆米花 App" 14pt
├── ColumnView
│   └── VideoHomePage
│       └── LoadingStateView
│           └── ZStack
└── ColumnView
    └── AppDetailContainerView
        └── NavigationStackView
            └── NavigationStack
```

### `--summary` / `--items` 提取的属性

每行对应 display-list 中的一个绘制 primitive（text / fill / image / platform / group）。

| 属性 | 类型 | 说明 |
|------|------|------|
| `identity` | string | display-list item identity 编号 |
| `kind` | enum | `text` `fill` `image` `platform` `group` |
| `x`, `y`, `w`, `h` | double | 在 NSHostingView 坐标系中的绝对 frame |
| `opacity` | double | 累积透明度（所有祖先 `#:opacity` 的乘积） |
| `cornerRadius` | double? | 从 clip-path 几何推断的圆角半径（启发式，±1pt） |
| `fillColor` | string? | `#RRGGBBAA` 格式 |
| `imageSize` | (w,h)? | 图片原始尺寸 |
| `text` | string? | verbatim 文本内容 |
| `font` | string? | 字体名（如 `.SFNS-Semibold`、`.PingFangSC-Regular`） |
| `fontSize` | double? | 字号（pt） |
| `alignment` | string? | 文本对齐 |
| `lineSpacing` | double? | 行间距 |
| `hasFrame` | bool | `false` 表示来自 CGDrawingLayer 降级路径（无帧位置） |
| `extras` | dict | 未投射的低级 token（`version`、`content-seed`、`required`、`platform-group` 等） |

#### Summary 表格示例

```
ID    KIND       X    Y    W    H    ALPHA  RADIUS   CONTENT
-     text       77   104  146  44   1.00   -        "网易爆米花" .SFNS-Semibold 14pt #FF333333
-     fill       77   104  146  44   1.00   -        #FF333333
-     image      134  96   32   32   0.50   -        img(32×32)
```

#### Summary 表格列说明

| 列 | 说明 |
|-----|------|
| `ID` | item identity（空为 `-`） |
| `KIND` | text / fill / image / platform / group |
| `X Y W H` | frame（pt） |
| `ALPHA` | 累积透明度 |
| `RADIUS` | 推断圆角（无则为 `-`） |
| `CONTENT` | text: `"文本" 字体 字号 颜色` / fill: `#RRGGBBAA` / image: `img(w×h)` |

#### 无法从 display-list 提取的属性

以下属性 **不在** display-list 中，需要回源到源码层查看：

- Border 宽度 / 颜色
- Shadow 颜色 / blur / offset
- Button / Toggle 的状态（enabled / pressed / focused）

### 降级机制

| 场景 | 处理 |
|------|------|
| `makeViewDebugData` 返回 `{"error": "..."}` | 自动降级到 `accessibilityDebugData`（AX 树），失去注解只保留节点名 |
| `makeViewDebugData` 无 `display-list-item`（**iOS / tvOS / visionOS** 普遍走此路径，因为非 macOS 端不输出 s-expression display-list） | 退到 attributed-string 描述解析（CGDrawingLayer 路径），仅能提取文本/字体/颜色（含行距、对齐），**无帧信息**（位置 / 尺寸字段为 0，`hasFrame=false`） |
| AX 树深度 > 400 层 | Server 端截断为 `"<truncated>"`（防止 NSJSONSerialization 深度 > 512 的栈溢出） |

> **iOS / tvOS / visionOS 平台特有限制**：iOS 端 `[uiHostingView makeViewDebugData]` 返回的 NSData JSON 与 macOS 结构同源，但**不输出 display-list-item s-expression 叶子**——因此 `--summary` 表的 `X / Y / W / H / RADIUS / ALPHA` 列不可达，只有 `TEXT / FONT / SIZE / COLOR / Alignment / LineSpacing` 列有值。位置 / 尺寸需要通过 `lookinside hierarchy` 取 CGDrawingLayer 节点的 frame 补齐（与 macOS UpdateDialog 等独立窗口的处理方式一致）。

### 限制 / 启动条件

- **必须 Debug Build**：Release / Archive 构建时 `makeViewDebugData` 返回空数组 `[]`
- **必须设置 `SWIFTUI_VIEW_DEBUG=287` 环境变量**：这是 SwiftUI 内部的 view-debug-data 开关。Xcode `Cmd+R` 启动时自动注入；用 `xcodebuild` / `xcodebuildmcp` 命令行 build 后再用 `open` / `simctl launch` 启动**不会**自动注入，需要手动指定（见下文「启动模板」）。env 缺失时 `swiftui-debug` 会返回空 `viewDebugData`（`viewDebugDataLength: 2 bytes`，即 `[]`）
- **必须命中 HostingView**：OID 必须解析为 SwiftUI 的 hosting view 实例（`_TtGC7SwiftUI13NSHostingView…` macOS / `_TtGC7SwiftUI14_UIHostingView…` iOS·tvOS·visionOS / `_TtGC7SwiftUI22ToolbarItemHostingView…` 工具栏项等）
- **需要 LookinServer 已注入目标 App**（即目标 App 必须已被 `lookinside list` 发现）

### 各平台正确启动模板

下表给出"如何让 App 进程在不依赖 Xcode IDE 启动的情况下也能返回 SwiftUI 调试数据"的命令模板。核心是把 `SWIFTUI_VIEW_DEBUG=287` 通过对应平台的 env 注入机制传给 App 进程。

| 启动方式 | `SWIFTUI_VIEW_DEBUG=287` 自动注入 | swiftui-debug 是否可用 |
|---|---|---|
| Xcode `Cmd+R` / `Cmd+Y` | ✅ | ✅ |
| `xcodebuildmcp macos build-and-run` 内部走 `open <app>` | ❌ | ❌ |
| `xcodebuildmcp simulator launch-app` | ❌ | ❌ |
| `xcrun simctl launch <udid> <bundle>` (无 SIMCTL_CHILD_ 前缀) | ❌ | ❌ |
| `open <app>` (无 `--env`) | ❌ | ❌ |
| ✅ `open -n -a <app> --env SWIFTUI_VIEW_DEBUG=287` | ✅ | ✅ |
| ✅ `SIMCTL_CHILD_SWIFTUI_VIEW_DEBUG=287 xcrun simctl launch …` | ✅ | ✅ |
| ✅ `xcrun devicectl device process launch --environment-variables '{"SWIFTUI_VIEW_DEBUG":"287"}' …` | ✅ | ✅ |

**macOS（本地直跑）**：

```bash
APP=/path/to/YourApp.app
pkill -f "$(basename "$APP" .app)" 2>/dev/null   # kill old instance
open -n -a "$APP" --env SWIFTUI_VIEW_DEBUG=287
```

> ⛔ macOS 上 `open --args` 同时使用时 `--env` 必须排在 `--args` **之前**，否则 `--env KEY=VAL` 会被当成 App argv 传入。

**iOS Simulator**：

```bash
SIM_ID=<simulator-udid>
BUNDLE=<your.bundle.id>
xcrun simctl terminate "$SIM_ID" "$BUNDLE" 2>/dev/null
SIMCTL_CHILD_SWIFTUI_VIEW_DEBUG=287 xcrun simctl launch "$SIM_ID" "$BUNDLE"
```

> 📝 `SIMCTL_CHILD_<NAME>` 前缀是 `xcrun simctl launch` 的官方 env 转发约定，等价于「设置 `<NAME>` 环境变量给被启动的子进程」。

**iOS / tvOS / visionOS USB 真机**（需要 iOS 17+ devicectl）：

```bash
DEVICE_UDID=<device-udid>
BUNDLE=<your.bundle.id>
xcrun devicectl device process launch \
    --device "$DEVICE_UDID" \
    --terminate-existing \
    --environment-variables '{"SWIFTUI_VIEW_DEBUG":"287"}' \
    "$BUNDLE"
```

> 📝 旧的 `ios-deploy` 不支持 env 注入；必须用 `devicectl`。

### 启动后自检

启动 App + 等 LookinServer 上线后，建议先跑一次自检确认 env 真的注入成功：

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

[ "$LEN" -gt 1000 ] && echo "✅ swiftui-debug ready: $LEN bytes" \
                   || echo "❌ FAIL: $LEN bytes — App was not launched with SWIFTUI_VIEW_DEBUG=287"
```

`viewDebugDataLength <= 100` 时即视作失败，**重启 App** 并核查启动命令是否带了 env，不要继续抓 hierarchy / 比对 — 拿到的是空数据。

### 287 是什么

`287 = 0x11F = 0b1_0001_1111`，bits 0/1/2/3/4/8 set —— SwiftUI 内部的 6 位 bitmask，开启 view-debug-data / display-list-export / accessibility-debug 等子开关。**值固定为 287**，来源于 Xcode `Cmd+R` 启动子进程时 IDE 注入的环境变量；任意 Cmd+R 启动的进程跑 `ps -E -p <pid>` 都能看到这个值。
