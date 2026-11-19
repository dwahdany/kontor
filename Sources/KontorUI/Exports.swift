// KontorUI re-exports the data model and the calculation engine: a feature file that says
// `import KontorUI` can use `PortfolioFile`, `Money`, `Day`, … (KontorModel) and `Ledger`,
// `Analysis`, `Scope`, `ReportingPeriod`, `DayInterval`, `Snapshot`, … (KontorEngine) without
// further imports. Explicit `import KontorModel` / `import KontorEngine` lines remain valid — every
// feature target lists both packages as dependencies.
//
// Not re-exported: KontorMarketData (FeatureSecurities imports it), KontorInterchange
// (FeatureImport) and KontorSampleData (shell, previews and tests).
@_exported import KontorModel
@_exported import KontorEngine

/// Unambiguous shorthand for the ledger entry type (`KontorModel.Transaction`).
///
/// SwiftUI also declares a `Transaction` (animation transactions), so the bare name is ambiguous
/// in files that import both SwiftUI and KontorModel. Feature targets solve this once with a
/// module-level `typealias Transaction = KontorModel.Transaction` (see `<Name>Feature.swift`);
/// `Txn` is available everywhere KontorUI is imported.
public typealias Txn = KontorModel.Transaction
