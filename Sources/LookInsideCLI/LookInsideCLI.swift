import ArgumentParser
import Foundation
import LookinCoreClient

private let supportedProtocolVersion = 7

@main
struct LookInside: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lookinside",
        abstract: "Inspect debuggable app targets from the command line.",
        discussion: """
        LookInside discovers inspectable macOS, simulator, and USB-connected targets,
        prints target metadata, fetches live view hierarchies, and exports hierarchy
        archives for later analysis.
        """,
        subcommands: [
            List.self,
            Inspect.self,
            Hierarchy.self,
            Export.self,
            Attrs.self,
            Ivars.self,
            SwiftUIDebug.self,
        ],
        defaultSubcommand: List.self
    )
}

private struct SharedTargetOptions: ParsableArguments {
    @Option(help: "Target identifier from `lookinside list`.")
    var target: String
}

private enum OutputFormat: String, ExpressibleByArgument, Codable, CaseIterable {
    case text
    case json
}

private enum HierarchyFormat: String, ExpressibleByArgument, Codable, CaseIterable {
    case tree
    case json
}

private enum TransportFilter: String, ExpressibleByArgument, Codable, CaseIterable {
    case mac
    case simulator
    case usb
}

private enum ExportFormat: String, ExpressibleByArgument, Codable, CaseIterable {
    case auto
    case json
    case archive
}

private struct List: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List currently inspectable apps."
    )

    @Option(help: "Output format.")
    var format: OutputFormat = .text

    @Option(help: "Restrict results to one transport.")
    var transport: TransportFilter?

    @Option(name: .customLong("bundle-id"), help: "Only include targets with an exact bundle identifier match.")
    var bundleIdentifier: String?

    @Option(name: .customLong("name-contains"), help: "Only include targets whose app name contains this text.")
    var nameContains: String?

    @Flag(name: .customLong("ids-only"), help: "Print only target IDs in text mode.")
    var idsOnly = false

    mutating func run() throws {
        var targets = try CLIClient().listTargets()
        targets = targets.filtered(by: transport, bundleIdentifier: bundleIdentifier, nameContains: nameContains)

        switch format {
        case .json:
            try StandardPrinter.printJSON(targets.map(TargetRecord.init))
        case .text:
            if targets.isEmpty {
                StandardPrinter.printLine("No inspectable apps found.")
                return
            }
            for target in targets {
                if idsOnly {
                    StandardPrinter.printLine(target.targetID)
                    continue
                }
                StandardPrinter.printLine(target.targetID)
                StandardPrinter.printLine("  \(target.appName) (\(target.bundleIdentifier))")
                StandardPrinter.printLine("  \(target.transport) port \(target.port) | \(target.deviceDescription) | \(target.osDescription) | server \(target.serverReadableVersion)")
            }
        }
    }
}

private struct Inspect: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Inspect one target and print its metadata."
    )

    @OptionGroup var options: SharedTargetOptions

    @Option(help: "Output format.")
    var format: OutputFormat = .text

    mutating func run() throws {
        let target = try CLIClient().inspectTarget(id: options.target)
        switch format {
        case .json:
            try StandardPrinter.printJSON(InspectRecord(target: target))
        case .text:
            StandardPrinter.printLine("id: \(target.targetID)")
            StandardPrinter.printLine("app: \(target.appName)")
            StandardPrinter.printLine("bundle: \(target.bundleIdentifier)")
            StandardPrinter.printLine("transport: \(target.transport)")
            StandardPrinter.printLine("port: \(target.port)")
            if let deviceID = target.deviceID, !deviceID.isEmpty {
                StandardPrinter.printLine("deviceID: \(deviceID)")
            }
            StandardPrinter.printLine("device: \(target.deviceDescription)")
            StandardPrinter.printLine("os: \(target.osDescription)")
            StandardPrinter.printLine("server: \(target.serverReadableVersion) (\(target.serverVersion))")
            StandardPrinter.printLine("protocolVersion: \(supportedProtocolVersion)")
            StandardPrinter.printLine("connectionState: connected")
        }
    }
}

private struct Hierarchy: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Fetch a live view hierarchy as text or JSON."
    )

    @OptionGroup var options: SharedTargetOptions

    @Option(help: "Hierarchy render format.")
    var format: HierarchyFormat = .tree

    @Option(help: "Write the hierarchy to a file instead of stdout.")
    var output: String?

    @Flag(name: .long, help: "Include the full attribute groups (text, color, font, etc.) for every node. Requires --format json.")
    var withAttrs: Bool = false

    mutating func validate() throws {
        if withAttrs && format != .json {
            throw CLIError("--with-attrs requires --format json.")
        }
    }

    mutating func run() throws {
        let rendered: String
        if withAttrs {
            rendered = try CLIClient().hierarchyWithAttrsJSON(target: options.target)
        } else {
            rendered = try CLIClient().hierarchy(target: options.target, format: format)
        }
        if let output, !output.isEmpty {
            let destination = try FileDestination(path: output)
            try destination.write(rendered)
            StandardPrinter.printLine("Wrote \(format.rawValue) hierarchy to \(destination.url.path)")
            return
        }
        StandardPrinter.printLine(rendered)
    }
}

private struct Export: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Export a hierarchy archive or JSON payload to disk."
    )

    @OptionGroup var options: SharedTargetOptions

    @Option(help: "Destination path.")
    var output: String

    @Option(help: "Export format. `auto` infers from the output extension.")
    var format: ExportFormat = .auto

    mutating func validate() throws {
        _ = try ExportDestination(path: output, format: format)
    }

    mutating func run() throws {
        let destination = try ExportDestination(path: output, format: format)
        let writtenURL = try CLIClient().export(target: options.target, to: destination.path)
        StandardPrinter.printLine("Wrote hierarchy export to \(writtenURL.path)")
    }
}

private struct Attrs: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Fetch all attributes for a specific view (text, color, font, corner radius, etc.)."
    )

    @OptionGroup var options: SharedTargetOptions

    @Option(help: "Layer OID from `lookinside hierarchy`.")
    var oid: UInt

    @Flag(name: [.long, .customShort("s")],
          help: "Print a flat summary table instead of the full JSON.")
    var summary: Bool = false

    @Flag(name: .long,
          help: "Print the flattened attribute list as a JSON array. Mutually exclusive with --summary.")
    var items: Bool = false

    mutating func validate() throws {
        if summary && items {
            throw ValidationError("--summary and --items are mutually exclusive.")
        }
    }

    mutating func run() throws {
        let json = try CLIClient().allAttrGroupsJSON(target: options.target, oid: oid)
        if summary {
            StandardPrinter.printLine(AttrsSummary.render(fromJSON: json))
        } else if items {
            StandardPrinter.printLine(AttrsSummary.renderItemsJSON(fromJSON: json))
        } else {
            StandardPrinter.printLine(json)
        }
    }
}

private struct Ivars: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Dump runtime ivars, AppKit quick-look (font/text/color), and AX info for an object.",
        discussion: """
        Useful for probing SwiftUI bridged views that don't expose attributes
        through the regular `attrs` subcommand. Works with any OID returned by
        `lookinside hierarchy`, including NSView subclasses.
        """
    )

    @OptionGroup var options: SharedTargetOptions

    @Option(help: "Object OID from `lookinside hierarchy`.")
    var oid: UInt

    mutating func run() throws {
        let json = try CLIClient().introspectJSON(target: options.target, oid: oid)
        StandardPrinter.printLine(json)
    }
}

/// Flattens the nested group → section → attribute JSON returned by
/// `allAttrGroupsJSON` into a table or JSON array.
///
/// The payload is an array of group objects:
///   [ { "group": "la", "sections": [ { "section": "lb_f", "attributes": [
///       { "id": "lb_f_n", "type": 24, "value": ".SFUI-Semibold" } ] } ] } ]
///
/// Type codes: 5/26=int  12/13=float  14=bool  17=CGPoint  20=CGRect
///             22=UIEdgeInsets  24=string  27=color{r,g,b,a}  28=optional/null
private enum AttrsSummary {

    struct Item {
        var group: String
        var section: String
        var id: String
        var type: Int
        var formatted: String
        var rawValue: Any?
    }

    static func extractItems(fromJSON jsonString: String) -> [Item]? {
        guard let data = jsonString.data(using: .utf8),
              let groups = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        var items: [Item] = []
        for group in groups {
            let groupName = group["group"] as? String ?? ""
            for section in (group["sections"] as? [[String: Any]] ?? []) {
                let sectionName = section["section"] as? String ?? ""
                for attr in (section["attributes"] as? [[String: Any]] ?? []) {
                    let id = attr["id"] as? String ?? ""
                    let type = attr["type"] as? Int ?? 0
                    let raw = attr["value"]
                    items.append(Item(group: groupName, section: sectionName,
                                      id: id, type: type,
                                      formatted: formatValue(type: type, value: raw),
                                      rawValue: raw))
                }
            }
        }
        return items
    }

