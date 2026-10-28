import Foundation

/// Where recorded voiceovers are written.
public enum VoiceoverFiles {
    public static let fileExtension = "m4a"

    /// A "Voiceovers" folder next to the project file, or ~/Movies/EditRush/Voiceovers for a project
    /// that hasn't been saved to a file yet.
    public static func folder(forProject projectURL: URL?) -> URL {
        if let projectURL {
            return projectURL.deletingLastPathComponent().appendingPathComponent("Voiceovers", isDirectory: true)
        }
        return defaultFolder
    }

    /// ~/Movies/EditRush/Voiceovers
    public static var defaultFolder: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EditRush", isDirectory: true)
            .appendingPathComponent("Voiceovers", isDirectory: true)
    }

    /// The first "Voiceover N.m4a" in `folder` that doesn't exist yet (N from 1).
    public static func nextURL(in folder: URL) -> URL {
        var n = 1
        while true {
            let url = folder.appendingPathComponent("Voiceover \(n).\(fileExtension)")
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            n += 1
        }
    }
}
