import AppKit
import SwiftUI
import KontorModel
import KontorUI
import KontorSampleData

/// Command line options of the headless screenshot mode.
struct ScreenshotOptions {
    enum Appearance: String { case light, dark, both }

    /// A screen id (`dashboard`, `holdings`, …), a shell surface (`welcome`, `palette`, `settings`,
    /// `portfolio-settings`, `consistency`, `quote-report`) or `all`.
    var target = "dashboard"
    var out = ""
    var demo = false
    var stress = false
    var open: String?
    var size = CGSize(width: 1440, height: 900)
    var appearance = Appearance.light
    var route: String?
    var period: String?
    var scope: String?
    var sheet: String?
    var state: [String: String] = [:]
    var today: Day?
    var locale: String?
    var showInspector = false
    var query = ""
    var scale: CGFloat = 1
    var onscreen = false
    var settleDelay = 0.6
    var redGains = false
    var timing = false
    var toast: String?
    var activity: BackgroundActivity?

    /// Surfaces of the shell that are not feature screens.
    static let shellTargets = ["welcome", "palette", "settings", "portfolio-settings", "consistency", "quote-report"]

    static let usage = """
    Kontor — headless screenshot mode

    USAGE
      Kontor --screenshot <target> --out <file.png | directory | -> [options]

    TARGETS
      \(AppScreen.allCases.map(\.rawValue).joined(separator: ", "))
      \(shellTargets.joined(separator: ", "))
      all            every target above; --out must be a directory (files: <target>[-light|-dark].png)

      --out -        writes the PNG to standard output (single target; works inside the App Sandbox)

    DATA
      --demo                     the demo portfolio (KontorSampleData, deterministic; ids are stable)
      --stress                   the stress portfolio: 200 securities × 25 years × 50,000 transactions,
                                 ending on "today"; prints the time until the screen settled
      --open <file.kontor>       this portfolio file ("-" reads it from standard input)
      --today <YYYY-MM-DD>       fix "today" (default: the real date) — use it for reproducible renders

    VIEW STATE
      --route <route>            focus an entity: security:<uuid>, account:<uuid>, depot:<uuid>,
                                 transaction:<uuid>, plan:<uuid>, taxonomy:<uuid>,
                                 classification:<taxonomy uuid>/<classification uuid>,
                                 or <screen>/<focus> (e.g. performance/security:<uuid>)
      --period <p>               reporting period: 1M 3M 6M YTD MTD QTD 1Y 3Y 5Y 10Y ALL, 30D,
                                 a year (2024) or a range (2024-01-01..2024-06-30)
      --scope <scope>            portfolio | depot:<uuid> | account:<uuid> |
                                 classification:<taxonomy uuid>/<classification uuid>
      --state <key>=<value>      feature-defined view state, repeatable (e.g. --state tab=rebalancing);
                                 screens read it from store.launchState when they appear
      --sheet <request>          present a sheet and capture it:
                                 new-transaction[:<kind>]  edit-transaction:<uuid>|first
                                 new-security  edit-security:<uuid>|first
                                 new-account   edit-account:<uuid>|first
                                 new-depot     edit-depot:<uuid>|first
                                 new-plan      edit-plan:<uuid>|first
                                 import[:<path>]  export[:transactions|securities|quotes:<uuid>|first]
                                 portfolio-settings  consistency
                                 custom:<id>[?key=value&key=value]
      --inspector                show the trailing inspector
      --query <text>             text typed into the command palette (target "palette")
      --toast <text>             show a toast notification
      --activity <text>          show a background activity, e.g. "Updating quotes 3/14"

    RENDERING
      --window-size <W>x<H>      window size in points (default 1440x900; alias: --size)
      --appearance light|dark|both   (default light; "both" adds -light/-dark to file names)
      --locale <id>              format numbers/dates for a locale, e.g. de_DE
      --red-gains                use the red-is-up color convention
      --scale <1|2>              pixels per point of the PNG (default 1)
      --delay <seconds>          extra settle time after the store reports idle (default 0.6)
      --timing                   print the time until the screen settled (always on with --stress)

    OTHER
      Kontor --write-demo <file.kontor> [--pretty] [--today <YYYY-MM-DD>]   save the demo portfolio
      Kontor --list-ids [--demo | --stress | --open <file>] [--today …]     print entity ids for --route/--sheet

    Features linked into this binary: \(FeatureCatalog.linkedFeatures.isEmpty ? "none" : FeatureCatalog.linkedFeatures.joined(separator: ", "))
    The screenshot mode never accesses the network.

    Exit status: 0 on success, 64 for bad arguments, 1 if rendering or writing failed.
    """