    static func render(fromJSON jsonString: String) -> String {
        guard let items = extractItems(fromJSON: jsonString) else {
            return "(error: could not parse attrs JSON)"
        }
        if items.isEmpty { return "(no attributes)" }
        return formatTable(items)
    }

    static func renderItemsJSON(fromJSON jsonString: String) -> String {
        guard let data = jsonString.data(using: .utf8),
              let groups = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return "[]"
        }
        var flat: [[String: Any]] = []
        for group in groups {
            let groupName = group["group"] as? String ?? ""
            for section in (group["sections"] as? [[String: Any]] ?? []) {
                let sectionName = section["section"] as? String ?? ""
                for attr in (section["attributes"] as? [[String: Any]] ?? []) {
                    var item: [String: Any] = [
                        "group": groupName,
                        "section": sectionName,
                        "id": attr["id"] as? String ?? "",
                        "type": attr["type"] as? Int ?? 0,
                        "value": attr["value"] ?? NSNull(),
                    ]
                    let type = attr["type"] as? Int ?? 0
                    item["formatted"] = formatValue(type: type, value: attr["value"])
                    flat.append(item)
                }
            }
        }
        let opts: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .fragmentsAllowed]
        guard let out = try? JSONSerialization.data(withJSONObject: flat, options: opts),
              let str = String(data: out, encoding: .utf8) else { return "[]" }
        return str
    }

    private static func formatValue(type: Int, value: Any?) -> String {
        guard let v = value, !(v is NSNull) else { return "null" }
        switch type {
        case 14:
            if let b = v as? Bool { return b ? "true" : "false" }
        case 12, 13:
            if let n = v as? Double { return String(format: "%.2f", n) }
            if let n = v as? Int { return "\(n)" }
        case 5, 26:
            if let n = v as? Int { return "\(n)" }
        case 24:
            if let s = v as? String { return "\"\(s)\"" }
        case 27:
            if let c = v as? [String: Any] {
                let r = toDouble(c["r"]), g = toDouble(c["g"]),
                    b = toDouble(c["b"]), a = toDouble(c["a"])
                return String(format: "#%02X%02X%02X%02X",
                              Int((r * 255).rounded()), Int((g * 255).rounded()),
                              Int((b * 255).rounded()), Int((a * 255).rounded()))
            }
        case 17:
            if let p = v as? [String: Any] {
                return String(format: "x=%.2f y=%.2f", toDouble(p["x"]), toDouble(p["y"]))
            }
        case 20:
            if let r = v as? [String: Any] {
                return String(format: "x=%.0f y=%.0f w=%.0f h=%.0f",
                              toDouble(r["x"]), toDouble(r["y"]),
                              toDouble(r["width"]), toDouble(r["height"]))
            }
        case 22:
            if let i = v as? [String: Any] {
                return String(format: "T=%.0f B=%.0f L=%.0f R=%.0f",
                              toDouble(i["top"]), toDouble(i["bottom"]),
                              toDouble(i["left"]), toDouble(i["right"]))
            }
        default:
            break
        }
        return "\(v)"
    }

    private static func toDouble(_ v: Any?) -> Double {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        return 0
    }

    private static func formatTable(_ items: [Item]) -> String {
        func clip(_ s: String, _ n: Int) -> String {
            s.count <= n ? s : String(s.prefix(n - 1)) + "…"
        }
        func pad(_ s: String, _ n: Int) -> String {
            let c = clip(s, n)
            return c + String(repeating: " ", count: n - c.count)
        }
        let cols = [("GROUP", 8), ("SECTION", 10), ("ATTR ID", 16), ("VALUE", 52)]
        let header = cols.map { pad($0.0, $0.1) }.joined(separator: "  ")
        var lines = [header.trimmingCharacters(in: .whitespaces),
                     String(repeating: "-", count: header.count)]
        for it in items {
            let row = [pad(it.group, 8), pad(it.section, 10),
                       pad(it.id, 16), clip(it.formatted, 52)].joined(separator: "  ")
            lines.append(row)
        }
        return lines.joined(separator: "\n")
    }
}

private struct SwiftUIDebug: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swiftui-debug",
        abstract: "Dump SwiftUI viewDebugData (font / colour / text / frame) for an NSHostingView.",
        discussion: """
        Calls -[NSHostingView makeViewDebugData] and
        -[NSHostingView _accessibilitySwiftUIDebugData] on the OID's resolved
        object — these are the same private-but-stable selectors Xcode's View
        Debugger uses to surface SwiftUI semantics. The first returns a JSON
        Data describing every view (Text/Image/Button/...) in the hosted
        SwiftUI tree with the resolved font name, point size, fill colour and
        string content; the second is the AX flavour with role/value/label
        already broken out per element.

        The target OID must resolve to an NSHostingView (or subclass). Use
        `lookinside hierarchy` to find one — they show up in the tree as
        `_TtGC7SwiftUI13NSHostingView...` classes with subrole AXHostingView.

        Output modes:
          (default)   the full Apple JSON payload (~50MB), with no filtering.
                      Use this when you need fields the parsed views don't
                      surface (image asset names, NamedColor tokens, view
                      modifier chains, etc.).
          --summary   a compact human-readable table extracted from the
                      display-list (frame / fill / clip radius / opacity /
                      font / size / color / alignment / text content).
          --items     the same parse as --summary but as a structured JSON
                      array, with each item carrying both the typed columns
                      and an `extras` dict preserving every keyword token
                      we didn't project (version, content-seed, raw clip
                      path, etc.). Use this when scripting consumers.
          --tree      a SwiftUI-style indented tree of just the visible view
                      kinds (VStack / HStack / Text / Image / Button / ...),
                      modifier wrappers and layout-only nodes collapsed.
        """
    )

    @OptionGroup var options: SharedTargetOptions

    @Option(help: "OID of an NSHostingView from `lookinside hierarchy`.")
    var oid: UInt

    @Flag(name: [.long, .customShort("s")],
          help: "Print only a flat summary table (text / font / size / color / frame) instead of the full JSON.")
    var summary: Bool = false

    @Flag(name: .long,
          help: "Print the parsed display-list items as a JSON array. Mutually exclusive with --summary.")
    var items: Bool = false

    @Flag(name: .long,
          help: "Print a SwiftUI-style indented view-kind tree. Mutually exclusive with --summary / --items.")
    var tree: Bool = false

    mutating func run() throws {
        let json: String
        do {
            json = try CLIClient().swiftUIDebugJSON(target: options.target, oid: oid)
        } catch {
            FileHandle.standardError.write(Data("swiftui-debug RPC failed: \(error)\n".utf8))
            throw ExitCode(1)
        }
        let modeCount = [summary, items, tree].filter { $0 }.count
        if modeCount > 1 {
            throw ValidationError("--summary, --items, and --tree are mutually exclusive.")
        }
        if summary {
            StandardPrinter.printLine(SwiftUIDebugSummary.render(fromJSON: json))
        } else if items {
            StandardPrinter.printLine(SwiftUIDebugSummary.renderItemsJSON(fromJSON: json))
        } else if tree {
            StandardPrinter.printLine(SwiftUIViewTree.render(fromJSON: json))
        } else {
            StandardPrinter.printLine(json)
        }
    }
}

/// Extracts a flat per-text-element table out of a swiftui-debug JSON dump.
/// Two complementary signals live in the payload:
///
///   1. The `display-list-item` field is one giant Lisp-flavoured s-expression
///      describing every drawn primitive with frame + colour + text content.
///      We grep it for `(text "..." #:size (W, H))` and the `(frame ...)`
///      currently in scope, plus the most-recent `(color #RRGGBBAA)` so we
///      can attribute fill colour to each text run.
///   2. Every text node also has an attributed-string description like
///        `登录{ NSColor = "..."; NSFont = ".SFNS-Semibold 14.00 pt"; ... }`
///      which gives the canonical font name + point size + alignment.
///
/// We pair these two by text content (the keys are unique within a hosting
/// view in practice) and emit a stable plain-text table.
private enum SwiftUIDebugSummary {

    // MARK: - Output row model

