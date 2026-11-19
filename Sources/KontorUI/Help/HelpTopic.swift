import SwiftUI

/// Short, plain-language explanations of the finance terms the app uses. Show one with
/// `HelpButton(.ttwror)` (an ⓘ that opens a popover) next to the label it explains.
///
/// Texts are written for someone who invests but never studied finance: what the number tells
/// you, and how it differs from its neighbour.
public enum HelpTopic: String, CaseIterable, Identifiable, Sendable {
    case ttwror, irr, ttwrorVersusIRR, annualizedReturn, absolutePerformance
    case costBasis, costMethod, purchasePrice
    case realizedGains, unrealizedGains, currencyGains
    case maxDrawdown, volatility, semiVolatility, sharpeRatio, riskFreeRate
    case dividendYield, yieldOnCost, grossVersusNet
    case benchmark, reportingPeriod, scope, investedCapital, externalFlows
    case allocation, targetWeight, rebalancing
    case trade, holdingPeriod, profitFactor
    case savingsPlan, exDate, delivery, securityTransfer
    case quoteFeed, exchangeRates, baseCurrency
    case consistencyCheck
    case netWorth, dayChange, weight, stalePrice, watchlist, depot, cashAccount, referenceAccount, retired, stockSplit, movingAverage, rollingReturn, trailingTwelveMonths, winRate, taxYear, drift, projection, planExecution

    public var id: String { rawValue }

    /// The term as a headline.
    public var title: String {
        switch self {
        case .ttwror: "Time-Weighted Return (TTWROR)"
        case .irr: "Internal Rate of Return (IRR)"
        case .ttwrorVersusIRR: "TTWROR or IRR?"
        case .annualizedReturn: "Annualized Return"
        case .absolutePerformance: "Absolute Performance"
        case .costBasis: "Cost Basis"
        case .costMethod: "FIFO and Average Cost"
        case .purchasePrice: "Purchase Price"
        case .realizedGains: "Realized Gains"
        case .unrealizedGains: "Unrealized Gains"
        case .currencyGains: "Currency Gains"
        case .maxDrawdown: "Maximum Drawdown"
        case .volatility: "Volatility"
        case .semiVolatility: "Downside Volatility"
        case .sharpeRatio: "Sharpe Ratio"
        case .riskFreeRate: "Risk-Free Rate"
        case .dividendYield: "Dividend Yield"
        case .yieldOnCost: "Yield on Cost"
        case .grossVersusNet: "Gross and Net"
        case .benchmark: "Benchmark"
        case .reportingPeriod: "Reporting Period"
        case .scope: "Scope"
        case .investedCapital: "Invested Capital"
        case .externalFlows: "Deposits and Withdrawals"
        case .allocation: "Allocation"
        case .targetWeight: "Target Weight"
        case .rebalancing: "Rebalancing"
        case .trade: "Trade"
        case .holdingPeriod: "Holding Period"
        case .profitFactor: "Profit Factor"
        case .savingsPlan: "Savings Plan"
        case .exDate: "Ex-Dividend Date"
        case .delivery: "Delivery"
        case .securityTransfer: "Security Transfer"
        case .quoteFeed: "Quote Feed"
        case .exchangeRates: "Exchange Rates"
        case .baseCurrency: "Base Currency"
        case .consistencyCheck: "Consistency Check"
        case .netWorth: "Net Worth"
        case .dayChange: "Day Change"
        case .weight: "Weight"
        case .stalePrice: "Outdated Price"
        case .watchlist: "Watchlist"
        case .depot: "Depot"
        case .cashAccount: "Cash Account"
        case .referenceAccount: "Reference Account"
        case .retired: "Retired"
        case .stockSplit: "Stock Split"
        case .movingAverage: "Moving Average"
        case .rollingReturn: "Rolling Return"
        case .trailingTwelveMonths: "Last 12 Months"
        case .winRate: "Win Rate"
        case .taxYear: "Tax Years"
        case .drift: "Deviation from Target"
        case .projection: "Projection"
        case .planExecution: "Plan Execution"
        }
    }

