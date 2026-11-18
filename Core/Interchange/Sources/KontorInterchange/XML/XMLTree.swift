import Foundation

/// A malformed-XML error with the 1-based line it occurred on.
struct XMLSyntaxError: Error, Equatable {
    var line: Int
    var message: String
}

/// A compact, read-only XML tree.
///
/// Portfolio files are dominated by hundreds of thousands of tiny `<price t=".." v=".."/>`
/// elements, so the tree is stored as flat arrays of fixed-size records that point into the original
/// byte buffer. Element names are interned to small integers; text and attribute values are only
/// decoded to `String` on demand. Building the tree is a single pass without per-node allocations.
struct XMLTree: Sendable {
    typealias NodeID = Int32
    typealias NameID = Int32

    struct Node: Sendable {
        var name: NameID
        var parent: NodeID
        var firstChild: NodeID = -1
        var lastChild: NodeID = -1
        var nextSibling: NodeID = -1
        var attributeStart: Int32
        var attributeCount: Int32 = 0
        /// Byte range of the first text segment (start == end if none).
        var textStart: Int32 = 0
        var textEnd: Int32 = 0
        /// Byte offset of the start tag (for diagnostics).
        var offset: Int32
    }

    struct Attribute: Sendable {
        var name: NameID
        var valueStart: Int32
        var valueEnd: Int32
    }

    let bytes: [UInt8]
    private(set) var nodes: [Node] = []
    private(set) var attributes: [Attribute] = []
    private(set) var names: [String] = []
    private var nameIndex: [UInt64: NameID] = [:]
    /// Text of nodes whose content is split over several segments (CDATA, mixed content).
    private var compositeText: [NodeID: String] = [:]

    var root: NodeID { nodes.isEmpty ? -1 : 0 }

    // MARK: Parsing

    init(parsing data: [UInt8]) throws {
        var source = data
        // Transcode UTF-16 (rare, but legal XML) to UTF-8; strip a UTF-8 BOM.
        if source.count >= 2, (source[0] == 0xFF && source[1] == 0xFE) || (source[0] == 0xFE && source[1] == 0xFF) {
            let littleEndian = source[0] == 0xFF
            var units = [UInt16]()
            units.reserveCapacity(source.count / 2)
            var i = 2
            while i + 1 < source.count {
                units.append(littleEndian ? UInt16(source[i]) | UInt16(source[i + 1]) << 8 : UInt16(source[i]) << 8 | UInt16(source[i + 1]))
                i += 2
            }
            source = Array(String(decoding: units, as: UTF16.self).utf8)
        }
        guard source.count < Int(Int32.max) else { throw XMLSyntaxError(line: 0, message: "file is too large") }
        bytes = source
        nodes.reserveCapacity(source.count / 24)
        attributes.reserveCapacity(source.count / 24)
        try source.withUnsafeBufferPointer { try build($0) }
    }

    private func line(at offset: Int) -> Int {
        var line = 1
        for i in 0..<min(offset, bytes.count) where bytes[i] == 10 { line += 1 }
        return line
    }

    /// Line number of a node's start tag.
    func line(of node: NodeID) -> Int { line(at: Int(nodes[Int(node)].offset)) }

    private mutating func intern(_ buffer: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) -> NameID {
        var key = StableID.fnv1a(UnsafeBufferPointer(rebasing: buffer[start..<end]))
        while let id = nameIndex[key] {
            let existing = names[Int(id)].utf8
            if existing.count == end - start, existing.elementsEqual(buffer[start..<end]) { return id }
            key &+= 1 // hash collision: probe
        }
        let id = NameID(names.count)
        names.append(String(decoding: buffer[start..<end], as: UTF8.self))
        nameIndex[key] = id
        return id
    }

