import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreAudio
import CoreGraphics
import QuartzCore
import Accelerate
import Combine

/// Niveaux audio prêts à afficher, tous entre 0 et 1.
struct AudioLevels {
    static let barCount = 12

    var level: Float = 0
    var bass: Float = 0
    var mid: Float = 0
    var high: Float = 0
    /// Augmente de 1 à chaque battement détecté.
    var beatCount = 0
    var bars = [Float](repeating: 0, count: AudioLevels.barCount)
}

enum AudioState: Equatable {
    case stopped
    case starting
    case running
    case needsPermission
    case failed(String)
}

/// Capture le son du système (ScreenCaptureKit) et en tire des niveaux par bande.
/// `start`, `stop` et `state` s'utilisent sur le thread principal ; l'analyse tourne sur sa propre file.
final class AudioEngine: NSObject, ObservableObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    @Published private(set) var state: AudioState = .stopped

    private let queue = DispatchQueue(label: "com.maxlab.aura.audio", qos: .userInitiated)
    private let lock = NSLock()
    private var levels = AudioLevels()   // protégé par lock
    private var demoUntil: CFTimeInterval = 0 // protégé par lock

    private var stream: SCStream?        // thread principal
    private var wanted = false           // thread principal

    // File audio uniquement
    private let analyzer = SpectrumAnalyzer()
    private let beatDetector = BeatDetector()
    private var pending: [Float] = []
    private var beatCount = 0
    private var peakLevel: Float = 0.02
    private var peakBass: Float = 0.004
    private var peakMid: Float = 0.004
    private var peakHigh: Float = 0.004
    private var peakBars: Float = 0.004
    private static let barEdges: [Int] = [1, 2, 3, 5, 7, 10, 15, 22, 33, 50, 75, 112, 170]

    // MARK: Autorisation

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Affiche la demande système la première fois ; ensuite il faut passer par Réglages Système.
    static func requestPermission() {
        _ = CGRequestScreenCaptureAccess()
    }

    // MARK: Démarrage / arrêt (thread principal)

    func start() {
        guard !wanted else { return }
        guard AudioEngine.hasPermission else {
            if state != .needsPermission {
                state = .needsPermission
            }
            return
        }
        wanted = true
        state = .starting
        Task { [weak self] in
            await self?.begin()
        }
    }

    func stop() {
        guard wanted || stream != nil || state != .stopped else { return }
        wanted = false
        if let stream {
            stream.stopCapture { _ in }
        }
        stream = nil
        state = .stopped
        clearLevels()
    }

    /// Niveaux simulés pendant quelques secondes : pour régler le halo sans musique.
    func demo(seconds: Double) {
        lock.lock()
        demoUntil = CACurrentMediaTime() + seconds
        lock.unlock()
    }

    /// Dernier état des niveaux. Peut être lu depuis n'importe quel thread.
    func snapshot() -> AudioLevels {
        let now = CACurrentMediaTime()
        lock.lock()
        defer { lock.unlock() }
        if now < demoUntil {
            return AudioEngine.demoLevels(at: now)
        }
        return levels
    }

    private func begin() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else {
                throw NSError(domain: "Aura", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Aucun écran disponible pour la capture."])
            }
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 48_000
            configuration.channelCount = 2
            // La vidéo est obligatoire : on la réduit au strict minimum.
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            configuration.queueDepth = 3
            configuration.showsCursor = false

            let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await newStream.startCapture()

            await MainActor.run {
                if self.wanted {
                    self.stream = newStream
                    self.state = .running
                } else {
                    newStream.stopCapture { _ in }
                }
            }
        } catch {
            let message = error.localizedDescription
            await MainActor.run {
                self.wanted = false
                self.stream = nil
                self.state = AudioEngine.hasPermission ? .failed(message) : .needsPermission
            }
        }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            self.stream = nil
            self.wanted = false
            self.state = .failed(message)
            self.clearLevels()
        }
    }

    // MARK: SCStreamOutput (file audio)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }
        process(sampleBuffer)
    }

    private func process(_ sampleBuffer: CMSampleBuffer) {
        guard let description = sampleBuffer.formatDescription?.audioStreamBasicDescription,
              description.mFormatID == kAudioFormatLinearPCM,
              (description.mFormatFlags & kAudioFormatFlagIsFloat) != 0,
              description.mBitsPerChannel == 32
        else { return }

        let frames = sampleBuffer.numSamples
        var mono = [Float](repeating: 0, count: frames)
        var channelCount = 0

        do {
            try sampleBuffer.withAudioBufferList { bufferList, _ in
                for buffer in bufferList {
                    guard let raw = buffer.mData else { continue }
                    let channels = max(1, Int(buffer.mNumberChannels))
                    let total = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                    let count = min(frames, total / channels)
                    let samples = raw.assumingMemoryBound(to: Float.self)
                    for channel in 0..<channels {
                        var index = 0
                        while index < count {
                            mono[index] += samples[index * channels + channel]
                            index += 1
                        }
                        channelCount += 1
                    }
                }
            }
        } catch {
            return
        }
        guard channelCount > 0 else { return }

        let gain = 1 / Float(channelCount)
        var energy: Float = 0
        for index in 0..<frames {
            let value = mono[index] * gain
            mono[index] = value
            energy += value * value
        }
        let rms = (energy / Float(frames)).squareRoot()

        if rms < 0.0005 {
            // Silence : rien à analyser.
            pending.removeAll(keepingCapacity: true)
            beatDetector.reset()
            lock.lock()
            let beats = levels.beatCount
            levels = AudioLevels()
            levels.beatCount = beats
            lock.unlock()
            return
        }

        pending.append(contentsOf: mono)
        let size = SpectrumAnalyzer.size
        while pending.count >= size {
            pending.withUnsafeBufferPointer { pointer in
                if let base = pointer.baseAddress {
                    analyzer.process(base)
                }
            }
            publish(rms: rms)
            pending.removeFirst(size / 2)
        }
    }

    /// Transforme le spectre courant en niveaux normalisés par rapport aux crêtes récentes.
    private func publish(rms: Float) {
        let magnitudes = analyzer.magnitudes

        // À 48 kHz, une bande ≈ 47 Hz : graves 47–234 Hz, médiums 280–2000 Hz, aigus 2–8 kHz.
        let bass = AudioEngine.mean(magnitudes, 1, 5)
        let mid = AudioEngine.mean(magnitudes, 6, 42)
        let high = AudioEngine.mean(magnitudes, 43, 170)

        peakLevel = max(peakLevel * 0.9995, rms, 0.02)
        peakBass = max(peakBass * 0.999, bass, 0.004)
        peakMid = max(peakMid * 0.999, mid, 0.002)
        peakHigh = max(peakHigh * 0.999, high, 0.0008)

        var bars = [Float](repeating: 0, count: AudioLevels.barCount)
        var loudest: Float = 0
        for index in 0..<AudioLevels.barCount {
            let value = AudioEngine.mean(magnitudes, AudioEngine.barEdges[index], AudioEngine.barEdges[index + 1] - 1)
            // Les aigus portent moins d'énergie : on les relève un peu.
            let tilted = value * (1 + Float(index) * 0.35)
            bars[index] = tilted
            loudest = max(loudest, tilted)
        }
        peakBars = max(peakBars * 0.999, loudest, 0.004)
        for index in 0..<AudioLevels.barCount {
            bars[index] = AudioEngine.shape(bars[index] / peakBars)
        }

        if beatDetector.feed(magnitudes) {
            beatCount += 1
        }

        lock.lock()
        levels.level = AudioEngine.shape(rms / peakLevel)
        levels.bass = AudioEngine.shape(bass / peakBass)
        levels.mid = AudioEngine.shape(mid / peakMid)
        levels.high = AudioEngine.shape(high / peakHigh)
        levels.beatCount = beatCount
        levels.bars = bars
        lock.unlock()
    }

    private func clearLevels() {
        lock.lock()
        let beats = levels.beatCount
        levels = AudioLevels()
        levels.beatCount = beats
        lock.unlock()
    }

    private static func mean(_ values: [Float], _ from: Int, _ through: Int) -> Float {
        let lower = max(0, from)
        let upper = min(values.count - 1, through)
        guard upper >= lower else { return 0 }
        var sum: Float = 0
        for index in lower...upper {
            sum += values[index]
        }
        return sum / Float(upper - lower + 1)
    }

    /// Borne entre 0 et 1 avec une légère compression (les niveaux moyens restent visibles).
    private static func shape(_ value: Float) -> Float {
        let clamped = min(max(value, 0), 1)
        return powf(clamped, 0.8)
    }

    private static func demoLevels(at time: CFTimeInterval) -> AudioLevels {
        var result = AudioLevels()
        let beatLength = 0.5
        let phase = time.truncatingRemainder(dividingBy: beatLength) / beatLength
        result.bass = Float(exp(-phase * 5))
        result.mid = Float(0.5 + 0.3 * sin(time * 2.1))
        result.high = Float(0.4 + 0.3 * sin(time * 3.7))
        result.level = 0.7
        result.beatCount = Int(time / beatLength)
        for index in 0..<AudioLevels.barCount {
            let wave = 0.5 + 0.45 * sin(time * (2 + Double(index) * 0.6) + Double(index))
            result.bars[index] = Float(wave) * (index < 3 ? result.bass * 0.5 + 0.5 : 1)
        }
        return result
    }
}
