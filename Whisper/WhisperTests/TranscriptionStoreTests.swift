import XCTest
@testable import Whisper

final class TranscriptionStoreTests: XCTestCase {
    var tempDir: URL!
    var store: TranscriptionStore!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = TranscriptionStore(directory: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testSaveCreatesFile() {
        let path = store.save("Hello world")
        XCTAssertNotNil(path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path!.path))
    }

    func testSaveContent() {
        let text = "Test transcription content"
        let path = store.save(text)!
        let saved = try! String(contentsOf: path, encoding: .utf8)
        XCTAssertEqual(saved, text)
    }

    func testCount() {
        XCTAssertEqual(store.count(), 0)
        _ = store.save("One")
        XCTAssertEqual(store.count(), 1)
        _ = store.save("Two")
        XCTAssertEqual(store.count(), 2)
    }

    func testLoadAll() {
        _ = store.save("First")
        _ = store.save("Second")
        let records = store.loadAll()
        XCTAssertEqual(records.count, 2)
        let texts = records.map { $0.text }
        XCTAssertTrue(texts.contains("First"))
        XCTAssertTrue(texts.contains("Second"))
    }

    func testLoadAllSortedByDate() {
        _ = store.save("Old", timestamp: Date(timeIntervalSinceNow: -100))
        _ = store.save("New", timestamp: Date())
        let records = store.loadAll()
        XCTAssertEqual(records.first?.text, "New")
        XCTAssertEqual(records.last?.text, "Old")
    }

    func testLoadAllEmpty() {
        let records = store.loadAll()
        XCTAssertTrue(records.isEmpty)
    }

    func testCountEmptyDirectory() {
        let emptyStore = TranscriptionStore(directory: tempDir.appendingPathComponent("nonexistent"))
        XCTAssertEqual(emptyStore.count(), 0)
    }

    func testDeleteExisting() {
        _ = store.save("To delete", timestamp: Date())
        let records = store.loadAll()
        XCTAssertEqual(records.count, 1)
        let deleted = store.delete(timestamp: records[0].timestamp)
        XCTAssertTrue(deleted)
        XCTAssertEqual(store.count(), 0)
    }

    func testDeleteNonexistent() {
        let deleted = store.delete(timestamp: "nonexistent")
        XCTAssertFalse(deleted)
    }

    func testTranscriptionRecordEquatable() {
        let a = TranscriptionRecord(timestamp: "2024-01-01", text: "Hello")
        let b = TranscriptionRecord(timestamp: "2024-01-01", text: "Hello")
        let c = TranscriptionRecord(timestamp: "2024-01-02", text: "Hello")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
