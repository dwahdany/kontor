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
            guard let number = unambiguous(trimmed, formatter: formatter) else { return nil }
            return formatter.parseFixed(number, scaleDigits: scaleDigits).map { abs($0) }
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

    /// Prepares one number for the shared parser, which is deliberately tolerant:
    ///
    /// * returns nil when letters stand **between** the digits (`1e5`, `12a3`) — the shared parser
    ///   would silently drop them and read 15 and 123; a currency before or after the number is fine;
    /// * a single separator after a zero (or empty) integer part is always the decimal separator:
    ///   `0.125` on a comma-decimal Mac is an eighth, never 125 — a leading zero cannot be a grouped
    ///   thousand. The separator is rewritten to the locale's own so the shared parser agrees.
    static func unambiguous(_ text: String, formatter: KontorFormatter) -> String? {
        let characters = Array(text)
        guard let first = characters.firstIndex(where: \.isWholeNumber), let last = characters.lastIndex(where: \.isWholeNumber) else { return text }
        var separators = [Int]()
        for index in first...last {
            let character = characters[index]
            if character.isLetter { return nil }
            if character == "." || character == "," { separators.append(index) }
        }
        // A separator directly in front of the first digit (".5") belongs to the number.
        var start = first
        if first > 0, characters[first - 1] == "." || characters[first - 1] == "," {
            start = first - 1
            separators.insert(start, at: 0)
        }
        guard separators.count == 1, let separator = separators.first else { return text }
        let integerPart = characters[start..<separator]
        guard integerPart.allSatisfy({ $0 == "0" }) else { return text }
        var result = characters
        result[separator] = formatter.number(0.5, decimals: 1, grouping: false).contains(",") ? "," : "."
        return String(result)
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
            let token = String(characters[start..<index])
            return formatter.parseDouble(Arithmetic.unambiguous(token, formatter: formatter) ?? token)
        }
    }
}
