import Foundation
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil

/// SVPlayer modification. Retain references to the selected demux packets so a newly installed
/// tap can replay audio the playback pipeline already read. No decoding runs on a playback thread.
final class AudioPacketWindow: @unchecked Sendable {
    private struct Identity: Hashable {
        let pts: Int64
        let bytes: Int32
        let prefix: UInt64

        init?(_ source: UnsafeMutablePointer<AVPacket>) {
            let value = source.pointee
            pts = value.pts != Int64.min ? value.pts : value.dts
            guard pts != Int64.min else { return nil }
            bytes = value.size
            prefix = bytes >= 8 && value.data != nil ? UnsafeRawPointer(value.data!).loadUnaligned(as: UInt64.self) : 0
        }
    }

    struct Format: @unchecked Sendable {
        let parameters: HLSVideoEngine.OwnedCodecParameters
        let timeBase: AVRational
        let streamIndex: Int32
        let version: UInt64
    }

    final class Packet: @unchecked Sendable {
        let pointer: UnsafeMutablePointer<AVPacket>
        let start: Double
        let end: Double
        let byteCount: Int

        init?(copying source: UnsafeMutablePointer<AVPacket>, timeBase: AVRational,
              offset: Int64, previousEnd: Double?) {
            guard let copy = av_packet_clone(source) else { return nil }
            pointer = copy
            let secondsPerTick = Double(timeBase.num) / Double(timeBase.den)
            if copy.pointee.pts != Int64.min {
                copy.pointee.pts = SourceTimestampBounds.sum(copy.pointee.pts, offset)
            }
            if copy.pointee.dts != Int64.min {
                copy.pointee.dts = SourceTimestampBounds.sum(copy.pointee.dts, offset)
                if copy.pointee.pts == Int64.min { copy.pointee.pts = copy.pointee.dts }
            }
            start = copy.pointee.pts != Int64.min ? Double(copy.pointee.pts) * secondsPerTick
                : previousEnd ?? -.infinity
            end = start + Double(max(0, copy.pointee.duration)) * secondsPerTick
            let sideBytes = (0..<Int(copy.pointee.side_data_elems)).reduce(0) {
                $0 + copy.pointee.side_data[$1].size
            }
            byteCount = max(1, Int(copy.pointee.size) + sideBytes)
        }

        deinit {
            var owned: UnsafeMutablePointer<AVPacket>? = pointer
            av_packet_free(&owned)
        }
    }

    private let lock = NSLock()
    private let capacity = 65_536
    private let byteLimit = 32 * 1024 * 1024
    private var slots: [Packet?] = []
    private var firstID = 0
    private var nextID = 0
    private var bytes = 0
    private var epoch: UInt64 = 0
    private var configuration: Format?
    private var previousEnd: Double?
    private var lastPacketStart: Double?
    private var ended = false
    private var playbackEnded = false
    private var offsetTicks: Int64 = 0
    private let deduplicatesReplay: Bool
    private var resident: [Identity: Int] = [:]

    init(deduplicatesReplay: Bool = false) {
        self.deduplicatesReplay = deduplicatesReplay
    }

    var format: Format? { lock.withLock { configuration } }
    var sourceOffset: Int64 { lock.withLock { offsetTicks } }
    var latestSourceEnd: Double? { lock.withLock { previousEnd } }

    func configure(stream: UnsafeMutablePointer<AVStream>, epoch: UInt64, sameSourceAcrossEpochs: Bool = true) {
        guard let parameters = stream.pointee.codecpar,
              let owned = HLSVideoEngine.OwnedCodecParameters(copying: parameters) else { return }
        let timeBase = stream.pointee.time_base
        guard timeBase.num > 0, timeBase.den > 0 else { return }
        lock.withLock {
            guard epoch >= self.epoch else { return }
            let newEpoch = epoch != self.epoch
            if newEpoch {
                previousEnd = nil
                lastPacketStart = nil
                ended = false
                playbackEnded = false
            }
            self.epoch = epoch
            if (!newEpoch || sameSourceAcrossEpochs), let format = configuration, stream.pointee.index == format.streamIndex,
               format.timeBase.num == timeBase.num, format.timeBase.den == timeBase.den,
               Self.sameCodec(owned.ptr, format.parameters.ptr) { return }
            clear()
            configuration = Format(parameters: owned, timeBase: timeBase, streamIndex: stream.pointee.index,
                                   version: (configuration?.version ?? 0) &+ 1)
        }
    }

