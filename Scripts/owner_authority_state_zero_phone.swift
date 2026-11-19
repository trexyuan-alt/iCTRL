import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

let running = OwnerAuthorityStatus(
    ownerArmed: true,
    executionReady: true,
    serviceState: "ON",
    controlState: "RUNNING",
    controlGeneration: 3,
    controlEpoch: "0123456789abcdef0123456789abcdef"
)
expect(running.uiState == .armed, "ready Owner authority must map to ARMED")

let armedNotReady = OwnerAuthorityStatus(
    ownerArmed: true,
    executionReady: false,
    serviceState: "ON",
    controlState: "STOPPED",
    controlGeneration: 4,
    controlEpoch: "0123456789abcdef0123456789abcdef"
)
expect(armedNotReady.uiState == .armed, "readiness loss must not hide durable Owner permission")

let disarmedServiceOn = OwnerAuthorityStatus(
    ownerArmed: false,
    executionReady: false,
    serviceState: "ON",
    controlState: "STOPPED",
    controlGeneration: 4,
    controlEpoch: "0123456789abcdef0123456789abcdef"
)
expect(disarmedServiceOn.uiState == .disarmed, "service ON without Owner permission must be DISARMED")

let serviceOff = OwnerAuthorityStatus(
    ownerArmed: false,
    executionReady: false,
    serviceState: "OFF",
    controlState: "STOPPED",
    controlGeneration: 5,
    controlEpoch: "0123456789abcdef0123456789abcdef"
)
expect(serviceOff.uiState == .disarmed, "service OFF must be DISARMED")

let invalidServiceAuthority = OwnerAuthorityStatus(
    ownerArmed: true,
    executionReady: false,
    serviceState: "OFF",
    controlState: "STOPPED",
    controlGeneration: 5,
    controlEpoch: "0123456789abcdef0123456789abcdef"
)
expect(invalidServiceAuthority.uiState == .unknown, "service OFF cannot retain Owner permission")

let invalidReadyState = OwnerAuthorityStatus(
    ownerArmed: true,
    executionReady: true,
    serviceState: "ON",
    controlState: "STOPPED",
    controlGeneration: 5,
    controlEpoch: "0123456789abcdef0123456789abcdef"
)
expect(invalidReadyState.uiState == .unknown, "execution ready requires RUNNING control")

let invalidGeneration = OwnerAuthorityStatus(
    ownerArmed: true,
    executionReady: true,
    serviceState: "ON",
    controlState: "RUNNING",
    controlGeneration: 0,
    controlEpoch: "0123456789abcdef0123456789abcdef"
)
expect(invalidGeneration.uiState == .unknown, "missing generation must map to UNKNOWN")

print("PASS owner authority/readiness/service state mapping")
