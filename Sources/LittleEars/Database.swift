import Foundation
import GRDB

actor LibraryDatabase {
    private let db: DatabaseQueue
    init(path: String, copyingHistoryFrom historyPath: String? = nil) throws {
        db = try DatabaseQueue(path: path)
        if let historyPath {
            var configuration = Configuration(); configuration.readonly = true
            let source = try DatabaseQueue(path: historyPath, configuration: configuration)
            try source.backup(to: db)
        }
        var migrations = DatabaseMigrator()
        migrations.registerMigration("v1") { db in
            try db.create(table: "sources") { t in
                t.column("id", .text).primaryKey(); t.column("path", .text).notNull()
                t.column("bookmark", .blob).notNull(); t.column("name", .text).notNull()
            }
            try db.create(table: "tracks") { t in
                t.column("id", .text).primaryKey(); t.column("sourceID", .text).notNull().indexed()
                t.column("relativePath", .text).notNull(); t.column("identity", .text).notNull().indexed()
                t.column("title", .text).notNull(); t.column("duration", .double).notNull()
                t.column("format", .text).notNull(); t.column("fileSize", .integer).notNull()
                t.column("available", .boolean).notNull()
            }
            try db.create(table: "sessions") { t in
                t.column("id", .text).primaryKey(); t.column("trackID", .text).notNull().indexed()
                t.column("startedAt", .datetime).notNull(); t.column("endedAt", .datetime)
                t.column("listenedSeconds", .double).notNull(); t.column("completed", .boolean).notNull()
                t.column("endReason", .text); t.column("completedDay", .text)
            }
            try db.create(table: "fragments") { t in
                t.column("id", .text).primaryKey(); t.column("sessionID", .text).notNull().indexed()
                t.column("trackID", .text).notNull().indexed(); t.column("day", .text).notNull().indexed()
                t.column("seconds", .double).notNull()
            }
            try db.create(table: "state") { t in t.column("key", .text).primaryKey(); t.column("value", .blob).notNull() }
        }
        migrations.registerMigration("v2-session-checkpoint") { db in
            try db.alter(table: "sessions") { $0.add(column: "checkpointAt", .datetime) }
        }
        migrations.registerMigration("v3-playlists") { db in
            try db.create(table: "playlists") { t in
                t.column("id", .text).primaryKey(); t.column("name", .text).notNull()
                t.column("createdAt", .datetime).notNull(); t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "playlistItems") { t in
                t.column("id", .text).primaryKey()
                t.column("playlistID", .text).notNull().indexed().references("playlists", onDelete: .cascade)
                t.column("trackID", .text).notNull().indexed()
                t.column("position", .integer).notNull()
            }
        }
        migrations.registerMigration("v4-playlist-order") { db in
            try db.alter(table: "playlists") { $0.add(column: "position", .integer).notNull().defaults(to: 0) }
            let ids = try String.fetchAll(db, sql: "SELECT id FROM playlists ORDER BY createdAt, id")
            for (position, id) in ids.enumerated() {
                try db.execute(sql: "UPDATE playlists SET position = ? WHERE id = ?", arguments: [position, id])
            }
        }
        try migrations.migrate(db)
        try db.write { db in
            try db.execute(sql: "UPDATE sessions SET endedAt = COALESCE(checkpointAt, startedAt), endReason = 'interrupted' WHERE endedAt IS NULL")
        }
    }
    func loadLibrary() throws -> ([LibrarySource], [Track]) {
        try db.read { (try LibrarySource.fetchAll($0), try Track.fetchAll($0)) }
    }
    func saveSource(_ source: LibrarySource) throws { try db.write { try source.save($0) } }
    func scanResult(sourceID: String, scanned: [Track]) throws {
        try db.write { db in
            let old = try Track.filter(Column("sourceID") == sourceID).fetchAll(db)
            var byIdentity: [String: Track] = [:]
            for track in old { byIdentity[track.identity] = track }
            try db.execute(sql: "UPDATE tracks SET available = 0 WHERE sourceID = ?", arguments: [sourceID])
            for var track in scanned {
                if let previous = byIdentity[track.identity] { track.id = previous.id }
                try track.save(db)
            }
        }
    }
    func saveSnapshot(_ snapshot: PlayerSnapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        try db.write { try $0.execute(sql: "INSERT OR REPLACE INTO state (key, value) VALUES ('player', ?)", arguments: [data]) }
    }
    func snapshot() throws -> PlayerSnapshot? {
        try db.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT value FROM state WHERE key = 'player'") else { return nil }
            return try JSONDecoder().decode(PlayerSnapshot.self, from: data)
        }
    }
    func checkpoint(session: ListenSession?, fragments: [ListenFragment], snapshot: PlayerSnapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        try db.write { db in
            if var session { session.checkpointAt = Date(); try session.save(db) }
            for fragment in fragments { try fragment.save(db) }
            try db.execute(sql: "INSERT OR REPLACE INTO state (key, value) VALUES ('player', ?)", arguments: [data])
        }
    }
    func stats() throws -> Stats {
        try db.read { db in
            let days = try DailyStat.fetchAll(db, sql: "SELECT day, SUM(seconds) AS seconds FROM fragments GROUP BY day ORDER BY day")
            let tracks = try TrackStat.fetchAll(db, sql: """
                SELECT trackID, SUM(seconds) AS seconds,
                (SELECT COUNT(*) FROM sessions s WHERE s.trackID = f.trackID AND completed = 1) AS completions
                FROM fragments f GROUP BY trackID ORDER BY seconds DESC
                """)
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions WHERE completed = 1") ?? 0
            return Stats(days: days, tracks: tracks, completions: count)
        }
    }
    func yearlyListeningStats(startDay: String, endDayExclusive: String) throws -> YearlyListeningStats {
        try db.read { db in
            let days = try DailyListeningStat.fetchAll(db, sql: """
                WITH duration AS (
                    SELECT day, SUM(seconds) AS seconds FROM fragments WHERE seconds > 0 AND day >= ? AND day < ? GROUP BY day
                ), complete AS (
                    SELECT completedDay AS day, COUNT(*) AS completions FROM sessions
                    WHERE completed = 1 AND completedDay >= ? AND completedDay < ? GROUP BY completedDay
                ), dates AS (SELECT day FROM duration UNION SELECT day FROM complete)
                SELECT dates.day, COALESCE(duration.seconds, 0) AS seconds, COALESCE(complete.completions, 0) AS completions
                FROM dates LEFT JOIN duration USING(day) LEFT JOIN complete USING(day) ORDER BY dates.day
                """, arguments: [startDay, endDayExclusive, startDay, endDayExclusive])
            let years = try String.fetchAll(db, sql: """
                SELECT DISTINCT substr(day, 1, 4) FROM fragments WHERE seconds > 0
                UNION SELECT DISTINCT substr(completedDay, 1, 4) FROM sessions WHERE completed = 1 AND completedDay IS NOT NULL
                """).compactMap(Int.init).sorted()
            return YearlyListeningStats(days: days, years: years)
        }
    }
    func dailyListeningDetails(day: String) throws -> DailyListeningDetails {
        try db.read { db in
            let values = try Row.fetchAll(db, sql: """
                WITH duration AS (SELECT trackID, SUM(seconds) AS seconds FROM fragments WHERE day = ? AND seconds > 0 GROUP BY trackID),
                complete AS (SELECT trackID, COUNT(*) AS completions FROM sessions WHERE completed = 1 AND completedDay = ? GROUP BY trackID),
                ids AS (SELECT trackID FROM duration UNION SELECT trackID FROM complete)
                SELECT ids.trackID, COALESCE(duration.seconds, 0) AS seconds, COALESCE(complete.completions, 0) AS completions
                FROM ids LEFT JOIN duration USING(trackID) LEFT JOIN complete USING(trackID)
                ORDER BY seconds DESC, ids.trackID
                """, arguments: [day, day])
            let tracks = try Track.fetchAll(db, sql: """
                SELECT * FROM tracks WHERE id IN (
                    SELECT trackID FROM fragments WHERE day = ? AND seconds > 0
                    UNION SELECT trackID FROM sessions WHERE completed = 1 AND completedDay = ?)
                """, arguments: [day, day])
            let byID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
            let entries = values.map { row -> DailyTrackListeningStat in
                let id: String = row["trackID"]
                return DailyTrackListeningStat(id: id, track: byID[id], seconds: row["seconds"], completions: row["completions"])
            }
            return DailyListeningDetails(day: day, seconds: entries.reduce(0) { $0 + $1.seconds }, completions: entries.reduce(0) { $0 + $1.completions }, tracks: entries)
        }
    }
    func trackStatistics(_ id: String, startDay: String?, endDay: String) throws -> TrackStatisticsDetails {
        try db.read { db in
            let summary = try TrackStatistics.fetchOne(db, sql: """
                SELECT
                (SELECT COALESCE(SUM(seconds), 0) FROM fragments WHERE trackID = :id AND seconds > 0) AS seconds,
                (SELECT COUNT(*) FROM sessions WHERE trackID = :id AND completed = 1) AS completions,
                (SELECT MAX(s.startedAt) FROM sessions s WHERE s.trackID = :id AND EXISTS
                    (SELECT 1 FROM fragments f WHERE f.sessionID = s.id AND f.trackID = :id AND f.seconds > 0)) AS lastPlayedAt,
                (SELECT COUNT(DISTINCT day) FROM fragments WHERE trackID = :id AND seconds > 0) AS listeningDays
                """, arguments: ["id": id]) ?? .empty
            let days = try DailyStat.fetchAll(db, sql: """
                SELECT day, SUM(seconds) AS seconds FROM fragments
                WHERE trackID = ? AND seconds > 0 AND day <= ? AND (? IS NULL OR day >= ?)
                GROUP BY day ORDER BY day
                """, arguments: [id, endDay, startDay, startDay])
            return TrackStatisticsDetails(summary: summary, days: days,
                history: try Self.queryTrackHistory(db, id: id, startDay: startDay, endDay: endDay, before: nil, limit: 50))
        }
    }
    func trackHistory(_ id: String, startDay: String?, endDay: String, before: TrackHistoryCursor? = nil, limit: Int = 50) throws -> TrackHistoryPage {
        try db.read { try Self.queryTrackHistory($0, id: id, startDay: startDay, endDay: endDay, before: before, limit: limit) }
    }
    private static func queryTrackHistory(_ db: Database, id: String, startDay: String?, endDay: String, before: TrackHistoryCursor?, limit: Int) throws -> TrackHistoryPage {
        let limit = min(100, max(1, limit))
        let rows = try TrackListeningRecord.fetchAll(db, sql: """
            SELECT s.id, s.startedAt, s.completed,
                (SELECT COALESCE(SUM(f.seconds), 0) FROM fragments f WHERE f.sessionID = s.id AND f.trackID = s.trackID AND f.seconds > 0) AS seconds
            FROM sessions s WHERE s.trackID = ? AND EXISTS
                (SELECT 1 FROM fragments f WHERE f.sessionID = s.id AND f.trackID = s.trackID
                    AND f.seconds > 0 AND f.day <= ? AND (? IS NULL OR f.day >= ?))
                AND (? IS NULL OR s.startedAt < ? OR (s.startedAt = ? AND s.id < ?))
            ORDER BY s.startedAt DESC, s.id DESC LIMIT ?
            """, arguments: [id, endDay, startDay, startDay, before?.id, before?.startedAt, before?.startedAt, before?.id, limit + 1])
        return TrackHistoryPage(records: Array(rows.prefix(limit)), hasMore: rows.count > limit)
    }
    func loadPlaylists() throws -> ([Playlist], [PlaylistItem]) {
        try db.read { db in
            (try Playlist.order(Column("position"), Column("createdAt"), Column("id")).fetchAll(db),
             try PlaylistItem.order(Column("position")).fetchAll(db))
        }
    }
    func savePlaylist(_ playlist: Playlist, items: [PlaylistItem]) throws {
        try db.write { db in
            try playlist.save(db)
            try PlaylistItem.filter(Column("playlistID") == playlist.id).deleteAll(db)
            for (index, var item) in items.enumerated() {
                item.playlistID = playlist.id; item.position = index
                try item.insert(db)
            }
        }
    }
    func savePlaylistOrder(_ ids: [String]) throws {
        try db.write { db in
            for (position, id) in ids.enumerated() {
                try db.execute(sql: "UPDATE playlists SET position = ? WHERE id = ?", arguments: [position, id])
            }
        }
    }
    func deletePlaylist(id: String) throws {
        try db.write { db in _ = try Playlist.deleteOne(db, key: id) }
    }

}