    private static func sameCodec(_ lhs: UnsafePointer<AVCodecParameters>,
                                  _ rhs: UnsafePointer<AVCodecParameters>) -> Bool {
        guard lhs.pointee.codec_id == rhs.pointee.codec_id,
              lhs.pointee.sample_rate == rhs.pointee.sample_rate,
              lhs.pointee.ch_layout.nb_channels == rhs.pointee.ch_layout.nb_channels,
              lhs.pointee.extradata_size == rhs.pointee.extradata_size else { return false }
        guard lhs.pointee.extradata_size > 0 else { return true }
        guard let left = lhs.pointee.extradata, let right = rhs.pointee.extradata else { return false }
        return memcmp(left, right, Int(lhs.pointee.extradata_size)) == 0
    }

    func append(_ source: UnsafeMutablePointer<AVPacket>, offset: Int64 = 0, epoch: UInt64 = 0,
                replay: Bool = false) {
        lock.withLock {
            guard epoch == self.epoch, let format = configuration,
                  source.pointee.stream_index == format.streamIndex else { return }
            let identity = deduplicatesReplay ? Identity(source) : nil
            if replay, let identity, resident[identity] != nil { return }
            guard let packet = Packet(copying: source, timeBase: format.timeBase, offset: offset,
                                      previousEnd: previousEnd), packet.start.isFinite,
                  packet.byteCount <= byteLimit else { return }
            previousEnd = packet.end
            lastPacketStart = packet.start
            ended = false
            offsetTicks = offset
            if slots.isEmpty { slots = Array(repeating: nil, count: capacity) }
            while firstID < nextID, let oldest = slots[firstID % capacity],
                  nextID - firstID >= capacity || bytes + packet.byteCount > byteLimit
                    || packet.start - oldest.end > 120 {
                bytes -= oldest.byteCount
                if deduplicatesReplay, let key = Identity(oldest.pointer), let count = resident[key] {
                    if count > 1 { resident[key] = count - 1 } else { resident.removeValue(forKey: key) }
                }
                slots[firstID % capacity] = nil
                firstID += 1
            }
            slots[nextID % capacity] = packet
            nextID += 1
            bytes += packet.byteCount
            if let identity { resident[identity, default: 0] += 1 }
        }
    }

    struct Cursor {
        var nextID: Int?
        var deferredID: Int?
        var deferredTime = Double.infinity
    }

    func finish(epoch: UInt64 = 0) {
        lock.withLock { if self.epoch == epoch { ended = true } }
    }

    func setPlaybackEnded(_ value: Bool) {
        lock.withLock { playbackEnded = value }
    }

    func hasEnded(at sourceTime: Double) -> Bool {
        lock.withLock {
            if playbackEnded { return true }
            guard ended else { return false }
            guard let lastPacketStart else { return true }
            return sourceTime >= lastPacketStart
        }
    }

    /// Skip a previous seek's far-future tail while looking for newly appended landing packets.
    /// Revisit that tail when it falls in the interval requested by the recognizer.
    func next(cursor: inout Cursor, from floor: Double, through ceiling: Double,
              version: UInt64) -> Packet? {
        lock.withLock {
            guard configuration?.version == version, firstID < nextID else { return nil }
            if let deferred = cursor.deferredID, cursor.deferredTime <= ceiling {
                cursor.nextID = min(cursor.nextID ?? firstID, deferred)
                cursor.deferredID = nil
                cursor.deferredTime = .infinity
            }
            var index = max(firstID, cursor.nextID ?? firstID)
            while index < nextID {
                let current = index
                index += 1
                guard let candidate = slots[current % capacity], candidate.end >= floor else { continue }
                if candidate.start <= ceiling {
                    cursor.nextID = index
                    return candidate
                }
                if candidate.start < cursor.deferredTime {
                    cursor.deferredID = current
                    cursor.deferredTime = candidate.start
                }
            }
            cursor.nextID = index
            return nil
        }
    }

    private func clear() {
        slots.removeAll()
        resident.removeAll()
        firstID = nextID
        previousEnd = nil
        lastPacketStart = nil
        ended = false
        playbackEnded = false
        offsetTicks = 0
        bytes = 0
    }
}