    struct ArgumentError: Error, CustomStringConvertible {
        let description: String
    }

    init(arguments: [String], requiresOutput: Bool = true) throws {
        var iterator = arguments.makeIterator()
        func value(_ flag: String) throws -> String {
            guard let v = iterator.next() else { throw ArgumentError(description: "missing value for \(flag)") }
            return v
        }
        while let argument = iterator.next() {
            switch argument {
            case "--screenshot": target = try value(argument)
            case "--list-ids": break
            case "--out": out = try value(argument)
            case "--demo": demo = true
            case "--stress": stress = true
            case "--open": open = try value(argument)
            case "--size", "--window-size":
                let parts = try value(argument).lowercased().split(separator: "x").compactMap { Double($0) }
                guard parts.count == 2, parts[0] >= 320, parts[1] >= 240, parts[0] <= 6000, parts[1] <= 6000 else {
                    throw ArgumentError(description: "\(argument) expects <width>x<height>, e.g. 1440x900")
                }
                size = CGSize(width: parts[0], height: parts[1])
            case "--appearance":
                guard let a = Appearance(rawValue: try value(argument)) else {
                    throw ArgumentError(description: "--appearance expects light, dark or both")
                }
                appearance = a
            case "--route": route = try value(argument)
            case "--period": period = try value(argument)
            case "--scope": scope = try value(argument)
            case "--sheet": sheet = try value(argument)
            case "--state":
                let pair = try value(argument)
                guard let equals = pair.firstIndex(of: "="), equals != pair.startIndex else {
                    throw ArgumentError(description: "--state expects <key>=<value>, e.g. --state tab=rebalancing")
                }
                state[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
            case "--today":
                guard let day = Day(iso: try value(argument)) else { throw ArgumentError(description: "--today expects YYYY-MM-DD") }
                today = day
            case "--locale": locale = try value(argument)
            case "--inspector": showInspector = true
            case "--query": query = try value(argument)
            case "--red-gains": redGains = true
            case "--timing": timing = true
            case "--toast": toast = try value(argument)
            case "--activity":
                // "Updating quotes 3/14" or just "Updating quotes" (indeterminate).
                let text = try value(argument)
                let parts = text.split(separator: " ")
                if let last = parts.last, let slash = last.firstIndex(of: "/"),
                   let done = Int(last[..<slash]), let total = Int(last[last.index(after: slash)...]) {
                    activity = BackgroundActivity(title: parts.dropLast().joined(separator: " "), completed: done, total: total)
                } else {
                    activity = BackgroundActivity(title: text)
                }
            case "--onscreen":
                onscreen = true
            case "--scale":
                guard let s = Double(try value(argument)), s == 1 || s == 2 else { throw ArgumentError(description: "--scale expects 1 or 2") }
                scale = s
            case "--delay":
                guard let d = Double(try value(argument)), d >= 0, d <= 30 else { throw ArgumentError(description: "--delay expects seconds (0…30)") }
                settleDelay = d
            default:
                throw ArgumentError(description: "unknown argument \(argument)")
            }
        }
        if [demo, stress, open != nil].filter({ $0 }).count > 1 {
            throw ArgumentError(description: "--demo, --stress and --open exclude each other")
        }
        guard !requiresOutput || !out.isEmpty else { throw ArgumentError(description: "--out is required") }
        if out == "-", target == "all" || appearance == .both {
            throw ArgumentError(description: "--out - (standard output) needs a single target and appearance")
        }
        // "chart-gallery" is a hidden debug target (KontorUI's ChartGallery); it is not part of "all".
        let known = AppScreen.allCases.map(\.rawValue) + Self.shellTargets + ["all", "chart-gallery"]
        guard known.contains(target) else {
            throw ArgumentError(description: "unknown screenshot target “\(target)”")
        }
        if let route, Route(string: route) == nil { throw ArgumentError(description: "cannot parse --route \(route)") }
        if let period, ReportingPeriod(code: period) == nil { throw ArgumentError(description: "cannot parse --period \(period)") }
        if let scope, ScopeSelection(string: scope) == nil { throw ArgumentError(description: "cannot parse --scope \(scope)") }
        if sheet != nil, target == "all" || target == "chart-gallery" || Self.shellTargets.contains(target) {
            throw ArgumentError(description: "--sheet needs a feature screen as target (the sheet is shown above it)")
        }
    }

    /// The portfolio the options ask for.
    func loadFile(today: Day) throws -> PortfolioFile {
        if open == "-" {
            do {
                return try PortfolioFile(data: FileHandle.standardInput.readDataToEndOfFile())
            } catch {
                throw ScreenshotRunner.Failure(description: "cannot read a portfolio from standard input: \(error)")
            }
        }
        if let path = open {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            do {
                return try PortfolioFile(data: Data(contentsOf: url))
            } catch {
                throw ScreenshotRunner.Failure(description: "cannot open \(url.path): \(error)")
            }
        }
        if stress { return SampleData.stressPortfolio(securities: 200, years: 25, transactions: 50_000, endingOn: today) }
        if demo { return SampleData.demoPortfolio(today: today) }
        return SampleData.starterPortfolio(name: "Untitled", baseCurrency: AppPreferences.defaultCurrency)
    }

    /// `--list-ids`: the entity ids of the selected portfolio, ready to paste into `--route`, `--scope`
    /// and `--sheet`.
    func listIDs() throws -> String {
        let file = try loadFile(today: today ?? .today)
        var lines: [String] = []
        func section(_ title: String, _ rows: [(String, String)], limit: Int = 40) {
            guard !rows.isEmpty else { return }
            lines.append("\(title) (\(rows.count))")
            for (id, name) in rows.prefix(limit) { lines.append("  \(id)  \(name)") }
            if rows.count > limit { lines.append("  … \(rows.count - limit) more") }
        }
        section("securities — security:<id>", file.securities.map { ("security:\($0.id.uuidString)", $0.name) })
        section("accounts — account:<id>", file.accounts.map { ("account:\($0.id.uuidString)", "\($0.name) (\($0.currency))") })
        section("depots — depot:<id>", file.depots.map { ("depot:\($0.id.uuidString)", $0.name) })
        section("plans — plan:<id>", file.plans.map { ("plan:\($0.id.uuidString)", $0.name) })
        section("taxonomies — taxonomy:<id>", file.taxonomies.map { ("taxonomy:\($0.id.uuidString)", $0.name) })
        for taxonomy in file.taxonomies {
            section("classifications of “\(taxonomy.name)” — classification:<taxonomy>/<id>", taxonomy.flattened.map {
                ("classification:\(taxonomy.id.uuidString)/\($0.classification.id.uuidString)", String(repeating: "  ", count: $0.depth) + $0.classification.name)
            })
        }
        section("transactions — transaction:<id> (first 10, chronological)",
                file.transactions.sorted(by: Transaction.chronological).prefix(10).map { ("transaction:\($0.id.uuidString)", "\($0.date.iso) \($0.kind.rawValue)") })
        return lines.joined(separator: "\n")
    }
}

/// Renders app surfaces into PNG files without user interaction, then exits.
///
/// Each shot hosts the real SwiftUI hierarchy (`MainWindowView` & co.) in a real `NSWindow`, waits
/// until `store.isBusy` has settled, and captures the window as composited by the window server —
/// so toolbars, Liquid Glass materials, tables and charts look exactly as on screen.
@MainActor
enum ScreenshotRunner {
    static func run(_ options: ScreenshotOptions) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = Delegate(options: options)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
        exit(0)
    }

