import Foundation
import GRDB

actor LibraryDatabase {
    private let db: DatabaseQueue
    init(path: String) throws {
        db = try DatabaseQueue(path: path)
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
    func loadPlaylists() throws -> ([Playlist], [PlaylistItem]) {
        try db.read { db in
            (try Playlist.order(Column("createdAt")).fetchAll(db),
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
    func deletePlaylist(id: String) throws {
        try db.write { db in _ = try Playlist.deleteOne(db, key: id) }
    }

}
