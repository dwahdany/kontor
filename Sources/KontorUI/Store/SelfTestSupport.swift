import Foundation

/// A failed step of the app's self-test (`Kontor --selftest`). Features throw it from the hooks
/// they expose for that mode (`<Feature>SelfTest`); the shell reports the message and goes on.
public struct SelfTestFailure: Error, CustomStringConvertible, Sendable {
    public var description: String

    public init(_ description: String) {
        self.description = description
    }
}
