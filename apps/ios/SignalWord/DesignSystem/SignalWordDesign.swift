import SwiftUI

enum SignalWordColor {
    static let canvas = Color(red: 0.043, green: 0.051, blue: 0.086)       // Midnight canvas
    static let surface = Color(red: 0.078, green: 0.086, blue: 0.141)      // Indigo elevated surface
    static let secondarySurface = Color(red: 0.106, green: 0.114, blue: 0.180) // Secondary indigo surface
    static let primaryText = Color(red: 0.961, green: 0.969, blue: 0.980) // #F5F7FA
    static let secondaryText = Color(red: 0.663, green: 0.690, blue: 0.737) // #A9B0BC
    static let mutedText = Color(red: 0.600, green: 0.635, blue: 0.694)   // #99A2B1; readable supporting copy on dark surfaces
    static let link = Color(red: 0.769, green: 0.737, blue: 1.0) // #C4BCFF
    static let action = Color(red: 0.478, green: 0.435, blue: 0.941)      // #7A6FF0
    static let ready = Color(red: 0.180, green: 0.812, blue: 0.569)       // #2ECF91
    static let attention = Color(red: 0.949, green: 0.725, blue: 0.373)   // #F2B95F
    static let critical = Color(red: 1.000, green: 0.384, blue: 0.384)    // #FF6262
    static let separator = Color(red: 0.180, green: 0.200, blue: 0.231)
    static let track = Color(red: 0.157, green: 0.173, blue: 0.204)
    static let calm = Color(red: 0.08, green: 0.10, blue: 0.13)
}

/// Cosmetic accents never replace warning, delivery or safety-state colours.
struct SignalWordAccent {
    let link: Color
    let action: Color

    init(appearance: String = "standard") {
        switch appearance {
        case "ocean":
            link = Color(red: 0.52, green: 0.87, blue: 1)
            action = Color(red: 0.20, green: 0.63, blue: 0.88)
        case "lavender":
            link = Color(red: 0.88, green: 0.70, blue: 1)
            action = Color(red: 0.64, green: 0.36, blue: 0.86)
        default:
            link = SignalWordColor.link
            action = SignalWordColor.action
        }
    }
}

private struct SignalWordAccentKey: EnvironmentKey {
    static let defaultValue = SignalWordAccent()
}

extension EnvironmentValues {
    var signalWordAccent: SignalWordAccent {
        get { self[SignalWordAccentKey.self] }
        set { self[SignalWordAccentKey.self] = newValue }
    }
}

enum SignalWordSpacing {
    static let compact: CGFloat = 8
    static let control: CGFloat = 12
    static let standard: CGFloat = 16
    static let card: CGFloat = 18
    static let page: CGFloat = 20
    static let section: CGFloat = 24
}

enum SignalWordRadius {
    static let row: CGFloat = 15
    static let control: CGFloat = 17
    static let card: CGFloat = 21
    static let panel: CGFloat = 28
}

enum SignalWordMotion {
    static let pressDuration: Double = 0.16
}

struct SignalWordCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(SignalWordSpacing.card)
            .background(SignalWordColor.surface, in: RoundedRectangle(cornerRadius: SignalWordRadius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: SignalWordRadius.card, style: .continuous)
                    .stroke(SignalWordColor.separator.opacity(0.5), lineWidth: 0.7)
            }
    }
}

enum ReadinessState: Equatable {
    case ready, actionNeeded, optional

    var symbolName: String {
        switch self {
        case .ready: "checkmark.circle.fill"
        case .actionNeeded: "exclamationmark.circle.fill"
        case .optional: "minus.circle.fill"
        }
    }

    var label: String {
        switch self {
        case .ready: "Ready"
        case .actionNeeded: "Action needed"
        case .optional: "Optional"
        }
    }

    var color: Color {
        switch self {
        case .ready: SignalWordColor.ready
        case .actionNeeded: SignalWordColor.attention
        case .optional: SignalWordColor.secondaryText
        }
    }
}

/// Only decorative colour extends under system chrome; content keeps its safe area.
struct SignalWordBackground: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 0.067, green: 0.075, blue: 0.204), SignalWordColor.canvas], startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
    }
}