    private final class Delegate: NSObject, NSApplicationDelegate {
        let options: ScreenshotOptions
        init(options: ScreenshotOptions) { self.options = options }

        func applicationDidFinishLaunching(_ notification: Notification) {
            Task { @MainActor in
                do {
                    let files = try await ScreenshotRunner.render(options)
                    for file in files { print(file.path) }
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data("kontor: screenshot failed: \(error)\n".utf8))
                    exit(1)
                }
            }
        }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    // MARK: Rendering

    static func render(_ options: ScreenshotOptions) async throws -> [URL] {
        if let locale = options.locale { Fmt.setLocale(Locale(identifier: locale)) }
        // Process-local override (the volatile "argument" domain wins over the user's saved
        // preferences and is never written to disk): concurrent screenshot runs do not see each
        // other's --red-gains, and a real preference is never touched.
        var overrides = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        overrides[AppPreferences.Key.gainStyle] = (options.redGains ? GainStyle.redUp : GainStyle.greenUp).rawValue
        UserDefaults.standard.setVolatileDomain(overrides, forName: UserDefaults.argumentDomain)

        let today = options.today ?? .today
        let file = try options.loadFile(today: today)
        let targets = options.target == "all" ? AppScreen.allCases.map(\.rawValue) + ScreenshotOptions.shellTargets : [options.target]
        let appearances: [ScreenshotOptions.Appearance] = options.appearance == .both ? [.light, .dark] : [options.appearance]
        if options.out == "-" {
            // Standard output: works even inside the App Sandbox (`Kontor --screenshot x --out - > x.png`).
            let image = try await shoot(target: options.target, appearance: options.appearance, file: file, today: today, options: options)
            guard let png = image.representation(using: .png, properties: [:]) else {
                throw Failure(description: "could not encode PNG for \(options.target)")
            }
            FileHandle.standardOutput.write(png)
            return []
        }
        let outURL = URL(fileURLWithPath: (options.out as NSString).expandingTildeInPath)
        let multiple = targets.count > 1 || appearances.count > 1
        let isDirectory = options.target == "all" || outURL.pathExtension.isEmpty
        if isDirectory {
            try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)
        } else {
            try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        }

