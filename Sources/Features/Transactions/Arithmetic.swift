import Foundation
import KontorUI

/// Number input for the editor's fields: a plain number in any locale format (through the shared
/// `KontorFormatter` parser) or a simple calculation such as `3*120.5`, `1.200,50 + 9,90` or
/// `(250 - 12.5) / 4`. Pure and locale-injectable, so it is unit-tested.
enum Arithmetic {
    /// Parses `text` into a fixed-point integer with `scaleDigits` decimals. Returns nil if the text is
    /// neither a number nor a valid calculation (or the result is negative, not finite or too large).
    static func evaluate(_ text: String, scaleDigits: Int, formatter: KontorFormatter = Fmt.current) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard isCalculation(trimmed) else {
            return formatter.parseFixed(trimmed, scaleDigits: scaleDigits).map { abs($0) }
        }
        var parser = Parser(text: trimmed, formatter: formatter)
        guard let value = parser.parse(), value.isFinite, value >= 0 else { return nil }
        let scaled = (value * pow(10, Double(scaleDigits))).rounded()
        guard scaled < 9.2e18 else { return nil }
        return Int64(scaled)
    }

    /// True if the text contains an operator that makes it a calculation rather than a (possibly
    /// signed) number.
    static func isCalculation(_ text: String) -> Bool {
        var seenDigit = false
        for character in text {
            switch character {
            case "0"..."9": seenDigit = true
            case "*", "×", "·", "/", "÷", "+", ":": if seenDigit || character != "+" { return true }
            case "-", "−", "–": if seenDigit { return true }
            case "(": if seenDigit { return true }
            case ")": if text.contains(where: { "*×·/÷+".contains($0) }) { return true }
            default: break
            }
        }
        return false
    }

    /// Recursive descent over `+ − × ÷` and parentheses; numbers go through the locale-aware parser.
    private struct Parser {
        let characters: [Character]
        let formatter: KontorFormatter
        var index = 0

        init(text: String, formatter: KontorFormatter) {
            characters = Array(text)
            self.formatter = formatter
        }

        mutating func parse() -> Double? {
            guard let value = sum() else { return nil }
            skipSpaces()
            return index == characters.count ? value : nil
        }

        private mutating func skipSpaces() {
            while index < characters.count, characters[index].isWhitespace { index += 1 }
        }

        private mutating func peek() -> Character? {
            skipSpaces()
            return index < characters.count ? characters[index] : nil
        }

        private mutating func sum() -> Double? {
            guard var value = product() else { return nil }
            while let op = peek() {
                if op == "+" {
                    index += 1
                    guard let rhs = product() else { return nil }
                    value += rhs
                } else if op == "-" || op == "−" || op == "–" {
                    index += 1
                    guard let rhs = product() else { return nil }
                    value -= rhs
                } else {
                    break
                }
            }
            return value
        }

        private mutating func product() -> Double? {
            guard var value = factor() else { return nil }
            while let op = peek() {
                if op == "*" || op == "×" || op == "·" {
                    index += 1
                    guard let rhs = factor() else { return nil }
                    value *= rhs
                } else if op == "/" || op == "÷" || op == ":" {
                    index += 1
                    guard let rhs = factor(), rhs != 0 else { return nil }
                    value /= rhs
                } else {
                    break
                }
            }
            return value
        }

        private mutating func factor() -> Double? {
            guard let next = peek() else { return nil }
            if next == "(" {
                index += 1
                guard let value = sum(), peek() == ")" else { return nil }
                index += 1
                return value
            }
            if next == "-" || next == "−" || next == "–" {
                index += 1
                return factor().map { -$0 }
            }
            if next == "+" {
                index += 1
                return factor()
            }
            let start = index
            while index < characters.count, characters[index].isNumber || characters[index] == "." || characters[index] == ","
                || characters[index] == "'" || characters[index] == "’" {
                index += 1
            }
            guard index > start else { return nil }
            return formatter.parseDouble(String(characters[start..<index]))
        }
    }
}
