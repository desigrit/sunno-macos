import Foundation

/// One profile location for both the child environment and its ownership record.
enum BackendProfile {
    static func directory(environment: [String: String] = ProcessInfo.processInfo.environment,
                          home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let override = environment["Sunno_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        }
        return home.appendingPathComponent("Library/Application Support/Sunno", isDirectory: true)
    }
}
