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
            TextSnapshot.self,
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

    mutating func run() throws {
        let json = try CLIClient().allAttrGroupsJSON(target: options.target, oid: oid)
        StandardPrinter.printLine(json)
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

private struct TextSnapshot: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "text-snapshot",
        abstract: "Capture the SwiftUI text drawn by a CALayer (font / size / color / text content).",
        discussion: """
        SwiftUI renders Text into private _CGDrawingLayer instances whose
        `content` is an opaque drawing closure, so the regular `attrs` and
        `ivars` subcommands can't see the resolved font, point size, fill
        colour or glyphs.

        text-snapshot installs CoreText / CoreGraphics interposers via
        fishhook the first time it runs, then drives the target layer's
        drawInContext: against an off-screen bitmap context. The hooks
        record every CTFontDrawGlyphs / CGContextSetFillColor* call made
        during that one draw pass and return them as JSON, including a
        best-effort glyph→character reversal that recovers the visible
        text.

        The target OID must resolve to a CALayer (typically a
        SwiftUI._CGDrawingLayer or its subclass).
        """
    )

    @OptionGroup var options: SharedTargetOptions

    @Option(help: "Layer OID from `lookinside hierarchy`. Must be a CALayer.")
    var oid: UInt

    mutating func run() throws {
        let json = try CLIClient().textSnapshotJSON(target: options.target, oid: oid)
        StandardPrinter.printLine(json)
    }
}

