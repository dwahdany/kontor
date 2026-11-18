import Foundation
import KontorModel
import Testing
@testable import KontorInterchange

/// Deterministic generator so that failures are reproducible.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Malformed input must produce an error or a (possibly odd) document — never a crash.
/// A trap anywhere in the package aborts the test process, which is what these tests detect.
@Suite struct FuzzTests {
    static let interesting: [[UInt8]] = [
        Array("<".utf8), Array(">".utf8), Array("/>".utf8), Array("\"".utf8), Array("&".utf8), Array("&#x110000;".utf8), Array("&#xD800;".utf8),
        Array("<![CDATA[".utf8), Array("<!--".utf8), Array("reference=\"../../..\"".utf8), Array("reference=\"../x[0]\"".utf8),
        Array("reference=\"/client/securities/security[99999999999999999999]\"".utf8), Array("reference=\".\"".utf8),
        Array("-9223372036854775808".utf8), Array("9223372036854775807".utf8), Array("99999999999999999999999".utf8),
        Array("0000-00-00".utf8), Array("9999-12-31T99:99".utf8), Array("<version>25</version>".utf8), Array("<version>1</version>".utf8), [0], [0xFF, 0xFE],
    ]

    static func mutate(_ original: [UInt8], _ rng: inout SplitMix64) -> [UInt8] {
        var bytes = original
        for _ in 0..<Int.random(in: 1...4, using: &rng) {
            guard !bytes.isEmpty else { break }
            let at = Int.random(in: 0..<bytes.count, using: &rng)
            switch Int.random(in: 0..<7, using: &rng) {
            case 0: bytes[at] = UInt8.random(in: 0...255, using: &rng)
            case 1: bytes.removeSubrange(at..<min(bytes.count, at + Int.random(in: 1...64, using: &rng)))
            case 2: bytes.removeSubrange(at...) // truncate
            case 3: bytes.insert(contentsOf: interesting.randomElement(using: &rng)!, at: at)
            case 4: // duplicate a chunk somewhere else
                let end = min(bytes.count, at + Int.random(in: 1...400, using: &rng))
                bytes.insert(contentsOf: Array(bytes[at..<end]), at: Int.random(in: 0..<bytes.count, using: &rng))
            case 5: // overwrite digits (indexes in reference paths, amounts, dates)
                var i = at
                while i < min(bytes.count, at + 200) {
                    if bytes[i] >= 48, bytes[i] <= 57 { bytes[i] = UInt8.random(in: 48...57, using: &rng) }
                    i += 1
                }
            default: // swap two chunks
                let other = Int.random(in: 0..<bytes.count, using: &rng)
                let length = min(32, bytes.count - max(at, other))
                for k in 0..<length { bytes.swapAt(at + k, other + k) }
            }
        }
        return bytes
    }

    @Test(arguments: ["client69.xml", "synthetic_all_types.xml", "synthetic_all_types_ids.xml", "client_with_security_events.xml",
                      "Issue1897AddFeesToDividendTransactions.xml", "Issue1498FifoCrossPortfolio.xml", "client69.xml.zip",
                      "client69.binary.portfolio"])
    func mutatedPortfolioPerformanceFilesNeverCrash(name: String) throws {
        let original = [UInt8](try Fixture.data("pp/\(name)"))
        var rng = SplitMix64(seed: UInt64(name.utf8.reduce(7) { $0 &* 31 &+ Int($1) }.magnitude))
        var imported = 0
        for _ in 0..<400 {
            let data = Data(Self.mutate(original, &rng))
            _ = FileFormat.detect(data: data, filename: name)
            guard let result = try? PortfolioPerformanceImporter.read(data, name: "fuzz") else { continue }
            imported += 1
            // Whatever was read must survive export and re-import, and stay a valid Kontor document.
            let exported = PortfolioPerformanceExporter.export(result.file)
            _ = try PortfolioPerformanceImporter.read(exported.data)
            _ = try PortfolioFile(data: result.file.encoded())
            #expect(Set(result.file.transactions.map(\.id)).count == result.file.transactions.count)
            for transaction in result.file.transactions {
                #expect(transaction.amount.minor >= 0 && transaction.shares.raw >= 0 && transaction.fees >= 0 && transaction.taxes >= 0)
            }
        }
        if name.hasSuffix(".xml") { #expect(imported > 20) } // the mutations must not all be rejected outright
    }

    @Test func randomBytesNeverCrashAnyReader() {
        var rng = SplitMix64(seed: 42)
        let prefixes: [[UInt8]] = [[], [0x50, 0x4B, 0x03, 0x04], Array("<client>".utf8), Array("PORTFOLIO".utf8), Array("PPPBV1".utf8), [0xFF, 0xFE], [0xEF, 0xBB, 0xBF],
                                   Array("Date;Value\n".utf8)]
        for round in 0..<1500 {
            var bytes = prefixes[round % prefixes.count]
            for _ in 0..<Int.random(in: 0...300, using: &rng) { bytes.append(UInt8.random(in: 0...255, using: &rng)) }
            let data = Data(bytes)
            _ = FileFormat.detect(data: data, filename: nil)
            _ = try? PortfolioPerformanceImporter.read(data)
            _ = try? Inflate.inflate(bytes, limit: 1 << 20)
            _ = try? ZipArchive(bytes)
            let document = CSVDocument(data: data)
            _ = CSVImporter.propose(document, file: PortfolioFile())
        }
    }

    @Test func zipWithLyingDirectoryIsRejectedWithoutHugeAllocations() throws {
        var bytes = [UInt8](try Fixture.data("pp/client69.xml.zip"))
        // Central directory: claim an uncompressed size of 4 GiB − 1.
        let signature: [UInt8] = [0x50, 0x4B, 0x01, 0x02]
        let directory = try #require((0..<(bytes.count - 4)).first { Array(bytes[$0..<($0 + 4)]) == signature })
        for k in 24..<28 { bytes[directory + k] = 0xFF }
        // The stream itself is intact, so the content still decodes; the declared size is only a hint.
        let result = try PortfolioPerformanceImporter.read(Data(bytes))
        #expect(result.file.securities.count == 1)
    }

    @Test func mutatedCSVNeverCrashes() throws {
        var rng = SplitMix64(seed: 7)
        let file = PortfolioFile(securities: [Security(name: "A", currency: "EUR", isin: "IE00B4WXJJ64")], accounts: [Account(name: "Giro", currency: "EUR")])
        for name in ["pp_portfolio_de.csv", "pp_account_en.csv", "broker_us_tab.csv", "broker_de_windows1252.csv", "quotes_yahoo.csv", "quotes_utf16.csv"] {
            let original = [UInt8](try Fixture.data("csv/\(name)"))
            for _ in 0..<300 {
                let data = Data(Self.mutate(original, &rng))
                let document = CSVDocument(data: data)
                #expect(document.rows.allSatisfy { $0.count == document.header.count })
                for target in CSVImportTarget.allCases {
                    let proposal = CSVImporter.propose(document, options: CSVImportOptions(target: target, securityID: file.securities[0].id), file: file)
                    #expect(proposal.rows.count == document.rows.count)
                    let updated = proposal.apply(to: file)
                    for transaction in updated.transactions {
                        #expect(transaction.amount.minor >= 0 && transaction.shares.raw >= 0 && transaction.fees >= 0 && transaction.taxes >= 0)
                    }
                }
            }
        }
    }
}