    /// One emitted row in the summary table. Each row corresponds to a
    /// drawn item we extracted from the display-list. The dimensions we
    /// can extract reliably are listed in `kind`-specific fields below;
    /// see swiftui-attrs.md for what the table can and cannot represent.
    struct Item {
        var identity: String       // display-list item identity, or "" for synthetic
        var kind: String           // group / fill / text / image / platform / clip
        var x: Double
        var y: Double
        var w: Double
        var h: Double
        var opacity: Double        // accumulated through ancestor (effect #:opacity)
        var cornerRadius: Double?  // extracted from enclosing clip path if it's a rounded rect
        var fillColor: String?     // "#RRGGBBAA"
        var imageSize: (Double, Double)?
        var text: String?
        var font: String?
        var fontSize: Double?
        var alignment: String?
        var lineSpacing: Double?
        /// false when the item was synthesised from the attributed-string
        /// fallback path (macOS CGDrawingLayer) — frame fields are 0 and
        /// should not be rendered or relied upon by consumers.
        var hasFrame: Bool = true
        /// Forms inside the item that we recognised the kind of but didn't
        /// otherwise project into a typed field — version, content-seed,
        /// raw clip path, raw style, etc. Round-tripped to JSON in
        /// `--items` mode so consumers can inspect any token we don't
        /// hand-pick into the typed columns.
        var extras: [String: String] = [:]
    }

    // MARK: - Public entry

    /// Run the full pipeline (collect leafs → parse attributed strings → walk
    /// display-list) and return the items array. Used by both `--summary`
    /// (which formats as a table) and `--items` (which serialises as JSON).
    static func extractItems(fromJSON jsonString: String) -> [Item]? {
        guard let data = jsonString.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var leafStrings: [String] = []
        collectLeafStrings(parsed["viewDebugData"], into: &leafStrings)

        var attrIndex: [String: AttrInfo] = [:]
        for s in leafStrings where s.contains("NSFont") {
            if let info = parseAttributedDescription(s) {
                attrIndex[info.text] = info
            }
        }

        var items: [Item] = []
        for s in leafStrings where s.contains("display-list-item") {
            items.append(contentsOf: walkDisplayList(s, attrIndex: attrIndex))
        }

        var seen = Set<String>()
        items = items.filter {
            let k = "\($0.identity)|\($0.x)|\($0.y)|\($0.w)|\($0.h)|\($0.kind)|\($0.text ?? "")"
            if seen.contains(k) { return false }
            seen.insert(k); return true
        }

        // Fallback for macOS CGDrawingLayer rendering path: no display-list-item
        // is emitted, but attributed-string descriptions (NSFont-tagged leaf
        // strings) are still present. Surface them as frame-less text items so
        // --summary and --items remain useful on macOS.
        if items.isEmpty && !attrIndex.isEmpty {
            items = attrIndex.values
                .sorted(by: { $0.text < $1.text })
                .compactMap { info -> Item? in
                    guard !info.text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                    var it = Item(identity: "", kind: "text",
                                  x: 0, y: 0, w: 0, h: 0, opacity: 1.0,
                                  cornerRadius: nil, fillColor: info.color,
                                  imageSize: nil, text: info.text, font: info.font,
                                  fontSize: info.fontSize, alignment: info.alignment,
                                  lineSpacing: info.lineSpacing)
                    it.hasFrame = false
                    return it
                }
        }

        return items
    }

    static func render(fromJSON jsonString: String) -> String {
        guard let items = extractItems(fromJSON: jsonString) else {
            return "(error: could not parse swiftui-debug JSON)"
        }
        if items.isEmpty {
            return "(no display-list items decoded — try the full JSON output without --summary)"
        }
        return formatTable(items)
    }

