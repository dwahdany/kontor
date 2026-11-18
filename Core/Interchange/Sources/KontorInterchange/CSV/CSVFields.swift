import Foundation
import KontorModel

/// What a CSV file is imported as.
public enum CSVImportTarget: String, Hashable, Sendable, Codable, CaseIterable {
    /// Ledger entries — cash and securities transactions may be mixed in one file.
    case transactions
    /// Historical quotes of one security.
    case quotes
    /// Securities master data (name, ISIN, WKN, ticker, currency).
    case securities

    /// The fields a column can be mapped to for this target, in presentation order.
    public var fields: [CSVField] {
        switch self {
        case .transactions: return CSVField.allCases
        case .quotes: return [.date, .quote]
        case .securities: return [.securityName, .isin, .wkn, .ticker, .currency, .note]
        }
    }

    /// Fields without which nothing can be imported.
    public var requiredFields: [CSVField] {
        switch self {
        case .transactions: return [.date]
        case .quotes: return [.date, .quote]
        case .securities: return []
        }
    }
}

/// The meaning of a CSV column.
public enum CSVField: String, Hashable, Sendable, Codable, CaseIterable {
    case date, time, type
    case securityName, isin, wkn, ticker
    case shares, quote, amount, fees, taxes, currency
    case grossAmount, grossCurrency, exchangeRate
    case account, counterAccount, depot, counterDepot
    case note

    /// English label for the mapping UI.
    public var displayName: String {
        switch self {
        case .date: return "Date"
        case .time: return "Time"
        case .type: return "Type"
        case .securityName: return "Security Name"
        case .isin: return "ISIN"
        case .wkn: return "WKN"
        case .ticker: return "Ticker Symbol"
        case .shares: return "Shares"
        case .quote: return "Quote"
        case .amount: return "Value"
        case .fees: return "Fees"
        case .taxes: return "Taxes"
        case .currency: return "Transaction Currency"
        case .grossAmount: return "Gross Amount"
        case .grossCurrency: return "Currency Gross Amount"
        case .exchangeRate: return "Exchange Rate"
        case .account: return "Cash Account"
        case .counterAccount: return "Offset Account"
        case .depot: return "Securities Account"
        case .counterDepot: return "Offset Securities Account"
        case .note: return "Note"
        }
    }

