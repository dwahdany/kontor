import KontorUI
import FeatureDashboard
import FeatureHoldings
import FeaturePerformance
import FeatureAllocation
import FeatureEarnings
import FeatureTrades
import FeatureSecurities
import FeatureTransactions
import FeatureAccounts
import FeaturePlans
import FeatureImport

/// The one place where the executable knows about concrete features. Each feature target exposes a
/// `FeatureModule`; everything else (screens, palette commands, inspectors, sheets) is resolved
/// through the registry, so features never reference each other.
enum FeatureCatalog {
    @MainActor
    static func makeRegistry() -> FeatureRegistry {
        FeatureRegistry([
            DashboardFeature.module,
            HoldingsFeature.module,
            PerformanceFeature.module,
            AllocationFeature.module,
            EarningsFeature.module,
            TradesFeature.module,
            SecuritiesFeature.module,
            TransactionsFeature.module,
            AccountsFeature.module,
            PlansFeature.module,
            ImportFeature.module,
        ])
    }
}
