import SwiftUI
import AVKit

/// Apple's player, showing one title from the media server. Reports progress back as it plays, and a last time when it closes.
struct NativePlayerView: UIViewControllerRepresentable {
    let session: PlaybackSession

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = context.coordinator.player
        context.coordinator.start()
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator: NSObject {
        let session: PlaybackSession
        let player: AVPlayer
        private var timeObserver: Any?
        private var statusObservation: NSKeyValueObservation?
        private var lastSeconds: Double
        private var stopped = false

        init(session: PlaybackSession) {
            self.session = session
            let item = AVPlayerItem(url: session.url)
            let title = AVMutableMetadataItem()
            title.identifier = .commonIdentifierTitle
            title.value = session.title as NSString
            title.extendedLanguageTag = "und"
            item.externalMetadata = [title]
            player = AVPlayer(playerItem: item)
            lastSeconds = session.startSeconds
        }

        func start() {
            if session.startSeconds > 0 {
                player.seek(to: CMTime(seconds: session.startSeconds, preferredTimescale: 600))
            }
            // Report every ten seconds while playing, and straight away when it pauses or resumes.
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 10, preferredTimescale: 1), queue: .main) { [weak self] time in
                MainActor.assumeIsolated { self?.send(.playing, at: time.seconds) }
            }
            statusObservation = player.observe(\.timeControlStatus) { [weak self] player, _ in
                MainActor.assumeIsolated {
                    switch player.timeControlStatus {
                    case .paused: self?.send(.paused, at: player.currentTime().seconds)
                    case .playing: self?.send(.playing, at: player.currentTime().seconds)
                    default: break
                    }
                }
            }
            player.play()
        }

        func stop() {
            guard !stopped else { return }
            stopped = true
            let seconds = player.currentTime().seconds
            player.pause()
            if let timeObserver { player.removeTimeObserver(timeObserver) }
            statusObservation = nil
            send(.stopped, at: seconds.isFinite ? seconds : lastSeconds, force: true)
        }

        private func send(_ state: PlaybackState, at seconds: Double, force: Bool = false) {
            guard !stopped || force, seconds.isFinite else { return }
            lastSeconds = seconds
            let reporter = session.reporter
            let duration = player.currentItem?.duration.seconds
            Task { await reporter.report(seconds: seconds, duration: duration?.isFinite == true ? duration : session.duration, state: state) }
        }
    }
}
