import AppKit
import SwiftUI
import KontorModel
import KontorUI

/// Command line options of the headless screenshot mode.
struct ScreenshotOptions {
    enum Appearance: String { case light, dark, both }

    /// A screen id (`dashboard`, `holdings`, …), a shell surface (`welcome`, `palette`, `settings`,
    /// `portfolio-settings`, `consistency`) or `all`.
    var target = "dashboard"
    var out = ""
    var demo = false
    var open: String?
    var size = CGSize(width: 1440, height: 900)
    var appearance = Appearance.light
    var route: String?
    var period: String?
    var today: Day?
    var locale: String?
    var showInspector = false
    var query = ""
    var scale: CGFloat = 1
    var settleDelay = 0.6
    var redGains = false
    var toast: String?
    var activity: BackgroundActivity?

    /// Surfaces of the shell that are not feature screens.
    static let shellTargets = ["welcome", "palette", "settings", "portfolio-settings", "consistency"]

    static let usage = """
    Kontor — headless screenshot mode

    USAGE
      Kontor --screenshot <target> --out <file.png | directory | -> [options]

    TARGETS
      \(AppScreen.allCases.map(\.rawValue).joined(separator: ", "))
      \(shellTargets.joined(separator: ", "))
      all            every target above; --out must be a directory (files: <target>[-light|-dark].png)

      --out -        writes the PNG to standard output (single target; works inside the App Sandbox)

    OPTIONS
      --demo                     use the built-in demo portfolio
      --open <file.kontor>       use this portfolio file ("-" reads it from standard input)
      --size <W>x<H>             window size in points (default 1440x900)
      --appearance light|dark|both   (default light; "both" adds -light/-dark to file names)
      --route <route>            focus an entity: security:<uuid>, account:<uuid>, depot:<uuid>,
                                 transaction:<uuid>, plan:<uuid>, taxonomy:<uuid>, or <screen>/<kind>:<uuid>
      --period <p>               reporting period: 1M 3M 6M YTD 1Y 3Y 5Y ALL or a year like 2024
      --today <YYYY-MM-DD>       fix "today" for reproducible renders
      --locale <id>              format numbers/dates for a locale, e.g. de_DE
      --inspector                show the trailing inspector
      --query <text>             text typed into the command palette (target "palette")
      --red-gains                use the red-is-up color convention
      --toast <text>             show a toast notification
      --activity <text>          show a background activity, e.g. "Updating quotes 3/14"
      --scale <1|2>              pixels per point of the PNG (default 1)
      --delay <seconds>          extra settle time after the store reports idle (default 0.6)

    OTHER
      Kontor --write-demo <file.kontor> [--pretty]   save the demo portfolio as a document

    Exit status: 0 on success, 64 for bad arguments, 1 if rendering or writing failed.
    """

    struct ArgumentError: Error, CustomStringConvertible {
        let description: String
    }

