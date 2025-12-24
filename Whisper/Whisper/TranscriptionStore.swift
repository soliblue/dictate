import Foundation

struct TranscriptionRecord: Equatable {
    let timestamp: String
    let text: String
}

final class TranscriptionStore {
    let directory: URL
    private let fileManager: FileManager

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dictate_transcripts", isDirectory: true),
         fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    func save(_ text: String, timestamp: Date = Date()) -> URL? {
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestampStr = formatter.string(from: timestamp)
        let path = directory.appendingPathComponent("\(timestampStr).txt")
        do {
            try text.write(to: path, atomically: true, encoding: .utf8)
            return path
        } catch {
            return nil
        }
    }

    func loadAll() -> [TranscriptionRecord] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        return files
            .filter { $0.pathExtension == "txt" }
            .sorted { a, b in
                let dateA = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
                let dateB = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
                return dateA > dateB
            }
            .compactMap { file -> TranscriptionRecord? in
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
                return TranscriptionRecord(timestamp: file.deletingPathExtension().lastPathComponent, text: text)
            }
    }

    func count() -> Int {
        guard fileManager.fileExists(atPath: directory.path) else { return 0 }
        return ((try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "txt" }.count) ?? 0
    }

    func delete(timestamp: String) -> Bool {
        let path = directory.appendingPathComponent("\(timestamp).txt")
        do {
            try fileManager.removeItem(at: path)
            return true
        } catch {
            return false
        }
    }
}
