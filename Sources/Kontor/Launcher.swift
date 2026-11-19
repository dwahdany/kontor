import AppKit
import SwiftUI
import KontorModel
import KontorSampleData

/// Process entry point. Normal launches start the SwiftUI app; `--screenshot …` runs the headless
/// renderer instead (see `ScreenshotRunner`), `--write-demo <file>` saves the demo portfolio as a
/// `.kontor` file, `--help` prints the command line reference.
@main
enum Launcher {
    @MainActor
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--help") || arguments.contains("-h") {
            print(ScreenshotOptions.usage)
            return
        }
        if let index = arguments.firstIndex(of: "--write-demo") {
            guard index + 1 < arguments.count else {
                FileHandle.standardError.write(Data("kontor: --write-demo expects a file path\n".utf8))
                exit(64)
            }
            do {
                let url = URL(fileURLWithPath: (arguments[index + 1] as NSString).expandingTildeInPath)
                var today = Day.today
                if let index = arguments.firstIndex(of: "--today"), index + 1 < arguments.count, let day = Day(iso: arguments[index + 1]) {
                    today = day
                }
                try SampleData.demoPortfolio(today: today).encoded(pretty: arguments.contains("--pretty")).write(to: url, options: .atomic)
                print(url.path)
                return
            } catch {
                FileHandle.standardError.write(Data("kontor: cannot write demo portfolio: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        if arguments.contains("--list-ids") {
            do {
                print(try ScreenshotOptions(arguments: arguments, requiresOutput: false).listIDs())
                return
            } catch {
                FileHandle.standardError.write(Data("kontor: \(error)\n".utf8))
                exit(64)
            }
        }
        if arguments.contains("--screenshot") {
            do {
                let options = try ScreenshotOptions(arguments: arguments)
                ScreenshotRunner.run(options)
            } catch {
                FileHandle.standardError.write(Data("kontor: \(error)\n\n\(ScreenshotOptions.usage)\n".utf8))
                exit(64)
            }
        } else {
            KontorApp.main()
        }
    }
}
