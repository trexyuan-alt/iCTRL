import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError("FAIL: \(message)") }
}
let armed = OwnerAuthorityStatus(ownerArmed: true, authorityEpoch: 7, armedGeneration: 3,
    absoluteExpiresAt: "2027-01-01T00:00:00Z", controlState: "RUNNING", controlGeneration: 3)
expect(armed.uiState == .armed, "Owner permission needs no RSD fields")
var stopped = OwnerAuthorityStatus(ownerArmed: true, authorityEpoch: 7, armedGeneration: 3,
    absoluteExpiresAt: "2027-01-01T00:00:00Z", controlState: "STOPPED", controlGeneration: 4)
stopped.executionReady = false; stopped.serviceState = "OFF"
expect(stopped.uiState == .armed, "STOP/readiness/service facts do not revoke Owner permission")
let disarmed = OwnerAuthorityStatus(ownerArmed: false, authorityEpoch: 8, armedGeneration: 0,
    absoluteExpiresAt: "", controlState: "STOPPED", controlGeneration: 4)
expect(disarmed.uiState == .disarmed, "revisioned OFF maps to DISARMED")
let missingGeneration = OwnerAuthorityStatus(ownerArmed: true, authorityEpoch: 7, armedGeneration: 3,
    absoluteExpiresAt: "2027-01-01T00:00:00Z", controlState: "RUNNING", controlGeneration: 0)
expect(missingGeneration.uiState == .unknown, "missing generation maps UNKNOWN")
let mismatchedBinding = OwnerAuthorityStatus(ownerArmed: true, authorityEpoch: 7, armedGeneration: 2,
    absoluteExpiresAt: "2027-01-01T00:00:00Z", controlState: "RUNNING", controlGeneration: 3)
expect(mismatchedBinding.uiState == .unknown, "RUNNING binding must match Observation generation")
print("PASS revisioned Owner permission state mapping")
