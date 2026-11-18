import Foundation

/// Fuzzy subsequence matching for the command palette and quick filters.
///
/// A candidate matches if all characters of the query occur in order (case- and
/// diacritic-insensitive). The score rewards matches at word starts, consecutive runs and early
/// positions, and penalises gaps — so "vwc" ranks "Vanguard FTSE All-World (VWCE)" by its ticker,
/// and "hold" puts "Holdings" before "Household".
public enum FuzzyMatcher {
    public struct Match: Sendable, Equatable {
        /// Higher is better. Only comparable between matches of the same query.
        public var score: Int
        /// Offsets (in `Character`s of the candidate) that matched — for highlighting.
        public var positions: [Int]
        /// True if every matched character continues the previous match or starts a word
        /// ("hold" in "Holdings", "nt" in "New Transaction") — as opposed to letters scattered
        /// through the text. `rank` hides scattered matches whenever tight ones exist.
        public var isTight: Bool

        public init(score: Int, positions: [Int], isTight: Bool = true) {
            self.score = score
            self.positions = positions
            self.isTight = isTight
        }
    }

    /// A pre-folded query. Create it once per keystroke and reuse it for all candidates.
    public struct Query: Sendable {
        let scalars: [Unicode.Scalar]
        public var isEmpty: Bool { scalars.isEmpty }

        public init(_ text: String) {
            scalars = FuzzyMatcher.fold(text).filter { $0 != " " }
        }
    }

    /// Matches `query` against `candidate`; nil if it is not a subsequence.
    /// An empty query matches everything with score 0.
    public static func match(_ query: Query, in candidate: String) -> Match? {
        let q = query.scalars
        guard !q.isEmpty else { return Match(score: 0, positions: []) }
        let c = fold(candidate)
        guard c.count >= q.count else { return nil }

        // Dynamic programme over (query index i, candidate index j): the best score with q[i] matched
        // at c[j] comes either from the adjacent predecessor (consecutive run) or from the best
        // earlier one minus a linear gap penalty, tracked as a running maximum — O(m·n) overall.
        let n = c.count, m = q.count
        let negative = Int.min / 2
        // best[j] = best score with q[i] matched exactly at c[j]; run[j] = length of the consecutive run ending there.
        var previous = [Int](repeating: negative, count: n)
        var previousRun = [Int](repeating: 0, count: n)
        var from = [[Int32]](repeating: [Int32](repeating: -1, count: n), count: m)

        for i in 0..<m {
            var current = [Int](repeating: negative, count: n)
            var currentRun = [Int](repeating: 0, count: n)
            // Running maximum of previous[k] + k over k <= j - 2 (linear gap penalty folded in).
            var bestGapScore = negative
            var bestGapIndex = -1
            for j in i..<(n - (m - 1 - i)) {
                if i > 0, j >= 2 {
                    let k = j - 2
                    if previous[k] > negative {
                        let candidateScore = previous[k] + k
                        if candidateScore > bestGapScore {
                            bestGapScore = candidateScore
                            bestGapIndex = k
                        }
                    }
                }
                guard c[j] == q[i] else { continue }
                let bonus = positionBonus(c, j)
                if i == 0 {
                    current[j] = bonus - min(j, 12)
                    currentRun[j] = 1
                    continue
                }
                var best = negative
                var bestFrom = -1
                var run = 1
                if j >= 1, previous[j - 1] > negative {
                    // Consecutive: bonus grows with the run length.
                    let r = previousRun[j - 1] + 1
                    let s = previous[j - 1] + bonus + 8 + min(r, 4) * 2
                    best = s
                    bestFrom = j - 1
                    run = r
                }
                if bestGapIndex >= 0 {
                    let s = bestGapScore - j + bonus - 2
                    if s > best {
                        best = s
                        bestFrom = bestGapIndex
                        run = 1
                    }
                }
                if best > negative {
                    current[j] = best
                    currentRun[j] = run
                    from[i][j] = Int32(bestFrom)
                }
            }
            previous = current
            previousRun = currentRun
        }

        var bestEnd = -1
        var bestScore = negative
        for j in 0..<n where previous[j] > bestScore {
            bestScore = previous[j]
            bestEnd = j
        }
        guard bestEnd >= 0 else { return nil }

        var positions = [Int](repeating: 0, count: m)
        var j = bestEnd
        for i in stride(from: m - 1, through: 0, by: -1) {
            positions[i] = j
            j = Int(from[i][j])
        }
        // Prefer shorter candidates and exact / prefix hits.
        var score = bestScore - (n - m) / 4
        if m == n { score += 40 } else if positions[0] == 0, positions[m - 1] == m - 1 { score += 20 }
        var tight = true
        for i in 0..<m where tight {
            let j = positions[i]
            let continues = i > 0 && positions[i - 1] == j - 1
            let startsWord = j == 0 || isSeparator(c[j - 1])
            tight = continues || startsWord
        }
        return Match(score: score, positions: positions, isTight: tight)
    }

    public static func match(_ query: String, in candidate: String) -> Match? {
        match(Query(query), in: candidate)
    }

    /// Ranks items by their best match over several searchable strings (first string = primary,
    /// later ones weigh slightly less). Stable for equal scores; with an empty query the input
    /// order is preserved. Scattered matches are dropped when tight ones exist.
    public static func rank<T>(_ items: [T], query: String, limit: Int = .max, keys: (T) -> [String]) -> [(item: T, match: Match)] {
        let q = Query(query)
        if q.isEmpty { return items.prefix(limit).map { ($0, Match(score: 0, positions: [])) } }
        var scored = [(index: Int, item: T, match: Match)]()
        for (index, item) in items.enumerated() {
            var best: Match?
            for (k, key) in keys(item).enumerated() {
                guard var m = match(q, in: key) else { continue }
                if k > 0 {
                    // Secondary keys rank lower and don't highlight the title.
                    m.score -= 6
                    m.positions = []
                }
                if best == nil || m.score > best!.score { best = m }
            }
            if let best { scored.append((index, item, best)) }
        }
        // Scattered subsequence hits are only useful as a last resort.
        if q.scalars.count >= 2, scored.contains(where: { $0.match.isTight }) {
            scored.removeAll { !$0.match.isTight }
        }
        scored.sort { $0.match.score != $1.match.score ? $0.match.score > $1.match.score : $0.index < $1.index }
        return scored.prefix(limit).map { ($0.item, $0.match) }
    }

    // MARK: Internals

    /// Lowercased, diacritic-stripped scalars, one per `Character` of the input (so positions map
    /// back to characters).
    static func fold(_ text: String) -> [Unicode.Scalar] {
        var result = [Unicode.Scalar]()
        result.reserveCapacity(text.utf8.count)
        for ch in text {
            if ch.isASCII, let ascii = ch.asciiValue {
                let lower = (ascii >= 65 && ascii <= 90) ? ascii + 32 : ascii
                result.append(Unicode.Scalar(lower))
            } else {
                let folded = String(ch).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
                result.append(folded.unicodeScalars.first ?? " ")
            }
        }
        return result
    }

    private static func isSeparator(_ s: Unicode.Scalar) -> Bool {
        switch s {
        case " ", "-", "_", "/", ".", ",", "(", ")", ":", "&", "+": true
        default: false
        }
    }

    private static func positionBonus(_ c: [Unicode.Scalar], _ j: Int) -> Int {
        if j == 0 { return 16 }
        return isSeparator(c[j - 1]) ? 12 : 0
    }
}
