import Foundation
import KontorModel

/// A stock split (or reverse split) of one security.
///
/// The engine assumes that quotes and share counts are mutually consistent, i.e. split-adjusted.
/// Applying a split rewrites history accordingly: every quote **before** the effective day is
/// multiplied by `oldShares / newShares`, the share count of every transaction of the security
/// before that day by `newShares / oldShares`; amounts are untouched. A `SecurityEvent` of kind
/// `.split` documents the change.
public struct StockSplit: Sendable, Hashable {
    public let securityID: UUID
    /// The first day the security trades at the new share count (ex-day).
    public let day: Day
    /// Shares after the split for every `oldShares` before it (2 for a 2:1 split).
    public let newShares: Int
    /// Shares before the split (1 for a 2:1 split, 10 for a 1:10 reverse split).
    public let oldShares: Int

    /// Nil unless both sides of the ratio are positive.
    public init?(securityID: UUID, day: Day, newShares: Int, oldShares: Int) {
        guard newShares > 0, oldShares > 0 else { return nil }
        self.securityID = securityID
        self.day = day
        self.newShares = newShares
        self.oldShares = oldShares
    }

    /// Parses a "new:old" ratio such as "2:1", "3 : 2" or "1:10". Nil if malformed.
    public init?(securityID: UUID, day: Day, ratio: String) {
        let parts = ratio.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let new = Int(parts[0]), let old = Int(parts[1]) else { return nil }
        self.init(securityID: securityID, day: day, newShares: new, oldShares: old)
    }

    /// "new:old", the format stored in `SecurityEvent.detail`.
    public var ratio: String { "\(newShares):\(oldShares)" }

    /// The outcome of applying a split.
    public struct Result: Sendable {
        /// The security with adjusted quotes and the recorded split event.
        public let security: Security
        /// All input transactions in their original order, with adjusted share counts.
        public let transactions: [Transaction]
        /// Ids of the transactions whose share count changed.
        public let adjustedTransactionIDs: [UUID]
        /// Number of quotes that were rescaled.
        public let adjustedPriceCount: Int
        /// The event appended to `security.events`.
        public let event: SecurityEvent
    }

    /// Whether `security` already carries a split event with the same day and ratio (applying the
    /// split again would adjust history twice).
    public func isRecorded(in security: Security) -> Bool {
        security.events.contains { event in
            guard event.kind == .split, event.day == day,
                  let other = StockSplit(securityID: securityID, day: day, ratio: event.detail) else { return false }
            return other.newShares * oldShares == newShares * other.oldShares
        }
    }

    /// Applies the split to `security` and to those of `transactions` that belong to it. Pure.
    /// Transactions of other securities, and those dated on or after `day`, are returned unchanged.
    public func apply(to security: Security, transactions: [Transaction], eventID: UUID = UUID()) -> Result {
        var adjusted = security
        var points: [PricePoint] = []
        points.reserveCapacity(security.prices.count)
        var priceCount = 0
        for point in security.prices {
            if point.day < day {
                points.append(PricePoint(
                    day: point.day, price: Price(raw: mulDiv(point.price.raw, Int64(oldShares), Int64(newShares)))))
                priceCount += 1
            } else {
                points.append(point)
            }
        }
        adjusted.prices = PriceSeries(points)
        let event = SecurityEvent(id: eventID, day: day, kind: .split, detail: ratio)
        adjusted.events.append(event)
        adjusted.events.sort { $0.day < $1.day }

        var changed: [UUID] = []
        var out = transactions
        for i in out.indices where out[i].securityID == securityID && out[i].date < day && out[i].shares.raw != 0 {
            out[i].shares = Shares(raw: mulDiv(out[i].shares.raw, Int64(newShares), Int64(oldShares)))
            changed.append(out[i].id)
        }
        return Result(
            security: adjusted, transactions: out, adjustedTransactionIDs: changed, adjustedPriceCount: priceCount,
            event: event)
    }
}

extension PortfolioFile {
    /// A copy of the file with `split` applied (quotes, share counts, split event). Nil if the
    /// security does not exist.
    public func applying(_ split: StockSplit, eventID: UUID = UUID()) -> PortfolioFile? {
        guard let index = securities.firstIndex(where: { $0.id == split.securityID }) else { return nil }
        let result = split.apply(to: securities[index], transactions: transactions, eventID: eventID)
        var copy = self
        copy.securities[index] = result.security
        copy.transactions = result.transactions
        return copy
    }
}