        var written = [URL]()
        for target in targets {
            for appearance in appearances {
                let image = try await shoot(target: target, appearance: appearance, file: file, today: today, options: options)
                let url: URL
                if isDirectory {
                    url = outURL.appendingPathComponent(appearances.count > 1 ? "\(target)-\(appearance.rawValue).png" : "\(target).png")
                } else if multiple {
                    let base = outURL.deletingPathExtension().lastPathComponent
                    url = outURL.deletingLastPathComponent().appendingPathComponent("\(base)-\(appearance.rawValue).png")
                } else {
                    url = outURL
                }
                guard let png = image.representation(using: .png, properties: [:]) else {
                    throw Failure(description: "could not encode PNG for \(target)")
                }
                do {
                    try png.write(to: url, options: .atomic)
                } catch {
                    let sandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
                    throw Failure(description: "cannot write \(url.path): \(error.localizedDescription)"
                        + (sandboxed ? " — this build is sandboxed and may only write inside its container; use the debug bundle (Scripts/bundle.sh debug) for screenshots." : ""))
                }
                written.append(url)
            }
        }
        return written
    }

    private static func shoot(
        target: String, appearance: ScreenshotOptions.Appearance, file: PortfolioFile, today: Day, options: ScreenshotOptions
    ) async throws -> NSBitmapImageRep {
        let registry = ShellContext.shared.registry
        let started = ContinuousClock.now
        let store = PortfolioStore(file: file, today: today)
        // No updater: the screenshot mode never touches the network.
        ShellContext.shared.installServices(on: store, network: false)
        if let period = options.period.flatMap(ReportingPeriod.init(code:)) { store.period = period }
        if let scope = options.scope.flatMap(ScopeSelection.init(string:)) {
            guard scope.resolve(in: file) != nil else { throw Failure(description: "--scope \(options.scope ?? "") does not exist in this portfolio") }
            store.scopeSelection = scope
        }
        store.launchState = options.state
        store.isInspectorPresented = options.showInspector
        var sheetRequest: SheetRequest?
        if let text = options.sheet {
            guard let request = SheetRequest.parse(text, in: file) else {
                throw Failure(description: "cannot resolve --sheet \(text) (malformed, unknown id, or “first” of an empty list)")
            }
            sheetRequest = request
        }

        var size = options.size
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        var title = file.name.isEmpty ? "Untitled" : file.name
        var capturesSheet = false
        let content: AnyView

        switch target {
        case "welcome":
            size = CGSize(width: 760, height: 520)
            title = ""
            let recents = ["Family Portfolio", "Retirement", "Kids’ Savings"].map {
                URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/\($0).kontor")
            }
            content = AnyView(WelcomeView(actions: WelcomeActions(), recents: options.demo ? recents : []).ignoresSafeArea())
        case "chart-gallery":
            // Debug gallery of the shared chart kit; pages via --state page=time|bars|parts|grids|states.
            title = "Chart Gallery"
            content = AnyView(ChartGallery().environment(store).environment(\.gainStyle, AppPreferences.gainStyle))
        case "settings":
            size = CGSize(width: 520, height: 640)
            style = [.titled, .closable]
            title = "General"
            content = AnyView(GeneralSettings().environment(\.gainStyle, AppPreferences.gainStyle).frame(width: 520, height: 640))
        default:
            if let screen = AppScreen(rawValue: target) {
                store.restore(route: options.route.flatMap(Route.init(string:)).map { Route(screen, focus: $0.focus) } ?? Route(screen))
            } else if let route = options.route.flatMap(Route.init(string:)) {
                store.restore(route: route)
            }
            switch target {
            case "palette": store.openCommandPalette(query: options.query)
            case "portfolio-settings": sheetRequest = .portfolioSettings
            case "consistency": sheetRequest = .consistencyReport
            default: break
            }
            capturesSheet = sheetRequest != nil
            content = AnyView(MainWindowView(store: store, registry: registry))
        }

        let window = ShotWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
        window.title = title
        window.animationBehavior = .none
        if target == "welcome" {
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
        } else {
            window.toolbarStyle = .unified
        }
        let host = NSHostingController(rootView: content)
        host.sceneBridgingOptions = .all
        host.sizingOptions = []
        window.contentViewController = host
        window.setContentSize(size)
        // Never disturb the person using this Mac: the window sits beneath the desktop picture,
        // ordered in without becoming key and the app is NOT activated. The window server still
        // composites it, and `ShotWindow` reports itself as key/main so it draws in its active state.
        // `--onscreen` restores a visible, frontmost window for debugging.
        if options.onscreen {
            if let screen = NSScreen.main {
                let visible = screen.visibleFrame
                window.setFrameOrigin(CGPoint(x: visible.minX + 20, y: max(visible.minY, visible.maxY - window.frame.height - 20)))
            }
            window.makeKeyAndOrderFront(nil)
            await activateForCapture()
        } else {
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.stationary, .ignoresCycle, .transient]
            if let screen = NSScreen.main {
                let visible = screen.visibleFrame
                window.setFrameOrigin(CGPoint(x: visible.minX + 20, y: max(visible.minY, visible.maxY - window.frame.height - 20)))
            }
            // Below the desktop picture: fully composited by the window server, never visible.
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
            window.orderBack(nil)
        }
        defer { window.close() }

        // Let SwiftUI build the hierarchy and install the toolbar, then trigger target-specific state.
        try await Task.sleep(for: .milliseconds(250))
        if let sheetRequest { store.present(sheetRequest) }

        let settled = await store.waitUntilSettled(quietPeriod: .milliseconds(200), timeout: .seconds(60))
        if options.timing || options.stress {
            // Time from creating the store until its last busy → idle transition (the screen's data
            // is complete), and how much of that the analysis layer was actually working.
            let seconds = { (d: Duration) in String(format: "%.2f", Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18) }
            let cache = store.analysisCache.statistics
            let message: String
            if settled == nil {
                message = "did NOT settle within 60 s"
            } else if let idle = store.lastIdleAt {
                message = "settled \(seconds(idle - started)) s after launch (busy for \(seconds(store.busyTime)) s)"
            } else {
                message = "settled immediately (no asynchronous work)"
            }
            FileHandle.standardError.write(Data("""
            kontor: \(target) [\(appearance.rawValue)] \(message) — \(file.transactions.count) transactions, \(file.securities.count) securities; \
            analysis cache: \(cache.computed) computed, \(cache.hits) hits, \(cache.joins) shared, \(cache.ledgersBuilt) ledger build(s)\n
            """.utf8))
        }
        // Decorations that would otherwise keep the store "busy" are applied after settling.
        if let toast = options.toast { store.show(Toast(toast, style: .success, duration: 60)) }
        if let activity = options.activity {
            store.beginActivity(activity.title, total: activity.total)
            store.updateActivity(completed: activity.completed)
        }
        if target == "quote-report" { store.presentQuoteReport(sampleQuoteReport(file, today: today)) }
        try await Task.sleep(for: .seconds(options.settleDelay + (capturesSheet || target == "quote-report" ? 0.8 : 0)))
        window.displayIfNeeded()
        CATransaction.flush()

        let rep = try capture(window, scale: options.scale)
        if capturesSheet { store.dismissSheet() }
        store.isQuoteReportPresented = false
        return rep
    }

    /// A representative outcome of a quote update (some new data, a few typical failures) for the
    /// `quote-report` target — built from the file's own securities, without any network access.
    private static func sampleQuoteReport(_ file: PortfolioFile, today: Day) -> QuoteUpdateReport {
        let messages = [
            "The symbol was not found. Check the ticker in the security's quote feed.",
            "The feed quotes in USD, but the security is kept in EUR.",
            "The server did not respond in time. Try again later.",
        ]
        let candidates = file.securities.filter { !$0.isRetired }
        let failures = zip(candidates.dropFirst(2).prefix(messages.count), messages).map {
            QuoteUpdateReport.Failure(securityID: $0.id, name: $0.name, message: $1)
        }
        return QuoteUpdateReport(
            finishedAt: today.date().addingTimeInterval(17 * 3600 + 42 * 60), targetCount: max(candidates.count, failures.count), newPrices: max(0, candidates.count - failures.count) * 3,
            newRates: 6, changedSecurities: max(0, candidates.count - failures.count), failures: failures)
    }

    /// Brings the process to the front so the window is composited in its active state (accent
    /// colored selection, vivid traffic lights). Plain `activate()` is cooperative and is often
    /// declined when launched from a terminal, so the unconditional variant is requested as well.
    private static func activateForCapture() async {
        NSApp.activate()
        for attempt in 0..<20 where !NSApp.isActive {
            if attempt == 2 {
                let selector = NSSelectorFromString("activateIgnoringOtherApps:")
                if NSApp.responds(to: selector) { NSApp.perform(selector, with: NSNumber(value: true)) }
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: Capture

    /// Captures the window (including an attached sheet) from the window server, which is the only
    /// path that faithfully includes toolbars and glass materials. Falls back to rendering the view
    /// hierarchy in-process if the window server refuses (no display session).
    private static func capture(_ window: NSWindow, scale: CGFloat) throws -> NSBitmapImageRep {
        let pointSize = window.frame.size
        var image: CGImage?
        // Front to back: popovers (child windows), an attached sheet, the window itself.
        var windows: [NSWindow] = (window.childWindows ?? []).filter { $0.isVisible && $0 !== window.attachedSheet }.reversed()
        if let sheet = window.attachedSheet {
            windows.append(contentsOf: (sheet.childWindows ?? []).filter(\.isVisible).reversed())
            windows.append(sheet)
        }
        windows.append(window)
        image = WindowServerCapture.image(of: windows, bounds: window.frame)
        if let captured = image, !isBlank(captured) {
            return try resample(captured, to: pointSize, scale: scale)
        }
        // In-process fallback: draws the frame view (titlebar + content) into a bitmap.
        guard let frameView = window.contentView?.superview ?? window.contentView,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else {
            throw Failure(description: "window has no view to capture")
        }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        guard let cg = rep.cgImage else { throw Failure(description: "in-process capture produced no image") }
        return try resample(cg, to: pointSize, scale: scale)
    }

    private static func resample(_ image: CGImage, to pointSize: CGSize, scale: CGFloat) throws -> NSBitmapImageRep {
        let width = Int((pointSize.width * scale).rounded()), height = Int((pointSize.height * scale).rounded())
        if image.width == width, image.height == height {
            let rep = NSBitmapImageRep(cgImage: image)
            rep.size = pointSize
            return rep
        }
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw Failure(description: "could not create bitmap context") }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { throw Failure(description: "could not scale capture") }
        let rep = NSBitmapImageRep(cgImage: scaled)
        rep.size = pointSize
        return rep
    }

    /// True if the capture is fully transparent (what the window server returns when it cannot see the window).
    private static func isBlank(_ image: CGImage) -> Bool {
        let w = 32, h = 32
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let context = CGContext(
            data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return !pixels.contains { $0 != 0 }
    }
}

/// A window that always renders in its active (key/main) state, so captures show the focused look
/// even though the screenshot process never becomes the frontmost app.
private final class ShotWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Window-server capture of the app's own windows.
///
/// `CGWindowListCreateImageFromArray` is not exposed to Swift in current SDKs (ScreenCaptureKit is
/// the replacement) but remains the only API that captures *this process's own windows* without a
/// Screen Recording permission prompt, which a headless tool cannot answer. It is resolved at
/// runtime and used only by the screenshot mode.
private enum WindowServerCapture {
    private typealias CreateImageFromArray = @convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?

    @MainActor
    static func image(of windows: [NSWindow], bounds: CGRect) -> CGImage? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImageFromArray"),
              let primary = NSScreen.screens.first else { return nil }
        let function = unsafeBitCast(symbol, to: CreateImageFromArray.self)
        // Window ids are passed as raw pointer-sized values in a CFArray without callbacks,
        // ordered front to back.
        var ids = windows.map { UnsafeRawPointer(bitPattern: UInt($0.windowNumber)) }
        guard let array = CFArrayCreate(kCFAllocatorDefault, &ids, ids.count, nil) else { return nil }
        // Quartz display coordinates have their origin at the top left of the primary display.
        let rect = CGRect(x: bounds.minX, y: primary.frame.maxY - bounds.maxY, width: bounds.width, height: bounds.height)
        let bestResolution: UInt32 = 1 << 3
        return function(rect, array, bestResolution)?.takeRetainedValue()
    }
}
