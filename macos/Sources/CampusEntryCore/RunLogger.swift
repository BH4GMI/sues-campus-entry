import Foundation

/// Thread-safe file logger writing to `~/Library/Logs/CampusEntry/run.log` with 512 KB rotation.
public final class RunLogger: @unchecked Sendable {
    public static let shared = RunLogger()
    public static let maxFileSize: Int = 512 * 1024

    public static var defaultLogURL: URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        return library
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("CampusEntry", isDirectory: true)
            .appendingPathComponent("run.log", isDirectory: false)
    }

    public let logURL: URL
    private let maxBytes: Int
    private let lock = NSLock()
    private let formatter: ISO8601DateFormatter

    public init(logURL: URL = RunLogger.defaultLogURL, maxBytes: Int = RunLogger.maxFileSize) {
        self.logURL = logURL
        self.maxBytes = maxBytes
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        fmt.timeZone = TimeZone.current
        self.formatter = fmt
    }

    /// Appends a timestamped log line, rotating `run.log` to `run.log.1` when size exceeds `maxBytes`.
    public func log(_ message: String) {
        let timestamp = formatter.string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        lock.lock()
        defer { lock.unlock() }

        do {
            let fm = FileManager.default
            let dir = logURL.deletingLastPathComponent()
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }

            if fm.fileExists(atPath: logURL.path) {
                let attrs = try? fm.attributesOfItem(atPath: logURL.path)
                let currentSize = (attrs?[.size] as? NSNumber)?.intValue ?? 0
                if currentSize + data.count > maxBytes {
                    rotateIfNeeded(fileManager: fm)
                }
            }

            if !fm.fileExists(atPath: logURL.path) {
                try data.write(to: logURL, options: .atomic)
            } else {
                let handle = try FileHandle(forWritingTo: logURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            }
        } catch {
            // Logging failures must never interrupt the host flow.
        }
    }

    private func rotateIfNeeded(fileManager: FileManager) {
        let backupURL = logURL.appendingPathExtension("1")
        if fileManager.fileExists(atPath: backupURL.path) {
            try? fileManager.removeItem(at: backupURL)
        }
        try? fileManager.moveItem(at: logURL, to: backupURL)
    }
}
