import Foundation

enum OwnerAuthorityUIState: Equatable {
    case unknown
    case verifierUnavailable
    case disarmed
    case armed
}

struct OwnerAuthorityStatus: Decodable, Equatable {
    let ownerArmed: Bool
    let authorityEpoch: UInt64
    let armedGeneration: UInt64
    let absoluteExpiresAt: String
    let controlState: String
    let controlGeneration: UInt64
    // Separate optional observations; absence says nothing about permission.
    var executionReady: Bool? = nil
    var serviceState: String? = nil
    var controlEpoch: String? = nil

    enum CodingKeys: String, CodingKey {
        case ownerArmed = "owner_armed", authorityEpoch = "authority_epoch"
        case armedGeneration = "armed_generation", absoluteExpiresAt = "absolute_expires_at"
        case controlState = "control_state", controlGeneration = "control_generation"
        case executionReady = "execution_ready", serviceState = "service_state", controlEpoch = "control_epoch"
    }

    var uiState: OwnerAuthorityUIState {
        guard controlGeneration > 0,
              controlState == "RUNNING" || controlState == "STOPPED" else { return .unknown }
        if ownerArmed {
            guard authorityEpoch > 0, armedGeneration > 0,
                  armedGeneration <= controlGeneration,
                  controlState != "RUNNING" || armedGeneration == controlGeneration,
                  !absoluteExpiresAt.isEmpty else { return .unknown }
            return .armed
        }
        return armedGeneration == 0 && absoluteExpiresAt.isEmpty ? .disarmed : .unknown
    }
}
