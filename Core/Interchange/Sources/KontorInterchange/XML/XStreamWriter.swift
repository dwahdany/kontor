import Foundation

/// Identity and serialization state of an object in an XStream document.
/// Subclass (or wrap) it for every value that can be referenced from more than one place.
class XStreamObject {
    /// Path of the element the object was first written to (XPath reference style).
    fileprivate var path: [String]?
    /// Sequential id (ID reference style).
    fileprivate var id: Int?
    var isWritten: Bool { path != nil }
}

/// Writes XML the way XStream does: every object is serialized in full where it is first
/// encountered; later occurrences become `<element reference="…"/>`, either as a relative XPath
/// (`../../securities/security[2]`) or as an id.
struct XStreamWriter {
    enum ReferenceStyle: Sendable { case xpath, id }

    private(set) var output: [UInt8] = []
    private let style: ReferenceStyle
    private var segments: [String] = []
    /// Per open element: how many children of each name were written so far.
    private var siblingCounts: [[String: Int]] = [[:]]
    private var hasChildren: [Bool] = [false]
    private var nextID = 1

    init(style: ReferenceStyle, capacity: Int = 1 << 16) {
        self.style = style
        output.reserveCapacity(capacity)
    }

    // MARK: Low level

    private mutating func write(_ text: String) { output.append(contentsOf: text.utf8) }

    private mutating func writeEscaped(_ text: String, attribute: Bool) {
        for byte in text.utf8 {
            switch byte {
            case 38: write("&amp;")
            case 60: write("&lt;")
            case 62: write("&gt;")
            case 34 where attribute: write("&quot;")
            case 39 where !attribute: write("&apos;")
            case 34: write("&quot;")
            case 13: write("&#xd;")
            case 10 where attribute: write("&#xa;")
            case 9 where attribute: write("&#x9;")
            case 0..<9, 11, 12, 14..<32: break // not representable in XML 1.0
            default: output.append(byte)
            }
        }
    }

    private mutating func indent() {
        if !output.isEmpty { output.append(10) }
        for _ in 0..<segments.count { output.append(32); output.append(32) }
    }

    /// Reserves the path segment for a new child element named `name` of the current element.
    private mutating func segment(for name: String) -> String {
        let count = (siblingCounts[siblingCounts.count - 1][name] ?? 0) + 1
        siblingCounts[siblingCounts.count - 1][name] = count
        hasChildren[hasChildren.count - 1] = true
        return count == 1 ? name : "\(name)[\(count)]"
    }

    private mutating func startTag(_ name: String, _ attributes: [(String, String)]) {
        indent()
        output.append(60)
        write(name)
        for (key, value) in attributes {
            output.append(32)
            write(key)
            write("=\"")
            writeEscaped(value, attribute: true)
            output.append(34)
        }
    }

    // MARK: Elements

    mutating func open(_ name: String, attributes: [(String, String)] = []) {
        let segment = segment(for: name)
        startTag(name, attributes)
        output.append(62)
        segments.append(segment)
        siblingCounts.append([:])
        hasChildren.append(false)
    }

    mutating func close(_ name: String) {
        let hadChildren = hasChildren.removeLast()
        siblingCounts.removeLast()
        segments.removeLast()
        if hadChildren { indent() }
        write("</")
        write(name)
        output.append(62)
    }

    /// `<name>text</name>`
    mutating func leaf(_ name: String, _ text: String, attributes: [(String, String)] = []) {
        _ = segment(for: name)
        startTag(name, attributes)
        output.append(62)
        writeEscaped(text, attribute: false)
        write("</")
        write(name)
        output.append(62)
    }

    /// `<name attr="…"/>`
    mutating func empty(_ name: String, attributes: [(String, String)] = []) {
        _ = segment(for: name)
        startTag(name, attributes)
        write("/>")
    }

    /// Appends pre-rendered, already indented child lines (used for bulk data like prices).
    /// `name` must be the element name of every line, `count` their number.
    mutating func rawChildren(named name: String, count: Int, _ render: (inout [UInt8], _ indentation: Int) -> Void) {
        guard count > 0 else { return }
        siblingCounts[siblingCounts.count - 1][name, default: 0] += count
        hasChildren[hasChildren.count - 1] = true
        render(&output, segments.count * 2)
    }

    // MARK: Objects

    /// Writes `object` as element `name`: in full via `body` the first time, as a reference afterwards.
    mutating func object(_ object: XStreamObject, as name: String, attributes: [(String, String)] = [], body: (inout XStreamWriter) -> Void) {
        if let path = object.path {
            _ = segment(for: name) // the reference occupies a sibling position like any other element
            let reference: String
            switch style {
            case .id:
                reference = String(object.id ?? 0)
            case .xpath:
                var common = 0
                while common < path.count, common < segments.count, path[common] == segments[common] { common += 1 }
                // From the referencing element itself: one step up per remaining segment (including its own).
                var steps = [String](repeating: "..", count: segments.count + 1 - common)
                steps.append(contentsOf: path[common...])
                reference = steps.joined(separator: "/")
            }
            startTag(name, attributes + [("reference", reference)])
            write("/>")
            return
        }
        var all = attributes
        if style == .id {
            object.id = nextID
            nextID += 1
            all.insert(("id", String(object.id!)), at: 0)
        }
        let own = segment(for: name)
        object.path = segments + [own]
        startTag(name, all)
        output.append(62)
        segments.append(own)
        siblingCounts.append([:])
        hasChildren.append(false)
        body(&self)
        close(name)
    }
}
