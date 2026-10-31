import Foundation

struct LocalNote: Identifiable, Codable {
    let id: UUID
    let text: String
    let date: Date
}

struct NoteStore {
    private var file: URL {
        get throws {
            let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true)
                .appendingPathComponent("JarvisPhone", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder.appendingPathComponent("notes.json")
        }
    }

    func load() throws -> [LocalNote] {
        let target = try file
        guard FileManager.default.fileExists(atPath: target.path) else { return [] }
        return try JSONDecoder().decode([LocalNote].self, from: Data(contentsOf: target))
    }

    func save(_ notes: [LocalNote]) throws {
        let data = try JSONEncoder().encode(notes)
        try data.write(to: file, options: [.atomic, .completeFileProtection])
    }
}