    /// JSON-serialised items. Each item is a dictionary with all typed
    /// fields plus an `extras` sub-dict for tokens that the formatted table
    /// doesn't surface (version / content-seed / raw clip-path / raw style /
    /// platform-group flag, etc.). Suitable as a stable wire format for
    /// downstream tooling that needs more than `--summary` exposes.
    static func renderItemsJSON(fromJSON jsonString: String) -> String {
        guard let items = extractItems(fromJSON: jsonString) else {
            return "[]"
        }
        let array: [[String: Any]] = items.map { it in
            var d: [String: Any] = [
                "identity": it.identity,
                "kind": it.kind,
                "hasFrame": it.hasFrame,
                "opacity": it.opacity,
            ]
            if it.hasFrame {
                d["x"] = it.x; d["y"] = it.y; d["w"] = it.w; d["h"] = it.h
            }
            if let r = it.cornerRadius { d["cornerRadius"] = r }
            if let c = it.fillColor    { d["fillColor"] = c }
            if let s = it.imageSize    { d["imageSize"] = ["w": s.0, "h": s.1] }
            if let t = it.text         { d["text"] = t }
            if let f = it.font         { d["font"] = f }
            if let s = it.fontSize     { d["fontSize"] = s }
            if let a = it.alignment    { d["alignment"] = a }
            if let l = it.lineSpacing  { d["lineSpacing"] = l }
            if !it.extras.isEmpty      { d["extras"] = it.extras }
            return d
        }
        let opts: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .fragmentsAllowed]
        guard let data = try? JSONSerialization.data(withJSONObject: array, options: opts),
              let str = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return str
    }

    // MARK: - Table render

    private static func formatTable(_ items: [Item]) -> String {
        // macOS CGDrawingLayer fallback: all items lack frame info
        if items.allSatisfy({ !$0.hasFrame }) {
            return formatFramelessTable(items)
        }

        func pad(_ s: String, _ n: Int) -> String {
            let len = s.count
            if len >= n { return clipString(s, n) }
            return s + String(repeating: " ", count: n - len)
        }

        let columns = [
            ("ID", 5), ("KIND", 9),
            ("X", 4), ("Y", 4), ("W", 4), ("H", 4),
            ("ALPHA", 5), ("RADIUS", 7),
            ("CONTENT", 64),
        ]
        var header = ""
        for (h, w) in columns { header += pad(h, w) + "  " }
        var lines = [header.trimmingCharacters(in: .whitespaces),
                     String(repeating: "-", count: header.count - 2)]

        for it in items {
            var content = ""
            switch it.kind {
            case "text":
                let parts: [String] = [
                    it.text.map { "\"\($0)\"" } ?? "",
                    it.font ?? "?",
                    it.fontSize.map { String(format: "%.0fpt", $0) } ?? "",
                    it.fillColor ?? "",
                    it.alignment ?? "",
                    it.lineSpacing.map { "lsp=\(Int($0))" } ?? "",
                ]
                content = parts.filter { !$0.isEmpty }.joined(separator: " ")
            case "fill":
                content = it.fillColor ?? ""
            case "image":
                if let sz = it.imageSize { content = String(format: "img(%.0f×%.0f)", sz.0, sz.1) }
            case "platform":
                content = "(platform-view — UIKit/AppKit child not introspected here)"
            default:
                content = ""
            }

            var row = ""
            row += pad(it.identity.isEmpty ? "-" : it.identity, 5) + "  "
            row += pad(it.kind, 9) + "  "
            row += pad(String(format: "%.0f", it.x), 4) + "  "
            row += pad(String(format: "%.0f", it.y), 4) + "  "
            row += pad(String(format: "%.0f", it.w), 4) + "  "
            row += pad(String(format: "%.0f", it.h), 4) + "  "
            row += pad(String(format: "%.2f", it.opacity), 5) + "  "
            row += pad(it.cornerRadius.map { String(format: "%.1f", $0) } ?? "-", 7) + "  "
            row += clipString(content, 64)
            lines.append(row)
        }

        // Footer documenting unrepresentable dimensions so consumers know
        // to consult the source code for them.
        lines.append("")
        lines.append("Notes:")
        lines.append("  - Border (width/color), shadow (color/blur/offset), and Button/Toggle state")
        lines.append("    (enabled/pressed/focused) cannot be extracted from SwiftUI's display list.")
        lines.append("    Audit those at the source-code layer; this table does not represent them.")
        lines.append("  - RADIUS is heuristic, derived from clip-path geometry; may be ± 1pt off the")
        lines.append("    SwiftUI source value due to anti-alias path expansion.")

        return lines.joined(separator: "\n")
    }

    /// Compact table for the macOS CGDrawingLayer fallback path where frame
    /// information is unavailable. Shows TEXT / FONT / SIZE / COLOR only.
    private static func formatFramelessTable(_ items: [Item]) -> String {
        func clip(_ s: String, _ n: Int) -> String {
            s.count <= n ? s : String(s.prefix(n - 1)) + "…"
        }
        func pad(_ s: String, _ n: Int) -> String {
            let c = clip(s, n)
            return c + String(repeating: " ", count: n - c.count)
        }
        let cols: [(String, Int)] = [("TEXT", 50), ("FONT", 24), ("SIZE", 6), ("COLOR", 10)]
        let header = cols.map { pad($0.0, $0.1) }.joined(separator: "  ")
        var lines = [
            "(macOS CGDrawingLayer path — position unavailable; text/font/color only)",
            header.trimmingCharacters(in: .whitespaces),
            String(repeating: "-", count: cols.reduce(0) { $0 + $1.1 + 2 } - 2),
        ]
        for it in items where it.kind == "text" {
            guard let text = it.text else { continue }
            let row = [
                pad("\"\(text)\"", 50),
                pad(it.font ?? "?", 24),
                pad(it.fontSize.map { String(format: "%.0fpt", $0) } ?? "?", 6),
                clip(it.fillColor ?? "?", 10),
            ].joined(separator: "  ")
            lines.append(row)
        }
        return lines.joined(separator: "\n")
    }

    private static func clipString(_ s: String, _ n: Int) -> String {
        if s.count <= n { return s }
        return String(s.prefix(n - 1)) + "…"
    }

    private static func collectLeafStrings(_ node: Any?, into out: inout [String]) {
        switch node {
        case let s as String:
            if !s.isEmpty { out.append(s) }
        case let dict as [String: Any]:
            for (_, v) in dict { collectLeafStrings(v, into: &out) }
        case let arr as [Any]:
            for v in arr { collectLeafStrings(v, into: &out) }
        default:
            break
        }
    }

    // MARK: - Attributed-string description parsing

    struct AttrInfo {
        var text: String
        var font: String?
        var fontSize: Double?
        var alignment: String?
        var lineSpacing: Double?
        var color: String?
    }

    private static func parseAttributedDescription(_ s: String) -> AttrInfo? {
        guard let braceIdx = s.firstIndex(of: "{") else { return nil }
        let text = String(s[..<braceIdx])
        if text.contains("\n") || text.count > 200 { return nil }
        if !s.contains("NSFont") { return nil }

        var info = AttrInfo(text: text)

        if let r = s.range(of: "([.A-Za-z0-9-]+)\\s+(\\d+(?:\\.\\d+)?)\\s*pt", options: .regularExpression) {
            let parts = s[r].split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            if parts.count >= 2 {
                info.font = String(parts[0])
                info.fontSize = Double(parts[1])
            }
        }
        if let r = s.range(of: "Alignment\\s+(\\w+)", options: .regularExpression),
           let p = s[r].split(separator: " ").last {
            info.alignment = String(p).trimmingCharacters(in: .punctuationCharacters)
        }
        if let r = s.range(of: "LineSpacing\\s+(\\d+(?:\\.\\d+)?)", options: .regularExpression),
           let p = s[r].split(separator: " ").last {
            info.lineSpacing = Double(p)
        }
        if let r = s.range(of: "NSColor\\s*=\\s*\"[^\"]+\"", options: .regularExpression) {
            let nums = s[r].split(whereSeparator: { !"0123456789.".contains($0) })
                .compactMap { Double($0) }
            if nums.count >= 4 {
                let r = nums[nums.count-4], g = nums[nums.count-3], b = nums[nums.count-2], a = nums[nums.count-1]
                info.color = String(format: "#%02X%02X%02X%02X",
                                    Int((r * 255).rounded()), Int((g * 255).rounded()),
                                    Int((b * 255).rounded()), Int((a * 255).rounded()))
            }
        }
        return info
    }

    // MARK: - S-expression parser

    indirect enum Sexpr {
        case atom(String)
        case list([Sexpr])
        case str(String)
    }

    private static func tokenize(_ s: String) -> [Substring] {
        var out: [Substring] = []
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "(" || c == ")" {
                out.append(Substring(String(c)))
                i += 1
            } else if c == "\"" {
                // Read until matching unescaped quote
                let start = i
                i += 1
                while i < chars.count, chars[i] != "\"" {
                    if chars[i] == "\\" && i + 1 < chars.count { i += 2 } else { i += 1 }
                }
                i += 1
                let str = String(chars[start..<min(i, chars.count)])
                out.append(Substring(str))
            } else if c.isWhitespace {
                i += 1
            } else {
                let start = i
                while i < chars.count, !chars[i].isWhitespace, chars[i] != "(", chars[i] != ")" {
                    i += 1
                }
                out.append(Substring(String(chars[start..<i])))
            }
        }
        return out
    }

    private static func parseSexpr(_ tokens: [Substring], _ pos: inout Int) -> Sexpr {
        let tok = tokens[pos]; pos += 1
        if tok == "(" {
            var children: [Sexpr] = []
            while pos < tokens.count, tokens[pos] != ")" {
                children.append(parseSexpr(tokens, &pos))
            }
            if pos < tokens.count { pos += 1 } // consume ')'
            return .list(children)
        } else if tok.first == "\"" {
            let raw = String(tok)
            let trimmed = String(raw.dropFirst().dropLast())
            return .str(trimmed)
        } else {
            return .atom(String(tok))
        }
    }

    // MARK: - Display-list walker

    /// Walks a display-list string and emits one Item per drawn primitive.
    /// Tracks parent-relative frame accumulation so all rows have absolute
    /// (X, Y) in the hosting view's local coordinate space.
    private static func walkDisplayList(_ s: String, attrIndex: [String: AttrInfo]) -> [Item] {
        let tokens = tokenize(s)
        var pos = 0
        // Top-level is `[ (display-list-item ...) ]` per Apple's framing.
        // Skip the outer brackets if present.
        var items: [Item] = []
        // Filter only ( and ) and atoms — brackets [] are not expected to nest at this layer.
        while pos < tokens.count, tokens[pos] != "(" { pos += 1 }
        if pos >= tokens.count { return items }
        let tree = parseSexpr(tokens, &pos)
        walkNode(tree, originX: 0, originY: 0, opacity: 1.0, cornerRadius: nil,
                 attrIndex: attrIndex, into: &items)
        return items
    }

    private static func walkNode(_ node: Sexpr,
                                 originX: Double, originY: Double,
                                 opacity: Double,
                                 cornerRadius: Double?,
                                 attrIndex: [String: AttrInfo],
                                 into items: inout [Item]) {
        guard case .list(let children) = node else { return }
        guard let head = children.first, case .atom(let headName) = head else {
            for c in children {
                walkNode(c, originX: originX, originY: originY, opacity: opacity,
                         cornerRadius: cornerRadius, attrIndex: attrIndex, into: &items)
            }
            return
        }

        switch headName {
        case "display-list-item":
            // Top wrapper: just descend
            for c in children.dropFirst() {
                walkNode(c, originX: originX, originY: originY, opacity: opacity,
                         cornerRadius: cornerRadius, attrIndex: attrIndex, into: &items)
            }

        case "item":
            handleItem(children: Array(children.dropFirst()),
                       parentOriginX: originX, parentOriginY: originY,
                       parentOpacity: opacity, parentCornerRadius: cornerRadius,
                       attrIndex: attrIndex, into: &items)

        default:
            // Unknown top-level — descend
            for c in children {
                walkNode(c, originX: originX, originY: originY, opacity: opacity,
                         cornerRadius: cornerRadius, attrIndex: attrIndex, into: &items)
            }
        }
    }

    /// Handles the body of an `(item #:identity N #:version V #:required B (frame ...) ...)` form.
    private static func handleItem(children: [Sexpr],
                                   parentOriginX: Double, parentOriginY: Double,
                                   parentOpacity: Double, parentCornerRadius: Double?,
                                   attrIndex: [String: AttrInfo],
                                   into items: inout [Item]) {
        var identity = ""
        var localFrame: (Double, Double, Double, Double) = (0, 0, 0, 0)
        var bodyForms: [Sexpr] = []
        let nodeOpacity: Double = 1.0
        let nodeCornerRadius: Double? = nil
        // Captures keyword pairs on the item itself (e.g. #:version 1801,
        // #:required true). Surfaces in `extras` for `--items` consumers.
        var itemKeywords: [String: String] = [:]

        // Walk each form to extract identity + frame and stash the rest.
        var i = 0
        while i < children.count {
            switch children[i] {
            case .atom(let a):
                if a.hasPrefix("#:identity"), i + 1 < children.count, case .atom(let v) = children[i+1] {
                    identity = v
                    i += 2
                    continue
                }
                if a.hasPrefix("#:") {
                    // Capture keyword/value pair (e.g. #:version 1801, #:required true)
                    if i + 1 < children.count, case .atom(let v) = children[i+1] {
                        let key = String(a.dropFirst(2))
                        itemKeywords[key] = v
                    }
                    i += 2
                    continue
                }
                i += 1
            case .list(let kids):
                if let h = kids.first, case .atom(let hn) = h {
                    if hn == "frame" {
                        // (frame (X Y; W H))  -- inner is parsed as a list of atoms with the ; treated as part of token
                        if let f = parseFrame(kids) {
                            localFrame = f
                        }
                        i += 1; continue
                    }
                }
                bodyForms.append(children[i])
                i += 1
            default:
                i += 1
            }
        }

        let absX = parentOriginX + localFrame.0
        let absY = parentOriginY + localFrame.1
        let w = localFrame.2
        let h = localFrame.3

        // Pre-pass over body forms: find effect with #:opacity, find any clip
        // that wraps later children.
        var contentSeed: String? = nil
        var didEmit = false

        for form in bodyForms {
            guard case .list(let kids) = form, let head = kids.first,
                  case .atom(let headName) = head else { continue }

            switch headName {
            case "effect":
                // Look for #:opacity and #:platform-group atoms
                var localOpacity = 1.0
                var idx = 1
                while idx < kids.count {
                    if case .atom(let a) = kids[idx], a == "#:opacity",
                       idx + 1 < kids.count, case .atom(let v) = kids[idx+1],
                       let o = Double(v) {
                        localOpacity = o
                        idx += 2
                        continue
                    }
                    if case .atom(_) = kids[idx] { idx += 1; continue }
                    break
                }
                let nestedOpacity = parentOpacity * localOpacity * nodeOpacity
                // Children of effect inherit any clip set by sibling clip forms.
                var inheritedClip: Double? = nodeCornerRadius ?? parentCornerRadius
                for inner in kids.dropFirst() {
                    guard case .list(let innerKids) = inner,
                          let innerHead = innerKids.first,
                          case .atom(let innerName) = innerHead else { continue }
                    if innerName == "clip" {
                        // find (path ...) inside; pass the item's outer
                        // width/height so the heuristic can bound the radius.
                        for c in innerKids.dropFirst() {
                            if case .list(let pk) = c, let pkHead = pk.first,
                               case .atom("path") = pkHead {
                                inheritedClip = extractRoundedRectRadius(from: pk, width: w, height: h)
                            }
                        }
                        continue
                    }
                    if innerName == "item" {
                        handleItem(children: Array(innerKids.dropFirst()),
                                   parentOriginX: absX, parentOriginY: absY,
                                   parentOpacity: nestedOpacity,
                                   parentCornerRadius: inheritedClip,
                                   attrIndex: attrIndex, into: &items)
                    }
                }

            case "color":
                // (color #RRGGBBAA) — emit a fill row for *this* item
                if kids.count >= 2, case .atom(let a) = kids[1] {
                    var color = a
                    if color.hasPrefix("#") {
                        color = "#" + String(color.dropFirst()).uppercased()
                    }
                    var item = Item(
                        identity: identity, kind: "fill",
                        x: absX, y: absY, w: w, h: h,
                        opacity: parentOpacity * nodeOpacity,
                        cornerRadius: parentCornerRadius,
                        fillColor: color, imageSize: nil,
                        text: nil, font: nil, fontSize: nil, alignment: nil, lineSpacing: nil)
                    item.extras = itemKeywords
                    items.append(item)
                    didEmit = true
                }

            case "text":
                // (text "..." #:size (W H))
                var text = ""
                if kids.count >= 2, case .str(let str) = kids[1] {
                    text = str
                }
                let attr = attrIndex[text]
                var item = Item(
                    identity: identity, kind: "text",
                    x: absX, y: absY, w: w, h: h,
                    opacity: parentOpacity * nodeOpacity,
                    cornerRadius: parentCornerRadius,
                    fillColor: attr?.color, imageSize: nil,
                    text: text, font: attr?.font, fontSize: attr?.fontSize,
                    alignment: attr?.alignment, lineSpacing: attr?.lineSpacing)
                item.extras = itemKeywords
                items.append(item)
                didEmit = true

            case "image":
                // (image #:size (W H))
                var imgSize: (Double, Double)? = nil
                for k in kids {
                    if case .list(let pk) = k, pk.count == 2,
                       case .atom(let aw) = pk[0], case .atom(let ah) = pk[1],
                       let dw = Double(aw), let dh = Double(ah) {
                        imgSize = (dw, dh)
                    }
                }
                var item = Item(
                    identity: identity, kind: "image",
                    x: absX, y: absY, w: w, h: h,
                    opacity: parentOpacity * nodeOpacity,
                    cornerRadius: parentCornerRadius,
                    fillColor: nil, imageSize: imgSize,
                    text: nil, font: nil, fontSize: nil, alignment: nil, lineSpacing: nil)
                item.extras = itemKeywords
                items.append(item)
                didEmit = true

            case "platform-view":
                var item = Item(
                    identity: identity, kind: "platform",
                    x: absX, y: absY, w: w, h: h,
                    opacity: parentOpacity * nodeOpacity,
                    cornerRadius: parentCornerRadius,
                    fillColor: nil, imageSize: nil,
                    text: nil, font: nil, fontSize: nil, alignment: nil, lineSpacing: nil)
                item.extras = itemKeywords
                items.append(item)
                didEmit = true

            case "content-seed":
                if kids.count >= 2, case .atom(let s) = kids[1] { contentSeed = s }

            default:
                break
            }
        }

        if let cs = contentSeed {
            itemKeywords["content-seed"] = cs
        }

        if !didEmit && (w > 0 || h > 0) {
            var item = Item(
                identity: identity, kind: "group",
                x: absX, y: absY, w: w, h: h,
                opacity: parentOpacity * nodeOpacity,
                cornerRadius: parentCornerRadius,
                fillColor: nil, imageSize: nil,
                text: nil, font: nil, fontSize: nil, alignment: nil, lineSpacing: nil)
            item.extras = itemKeywords
            items.append(item)
        }
    }

    /// Parses `(frame (X Y; W H))`. The `X Y; W H` block tokenises with `;`
    /// as part of one atom because our tokenizer keeps it attached to `Y`.
    private static func parseFrame(_ kids: [Sexpr]) -> (Double, Double, Double, Double)? {
        guard kids.count >= 2, case .list(let nums) = kids[1] else { return nil }
        // Concatenate all atoms, split on whitespace + `;` to recover four floats.
        var floats: [Double] = []
        for n in nums {
            if case .atom(let a) = n {
                let cleaned = a.replacingOccurrences(of: ";", with: " ")
                                .replacingOccurrences(of: ",", with: " ")
                for tok in cleaned.split(separator: " ") {
                    if let d = Double(tok) { floats.append(d) }
                }
            }
        }
        if floats.count >= 4 {
            return (floats[0], floats[1], floats[2], floats[3])
        }
        return nil
    }

    /// Heuristic corner-radius extractor for a SwiftUI rounded-rect / capsule
    /// clip path. SwiftUI emits the path starting at point `(W, R) m` where
    /// `R` is the corner radius (from the right-edge midpoint going down).
    /// We look at the first `m` (move-to) command and read the two numbers
    /// preceding it; the second one is the radius. Returns nil if the path
    /// doesn't start with a move-to (i.e. not a rounded-rect-shaped clip).
    private static func extractRoundedRectRadius(from kids: [Sexpr], width: Double, height: Double) -> Double? {
        guard width > 0, height > 0 else { return nil }
        // Read out the path's atoms in order.
        var atoms: [String] = []
        for k in kids {
            if case .atom(let a) = k { atoms.append(a) }
        }
        // Find the first 'm' command and read the two preceding floats.
        for (i, atom) in atoms.enumerated() {
            if atom == "m", i >= 2,
               let x = Double(atoms[i-2]),
               let y = Double(atoms[i-1]) {
                // SwiftUI starts at (W, R); a capsule's R == H/2.
                // Sanity-check: y must be in (0, H/2 + 1pt slop].
                let limit = min(width, height) / 2 + 1
                if y > 0 && y <= limit && abs(x - width) < 1 {
                    return y
                }
            }
        }
        return nil
    }
}

