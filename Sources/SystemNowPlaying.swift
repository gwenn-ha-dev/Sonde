import MediaPlayer
import AppKit

/// Publishes the amp's playback to macOS "Now Playing" (Control Center, the media-key
/// overlay) and routes the hardware media keys / Control Center buttons back to the amp.
@MainActor
final class SystemNowPlaying {
    var onPlay: (() -> Void)?
    var onPause: (() -> Void)?
    var onToggle: (() -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?

    private var title = ""
    private var artist = ""
    private var isPlaying = false
    private var artworkURL: URL?
    private var artworkImage: NSImage?

    init() {
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.addTarget { [weak self] _ in self?.onPlay?(); return .success }
        cc.pauseCommand.addTarget { [weak self] _ in self?.onPause?(); return .success }
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in self?.onToggle?(); return .success }
        cc.nextTrackCommand.addTarget { [weak self] _ in self?.onNext?(); return .success }
        cc.previousTrackCommand.addTarget { [weak self] _ in self?.onPrevious?(); return .success }

        for cmd in [cc.playCommand, cc.pauseCommand, cc.togglePlayPauseCommand,
                    cc.nextTrackCommand, cc.previousTrackCommand] {
            cmd.isEnabled = true
        }
        // We don't expose scrubbing/seeking for live radio.
        for cmd in [cc.changePlaybackPositionCommand, cc.seekForwardCommand,
                    cc.seekBackwardCommand, cc.skipForwardCommand, cc.skipBackwardCommand] {
            cmd.isEnabled = false
        }
    }

    func update(title: String, artist: String, artworkURL: URL?, isPlaying: Bool) {
        self.title = title
        self.artist = artist
        self.isPlaying = isPlaying
        if artworkURL != self.artworkURL {
            self.artworkURL = artworkURL
            self.artworkImage = nil
            fetchArtwork(artworkURL)
        }
        apply()
    }

    private func apply() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let img = artworkImage {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
        }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
    }

    private func fetchArtwork(_ url: URL?) {
        guard let url else { return }
        Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let img = NSImage(data: data) else { return }
            guard let self, self.artworkURL == url else { return }
            self.artworkImage = img
            self.apply()
        }
    }
}
