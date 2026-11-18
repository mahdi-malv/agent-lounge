import Foundation

/// Reads transcripts in the background, a few new bytes at a time.
actor TranscriptReader {
    /// Files above this size are read from `tailBytes` before the end on first read.
    static let fullReadLimit: UInt64 = 32 * 1024 * 1024
    static let tailBytes: UInt64 = 8 * 1024 * 1024

    private struct FileState {
        var parser: any TranscriptParsing
        var offset: UInt64
    }

    private var files: [String: FileState] = [:]

    /// Reads new bytes. Returns the summary after the first read or when it changed, else nil.
    func read(path: String, format: TranscriptFormat) -> TranscriptSummary? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value else { return nil }

        let known = files[path]
        var state: FileState
        if let known, size >= known.offset {
            state = known
        } else {
            // First read, or the file got shorter (replaced).
            let startsMidFile = size > Self.fullReadLimit
            state = FileState(parser: format.makeParser(startsMidFile: startsMidFile), offset: startsMidFile ? size - Self.tailBytes : 0)
        }
        let isFirstRead = known == nil
        guard size > state.offset else {
            files[path] = state
            return isFirstRead ? state.parser.summary : nil
        }

        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: state.offset)
            let data = try handle.read(upToCount: Int(size - state.offset)) ?? Data()
            state.offset += UInt64(data.count)
            let before = state.parser.summary
            state.parser.consume(data)
            files[path] = state
            return isFirstRead || state.parser.summary != before ? state.parser.summary : nil
        } catch {
            return nil
        }
    }

    func forget(path: String) {
        files[path] = nil
    }
}