    /// Header names (normalized: lower case, no diacritics, letters and digits only) that identify the
    /// field, most specific first. Includes the column names of Portfolio Performance's own CSV
    /// export in English and German and common broker/bank export headers.
    var synonyms: [String] {
        switch self {
        case .date:
            return ["date", "datum", "buchungstag", "buchungsdatum", "handelstag", "handelsdatum", "tradedate", "transactiondate", "ausfuhrungsdatum",
                    "ausfuhrungstag", "valuta", "valutadatum", "wertstellung", "datumwert", "dateofvalue", "kursdatum", "dateofquote", "bookingdate",
                    "settlementdate", "datetime", "timestamp", "zeitpunkt", "tag", "day", "geschaftstag", "executiondate", "orderdate"]
        case .time:
            return ["time", "uhrzeit", "zeit", "handelszeit", "ausfuhrungszeit", "tradetime", "executiontime"]
        case .type:
            return ["type", "typ", "transactiontype", "transaktionstyp", "transaktionsart", "action", "aktion", "activity", "aktivitat", "art", "umsatzart",
                    "buchungsart", "geschaftsart", "vorgang", "transaktion", "transaction", "operation", "side", "kaufverkauf", "buysell", "orderart", "ordertyp", "ordertype"]
        case .securityName:
            return ["securityname", "wertpapiername", "wertpapier", "wertpapierbezeichnung", "security", "bezeichnung", "instrument", "produkt", "product",
                    "asset", "titel", "stock", "fund", "fonds", "aktie", "name", "securitydescription", "instrumentname", "produktname", "description"]
        case .isin:
            return ["isin", "isincode", "isinnummer"]
        case .wkn:
            return ["wkn", "wertpapierkennnummer", "wknr", "wertpapierkennummer"]
        case .ticker:
            return ["tickersymbol", "ticker", "symbol", "kurzel", "borsenkurzel", "stocksymbol", "tickersymbolyahoo"]
        case .shares:
            return ["shares", "stuck", "stucke", "stuckzahl", "quantity", "qty", "anzahl", "anteile", "units", "menge", "nominal", "nominale", "stucknominale",
                    "numberofshares", "anzahlstuck", "stk", "noofshares"]
        case .quote:
            return ["quote", "kurs", "close", "schluss", "schlusskurs", "adjclose", "adjustedclose", "price", "preis", "ausfuhrungskurs", "kursprostuck",
                    "pricepershare", "unitprice", "stuckpreis", "executionprice", "last", "letzter", "purchaseprice", "kaufkurs", "closingprice"]
        case .amount:
            return ["value", "wert", "amount", "betrag", "gesamtbetrag", "total", "totalamount", "gesamt", "netamount", "nettobetrag", "netto", "endbetrag",
                    "buchungsbetrag", "ausmachenderbetrag", "umsatz", "proceeds", "nettowert", "transactionvalue", "cashflow", "sollhaben", "debitcredit", "summe"]
        case .fees:
            return ["fees", "fee", "gebuhren", "gebuhr", "provision", "commission", "commissions", "kosten", "spesen", "ordergebuhr", "transaktionskosten",
                    "charges", "transactioncosts", "feesandcommissions", "fremdkosten", "orderprovision", "entgelt"]
        case .taxes:
            return ["taxes", "tax", "steuern", "steuer", "kapitalertragsteuer", "kapitalertragssteuer", "kest", "quellensteuer", "withholdingtax", "abgeltungsteuer",
                    "abgeltungssteuer", "taxamount", "steuerbetrag"]
        case .currency:
            return ["transactioncurrency", "buchungswahrung", "currency", "wahrung", "ccy", "curr", "whrg", "currencycode", "transaktionswahrung", "kontowahrung",
                    "abrechnungswahrung", "settlementcurrency"]
        case .grossAmount:
            return ["grossamount", "bruttobetrag", "gross", "brutto", "grossvalue", "bruttowert", "kurswert", "marketvalue"]
        case .grossCurrency:
            return ["currencygrossamount", "wahrungbruttobetrag", "grosscurrency", "bruttowahrung", "originalcurrency", "originalwahrung", "wertpapierwahrung",
                    "securitycurrency", "handelswahrung", "tradecurrency"]
        case .exchangeRate:
            return ["exchangerate", "wechselkurs", "fxrate", "devisenkurs", "umrechnungskurs", "conversionrate", "fx", "kursfx", "wahrungskurs"]
        case .account:
            return ["cashaccount", "konto", "account", "accountname", "kontoname", "verrechnungskonto", "kontobezeichnung", "geldkonto"]
        case .counterAccount:
            return ["offsetaccount", "gegenkonto", "counteraccount", "targetaccount", "zielkonto", "toaccount", "empfangerkonto"]
        case .depot:
            return ["securitiesaccount", "depot", "portfolio", "depotname", "portfolioname", "custodyaccount", "brokerageaccount", "wertpapierdepot", "depotbezeichnung"]
        case .counterDepot:
            return ["offsetsecuritiesaccount", "gegendepot", "counterdepot", "zieldepot", "targetportfolio", "todepot"]
        case .note:
            return ["note", "notiz", "notes", "notizen", "comment", "comments", "kommentar", "bemerkung", "memo", "verwendungszweck", "buchungstext", "text",
                    "beschreibung", "remarks", "anmerkung", "info", "details"]
        }
    }

    /// Lower-cases, removes diacritics, parenthesised units like "(EUR)" and everything but letters and digits.
    static func normalize(_ text: String) -> String {
        var depth = 0
        var kept = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar == "(" || scalar == "[" { depth += 1; continue }
            if scalar == ")" || scalar == "]" { depth = max(0, depth - 1); continue }
            if depth == 0 { kept.append(scalar) }
        }
        let base = String(kept).isEmpty ? text : String(kept)
        let folded = base.replacingOccurrences(of: "ß", with: "ss").folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        return String(folded.unicodeScalars.filter { $0.properties.isAlphabetic || ($0.value >= 48 && $0.value <= 57) })
    }

    private static let exactIndex: [String: CSVField] = {
        var index: [String: CSVField] = [:]
        for field in CSVField.allCases {
            for synonym in field.synonyms where index[synonym] == nil { index[synonym] = field }
        }
        return index
    }()

    /// The field a column title most likely denotes, or nil.
    public static func match(header: String) -> CSVField? {
        let key = normalize(header)
        guard !key.isEmpty else { return nil }
        if let exact = exactIndex[key] { return exact }
        // "Betrag in EUR", "Kurs EUR", "Gebühren gesamt": a known name followed by decoration.
        var best: (field: CSVField, length: Int)?
        for field in CSVField.allCases {
            for synonym in field.synonyms where synonym.count >= 4 && key.hasPrefix(synonym) {
                if synonym.count > (best?.length ?? 0) { best = (field, synonym.count) }
            }
        }
        return best?.field
    }
}