    private mutating func build(_ b: UnsafeBufferPointer<UInt8>) throws {
        let n = b.count
        var i = 0
        if n >= 3, b[0] == 0xEF, b[1] == 0xBB, b[2] == 0xBF { i = 3 }
        var stack: [NodeID] = []
        func fail(_ message: String, _ at: Int) -> XMLSyntaxError { XMLSyntaxError(line: line(at: at), message: message) }
        @inline(__always) func isSpace(_ c: UInt8) -> Bool { c == 32 || c == 10 || c == 13 || c == 9 }
        func find(_ pattern: StaticString, from: Int) -> Int? {
            let p = UnsafeBufferPointer(start: pattern.utf8Start, count: pattern.utf8CodeUnitCount)
            guard n >= p.count else { return nil }
            var j = from
            let last = n - p.count
            while j <= last {
                if b[j] == p[0] {
                    var k = 1
                    while k < p.count, b[j + k] == p[k] { k += 1 }
                    if k == p.count { return j }
                }
                j += 1
            }
            return nil
        }

        while i < n {
            if b[i] != 60 { // text
                let start = i
                var onlySpace = true
                while i < n, b[i] != 60 {
                    if onlySpace, !isSpace(b[i]) { onlySpace = false }
                    i += 1
                }
                if onlySpace { continue }
                guard let top = stack.last else {
                    if !nodes.isEmpty { continue } // trailing garbage after the root is ignored
                    throw fail("text before the root element", start)
                }
                appendText(to: top, start: start, end: i, raw: false, b)
                continue
            }
            guard i + 1 < n else { throw fail("unexpected end of file", i) }
            let c = b[i + 1]
            if c == 63 { // <? ... ?>
                guard let end = find("?>", from: i + 2) else { throw fail("unterminated processing instruction", i) }
                i = end + 2
            } else if c == 33 { // <!
                if i + 3 < n, b[i + 2] == 45, b[i + 3] == 45 {
                    guard let end = find("-->", from: i + 4) else { throw fail("unterminated comment", i) }
                    i = end + 3
                } else if i + 8 < n, b[i + 2] == 91, b[i + 3] == 67, b[i + 4] == 68, b[i + 5] == 65, b[i + 6] == 84, b[i + 7] == 65, b[i + 8] == 91 {
                    guard let end = find("]]>", from: i + 9) else { throw fail("unterminated CDATA section", i) }
                    guard let top = stack.last else { throw fail("CDATA outside the root element", i) }
                    appendText(to: top, start: i + 9, end: end, raw: true, b)
                    i = end + 3
                } else { // DOCTYPE etc.: skip to the matching '>' (internal subsets use [ ])
                    var depth = 0
                    var j = i + 2
                    while j < n {
                        if b[j] == 91 { depth += 1 } else if b[j] == 93 { depth -= 1 } else if b[j] == 62, depth <= 0 { break }
                        j += 1
                    }
                    guard j < n else { throw fail("unterminated declaration", i) }
                    i = j + 1
                }
            } else if c == 47 { // </name>
                var j = i + 2
                let nameStart = j
                while j < n, b[j] != 62, !isSpace(b[j]) { j += 1 }
                let nameEnd = j
                while j < n, b[j] != 62 { j += 1 }
                guard j < n else { throw fail("unterminated end tag", i) }
                guard let top = stack.popLast() else { throw fail("unexpected end tag", i) }
                let expected = names[Int(nodes[Int(top)].name)].utf8
                guard expected.count == nameEnd - nameStart, expected.elementsEqual(b[nameStart..<nameEnd]) else {
                    throw fail("end tag </\(String(decoding: b[nameStart..<nameEnd], as: UTF8.self))> does not match <\(names[Int(nodes[Int(top)].name)])>", i)
                }
                i = j + 1
            } else { // <name attr="value" ...> or <name/>
                guard stack.count < 100_000 else { throw fail("elements are nested too deeply", i) }
                if stack.isEmpty, !nodes.isEmpty { throw fail("more than one root element", i) }
                var j = i + 1
                let nameStart = j
                while j < n, b[j] != 62, b[j] != 47, !isSpace(b[j]) { j += 1 }
                guard j < n, j > nameStart else { throw fail("malformed start tag", i) }
                let id = NodeID(nodes.count)
                var node = Node(name: intern(b, nameStart, j), parent: stack.last ?? -1, attributeStart: Int32(attributes.count), offset: Int32(i))
                var selfClosing = false
                while true {
                    while j < n, isSpace(b[j]) { j += 1 }
                    guard j < n else { throw fail("unterminated start tag", i) }
                    if b[j] == 62 { j += 1; break }
                    if b[j] == 47 {
                        guard j + 1 < n, b[j + 1] == 62 else { throw fail("malformed start tag", i) }
                        selfClosing = true
                        j += 2
                        break
                    }
                    let attrStart = j
                    while j < n, b[j] != 61, b[j] != 62, !isSpace(b[j]) { j += 1 }
                    let attrEnd = j
                    while j < n, isSpace(b[j]) { j += 1 }
                    guard j < n, b[j] == 61, attrEnd > attrStart else { throw fail("attribute without a value", attrStart) }
                    j += 1
                    while j < n, isSpace(b[j]) { j += 1 }
                    guard j < n, b[j] == 34 || b[j] == 39 else { throw fail("attribute value must be quoted", attrStart) }
                    let quote = b[j]
                    j += 1
                    let valueStart = j
                    while j < n, b[j] != quote { j += 1 }
                    guard j < n else { throw fail("unterminated attribute value", attrStart) }
                    attributes.append(Attribute(name: intern(b, attrStart, attrEnd), valueStart: Int32(valueStart), valueEnd: Int32(j)))
                    node.attributeCount += 1
                    j += 1
                }
                nodes.append(node)
                if let parent = stack.last {
                    let last = nodes[Int(parent)].lastChild
                    if last < 0 { nodes[Int(parent)].firstChild = id } else { nodes[Int(last)].nextSibling = id }
                    nodes[Int(parent)].lastChild = id
                }
                if !selfClosing { stack.append(id) }
                i = j
            }
        }
        guard !nodes.isEmpty else { throw fail("the file contains no XML element", 0) }
        if let open = stack.last {
            throw fail("element <\(names[Int(nodes[Int(open)].name)])> is not closed (file truncated?)", n)
        }
    }

