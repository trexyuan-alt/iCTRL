import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

let running = OwnerAuthorityStatus(
    ownerArmed: true,
    controlState: "RUNNING",
    controlGeneration: 3,
    controlEpoch: "0123456789abcdef0123456789abcdef"
)
expect(running.uiState == .armed, "RUNNING authoritative state must map to ARMED")

let stopped = OwnerAuthorityStatus(
    ownerArmed: false,
    controlState: "STOPPED",
    controlGeneration: 4,
    controlEpoch: "0123456789abcdef0123456789abcdef"
)
expect(stopped.uiState == .disarmed, "STOPPED authoritative state must map to DISARMED")

let revokedAgainstStaleLocal = OwnerAuthorityStatus(
    ownerArmed: false,
    controlState: "STOPPED",
    controlGeneration: 4,
    controlEpoch: "0123456789abcdef0123456789abcdef"
)
expect(revokedAgainstStaleLocal.uiState == .disarmed, "backend revoke must override stale local ARMED")

let inconsistent = OwnerAuthorityStatus(
    ownerArmed: true,
    controlState: "UNKNOWN",
    controlGeneration: 3,
    controlEpoch: "0123456789abcdef0123456789abcdef"
)
expect(inconsistent.uiState == .unknown, "invalid authoritative state must map to UNKNOWN")

let invalidGeneration = OwnerAuthorityStatus(
    ownerArmed: true,
    controlState: "RUNNING",
    controlGeneration: 0,
    controlEpoch: "0123456789abcdef0123456789abcdef"
)
expect(invalidGeneration.uiState == .unknown, "missing generation must map to UNKNOWN")

print("PASS owner authority state mapping")