/// Renders Apple's `makeViewDebugData` payload as a SwiftUI-style indented
/// view tree — the same shape a developer would write in source.
///
/// Apple's payload is a tree of nodes, each with a `properties` array. Most
/// properties are layout/modifier metadata (CGSize, _PaddingLayout, ViewTransform,
/// _SafeAreaInsetsModifier, ...). The actual visible view kind shows up as
/// one of the property `readableType` strings — `Text`, `Image`, `Button<...>`,
/// `VStack<...>`, `HStack<...>`, `ZStack<...>`, `ResolvedProgressView`, etc.
///
/// We walk the children tree and only emit a line when a node's properties
/// contain one of those kinds. Wrapper modifiers (anything else) are skipped
/// silently — their children attach to the nearest emitted ancestor. This
/// matches what `lookinside hierarchy` does for AppKit chrome but for the
/// SwiftUI side, and produces output like:
///
///     VStack
///       Text
///       ZStack
///         Rectangle
///         Image
///         Image
///       HStack
///         Text
///         Text
///         Text
///
/// The kept-kinds set is intentionally conservative — adding more types is
/// safe but pollutes the tree with low-value nodes (`OptionalSourceWriter`,
/// `_VariadicView.Tree`, etc.). Override via `--include-kind` later if needed.
private enum SwiftUIViewTree {