    /// Two to four sentences.
    public var text: String {
        switch self {
        case .ttwror:
            "How well your investments performed, independent of when you added or withdrew money. Each day's return counts equally, so a large deposit just before a rally does not flatter the result. Use it to compare yourself with a fund or an index."
        case .irr:
            "Your personal, money-weighted return per year: the interest rate a savings account would have needed to turn your deposits into today's value. Unlike TTWROR it rewards good timing — money you added before a rise counts for more."
        case .ttwrorVersusIRR:
            "TTWROR measures the investments: it ignores when you put money in, so it is comparable with an index. IRR measures your result: it weights every euro by how long it was invested. If the two differ a lot, the timing of your deposits and withdrawals made the difference."
        case .annualizedReturn:
            "The total return converted to a yearly rate, as if the portfolio had grown at the same pace every year. It makes periods of different length comparable. For periods shorter than a year it can exaggerate, so read it with care."
        case .absolutePerformance:
            "What you gained or lost in money: today's value minus the value at the start of the period, minus what you added, plus what you withdrew. Dividends, interest, fees and taxes are included."
        case .costBasis:
            "What you paid for the shares you still hold, including purchase fees. The difference between the current value and the cost basis is your unrealized gain. When you sell part of a position, the cost method decides which purchases the sold shares came from."
        case .costMethod:
            "FIFO (first in, first out) assumes you sell your oldest shares first — this is what most tax authorities use. Average cost treats all shares of a position as bought at their average price. The choice changes realized gains and the remaining cost basis, never the total."
        case .purchasePrice:
            "The average price you paid per share for the shares you still hold, fees included. Compare it with the current quote to see how far the position is in profit or loss."
        case .realizedGains:
            "Profit or loss you have locked in by selling: sale proceeds minus what the sold shares cost. Once realized it no longer changes with the market."
        case .unrealizedGains:
            "Profit or loss on paper for positions you still hold: current value minus cost basis. It moves with every quote and only becomes real when you sell."
        case .currencyGains:
            "The part of a gain or loss that comes from exchange rates rather than from the security's own price. A US stock can stand still in dollars and still gain or lose value in your base currency."
        case .maxDrawdown:
            "The largest fall from a peak to the following low within the period, in percent. It shows how much you would have lost at the worst moment — a practical measure of how much decline you had to sit through."
        case .volatility:
            "How strongly the value fluctuates, expressed as a yearly percentage (the standard deviation of daily returns). A higher number means a bumpier ride; it says nothing about the direction."
        case .semiVolatility:
            "Volatility counting only the days that were worse than average. It measures the fluctuation that actually hurts and ignores swings to the upside."
        case .sharpeRatio:
            "Return per unit of risk: the yearly return above the risk-free rate, divided by volatility. Above 1 is generally considered good. It lets you compare investments that take different amounts of risk."
        case .riskFreeRate:
            "The yearly return you could earn without risk, for example on overnight money or short government bonds. The Sharpe ratio only counts return above this rate. Set it in Portfolio Settings."
        case .dividendYield:
            "Dividends of the last twelve months divided by the current value of the position. It tells you what the holding pays at today's price."
        case .yieldOnCost:
            "Dividends divided by what you originally paid, instead of by the current value. It grows when a company raises its dividend after you bought, and shows what your own investment earns."
        case .grossVersusNet:
            "Gross is the amount before fees and taxes, net is what actually reached or left your account. Kontor stores the net amount of each transaction together with its fees and taxes, so both views are always available."
        case .benchmark:
            "An index or fund you compare your portfolio with. Add a security as a benchmark in Portfolio Settings; it does not have to be something you own. Comparisons use the time-weighted return."
        case .reportingPeriod:
            "The time span all figures on screen refer to. The value at the close of the day before the period starts is the baseline; transactions on later days count as part of the period."
        case .scope:
            "The part of your portfolio the figures cover: everything, one depot, one account, or a classification such as “Equity”. Money moving between the scope and the rest of your portfolio counts as a deposit or withdrawal for that scope."
        case .investedCapital:
            "The value at the start of the period plus everything you added since, minus what you withdrew. The gap between this line and the portfolio value is what the market contributed."
        case .externalFlows:
            "Money or securities entering or leaving the portfolio from outside: deposits, withdrawals and deliveries. They change the value but are not performance, so return figures are adjusted for them."
        case .allocation:
            "How your money is spread across categories such as asset classes or regions. A security can be split across several categories, for example a world fund across regions."
        case .targetWeight:
            "The share of the portfolio you want a category to have. Targets of sub-categories are relative to their parent. Comparing targets with actual weights shows where you are over- or underweight."
        case .rebalancing:
            "Bringing the portfolio back to its target weights by buying what is underweight and, optionally, selling what is overweight. With “no sales”, only new money is used, which avoids fees and taxes on sales."
        case .trade:
            "A purchase paired with the sale that closed it. Kontor matches sales to purchases using the portfolio's cost method and shows the result of each round trip, including fees."
        case .holdingPeriod:
            "How long shares were held between purchase and sale (for open positions: until today). For trades made of several purchases it is counted from the earliest one."
        case .profitFactor:
            "Total profit of all winning trades divided by the total loss of all losing trades. Above 1 means the winners outweighed the losers; 2 means you earned two for every one lost."
        case .savingsPlan:
            "A recurring purchase, deposit or withdrawal. Kontor lists the dates that are due and creates the transactions for you with one click; you can skip individual dates."
        case .exDate:
            "The first day a share trades without the right to the upcoming dividend. Whoever holds the share at the close of the day before receives the payment, which usually arrives a few days later."
        case .delivery:
            "Shares that enter or leave a depot without a cash transaction in Kontor — for example a gift, an inheritance, or holdings you owned before you started tracking. An inbound delivery records what the shares cost, so gains are still calculated correctly."
        case .securityTransfer:
            "Moving shares from one of your depots to another. Nothing is bought or sold: purchase dates and cost basis travel with the shares."
        case .quoteFeed:
            "Where Kontor downloads prices for a security from, for example Yahoo Finance or a web address you provide. “Manual” means prices are only entered or imported by you; such securities are never requested online."
        case .exchangeRates:
            "Daily reference rates used to convert foreign-currency positions and transactions into your base currency. Kontor downloads the European Central Bank's rates together with the quotes."
        case .baseCurrency:
            "The currency all totals and reports are shown in. Accounts and securities keep their own currency; values are converted at each day's exchange rate."
        case .consistencyCheck:
            "Looks for transactions that cannot be right: selling more shares than you held, missing accounts, amounts in the wrong currency, probable duplicates, and securities without recent quotes. Nothing is changed automatically."
        case .netWorth:
            "Everything in this portfolio added up in your base currency: the market value of all securities at their latest prices plus the balances of all cash accounts."
        case .dayChange:
            "How much the value moved between the two most recent prices of a security — usually yesterday's close and today's. On weekends and holidays it shows the last trading day."
        case .weight:
            "A position's share of the total value shown. A large weight means your result depends heavily on that single holding."
        case .stalePrice:
            "The latest price of this security is more than a few days old, so its value may be off. Update quotes, check the security's data source, or enter a price by hand."
        case .watchlist:
            "A list of securities you want to keep an eye on, whether you own them or not. Watchlists do not affect any calculation."
        case .depot:
            "A depot is a securities account: the place at your bank or broker where shares, funds and bonds are held. Buying and selling settles against a cash account — the depot's reference account."
        case .cashAccount:
            "An account that holds money in one currency: a checking, savings or broker settlement account. Deposits, withdrawals, dividends, interest, fees and the cash side of every trade are booked here."
        case .referenceAccount:
            "The cash account a depot settles against: purchases are paid from it, and sales and dividends are credited to it unless you choose another account for a transaction."
        case .retired:
            "Retired securities and accounts stay in the file with their history but are hidden from pickers and lists, and their quotes are no longer updated. You can bring them back at any time."
        case .stockSplit:
            "A company divides its shares, for example 4 for 1: you hold four times as many shares at a quarter of the price, and the value stays the same. Recording a split adjusts earlier share counts and prices so charts and gains remain comparable."
        case .movingAverage:
            "The average price of the last 50 or 200 trading days, drawn as a smooth line. It shows the trend without the daily noise; it is not a forecast."
        case .rollingReturn:
            "The return of every 12-month (or 3-year) stretch, one for each end date. It shows how much the result depends on when you look — a single period can be lucky."
        case .trailingTwelveMonths:
            "The sum of the most recent twelve months. Unlike a calendar year it is always a full year, so it can be compared at any time of the year."
        case .winRate:
            "The share of closed trades that ended with a gain. A high win rate alone says little: a few large losses can outweigh many small wins — see the profit factor."
        case .taxYear:
            "What was realized in each calendar year: gains and losses of the trades closed in that year, plus dividends, interest, fees and taxes paid. The figures are a summary for your records, not a tax statement."
        case .drift:
            "How far a classification's actual share is from its target, in percentage points. Positive means overweight, negative underweight; rebalancing brings it back towards zero."
        case .projection:
            "An illustration of how regular contributions could grow at a steady assumed return. Real markets do not move steadily: treat the range as a rough corridor, not as a forecast."
        case .planExecution:
            "One scheduled date of a plan. When it is due, Kontor proposes the transaction for you to review; you can create it, skip the date, or decide later. Nothing is booked automatically."
        }
    }

