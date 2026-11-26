import Foundation

public protocol SnapshotStore: Sendable {
    func save(_ snapshot: RouteSnapshot) throws
    func load() throws -> RouteSnapshot?
}

/// Stores the latest snapshot as JSON so a relaunch can resume without the network.
public struct FileSnapshotStore: SnapshotStore {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static func defaultStore() throws -> FileSnapshotStore {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return FileSnapshotStore(url: directory.appendingPathComponent("route-snapshot.json"))
    }

    public func save(_ snapshot: RouteSnapshot) throws {
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }

    public func load() throws -> RouteSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(RouteSnapshot.self, from: Data(contentsOf: url))
    }
}
