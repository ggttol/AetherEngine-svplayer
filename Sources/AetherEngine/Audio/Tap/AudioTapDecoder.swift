import Foundation
import AVFAudio
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil
import AetherLibswresample

/// One decoded PCM chunk in the tap's fixed format on the engine's source PTS axis.
struct AudioTapChunk {
    let buffer: AVAudioPCMBuffer
    let ptsSeconds: Double
    var channels: AudioTapChannels = .downmix
    var discontinuity = false
}

/// FFmpeg decoder for the audio tap (#95): compressed packets to mono Float32 16 kHz
/// `AVAudioPCMBuffer`s. Mirrors `AudioDecoder`'s lazy-resampler + lock discipline but with a
/// fixed swr output and a running sample clock (anchor + emitted/16000) so chunks abut exactly.
final class AudioTapDecoder: @unchecked Sendable {

    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private var swrContext: OpaquePointer?
    private let stateLock = NSLock()
    private var timeBase = AVRational(num: 1, den: 90_000)

    /// Running clock: PTS of the first decoded frame + samples emitted since. Re-anchored on
    /// a source PTS that diverges > 250 ms from the running position (seek within a session).
    private var anchorPTS: Double?
    private var samplesSinceAnchor: Int64 = 0

    private var pending: [Float] = []
    private var pendingStartPTS: Double = 0
    private var needsDiscontinuity = false

    /// What the current `swrContext` reads (#452). The tap outlives a live splice the same way the
    /// SW path does, and its output side is pinned to mono 16 kHz, so only the input can move.
    private var configuredInput = ResamplerInputParameters()

    /// What the host asked for, and what the current `swrContext` delivers: `.dialogue` falls
    /// back to `.downmix` on a layout without a centre channel (#908).
    private let requestedChannels: AudioTapChannels
    private var deliveredChannels: AudioTapChannels = .downmix

    init(channels: AudioTapChannels = .downmix) {
        requestedChannels = channels
    }

    enum TapDecoderError: Error, CustomStringConvertible, LocalizedError {
        case noCodecParameters, unsupportedCodec, allocFailed, openFailed

        var description: String {
            switch self {
            case .noCodecParameters: "AudioTapDecoder: stream has no codec parameters"
            case .unsupportedCodec: "AudioTapDecoder: no decoder for the tap codec"
            case .allocFailed: "AudioTapDecoder: avcodec_alloc_context3 failed"
            case .openFailed: "AudioTapDecoder: decoder open failed"
            }
        }

        var errorDescription: String? { description }
    }

    func open(stream: UnsafeMutablePointer<AVStream>) throws {
        guard let codecpar = stream.pointee.codecpar else { throw TapDecoderError.noCodecParameters }
        try open(parameters: codecpar, timeBase: stream.pointee.time_base)
    }

    // SVPlayer modification: the packet tap owns a copy of the demux track description.
    func open(parameters codecpar: UnsafePointer<AVCodecParameters>, timeBase: AVRational) throws {
        self.timeBase = timeBase
        guard let codec = avcodec_find_decoder(codecpar.pointee.codec_id) else {
            throw TapDecoderError.unsupportedCodec
        }
        guard let ctx = avcodec_alloc_context3(codec) else { throw TapDecoderError.allocFailed }
        codecContext = ctx
        ctx.pointee.pkt_timebase = timeBase
        guard avcodec_parameters_to_context(ctx, codecpar) >= 0,
              avcodec_open2(ctx, codec, nil) >= 0 else {
            avcodec_free_context(&codecContext)
            throw TapDecoderError.openFailed
        }
    }

    func decode(packet: UnsafeMutablePointer<AVPacket>) -> [AudioTapChunk] {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let ctx = codecContext else { return [] }
        var chunks: [AudioTapChunk] = []
        if (packet.pointee.flags & AV_PKT_FLAG_CORRUPT) != 0 {
            recover(ctx, code: FFmpegErr.invalidData, into: &chunks)
            return chunks
        }
        var sent = avcodec_send_packet(ctx, packet)
        if sent == FFmpegErr.eagain {
            chunks = receiveAll(ctx)
            sent = avcodec_send_packet(ctx, packet)
        }
        guard sent >= 0 else {
            recover(ctx, code: sent, into: &chunks)
            return chunks
        }
        chunks += receiveAll(ctx)
        return chunks
    }

