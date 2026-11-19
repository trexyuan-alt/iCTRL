import Foundation

enum OwnerAuthorityUIState: Equatable {
    case unknown
    case disarmed
    case armed
}

struct OwnerAuthorityStatus: Equatable {
    let ownerArmed: Bool
    let executionReady: Bool
    let serviceState: String
    let controlState: String
    let controlGeneration: UInt64
    let controlEpoch: String

    var uiState: OwnerAuthorityUIState {
        guard controlGeneration > 0,
              !controlEpoch.isEmpty,
              serviceState == "ON" || serviceState == "OFF",
              controlState == "RUNNING" || controlState == "STOPPED" else {
            return .unknown
        }
        if serviceState == "OFF" &&
            (ownerArmed || executionReady || controlState != "STOPPED") { return .unknown }
        if executionReady &&
            (!ownerArmed || serviceState != "ON" || controlState != "RUNNING") { return .unknown }
        return ownerArmed ? .armed : .disarmed
    }
}
