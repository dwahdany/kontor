import Foundation

/// Resolves XStream object references on top of an `XMLTree`.
///
/// XStream writes every object once and refers to it from all other places. Two reference styles
/// occur in Portfolio Performance files:
///
/// * **XPath references** (default): `<security reference="../../../securities/security[3]"/>` — a path
///   relative to the referencing element (absolute paths starting with `/` are understood as well).
///   Steps are `..`, `.`, `name` (first child of that name) or `name[n]` (n-th child of that name, 1-based).
/// * **ID references**: the object carries `id="42"` and is referred to with `reference="42"`.
///
/// The object identity of an element is the id of the element that holds its data, i.e. the node
/// obtained by following references until an element without a `reference` attribute is reached.
struct XStreamGraph: Sendable {
    typealias NodeID = XMLTree.NodeID

    let tree: XMLTree
    private let referenceName: XMLTree.NameID
    private let idsByValue: [ArraySlice<UInt8>: NodeID]
    /// Memoized targets (node -> canonical node); -1 = not a reference, -2 = unresolvable.
    private let canonical: [NodeID]
    /// Number of references that could not be resolved, with the line of the first few.
    let unresolved: [NodeID]

    init(_ tree: XMLTree) {
        self.tree = tree
        referenceName = tree.nameID("reference")
        let idName = tree.nameID("id")
        var ids: [ArraySlice<UInt8>: NodeID] = [:]
        if idName >= 0 {
            for index in tree.nodes.indices where tree.nodes[index].attributeCount > 0 {
                // `id` child *elements* are common (taxonomies); only the attribute marks an object id.
                if let range = tree.attributeRange(NodeID(index), idName) { ids[tree.bytes[range]] = NodeID(index) }
            }
        }
        idsByValue = ids

        var canonical = [NodeID](repeating: -1, count: tree.nodes.count)
        var unresolved: [NodeID] = []
        if referenceName >= 0 {
            // First pass: direct targets.
            var direct = [NodeID](repeating: -1, count: tree.nodes.count)
            var references: [NodeID] = []
            var siblings = SiblingIndex()
            for index in tree.nodes.indices where tree.nodes[index].attributeCount > 0 {
                let node = NodeID(index)
                guard let range = tree.attributeRange(node, referenceName) else { continue }
                references.append(node)
                direct[index] = XStreamGraph.target(of: node, path: range, tree: tree, ids: ids, siblings: &siblings) ?? -2
            }
            // Second pass: follow chains (a reference normally points at a real element, but be lenient).
            for node in references {
                var current = direct[Int(node)]
                var hops = 0
                while current >= 0, direct[Int(current)] != -1, hops < 64 {
                    current = direct[Int(current)]
                    hops += 1
                }
                if hops >= 64 { current = -2 } // reference cycle
                canonical[Int(node)] = current
                if current < 0 { unresolved.append(node) }
            }
        }
        self.canonical = canonical
        self.unresolved = unresolved
    }

    /// Positional lookups (`transaction[1234]`) into long lists would make resolution quadratic —
    /// a ledger with n purchases contains n such steps into a list of n siblings. The same-named
    /// children of a parent are therefore tabulated the first time a large index is requested.
    private struct SiblingIndex {
        private var tables: [UInt64: [NodeID]] = [:]

        mutating func child(_ parent: NodeID, _ name: XMLTree.NameID, index: Int, in tree: XMLTree) -> NodeID? {
            guard index > 8 else { return tree.child(parent, name, index: index) }
            guard name >= 0 else { return nil }
            let key = UInt64(UInt32(bitPattern: parent)) << 32 | UInt64(UInt32(bitPattern: name))
            if let table = tables[key] { return index <= table.count ? table[index - 1] : nil }
            var table: [NodeID] = []
            for child in tree.children(of: parent) where tree.nodes[Int(child)].name == name { table.append(child) }
            tables[key] = table
            return index <= table.count ? table[index - 1] : nil
        }
    }

    private static func target(of node: NodeID, path: Range<Int>, tree: XMLTree, ids: [ArraySlice<UInt8>: NodeID], siblings: inout SiblingIndex) -> NodeID? {
        let bytes = tree.bytes
        guard !path.isEmpty else { return nil }
        let first = bytes[path.lowerBound]
        let looksLikePath = first == 46 || first == 47 // '.' or '/'
        if !looksLikePath, let byID = ids[bytes[path]] { return byID }

        var current: NodeID
        var i = path.lowerBound
        if first == 47 {
            // Absolute path: the first step names the root element.
            current = -1
            i += 1
        } else {
            current = node
        }
        while i < path.upperBound {
            var j = i
            while j < path.upperBound, bytes[j] != 47 { j += 1 }
            // step = bytes[i..<j]
            if j - i == 2, bytes[i] == 46, bytes[i + 1] == 46 {
                guard current >= 0 else { return nil }
                current = tree.parent(of: current)
                guard current >= 0 else { return nil }
            } else if j - i == 1, bytes[i] == 46 {
                // stay
            } else if j > i {
                var nameEnd = j
                var position = 1
                if bytes[j - 1] == 93 { // name[n]
                    var k = j - 2
                    var value = 0, scale = 1
                    while k > i, bytes[k] >= 48, bytes[k] <= 57 {
                        // No element has a billion siblings; longer indexes are garbage (and would overflow).
                        guard scale <= 100_000_000 else { return nil }
                        value += Int(bytes[k] - 48) * scale
                        scale *= 10
                        k -= 1
                    }
                    guard k > i, bytes[k] == 91, scale > 1 else { return nil }
                    nameEnd = k
                    position = value
                }
                let name = tree.nameID(bytes: i..<nameEnd)
                if current < 0 {
                    guard tree.root >= 0, tree.nodes[0].name == name, position == 1 else { return nil }
                    current = tree.root
                } else {
                    guard let next = siblings.child(current, name, index: position, in: tree) else { return nil }
                    current = next
                }
            }
            i = j + 1
        }
        return current >= 0 && current != node ? current : nil
    }

    /// Whether the element is a reference to another element.
    func isReference(_ node: NodeID) -> Bool { canonical[Int(node)] != -1 }

    /// The element that holds the data of the object `node` denotes; nil for a dangling reference.
    func resolve(_ node: NodeID) -> NodeID? {
        let target = canonical[Int(node)]
        if target == -1 { return node }
        return target >= 0 ? target : nil
    }

    /// The resolved first child named `name`.
    func object(_ node: NodeID, _ name: XMLTree.NameID) -> NodeID? {
        tree.child(node, name).flatMap(resolve)
    }
}
