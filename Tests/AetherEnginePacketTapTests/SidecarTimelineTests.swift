import XCTest
@testable import AetherEngine

final class SidecarTimelineTests: XCTestCase {
    func testMovieRelativeBitmapPacketsAreIndexedAtSourceTimeBeforeDrain() async throws {
        func segment(_ seconds: UInt32, _ type: UInt8, _ payload: [UInt8]) -> [UInt8] {
            [0x50, 0x47] + withUnsafeBytes(of: (seconds * 90_000).bigEndian, Array.init)
                + [0, 0, 0, 0, type, 0, UInt8(payload.count)] + payload
        }
        let display = [UInt8](arrayLiteral: 0x07, 0x80, 0x04, 0x38, 0x10, 0, 0, 0x80, 0, 0, 1, 0, 0, 0, 0, 0, 32, 0, 64)
        let clear = Array(display.prefix(5)) + [0, 1, 0, 0, 0, 0]
        let window: [UInt8] = [1, 0, 0, 32, 0, 64, 0, 2, 0, 1]
        let palette: [UInt8] = [0, 0, 1, 200, 128, 128, 255]
        let object: [UInt8] = [0, 0, 0, 0xC0, 0, 0, 8, 0, 2, 0, 1, 1, 1, 0, 0]
        let segments = [segment(1, 0x16, display), segment(1, 0x17, window), segment(1, 0x14, palette),
                        segment(1, 0x15, object), segment(1, 0x80, []), segment(3, 0x16, clear),
                        segment(3, 0x80, [])]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).sup")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(segments.joined()).write(to: url)
        let decoded = try await SubtitleDecoder.decodeFile(url: url, keepsBitmapPackets: true, sourceOrigin: 612.5)
        let source = try XCTUnwrap(decoded.bitmapSource)
        let packets = source.packets
        XCTAssertEqual(packets.map(\.ptsSeconds), [613.5, 615.5])
        let decoder = try XCTUnwrap(source.makeDecoder(sourceIsPQ: true))
        let first = try XCTUnwrap(packets.first)
        let cue = try XCTUnwrap(AetherEngine.decodeStoredSubtitlePacket(first, with: decoder)?.cues.first)
        XCTAssertEqual(cue.startTime, 613.5, accuracy: 0.001)
        guard case .image(let image) = cue.body else { return XCTFail("Expected a decoded PGS bitmap") }
        XCTAssertEqual(image.canvasSize, CGSize(width: 1920, height: 1080))
        XCTAssertEqual(image.cgImage.width, 2)
    }

    func testEmbySidecarRequestRetainsItsURLAndAuthentication() async throws {
        let config = SidecarTextFetch.sessionConfiguration()
        config.protocolClasses = [EmbySubtitleProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let url = try XCTUnwrap(URL(string: "https://emby.test/Videos/1/source/Subtitles/3/0/Stream.srt?test=subtitle"))
        let temporary = try await SidecarTextFetch.download(url, headers: ["X-Emby-Token": "test-only"],
                                                           formatHint: "srt", session: session)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let result = try await SubtitleDecoder.decodeFile(url: temporary, sourceOrigin: 42)
        XCTAssertEqual(result.cues.first?.text, "Emby subtitle")
        XCTAssertEqual(result.cues.first?.startTime, 44)
    }

    func testRemoteVobSubDownloadsSiblingsAndDecodesTheDVDPicture() async throws {
        let config = SidecarTextFetch.sessionConfiguration()
        config.protocolClasses = [VobSubProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let input = try XCTUnwrap(URL(string: "https://emby.test/media/Synthetic%20Clip.sub?case=film"))
        let pair = try XCTUnwrap(SidecarTextFetch.vobSubPair(input))
        XCTAssertEqual(pair.index.absoluteString, "https://emby.test/media/Synthetic%20Clip.idx?case=film")
        let index = try await SidecarTextFetch.downloadVobSub(pair, headers: ["X-Emby-Token": "test-only"], session: session)
        defer { try? FileManager.default.removeItem(at: index.deletingLastPathComponent()) }
        let result = try await SubtitleDecoder.decodeFile(url: index, keepsBitmapPackets: true, sourceOrigin: 27)
        let source = try XCTUnwrap(result.bitmapSource)
        let packet = try XCTUnwrap(source.packets.first)
        XCTAssertEqual(packet.ptsSeconds, 28, accuracy: 0.01)
        let decoder = try XCTUnwrap(source.makeDecoder())
        let cue = try XCTUnwrap(AetherEngine.decodeStoredSubtitlePacket(packet, with: decoder)?.cues.first)
        guard case .image(let bitmap) = cue.body else { return XCTFail("Expected a VobSub bitmap") }
        XCTAssertEqual(bitmap.cgImage.width, 16)

        let oversized = try XCTUnwrap(URL(string: "https://emby.test/media/oversize.idx?case=limit"))
        let oversizePair = try XCTUnwrap(SidecarTextFetch.vobSubPair(oversized))
        do {
            _ = try await SidecarTextFetch.downloadVobSub(oversizePair, headers: ["X-Emby-Token": "test-only"], session: session)
            XCTFail("Accepted oversized companion")
        } catch let error as BoundedFetch.Exceeded {
            XCTAssertEqual(error.limit, SidecarBitmapSource.byteCap)
        }
    }

    func testStandaloneFormatsMapMovieTimeIntoSourcePTSAndDecodePlainLines() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixtures = [
            ("srt", "1\n00:00:01,000 --> 00:00:03,000\n臺灣\n字幕\n"),
            ("vtt", "WEBVTT\n\n00:00:01.000 --> 00:00:03.000\n臺灣\n字幕\n"),
            ("ass", """
             [Script Info]
             ScriptType: v4.00+
             [V4+ Styles]
             Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
             Style: Default,Arial,20,&H00FFFFFF,&H00FFFFFF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,1,0,2,10,10,10,1
             [Events]
             Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
             Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,{\\b1}臺灣\\N字幕

             """)
        ]
        for (ext, contents) in fixtures {
            let url = directory.appendingPathComponent("sample.\(ext)")
            try Data(contents.utf8).write(to: url)
            let decoded = try await SubtitleDecoder.decodeFile(url: url, preserveASSMarkup: false, sourceOrigin: 612.5)
            let cue = try XCTUnwrap(decoded.cues.first)
            XCTAssertEqual(cue.startTime, 613.5, accuracy: 0.01)
            XCTAssertEqual(cue.endTime, 615.5, accuracy: 0.01)
            XCTAssertEqual(cue.text, "臺灣\n字幕")
        }
    }
}

