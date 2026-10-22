import Foundation

protocol PlaybackBackend: Actor {
    func activate() async throws
    func start(data: Data) throws
    func stop() async throws
}

/// Serializes complete activation/play/stop operations across suspension points.
/// Revisions prevent a late stop or activation from affecting a newer selection.
actor PlaybackCoordinator<Backend: PlaybackBackend> {
    private let backend: Backend
    private var tail: Task<Void, Never>?
    private(set) var latestRevision = -1

    init(backend: Backend) { self.backend = backend }

    func play(data: Data, revision: Int) async throws -> Bool {
        guard revision >= latestRevision else { return false }
        latestRevision = revision
        let previous = tail
        let work = Task { [self] in
            await previous?.value
            guard revision == latestRevision else { return false }
            try await backend.stop()
            guard revision == latestRevision else { return false }
            try await backend.activate()
            guard revision == latestRevision else {
                try await backend.stop()
                return false
            }
            do {
                try await backend.start(data: data)
                return true
            } catch {
                try? await backend.stop()
                throw error
            }
        }
        tail = Task { _ = try? await work.value }
        return try await work.value
    }

    func stop(revision: Int) async throws {
        guard revision >= latestRevision else { return }
        latestRevision = revision
        let previous = tail
        let work = Task { [self] in
            await previous?.value
            guard revision == latestRevision else { return }
            try await backend.stop()
        }
        tail = Task { _ = try? await work.value }
        try await work.value
    }
}