    /// View kinds we surface in the rendered tree. Anything else is treated
    /// as a transparent wrapper. Match is on the *base* of the readable type
    /// string, i.e. the identifier before the first `<`.
    ///
    /// In addition to this explicit set, `nodeKindAndAnnotation` surfaces any
    /// type whose readable name belongs to a module outside `SwiftUI`/`Swift`
    /// — that catches user-defined views (`AppContentView`, `PosterCard`,
    /// etc.) without having to list them, giving you the same left-rail
    /// detail Xcode's View Debugger shows for the hosted root.
    private static let viewKinds: Set<String> = [
        // Layout containers
        "VStack", "HStack", "ZStack", "LazyVStack", "LazyHStack",
        "LazyVGrid", "LazyHGrid", "Grid", "GridRow",
        "Group", "Section", "Form", "List", "Table",
        "ScrollView", "ScrollViewReader", "GeometryReader",
        "NavigationStack", "NavigationView", "NavigationSplitView",
        "NavigationLink",
        "TabView",

        // Leaf views
        "Text", "Label", "Image", "Color", "Shape",
        "Rectangle", "RoundedRectangle", "Circle", "Capsule", "Ellipse", "Path",
        "Spacer", "Divider", "EmptyView", "AnyView",

        // Interactive
        "Button", "Toggle", "Picker", "Slider", "Stepper", "Menu",
        "TextField", "SecureField", "TextEditor",
        "DatePicker", "ColorPicker", "Link",

        // Indicators
        "ProgressView", "ResolvedProgressView",

        // SwiftUI-internal but useful as anchors
        "ForEach", "TupleView",

        // NavigationSplitView / NavigationStack runtime scaffolding.
        // These are SwiftUI private types but they are the only things
        // visible *at the NavigationSplit column level* — without them the
        // tree collapses to a single ZStack and hides column separation.
        "NavigationSplitCore", "_NavigationSplitReader",
        "NavigationStackCore", "StatefulNavigationStackChildren",
        "ExplicitStack", "StackSubstructure",
        "VariadicViewForest", "_VariadicView",
        "ColumnView", "SidebarStyleContext", "ContainerStyleContext",

        // Platform bridges — useful to see because they mark where SwiftUI
        // hands off to an AppKit/UIKit representable or a nested hosting view.
        "PlatformViewRepresentableAdaptor", "DraggingDestinationView",
        "AppKitPlatformViewHost",

        // Conditional branches that shape the user-visible tree. We keep
        // _ConditionalContent because it's the only way to tell that an
        // `if ... else` is present; _OverlayModifier because .overlay() is
        // a first-class layout primitive for stacking.
        "_ConditionalContent", "_OverlayModifier",
        "ViewLeafView",
    ]

    /// Returns true if @c node looks like a real SwiftUI view-debug payload
    /// (an array or dict with `children` somewhere) rather than the
    /// `{"error": "..."}` placeholder Apple's makeViewDebugData returns when
    /// it can't serialise the requested hosting view.
    private static func isUsefulDebugTree(_ node: Any?) -> Bool {
        if let arr = node as? [Any] { return !arr.isEmpty }
        if let dict = node as? [String: Any] {
            if dict["error"] != nil && dict.count == 1 { return false }
            return !dict.isEmpty
        }
        return false
    }

    static func render(fromJSON jsonString: String) -> String {
        guard let data = jsonString.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "(error: could not parse swiftui-debug JSON)"
        }

        // Pick the most informative source. SwiftUI's makeViewDebugData
        // sometimes returns just `{"error": "..."}` for the main hosting view
        // (NavigationSplit roots in particular trigger an Apple-internal
        // serialisation failure). When that happens, fall back to
        // accessibilityDebugData which carries the same {attribute, children,
        // kind, type} shape and survives Apple's encoding bug.
        var root: Any? = nil
        let vdd = parsed["viewDebugData"]
        if isUsefulDebugTree(vdd) {
            root = vdd
        } else if let ax = parsed["accessibilityDebugData"], isUsefulDebugTree(ax) {
            root = ax
        } else {
            root = vdd ?? parsed["accessibilityDebugData"]
        }
        guard let root else {
            return "(viewDebugData missing — server did not return SwiftUI tree)"
        }

