import Foundation
import KontorModel
import Testing
@testable import KontorInterchange

enum Fixture {
    static func url(_ path: String) -> URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures").appendingPathComponent(path)
    }

    static func data(_ path: String) throws -> Data {
        try Data(contentsOf: url(path))
    }

    static func pp(_ name: String) throws -> PortfolioPerformanceImport {
        try PortfolioPerformanceImporter.read(try data("pp/\(name)"), name: name)
    }
}

func day(_ iso: String) -> Day { Day(iso: iso)! }
