import Foundation
import AppKit
import ImageIO
import Combine

/// Couleurs tirées de la pochette du morceau en cours.
@MainActor
final class HaloPalette: ObservableObject {
    @Published var first: RGB?
    @Published var second: RGB?
    @Published var track = ""
    /// Message à montrer dans les réglages (autorisation refusée, etc.).
    @Published var note = ""
}

/// Morceau en cours, pour l'encoche (ailes « musique » et carte de l'accueil).
@MainActor
final class MusicState: ObservableObject {
    /// Un morceau est chargé (en lecture ou en pause).
    @Published var hasTrack = false
    @Published var isPlaying = false
    @Published var title = ""
    @Published var artist = ""
    /// Pochette réduite (miniature), ou nil.
    @Published var artwork: NSImage?
    /// « Spotify » ou « Musique ».
    @Published var source = ""
    /// Identifiant du morceau affiché : une pochette qui arrive en retard n'écrase pas la suivante.
    var trackKey = ""
}

/// Sonde Spotify et Musique (seulement si l'app tourne) : titre, artiste, pochette, état de lecture.
/// Les deux apps préviennent à chaque changement (notifications distribuées), donc le sondage de
/// fond est lent. AppleScript s'exécute sur une file dédiée, jamais sur le thread principal.
final class NowPlaying: @unchecked Sendable {
    private static let spotifyID = "com.spotify.client"
    private static let musicID = "com.apple.Music"

    private static let spotifyInfo = """
    tell application id "com.spotify.client"
        if player state is playing then
            set s to "playing"
        else if player state is paused then
            set s to "paused"
        else
            return ""
        end if
        return s & linefeed & (id of current track) & linefeed & (artwork url of current track) & linefeed & (name of current track) & linefeed & (artist of current track)
    end tell
    """

    private static let musicInfo = """
    tell application id "com.apple.Music"
        if player state is playing then
            set s to "playing"
        else if player state is paused then
            set s to "paused"
        else
            return ""
        end if
        return s & linefeed & (persistent ID of current track) & linefeed & (name of current track) & linefeed & (artist of current track)
    end tell
    """

    private static let musicArtwork = """
    tell application id "com.apple.Music"
        return data of artwork 1 of current track
    end tell
    """

    private static let musicRawArtwork = """
    tell application id "com.apple.Music"
        return raw data of artwork 1 of current track
    end tell
    """

    private struct Track {
        var player: String
        var playing: Bool
        var id: String
        var title: String
        var artist: String
        var artworkURL: String

        var key: String { player + ":" + id }
    }

    private let palette: HaloPalette
    private let music: MusicState
    private let queue = DispatchQueue(label: "com.maxlab.aura.nowplaying", qos: .utility)
    private var timer: DispatchSourceTimer?        // thread principal
    private var observers: [NSObjectProtocol] = [] // thread principal
    private var scripts: [String: NSAppleScript] = [:] // file dédiée
    private var lastKey = ""                        // file dédiée
    private var lastState = ""                      // file dédiée
    private var lastPlayer = ""                     // file dédiée

    init(palette: HaloPalette, music: MusicState) {
        self.palette = palette
        self.music = music
    }

