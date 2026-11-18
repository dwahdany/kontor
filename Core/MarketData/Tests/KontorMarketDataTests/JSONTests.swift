import Foundation
import Testing
@testable import KontorMarketData

@Suite struct JSONTests {
    @Test func parsesAllValueKinds() throws {
        let json = try JSONValue(parsing: #" {"a": 1, "b": -2.5e2, "c": "x\n\"y\" é 😀", "d": [true, false, null], "e": {}, "f": 1234567890123456789012} "#)
        #expect(json["a"] == .number(1))
        #expect(json["b"] == .number(-250))
        #expect(json["c"] == .string("x\n\"y\" é 😀"))
        #expect(json["d"] == .array([.bool(true), .bool(false), .null]))
        #expect(json["e"] == .object(JSONObject()))
        #expect(json["f"]?.doubleValue == 1.234567890123456789012e21)
        #expect(json["d"]?[-1] == .null)
        #expect(json["missing"] == nil)
    }

    @Test func keepsMemberOrder() throws {
        let json = try JSONValue(parsing: #"{"zeta": 1, "alpha": 2, "mid": 3}"#)
        #expect(json.objectValue?.keys == ["zeta", "alpha", "mid"])
    }

    @Test(arguments: ["", "{", "[1,]", "{\"a\" 1}", "nul", "\"abc", "[1] x", "{\"a\":1,}", "-"])
    func rejectsMalformedDocuments(_ text: String) {
        #expect(throws: MarketDataError.self) { _ = try JSONValue(parsing: text) }
    }

    let document = try! JSONValue(parsing: #"""
    {
      "a": {"b": [{"c": 1, "d": "2024-01-02"}, {"c": 2, "d": "2024-01-03"}, {"x": 0}]},
      "matrix": [[1704153600000, 10.5], [1704240000000, 11.25]],
      "Time Series (Daily)": {
        "2024-01-03": {"4. close": "101.50"},
        "2024-01-02": {"4. close": "100.25"}
      },
      "deep": {"k": {"price": 1}, "l": [{"price": 2}, {"m": {"price": 3}}]}
    }
    """#)

    @Test func evaluatesChildWildcardAndIndex() throws {
        #expect(try JSONPath("$.a.b[*].c").evaluate(document) == [.number(1), .number(2)])
        #expect(try JSONPath("$.a.b[*].d").evaluate(document) == [.string("2024-01-02"), .string("2024-01-03")])
        #expect(try JSONPath("$.a.b[0].c").evaluate(document) == [.number(1)])
        #expect(try JSONPath("$.a.b[-1].x").evaluate(document) == [.number(0)])
        #expect(try JSONPath("a.b[1].c").evaluate(document) == [.number(2)])
        #expect(try JSONPath("$.matrix[*][0]").evaluate(document) == [.number(1704153600000), .number(1704240000000)])
        #expect(try JSONPath("$.matrix[*][1]").evaluate(document) == [.number(10.5), .number(11.25)])
        #expect(try JSONPath("$.a.b.*.c").evaluate(document) == [.number(1), .number(2)])
        #expect(try JSONPath("$.nope[*].c").evaluate(document).isEmpty)
        #expect(try JSONPath("$").evaluate(document) == [document])
    }

    @Test func evaluatesQuotedNamesKeysAndDescendants() throws {
        #expect(try JSONPath("$['Time Series (Daily)'].*~").evaluate(document) == [.string("2024-01-03"), .string("2024-01-02")])
        #expect(try JSONPath("$['Time Series (Daily)'].*['4. close']").evaluate(document) == [.string("101.50"), .string("100.25")])
        #expect(try JSONPath(#"$["Time Series (Daily)"][*]["4. close"]"#).evaluate(document).count == 2)
        #expect(try JSONPath("$.deep..price").evaluate(document) == [.number(1), .number(2), .number(3)])
        #expect(try JSONPath("$.matrix[*]~").evaluate(document) == [.number(0), .number(1)])
    }

    @Test(arguments: ["$.a[", "$.a[x]", "$.a['b", "$.a~.b", "$.", "$.a..", "$[*]x"])
    func rejectsMalformedPaths(_ expression: String) {
        #expect(throws: MarketDataError.self) { _ = try JSONPath(expression) }
    }
}