    /// Topics worth reading next (shown as links in the popover).
    public var related: [HelpTopic] {
        switch self {
        case .ttwror, .irr: [.ttwrorVersusIRR, .annualizedReturn]
        case .ttwrorVersusIRR: [.ttwror, .irr]
        case .costBasis: [.costMethod, .unrealizedGains]
        case .costMethod: [.costBasis, .realizedGains]
        case .realizedGains: [.unrealizedGains, .costMethod]
        case .unrealizedGains: [.realizedGains, .costBasis]
        case .volatility: [.sharpeRatio, .maxDrawdown]
        case .sharpeRatio: [.volatility, .riskFreeRate]
        case .dividendYield: [.yieldOnCost]
        case .yieldOnCost: [.dividendYield]
        case .allocation: [.targetWeight, .rebalancing]
        case .targetWeight, .rebalancing: [.allocation]
        case .scope: [.externalFlows]
        case .investedCapital: [.externalFlows, .absolutePerformance]
        case .depot: [.referenceAccount, .cashAccount]
        case .referenceAccount: [.depot]
        case .winRate: [.profitFactor]
        case .drift: [.targetWeight, .rebalancing]
        case .netWorth: [.baseCurrency]
        case .stalePrice: [.quoteFeed]
        default: []
        }
    }
}

