import SwiftUI
import KontorModel
import KontorUI

/// Registration of the Accounts feature with the app shell. The executable lists `AccountsFeature.module` in
/// its feature catalog; everything this feature contributes (screen, palette commands, inspector,
/// sheets) is declared here, so no file outside `Sources/Features/Accounts` needs to change.
public enum AccountsFeature {
    @MainActor public static var module: FeatureModule {
        FeatureModule(.accounts) { AccountsScreen() }
    }
}

// In this module the bare name `Transaction` means the ledger entry (`KontorModel.Transaction`),
// not SwiftUI's animation transaction. Without this alias the name is ambiguous in files that
// import both SwiftUI and KontorModel.
typealias Transaction = KontorModel.Transaction
