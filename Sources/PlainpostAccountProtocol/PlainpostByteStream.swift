import Foundation

/// A single-producer, single-consumer byte stream with bounded storage.
/// Producers suspend when the buffer is full; consumers suspend while empty.
public final class PlainpostByteStream: AsyncSequence, @unchecked Sendable {
    public typealias Element = Data

    @_spi(Testing)
    public enum SuspensionEvent: Sendable, Equatable {
        case sender(sequence: Int)
        case receiver
    }

    public final class Producer: @unchecked Sendable {
        private let channel: Channel

        fileprivate init(channel: Channel) { self.channel = channel }

        public func send(_ value: Data) async throws { try await channel.send(value) }
        public func finish() { Task { await channel.finish() } }
        public func fail(_ error: Error) { Task { await channel.fail(error) } }
    }

    public final class Iterator: AsyncIteratorProtocol {
        private let channel: Channel
        private let cancellation: CancellationSignal

        fileprivate init(channel: Channel, cancellation: CancellationSignal) {
            self.channel = channel
            self.cancellation = cancellation
        }

        deinit {
            cancellation.fire()
            let channel = self.channel
            Task { await channel.cancelConsumer() }
        }

        public func next() async throws -> Data? { try await channel.next() }

        /// Explicitly releases consumer ownership of the stream. This is the
        /// deterministic counterpart to iterator lifetime cleanup and lets a
        /// consumer stop before draining the sequence without waiting for
        /// ARC/deinitialization.
        public func cancel() {
            cancellation.fire()
            let channel = channel
            Task { await channel.cancelConsumer() }
        }
    }

    public let producer: Producer
    private let channel: Channel
    private let cancellation: CancellationSignal

    public convenience init(capacity: Int = 2) {
        self.init(capacity: capacity, onCancellation: nil)
    }

    public convenience init(capacity: Int, onCancellation: (@Sendable () -> Void)?) {
        self.init(capacity: capacity, onCancellation: onCancellation, onSuspension: nil)
    }

    @_spi(Testing)
    public init(
        capacity: Int,
        onCancellation: (@Sendable () -> Void)?,
        onSuspension: (@Sendable (SuspensionEvent) -> Void)?
    ) {
        precondition(capacity > 0)
        let cancellation = CancellationSignal(onCancellation)
        let channel = Channel(capacity: capacity, onCancellation: cancellation.fire, onSuspension: onSuspension)
        self.channel = channel
        self.cancellation = cancellation
        producer = Producer(channel: channel)
    }

    /// Explicitly cancels the consumer side and invokes the cancellation
    /// owner at most once.
    public func cancel() {
        cancellation.fire()
        let channel = channel
        Task { await channel.cancelConsumer() }
    }

    public func makeAsyncIterator() -> Iterator { Iterator(channel: channel, cancellation: cancellation) }

    fileprivate final class CancellationSignal: @unchecked Sendable {
        private let lock = NSLock()
        private var didFire = false
        private let callback: (@Sendable () -> Void)?

        init(_ callback: (@Sendable () -> Void)?) { self.callback = callback }

        func fire() {
            lock.lock()
            guard !didFire else {
                lock.unlock()
                return
            }
            didFire = true
            lock.unlock()
            callback?()
        }
    }

    fileprivate actor Channel {
        private let capacity: Int
        private let onCancellation: (@Sendable () -> Void)?
        private let onSuspension: (@Sendable (SuspensionEvent) -> Void)?
        private var values: [Data] = []
        private var senders: [PendingSender] = []
        private var receivers: [CheckedContinuation<Data?, Error>] = []
        private var terminal: Terminal?
        private var nextSenderSequence = 1

        private struct PendingSender {
            let value: Data
            let continuation: CheckedContinuation<Void, Error>
        }

        init(
            capacity: Int,
            onCancellation: (@Sendable () -> Void)?,
            onSuspension: (@Sendable (SuspensionEvent) -> Void)?
        ) {
            self.capacity = capacity
            self.onCancellation = onCancellation
            self.onSuspension = onSuspension
        }

        func send(_ value: Data) async throws {
            try Task.checkCancellation()
            if let terminal { throw terminal.error }
            if let receiver = receivers.first {
                receivers.removeFirst()
                receiver.resume(returning: value)
                return
            }
            if values.count < capacity {
                values.append(value)
                return
            }
            try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    if let terminal {
                        continuation.resume(throwing: terminal.error)
                    } else if let receiver = receivers.first {
                        receivers.removeFirst()
                        receiver.resume(returning: value)
                        continuation.resume(returning: ())
                    } else if values.count < capacity {
                        values.append(value)
                        continuation.resume(returning: ())
                    } else {
                        let sequence = nextSenderSequence
                        nextSenderSequence += 1
                        senders.append(PendingSender(value: value, continuation: continuation))
                        onSuspension?(.sender(sequence: sequence))
                    }
                }
            }, onCancel: { Task { await self.cancelProducer() } })
            try Task.checkCancellation()
        }

        func next() async throws -> Data? {
            if !values.isEmpty {
                let value = values.removeFirst()
                resumeSenderIfCapacityAvailable()
                return value
            }
            if let terminal {
                if case .finished = terminal { return nil }
                throw terminal.error
            }
            return try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { continuation in
                    if !values.isEmpty {
                        let value = values.removeFirst()
                        resumeSenderIfCapacityAvailable()
                        continuation.resume(returning: value)
                    } else if let terminal {
                        if case .finished = terminal { continuation.resume(returning: nil) }
                        else { continuation.resume(throwing: terminal.error) }
                    } else {
                        receivers.append(continuation)
                        onSuspension?(.receiver)
                    }
                }
            }, onCancel: { Task { await self.cancelConsumer() } })
        }

        func finish() {
            guard terminal == nil else { return }
            terminal = .finished
            resumeAllSenders(with: .failure(CancellationError()))
            resumeAllReceivers(with: .success(nil))
        }

        func fail(_ error: Error) {
            guard terminal == nil else { return }
            terminal = .failed(error)
            values.removeAll()
            resumeAllSenders(with: .failure(error))
            resumeAllReceivers(with: .failure(error))
        }

        func cancelProducer() {
            guard terminal == nil else { return }
            fail(CancellationError())
        }

        func cancelConsumer() {
            guard terminal == nil else { return }
            fail(CancellationError())
            onCancellation?()
        }

        private func resumeSenderIfCapacityAvailable() {
            while values.count < capacity, !senders.isEmpty {
                let pending = senders.removeFirst()
                values.append(pending.value)
                pending.continuation.resume(returning: ())
            }
        }

        private func resumeAllSenders(with result: Result<Void, Error>) {
            let pending = senders
            senders.removeAll()
            for sender in pending { sender.continuation.resume(with: result) }
        }

        private func resumeAllReceivers(with result: Result<Data?, Error>) {
            let pending = receivers
            receivers.removeAll()
            for receiver in pending { receiver.resume(with: result) }
        }

        private enum Terminal {
            case finished
            case failed(Error)

            var error: Error {
                switch self {
                case .finished: return CancellationError()
                case .failed(let error): return error
                }
            }
        }
    }
}