        // Two-pass: first collect a real tree (so each rendered node knows
        // its siblings and can pick ├── vs └── + │   vs four-space prefix).
        let roots = collectTrees(root)
        if roots.isEmpty {
            return "(no SwiftUI views detected — try the full JSON output without --tree)"
        }
        var out: [String] = []
        for (i, node) in roots.enumerated() {
            renderTree(node, prefix: "", isLast: i == roots.count - 1, isRoot: true, into: &out)
        }
        return out.joined(separator: "\n")
    }

    /// Tree node that represents one *visible* SwiftUI view kind plus the
    /// (possibly transparent) wrapper subtree beneath it.
    private final class Node {
        let kind: String
        var annotation: String?      // e.g. `"登录"` for Text, `asset="qrcode"` for Image
        var children: [Node] = []
        init(_ kind: String, annotation: String? = nil) {
            self.kind = kind
            self.annotation = annotation
        }
    }

    /// Walks the JSON tree, collecting only nodes whose properties match a
    /// known view kind. Transparent wrappers (modifiers, _PaddingLayout, etc.)
    /// are collapsed: their visible children re-parent to the nearest visible
    /// ancestor — exactly the same logic the previous flat-line walker had,
    /// but materialised so the renderer can draw connectors.
    private static func collectTrees(_ node: Any) -> [Node] {
        var roots: [Node] = []
        collect(node, into: &roots)
        return roots
    }

    private static func collect(_ node: Any, into siblings: inout [Node]) {
        if let arr = node as? [Any] {
            for c in arr { collect(c, into: &siblings) }
            return
        }
        guard let dict = node as? [String: Any] else { return }

        if let (kind, annotation) = nodeKindAndAnnotation(dict) {
            let n = Node(kind, annotation: annotation)
            for child in (dict["children"] as? [Any] ?? []) {
                collect(child, into: &n.children)
            }
            siblings.append(n)
        } else {
            for child in (dict["children"] as? [Any] ?? []) {
                collect(child, into: &siblings)
            }
        }
    }

    /// Renders a tree node as its own line plus recursive children, using
    /// box-drawing connectors:
    ///
    ///     VStack
    ///     ├── Text  "title"
    ///     ├── ZStack
    ///     │   ├── Rectangle
    ///     │   ├── Image  asset="qrcode"
    ///     │   └── Image  asset="logo"
    ///     └── HStack
    ///         ├── Text  "请使用"
    ///         ├── Text  "手机端网易爆米花"
    ///         └── Text  "扫码登录或扫码下载网易爆米花 App"
    ///
    /// `prefix` carries the connector ladder for ancestors (│ if there's
    /// still a sibling below, four spaces if the ancestor was the last).
    /// `isRoot` suppresses the connector for the very first level so the
    /// root view kind sits flush left.
    private static func renderTree(_ node: Node,
                                   prefix: String,
                                   isLast: Bool,
                                   isRoot: Bool,
                                   into out: inout [String]) {
        var label = node.kind
        if let a = node.annotation, !a.isEmpty {
            label += "  " + a
        }
        let line: String
        if isRoot {
            line = label
        } else {
            let connector = isLast ? "└── " : "├── "
            line = prefix + connector + label
        }
        out.append(line)

        let childPrefix: String
        if isRoot {
            childPrefix = ""
        } else {
            childPrefix = prefix + (isLast ? "    " : "│   ")
        }
        for (i, child) in node.children.enumerated() {
            renderTree(child,
                       prefix: childPrefix,
                       isLast: i == node.children.count - 1,
                       isRoot: false,
                       into: &out)
        }
    }

    /// Inspects a node's `properties` array, returns (kind, annotation).
    /// Annotation is a short human-readable description shown after the kind:
    ///   - Text   → `"verbatim string" Npt`
    ///   - Image  → `asset="<name>"` for catalog/symbol assets
    ///   - Color  → `rgba(r,g,b,a)` for resolved literals,
    ///              `name="<token>"` for catalog colours
    ///   - Stack  → `(N items)` if TupleView arity is recoverable
    ///   - ProgressView → `(indeterminate)` when the value carries that flag
    /// Returns nil for nodes that aren't visible view kinds.
    ///
    /// Two node shapes are accepted:
    ///   1. `viewDebugData` form: `{"properties": [{"attribute": {"readableType": "..."}}], "children": [...]}`
    ///   2. `accessibilityDebugData` form: `{"type": "SwiftUI.VStack<...>", "kind": "view", "children": [...]}`
    /// The AX form is used as a fallback when `makeViewDebugData` returns an
    /// error dict (e.g. NavigationSplit column hosts on macOS 26) but the
    /// same hosting view's AX graph is usable.
    private static func nodeKindAndAnnotation(_ node: [String: Any]) -> (String, String?)? {
        // Shape 1: viewDebugData — rich `properties` with nested attributes
        // carrying verbatim/size/asset/color etc. This is the preferred path
        // because it still has annotation-worthy data.
        if let props = node["properties"] as? [[String: Any]] {
            for p in props {
                let attr = (p["attribute"] as? [String: Any]) ?? p
                guard let t = attr["readableType"] as? String, !t.isEmpty else { continue }
                let base = String(t.prefix(while: { $0 != "<" }))
                // viewDebugData drops the module prefix from `readableType`
                // ("AppContentView" instead of "网易爆米花测试.AppContentView"),
                // but keeps it on the sibling `type` field. Pull the module
                // out of there so the user-defined-view rule still fires for
                // app-defined views like `AppContentView`.
                let module: String? = {
                    guard let full = attr["type"] as? String else { return nil }
                    let (_, m) = axBaseAndModule(full)
                    return m
                }()
                if let surfaced = surfaceName(base: base, module: module) {
                    let annotation = annotationFor(kind: surfaced, attr: attr,
                                                    fullType: t, node: node)
                    return (surfaced, annotation)
                }
            }
        }

        // Shape 2: accessibilityDebugData — bare `type` on the node itself.
        // No annotation data (no verbatim/size/asset), so we only emit the
        // kind. Use this branch whenever we're walking the AX fallback tree.
        if let t = node["type"] as? String, !t.isEmpty {
            // AX types are fully qualified: "SwiftUI.VStack<...>",
            // "网易爆米花测试.AppContentView", "SwiftUI.(unknown context at
            // $1bc34a2c4)._NavigationSplitReader". Strip module + any
            // "(unknown context at ...)" decoration, then the generic tail.
            let (base, module) = axBaseAndModule(t)
            if let surfaced = surfaceName(base: base, module: module) {
                return (surfaced, nil)
            }
        }
        return nil
    }

    /// Applies the surface/hide policy:
    ///   1. Explicit `viewKinds` whitelist always wins.
    ///   2. User-defined views (carrying an AX-form module prefix that is
    ///      neither SwiftUI. nor Swift.) are surfaced verbatim — this is
    ///      how `AppContentView`, `FloatingBubbleView`, `MyRowView`, etc.
    ///      show up without having to list them.
    ///   3. Everything else (SwiftUI internals, modifiers, effect views,
    ///      renderer plumbing) is collapsed. This matches what Xcode's View
    ///      Debugger left rail shows — a tree of user-meaningful containers
    ///      and leaves, not every `ModifiedContent` / `*Modifier` /
    ///      `OpacityRendererEffect` / `PlaceholderContentView` wrapper.
    ///
    /// `module` is the dotted module prefix from the AX `type` field (e.g.
    /// "SwiftUI", "Swift", "网易爆米花测试"). Pass nil when the node came
    /// from viewDebugData (which doesn't carry the module qualifier — the
    /// whitelist branch is the only one that fires there).
    private static func surfaceName(base: String, module: String? = nil) -> String? {
        if viewKinds.contains(base) {
            return prettyName(base)
        }
        // User-defined view: module prefix outside the SwiftUI/Swift
        // namespace (and not one of the anonymous "unknown context" shims,
        // which we've already stripped in axBaseType).
        //
        // Excluded modules:
        //   - SwiftUI / _SwiftUI : framework internals
        //   - Swift              : Swift stdlib (Optional, Array, ...)
        //   - Foundation         : NSDate, NSURL bridges
        //   - __C / __C_Synthesized : Imported C / Core Graphics
        //                          structs (CGSize, CGPoint, CGRect, ...).
        //                          These show up as `properties` siblings
        //                          on every SwiftUI node and are pure
        //                          layout metadata, not visual elements.
        if let module, !module.isEmpty,
           module != "SwiftUI", module != "_SwiftUI",
           module != "Swift", module != "Foundation",
           module != "__C", module != "__C_Synthesized",
           !base.isEmpty, !base.hasPrefix("_") {
            // Guard against the empty/backtick-first edge cases.
            if let first = base.first, first.isLetter {
                return base
            }
        }
        return nil
    }

    /// Parses a fully-qualified AX type string into (base, module).
    /// Examples:
    ///   "SwiftUI.VStack<SwiftUI.TupleView<...>>"        -> ("VStack", "SwiftUI")
    ///   "SwiftUI.(unknown context at $1bc34a2c4)._NavigationSplitReader"
    ///                                                   -> ("_NavigationSplitReader", "SwiftUI")
    ///   "网易爆米花测试.AppContentView"                  -> ("AppContentView", "网易爆米花测试")
    ///   "Swift.Optional<...>"                           -> ("Optional", "Swift")
    private static func axBaseAndModule(_ fullType: String) -> (String, String?) {
        // Drop generic arguments.
        let noGenerics = String(fullType.prefix(while: { $0 != "<" }))
        // Drop "(unknown context at $...)" decoration.
        var s = noGenerics
        while let r = s.range(of: "(unknown context at $") {
            if let close = s.range(of: ")", range: r.upperBound..<s.endIndex) {
                var end = close.upperBound
                if end < s.endIndex, s[end] == "." {
                    end = s.index(after: end)
                }
                s.removeSubrange(r.lowerBound..<end)
            } else {
                break
            }
        }
        // First dotted segment is the module (unless there is no dot, in
        // which case we have no module info).
        guard let firstDot = s.firstIndex(of: ".") else { return (s, nil) }
        let module = String(s[..<firstDot])
        let rest = String(s[s.index(after: firstDot)...])
        // The base name is the final dotted segment of the remainder so
        // nested types like "NavigationSplitCore.NavigationSplitCoordinator.ColumnView"
        // show as "ColumnView".
        if let lastDot = rest.lastIndex(of: ".") {
            return (String(rest[rest.index(after: lastDot)...]), module)
        }
        return (rest, module)
    }

    /// Builds the per-kind annotation. Each branch is best-effort: if the
    /// expected sub-attribute path isn't present, we silently return nil so
    /// the line stays clean.
    private static func annotationFor(kind: String,
                                       attr: [String: Any],
                                       fullType: String,
                                       node: [String: Any]) -> String? {
        switch kind {
        case "Text":
            return textAnnotation(attr)
        case "Image":
            return imageAnnotation(attr)
        case "Color":
            return colorAnnotation(attr)
        case "VStack", "HStack", "ZStack",
             "LazyVStack", "LazyHStack", "LazyVGrid", "LazyHGrid":
            return stackAnnotation(fullType: fullType)
        case "ProgressView":
            return progressAnnotation(node: node)
        default:
            return nil
        }
    }

    /// Text → `"<verbatim>" <size>pt` (size only when SystemProvider gave it).
    private static func textAnnotation(_ attr: [String: Any]) -> String? {
        let verbatim = deepFindValue(attr: attr, name: "verbatim") as? String
        // Localized text uses `key` instead of `verbatim`.
        let key = deepFindValue(attr: attr, name: "key") as? String
        let str = verbatim ?? key
        let size = deepFindValue(attr: attr, name: "size") as? Double

        var parts: [String] = []
        if let s = str { parts.append("\"\(s)\"") }
        if let sz = size { parts.append(String(format: "%.0fpt", sz)) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Image → `asset="<name>"` for named/system assets, otherwise nil.
    private static func imageAnnotation(_ attr: [String: Any]) -> String? {
        if let name = deepFindValue(attr: attr, name: "name") as? String {
            return "asset=\"\(name)\""
        }
        return nil
    }

    /// Color → `rgba(R,G,B,A)` for resolved literals, `name="<token>"` for
    /// catalog colours, nil for the bare placeholder Color box.
    private static func colorAnnotation(_ attr: [String: Any]) -> String? {
        if let name = deepFindValue(attr: attr, name: "name") as? String {
            return "name=\"\(name)\""
        }
        if let comps = deepFindValue(attr: attr, name: "color") as? [String: Any],
           let arr = comps["color"] as? [Double], arr.count >= 4 {
            return String(format: "rgba(%.2f, %.2f, %.2f, %.2f)", arr[0], arr[1], arr[2], arr[3])
        }
        // Plain `color` array (older SwiftUI without ResolvedHDR wrapper).
        if let arr = deepFindValue(attr: attr, name: "color") as? [Double], arr.count >= 4 {
            return String(format: "rgba(%.2f, %.2f, %.2f, %.2f)", arr[0], arr[1], arr[2], arr[3])
        }
        return nil
    }

    /// VStack / HStack / ZStack → counts immediate items in the TupleView
    /// generic by walking top-level commas. Returns nil when the type doesn't
    /// expose its arity that way.
    private static func stackAnnotation(fullType: String) -> String? {
        guard let s = fullType.range(of: "TupleView<("),
              let e = fullType.range(of: ")>", range: s.upperBound..<fullType.endIndex) else {
            return nil
        }
        let inner = fullType[s.upperBound..<e.lowerBound]
        var depth = 0
        var commas = 0
        for ch in inner {
            switch ch {
            case "<", "(": depth += 1
            case ">", ")": depth -= 1
            case "," where depth == 0: commas += 1
            default: break
            }
        }
        let arity = commas + 1
        return arity > 0 ? "(\(arity) item\(arity == 1 ? "" : "s"))" : nil
    }

    /// ProgressView → `(indeterminate)` when ProgressViewValue.absolute.alwaysIndeterminate.
    private static func progressAnnotation(node: [String: Any]) -> String? {
        for p in (node["properties"] as? [[String: Any]] ?? []) {
            let attr = (p["attribute"] as? [String: Any]) ?? p
            if let v = deepFindValue(attr: attr, name: "alwaysIndeterminate") as? Bool, v {
                return "(indeterminate)"
            }
        }
        return nil
    }

    /// Walks the attribute's `subattributes` tree depth-first, returning the
    /// first leaf whose `name` matches. Used to dig out Text.storage.verbatim,
    /// Image.provider.name, Color.provider.color, etc. without hardcoding the
    /// exact box-class chain (Apple wraps these differently across releases).
    private static func deepFindValue(attr: [String: Any], name target: String) -> Any? {
        if let n = attr["name"] as? String, n == target,
           let v = attr["value"] {
            return v
        }
        for sub in (attr["subattributes"] as? [[String: Any]] ?? []) {
            if let r = deepFindValue(attr: sub, name: target) { return r }
        }
        return nil
    }

    /// Inspects a node's `properties` array, returns the most-specific view
    /// kind we're willing to surface, or nil if none match. Kept as a thin
    /// wrapper for places that want kind-only.
    private static func nodeKind(_ node: [String: Any]) -> String? {
        nodeKindAndAnnotation(node)?.0
    }

    /// `ResolvedProgressView` is SwiftUI's runtime form of `ProgressView`;
    /// re-label so the tree stays familiar to source readers.
    private static func prettyName(_ kind: String) -> String {
        switch kind {
        case "ResolvedProgressView": return "ProgressView"
        default: return kind
        }
    }
}

private struct CLIClient {
    private let client = LICClient()

    func listTargets() throws -> [LICDiscoveredTarget] {
        var error: NSError?
        let targets = client.listTargets(&error)
        if let error {
            throw error
        }
        return targets
    }

    func inspectTarget(id: String) throws -> LICDiscoveredTarget {
        do {
            return try client.inspectTarget(withID: id)
        } catch {
            throw error
        }
    }

    func hierarchy(target: String, format: HierarchyFormat) throws -> String {
        do {
            return try client.hierarchy(forTargetID: target, format: format.rawValue)
        } catch {
            throw error
        }
    }

    func hierarchyWithAttrsJSON(target: String) throws -> String {
        do {
            return try client.hierarchyWithAttrsJSON(forTargetID: target)
        } catch {
            throw error
        }
    }

    func export(target: String, to outputPath: String) throws -> URL {
        do {
            return try client.exportTargetID(target, outputPath: outputPath)
        } catch {
            throw error
        }
    }

    func allAttrGroupsJSON(target: String, oid: UInt) throws -> String {
        do {
            return try client.allAttrGroupsJSON(forTargetID: target, layerOID: oid)
        } catch {
            throw error
        }
    }

    func introspectJSON(target: String, oid: UInt) throws -> String {
        do {
            return try client.introspectJSON(forTargetID: target, oid: oid)
        } catch {
            throw error
        }
    }

    func swiftUIDebugJSON(target: String, oid: UInt) throws -> String {
        do {
            return try client.swiftUIDebugJSON(forTargetID: target, oid: oid)
        } catch {
            throw error
        }
    }
}

private struct FileDestination {
    let url: URL

    init(path: String) throws {
        let expandedPath = NSString(string: path).expandingTildeInPath
        guard !expandedPath.isEmpty else {
            throw CLIError("Output path cannot be empty.")
        }
        url = URL(fileURLWithPath: expandedPath)
    }

    func write(_ string: String) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try string.write(to: url, atomically: true, encoding: .utf8)
    }
}

