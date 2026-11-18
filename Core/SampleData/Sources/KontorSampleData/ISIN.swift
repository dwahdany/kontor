import Foundation

/// ISIN helpers for the fictional identifiers used in sample data.
enum ISIN {
    /// The ISO 6166 check digit for an 11-character body (2-letter country + 9 alphanumerics).
    static func checkDigit(for body: String) -> Int? {
        var digits = [Int]()
        digits.reserveCapacity(22)
        for c in body.utf8 {
            switch c {
            case 48...57: digits.append(Int(c) - 48)
            case 65...90:
                let v = Int(c) - 55
                digits.append(v / 10)
                digits.append(v % 10)
            default: return nil
            }
        }
        guard body.utf8.count == 11 else { return nil }
        var sum = 0
        var double = true // the rightmost body digit is doubled (the check digit itself is not)
        for d in digits.reversed() {
            let v = double ? d * 2 : d
            sum += v > 9 ? v - 9 : v
            double.toggle()
        }
        return (10 - sum % 10) % 10
    }

    /// Builds a complete ISIN from a country prefix and a 9-character national identifier.
    static func make(country: String, nsin: String) -> String {
        let body = country + nsin
        guard let check = checkDigit(for: body) else { preconditionFailure("invalid ISIN body \(body)") }
        return body + String(check)
    }

    static func isValid(_ isin: String) -> Bool {
        guard isin.utf8.count == 12, let last = isin.utf8.last, last >= 48, last <= 57 else { return false }
        return checkDigit(for: String(isin.dropLast())) == Int(last) - 48
    }

    /// A clearly fictional ISIN ("DEMO" / "TEST" in the national identifier) with a valid check digit.
    ///
    /// The number is zero-padded behind the tag. Numbers too long for that shorten the tag
    /// ("TES100000", …) and wrap at 10⁹, so every input yields a well-formed 12-character ISIN.
    static func fictional(country: String, tag: String = "DEMO", number: Int) -> String {
        let digits = String(number.magnitude % 1_000_000_000)
        let marker = tag.prefix(max(0, 9 - digits.count))
        let padding = String(repeating: "0", count: 9 - marker.count - digits.count)
        return make(country: country, nsin: marker + padding + digits)
    }
}