    /// Thread principal.
    func start() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 0.3, repeating: 4.0, leeway: .milliseconds(500))
        source.setEventHandler { [weak self] in
            self?.poll()
        }
        source.resume()
        timer = source

        // Spotify et Musique annoncent chaque changement de lecture : mise à jour immédiate.
        let center = DistributedNotificationCenter.default()
        for name in ["com.spotify.client.PlaybackStateChanged", "com.apple.Music.playerInfo"] {
            let token = center.addObserver(forName: Notification.Name(name), object: nil, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.queue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    self?.poll()
                }
            }
            observers.append(token)
        }
    }

    /// Thread principal.
    func stop() {
        guard timer != nil else { return }
        timer?.cancel()
        timer = nil
        let center = DistributedNotificationCenter.default()
        for token in observers {
            center.removeObserver(token)
        }
        observers = []
        queue.async { [weak self] in
            self?.lastKey = ""
            self?.lastState = ""
            self?.lastPlayer = ""
        }
        let music = self.music
        Task { @MainActor in
            music.hasTrack = false
            music.isPlaying = false
            music.trackKey = ""
            music.artwork = nil
        }
    }

    /// Lecture / pause, suivant, précédent, envoyés à l'app qui joue. Thread principal.
    func send(_ command: MusicCommand) {
        queue.async { [weak self] in
            guard let self else { return }
            let player = self.lastPlayer
            guard !player.isEmpty else { return }
            let bundleID = player == "spotify" ? NowPlaying.spotifyID : NowPlaying.musicID
            guard NowPlaying.isRunning(bundleID) else { return }
            let verb: String
            switch command {
            case .toggle: verb = "playpause"
            case .next: verb = "next track"
            case .previous: verb = "previous track"
            }
            _ = self.run("tell application id \"\(bundleID)\" to \(verb)")
            self.queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.poll()
            }
        }
    }

    // MARK: Sondage (file dédiée)

    private func poll() {
        var chosen: Track?

        if NowPlaying.isRunning(NowPlaying.spotifyID),
           let info = run(NowPlaying.spotifyInfo)?.stringValue, !info.isEmpty {
            let parts = info.components(separatedBy: "\n")
            if parts.count >= 5 {
                chosen = Track(player: "spotify", playing: parts[0] == "playing", id: parts[1],
                               title: parts[3], artist: parts[4], artworkURL: parts[2].trimmed)
            }
        }

        // Musique passe devant seulement si Spotify ne joue pas.
        if chosen?.playing != true,
           NowPlaying.isRunning(NowPlaying.musicID),
           let info = run(NowPlaying.musicInfo)?.stringValue, !info.isEmpty {
            let parts = info.components(separatedBy: "\n")
            if parts.count >= 4 {
                let track = Track(player: "music", playing: parts[0] == "playing", id: parts[1],
                                  title: parts[2], artist: parts[3], artworkURL: "")
                if track.playing || chosen == nil {
                    chosen = track
                }
            }
        }

        guard let track = chosen else {
            if !lastState.isEmpty {
                lastState = ""
                lastKey = ""
                lastPlayer = ""
                publishStopped()
            }
            return
        }

        lastPlayer = track.player
        let state = "\(track.key):\(track.playing)"
        if state != lastState {
            lastState = state
            publishState(track)
        }

        guard track.key != lastKey else { return }
        lastKey = track.key
        if track.player == "spotify" {
            loadSpotifyArtwork(track.artworkURL, track: track)
        } else {
            var image = run(NowPlaying.musicArtwork).flatMap { NowPlaying.decode($0.data) }
            if image == nil {
                image = run(NowPlaying.musicRawArtwork).flatMap { NowPlaying.decode($0.data) }
            }
            publish(image: image, track: track)
        }
    }

    private static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    private func run(_ source: String) -> NSAppleEventDescriptor? {
        let script: NSAppleScript
        if let cached = scripts[source] {
            script = cached
        } else {
            guard let created = NSAppleScript(source: source) else { return nil }
            scripts[source] = created
            script = created
        }

        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
            if code == -1743 {
                setNote("Autorise Aura à contrôler Spotify / Musique : Réglages Système > Confidentialité et sécurité > Automatisation.")
            }
            return nil
        }
        return result
    }

    private func loadSpotifyArtwork(_ address: String, track: Track) {
        guard let url = URL(string: address), url.scheme == "https" || url.scheme == "http" else {
            publish(image: nil, track: track)
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            let image = data.flatMap { NowPlaying.decode($0) }
            self?.publish(image: image, track: track)
        }.resume()
    }

    private static func decode(_ data: Data) -> CGImage? {
        guard !data.isEmpty, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Miniature carrée de 192 px : la pochette d'origine (parfois plusieurs mégapixels) n'est pas gardée.
    private static func thumbnail(of image: CGImage) -> NSImage? {
        let side = 192
        guard image.width > 0, image.height > 0,
              let context = CGContext(data: nil,
                                      width: side,
                                      height: side,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let scale = max(CGFloat(side) / CGFloat(image.width), CGFloat(side) / CGFloat(image.height))
        let drawn = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: (CGFloat(side) - drawn.width) / 2,
                                       y: (CGFloat(side) - drawn.height) / 2,
                                       width: drawn.width,
                                       height: drawn.height))
        guard let output = context.makeImage() else { return nil }
        return NSImage(cgImage: output, size: NSSize(width: 96, height: 96))
    }

    private func publishState(_ track: Track) {
        let music = self.music
        let key = track.key
        let title = track.title
        let artist = track.artist
        let playing = track.playing
        let source = track.player == "spotify" ? "Spotify" : "Musique"
        Task { @MainActor in
            if music.trackKey != key {
                music.trackKey = key
                music.artwork = nil
            }
            if music.title != title { music.title = title }
            if music.artist != artist { music.artist = artist }
            if music.source != source { music.source = source }
            if !music.hasTrack { music.hasTrack = true }
            if music.isPlaying != playing { music.isPlaying = playing }
        }
    }

    private func publishStopped() {
        let music = self.music
        Task { @MainActor in
            if music.isPlaying { music.isPlaying = false }
            if music.hasTrack { music.hasTrack = false }
            music.trackKey = ""
        }
    }

    private func publish(image: CGImage?, track: Track) {
        let pair = image.flatMap { ColorExtractor.dominantPair(from: $0) }
        let thumbnail = image.flatMap { NowPlaying.thumbnail(of: $0) }
        let palette = self.palette
        let music = self.music
        let key = track.key
        let name = track.title
        Task { @MainActor in
            palette.track = name
            palette.note = ""
            palette.first = pair?.0
            palette.second = pair?.1
            if music.trackKey == key || music.trackKey.isEmpty {
                music.trackKey = key
                music.artwork = thumbnail
            }
        }
    }

    private func setNote(_ text: String) {
        let palette = self.palette
        Task { @MainActor in
            if palette.note != text {
                palette.note = text
            }
        }
    }
}
