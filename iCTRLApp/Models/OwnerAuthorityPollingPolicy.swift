import Foundation

enum OwnerAuthorityPollingPolicy {
    static let transientInterval: TimeInterval = 2
    static let stableInterval: TimeInterval = 15
    static let transientWindow: TimeInterval = 20

    static func isStable(_ status: OwnerAuthorityStatus?) -> Bool {
        guard let status else { return false }

        if status.serviceState == "OFF" {
            return !status.ownerArmed &&
                !status.executionReady &&
                status.controlState == "STOPPED"
        }

        guard status.serviceState == "ON" else { return false }

        if !status.ownerArmed {
            return !status.executionReady && status.controlState == "STOPPED"
        }

        return status.executionReady && status.controlState == "RUNNING"
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
