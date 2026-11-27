import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError("FAIL: \(message)") }
}
let now = Date(timeIntervalSince1970: 1_000)
let fast = now.addingTimeInterval(OwnerAuthorityPollingPolicy.transientWindow)
let expired = now.addingTimeInterval(-1)
let armed = OwnerAuthorityStatus(ownerArmed: true, authorityEpoch: 1, armedGeneration: 3,
    absoluteExpiresAt: "", controlState: "RUNNING", controlGeneration: 3)
let disarmed = OwnerAuthorityStatus(ownerArmed: false, authorityEpoch: 2, armedGeneration: 0,
    absoluteExpiresAt: "", controlState: "STOPPED", controlGeneration: 4)
var unavailableRSD = armed
unavailableRSD.executionReady = false
unavailableRSD.serviceState = "OFF"
expect(OwnerAuthorityPollingPolicy.isStable(armed), "ARMED without readiness/service fields is stable")
expect(OwnerAuthorityPollingPolicy.isStable(disarmed), "DISARMED is stable")
expect(OwnerAuthorityPollingPolicy.isStable(unavailableRSD), "RSD loss cannot rewrite permission or start tight polling")
expect(!OwnerAuthorityPollingPolicy.isStable(nil), "UNKNOWN is transient")
for status in [armed, disarmed, unavailableRSD] {
    expect(OwnerAuthorityPollingPolicy.nextInterval(now: now, transientUntil: fast, status: status, transitionActive: false) == 15, "stable permission polls at 15 seconds")
    expect(OwnerAuthorityPollingPolicy.nextInterval(now: now, transientUntil: fast, status: status, transitionActive: true) == 2, "explicit transition gets bounded fast polling")
}
expect(OwnerAuthorityPollingPolicy.nextInterval(now: now, transientUntil: fast, status: nil, transitionActive: false) == 2, "UNKNOWN fast window")
expect(OwnerAuthorityPollingPolicy.nextInterval(now: now, transientUntil: expired, status: nil, transitionActive: false) == 15, "failed status backs off")
expect(OwnerAuthorityPollingPolicy.nextInterval(now: now, transientUntil: expired, status: armed, transitionActive: true) == 15, "transition window remains bounded")
print("PASS adaptive revisioned Owner status polling; readiness/service remain optional")