/// Assignment of CSV columns to fields.
public struct CSVColumnMapping: Hashable, Sendable, Codable {
    /// One entry per column: the field it feeds, or nil to ignore the column.
    public var columns: [CSVField?]

    public init(columns: [CSVField?]) { self.columns = columns }

    /// Index of the column mapped to `field`.
    public func column(for field: CSVField) -> Int? { columns.firstIndex(of: field) }

    /// Maps `field` to `column` (un-mapping whatever used either before); nil removes the field.
    public mutating func set(_ field: CSVField, column: Int?) {
        for index in columns.indices where columns[index] == field { columns[index] = nil }
        if let column, columns.indices.contains(column) { columns[column] = field }
    }

    /// Guesses the mapping from the column titles using multilingual synonyms. Each field is assigned
    /// to at most one column (the first match); exact title matches win over partial ones.
    public static func automatic(header: [String], target: CSVImportTarget = .transactions) -> CSVColumnMapping {
        let allowed = Set(target.fields)
        var columns = [CSVField?](repeating: nil, count: header.count)
        var used: Set<CSVField> = []
        let keys = header.map(CSVField.normalize)
        // Pass 1: exact synonyms, in order of each field's synonym priority.
        for field in target.fields {
            search: for synonym in field.synonyms {
                for (index, key) in keys.enumerated() where columns[index] == nil && key == synonym {
                    columns[index] = field
                    used.insert(field)
                    break search
                }
            }
        }
        // Pass 2: decorated titles.
        for (index, title) in header.enumerated() where columns[index] == nil {
            if let field = CSVField.match(header: title), allowed.contains(field), !used.contains(field) {
                columns[index] = field
                used.insert(field)
            }
        }
        // A two-column quotes file without recognisable titles is date + quote.
        if target == .quotes, !used.contains(.quote), header.count == 2 {
            if columns[0] == nil, !used.contains(.date) { columns[0] = .date }
            if columns[1] == nil { columns[1] = .quote }
        }
        return CSVColumnMapping(columns: columns)
    }
}

/// The transaction types a CSV "type" cell can denote.
public enum CSVTransactionType: String, Hashable, Sendable, Codable, CaseIterable {
    case buy, sell, deliveryIn, deliveryOut
    case deposit, withdrawal
    case dividend, interest, interestCharge
    case fee, feeRefund, tax, taxRefund
    /// A transfer whose direction follows from the accounts / the sign of the amount.
    case transfer
    case transferIn, transferOut

