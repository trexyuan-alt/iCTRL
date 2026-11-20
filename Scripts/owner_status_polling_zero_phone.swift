import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

let now = Date(timeIntervalSince1970: 1_000)
let fast = now.addingTimeInterval(OwnerAuthorityPollingPolicy.transientWindow)
let expired = now.addingTimeInterval(-1)
let epoch = "0123456789abcdef0123456789abcdef"

let armedReady = OwnerAuthorityStatus(
    ownerArmed: true, executionReady: true, serviceState: "ON",
    controlState: "RUNNING", controlGeneration: 3, controlEpoch: epoch
)
let disarmedOn = OwnerAuthorityStatus(
    ownerArmed: false, executionReady: false, serviceState: "ON",
    controlState: "STOPPED", controlGeneration: 4, controlEpoch: epoch
)
let serviceOff = OwnerAuthorityStatus(
    ownerArmed: false, executionReady: false, serviceState: "OFF",
    controlState: "STOPPED", controlGeneration: 5, controlEpoch: epoch
)
let armedNotReady = OwnerAuthorityStatus(
    ownerArmed: true, executionReady: false, serviceState: "ON",
    controlState: "STOPPED", controlGeneration: 6, controlEpoch: epoch
)

expect(OwnerAuthorityPollingPolicy.isStable(armedReady), "ARMED+READY must be stable")
expect(OwnerAuthorityPollingPolicy.isStable(disarmedOn), "ON+DISARMED must be stable")
expect(OwnerAuthorityPollingPolicy.isStable(serviceOff), "OFF must be stable")
expect(!OwnerAuthorityPollingPolicy.isStable(armedNotReady), "ARMED+NOT READY must be transient")
expect(!OwnerAuthorityPollingPolicy.isStable(nil), "UNKNOWN must be transient")

expect(
    OwnerAuthorityPollingPolicy.nextInterval(now: now, transientUntil: nil, status: armedReady, transitionActive: false) == 15,
    "stable ARMED interval must be 15s"
)
expect(
    OwnerAuthorityPollingPolicy.nextInterval(now: now, transientUntil: nil, status: disarmedOn, transitionActive: false) == 15,
    "stable DISARMED interval must be 15s"
)
expect(
    OwnerAuthorityPollingPolicy.nextInterval(now: now, transientUntil: nil, status: serviceOff, transitionActive: false) == 15,
    "stable OFF interval must be 15s"
)
expect(
    OwnerAuthorityPollingPolicy.nextInterval(now: now, transientUntil: fast, status: nil, transitionActive: false) == 2,
    "UNKNOWN inside bounded window must poll at 2s"
)
expect(
    OwnerAuthorityPollingPolicy.nextInterval(now: now, transientUntil: fast, status: armedNotReady, transitionActive: false) == 2,
    "ARMED+NOT READY inside bounded window must poll at 2s"
)
expect(
    OwnerAuthorityPollingPolicy.nextInterval(now: now, transientUntil: fast, status: armedReady, transitionActive: true) == 2,
    "explicit transition inside bounded window must poll at 2s"
)
expect(
    OwnerAuthorityPollingPolicy.nextInterval(now: now, transientUntil: expired, status: nil, transitionActive: false) == 15,
    "failed UNKNOWN polling must back off after bounded window"
)
expect(
    OwnerAuthorityPollingPolicy.nextInterval(now: now, transientUntil: expired, status: armedReady, transitionActive: true) == 15,
    "transition polling must not remain permanently tight after bound"
)

print("PASS adaptive Owner status polling policy")
