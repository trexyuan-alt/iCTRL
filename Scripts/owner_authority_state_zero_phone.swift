import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError("FAIL: \(message)") }
}
let armed = OwnerAuthorityStatus(ownerArmed: true, authorityEpoch: 7, armedGeneration: 3,
    absoluteExpiresAt: "", controlState: "RUNNING", controlGeneration: 3)
expect(armed.uiState == .armed, "Owner permission needs no RSD fields")
var stopped = OwnerAuthorityStatus(ownerArmed: true, authorityEpoch: 7, armedGeneration: 3,
    absoluteExpiresAt: "", controlState: "STOPPED", controlGeneration: 4)
stopped.executionReady = false; stopped.serviceState = "OFF"
expect(stopped.uiState == .armed, "STOP/readiness/service facts do not revoke Owner permission")
let disarmed = OwnerAuthorityStatus(ownerArmed: false, authorityEpoch: 8, armedGeneration: 0,
    absoluteExpiresAt: "", controlState: "STOPPED", controlGeneration: 4)
expect(disarmed.uiState == .disarmed, "revisioned OFF maps to DISARMED")
let missingGeneration = OwnerAuthorityStatus(ownerArmed: true, authorityEpoch: 7, armedGeneration: 3,
    absoluteExpiresAt: "", controlState: "RUNNING", controlGeneration: 0)
expect(missingGeneration.uiState == .unknown, "missing generation maps UNKNOWN")
let mismatchedBinding = OwnerAuthorityStatus(ownerArmed: true, authorityEpoch: 7, armedGeneration: 2,
    absoluteExpiresAt: "", controlState: "RUNNING", controlGeneration: 3)
expect(mismatchedBinding.uiState == .unknown, "RUNNING binding must match Observation generation")
print("PASS revisioned Owner permission state mapping")

// Decode CURRENT wire snapshots, omitted compatibility fields, and legacy
// timestamps. Expiry must never change permission or bypass binding checks.
for expiry: String? in ["", nil, "2000-01-01T00:00:00Z", "2027-01-01T00:00:00Z"] {
    for isArmed in [true, false] {
        var wire: [String: Any] = [
            "ok": true, "owner_armed": isArmed, "authority_epoch": 7,
            "armed_generation": isArmed ? 3 : 0,
            "control_state": isArmed ? "RUNNING" : "STOPPED", "control_generation": 3,
        ]
        if let expiry { wire["absolute_expires_at"] = expiry }
        let status = try! JSONDecoder().decode(OwnerAuthorityStatus.self,
            from: JSONSerialization.data(withJSONObject: wire))
        expect(status.uiState == (isArmed ? .armed : .disarmed), "empty/missing/legacy expiry is authority-inert")
        expect(status.absoluteExpiresAt == expiry, "legacy compatibility value is preserved without synthesis")
        wire["armed_generation"] = isArmed ? 2 : 1
        let invalid = try! JSONDecoder().decode(OwnerAuthorityStatus.self,
            from: JSONSerialization.data(withJSONObject: wire))
        expect(invalid.uiState == .unknown, "inert expiry cannot bypass authoritative binding validation")
    }
}
print("PASS CURRENT empty/missing expiry and legacy past/future expiry classify identically; binding checks stay closed")
