import Foundation

/// SVPlayer modification. A seek discards queued PCM. At natural EOF the recognizer can consume
/// the queued tail before its input ends. AsyncStream.Continuation.finish() alone drains in both cases.
private final class AudioTapMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = [AudioTapBuffer?](repeating: nil, count: 1024)
    private var head = 0
    private var count = 0
    private var closed = false
    private var readers: [CheckedContinuation<AudioTapBuffer?, Never>] = []

    func offer(_ buffer: AudioTapBuffer) -> Bool {
        lock.lock()
        guard !closed else { lock.unlock(); return false }
        if !readers.isEmpty {
            let reader = readers.removeFirst()
            lock.unlock()
            reader.resume(returning: buffer)
            return true
        }
        guard count < storage.count else { lock.unlock(); return false }
        storage[(head + count) % storage.count] = buffer
        count += 1
        lock.unlock()
        return true
    }

    func next() async -> AudioTapBuffer? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if count > 0 {
                let buffer = storage[head]
                storage[head] = nil
                head = (head + 1) % storage.count
                count -= 1
                lock.unlock()
                continuation.resume(returning: buffer)
            } else if closed {
                lock.unlock()
                continuation.resume(returning: nil)
            } else {
                readers.append(continuation)
                lock.unlock()
            }
        }
    }

    func close(discard: Bool) {
        lock.lock()
        closed = true
        if discard {
            storage.removeAll()
            head = 0
            count = 0
        }
        let waiting = readers
        readers.removeAll()
        lock.unlock()
        for reader in waiting { reader.resume(returning: nil) }
    }
}

@MainActor
final class AudioTapController {
    var readProgress: (() -> AudioTapProgress)?
    typealias StartReader = (_ onStop: (@escaping () -> Void) -> Void) -> Void
    private let mailbox = AudioTapMailbox()
    private var filter: AudioTapMonotonicFilter?
    private var stopReader: (() -> Void)?

    func makeStream(startReader: StartReader) -> AsyncStream<AudioTapBuffer> {
        let mailbox = self.mailbox
        filter = AudioTapMonotonicFilter { buffer in mailbox.offer(buffer) }
        let stream = AsyncStream<AudioTapBuffer>(unfolding: {
            await mailbox.next()
        }, onCancel: { [weak self] in
            mailbox.close(discard: true)
            Task { @MainActor in self?.teardown() }
        })
        startReader { [weak self] stop in self?.stopReader = stop }
        return stream
    }

    func makeYield() -> (@Sendable (AudioTapBuffer) -> Void)? {
        guard let filter else { return nil }
        return { buffer in filter.accept(buffer) }
    }

    var hasDeliverySource: Bool { stopReader != nil }

    func finishInput() {
        mailbox.close(discard: false)
        stopReader?()
        stopReader = nil
        filter = nil
    }

    func teardown() {
        mailbox.close(discard: true)
        readProgress = nil
        stopReader?()
        stopReader = nil
        filter = nil
    }
}
