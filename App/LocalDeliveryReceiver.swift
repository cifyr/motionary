import Foundation
import Network
import os

/// Listens for a design sent from a Mac on the same network.
///
/// The other ways in need a cable or a person: `devicectl` copying into the
/// app's container, or somebody AirDropping a file and tapping through a share
/// sheet. This is the one that feels like the product - press send on the Mac,
/// the Home Screen changes - and it needs no account, no entitlement and no
/// Apple infrastructure, which is why it exists before the iCloud version does.
///
/// The phone advertises and the Mac connects, rather than the other way round:
/// a phone cannot be relied on to keep a socket open in the background, so the
/// side that must be awake is the side the person is looking at.
@MainActor
final class LocalDeliveryReceiver: ObservableObject {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "LocalDelivery")

    /// What the last transfer did, for the app to show. Deliberately plain
    /// text: this is the only place a failed delivery can be seen at all, and
    /// the widget cannot report it.
    @Published private(set) var status = "Not listening" {
        didSet {
            // Into the shared log as well as onto the screen. A transfer that
            // fails on the phone is otherwise invisible from the Mac that sent
            // it - the sender sees a closed socket and nothing about why - and
            // this log is the one the report mirror carries off the device.
            guard status != oldValue else { return }
            WidgetRenderLog.append("net  \(status)")
        }
    }

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    func start() {
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            // Peer-to-peer, so the two ends find each other over AWDL when
            // they are not on the same Wi-Fi network.
            parameters.includePeerToPeer = true
            let listener = try NWListener(using: parameters)
            listener.service = NWListener.Service(
                name: UIDeviceName.current,
                type: DeliveryWire.serviceType
            )
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.status = "Listening as \(UIDeviceName.current)"
                    case .failed(let error):
                        self?.status = "Could not listen: \(error)"
                        Self.logger.error("listener failed: \(String(describing: error), privacy: .public)")
                        self?.stop()
                    default:
                        break
                    }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
            Self.logger.info("advertising \(DeliveryWire.serviceType, privacy: .public)")
        } catch {
            status = "Could not listen: \(error)"
            Self.logger.error("could not start listening: \(String(describing: error), privacy: .public)")
        }
    }

    func stop() {
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        listener?.cancel()
        listener = nil
        status = "Not listening"
    }

    private func accept(_ connection: NWConnection) {
        connections[ObjectIdentifier(connection)] = connection
        status = "Receiving..."
        connection.start(queue: .main)
        receive(on: connection, buffer: Data())
    }

    /// Accumulates until the frame says it is whole.
    ///
    /// A socket delivers whatever it happens to have, so every read has to be
    /// able to say "not yet". Completion of the stream is not the signal - a
    /// dropped connection ends it too, and that is exactly the case the length
    /// prefix exists to tell apart.
    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) {
            [weak self] chunk, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                var buffer = buffer
                if let chunk { buffer.append(chunk) }

                if let error {
                    self.finish(connection, ok: false, message: "the connection failed: \(error)")
                    return
                }
                do {
                    if let payload = try DeliveryWire.payload(in: buffer) {
                        self.deliver(payload, on: connection)
                        return
                    }
                } catch {
                    self.finish(connection, ok: false, message: "\(error)")
                    return
                }
                if isComplete {
                    self.finish(
                        connection,
                        ok: false,
                        message: "the sender stopped after \(buffer.count) bytes, before the design was whole"
                    )
                    return
                }
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func deliver(_ payload: Data, on connection: NWConnection) {
        // Through a file rather than straight into the store, so a delivery
        // over the network takes exactly the same path as one from Files or
        // AirDrop and cannot drift from it.
        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent("incoming.\(DesignPackage.fileExtension)")
        do {
            try payload.write(to: staged, options: .atomic)
        } catch {
            finish(connection, ok: false, message: "could not stage the delivery: \(error)")
            return
        }
        defer { try? FileManager.default.removeItem(at: staged) }

        let outcome = DesignDelivery.receive(at: staged)
        switch outcome {
        case .delivered:
            finish(connection, ok: true, message: outcome.message)
        case .failed, .nothingToDo:
            finish(connection, ok: false, message: outcome.message)
        }
    }

    private func finish(_ connection: NWConnection, ok: Bool, message: String) {
        status = message
        if ok {
            Self.logger.info("\(message, privacy: .public)")
        } else {
            Self.logger.error("\(message, privacy: .public)")
        }
        let receipt = DeliveryWire.Receipt(ok: ok, message: message).encoded
        connection.send(content: receipt, completion: .contentProcessed { _ in
            connection.cancel()
        })
        connections.removeValue(forKey: ObjectIdentifier(connection))
    }
}

/// The name the Mac will show in its list. `UIDevice` rather than the host
/// name: "Caden's iPhone" is what somebody is looking for, and the host name on
/// a phone is a string nobody chose.
private enum UIDeviceName {
    @MainActor
    static var current: String {
        #if canImport(UIKit)
        UIDevice.current.name
        #else
        ProcessInfo.processInfo.hostName
        #endif
    }
}

#if canImport(UIKit)
import UIKit
#endif
