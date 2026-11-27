import Foundation
import SQLite3
import NavigationCore

/// SQLite persistence for editable routes. ETA values are seconds from the route's
/// planned departure; usage rows preserve each actual route run.
final class RouteDatabase {
    static let shared = RouteDatabase()

    private var db: OpaquePointer?

    private init() {
        let url = try! FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
            .appendingPathComponent("routes.sqlite")
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { fatalError("Could not open route database") }
        sqlite3_busy_timeout(db, 5_000)
        execute("PRAGMA foreign_keys = ON")
        execute("""
        CREATE TABLE IF NOT EXISTS Route (
          ID TEXT PRIMARY KEY, Route_Number TEXT NOT NULL UNIQUE
            CHECK(length(Route_Number) BETWEEN 1 AND 10 AND Route_Number NOT GLOB '*[^0-9]*'),
          Route_Name TEXT NOT NULL DEFAULT '' CHECK(length(Route_Name) <= 100), Route_Colour TEXT NOT NULL DEFAULT '007AFF'
            CHECK(length(Route_Colour) = 6),
          Planned_Departure REAL
        );
        CREATE TABLE IF NOT EXISTS Waypoints (
          Waypoint_ID TEXT PRIMARY KEY, Route_ID TEXT NOT NULL REFERENCES Route(ID) ON DELETE CASCADE,
          Waypoint_Order INTEGER NOT NULL, Waypoint_Latitude REAL NOT NULL,
          Waypoint_Longitude REAL NOT NULL, Waypoint_Name TEXT NOT NULL DEFAULT '',
          UNIQUE(Route_ID, Waypoint_ID), UNIQUE(Route_ID, Waypoint_Order)
        );
        CREATE TABLE IF NOT EXISTS Leg (
          Route_ID TEXT NOT NULL REFERENCES Route(ID) ON DELETE CASCADE,
          Prev_Waypoint_ID TEXT NOT NULL, Next_Waypoint_ID TEXT NOT NULL,
          Leg_Duration REAL NOT NULL CHECK(Leg_Duration >= 0), ETA REAL NOT NULL,
          PRIMARY KEY(Route_ID, Prev_Waypoint_ID, Next_Waypoint_ID),
          FOREIGN KEY(Route_ID, Prev_Waypoint_ID) REFERENCES Waypoints(Route_ID, Waypoint_ID) ON DELETE CASCADE,
          FOREIGN KEY(Route_ID, Next_Waypoint_ID) REFERENCES Waypoints(Route_ID, Waypoint_ID) ON DELETE CASCADE
        );
        CREATE TABLE IF NOT EXISTS Route_Usage (
          Usage_ID TEXT PRIMARY KEY, Route_ID TEXT NOT NULL REFERENCES Route(ID) ON DELETE CASCADE,
          Started_At REAL NOT NULL, Finished_At REAL, Actual_Duration REAL
        );
        CREATE TABLE IF NOT EXISTS Migration (Name TEXT PRIMARY KEY);
        """)
        importLegacySnapshotIfNeeded()
    }

    struct LibraryRoute: Identifiable {
        let id: UUID
        var number: String
        var name: String
        let waypointCount: Int
    }

