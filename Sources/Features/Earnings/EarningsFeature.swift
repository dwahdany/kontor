import SwiftUI
import KontorModel
import KontorUI

/// Registration of the Earnings feature with the app shell. The executable lists `EarningsFeature.module` in
/// its feature catalog; everything this feature contributes (screen, palette commands, inspector,
/// sheets) is declared here, so no file outside `Sources/Features/Earnings` needs to change.
public enum EarningsFeature {
    @MainActor public static var module: FeatureModule {
        FeatureModule(.earnings) { EarningsScreen() }
    }
}

// In this module the bare name `Transaction` means the ledger entry (`KontorModel.Transaction`),
// not SwiftUI's animation transaction. Without this alias the name is ambiguous in files that
// import both SwiftUI and KontorModel.
typealias Transaction = KontorModel.Transaction