    /// EOF drain: flush delay frames, then force-emit the sub-threshold tail.
    func drain() -> [AudioTapChunk] {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let ctx = codecContext else { return [] }
        avcodec_send_packet(ctx, nil)
        var chunks = receiveAll(ctx)
        if let tail = emitPending(force: true) { chunks.append(tail) }
        return chunks
    }

    func close() {
        stateLock.lock()
        defer { stateLock.unlock() }
        if codecContext != nil { avcodec_free_context(&codecContext) }
        if swrContext != nil { swr_free(&swrContext) }
        configuredInput.release()
        pending.removeAll()
        anchorPTS = nil
        samplesSinceAnchor = 0
        needsDiscontinuity = false
    }

    deinit { close() }

    // MARK: - Internals (all called with stateLock held)

    /// SVPlayer modification. Preserve good output before the hole and re-anchor on the next decoded PTS.
    private func recover(_ context: UnsafeMutablePointer<AVCodecContext>, code: Int32, into chunks: inout [AudioTapChunk]) {
        if let tail = emitPending(force: true) { chunks.append(tail) }
        if !needsDiscontinuity { EngineLog.emit("[AudioTap] recovering decode error code=\(code)", category: .engine) }
        avcodec_flush_buffers(context)
        if swrContext != nil { swr_free(&swrContext) }
        configuredInput.release()
        anchorPTS = nil
        samplesSinceAnchor = 0
        needsDiscontinuity = true
    }