private struct ExportDestination {
    let path: String

    init(path: String, format: ExportFormat) throws {
        let expandedPath = NSString(string: path).expandingTildeInPath
        guard !expandedPath.isEmpty else {
            throw CLIError("Output path cannot be empty.")
        }

        let url = URL(fileURLWithPath: expandedPath)
        let ext = url.pathExtension.lowercased()

        switch format {
        case .auto:
            if ext.isEmpty {
                throw CLIError("Export format could not be inferred from '\(expandedPath)'. Use --format json or --format archive, or provide an extension.")
            }
            self.path = expandedPath
        case .json:
            if ext.isEmpty || ext == "json" {
                self.path = ext == "json" ? expandedPath : url.appendingPathExtension("json").path
            } else {
                throw CLIError("JSON exports must use a .json extension.")
            }
        case .archive:
            let allowed = Set(["archive", "lookin", "lookinside"])
            if ext.isEmpty {
                self.path = url.appendingPathExtension("lookinside").path
            } else if allowed.contains(ext) {
                self.path = expandedPath
            } else {
                throw CLIError("Archive exports must use .archive, .lookin, or .lookinside.")
            }
        }
    }
}

private enum StandardPrinter {
    static func printLine(_ string: String) {
        Swift.print(string)
    }

    static func printJSON(_ value: some Encodable) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw CLIError("Failed to encode UTF-8 output.")
        }
        printLine(string)
    }
}

private struct TargetRecord: Codable {
    let targetID: String
    let transport: String
    let port: Int
    let deviceID: String?
    let appName: String
    let bundleIdentifier: String
    let deviceDescription: String
    let osDescription: String
    let serverVersion: Int
    let serverReadableVersion: String
    let appInfoIdentifier: Int

    init(_ target: LICDiscoveredTarget) {
        targetID = target.targetID
        transport = target.transport
        port = target.port
        deviceID = target.deviceID
        appName = target.appName
        bundleIdentifier = target.bundleIdentifier
        deviceDescription = target.deviceDescription
        osDescription = target.osDescription
        serverVersion = target.serverVersion
        serverReadableVersion = target.serverReadableVersion
        appInfoIdentifier = target.appInfoIdentifier
    }
}

private struct InspectRecord: Codable {
    let target: TargetRecord
    let protocolVersion: Int
    let connectionState: String

    init(target: LICDiscoveredTarget) {
        self.target = TargetRecord(target)
        protocolVersion = supportedProtocolVersion
        connectionState = "connected"
    }
}

private struct CLIError: LocalizedError, CustomStringConvertible {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }

    var description: String {
        message
    }
}

private extension [LICDiscoveredTarget] {
    func filtered(
        by transport: TransportFilter?,
        bundleIdentifier: String?,
        nameContains: String?
    ) -> [LICDiscoveredTarget] {
        filter { target in
            if let transport, target.transport.caseInsensitiveCompare(transport.rawValue) != .orderedSame {
                return false
            }
            if let bundleIdentifier, target.bundleIdentifier != bundleIdentifier {
                return false
            }
            if let nameContains, !nameContains.isEmpty {
                return target.appName.range(of: nameContains, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
            return true
        }
    }
}
