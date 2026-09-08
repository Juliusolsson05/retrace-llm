import Foundation
import CoreGraphics
import SQLCipher
import Shared

/// SELECT-only evidence reads over a caller-owned connection. No manager, initialization,
/// migration, key lookup, or metric writes occur here. Callers must serialize access to the
/// connection and run these synchronous SQLite operations off the main actor (e.g. in a read pool).
public enum EvidenceReadQueries {
    /// Frame IDs in ascending timestamp order for the current calendar's local day.
    /// The day and source windows include their start and exclude their end. Native hidden
    /// segments and pending deletions are excluded, matching the default filtered timeline.
    /// Rewind has neither native visibility columns nor tags. Date bindings use the config's
    /// integer milliseconds or ISO-8601 TEXT format; numeric seconds are not a supported format.
    public static func visibleFrameIDs(
        connection: DatabaseConnection,
        config: DatabaseConfig,
        day: Date
    ) throws -> [Int64] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        let hiddenTagID = config.source == .rewind ? nil : try hiddenTagID(connection: connection)
        let boundary = buildSourceBoundaryClause(config: config, columnName: "f.createdAt")
        var clauses = ["f.createdAt >= ?", "f.createdAt < ?"]
        if let visibility = nativeVisibleFrameClause(isRewindDatabase: config.source == .rewind) {
            clauses.append(visibility)
        }
        if let boundaryClause = boundary.clause {
            clauses.append(boundaryClause)
        }
        if hiddenTagID != nil {
            clauses.append("""
                NOT EXISTS (
                    SELECT 1 FROM segment_tag st_hidden
                    WHERE st_hidden.segmentId = f.segmentId
                    AND st_hidden.tagId = ?
                )
                """)
        }
        let sql = """
            SELECT f.id
            FROM frame f
            INNER JOIN segment s ON f.segmentId = s.id
            WHERE \(clauses.joined(separator: " AND "))
            ORDER BY f.createdAt ASC
            """
        guard let statement = try connection.prepare(sql: sql) else {
            throw DatabaseConnectionError.notConnected
        }
        defer { connection.finalize(statement) }
        config.bindDate(start, to: statement, at: 1)
        config.bindDate(end, to: statement, at: 2)
        var index: Int32 = 3
        for date in boundary.bindValues {
            config.bindDate(date, to: statement, at: index)
            index += 1
        }
        if let hiddenTagID { sqlite3_bind_int64(statement, index, hiddenTagID) }
        var ids: [Int64] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            ids.append(sqlite3_column_int64(statement, 0))
            result = sqlite3_step(statement)
        }
        try checkCompletion(result, statement: statement, sql: sql)
        return ids
    }

    /// Same name lookup used by DataAdapter's hidden-tag cache, without DatabaseManager.
    /// An absent tag is not created. Query failures are propagated to avoid returning
    /// apparently complete evidence after a failed privacy-filter lookup.
    public static func hiddenTagID(connection: DatabaseConnection) throws -> Int64? {
        let sql = "SELECT id, name FROM tag WHERE name = ?;"
        guard let statement = try connection.prepare(sql: sql) else {
            throw DatabaseConnectionError.notConnected
        }
        defer { connection.finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, "hidden", -1, transient)
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW {
            guard sqlite3_column_text(statement, 1) != nil else { return nil }
            return sqlite3_column_int64(statement, 0)
        }
        try checkCompletion(result, statement: statement, sql: sql)
        return nil
    }

    private static func checkCompletion(_ result: Int32, statement: OpaquePointer, sql: String) throws {
        guard result == SQLITE_DONE else {
            throw DatabaseConnectionError.executionFailed(
                sql: sql, error: String(cString: sqlite3_errmsg(sqlite3_db_handle(statement)))
            )
        }
    }

    // The helpers below preserve DataAdapter's existing SQL, projections, and row decoding.
    // Keep legacy range/calendar behavior separate from the stricter day evidence contract:
    // nil-filter ranges include hidden segments and their clamped upper endpoint, and the
    // unfiltered calendar lists hidden-only days. Changing these would change existing UI reads.

    public static func buildSourceBoundaryClause(
        config: DatabaseConfig,
        columnName: String
    ) -> (clause: String?, bindValues: [Date]) {
        var clauses: [String] = []
        var bindValues: [Date] = []

        if let minimumDate = config.minimumDate {
            clauses.append("\(columnName) >= ?")
            bindValues.append(minimumDate)
        }

        if let cutoffDate = config.cutoffDate {
            clauses.append("\(columnName) < ?")
            bindValues.append(cutoffDate)
        }

        guard !clauses.isEmpty else {
            return (nil, [])
        }

        return ("(" + clauses.joined(separator: " AND ") + ")", bindValues)
    }

    /// Native visibility is deletion-only; processingStatus/redactionReason do not hide frames.
    public static func nativeVisibleFrameClause(
        frameAlias: String? = "f",
        isRewindDatabase: Bool
    ) -> String? {
        guard !isRewindDatabase else { return nil }
        let prefix = frameAlias.map { "\($0)." } ?? ""
        return "(\(prefix)rewritePurpose IS NULL OR \(prefix)rewritePurpose != 'deletion')"
    }

    public struct FrameWithVideoProjection: Sendable {
        public let encodedAtColumn: String
        public let processingStatusColumn: String
        public let redactionReasonColumn: String
        public let captureTriggerColumn: String
        public let mousePositionColumn: String
        public let scrollPositionColumn: String
        public let videoCurrentTimeColumn: String
    }

    public static func frameWithVideoProjection(
        source: FrameSource,
        tableAlias: String
    ) -> FrameWithVideoProjection {
        if source == .rewind {
            return FrameWithVideoProjection(
                encodedAtColumn: "NULL as encodedAt",
                processingStatusColumn: "-1 as processingStatus",
                redactionReasonColumn: "NULL as redactionReason",
                captureTriggerColumn: "NULL as captureTrigger",
                mousePositionColumn: "NULL",
                scrollPositionColumn: "NULL",
                videoCurrentTimeColumn: "NULL"
            )
        }

        return FrameWithVideoProjection(
            encodedAtColumn: "\(tableAlias).encodedAt",
            processingStatusColumn: "\(tableAlias).processingStatus",
            redactionReasonColumn: "\(tableAlias).redactionReason",
            captureTriggerColumn: "\(tableAlias).capture_trigger",
            mousePositionColumn: "\(tableAlias).mousePosition",
            scrollPositionColumn: "\(tableAlias).scrollPosition",
            videoCurrentTimeColumn: "\(tableAlias).videoCurrentTime"
        )
    }

    public static func frameWithVideoSubqueryProjection(source: FrameSource) -> FrameWithVideoProjection {
        if source == .rewind {
            return FrameWithVideoProjection(
                encodedAtColumn: "NULL as encodedAt",
                processingStatusColumn: "-1 as processingStatus",
                redactionReasonColumn: "NULL as redactionReason",
                captureTriggerColumn: "NULL as captureTrigger",
                mousePositionColumn: "NULL as mousePosition",
                scrollPositionColumn: "NULL as scrollPosition",
                videoCurrentTimeColumn: "NULL as videoCurrentTime"
            )
        }

        return FrameWithVideoProjection(
            encodedAtColumn: "encodedAt",
            processingStatusColumn: "processingStatus",
            redactionReasonColumn: "redactionReason",
            captureTriggerColumn: "capture_trigger",
            mousePositionColumn: "mousePosition",
            scrollPositionColumn: "scrollPosition",
            videoCurrentTimeColumn: "videoCurrentTime"
        )
    }

    public static func videoInfoProjection(
        source: FrameSource,
        frameAlias: String,
        videoAlias: String
    ) -> String {
        if source == .rewind {
            return "\(videoAlias).path, \(videoAlias).frameRate, \(videoAlias).width, \(videoAlias).height, 0 as videoProcessingState, NULL as videoFileSize, NULL as videoFrameCount, NULL as videoReencodedAt"
        }

        return """
            \(videoAlias).path, \(videoAlias).frameRate, \(videoAlias).width, \(videoAlias).height,
            \(videoAlias).processingState as videoProcessingState, \(videoAlias).fileSize as videoFileSize, \(videoAlias).frameCount as videoFrameCount,
            (SELECT MAX(fr.rewrittenAt) FROM frame fr WHERE fr.videoId = \(frameAlias).videoId) as videoReencodedAt
            """
    }

    /// Compatibility range read with both clamped endpoints included. DataAdapter supplies its
    /// cached hidden tag and requires a segment for default filtered reads; nil-filter reads
    /// include hidden/unsegmented frames. Use visibleFrameIDs for the strict day contract.
    public static func timelineFramesInRange(
        from startDate: Date,
        to endDate: Date,
        limit: Int,
        connection: DatabaseConnection,
        config: DatabaseConfig,
        hiddenTagID: Int64? = nil,
        requireSegment: Bool = false
    ) throws -> [FrameWithVideoInfo] {
        let effectiveStartDate = config.applyLowerBound(to: startDate)
        let effectiveEndDate = config.applyCutoff(to: endDate)
        guard effectiveStartDate < effectiveEndDate else { return [] }

        var whereClauses = ["f.createdAt >= ?", "f.createdAt <= ?"]
        if let visibilityClause = Self.nativeVisibleFrameClause(
            frameAlias: "f",
            isRewindDatabase: config.source == .rewind
        ) {
            whereClauses.append(visibilityClause)
        }

        let hiddenTagID = config.source == .rewind ? nil : hiddenTagID
        if hiddenTagID != nil {
            whereClauses.append("""
                NOT EXISTS (
                    SELECT 1 FROM segment_tag st_hidden
                    WHERE st_hidden.segmentId = f.segmentId
                    AND st_hidden.tagId = ?
                )
                """)
        }

        let whereClause = whereClauses.joined(separator: " AND ")

        let projection = Self.frameWithVideoProjection(source: config.source, tableAlias: "f")

        let sql = """
            SELECT
                f.id,
                f.createdAt,
                f.segmentId,
                f.videoId,
                f.videoFrameIndex,
                \(projection.encodedAtColumn),
                \(projection.processingStatusColumn),
                \(projection.redactionReasonColumn),
                \(projection.captureTriggerColumn),
                s.bundleID,
                s.windowName,
                s.browserUrl,
                \(projection.mousePositionColumn),
                \(projection.scrollPositionColumn),
                \(projection.videoCurrentTimeColumn),
                \(Self.videoInfoProjection(source: config.source, frameAlias: "f", videoAlias: "v"))
            FROM frame f
            \(requireSegment ? "INNER" : "LEFT") JOIN segment s ON f.segmentId = s.id
            LEFT JOIN video v ON f.videoId = v.id
            WHERE \(whereClause)
            ORDER BY f.createdAt ASC
            LIMIT ?;
            """

        guard let statement = try? connection.prepare(sql: sql) else { return [] }
        defer { connection.finalize(statement) }

        config.bindDate(effectiveStartDate, to: statement, at: 1)
        config.bindDate(effectiveEndDate, to: statement, at: 2)

        var bindIndex: Int32 = 3
        if let hiddenTagID {
            sqlite3_bind_int64(statement, bindIndex, hiddenTagID)
            bindIndex += 1
        }
        sqlite3_bind_int(statement, bindIndex, Int32(limit))

        var frames: [FrameWithVideoInfo] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let frameWithVideo = Self.parseFrameWithVideoInfo(statement: statement, config: config) {
                frames.append(frameWithVideo)
            }
        }

        return frames
    }

    /// Unfiltered calendar timestamps (earliest visible frame per local day, newest day first).
    /// Preserves hidden-only days and the legacy empty-result fallback on preparation failures.
    public static func distinctDates(connection: DatabaseConnection, config: DatabaseConfig) throws -> [Date] {
        let sourceBoundaryFilter = Self.buildSourceBoundaryClause(config: config, columnName: "createdAt")
        var whereClauses: [String] = []
        if let visibilityClause = Self.nativeVisibleFrameClause(
            frameAlias: nil,
            isRewindDatabase: config.source == .rewind
        ) {
            whereClauses.append(visibilityClause)
        }
        if let boundaryClause = sourceBoundaryFilter.clause {
            whereClauses.append(boundaryClause)
        }
        let whereClause = whereClauses.isEmpty ? "" : "WHERE " + whereClauses.joined(separator: " AND ")

        let sql: String
        if config.dateFormatter == nil {
            sql = """
                SELECT MIN(createdAt) as dayTimestamp
                FROM frame
                \(whereClause)
                GROUP BY date(createdAt / 1000, 'unixepoch', 'localtime')
                ORDER BY dayTimestamp DESC
                """
        } else {
            sql = """
                SELECT MIN(createdAt) as dayTimestamp
                FROM frame
                \(whereClause)
                GROUP BY date(createdAt, 'localtime')
                ORDER BY dayTimestamp DESC
                """
        }

        guard let statement = try? connection.prepare(sql: sql) else {
            return []
        }
        defer { connection.finalize(statement) }

        var bindIndex = 1
        for date in sourceBoundaryFilter.bindValues {
            config.bindDate(date, to: statement, at: Int32(bindIndex))
            bindIndex += 1
        }

        var dates: [Date] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let date = config.parseDate(from: statement, column: 0) else { continue }
            dates.append(date)
        }

        return dates
    }

    public static func parseFrameWithVideoInfo(statement: OpaquePointer, config: DatabaseConfig) -> FrameWithVideoInfo? {
        let id = FrameID(value: sqlite3_column_int64(statement, 0))

        guard let timestamp = config.parseDate(from: statement, column: 1) else {
            return nil
        }

        let segmentID = AppSegmentID(value: sqlite3_column_int64(statement, 2))
        let videoID = VideoSegmentID(value: sqlite3_column_int64(statement, 3))
        let videoFrameIndex = Int(sqlite3_column_int(statement, 4))

        let encodedAt = config.parseDate(from: statement, column: 5)
        let processingStatus = Int(sqlite3_column_int(statement, 6))

        let redactionReason = Self.getTextOrNil(statement, 7)
        let captureTrigger = Self.getTextOrNil(statement, 8).flatMap(FrameCaptureTrigger.init(rawValue:))
        let bundleID = Self.getTextOrNil(statement, 9) ?? ""
        let windowName = Self.getTextOrNil(statement, 10)
        let browserUrl = Self.getTextOrNil(statement, 11)
        let mousePosition = Self.decodeStoredPoint(Self.getTextOrNil(statement, 12))
        let scrollY = Self.decodeStoredPoint(Self.getTextOrNil(statement, 13))?.y
        let videoCurrentTime = sqlite3_column_type(statement, 14) != SQLITE_NULL ? sqlite3_column_double(statement, 14) : nil

        let videoPath = Self.getTextOrNil(statement, 15)
        let frameRate = sqlite3_column_type(statement, 16) != SQLITE_NULL ? sqlite3_column_double(statement, 16) : nil
        let width = sqlite3_column_type(statement, 17) != SQLITE_NULL ? Int(sqlite3_column_int(statement, 17)) : nil
        let height = sqlite3_column_type(statement, 18) != SQLITE_NULL ? Int(sqlite3_column_int(statement, 18)) : nil
        let videoProcessingState = sqlite3_column_type(statement, 19) != SQLITE_NULL ? Int(sqlite3_column_int(statement, 19)) : 0
        let fileSizeBytes = sqlite3_column_type(statement, 20) != SQLITE_NULL ? sqlite3_column_int64(statement, 20) : nil
        let frameCount = sqlite3_column_type(statement, 21) != SQLITE_NULL ? Int(sqlite3_column_int(statement, 21)) : nil
        let videoReencodedAt = config.parseDate(from: statement, column: 22)

        let metadata = FrameMetadata(
            appBundleID: bundleID.isEmpty ? nil : bundleID,
            appName: bundleID.components(separatedBy: ".").last,
            windowName: windowName,
            browserURL: browserUrl,
            redactionReason: redactionReason,
            captureTrigger: captureTrigger,
            displayID: 0,
            mousePosition: mousePosition.map { CGPoint(x: $0.x, y: $0.y) }
        )

        let frame = FrameReference(
            id: id,
            timestamp: timestamp,
            segmentID: segmentID,
            videoID: videoID,
            frameIndexInSegment: videoFrameIndex,
            encodedAt: encodedAt,
            metadata: metadata,
            source: config.source
        )

        let videoInfo: FrameVideoInfo?
        if let relativePath = videoPath, let rate = frameRate, let w = width, let h = height {
            let fullPath = "\(config.storageRoot)/\(relativePath)"
            videoInfo = FrameVideoInfo(
                videoPath: fullPath,
                frameIndex: videoFrameIndex,
                frameRate: rate,
                width: w,
                height: h,
                isVideoFinalized: videoProcessingState == 0,
                videoReencodedAt: videoReencodedAt,
                fileSizeBytes: fileSizeBytes,
                frameCount: frameCount
            )
        } else {
            videoInfo = nil
        }

        return FrameWithVideoInfo(
            frame: frame,
            videoInfo: videoInfo,
            processingStatus: processingStatus,
            videoCurrentTime: videoCurrentTime,
            scrollY: scrollY
        )
    }

    private static func getTextOrNil(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        guard let cString = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: cString)
    }

    private static func decodeStoredPoint(_ rawValue: String?) -> (x: Double, y: Double)? {
        guard let rawValue else {
            return nil
        }
        let parts = rawValue.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let x = Double(parts[0]),
              let y = Double(parts[1]) else {
            return nil
        }
        return (x, y)
    }
}
