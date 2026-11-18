import KontorModel

/// Unambiguous shorthand for the ledger entry type (`KontorModel.Transaction`).
///
/// SwiftUI also declares a `Transaction` (animation transactions), so the bare name is ambiguous
/// in files that import both SwiftUI and KontorModel. Feature targets solve this once with a
/// module-level `typealias Transaction = KontorModel.Transaction` (see `<Name>Feature.swift`);
/// `Txn` is available everywhere KontorUI is imported.
public typealias Txn = KontorModel.Transaction