/// An ⓘ button that explains a finance term in a popover.
///
/// ```swift
/// HStack(spacing: DS.Spacing.xs) { Text("TTWROR"); HelpButton(.ttwror) }
/// StatTile("IRR", value: Fmt.percent(irr)).overlay(alignment: .topTrailing) { HelpButton(.irr) }
/// ```
public struct HelpButton: View {
    private let topic: HelpTopic
    @State private var shown: HelpTopic?

    public init(_ topic: HelpTopic) {
        self.topic = topic
    }

    public var body: some View {
        Button {
            shown = shown == nil ? topic : nil
        } label: {
            Image(systemName: "info.circle")
                .imageScale(.small)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("What is “\(topic.title)”?")
        .accessibilityLabel("Explain \(topic.title)")
        .popover(item: $shown, arrowEdge: .bottom) { current in
            HelpTopicView(topic: current) { shown = $0 }
        }
    }
}

/// A label followed by its ⓘ: `HelpLabel("Sharpe Ratio", topic: .sharpeRatio)`.
public struct HelpLabel: View {
    private let title: String
    private let topic: HelpTopic

    public init(_ title: String, topic: HelpTopic) {
        self.title = title
        self.topic = topic
    }

    public var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            Text(title)
            HelpButton(topic)
        }
    }
}

/// The content of a help popover; also usable inline (e.g. in an empty state or a settings pane).
public struct HelpTopicView: View {
    private let topic: HelpTopic
    private let open: ((HelpTopic) -> Void)?

    /// - Parameter open: Called when a related topic is clicked; without it related topics are not offered.
    public init(topic: HelpTopic, open: ((HelpTopic) -> Void)? = nil) {
        self.topic = topic
        self.open = open
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Text(topic.title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(topic.text)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let open, !topic.related.isEmpty {
                Divider().padding(.vertical, DS.Spacing.xxs)
                HStack(spacing: DS.Spacing.m) {
                    Text("See also").font(.caption).foregroundStyle(.secondary)
                    ForEach(topic.related) { related in
                        Button(related.title) { open(related) }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }
        }
        .padding(DS.Spacing.l)
        .frame(width: 340, alignment: .leading)
    }
}
