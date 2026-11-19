import KontorUI
#if canImport(FeatureDashboard)
import FeatureDashboard
#endif
#if canImport(FeatureHoldings)
import FeatureHoldings
#endif
#if canImport(FeaturePerformance)
import FeaturePerformance
#endif
#if canImport(FeatureAllocation)
import FeatureAllocation
#endif
#if canImport(FeatureEarnings)
import FeatureEarnings
#endif
#if canImport(FeatureTrades)
import FeatureTrades
#endif
#if canImport(FeatureSecurities)
import FeatureSecurities
#endif
#if canImport(FeatureTransactions)
import FeatureTransactions
#endif
#if canImport(FeatureAccounts)
import FeatureAccounts
#endif
#if canImport(FeaturePlans)
import FeaturePlans
#endif
#if canImport(FeatureImport)
import FeatureImport
#endif

/// The one place where the executable knows about concrete features. Each feature target exposes a
/// `FeatureModule`; everything else (screens, palette commands, inspectors, sheets) is resolved
/// through the registry, so features never reference each other.
///
/// Which features are linked is decided by `KONTOR_FEATURES` in Package.swift (unset = all). A
/// feature that is not linked simply is not registered: its screen shows `FeaturePlaceholder` and
/// its sheets the shell's placeholder sheet.
enum FeatureCatalog {
    @MainActor
    static func makeRegistry() -> FeatureRegistry {
        var modules: [FeatureModule] = []
        #if canImport(FeatureDashboard)
        modules.append(DashboardFeature.module)
        #endif
        #if canImport(FeatureHoldings)
        modules.append(HoldingsFeature.module)
        #endif
        #if canImport(FeaturePerformance)
        modules.append(PerformanceFeature.module)
        #endif
        #if canImport(FeatureAllocation)
        modules.append(AllocationFeature.module)
        #endif
        #if canImport(FeatureEarnings)
        modules.append(EarningsFeature.module)
        #endif
        #if canImport(FeatureTrades)
        modules.append(TradesFeature.module)
        #endif
        #if canImport(FeatureSecurities)
        modules.append(SecuritiesFeature.module)
        #endif
        #if canImport(FeatureTransactions)
        modules.append(TransactionsFeature.module)
        #endif
        #if canImport(FeatureAccounts)
        modules.append(AccountsFeature.module)
        #endif
        #if canImport(FeaturePlans)
        modules.append(PlansFeature.module)
        #endif
        #if canImport(FeatureImport)
        modules.append(ImportFeature.module)
        #endif
        return FeatureRegistry(modules)
    }

    /// Names of the features compiled into this binary (for `--help` and diagnostics).
    static var linkedFeatures: [String] {
        var names: [String] = []
        #if canImport(FeatureDashboard)
        names.append("Dashboard")
        #endif
        #if canImport(FeatureHoldings)
        names.append("Holdings")
        #endif
        #if canImport(FeaturePerformance)
        names.append("Performance")
        #endif
        #if canImport(FeatureAllocation)
        names.append("Allocation")
        #endif
        #if canImport(FeatureEarnings)
        names.append("Earnings")
        #endif
        #if canImport(FeatureTrades)
        names.append("Trades")
        #endif
        #if canImport(FeatureSecurities)
        names.append("Securities")
        #endif
        #if canImport(FeatureTransactions)
        names.append("Transactions")
        #endif
        #if canImport(FeatureAccounts)
        names.append("Accounts")
        #endif
        #if canImport(FeaturePlans)
        names.append("Plans")
        #endif
        #if canImport(FeatureImport)
        names.append("Import")
        #endif
        return names
    }
}
