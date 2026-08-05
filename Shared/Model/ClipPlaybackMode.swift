import Foundation

enum ClipPlaybackMode: String, Codable, CaseIterable, Sendable {
    case manual
    case shuffled

    var title: String {
        switch self {
        case .manual: "One clip"
        case .shuffled: "Shuffle after every clip"
        }
    }
}
