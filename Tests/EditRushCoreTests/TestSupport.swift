import XCTest
import Foundation

/// Locates generated test media (run `Scripts/make_fixtures.sh` first).
enum Fixture {
    static let folder: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)

    /// URL of a fixture; skips the calling test if fixtures have not been generated.
    static func url(_ name: String) throws -> URL {
        let u = folder.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: u.path) else {
            throw XCTSkip("Fixture \(name) missing — run Scripts/make_fixtures.sh")
        }
        return u
    }
}
