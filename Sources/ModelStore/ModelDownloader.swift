import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Failures thrown by `ModelDownloader`.
public enum ModelDownloadError: Error, Sendable, Equatable {
    case notAnHTTPResponse
    case unexpectedHTTPStatus(Int)
    case cannotWritePartialFile(String)
    /// Hex digests are lowercase. The corrupt partial file is removed before
    /// this is thrown, so the next attempt starts clean.
    case checksumMismatch(expected: String, actual: String)
}

/// Downloads one model file with resume support: bytes stream into a
/// `<name>.partial` file next to the destination, a `Range` request continues
/// an interrupted download, SHA-256 is verified when the spec provides one,
/// and the finished file is moved into place atomically.
public actor ModelDownloader {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Downloads `file` to `destination`. `progress` receives fractions in
    /// `0...1`; it is best-effort and may not reach exactly 1.0 until the
    /// final call after the atomic move.
    public func download(
        file: ModelFileSpec,
        to destination: URL,
        progress: @Sendable (Double) -> Void
    ) async throws {
        let fileManager = FileManager.default
        let partial = Self.partialFileURL(for: destination)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let resumeOffset = Self.existingPartialBytes(at: partial)
        let request = Self.makeRequest(for: file, resumingFrom: resumeOffset)
        // swift-corelibs-foundation has no URLSession.bytes; Linux (CI-only,
        // never downloads real models) buffers the body instead.
        #if canImport(Darwin)
        let (byteStream, response) = try await session.bytes(for: request)
        #else
        let (bodyData, response) = try await Self.legacyData(session: session, request: request)
        #endif
        guard let http = response as? HTTPURLResponse else {
            throw ModelDownloadError.notAnHTTPResponse
        }

        let startOffset: Int64
        switch http.statusCode {
        case 200:
            // Full body: the server ignored (or was never sent) the Range
            // header, so any stale partial content is discarded below.
            startOffset = 0
        case 206:
            startOffset = resumeOffset
        default:
            throw ModelDownloadError.unexpectedHTTPStatus(http.statusCode)
        }
        if startOffset == 0 {
            guard fileManager.createFile(atPath: partial.path, contents: nil) else {
                throw ModelDownloadError.cannotWritePartialFile(partial.path)
            }
        }

        let expectedTotal: Int64 =
            http.expectedContentLength > 0
            ? startOffset + http.expectedContentLength
            : file.bytes

        let handle = try FileHandle(forWritingTo: partial)
        var written = startOffset
        do {
            _ = try handle.seekToEnd()
            #if canImport(Darwin)
            var buffer = Data(capacity: Self.writeChunkSize)
            for try await byte in byteStream {
                buffer.append(byte)
                if buffer.count >= Self.writeChunkSize {
                    try handle.write(contentsOf: buffer)
                    written += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    Self.report(progress, written: written, of: expectedTotal)
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
            }
            #else
            try handle.write(contentsOf: bodyData)
            written += Int64(bodyData.count)
            #endif
            try handle.close()
        } catch {
            // Keep the partial file so a later attempt can resume it.
            try? handle.close()
            throw error
        }
        Self.report(progress, written: written, of: expectedTotal)

        if let expectedHex = file.sha256 {
            let expected = expectedHex.lowercased()
            let actual = try Self.sha256Hex(ofFileAt: partial)
            guard actual == expected else {
                try? fileManager.removeItem(at: partial)
                throw ModelDownloadError.checksumMismatch(expected: expected, actual: actual)
            }
        }

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: partial, to: destination)
        progress(1.0)
    }

    private static let writeChunkSize = 64 * 1024

    /// The in-progress sibling of `destination`: `<name>.partial`.
    static func partialFileURL(for destination: URL) -> URL {
        destination.appendingPathExtension("partial")
    }

    /// Size of an existing partial file; 0 when absent or not a regular file.
    static func existingPartialBytes(at partialURL: URL) -> Int64 {
        FileInfo.regularFileSize(atPath: partialURL.path) ?? 0
    }

    /// Builds the GET request, adding a `Range` header when a prior attempt
    /// left `resumingFrom` bytes on disk.
    static func makeRequest(for file: ModelFileSpec, resumingFrom existingBytes: Int64) -> URLRequest {
        var request = URLRequest(url: file.url)
        request.httpMethod = "GET"
        if existingBytes > 0 {
            request.setValue("bytes=\(existingBytes)-", forHTTPHeaderField: "Range")
        }
        return request
    }

    private static func report(
        _ progress: @Sendable (Double) -> Void,
        written: Int64,
        of expectedTotal: Int64
    ) {
        guard expectedTotal > 0 else { return }
        progress(min(1.0, Double(written) / Double(expectedTotal)))
    }

    private static func sha256Hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256Digest()
        while let chunk = try handle.read(upToCount: 1 << 16), !chunk.isEmpty {
            digest.update(data: chunk)
        }
        return digest.finalizedHex()
    }

    #if !canImport(Darwin)
    /// corelibs-foundation lacks `URLSession.bytes`/async `data(for:)`; wrap the
    /// completion-handler API, which exists on every platform.
    private static func legacyData(
        session: URLSession,
        request: URLRequest
    ) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let response {
                    continuation.resume(returning: (data ?? Data(), response))
                } else {
                    continuation.resume(throwing: ModelDownloadError.notAnHTTPResponse)
                }
            }
            task.resume()
        }
    }
    #endif
}
