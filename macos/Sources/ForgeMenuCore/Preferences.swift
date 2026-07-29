import Foundation

public final class AppPreferences: @unchecked Sendable {
    public static let launchAtLoginKey = "launchAtLogin"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var launchAtLogin: Bool {
        get { defaults.bool(forKey: Self.launchAtLoginKey) }
        set { defaults.set(newValue, forKey: Self.launchAtLoginKey) }
    }
}

public struct RestartBackoff: Equatable, Sendable {
    public let baseDelay: TimeInterval
    public let maximumDelay: TimeInterval
    public let stableRunThreshold: TimeInterval

    public init(
        baseDelay: TimeInterval = 1,
        maximumDelay: TimeInterval = 60,
        stableRunThreshold: TimeInterval = 120
    ) {
        self.baseDelay = baseDelay
        self.maximumDelay = maximumDelay
        self.stableRunThreshold = stableRunThreshold
    }

    public func delay(forAttempt attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return 0 }
        let exponent = min(attempt - 1, 20)
        return min(maximumDelay, baseDelay * pow(2, Double(exponent)))
    }

    public func nextAttempt(previousAttempt: Int, runtime: TimeInterval) -> Int {
        runtime >= stableRunThreshold ? 1 : previousAttempt + 1
    }
}