private final class EmbySubtitleProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "emby.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, url.path.hasSuffix("/3/0/Stream.srt"), url.query == "test=subtitle",
              request.value(forHTTPHeaderField: "X-Emby-Token") == "test-only",
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("1\n00:00:02,000 --> 00:00:04,000\nEmby subtitle\n".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class VobSubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "emby.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, request.value(forHTTPHeaderField: "X-Emby-Token") == "test-only" else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let data: Data
        let declared: Int
        if url.pathExtension == "idx" {
            data = Data("""
                # VobSub index file, v7 (do not modify this line!)
                size: 720x480
                palette: 000000, ffffff, 000000, 000000, 000000, 000000, 000000, 000000, 000000, 000000, 000000, 000000, 000000, 000000, 000000, 000000
                id: en, index: 0
                timestamp: 00:00:01:000, filepos: 000000000

                """.utf8)
            declared = data.count
        } else if url.query == "case=limit" {
            data = Data()
            declared = SidecarBitmapSource.byteCap + 1
        } else {
            // One original MPEG-PS sector carrying a 16×12 subtitle at (32, 64).
            let header = Data(base64Encoded: "AAABukQABAAEAYZmz/gAAAG7AAnDM2cAIP+9wIAAAAG9AEeAgQkhAANfkRBgEP8gADoAHAQQBBAEEAQQBBAEEAQQBBAEEAQQBBAEEAAAADQDAHAEAPAFAgAvBABLBgAEABAB////ADQC/wAAAb4HkA==")!
            data = header + Data(repeating: 0xff, count: 2048 - header.count)
            declared = data.count
        }
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Length": "\(declared)"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