    var synonyms: [String] {
        switch self {
        case .buy:
            return ["buy", "kauf", "purchase", "bought", "kaufen", "b", "k", "wertpapierkauf", "sparplan", "savingsplan", "sparplanausfuhrung", "buyorder", "marketbuy",
                    "limitbuy", "erwerb", "zeichnung", "ankauf", "kaufmarket", "kauflimit", "ordertobuy", "reinvestment", "wiederanlage"]
        case .sell:
            return ["sell", "verkauf", "sale", "sold", "verkaufen", "s", "v", "wertpapierverkauf", "marketsell", "limitsell", "sellorder", "ruckgabe", "ruckzahlung", "tilgung"]
        case .deliveryIn:
            return ["deliveryinbound", "einlieferung", "delivery", "depoteingang", "einbuchung", "depotubertrageingang", "inbounddelivery", "wertpapiereinlieferung", "bonusaktien", "spinoff"]
        case .deliveryOut:
            return ["deliveryoutbound", "auslieferung", "depotausgang", "ausbuchung", "depotubertragausgang", "outbounddelivery", "wertpapierauslieferung"]
        case .deposit:
            return ["deposit", "einlage", "einzahlung", "cashin", "gutschrift", "uberweisungseingang", "geldeingang", "depositcash", "inpayment", "paymentin"]
        case .withdrawal:
            return ["removal", "withdrawal", "entnahme", "auszahlung", "cashout", "uberweisungsausgang", "geldausgang", "outpayment", "paymentout", "abhebung"]
        case .dividend:
            return ["dividend", "dividends", "dividende", "dividenden", "ausschuttung", "distribution", "ertrag", "ertragsgutschrift", "div", "coupon", "kupon",
                    "wertpapierertrag", "dividendenzahlung", "cashdividend", "dividendengutschrift", "ertragnisgutschrift", "zinskupon"]
        case .interest:
            return ["interest", "zinsen", "zins", "zinsgutschrift", "interestpayment", "habenzinsen", "zinsertrag", "guthabenzinsen", "interestreceived"]
        case .interestCharge:
            return ["interestcharge", "zinsbelastung", "sollzinsen", "debitinterest", "interestpaid", "uberziehungszinsen"]
        case .fee:
            return ["fees", "fee", "gebuhren", "gebuhr", "kosten", "depotgebuhr", "depotgebuhren", "entgelt", "commission", "kontofuhrung", "kontofuhrungsgebuhr", "charge"]
        case .feeRefund:
            return ["feesrefund", "feerefund", "gebuhrenerstattung", "gebuhrenruckerstattung", "kostenerstattung"]
        case .tax:
            return ["taxes", "tax", "steuern", "steuer", "kapitalertragsteuer", "kapitalertragssteuer", "steuerbelastung", "vorabpauschale", "quellensteuer", "withholdingtax"]
        case .taxRefund:
            return ["taxrefund", "steuerruckerstattung", "steuererstattung", "taxrebate", "steuergutschrift", "steuerkorrektur"]
        case .transfer:
            return ["transfer", "umbuchung", "ubertrag", "accounttransfer", "kontoubertrag", "internaltransfer"]
        case .transferIn:
            return ["transferinbound", "umbuchungeingang", "transferin", "ubertrageingang"]
        case .transferOut:
            return ["transferoutbound", "umbuchungausgang", "transferout", "ubertragausgang"]
        }
    }

    private static let index: [String: CSVTransactionType] = {
        var index: [String: CSVTransactionType] = [:]
        for type in CSVTransactionType.allCases {
            for synonym in type.synonyms where index[synonym] == nil { index[synonym] = type }
        }
        return index
    }()

    /// Interprets a type cell ("Kauf", "Dividend", "Transfer (Outbound)" …) in English or German.
    public static func match(_ text: String) -> CSVTransactionType? {
        // Parentheses carry meaning here ("Transfer (Inbound)"), so only case, diacritics and punctuation are folded.
        let folded = text.replacingOccurrences(of: "ß", with: "ss").folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        let key = String(folded.unicodeScalars.filter { $0.properties.isAlphabetic })
        guard !key.isEmpty else { return nil }
        return index[key]
    }

    /// English label for pickers (e.g. when assigning `ImportProposal.unrecognizedTypes` to a type).
    public var displayName: String { label(german: false) }

    /// The label used when exporting, matching Portfolio Performance's vocabulary.
    func label(german: Bool) -> String {
        switch self {
        case .buy: return german ? "Kauf" : "Buy"
        case .sell: return german ? "Verkauf" : "Sell"
        case .deliveryIn: return german ? "Einlieferung" : "Delivery (Inbound)"
        case .deliveryOut: return german ? "Auslieferung" : "Delivery (Outbound)"
        case .deposit: return german ? "Einlage" : "Deposit"
        case .withdrawal: return german ? "Entnahme" : "Removal"
        case .dividend: return german ? "Dividende" : "Dividend"
        case .interest: return german ? "Zinsen" : "Interest"
        case .interestCharge: return german ? "Zinsbelastung" : "Interest Charge"
        case .fee: return german ? "Gebühren" : "Fees"
        case .feeRefund: return german ? "Gebührenerstattung" : "Fees Refund"
        case .tax: return german ? "Steuern" : "Taxes"
        case .taxRefund: return german ? "Steuerrückerstattung" : "Tax Refund"
        case .transfer: return german ? "Umbuchung" : "Transfer"
        case .transferIn: return german ? "Umbuchung (Eingang)" : "Transfer (Inbound)"
        case .transferOut: return german ? "Umbuchung (Ausgang)" : "Transfer (Outbound)"
        }
    }
}
