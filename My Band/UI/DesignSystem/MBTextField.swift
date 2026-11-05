import SwiftUI

// MARK: - MBTextField
//
// Port of components/forms/TextField.jsx + base.css (.mb-field).
// Supports a leading SF Symbol, mono input, an optional secure/reveal toggle,
// an error state and a hint line.

struct MBTextField: View {

    let label: String
    @Binding var text: String
    var icon: String? = nil          // SF Symbol, leading
    var placeholder: String = ""
    var mono: Bool = false
    var secure: Bool = false         // renders an eye reveal toggle
    var hint: String? = nil
    var errorText: String? = nil
    var autocapitalization: Bool = false

    @State private var reveal = false
    @FocusState private var focused: Bool

    private var hasError: Bool { errorText != nil }
    private var showSecure: Bool { secure && !reveal }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(.mbSubheadEmph)
                .foregroundStyle(MB.textSecondary)

            HStack(spacing: MB.Space.x2 + 2) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 20))
                        .foregroundStyle(MB.textTertiary)
                        .frame(width: 20)
                }

                Group {
                    if showSecure {
                        SecureField("", text: $text, prompt: placeholderText)
                    } else {
                        TextField("", text: $text, prompt: placeholderText)
                    }
                }
                .focused($focused)
                .font(mono ? .mbMono : .mbBody)
                .tracking(mono ? 0.06 * 14 : 0)
                .foregroundStyle(MB.textPrimary)
                .textInputAutocapitalization(autocapitalization ? .sentences : .never)
                .autocorrectionDisabled(true)
                .tint(MB.accent)

                if secure {
                    Button { reveal.toggle() } label: {
                        Image(systemName: reveal ? "eye.slash" : "eye")
                            .font(.system(size: 18))
                            .foregroundStyle(MB.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(reveal ? "Hide" : "Show")
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(MB.surfaceControl)
            .overlay(
                RoundedRectangle(cornerRadius: MB.Radius.md, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: focused || hasError ? 1.5 : 1)
            )
            .mbCornerRadius(MB.Radius.md)

            if let errorText {
                Text(errorText).font(.mbFootnote).foregroundStyle(MB.danger)
            } else if let hint {
                Text(hint).font(.mbFootnote).foregroundStyle(MB.textTertiary)
            }
        }
        .animation(.easeOut(duration: MB.Motion.durFast), value: focused)
    }

    private var placeholderText: Text {
        Text(placeholder).foregroundColor(MB.textTertiary)
    }

    private var borderColor: Color {
        if hasError { return MB.danger }
        if focused { return MB.accent }
        return MB.hairlineStrong
    }
}
