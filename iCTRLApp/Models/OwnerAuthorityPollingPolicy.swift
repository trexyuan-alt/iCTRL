import Foundation

enum OwnerAuthorityPollingPolicy {
    static let transientInterval: TimeInterval = 2
    static let stableInterval: TimeInterval = 15
    static let transientWindow: TimeInterval = 20

    static func isStable(_ status: OwnerAuthorityStatus?) -> Bool {
        guard let status else { return false }

        return status.uiState != .unknown
    }

    static func nextInterval(
        now: Date,
        transientUntil: Date?,
        status: OwnerAuthorityStatus?,
        transitionActive: Bool
    ) -> TimeInterval {
        let transient = transitionActive || !isStable(status)
        if transient,
           let transientUntil,
           now < transientUntil {
            return transientInterval
        }
        return stableInterval
    }
}