    func libraryRoutes() -> [LibraryRoute] {
        var statement: OpaquePointer?
        let sql = "SELECT R.ID,R.Route_Number,R.Route_Name,COUNT(W.Waypoint_ID) FROM Route R LEFT JOIN Waypoints W ON W.Route_ID=R.ID GROUP BY R.ID ORDER BY CAST(R.Route_Number AS INTEGER),R.Route_Number"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var routes: [LibraryRoute] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idRaw = sqlite3_column_text(statement, 0), let id = UUID(uuidString: String(cString: idRaw)) else { continue }
            routes.append(LibraryRoute(id: id,
                number: sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? "",
                name: sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? "",
                waypointCount: Int(sqlite3_column_int(statement, 3))))
        }
        return routes
    }

    func updateRouteDetails(id: UUID, number: String, name: String) throws {
        let trimmedNumber = number.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNumber.isEmpty, trimmedNumber.count <= 10,
              trimmedNumber.allSatisfy({ $0 >= "0" && $0 <= "9" }), name.count <= 100 else {
            throw NSError(domain: "RouteDatabase", code: 1, userInfo: [NSLocalizedDescriptionKey: "Use a route number of up to 10 digits and a route name of up to 100 characters."])
        }
        if numberExists(trimmedNumber, excluding: id) {
            throw RouteNumberConflict(number: trimmedNumber, suggestion: nextRouteNumber())
        }
        try run("UPDATE Route SET Route_Number=?,Route_Name=? WHERE ID=?",
                [.text(trimmedNumber), .text(name.trimmingCharacters(in: .whitespacesAndNewlines)), .text(id.uuidString)])
    }

    struct SavedRoute {
        let id: UUID
        let number: String
        let name: String
        let waypoints: [(UUID, Double, Double, String)]
    }

    func loadRoute(id: UUID) -> SavedRoute? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT Route_Number,Route_Name FROM Route WHERE ID=?", -1, &statement, nil) == SQLITE_OK else { return nil }
        bind(.text(id.uuidString), to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { sqlite3_finalize(statement); return nil }
        let number = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
        let name = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
        sqlite3_finalize(statement)
        guard sqlite3_prepare_v2(db, "SELECT Waypoint_ID,Waypoint_Latitude,Waypoint_Longitude,Waypoint_Name FROM Waypoints WHERE Route_ID=? ORDER BY Waypoint_Order", -1, &statement, nil) == SQLITE_OK else { return SavedRoute(id: id, number: number, name: name, waypoints: []) }
        defer { sqlite3_finalize(statement) }
        bind(.text(id.uuidString), to: 1, in: statement)
        var points: [(UUID, Double, Double, String)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(statement, 0), let waypointID = UUID(uuidString: String(cString: raw)) else { continue }
            points.append((waypointID, sqlite3_column_double(statement, 1), sqlite3_column_double(statement, 2), sqlite3_column_text(statement, 3).map { String(cString: $0) } ?? ""))
        }
        return SavedRoute(id: id, number: number, name: name, waypoints: points)
    }

    deinit { sqlite3_close(db) }

    /// The next sequential numeric identifier, allocated under an immediate transaction on save.
    func nextRouteNumber() -> String {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT COALESCE(MAX(CAST(Route_Number AS INTEGER)), 0) + 1 FROM Route WHERE Route_Number GLOB '[0-9]*'", -1, &statement, nil) == SQLITE_OK else { return "1" }
        _ = sqlite3_step(statement)
        return String(sqlite3_column_int64(statement, 0))
    }

    /// Upserts the current map route, allocating a number on first save.
    func save(waypoints: [(UUID, Double, Double, String)], legs: [(UUID, UUID, Double)], routeID: UUID?, routeNumber: String?, name: String = "", colour: String = "007AFF") throws -> (UUID, String) {
        try withTransaction {
            let id = routeID ?? UUID()
            let number = routeNumber ?? nextRouteNumber()
            if numberExists(number, excluding: routeID) {
                throw RouteNumberConflict(number: number, suggestion: nextRouteNumber())
            }
            try run("INSERT INTO Route(ID, Route_Number, Route_Name, Route_Colour, Planned_Departure) VALUES(?,?,?,?,?) ON CONFLICT(ID) DO UPDATE SET Planned_Departure=excluded.Planned_Departure",
                    [.text(id.uuidString), .text(number), .text(name), .text(colour), .real(Date().timeIntervalSince1970)])
            try run("DELETE FROM Leg WHERE Route_ID=?", [.text(id.uuidString)])
            try run("DELETE FROM Waypoints WHERE Route_ID=?", [.text(id.uuidString)])
            for (index, point) in waypoints.enumerated() {
                try run("INSERT INTO Waypoints(Waypoint_ID,Route_ID,Waypoint_Order,Waypoint_Latitude,Waypoint_Longitude,Waypoint_Name) VALUES(?,?,?,?,?,?)",
                        [.text(point.0.uuidString), .text(id.uuidString), .integer(Int64(index)), .real(point.1), .real(point.2), .text(point.3)])
            }
            var eta = 0.0
            for leg in legs {
                eta += leg.2
                try run("INSERT INTO Leg(Route_ID,Prev_Waypoint_ID,Next_Waypoint_ID,Leg_Duration,ETA) VALUES(?,?,?,?,?)",
                        [.text(id.uuidString), .text(leg.0.uuidString), .text(leg.1.uuidString), .real(leg.2), .real(eta)])
            }
            return (id, number)
        }
    }

    private func numberExists(_ number: String, excluding id: UUID?) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM Route WHERE Route_Number=? AND (? IS NULL OR ID<>?) LIMIT 1", -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        bind(.text(number), to: 1, in: statement)
        if let id {
            bind(.text(id.uuidString), to: 2, in: statement)
            bind(.text(id.uuidString), to: 3, in: statement)
        } else {
            bind(.null, to: 2, in: statement)
            bind(.null, to: 3, in: statement)
        }
        return sqlite3_step(statement) == SQLITE_ROW
    }

    func loadLatest() -> (UUID, String, [(UUID, Double, Double, String)])? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT ID,Route_Number FROM Route ORDER BY rowid DESC LIMIT 1", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW,
              let idText = sqlite3_column_text(statement, 0), let numberText = sqlite3_column_text(statement, 1),
              let id = UUID(uuidString: String(cString: idText)) else { sqlite3_finalize(statement); return nil }
        let number = String(cString: numberText)
        sqlite3_finalize(statement)
        var points: [(UUID, Double, Double, String)] = []
        guard sqlite3_prepare_v2(db, "SELECT Waypoint_ID,Waypoint_Latitude,Waypoint_Longitude,Waypoint_Name FROM Waypoints WHERE Route_ID=? ORDER BY Waypoint_Order", -1, &statement, nil) == SQLITE_OK else { return (id, number, points) }
        defer { sqlite3_finalize(statement) }
        bind(.text(id.uuidString), to: 1, in: statement)
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(statement, 0), let waypointID = UUID(uuidString: String(cString: raw)) else { continue }
            let name = sqlite3_column_text(statement, 3).map { String(cString: $0) } ?? ""
            points.append((waypointID, sqlite3_column_double(statement, 1), sqlite3_column_double(statement, 2), name))
        }
        return (id, number, points)
    }

    func recordUsage(routeID: UUID, startedAt: Date = Date(), finishedAt: Date? = nil, actualDuration: TimeInterval? = nil) throws {
        try run("INSERT INTO Route_Usage(Usage_ID,Route_ID,Started_At,Finished_At,Actual_Duration) VALUES(?,?,?,?,?)",
                [.text(UUID().uuidString), .text(routeID.uuidString), .real(startedAt.timeIntervalSince1970),
                 finishedAt.map { .real($0.timeIntervalSince1970) } ?? .null, actualDuration.map { .real($0) } ?? .null])
    }

    private enum Value { case text(String), real(Double), integer(Int64), null }

    /// Imports the previously persisted route-snapshot.json once. The original remains
    /// intact as a recovery copy; the migration marker prevents duplicate imports.
    private func importLegacySnapshotIfNeeded() {
        var check: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM Migration WHERE Name='route-snapshot-json-v1'", -1, &check, nil) == SQLITE_OK else { return }
        let alreadyImported = sqlite3_step(check) == SQLITE_ROW
        sqlite3_finalize(check)
        guard !alreadyImported else { return }
        defer { try? run("INSERT OR IGNORE INTO Migration(Name) VALUES(?)", [.text("route-snapshot-json-v1")]) }
        guard let directory = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return }
        let source = directory.appendingPathComponent("route-snapshot.json")
        guard let data = try? Data(contentsOf: source), let snapshot = try? JSONDecoder().decode(RouteSnapshot.self, from: data) else { return }
        let points = snapshot.waypoints.map { waypoint in
            (waypoint.id, waypoint.coordinate.latitude, waypoint.coordinate.longitude,
             waypoint.name.resolved(preferring: [Locale.preferredLanguages.first ?? "en", "en"]) ?? "")
        }
        let legs = snapshot.legs.map { ($0.fromWaypointID, $0.toWaypointID, $0.expectedTravelTime) }
        _ = try? save(waypoints: points, legs: legs, routeID: snapshot.id, routeNumber: nil,
                      name: "Imported route", colour: "007AFF")
    }

    private func bind(_ value: Value, to index: Int32, in statement: OpaquePointer?) {
        switch value {
        case .text(let value): sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
        case .real(let value): sqlite3_bind_double(statement, index, value)
        case .integer(let value): sqlite3_bind_int64(statement, index, value)
        case .null: sqlite3_bind_null(statement, index)
        }
    }
    private func run(_ sql: String, _ values: [Value]) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw error() }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() { bind(value, to: Int32(offset + 1), in: statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
    }
    private func execute(_ sql: String) {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { fatalError(error().localizedDescription) }
    }
    private func withTransaction<T>(_ body: () throws -> T) throws -> T {
        execute("BEGIN IMMEDIATE")
        do { let value = try body(); execute("COMMIT"); return value }
        catch { execute("ROLLBACK"); throw error }
    }
    private func error() -> NSError { NSError(domain: "RouteDatabase", code: Int(sqlite3_errcode(db)), userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]) }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private struct RouteNumberConflict: LocalizedError {
    let number: String
    let suggestion: String
    var errorDescription: String? { "Route number \(number) already exists. Try route number \(suggestion)." }
}
