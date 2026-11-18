import SwiftUI
import KontorModel
import KontorUI

/// Registration of the Performance feature with the app shell. The executable lists `PerformanceFeature.module` in
/// its feature catalog; everything this feature contributes (screen, palette commands, inspector,
/// sheets) is declared here, so no file outside `Sources/Features/Performance` needs to change.
public enum PerformanceFeature {
    @MainActor public static var module: FeatureModule {
        FeatureModule(.performance) { PerformanceScreen() }
    }
}

// In this module the bare name `Transaction` means the ledger entry (`KontorModel.Transaction`),
// not SwiftUI's animation transaction. Without this alias the name is ambiguous in files that
// import both SwiftUI and KontorModel.
typealias Transaction = KontorModel.Transaction
