import SwiftUI
import UIKit

struct PageHeading: View {
    @Environment(\.signalWordAccent) private var accent
    let eyebrow: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(eyebrow)
                .font(.caption.weight(.bold))
                .tracking(1.3)
                .foregroundStyle(accent.link)
            Text(title)
                .font(.title.weight(.semibold))
                .tracking(-0.55)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(SignalWordColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct PrivacyLine: View {
    @Environment(\.signalWordAccent) private var accent
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(accent.link)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(SignalWordColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

struct LabeledTextField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var contentType: UITextContentType?
    var keyboard: UIKeyboardType = .default

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .tracking(0.8)
                .foregroundStyle(SignalWordColor.secondaryText)
            TextField(placeholder, text: $text)
                .font(.body)
                .textContentType(contentType)
                .textInputAutocapitalization(keyboard == .emailAddress ? .never : .words)
                .keyboardType(keyboard)
                .autocorrectionDisabled(keyboard == .emailAddress)
                .submitLabel(.next)
        }
        .padding(.vertical, 12)
    }
}

struct FieldDivider: View {
    var body: some View { Divider().overlay(SignalWordColor.separator) }
}

struct ReadinessLine: View {
    let title: String
    let detail: String
    let state: ReadinessState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: state.symbolName)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(state.color)
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(SignalWordColor.primaryText)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(SignalWordColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Text(state.shortLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(state.color)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(state.color.opacity(0.12), in: Capsule())
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(SignalWordColor.mutedText)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 62)
        .accessibilityElement(children: .combine)
    }
}

struct SettingsRow: View {
    let symbol: String
    let title: String
    let detail: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(SignalWordColor.primaryText)
                    Text(detail).font(.caption).foregroundStyle(SignalWordColor.secondaryText)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(SignalWordColor.mutedText)
            }
            .frame(minHeight: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct SignalOrb: View {
    enum State {
        case ready, active, attention

        var color: Color {
            switch self {
            case .ready: SignalWordColor.action
            case .active: SignalWordColor.ready
            case .attention: SignalWordColor.attention
            }
        }
        var label: String {
            switch self {
            case .ready: "READY"
            case .active: "ACTIVE"
            case .attention: "SETUP"
            }
        }
    }

    let state: State
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(state.color.opacity(0.09))
                .frame(width: size, height: size)
                .blur(radius: 13)
                .scaleEffect(0.94)
            Circle()
                .stroke(state.color.opacity(0.22), lineWidth: 1)
                .frame(width: size * 0.94, height: size * 0.94)
            Circle()
                .stroke(state.color.opacity(0.65), lineWidth: 1.5)
                .frame(width: size * 0.79, height: size * 0.79)
            Circle()
                .fill(LinearGradient(colors: [SignalWordColor.surface, state.color.opacity(0.16)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size * 0.68, height: size * 0.68)
                .overlay(Circle().stroke(state.color.opacity(0.35), lineWidth: 1))
            VStack(spacing: 3) {
                Image(systemName: "waveform")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(state.color)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct PrimaryButton: View {
    @Environment(\.signalWordAccent) private var accent
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    let symbol: String
    var isLoading = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if isLoading { ProgressView().tint(.white) }
                Text(title).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                if !isLoading { Image(systemName: symbol).font(.subheadline.weight(.semibold)) }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 50)
            .foregroundStyle(SignalWordColor.canvas)
            .background(LinearGradient(colors: [accent.link, accent.action], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: SignalWordRadius.control, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: SignalWordRadius.control, style: .continuous))
            .opacity(isEnabled ? 1 : 0.48)
        }
        .buttonStyle(PressScaleButtonStyle())
        .accessibilityHint(isLoading ? "In progress" : "")
    }
}

struct SecondaryButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, minHeight: 48)
                .foregroundStyle(SignalWordColor.primaryText)
                .background(SignalWordColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressScaleButtonStyle())
    }
}

struct PressScaleButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: SignalWordMotion.pressDuration), value: configuration.isPressed)
    }
}

struct InlineMessage: View {
    enum Kind { case attention }
    let message: String
    let kind: Kind

    init(_ message: String, kind: Kind) { self.message = message; self.kind = kind }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill").foregroundStyle(SignalWordColor.attention)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(SignalWordColor.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(SignalWordColor.attention.opacity(0.11), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

extension ReadinessState {
    var shortLabel: String {
        switch self {
        case .ready: "Ready"
        case .actionNeeded: "To do"
        case .optional: "Optional"
        }
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
