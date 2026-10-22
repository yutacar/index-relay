import Foundation

actor FakePlayback: PlaybackBackend {
    struct Snapshot: Sendable { let activations: Int; let deactivations: Int; let starts: [Data]; let active: Bool }
    enum FakeError: Error { case startFailed }
    private let holdFirst: Bool
    private let failStart: Bool
    private var activations = 0
    private var deactivations = 0
    private var starts: [Data] = []
    private var active = false
    private var gate: CheckedContinuation<Void, Never>?
    private var entered = false
    private var observers: [CheckedContinuation<Void, Never>] = []
    init(holdFirst: Bool = false, failStart: Bool = false) { self.holdFirst = holdFirst; self.failStart = failStart }
    func activate() async throws {
        activations += 1
        if holdFirst && activations == 1 {
            await withCheckedContinuation { continuation in
                gate = continuation
                entered = true
                observers.forEach { $0.resume() }
                observers = []
            }
        }
        active = true
    }
    func start(data: Data) throws {
        if failStart { throw FakeError.startFailed }
        starts.append(data)
    }
    func stop() async throws {
        guard active else { return }
        deactivations += 1
        active = false
    }
    func waitForActivation() async {
        if entered { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func release() { gate?.resume(); gate = nil }
    func snapshot() -> Snapshot { Snapshot(activations: activations, deactivations: deactivations, starts: starts, active: active) }
}
var checks = 0
@MainActor
func expect(_ condition: Bool, _ message: String) {
    checks += 1
    precondition(condition, message)
}
@MainActor
func waitRevision<B: PlaybackBackend>(_ coordinator: PlaybackCoordinator<B>, _ revision: Int) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(3))
    while await coordinator.latestRevision < revision && clock.now < deadline { await Task.yield() }
    expect(await coordinator.latestRevision >= revision, "Command was submitted")
}
let idleBackend = FakePlayback()
let idle = PlaybackCoordinator(backend: idleBackend)
try await idle.stop(revision: 0)
let idleState = await idleBackend.snapshot()
expect(idleState.activations == 0 && idleState.deactivations == 0, "Stopping unused playback doesn't touch audio session")

let cancelledBackend = FakePlayback(holdFirst: true)
let cancelled = PlaybackCoordinator(backend: cancelledBackend)
let first = Task { try await cancelled.play(data: Data([1]), revision: 1) }
await cancelledBackend.waitForActivation()
let stop = Task { try await cancelled.stop(revision: 2) }
await waitRevision(cancelled, 2)
await cancelledBackend.release()
expect(try await first.value == false, "Stop during activation prevents stale audio from playing")
try await stop.value
let cancelledState = await cancelledBackend.snapshot()
expect(cancelledState.starts.isEmpty && !cancelledState.active, "Cancelled activation is deactivated")
expect(cancelledState.deactivations == 1, "Cancelled activation deactivated exactly once")

let switchedBackend = FakePlayback(holdFirst: true)
let switched = PlaybackCoordinator(backend: switchedBackend)
let older = Task { try await switched.play(data: Data([1]), revision: 1) }
await switchedBackend.waitForActivation()
let newer = Task { try await switched.play(data: Data([2]), revision: 3) }
await waitRevision(switched, 3)
await switchedBackend.release()
expect(try await older.value == false, "Superseded activation skipped")
expect(try await newer.value == true, "New selection plays")
let switchedState = await switchedBackend.snapshot()
expect(switchedState.starts == [Data([2])], "Only the latest selection is played")
try await switched.stop(revision: 2)
let afterOldStop = await switchedBackend.snapshot()
expect(afterOldStop.active, "Late old stop cannot silence new playback")
try await switched.stop(revision: 4)
try await switched.stop(revision: 4)
let stopped = await switchedBackend.snapshot()
expect(!stopped.active && stopped.deactivations == 2, "Repeated stop doesn't duplicate deactivation")

let failingBackend = FakePlayback(failStart: true)
let failing = PlaybackCoordinator(backend: failingBackend)
do {
    _ = try await failing.play(data: Data([1]), revision: 1)
    fatalError("Start failure swallowed")
} catch { checks += 1 }
let failed = await failingBackend.snapshot()
expect(!failed.active && failed.deactivations == 1, "Failed player creation cleans up active session")
print("PlaybackCoordinator: \(checks) checks passed")
