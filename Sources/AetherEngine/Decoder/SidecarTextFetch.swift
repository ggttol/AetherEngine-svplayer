// Modified by SVPlayer on 2026-11-20.
import Foundation

/// AE#984: a text sidecar (SRT, WebVTT, ASS/SSA) over HTTP is read with ONE plain GET for the whole
/// body, then decoded from a private temporary file.
///
/// It used to borrow the playback reader, which is tuned for a multi-gigabyte container and none of
/// whose habits fit a file of a few kilobytes. Its open sends the speculative tail range and the
/// `bytes=0-` data range at once, so every sidecar cost two concurrent requests. And when the first
/// byte took longer than 15 s it dropped that request and asked again with a 25 s budget, so a server
/// that needs 25 s or more to produce the file (Jellyfin extracting a subtitle stream on demand, a
/// busy proxy) could never deliver it: the answer to the first request arrived on a connection
/// already abandoned, and the second one ran out before its own answer came.
///
/// Containers (an MKV or MKS holding several streams, #266) and bitmap sidecars (`.sup`, #921) stay
/// on the reader: they can be far too large to hold, and their parse seeks.
enum SidecarTextFetch {

    /// A styled ASS with embedded fonts reaches a few megabytes; a text sidecar past this is not one.
    static let maximumBodyBytes = 64 * 1024 * 1024

    /// No byte for this long ends the fetch. Generous on purpose: a sidecar is optional, nothing
    /// waits on it but its own track, and a server that extracts the stream first answers late.
    static let requestTimeout: TimeInterval = 120

    /// The whole transfer, waiting included.
    static let resourceTimeout: TimeInterval = 300

    static let textExtensions: Set<String> = ["srt", "subrip", "vtt", "webvtt", "ass", "ssa"]

    /// True for an http(s) URL whose format (the host's hint first, else the path extension) is a
    /// text format.
    static func appliesTo(_ url: URL, formatHint: String?) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        return textExtensions.contains((formatHint ?? url.pathExtension).lowercased())
    }

    static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }

    /// Owned and process-wide: an uninvalidated session outlives its caller, and the trust delegate
    /// is what lets a host's certificate decision reach this fetch.
    static let session = URLSession(
        configuration: sessionConfiguration(), delegate: EngineTLS.sessionDelegate, delegateQueue: nil)

    /// SVPlayer modification. VobSub opens its SUB next to its IDX using a file name derived by
    /// libavformat. Keep both requests on the registered origin, preserving the encoded path and query.
    static func vobSubPair(_ url: URL) -> (index: URL, payload: URL)? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return nil }
        let path = parts.percentEncodedPath
        guard path.lowercased().hasSuffix(".idx") || path.lowercased().hasSuffix(".sub") else { return nil }
        let upper = path.suffix(3) == path.suffix(3).uppercased()
        parts.percentEncodedPath = path.dropLast(3) + (upper ? "IDX" : "idx")
        guard let index = parts.url else { return nil }
        parts.percentEncodedPath = path.dropLast(3) + (upper ? "SUB" : "sub")
        guard let payload = parts.url else { return nil }
        return (index, payload)
    }

    static func downloadVobSub(_ pair: (index: URL, payload: URL), headers: [String: String],
                               session: URLSession = session) async throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aether-vobsub-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let index = directory.appendingPathComponent("captions.idx")
        do {
            for (remote, local, limit) in [(pair.index, index, 8 * 1024 * 1024),
                                           (pair.payload, directory.appendingPathComponent("captions.sub"), SidecarBitmapSource.byteCap)] {
                try Task.checkCancellation()
                var request = URLRequest(engineURL: remote)
                for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
                let response = try await BoundedFetch.file(for: request, session: session, limit: limit, to: local)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                guard (200..<300).contains(status) else { throw SubtitleDecoderError.httpStatus(status) }
                if local == index {
                    let handle = try FileHandle(forReadingFrom: index)
                    defer { try? handle.close() }
                    let prefix = try handle.read(upToCount: 96) ?? Data()
                    guard String(decoding: prefix, as: UTF8.self).contains("VobSub index file") else {
                        throw SubtitleDecoderError.noSubtitleStream
                    }
                }
            }
            try Task.checkCancellation()
            return index
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// The whole body, written to a temporary file named with the sidecar's own extension so
    /// libavformat probes it exactly as it probed the URL. The caller removes the file.
    static func download(_ url: URL, headers: [String: String], formatHint: String?,
                         session: URLSession = session) async throws -> URL {
        var request = URLRequest(engineURL: url)
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await BoundedFetch.data(
                for: request, session: session, limit: maximumBodyBytes)
        } catch is BoundedFetch.Exceeded {
            throw SubtitleDecoderError.textLimitExceeded
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else { throw SubtitleDecoderError.httpStatus(status) }
        try Task.checkCancellation()
        let ext = (formatHint ?? url.pathExtension).lowercased()
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("aether-sidecar-\(UUID().uuidString)")
            .appendingPathExtension(textExtensions.contains(ext) ? ext : "txt")
        try data.write(to: file, options: .atomic)
        return file
    }
}
