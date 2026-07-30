import Foundation
import os

/// The measured edge profile, as data rather than as source.
///
/// It lives in `Resources/edge-profile.json` because recalibrating it is a
/// measurement, not a code change: `Tools/edge-calibrate.py` reads a Home Screen
/// screenshot and writes this file back, which is the whole loop. Three rounds of
/// copying numbers into Swift by hand is what it replaces.
///
/// The shipped numbers are still compiled in, as `EdgeCompensation.shipped`. A
/// file that is missing, truncated or hand-edited into nonsense must not be able
/// to ship a design with no correction at all - that failure looks exactly like
/// the bug the correction exists to fix.
struct EdgeProfile: Equatable, Sendable {
    /// Per channel, by distance in pixels inward from the widget's own edge.
    var top: [(r: Double, g: Double, b: Double)]
    var bottom: [(r: Double, g: Double, b: Double)]
    /// A scale on the whole profile, so a recalibration can be dialled back
    /// without rewriting it. 1.0 means apply what was measured.
    var strength: Double
    var measuredAt: String?

    static func == (lhs: EdgeProfile, rhs: EdgeProfile) -> Bool {
        lhs.strength == rhs.strength
            && lhs.measuredAt == rhs.measuredAt
            && lhs.top.elementsEqual(rhs.top, by: ==)
            && lhs.bottom.elementsEqual(rhs.bottom, by: ==)
    }
}

enum EdgeProfileError: Error, CustomStringConvertible {
    case resourceMissing(name: String)
    case deviceMissing(id: String, available: [String])
    case edgeEmpty(edge: String, deviceID: String)
    case malformedRow(edge: String, index: Int, count: Int)
    case negativeValue(edge: String, index: Int)
    case strengthOutOfRange(Double)

    var description: String {
        switch self {
        case .resourceMissing(let name):
            "edge profile: \(name).json is not in the bundle"
        case .deviceMissing(let id, let available):
            "edge profile: no entry for device \(id); the file has \(available.sorted().joined(separator: ", "))"
        case .edgeEmpty(let edge, let deviceID):
            "edge profile: \(deviceID) has no \(edge) rows; an empty edge would silently apply no correction"
        case .malformedRow(let edge, let index, let count):
            "edge profile: \(edge) row \(index) has \(count) values, wanted 3 (r, g, b)"
        case .negativeValue(let edge, let index):
            "edge profile: \(edge) row \(index) is negative; the system adds light, so a correction can only subtract it"
        case .strengthOutOfRange(let value):
            "edge profile: strength \(value) is outside 0...1"
        }
    }
}

/// Reads the profile out of the bundle, per device.
enum EdgeProfileStore {
    private static let logger = Logger(subsystem: "com.caden.Motionary", category: "EdgeProfile")
    static let resourceName = "edge-profile"

    /// The profile for one device, or the fallback with the reason logged.
    ///
    /// Never throws to the caller. A build that stopped because a calibration
    /// file was malformed would be worse than one that used the last known-good
    /// numbers and said so, and the numbers it falls back to are the ones that
    /// were shipping before the file existed.
    static func load(deviceID: String, fallback: EdgeProfile) -> EdgeProfile {
        do {
            let profile = try loadOrThrow(deviceID: deviceID)
            logger.info("""
            edge profile for \(deviceID, privacy: .public): \
            \(profile.top.count) top rows, \(profile.bottom.count) bottom, \
            strength \(profile.strength), measured \(profile.measuredAt ?? "unstated", privacy: .public)
            """)
            return profile
        } catch {
            logger.error("""
            \(String(describing: error), privacy: .public) - \
            using the compiled-in profile instead
            """)
            return fallback
        }
    }

    /// Separated out so a test can assert on the specific failure rather than on
    /// the fallback having been used, which looks the same from outside.
    static func loadOrThrow(deviceID: String, data: Data? = nil) throws -> EdgeProfile {
        let data = try data ?? {
            guard let url = PrebuiltDesign.resource(named: resourceName, extension: "json") else {
                throw EdgeProfileError.resourceMissing(name: resourceName)
            }
            return try Data(contentsOf: url)
        }()

        let file = try JSONDecoder().decode(File.self, from: data)
        guard let device = file.devices[deviceID] else {
            throw EdgeProfileError.deviceMissing(id: deviceID, available: Array(file.devices.keys))
        }
        let strength = device.strength ?? 1
        guard strength > 0, strength <= 1 else {
            throw EdgeProfileError.strengthOutOfRange(strength)
        }
        return EdgeProfile(
            top: try triples(device.top, edge: "top", deviceID: deviceID),
            bottom: try triples(device.bottom, edge: "bottom", deviceID: deviceID),
            strength: strength,
            measuredAt: device.measuredAt
        )
    }

    private static func triples(
        _ rows: [[Double]],
        edge: String,
        deviceID: String
    ) throws -> [(r: Double, g: Double, b: Double)] {
        guard !rows.isEmpty else { throw EdgeProfileError.edgeEmpty(edge: edge, deviceID: deviceID) }
        return try rows.enumerated().map { index, row in
            guard row.count == 3 else {
                throw EdgeProfileError.malformedRow(edge: edge, index: index, count: row.count)
            }
            guard row.allSatisfy({ $0 >= 0 }) else {
                throw EdgeProfileError.negativeValue(edge: edge, index: index)
            }
            return (r: row[0], g: row[1], b: row[2])
        }
    }

    /// Only the keys the pipeline needs; the file also carries prose about how it
    /// was measured, which is for whoever reads it next rather than for this.
    private struct File: Decodable {
        let devices: [String: Device]

        struct Device: Decodable {
            let top: [[Double]]
            let bottom: [[Double]]
            /// Optional, because a file written before these existed still has to
            /// decode - a missing key throws rather than taking a property's
            /// default, and a profile that fails to decode falls back silently.
            let strength: Double?
            let measuredAt: String?

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                top = try container.decode([[Double]].self, forKey: .top)
                bottom = try container.decode([[Double]].self, forKey: .bottom)
                strength = try container.decodeIfPresent(Double.self, forKey: .strength)
                measuredAt = try container.decodeIfPresent(String.self, forKey: .measuredAt)
            }

            enum CodingKeys: String, CodingKey {
                case top, bottom, strength, measuredAt
            }
        }
    }
}
