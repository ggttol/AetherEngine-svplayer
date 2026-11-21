// Modified by SVPlayer on 2026-11-20.
import Foundation
import AetherLibavformat

// SVPlayer modification: the independent still decoder reads one seekable container.
// HTTP files and each resource of a selected HLS segment share the capture's cancellation.
@_spi(SVPlayer) public final class FrameCaptureInput {
    public let reader: IOReader
    public let elapsedSeconds: Double
    public let isSeekable: Bool
    private let loader: Loader

    public init(url: URL, seconds: Double, userAgent: String?, deadline: DispatchTime,
                cancellation: ProbeCancellation, configuration: URLSessionConfiguration = .ephemeral) throws {
        let loader = try Loader(url: url, userAgent: userAgent, deadline: deadline,
                                cancellation: cancellation, configuration: configuration)
        let input = try loader.resolve(seconds: seconds.isFinite ? max(0, seconds) : 0)
        self.loader = loader
        reader = input.reader
        elapsedSeconds = input.seconds
        isSeekable = (input.reader as? Resource)?.source.isSeekable ?? true
    }

    private final class Resource: IOReader, @unchecked Sendable {
        let source: AVIOReader
        let control: ProbeControl
        let base: Int64
        var length: Int64 = 0
        private var position: Int64 = 0

        init(url: URL, headers: [String: String], range: HLSByteRange?, control: ProbeControl, session: URLSession) {
            self.control = control
            base = Int64(range?.offset ?? 0)
            source = AVIOReader(url: url, extraHeaders: headers, label: "frame-capture", chunkSize: 256 * 1024,
                                prefetchEnabled: false, chunkRequestTimeout: control.remainingTime ?? 3,
                                chunkMaxRetries: 1, streamHighWater: 4 * 1024 * 1024,
                                probeControl: control, probeRequestSession: session)
            control.interrupt { [source] in source.markClosed() }
        }

        func open(range: HLSByteRange?) throws -> (url: URL, prefix: Data) {
            let head = try source.openCaptureRange(start: base, length: range?.length)
            let size = source.seek(offset: 0, whence: AVSEEK_SIZE)
            length = range.map { Int64($0.length) } ?? size
            if size >= 0, base > size || length > size - base { throw ProbeError.invalidReaderResult }
            if !source.isSeekable, base > 0 {
                var scratch = [UInt8](repeating: 0, count: 32 * 1024)
                var remaining = base
                while remaining > 0 {
                    try control.check()
                    let count = source.read(into: &scratch, size: Int32(min(Int64(scratch.count), remaining)))
                    guard count > 0 else { throw ProbeError.invalidReaderResult }
                    remaining -= Int64(count)
                }
            }
            return head
        }

        func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
            guard let buffer, size >= 0, !control.isStopped else { return -1 }
            let wanted = length >= 0 ? min(Int64(size), length - position) : Int64(size)
            guard wanted > 0 else { return 0 }
            let count = source.read(into: buffer, size: Int32(wanted))
            if count == FFmpegErr.eof, length < 0 { return 0 }
            guard count > 0 else { return -1 }
            position += Int64(count)
            return count
        }

        func seek(offset: Int64, whence: Int32) -> Int64 {
            guard !control.isStopped else { return -1 }
            let origin: Int64
            switch whence & ~AVSEEK_FORCE {
            case AVSEEK_SIZE: return length
            case SEEK_SET: origin = 0
            case SEEK_CUR: origin = position
            case SEEK_END where length >= 0: origin = length
            default: return -1
            }
            let (next, overflow) = origin.addingReportingOverflow(offset)
            let (absolute, absoluteOverflow) = base.addingReportingOverflow(next)
            if !source.isSeekable, next != position { return -1 }
            guard !overflow, !absoluteOverflow, next >= 0, (length < 0 || next <= length),
                  source.seek(offset: absolute, whence: SEEK_SET) == absolute else { return -1 }
            position = next
            return next
        }

        func allBytes(limit: Int) throws -> Data {
            guard length <= Int64(limit) else { throw ProbeError.inputLimit }
            var bytes = Data()
            if length > 0 { bytes.reserveCapacity(Int(length)) }
            var block = [UInt8](repeating: 0, count: min(limit + 1, 64 * 1024))
            while length < 0 || bytes.count < length {
                let size = Int32(min(block.count, limit + 1 - bytes.count))
                let count = read(&block, size: size)
                if count == 0, length < 0 { break }
                guard count > 0 else { throw ProbeError.invalidReaderResult }
                guard bytes.count + Int(count) <= limit else { throw ProbeError.inputLimit }
                bytes.append(contentsOf: block.prefix(Int(count)))
            }
            return bytes
        }

