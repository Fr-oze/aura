import Foundation
import Accelerate

/// FFT réelle de 1024 points (fenêtre de Hann). Utilisé sur une seule file.
final class SpectrumAnalyzer {
    static let size = 1024
    static let log2Size: vDSP_Length = 10

    private let setup: FFTSetup
    private var window = [Float](repeating: 0, count: SpectrumAnalyzer.size)
    private var windowed = [Float](repeating: 0, count: SpectrumAnalyzer.size)
    private var real = [Float](repeating: 0, count: SpectrumAnalyzer.size / 2)
    private var imaginary = [Float](repeating: 0, count: SpectrumAnalyzer.size / 2)

    /// Amplitudes des 512 premières bandes après le dernier `process`.
    private(set) var magnitudes = [Float](repeating: 0, count: SpectrumAnalyzer.size / 2)

    init() {
        guard let created = vDSP_create_fftsetup(SpectrumAnalyzer.log2Size, FFTRadix(kFFTRadix2)) else {
            fatalError("Création de la FFT impossible")
        }
        setup = created
        vDSP_hann_window(&window, vDSP_Length(SpectrumAnalyzer.size), Int32(vDSP_HANN_NORM))
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    /// `samples` doit contenir au moins 1024 échantillons mono.
    func process(_ samples: UnsafePointer<Float>) {
        let size = SpectrumAnalyzer.size
        let half = size / 2
        let setup = self.setup
        let window = self.window
        var windowed = self.windowed
        var real = self.real
        var imaginary = self.imaginary
        var output = self.magnitudes

        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(size))

        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                guard let realBase = realPointer.baseAddress, let imaginaryBase = imaginaryPointer.baseAddress else { return }
                var split = DSPSplitComplex(realp: realBase, imagp: imaginaryBase)

                windowed.withUnsafeBufferPointer { windowedPointer in
                    guard let base = windowedPointer.baseAddress else { return }
                    base.withMemoryRebound(to: DSPComplex.self, capacity: half) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(half))
                    }
                }

                vDSP_fft_zrip(setup, &split, 1, SpectrumAnalyzer.log2Size, FFTDirection(FFT_FORWARD))

                output.withUnsafeMutableBufferPointer { outputPointer in
                    guard let outputBase = outputPointer.baseAddress else { return }
                    vDSP_zvabs(&split, 1, outputBase, 1, vDSP_Length(half))
                }
            }
        }

        // Mise à l'échelle : zrip renvoie des valeurs doublées, non normalisées.
        var scale = 1.0 / Float(size)
        var scaled = [Float](repeating: 0, count: half)
        vDSP_vsmul(output, 1, &scale, &scaled, 1, vDSP_Length(half))

        self.windowed = windowed
        self.real = real
        self.imaginary = imaginary
        self.magnitudes = scaled
    }
}

/// Détection de battement par flux spectral avec seuil adaptatif.
final class BeatDetector {
    private var previous = [Float](repeating: 0, count: 128)
    private var history = [Float](repeating: 0, count: 60)
    private var writeIndex = 0
    private var filled = 0
    private var cooldown = 0

    /// Renvoie vrai quand la trame porte une attaque nette par rapport aux dernières ~0,6 s.
    func feed(_ magnitudes: [Float]) -> Bool {
        let count = min(previous.count, magnitudes.count)
        var flux: Float = 0
        for index in 0..<count {
            let rise = magnitudes[index] - previous[index]
            if rise > 0 { flux += rise }
            previous[index] = magnitudes[index]
        }

        var mean: Float = 0
        var variance: Float = 0
        if filled > 0 {
            for index in 0..<filled { mean += history[index] }
            mean /= Float(filled)
            for index in 0..<filled {
                let delta = history[index] - mean
                variance += delta * delta
            }
            variance /= Float(filled)
        }
        let deviation = variance.squareRoot()

        history[writeIndex] = flux
        writeIndex = (writeIndex + 1) % history.count
        filled = min(filled + 1, history.count)

        if cooldown > 0 {
            cooldown -= 1
            return false
        }
        let threshold = mean * 1.35 + deviation * 1.6 + 0.0008
        if filled > 20 && flux > threshold {
            cooldown = 14 // ~150 ms à 94 trames par seconde
            return true
        }
        return false
    }

    func reset() {
        for index in previous.indices { previous[index] = 0 }
        for index in history.indices { history[index] = 0 }
        writeIndex = 0
        filled = 0
        cooldown = 0
    }
}
