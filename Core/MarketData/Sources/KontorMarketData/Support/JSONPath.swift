import Foundation

/// A small JSONPath dialect for pulling columns of values out of a JSON document.
///
/// Supported syntax:
///
/// | expression            | meaning                                                   |
/// |-----------------------|-----------------------------------------------------------|
/// | `$`                   | the root (optional)                                       |
/// | `.name`, `['name']`   | member of an object                                       |
/// | `[3]`, `[-1]`         | array element (negative: from the end)                    |
/// | `[*]`, `.*`           | all elements of an array / all member values of an object |
/// | `..name`              | all members called `name` at any depth (document order)   |
/// | trailing `~`          | the member *names* (or array indexes) of the matches      |
///
/// Examples: `$.prices[*].close`, `$.chart.result[0].timestamp[*]`, `$['Time Series (Daily)'].*~`
/// (the dates used as keys) together with `$['Time Series (Daily)'].*['4. close']`.
public struct JSONPath: Hashable, Sendable, CustomStringConvertible {
    enum Segment: Hashable, Sendable {
        case member(String)
        case index(Int)
        case wildcard
        case descendant(String)
    }

    let segments: [Segment]
    let selectsKeys: Bool
    public let description: String

    /// Compiles an expression. Throws ``MarketDataError/invalidConfiguration(_:)`` on syntax errors.
    public init(_ expression: String) throws {
        description = expression
        var segments = [Segment]()
        var selectsKeys = false
        let chars = Array(expression.trimmingCharacters(in: .whitespaces))
        var i = 0
        func fail(_ message: String) -> MarketDataError {
            .invalidConfiguration("Invalid path “\(expression)”: \(message)")
        }
        func readName() -> String {
            let start = i
            while i < chars.count, chars[i] != ".", chars[i] != "[", chars[i] != "~" { i += 1 }
            return String(chars[start..<i])
        }
        if i < chars.count, chars[i] == "$" { i += 1 }
        while i < chars.count {
            switch chars[i] {
            case "~":
                guard i == chars.count - 1 else { throw fail("“~” is only allowed at the end") }
                selectsKeys = true
                i += 1
            case ".":
                i += 1
                var descendant = false
                if i < chars.count, chars[i] == "." { descendant = true; i += 1 }
                if i < chars.count, chars[i] == "[" , !descendant { continue }
                let name = readName()
                guard !name.isEmpty else { throw fail("missing name after “.”") }
                if descendant {
                    segments.append(.descendant(name))
                } else {
                    segments.append(name == "*" ? .wildcard : .member(name))
                }
            case "[":
                i += 1
                guard i < chars.count else { throw fail("unterminated “[”") }
                if chars[i] == "'" || chars[i] == "\"" {
                    let quote = chars[i]
                    i += 1
                    var name = ""
                    while i < chars.count, chars[i] != quote {
                        if chars[i] == "\\", i + 1 < chars.count { i += 1 }
                        name.append(chars[i])
                        i += 1
                    }
                    guard i + 1 < chars.count, chars[i + 1] == "]" else { throw fail("unterminated quoted name") }
                    i += 2
                    segments.append(.member(name))
                } else {
                    let start = i
                    while i < chars.count, chars[i] != "]" { i += 1 }
                    guard i < chars.count else { throw fail("unterminated “[”") }
                    let inner = String(chars[start..<i]).trimmingCharacters(in: .whitespaces)
                    i += 1
                    if inner == "*" {
                        segments.append(.wildcard)
                    } else if let n = Int(inner) {
                        segments.append(.index(n))
                    } else {
                        throw fail("“[\(inner)]” is neither an index, “*” nor a quoted name")
                    }
                }
            default:
                // A bare leading name ("prices[*].close") is accepted for convenience.
                guard segments.isEmpty else { throw fail("unexpected “\(chars[i])”") }
                let name = readName()
                segments.append(name == "*" ? .wildcard : .member(name))
            }
        }
        self.segments = segments
        self.selectsKeys = selectsKeys
    }

    /// All values matched in `root`, in document order.
    public func evaluate(_ root: JSONValue) -> [JSONValue] {
        var current: [(key: JSONValue, value: JSONValue)] = [(.null, root)]
        for segment in segments {
            var next: [(key: JSONValue, value: JSONValue)] = []
            for (_, node) in current {
                switch segment {
                case .member(let name):
                    if let v = node[name] { next.append((.string(name), v)) }
                case .index(let index):
                    if let v = node[index] { next.append((.number(Double(index)), v)) }
                case .wildcard:
                    Self.children(of: node, into: &next)
                case .descendant(let name):
                    Self.collect(name, in: node, into: &next)
                }
            }
            current = next
            if current.isEmpty { break }
        }
        return selectsKeys ? current.map(\.key) : current.map(\.value)
    }

    private static func children(of node: JSONValue, into out: inout [(key: JSONValue, value: JSONValue)]) {
        switch node {
        case .array(let a):
            out.reserveCapacity(out.count + a.count)
            for (i, v) in a.enumerated() { out.append((.number(Double(i)), v)) }
        case .object(let o):
            out.reserveCapacity(out.count + o.count)
            for i in 0..<o.count { out.append((.string(o.keys[i]), o.values[i])) }
        default:
            break
        }
    }

    private static func collect(_ name: String, in node: JSONValue, into out: inout [(key: JSONValue, value: JSONValue)]) {
        switch node {
        case .array(let a):
            for v in a { collect(name, in: v, into: &out) }
        case .object(let o):
            for i in 0..<o.count {
                if o.keys[i] == name { out.append((.string(name), o.values[i])) }
                collect(name, in: o.values[i], into: &out)
            }
        default:
            break
        }
    }
}
