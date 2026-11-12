import Foundation
import BackgroundTasks

/// User-started bounded background runtime for the ZERO-XCTEST Companion.
///
/// This is intentionally NOT a forever-daemon and does not own phone-control
/// authority. It keeps the normal Companion process eligible to run while a
/// clearly bounded Remote Control session is active. The existing Gateway P0
/// authority probe remains authoritative: if this task expires, the process is
/// suspended, or :8200 becomes unreachable, control still fails closed.
final class BackgroundControlSession: ObservableObject {
    enum State: Equatable {
        case unsupported
        case idle
        case submitted
        case running
        case completed
        case expired
        case failed(String)
    }

    enum EndReason {
        case completed
        case expired
        case ownerStopped
    }

    @Published private(set) var state: State = .idle

    /// Called only when the background session ends without the local Stop
    /// button already owning cleanup. AppState uses this to close :8200 so
    /// authority is revoked immediately instead of waiting for suspension.
    var onForcedEnd: (() -> Void)?

    private let durationSeconds: Int64 = 30 * 60
    private let workerQueue = DispatchQueue(label: "com.openminis.ictrl.background-control", qos: .utility)
    private var activeRun: AnyObject?
    private var registered = false

    private var taskIdentifier: String {
        let bundle = Bundle.main.bundleIdentifier ?? "com.openminis.ictrl"
        return bundle + ".remote-control-session"
    }

    init() {
        if #available(iOS 26.0, *) {
            registerHandler()
        } else {
            state = .unsupported
        }
    }

    var isActive: Bool {
        switch state {
        case .submitted, .running:
            return true
        default:
            return false
        }
    }

    /// Must be called only as a direct result of an Owner action in foreground.
    ///
    /// BGContinuedProcessingTask is deliberately a bounded user-visible task,
    /// not an automatic startup mechanism.
    @discardableResult
    func start() -> Bool {
        guard #available(iOS 26.0, *) else {
            publish(.unsupported)
            return false
        }
        guard !isActive else { return true }
        guard registered else {
            publish(.failed("Background task registration failed"))
            return false
        }

        let request = BGContinuedProcessingTaskRequest(
            identifier: taskIdentifier,
            title: "iCTRL Remote Control",
            subtitle: "30-minute ZERO-XCTEST control session"
        )
        // Remote control is useful only if background runtime starts now.
        // Never queue a stale control session for later execution.
        request.strategy = .fail

        do {
            try BGTaskScheduler.shared.submit(request)
            publish(.submitted)
            return true
        } catch {
            publish(.failed(error.localizedDescription))
            return false
        }
    }

    /// Local/OOB Owner stop. AppState closes :8200 separately.
    func stopOwnerInitiated() {
        if #available(iOS 26.0, *) {
            if let run = activeRun as? ContinuedRun {
                run.requestStop(.ownerStopped)
            }
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
        }
        activeRun = nil
        if case .unsupported = state { return }
        publish(.idle)
    }

    @available(iOS 26.0, *)
    private func registerHandler() {
        // Static identifier is permitted by Info.plist. Register exactly once
        // per process; a second registration for the same identifier is fatal.
        registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: workerQueue
        ) { [weak self] rawTask in
            guard let task = rawTask as? BGContinuedProcessingTask else {
                rawTask.setTaskCompleted(success: false)
                return
            }
            self?.begin(task)
        }

        if !registered {
            publish(.failed("Background task identifier is not permitted"))
        }
    }

    @available(iOS 26.0, *)
    private func begin(_ task: BGContinuedProcessingTask) {
        let run = ContinuedRun(task: task)
        activeRun = run
        publish(.running)

        task.progress.totalUnitCount = durationSeconds
        task.progress.completedUnitCount = 0

        task.expirationHandler = { [weak run] in
            run?.requestStop(.expired)
        }

        workerQueue.async { [weak self, weak run] in
            guard let self, let run else {
                task.setTaskCompleted(success: false)
                return
            }

            let started = Date()
            var reason: EndReason = .completed

            while true {
                if let requested = run.stopReason {
                    reason = requested
                    break
                }
                if task.progress.isCancelled {
                    reason = .expired
                    break
                }

                let elapsed = Int64(Date().timeIntervalSince(started))
                task.progress.completedUnitCount = min(self.durationSeconds, max(0, elapsed))

                if elapsed >= self.durationSeconds {
                    reason = .completed
                    break
                }

                // Update the visible system activity occasionally without
                // turning a heartbeat into UI churn.
                if elapsed > 0 && elapsed % 60 == 0 {
                    let remaining = max(0, (self.durationSeconds - elapsed) / 60)
                    task.updateTitle(
                        "iCTRL Remote Control",
                        subtitle: "\(remaining) minutes remaining"
                    )
                }

                Thread.sleep(forTimeInterval: 1.0)
            }

            task.progress.completedUnitCount = min(
                self.durationSeconds,
                Int64(Date().timeIntervalSince(started))
            )
            task.setTaskCompleted(success: reason == .completed)

            DispatchQueue.main.async { [weak self] in
                self?.finish(run: run, reason: reason)
            }
        }
    }

    @available(iOS 26.0, *)
    private func finish(run: ContinuedRun, reason: EndReason) {
        guard let current = activeRun as? ContinuedRun, current === run else { return }
        activeRun = nil

        switch reason {
        case .ownerStopped:
            state = .idle
        case .completed:
            state = .completed
            onForcedEnd?()
        case .expired:
            state = .expired
            onForcedEnd?()
        }
    }

    private func publish(_ newState: State) {
        if Thread.isMainThread {
            state = newState
        } else {
            DispatchQueue.main.async { [weak self] in self?.state = newState }
        }
    }
}

@available(iOS 26.0, *)
private final class ContinuedRun {
    private let lock = NSLock()
    private var reason: BackgroundControlSession.EndReason?

    let task: BGContinuedProcessingTask

    init(task: BGContinuedProcessingTask) {
        self.task = task
    }

    var stopReason: BackgroundControlSession.EndReason? {
        lock.lock()
        defer { lock.unlock() }
        return reason
    }

    func requestStop(_ newReason: BackgroundControlSession.EndReason) {
        lock.lock()
        if reason == nil { reason = newReason }
        lock.unlock()
    }
}
