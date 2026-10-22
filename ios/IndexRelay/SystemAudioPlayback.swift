import Foundation
@preconcurrency import AVFoundation

/// Owns playback-only audio resources off the main actor. BLE receiving does not use these.
actor SystemAudioPlayback: PlaybackBackend {
    private var session: AVAudioSession?
    private var active = false
    private var player: AVAudioPlayer?
    enum PlaybackError: Error { case activationFailed, deactivationFailed, playbackFailed }

    func activate() async throws {
        guard !active else { return }
        let session = self.session ?? AVAudioSession.sharedInstance()
        self.session = session
        try session.setCategory(.playback, mode: .default)
        if #available(iOS 27.0, *) {
            guard try await session.activate(options: []) else { throw PlaybackError.activationFailed }
        } else {
            // iOS 26: synchronous API is confined to this background actor.
            try session.setActive(true)
        }
        active = true
    }

    func start(data: Data) throws {
        player = try AVAudioPlayer(data: data)
        guard player?.play() == true else { throw PlaybackError.playbackFailed }
    }

    func stop() async throws {
        player?.stop()
        player = nil
        // In particular, don't initialize/deactivate a session during BLE tests or log clearing.
        guard active, let session else { return }
        if #available(iOS 27.0, *) {
            guard try await session.deactivate(options: .notifyOthersOnDeactivation) else {
                throw PlaybackError.deactivationFailed
            }
        } else {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        }
        active = false
    }
}
