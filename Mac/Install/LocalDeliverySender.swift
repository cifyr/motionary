import Foundation
import Network
import os

enum LocalDeliveryError: Error, CustomStringConvertible {
    case noReceivers
    case notFound(name: String, found: [String])
    case connectionFailed(String)
    case noReceipt

    var description: String {
        switch self {
        case .noReceivers:
            "no phone is listening; open Motionary on the phone and leave it on screen"
        case .notFound(let name, let found):
            "no phone called \(name) is listening"
                + (found.isEmpty ? "" : "; found \(found.joined(separator: ", "))")
        case .connectionFailed(let reason):
            "could not reach the phone: \(reason)"
        case .noReceipt:
            "the phone took the design but said nothing back, so it is not known whether it drew"
        }
    }
}

/// Sends a design package to a phone on the same network.
///
/// The counterpart to `LocalDeliveryReceiver`: the phone advertises, this
/// browses for it and connects. Nothing here needs an account, an entitlement
/// or Apple's infrastructure, which is the whole reason it exists ahead of the
/// iCloud version - the seam is the same either way, because what crosses is a
/// package file.
enum LocalDeliverySender {
    private static let logger = Logger(subsystem: "com.caden.MotionaryStudio", category: "LocalDelivery")

    struct Receiver: Sendable, Identifiable {
        let name: String
        let endpoint: NWEndpoint
        var id: String { name }
    }

    /// Phones currently listening.
    ///
    /// Browsing is not instant and has no "that is all of them" - so this waits
    /// a fixed moment and reports what turned up, rather than returning the
    /// first answer and calling it the only phone in the house.
    static func browse(for seconds: TimeInterval = 3) async -> [Receiver] {
        let browser = NWBrowser(
            for: .bonjour(type: DeliveryWire.serviceType, domain: nil),
            using: {
                let parameters = NWParameters()
                parameters.includePeerToPeer = true
                return parameters
            }()
        )
        let found = Box<[String: NWEndpoint]>([:])

        browser.browseResultsChangedHandler = { results, _ in
            for result in results {
                if case .service(let name, _, _, _) = result.endpoint {
                    found.mutate { $0[name] = result.endpoint }
                }
            }
        }
        browser.start(queue: .global())
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        browser.cancel()

        return found.value
            .map { Receiver(name: $0.key, endpoint: $0.value) }
            .sorted { $0.name < $1.name }
    }

    static func send(_ package: Data, to receiver: Receiver) async throws -> DeliveryWire.Receipt {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let connection = NWConnection(to: receiver.endpoint, using: parameters)

        return try await withCheckedThrowingContinuation { continuation in
            let resumed = Box(false)
            // A closure rather than a local function so it can cross into the
            // `Network` callbacks, which are `@Sendable`.
            //
            // Every path here can fire more than once - a failed state update
            // can follow a completed send - and resuming a continuation twice
            // is a crash rather than a bug report.
            let settle: @Sendable (Result<DeliveryWire.Receipt, Error>) -> Void = { result in
                var alreadyDone = false
                resumed.mutate { alreadyDone = $0; $0 = true }
                guard !alreadyDone else { return }
                connection.cancel()
                continuation.resume(with: result)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: DeliveryWire.frame(package), completion: .contentProcessed { error in
                        if let error {
                            settle(.failure(LocalDeliveryError.connectionFailed("\(error)")))
                            return
                        }
                        // The receipt is the point of waiting: the phone reports
                        // whether the design unpacked, which is not the same
                        // question as whether the bytes arrived.
                        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                            data, _, _, error in
                            if let error {
                                settle(.failure(LocalDeliveryError.connectionFailed("\(error)")))
                            } else if let data, !data.isEmpty {
                                settle(.success(DeliveryWire.Receipt.decode(data)))
                            } else {
                                settle(.failure(LocalDeliveryError.noReceipt))
                            }
                        }
                    })
                case .failed(let error):
                    settle(.failure(LocalDeliveryError.connectionFailed("\(error)")))
                case .cancelled:
                    settle(.failure(LocalDeliveryError.connectionFailed("the connection was cancelled")))
                default:
                    break
                }
            }
            connection.start(queue: .global())
        }
    }

    /// Browses, picks, sends. `name` nil takes the only phone listening, and
    /// refuses rather than guessing when there is more than one.
    static func deliver(_ package: Data, to name: String?) async throws -> (receiver: Receiver, receipt: DeliveryWire.Receipt) {
        let receivers = await browse()
        guard !receivers.isEmpty else { throw LocalDeliveryError.noReceivers }

        let chosen: Receiver
        if let name {
            guard let match = receivers.first(where: { $0.name == name }) else {
                throw LocalDeliveryError.notFound(name: name, found: receivers.map(\.name))
            }
            chosen = match
        } else {
            chosen = receivers[0]
        }
        logger.info("sending \(package.count) bytes to \(chosen.name, privacy: .public)")
        return (chosen, try await send(package, to: chosen))
    }
}

/// A reference box for state shared with a `Network` callback queue.
private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func mutate(_ change: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        change(&stored)
    }
}