    init(arguments: [String]) throws {
        var iterator = arguments.makeIterator()
        func value(_ flag: String) throws -> String {
            guard let v = iterator.next() else { throw ArgumentError(description: "missing value for \(flag)") }
            return v
        }
        while let argument = iterator.next() {
            switch argument {
            case "--screenshot": target = try value(argument)
            case "--out": out = try value(argument)
            case "--demo": demo = true
            case "--open": open = try value(argument)
            case "--size":
                let parts = try value(argument).lowercased().split(separator: "x").compactMap { Double($0) }
                guard parts.count == 2, parts[0] >= 320, parts[1] >= 240, parts[0] <= 6000, parts[1] <= 6000 else {
                    throw ArgumentError(description: "--size expects <width>x<height>, e.g. 1440x900")
                }
                size = CGSize(width: parts[0], height: parts[1])
            case "--appearance":
                guard let a = Appearance(rawValue: try value(argument)) else {
                    throw ArgumentError(description: "--appearance expects light, dark or both")
                }
                appearance = a
            case "--route": route = try value(argument)
            case "--period": period = try value(argument)
            case "--today":
                guard let day = Day(iso: try value(argument)) else { throw ArgumentError(description: "--today expects YYYY-MM-DD") }
                today = day
            case "--locale": locale = try value(argument)
            case "--inspector": showInspector = true
            case "--query": query = try value(argument)
            case "--red-gains": redGains = true
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
        guard !out.isEmpty else { throw ArgumentError(description: "--out is required") }
        if out == "-", target == "all" || appearance == .both {
            throw ArgumentError(description: "--out - (standard output) needs a single target and appearance")
        }
        let known = AppScreen.allCases.map(\.rawValue) + Self.shellTargets + ["all"]
        guard known.contains(target) else {
            throw ArgumentError(description: "unknown screenshot target “\(target)”")
        }
        if let route, Route(string: route) == nil { throw ArgumentError(description: "cannot parse --route \(route)") }
        if let period, Self.parsePeriod(period) == nil { throw ArgumentError(description: "cannot parse --period \(period)") }
    }

    static func parsePeriod(_ text: String) -> ReportingPeriod? {
        switch text.uppercased() {
        case "1M": .trailingMonths(1)
        case "3M": .trailingMonths(3)
        case "6M": .trailingMonths(6)
        case "YTD": .yearToDate
        case "MTD": .monthToDate
        case "QTD": .quarterToDate
        case "1Y": .trailingMonths(12)
        case "3Y": .trailingMonths(36)
        case "5Y": .trailingMonths(60)
        case "10Y": .trailingMonths(120)
        case "ALL": .allTime
        default: Int(text).flatMap { (1900...2200).contains($0) ? .calendarYear($0) : nil }
        }
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
        if options.redGains { UserDefaults.standard.set(GainStyle.redUp.rawValue, forKey: AppPreferences.Key.gainStyle) }
        defer { if options.redGains { UserDefaults.standard.removeObject(forKey: AppPreferences.Key.gainStyle) } }

        let today = options.today ?? .today
        let file = try loadFile(options, today: today)
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

    private static func loadFile(_ options: ScreenshotOptions, today: Day) throws -> PortfolioFile {
        if options.open == "-" {
            do {
                return try PortfolioFile(data: FileHandle.standardInput.readDataToEndOfFile())
            } catch {
                throw Failure(description: "cannot read a portfolio from standard input: \(error)")
            }
        }
        if let path = options.open {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            do {
                return try PortfolioFile(data: Data(contentsOf: url))
            } catch {
                throw Failure(description: "cannot open \(url.path): \(error)")
            }
        }
        if options.demo { return DemoPortfolio.make(today: today) }
        return PortfolioFile(name: "Untitled", settings: Settings(baseCurrency: AppPreferences.defaultCurrency))
    }

    private static func shoot(
        target: String, appearance: ScreenshotOptions.Appearance, file: PortfolioFile, today: Day, options: ScreenshotOptions
    ) async throws -> NSBitmapImageRep {
        let registry = ShellContext.shared.registry
        let store = PortfolioStore(file: file, today: today)
        ShellContext.shared.installServices(on: store)
        if let period = options.period.flatMap(ScreenshotOptions.parsePeriod) { store.period = period }
        store.isInspectorPresented = options.showInspector

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
            case "portfolio-settings": capturesSheet = true
            case "consistency": capturesSheet = true
            default: break
            }
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
        if let screen = NSScreen.main {
            // Keep the whole window on a display so the window server composites all of it.
            let visible = screen.visibleFrame
            window.setFrameOrigin(CGPoint(x: visible.minX + 20, y: max(visible.minY, visible.maxY - window.frame.height - 20)))
        }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        defer { window.close() }
        await activateForCapture()

        // Let SwiftUI build the hierarchy and install the toolbar, then trigger target-specific state.
        try await Task.sleep(for: .milliseconds(250))
        switch target {
        case "portfolio-settings": store.present(.portfolioSettings)
        case "consistency": store.present(.consistencyReport)
        default: break
        }

        await store.waitUntilSettled(quietPeriod: .milliseconds(200), timeout: .seconds(20))
        // Decorations that would otherwise keep the store "busy" are applied after settling.
        if let toast = options.toast { store.show(Toast(toast, style: .success, duration: 60)) }
        if let activity = options.activity {
            store.beginActivity(activity.title, total: activity.total)
            store.updateActivity(completed: activity.completed)
        }
        try await Task.sleep(for: .seconds(options.settleDelay + (capturesSheet ? 0.8 : 0)))
        window.displayIfNeeded()
        CATransaction.flush()

        let rep = try capture(window, scale: options.scale)
        if capturesSheet { store.dismissSheet() }
        return rep
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
        if let sheet = window.attachedSheet {
            image = WindowServerCapture.image(of: [sheet, window], bounds: window.frame)
        } else {
            image = WindowServerCapture.image(of: [window], bounds: window.frame)
        }
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