    private mutating func appendText(to node: NodeID, start: Int, end: Int, raw: Bool, _ b: UnsafeBufferPointer<UInt8>) {
        let index = Int(node)
        if !raw, compositeText[node] == nil, nodes[index].textStart == nodes[index].textEnd {
            nodes[index].textStart = Int32(start)
            nodes[index].textEnd = Int32(end)
            return
        }
        var text = compositeText[node] ?? XMLTree.decode(b, Int(nodes[index].textStart), Int(nodes[index].textEnd))
        text += raw ? String(decoding: b[start..<end], as: UTF8.self) : XMLTree.decode(b, start, end)
        compositeText[node] = text
    }

    // MARK: Decoding

    /// Decodes character data, resolving the predefined and numeric entities.
    private static func decode(_ b: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) -> String {
        guard start < end else { return "" }
        var hasEntity = false
        var i = start
        while i < end {
            if b[i] == 38 { hasEntity = true; break }
            i += 1
        }
        guard hasEntity else { return String(decoding: b[start..<end], as: UTF8.self) }
        var out = [UInt8]()
        out.reserveCapacity(end - start)
        i = start
        while i < end {
            let c = b[i]
            guard c == 38 else { out.append(c); i += 1; continue }
            var j = i + 1
            while j < end, j - i <= 12, b[j] != 59 { j += 1 }
            guard j < end, b[j] == 59 else { out.append(c); i += 1; continue }
            let entity = String(decoding: b[(i + 1)..<j], as: UTF8.self)
            var scalar: Unicode.Scalar?
            switch entity {
            case "amp": scalar = "&"
            case "lt": scalar = "<"
            case "gt": scalar = ">"
            case "quot": scalar = "\""
            case "apos": scalar = "'"
            default:
                if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                    scalar = UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init)
                } else if entity.hasPrefix("#") {
                    scalar = UInt32(entity.dropFirst(), radix: 10).flatMap(Unicode.Scalar.init)
                }
            }
            if let scalar {
                out.append(contentsOf: Array(String(Character(scalar)).utf8))
                i = j + 1
            } else {
                out.append(c)
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: Navigation

    func name(of node: NodeID) -> String { names[Int(nodes[Int(node)].name)] }

    /// The interned id of `name`, or -1 if no element/attribute of that name exists in the document.
    func nameID(_ name: String) -> NameID {
        var key = StableID.fnv1a(name.utf8)
        while let id = nameIndex[key] {
            if names[Int(id)] == name { return id }
            key &+= 1
        }
        return -1
    }

    /// Interned id for a name given as a byte range of the source buffer, or -1.
    func nameID(bytes range: Range<Int>) -> NameID {
        var key = StableID.fnv1a(bytes[range])
        while let id = nameIndex[key] {
            let existing = names[Int(id)].utf8
            if existing.count == range.count, existing.elementsEqual(bytes[range]) { return id }
            key &+= 1
        }
        return -1
    }

    func parent(of node: NodeID) -> NodeID { nodes[Int(node)].parent }

    /// The first child element named `name`.
    func child(_ node: NodeID, _ name: NameID) -> NodeID? {
        guard name >= 0 else { return nil }
        var c = nodes[Int(node)].firstChild
        while c >= 0 {
            if nodes[Int(c)].name == name { return c }
            c = nodes[Int(c)].nextSibling
        }
        return nil
    }

    /// The `index`-th (1-based) child element named `name` — XPath's `name[index]`.
    func child(_ node: NodeID, _ name: NameID, index: Int) -> NodeID? {
        guard name >= 0, index >= 1 else { return nil }
        var remaining = index
        var c = nodes[Int(node)].firstChild
        while c >= 0 {
            if nodes[Int(c)].name == name {
                remaining -= 1
                if remaining == 0 { return c }
            }
            c = nodes[Int(c)].nextSibling
        }
        return nil
    }

    struct Children: Sequence, IteratorProtocol {
        let tree: XMLTree
        var next_: NodeID
        mutating func next() -> NodeID? {
            guard next_ >= 0 else { return nil }
            defer { next_ = tree.nodes[Int(next_)].nextSibling }
            return next_
        }
    }

    func children(of node: NodeID) -> Children { Children(tree: self, next_: nodes[Int(node)].firstChild) }

    func hasChildren(_ node: NodeID) -> Bool { nodes[Int(node)].firstChild >= 0 }

    /// Character data directly inside the element (entities resolved).
    func text(of node: NodeID) -> String {
        if let composite = compositeText[node] { return composite }
        let record = nodes[Int(node)]
        return bytes.withUnsafeBufferPointer { XMLTree.decode($0, Int(record.textStart), Int(record.textEnd)) }
    }

    /// Raw (undecoded) bytes of the element's text — for numeric fields.
    func textBytes(of node: NodeID) -> ArraySlice<UInt8> {
        let record = nodes[Int(node)]
        return bytes[Int(record.textStart)..<Int(record.textEnd)]
    }

    func attributeRange(_ node: NodeID, _ name: NameID) -> Range<Int>? {
        guard name >= 0 else { return nil }
        let record = nodes[Int(node)]
        var i = Int(record.attributeStart)
        let end = i + Int(record.attributeCount)
        while i < end {
            if attributes[i].name == name { return Int(attributes[i].valueStart)..<Int(attributes[i].valueEnd) }
            i += 1
        }
        return nil
    }

    func attribute(_ node: NodeID, _ name: NameID) -> String? {
        guard let range = attributeRange(node, name) else { return nil }
        return bytes.withUnsafeBufferPointer { XMLTree.decode($0, range.lowerBound, range.upperBound) }
    }

    func attributeBytes(_ node: NodeID, _ name: NameID) -> ArraySlice<UInt8>? {
        attributeRange(node, name).map { bytes[$0] }
    }
}