        func close() {
            control.finish()
            source.markClosed()
            source.finishProbeTransfers()
            source.close()
        }
    }

    private final class Loader {
        let root: URL
        let headers: [String: String]
        let deadline: DispatchTime
        let cancellation: ProbeCancellation
        let session: URLSession
        var resources: [Resource] = []

        init(url: URL, userAgent: String?, deadline: DispatchTime,
             cancellation: ProbeCancellation, configuration: URLSessionConfiguration) throws {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true),
                  let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  components.host != nil else { throw ProbeError.unsupportedURL }
            var headers = ["Accept-Encoding": "identity",
                           "User-Agent": userAgent.flatMap { $0.isEmpty ? nil : $0 } ?? "SVPlayer-FrameCapture"]
            if let user = components.user {
                headers["Authorization"] = "Basic " + Data("\(user):\(components.password ?? "")".utf8).base64EncodedString()
                components.user = nil
                components.password = nil
            }
            guard let root = components.url else { throw ProbeError.unsupportedURL }
            self.root = root
            self.headers = headers
            self.deadline = deadline
            self.cancellation = cancellation
            session = URLSession(configuration: configuration, delegate: EngineTLS.sessionDelegate, delegateQueue: nil)
        }

        func open(_ url: URL, range: HLSByteRange? = nil) throws -> (resource: Resource, url: URL, prefix: Data) {
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
                  url.user == nil, url.password == nil else { throw ProbeError.unsupportedURL }
            let now = DispatchTime.now().uptimeNanoseconds
            guard deadline.uptimeNanoseconds > now else { throw ProbeError.timedOut }
            let remaining = Double(deadline.uptimeNanoseconds - now) / 1e9
            let control = try ProbeControl(limits: .init(timeBudget: remaining), cancellation: cancellation)
            let scoped = RedirectHeaderPolicy.scoped(headers, grantedFor: root, sentTo: url)
            let resource = Resource(url: url, headers: scoped, range: range, control: control, session: session)
            resources.append(resource)
            let head = try resource.open(range: range)
            return (resource, head.url, head.prefix)
        }

        func resolve(seconds: Double) throws -> (reader: IOReader, seconds: Double) {
            var url = root
            for depth in 0..<5 {
                let head = try open(url)
                guard AVIOReader.bodyBeginsWithHLSPlaylistTag(Array(head.prefix.prefix(64))) else {
                    guard depth == 0 else { throw ProbeError.invalidReaderResult }
                    return (head.resource, seconds)
                }
                let manifest = try head.resource.allBytes(limit: 4 * 1024 * 1024)
                let playlist = try HLSPlaylistParser.parse(String(decoding: manifest, as: UTF8.self))
                switch playlist {
                case .master(let master):
                    guard let variant = master.variants.max(by: { $0.bandwidth < $1.bandwidth }),
                          let child = HLSPlaylistParser.resolve(uri: variant.uri, against: head.url) else {
                        throw ProbeError.invalidReaderResult
                    }
                    url = child
                case .media(let media):
                    guard !media.hasUnsupportedEncryption else { throw ProbeError.unsupportedURL }
                    var elapsed = seconds
                    for (index, segment) in media.segments.enumerated() {
                        if elapsed < segment.duration || index == media.segments.count - 1 {
                            let part = try part(segment.uri, range: segment.byteRange, crypt: segment.crypt, base: head.url)
                            guard let map = segment.initialization else { return (part, elapsed) }
                            let initialization = try self.part(map.uri, range: map.byteRange, crypt: map.crypt, base: head.url)
                            func section(_ input: IOReader, limit: Int) throws -> (IOReader, Int64) {
                                if let file = input as? Resource, !file.source.isSeekable || file.length < 0 {
                                    let bytes = try file.allBytes(limit: limit)
                                    return (DataIOReader(data: bytes), Int64(bytes.count))
                                }
                                let size = input.seek(offset: 0, whence: AVSEEK_SIZE)
                                guard size > 0 else { throw ProbeError.invalidReaderResult }
                                return (input, size)
                            }
                            let (initInput, initSize) = try section(initialization, limit: 4 * 1024 * 1024)
                            let (mediaInput, mediaSize) = try section(part, limit: 64 * 1024 * 1024)
                            let parts = ["init": initInput, "media": mediaInput]
                            let sections = [MultiFileConcatIOReader.Segment(path: "init", size: initSize),
                                            MultiFileConcatIOReader.Segment(path: "media", size: mediaSize)]
                            return (MultiFileConcatIOReader(segments: sections) { parts[$0] }, elapsed)
                        }
                        elapsed -= max(0, segment.duration)
                    }
                    throw ProbeError.invalidReaderResult
                }
            }
            throw ProbeError.invalidReaderResult
        }

        func part(_ uri: String, range: HLSByteRange?, crypt: HLSSegmentCrypt?, base: URL) throws -> IOReader {
            guard let url = HLSPlaylistParser.resolve(uri: uri, against: base) else { throw ProbeError.unsupportedURL }
            let file = try open(url, range: range).resource
            guard let crypt else { return file }
            guard let keyURL = HLSPlaylistParser.resolve(uri: crypt.keyURI, against: base) else {
                throw ProbeError.unsupportedURL
            }
            let key = try open(keyURL).resource.allBytes(limit: 16)
            let encrypted = try file.allBytes(limit: 64 * 1024 * 1024)
            guard let plaintext = HLSSegmentDecryptor.decryptAES128CBC(encrypted, key: key, iv: crypt.iv) else {
                throw ProbeError.invalidReaderResult
            }
            return DataIOReader(data: plaintext)
        }

        deinit {
            for resource in resources { resource.close() }
            session.invalidateAndCancel()
        }
    }
}
