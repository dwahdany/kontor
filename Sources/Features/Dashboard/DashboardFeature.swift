import SwiftUI
import KontorModel
import KontorUI

/// Registration of the Dashboard feature with the app shell. The executable lists `DashboardFeature.module` in
/// its feature catalog; everything this feature contributes (screen, palette commands, inspector,
/// sheets) is declared here, so no file outside `Sources/Features/Dashboard` needs to change.
public enum DashboardFeature {
    @MainActor public static var module: FeatureModule {
        FeatureModule(.dashboard) { DashboardScreen() }
    }
}

// In this module the bare name `Transaction` means the ledger entry (`KontorModel.Transaction`),
// not SwiftUI's animation transaction. Without this alias the name is ambiguous in files that
// import both SwiftUI and KontorModel.
typealias Transaction = KontorModel.Transaction
