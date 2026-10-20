import Foundation
import HermesKit
import HermesPush
import MediaPlayer
import NowPlaying
import Observation
import SwiftUI

/// Listen on the Lock Screen and in Control Center (`docs/voice.md` §3): the chat's title, the Bot,
/// its face, Back and Ahead 15 s, Play/Pause and the speed. On 27 the NowPlaying framework
/// watches the player; on 26 `MPNowPlayingInfoCenter` is told whenever what's shown changes.
@MainActor
final class NowPlayingPublisher {
    private var session: AnyObject?
    private var watcher: Task<Void, Never>?
    private var targets: [(MPRemoteCommand, Any)] = []

    init(player: ListenPlayer) {
        if #available(iOS 27, macOS 27, *) {
            session = MediaSession(ListenMediaModel(player: player))
        } else {
            publishLegacy(player)
        }
    }

    func end() {
        session = nil
        watcher?.cancel()
        watcher = nil
        for (command, target) in targets { command.removeTarget(target) }
        targets = []
        if #unavailable(iOS 27, macOS 27) {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            #if os(macOS)
            MPNowPlayingInfoCenter.default().playbackState = .stopped
            #endif
        }
    }

    // MARK: 26: MediaPlayer

    private func publishLegacy(_ player: ListenPlayer) {
        let center = MPRemoteCommandCenter.shared()
        func on(_ command: MPRemoteCommand, _ action: @escaping @MainActor (MPRemoteCommandEvent) -> Void) {
            let target = command.addTarget { event in
                MainActor.assumeIsolated { action(event) }
                return .success
            }
            targets.append((command, target))
        }
        on(center.playCommand) { [weak player] _ in player?.resume() }
        on(center.pauseCommand) { [weak player] _ in player?.pause() }
        on(center.togglePlayPauseCommand) { [weak player] _ in player?.togglePause() }
        on(center.stopCommand) { [weak player] _ in player?.stop() }
        center.skipBackwardCommand.preferredIntervals = [15]
        on(center.skipBackwardCommand) { [weak player] event in
            player?.back(by: (event as? MPSkipIntervalCommandEvent)?.interval ?? 15)
        }
        center.skipForwardCommand.preferredIntervals = [15]
        on(center.skipForwardCommand) { [weak player] event in
            player?.forward(by: (event as? MPSkipIntervalCommandEvent)?.interval ?? 15)
        }
        center.changePlaybackRateCommand.supportedPlaybackRates = [1, 1.5, 2]
        on(center.changePlaybackRateCommand) { [weak player] event in
            if let rate = (event as? MPChangePlaybackRateCommandEvent)?.playbackRate { player?.rate = Double(rate) }
        }
        let artwork = Self.legacyArtwork(player.reading?.context.appearance)
        watcher = Task { [weak player] in
            guard let player else { return }
            let changes = Observations { (player.reading?.id, player.isPaused, player.timeline.elapsed, player.rate) }
            for await _ in changes {
                guard let reading = player.reading else { return }
                var info: [String: Any] = [
                    MPMediaItemPropertyTitle: reading.context.title,
                    MPMediaItemPropertyArtist: reading.context.speaker,
                    MPMediaItemPropertyPlaybackDuration: player.estimatedDuration,
                    MPNowPlayingInfoPropertyElapsedPlaybackTime: player.timeline.elapsed,
                    MPNowPlayingInfoPropertyPlaybackRate: player.isPaused ? 0 : player.rate,
                    MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
                    MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
                ]
                if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
                #if os(macOS)
                MPNowPlayingInfoCenter.default().playbackState = player.isPaused ? .paused : .playing
                #endif
            }
        }
    }

    private static func legacyArtwork(_ appearance: BotAppearance?) -> MPMediaItemArtwork? {
        guard let image = ListenArtwork.image(appearance, side: 600) else { return nil }
        #if os(iOS)
        let platform = UIImage(cgImage: image)
        #else
        let platform = NSImage(cgImage: image, size: NSSize(width: 600, height: 600))
        #endif
        return MPMediaItemArtwork(boundsSize: CGSize(width: 600, height: 600)) { _ in platform }
    }
}

/// What Listen shows in Now Playing on 27; the session watches it.
@available(iOS 27, macOS 27, *)
@MainActor
final class ListenMediaModel: MediaSessionRepresentable {
    private weak var player: ListenPlayer?
    nonisolated let id = "listen"

    init(player: ListenPlayer) {
        self.player = player
    }

    var content: (any MediaContentRepresentable)? {
        guard let player, let reading = player.reading else { return nil }
        let appearance = reading.context.appearance
        return GenericContent(
            id: reading.id,
            title: reading.context.title,
            subtitle: reading.context.speaker,
            type: .audio,
            duration: .finite(player.estimatedDuration),
            artwork: Artwork(id: "face-\(appearance.id)") { size in
                let image = await MainActor.run { ListenArtwork.image(appearance, side: max(size.width, size.height)) }
                guard let image else { throw CancellationError() }
                return try ArtworkRepresentation(cgImage: image)
            }
        )
    }

    var playbackSnapshot: MediaPlaybackSnapshot? {
        guard let player, player.reading != nil else { return nil }
        // The elapsed time as of the last change; the system runs it on from there.
        return MediaPlaybackSnapshot(
            state: player.isPaused ? .paused : player.isStarting ? .buffering : .playing(rate: Float(player.rate)),
            elapsedTime: player.timeline.elapsed,
            timestamp: player.timeline.date
        )
    }

    var commands: [MediaCommand] {
        [
            .play { [weak self] in self?.player?.resume() },
            .pause { [weak self] in self?.player?.pause() },
            .togglePlayPause { [weak self] in self?.player?.togglePause() },
            .stop { [weak self] in self?.player?.stop() },
            .skipBackward(preferredIntervals: [15]) { [weak self] interval in self?.player?.back(by: interval) },
            .skipForward(preferredIntervals: [15]) { [weak self] interval in self?.player?.forward(by: interval) },
            .changePlaybackRate(supported: [1, 1.5, 2]) { [weak self] rate in self?.player?.rate = Double(rate) },
        ]
    }
}

/// The Bot's face, still, as Now Playing artwork.
@MainActor
enum ListenArtwork {
    static func image(_ appearance: BotAppearance?, side: CGFloat) -> CGImage? {
        let side = min(max(side, 120), 1024)
        let look = (appearance ?? BotAppearance(profile: "hermes")).look
        let view = ZStack {
            Theme.surface
            StillFace(look: look, size: side * 0.62)
        }
        .frame(width: side, height: side)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return renderer.cgImage
    }
}
