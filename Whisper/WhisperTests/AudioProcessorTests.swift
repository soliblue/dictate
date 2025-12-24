import XCTest
@testable import Whisper

final class AudioProcessorTests: XCTestCase {

    func testResampleSameRate() {
        let samples: [Float] = [1.0, 2.0, 3.0, 4.0]
        let result = AudioProcessor.resampleTo16kHz(samples: samples, fromRate: 16000)
        XCTAssertEqual(result, samples)
    }

    func testResampleFromHigherRate() {
        let samples: [Float] = [0.0, 1.0, 0.0, 1.0]
        let result = AudioProcessor.resampleTo16kHz(samples: samples, fromRate: 32000)
        XCTAssertEqual(result.count, 2)
    }

    func testResampleFromLowerRate() {
        let samples: [Float] = [0.0, 1.0]
        let result = AudioProcessor.resampleTo16kHz(samples: samples, fromRate: 8000)
        XCTAssertEqual(result.count, 4)
    }

    func testResampleEmpty() {
        let result = AudioProcessor.resampleTo16kHz(samples: [], fromRate: 44100)
        XCTAssertTrue(result.isEmpty)
    }

    func testResampleInterpolation() {
        let samples: [Float] = [0.0, 1.0]
        let result = AudioProcessor.resampleTo16kHz(samples: samples, fromRate: 8000)
        XCTAssertEqual(result[0], 0.0, accuracy: 0.01)
        XCTAssertEqual(result[1], 0.25, accuracy: 0.01)
        XCTAssertEqual(result[2], 0.5, accuracy: 0.01)
        XCTAssertEqual(result[3], 0.75, accuracy: 0.01)
    }

    func testDuration() {
        XCTAssertEqual(AudioProcessor.duration(sampleCount: 16000, sampleRate: 16000), 1.0)
        XCTAssertEqual(AudioProcessor.duration(sampleCount: 8000, sampleRate: 16000), 0.5)
        XCTAssertEqual(AudioProcessor.duration(sampleCount: 44100, sampleRate: 44100), 1.0)
    }

    func testDurationZeroRate() {
        XCTAssertEqual(AudioProcessor.duration(sampleCount: 1000, sampleRate: 0), 0)
    }
}
