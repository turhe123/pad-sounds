import SwiftUI

/// How a pad reacts to presses and releases.
enum PlayMode: String, Codable, CaseIterable, Identifiable {
    case once, hold, toggle
    var id: String { rawValue }
    var title: String {
        switch self {
        case .once: return "Play Once"
        case .hold: return "Hold to Play"
        case .toggle: return "Toggle"
        }
    }
}

/// The fixed palette of pad colours, stored by name so the JSON stays readable.
enum PadColor: String, Codable, CaseIterable, Identifiable {
    case red, orange, yellow, green, mint, teal, blue, indigo, purple, pink, gray
    var id: String { rawValue }
    var color: Color {
        switch self {
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .mint: return .mint
        case .teal: return .teal
        case .blue: return .blue
        case .indigo: return .indigo
        case .purple: return .purple
        case .pink: return .pink
        case .gray: return .gray
        }
    }
}

/// A single pad definition as persisted in `board.json`. `fileName` refers to a copy in Application Support.
struct Pad: Codable, Identifiable, Equatable {
    var id = UUID()
    var label: String
    var color: PadColor
    var fileName: String?
    var volume: Double = 1
    var loops = false
    var mode: PlayMode = .once
    var key: String?

    static let defaultKeys = Array("1234qwerasdfzxcv").map(String.init)

    /// Builds the default empty 4×4 board with a rainbow of colours and a keyboard-shaped key layout.
    static func defaultBoard() -> [Pad] {
        let colors = PadColor.allCases
        return (0..<16).map { i in
            Pad(label: "Pad \(i + 1)", color: colors[i % (colors.count - 1)], key: defaultKeys[i])
        }
    }
}
