import Foundation

/// Persisted preferences in `~/Library/Application Support/CampusEntry/entry.json`.
public final class EntrySettings: Codable {
    public var prefix: String?
    public var saveAccount: Bool
    public var saveDecided: Bool
    public var hideNotices: Bool

    public var left: Double?
    public var top: Double?
    public var width: Double?
    public var height: Double?
    public var maximized: Bool

    /// Non-persisted directory override for isolated host/unit tests.
    public var dataDirectory: URL?

    public static var defaultDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport.appendingPathComponent("CampusEntry", isDirectory: true)
    }

    private var resolvedDirectory: URL {
        dataDirectory ?? Self.defaultDirectory
    }

    public var fileURL: URL {
        resolvedDirectory.appendingPathComponent("entry.json", isDirectory: false)
    }

    enum CodingKeys: String, CodingKey {
        case prefix
        case saveAccount
        case saveDecided
        case hideNotices
        case left
        case top
        case width
        case height
        case maximized
    }

    public init(
        prefix: String? = nil,
        saveAccount: Bool = true,
        saveDecided: Bool = false,
        hideNotices: Bool = true,
        left: Double? = nil,
        top: Double? = nil,
        width: Double? = nil,
        height: Double? = nil,
        maximized: Bool = false,
        dataDirectory: URL? = nil
    ) {
        self.prefix = prefix
        self.saveAccount = saveAccount
        self.saveDecided = saveDecided
        self.hideNotices = hideNotices
        self.left = left
        self.top = top
        self.width = width
        self.height = height
        self.maximized = maximized
        self.dataDirectory = dataDirectory
    }

    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.prefix = try container.decodeIfPresent(String.self, forKey: .prefix)
        self.saveAccount = try container.decodeIfPresent(Bool.self, forKey: .saveAccount) ?? true
        self.saveDecided = try container.decodeIfPresent(Bool.self, forKey: .saveDecided) ?? false
        self.hideNotices = try container.decodeIfPresent(Bool.self, forKey: .hideNotices) ?? true
        self.left = try container.decodeIfPresent(Double.self, forKey: .left)
        self.top = try container.decodeIfPresent(Double.self, forKey: .top)
        self.width = try container.decodeIfPresent(Double.self, forKey: .width)
        self.height = try container.decodeIfPresent(Double.self, forKey: .height)
        self.maximized = try container.decodeIfPresent(Bool.self, forKey: .maximized) ?? false
        self.dataDirectory = nil
    }

    /// Loads settings from `directory/entry.json`, falling back to defaults on missing or corrupt files.
    public static func load(from directory: URL = EntrySettings.defaultDirectory) -> EntrySettings {
        let path = directory.appendingPathComponent("entry.json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: path.path) else {
            return EntrySettings(dataDirectory: directory)
        }
        do {
            let data = try Data(contentsOf: path)
            let settings = try JSONDecoder().decode(EntrySettings.self, from: data)
            settings.dataDirectory = directory
            return settings
        } catch {
            return EntrySettings(dataDirectory: directory)
        }
    }

    /// Atomically writes settings to `entry.json`. Never throws; returns `true` on success.
    @discardableResult
    public func save() -> Bool {
        do {
            let fm = FileManager.default
            if !fm.fileExists(atPath: resolvedDirectory.path) {
                try fm.createDirectory(at: resolvedDirectory, withIntermediateDirectories: true)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(self)
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
