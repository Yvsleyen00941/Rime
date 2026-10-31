import Foundation

/// What happens to the menu bar and Dock while a PDF is frozen in place.
enum BarsWhileReading: String, CaseIterable, Identifiable {
    case hide, show

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hide: "Hide while reading"
        case .show: "Keep visible"
        }
    }

    var explanation: String {
        switch self {
        case .hide: "While you read, the menu bar and Dock slide out of sight. Move the pointer to the top or bottom edge of the screen to bring them back."
        case .show: "The menu bar and Dock stay on the ice. Pages keep clear of them and fade softly where they meet."
        }
    }
}

enum Preferences {
    static let barsKey = "barsWhileReading"

    static var bars: BarsWhileReading {
        BarsWhileReading(rawValue: UserDefaults.standard.string(forKey: barsKey) ?? "") ?? .hide
    }
}