private struct SwiftUIDebug: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swiftui-debug",
        abstract: "Dump SwiftUI viewDebugData (font / colour / text) for an NSHostingView.",
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
        """
    )

    @OptionGroup var options: SharedTargetOptions

    @Option(help: "OID of an NSHostingView from `lookinside hierarchy`.")
    var oid: UInt

    @Flag(name: [.long, .customShort("s")],
          help: "Print only a flat summary table (text / font / size / color / frame) instead of the full JSON.")
    var summary: Bool = false

    mutating func run() throws {
        let json = try CLIClient().swiftUIDebugJSON(target: options.target, oid: oid)
        if summary {
            StandardPrinter.printLine(SwiftUIDebugSummary.render(fromJSON: json))
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

    struct TextRun {
        var text: String
        var width: Double?
        var height: Double?
        var color: String?       // from display-list "(color #RRGGBBAA)"
        var font: String?        // from attributed-string ".SFNS-Semibold"
        var fontSize: Double?
        var alignment: String?
        var lineSpacing: Double?
    }

    static func render(fromJSON jsonString: String) -> String {
        guard let data = jsonString.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "(error: could not parse swiftui-debug JSON)"
        }

        // Collect every leaf string from the entire payload first.
        var leafStrings: [String] = []
        collectLeafStrings(parsed["viewDebugData"], into: &leafStrings)

        // 1. Parse each attributed-string description into (text, font, size, ...).
        var attrIndex: [String: TextRun] = [:]   // keyed by text content
        for s in leafStrings {
            if !s.contains("NSFont") { continue }   // fast reject
            if let run = parseAttributedDescription(s) {
                attrIndex[run.text] = run
            }
        }

        // 2. Walk every display-list-item and pull (text "..." #:size (W,H))
        //    plus the nearest enclosing frame + most-recent color.
        var runs: [TextRun] = []
        for s in leafStrings where s.contains("display-list-item") {
            runs.append(contentsOf: parseDisplayList(s))
        }

        // 3. Merge: the attribute description usually wins for font/size, the
        //    display list wins for colour + frame.
        var merged: [TextRun] = []
        for r in runs {
            var out = r
            if let known = attrIndex[r.text] {
                out.font = known.font ?? out.font
                out.fontSize = known.fontSize ?? out.fontSize
                out.alignment = known.alignment ?? out.alignment
                out.lineSpacing = known.lineSpacing ?? out.lineSpacing
            }
            merged.append(out)
        }

        // De-dup by (text, frame size) so we don't repeat across multiple
        // display-list copies of the same screen.
        var seen = Set<String>()
        merged = merged.filter { r in
            let key = "\(r.text)|\(r.width ?? -1)|\(r.height ?? -1)"
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }

        if merged.isEmpty {
            return "(no text runs detected — try the full JSON output without --summary)"
        }

        // Tabular render. We use Swift String padding instead of String(format:)
        // because %s expects C strings and crashes on Swift String values.
        func pad(_ s: String, _ n: Int) -> String {
            let len = s.count
            if len >= n { return clip(s, n) }
            return s + String(repeating: " ", count: n - len)
        }

        let header = pad("TEXT", 44) + "  " + pad("FONT", 30) + "  "
                   + pad("SIZE", 6) + "  " + pad("COLOR", 11) + "  "
                   + pad("ALIGN", 9) + "  " + pad("LINE_SP", 8) + "  W×H"
        var lines = [header, String(repeating: "-", count: header.count)]
        for r in merged {
            let text = pad(r.text, 44)
            let font = pad(r.font ?? "?", 30)
            let size = pad(r.fontSize.map { String(format: "%.0fpt", $0) } ?? "?", 6)
            let color = pad(r.color ?? "?", 11)
            let align = pad(r.alignment ?? "?", 9)
            let lspc  = pad(r.lineSpacing.map { String(format: "%.0f", $0) } ?? "?", 8)
            let wh = (r.width != nil && r.height != nil)
                ? String(format: "%.0f×%.0f", r.width!, r.height!) : "?"
            lines.append("\(text)  \(font)  \(size)  \(color)  \(align)  \(lspc)  \(wh)")
        }
        return lines.joined(separator: "\n")
    }

    private static func clip(_ s: String, _ n: Int) -> String {
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

    /// Parses strings like:
    ///   `登录即可自动同步媒体库影片数据{
    ///       NSColor = "sRGB ... 0.0352941 0.0352941 0.0392157 1";
    ///       NSFont  = "\".SFNS-Regular 14.00 pt. ...\"";
    ///       NSParagraphStyle = "Alignment Center, LineSpacing 8, ...";
    ///   }`
    private static func parseAttributedDescription(_ s: String) -> TextRun? {
        guard let braceIdx = s.firstIndex(of: "{") else { return nil }
        let text = String(s[..<braceIdx])
        // Reject obviously non-attributed strings.
        if text.contains("\n") || text.count > 200 { return nil }
        if !s.contains("NSFont") { return nil }

        var run = TextRun(text: text)

        // Font + point size: ".SFNS-Semibold 14.00 pt"
        if let fontMatch = s.range(of: "([.A-Za-z0-9-]+)\\s+(\\d+(?:\\.\\d+)?)\\s*pt", options: .regularExpression) {
            let frag = String(s[fontMatch])
            let parts = frag.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            if parts.count >= 2 {
                run.font = String(parts[0])
                run.fontSize = Double(parts[1])
            }
        }

        // Alignment
        if let r = s.range(of: "Alignment\\s+(\\w+)", options: .regularExpression) {
            let m = String(s[r])
            if let p = m.split(separator: " ").last { run.alignment = String(p).trimmingCharacters(in: .punctuationCharacters) }
        }

        // LineSpacing
        if let r = s.range(of: "LineSpacing\\s+(\\d+(?:\\.\\d+)?)", options: .regularExpression) {
            let m = String(s[r])
            if let p = m.split(separator: " ").last { run.lineSpacing = Double(p) }
        }

        // NSColor sRGB: pull last 4 floats before alpha terminator.
        if let r = s.range(of: "NSColor\\s*=\\s*\"[^\"]+\"", options: .regularExpression) {
            let segment = String(s[r])
            let nums = segment.split(whereSeparator: { !"0123456789.".contains($0) })
                .compactMap { Double($0) }
            if nums.count >= 4 {
                let r = nums[nums.count-4], g = nums[nums.count-3], b = nums[nums.count-2], a = nums[nums.count-1]
                run.color = String(format: "#%02X%02X%02X%02X",
                                   Int((r * 255).rounded()),
                                   Int((g * 255).rounded()),
                                   Int((b * 255).rounded()),
                                   Int((a * 255).rounded()))
            }
        }

        return run
    }

    /// Parses the giant display-list s-expression. We do a single forward pass:
    /// track the most-recent (frame ...) and (color ...) we've seen, then emit
    /// a TextRun every time we hit a (text "..." #:size (W, H)) form.
    private static func parseDisplayList(_ s: String) -> [TextRun] {
        var runs: [TextRun] = []
        var lastColor: String?

        // Use NSRegularExpression once over the whole string to avoid the
        // O(n²) substring stepping that earlier attempts hit + the
        // string-index gymnastics that crashed.
        let ns = s as NSString
        let full = NSRange(location: 0, length: ns.length)

        let colorRE = try? NSRegularExpression(pattern: "\\(color\\s+#([0-9A-Fa-f]{8})\\)")
        let textRE = try? NSRegularExpression(pattern: "\\(text\\s+\"([^\"]*)\"\\s+#:size\\s+\\(([\\d.]+)[\\s,]+([\\d.]+)\\)")

        // Collect (offset, kind, captures...) tuples so we can interleave.
        struct Hit { let location: Int; let isColor: Bool; let groups: [String] }
        var hits: [Hit] = []
        if let re = colorRE {
            re.enumerateMatches(in: s, range: full) { m, _, _ in
                guard let m = m, m.numberOfRanges >= 2 else { return }
                let g = ns.substring(with: m.range(at: 1))
                hits.append(Hit(location: m.range.location, isColor: true, groups: [g]))
            }
        }
        if let re = textRE {
            re.enumerateMatches(in: s, range: full) { m, _, _ in
                guard let m = m, m.numberOfRanges >= 4 else { return }
                let txt = ns.substring(with: m.range(at: 1))
                let w = ns.substring(with: m.range(at: 2))
                let h = ns.substring(with: m.range(at: 3))
                hits.append(Hit(location: m.range.location, isColor: false, groups: [txt, w, h]))
            }
        }
        hits.sort { $0.location < $1.location }

        for h in hits {
            if h.isColor {
                lastColor = "#" + h.groups[0].uppercased()
            } else {
                var run = TextRun(text: h.groups[0], width: Double(h.groups[1]),
                                  height: Double(h.groups[2]), color: lastColor)
                _ = run
                runs.append(run)
            }
        }
        return runs
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

    func textSnapshotJSON(target: String, oid: UInt) throws -> String {
        do {
            return try client.textSnapshotJSON(forTargetID: target, oid: oid)
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