    private func receiveAll(_ ctx: UnsafeMutablePointer<AVCodecContext>) -> [AudioTapChunk] {
        var chunks: [AudioTapChunk] = []
        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&frame) }
        guard let f = frame else { return [] }
        while true {
            let result = avcodec_receive_frame(ctx, f)
            guard result >= 0 else {
                if result != FFmpegErr.eagain, result != FFmpegErr.eof {
                    recover(ctx, code: result, into: &chunks)
                }
                break
            }
            if f.pointee.flags & AV_FRAME_FLAG_CORRUPT != 0 || (swrContext == nil && !initResampler(from: f)) {
                recover(ctx, code: FFmpegErr.invalidData, into: &chunks)
                break
            }
            // A mid-stream input change (5.1 to stereo at a live program boundary) leaves the context
            // reading planes the frame no longer carries, which faults inside swr_convert (#452).
            // The accumulator is already in the fixed output format and the running clock counts
            // output samples either way; it is flushed only so one chunk never carries two channel
            // selections (#908: a dialogue tap falls back to the downmix on the stereo side).
            if configuredInput.differ(from: f) {
                EngineLog.emit(
                    "[AudioTap] input format changed mid-stream ("
                    + "\(configuredInput.rate)Hz/\(configuredInput.layout.nb_channels)ch/fmt=\(configuredInput.format.rawValue)"
                    + " -> \(f.pointee.sample_rate)Hz/\(f.pointee.ch_layout.nb_channels)ch/fmt=\(f.pointee.format)"
                    + "); rebuilding resampler",
                    category: .engine)
                if let tail = emitPending(force: true) { chunks.append(tail) }
                swr_free(&swrContext)
                guard initResampler(from: f) else {
                    recover(ctx, code: FFmpegErr.invalidData, into: &chunks)
                    break
                }
            }
            guard ingest(frame: f) else {
                recover(ctx, code: FFmpegErr.invalidData, into: &chunks)
                break
            }
            if pending.count >= AudioTapDefaults.minSamplesPerChunk,
               let chunk = emitPending(force: false) {
                chunks.append(chunk)
            }
        }
        return chunks
    }

    private func initResampler(from frame: UnsafeMutablePointer<AVFrame>) -> Bool {
        var outLayout = AVChannelLayout()
        av_channel_layout_default(&outLayout, 1)
        var inLayout = AVChannelLayout()
        if frame.pointee.ch_layout.nb_channels > 0 {
            av_channel_layout_copy(&inLayout, &frame.pointee.ch_layout)
        } else {
            av_channel_layout_default(&inLayout, 2)
        }
        // copy() allocates a channel map for custom-order layouts; uninit or that map leaks.
        defer {
            av_channel_layout_uninit(&inLayout)
            av_channel_layout_uninit(&outLayout)
        }
        let ret = swr_alloc_set_opts2(
            &swrContext,
            &outLayout, AV_SAMPLE_FMT_FLT, Int32(AudioTapDefaults.sampleRate),
            &inLayout, AVSampleFormat(rawValue: frame.pointee.format), frame.pointee.sample_rate,
            0, nil
        )
        guard ret >= 0, swrContext != nil else {
            if swrContext != nil { swr_free(&swrContext) }
            return false
        }
        deliveredChannels = .downmix
        if requestedChannels == .dialogue, let centre = Self.centreIndex(of: &inLayout) {
            // One output row: the centre at unity, every other input channel at zero.
            var matrix = [Double](repeating: 0, count: Int(inLayout.nb_channels))
            matrix[centre] = 1
            if swr_set_matrix(swrContext, matrix, inLayout.nb_channels) >= 0 {
                deliveredChannels = .dialogue
            }
        }
        guard swr_init(swrContext) >= 0 else {
            swr_free(&swrContext)
            return false
        }
        // What this context reads; every later frame is compared against it (#452).
        configuredInput.adopt(
            layout: &inLayout,
            format: AVSampleFormat(rawValue: frame.pointee.format),
            rate: frame.pointee.sample_rate
        )
        return true
    }

    /// See `frontCentreIndex(of:)`.
    static func centreIndex(of layout: UnsafePointer<AVChannelLayout>) -> Int? {
        frontCentreIndex(of: layout)
    }

    private func ingest(frame f: UnsafeMutablePointer<AVFrame>) -> Bool {
        guard let swr = swrContext, f.pointee.nb_samples > 0 else { return false }
        // Corrupt live MPEG-TS decodes to a frame with samples but a NULL plane and declares no
        // change; swr_convert dereferences it (#452).
        guard configuredInput.framePlanesArePresent(f) else { return false }

        let framePTS: Double? = f.pointee.pts != Int64.min && timeBase.den > 0
            ? Double(f.pointee.pts) * Double(timeBase.num) / Double(timeBase.den)
            : nil
        let runningPTS = anchorPTS.map { $0 + Double(samplesSinceAnchor) / AudioTapDefaults.sampleRate }
        // SVPlayer modification: await a real source timestamp when opening a new seek generation.
        guard anchorPTS != nil || framePTS != nil else { return true }
        if anchorPTS == nil || (framePTS != nil && runningPTS != nil && abs(framePTS! - runningPTS!) > 0.25) {
            // First frame, or a real discontinuity: drop the misplaced tail and re-anchor.
            if anchorPTS != nil { needsDiscontinuity = true }
            pending.removeAll(keepingCapacity: true)
            anchorPTS = framePTS ?? 0
            samplesSinceAnchor = 0
        }
        if pending.isEmpty {
            pendingStartPTS = anchorPTS! + Double(samplesSinceAnchor) / AudioTapDefaults.sampleRate
        }

        let maxOut = Int(swr_get_out_samples(swr, f.pointee.nb_samples))
        guard maxOut > 0 else { return maxOut == 0 }
        var out = [Float](repeating: 0, count: maxOut)
        let converted: Int32 = out.withUnsafeMutableBytes { raw in
            var outPtr: UnsafeMutablePointer<UInt8>? =
                raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            return withUnsafeMutablePointer(to: &outPtr) { outBuf in
                let srcData = UnsafePointer<UnsafePointer<UInt8>?>(
                    OpaquePointer(f.pointee.extended_data)
                )
                return swr_convert(swr, outBuf, Int32(maxOut), srcData, f.pointee.nb_samples)
            }
        }
        guard converted > 0 else { return converted == 0 }
        pending.append(contentsOf: out.prefix(Int(converted)))
        samplesSinceAnchor += Int64(converted)
        return true
    }

    private func emitPending(force: Bool) -> AudioTapChunk? {
        guard !pending.isEmpty, force || pending.count >= AudioTapDefaults.minSamplesPerChunk else {
            return nil
        }
        guard let buf = AVAudioPCMBuffer(pcmFormat: AetherEngine.audioTapFormat,
                                         frameCapacity: AVAudioFrameCount(pending.count)) else {
            pending.removeAll(keepingCapacity: true)
            return nil
        }
        buf.frameLength = AVAudioFrameCount(pending.count)
        pending.withUnsafeBufferPointer { src in
            buf.floatChannelData![0].update(from: src.baseAddress!, count: src.count)
        }
        let chunk = AudioTapChunk(buffer: buf, ptsSeconds: pendingStartPTS, channels: deliveredChannels,
                                  discontinuity: needsDiscontinuity)
        needsDiscontinuity = false
        pendingStartPTS += Double(pending.count) / AudioTapDefaults.sampleRate
        pending.removeAll(keepingCapacity: true)
        return chunk
    }
}

