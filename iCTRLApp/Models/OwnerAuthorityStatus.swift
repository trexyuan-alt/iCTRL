import Foundation

enum OwnerAuthorityUIState: Equatable {
    case unknown
    case disarmed
    case armed
}

struct OwnerAuthorityStatus: Equatable {
    let ownerArmed: Bool
    let controlState: String
    let controlGeneration: UInt64
    let controlEpoch: String

    var uiState: OwnerAuthorityUIState {
        guard controlGeneration > 0, !controlEpoch.isEmpty else { return .unknown }
        if ownerArmed && controlState == "RUNNING" { return .armed }
        if controlState == "STOPPED" || !ownerArmed { return .disarmed }
        return .unknown
    }
}
