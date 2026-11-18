import SwiftUI
import KontorModel
import KontorUI

/// Registration of the Import feature with the app shell. The executable lists `ImportFeature.module` in
/// its feature catalog; everything this feature contributes (screen, palette commands, inspector,
/// sheets) is declared here, so no file outside `Sources/Features/Import` needs to change.
public enum ImportFeature {
    @MainActor public static var module: FeatureModule {
        FeatureModule(.`import`) { ImportScreen() }
    }
}

// In this module the bare name `Transaction` means the ledger entry (`KontorModel.Transaction`),
// not SwiftUI's animation transaction. Without this alias the name is ambiguous in files that
// import both SwiftUI and KontorModel.
typealias Transaction = KontorModel.Transaction
