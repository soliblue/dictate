import Foundation

enum AudioProcessor {
    static func resampleTo16kHz(samples: [Float], fromRate: Double) -> [Float] {
        guard fromRate != 16000 else { return samples }
        let ratio = 16000.0 / fromRate
        let newCount = Int(Double(samples.count) * ratio)
        guard newCount > 0, !samples.isEmpty else { return [] }
        return (0..<newCount).map { i in
            let srcIndex = Double(i) / ratio
            let lower = Int(srcIndex)
            let upper = min(lower + 1, samples.count - 1)
            let fraction = Float(srcIndex - Double(lower))
            return samples[lower] * (1 - fraction) + samples[upper] * fraction
        }
    }

    static func duration(sampleCount: Int, sampleRate: Double) -> Double {
        guard sampleRate > 0 else { return 0 }
        return Double(sampleCount) / sampleRate
    }
}
