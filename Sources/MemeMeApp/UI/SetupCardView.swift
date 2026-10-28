import MemeMeCore
import SwiftUI

/// First-run "You're set" card, shown after the first pick in place of the top row.
struct SetupCardView: View {
    @ObservedObject var model: AppModel

    @State private var openAtLogin = true
    @State private var findStarted = false

    init(model: AppModel) {
        _model = ObservedObject(wrappedValue: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                HStack(spacing: 8) {
                    ZStack {
                        Circle().fill(Theme.green)
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(Theme.onGreen)
                    }
                    .frame(width: 22, height: 22)
                    .accessibilityHidden(true)
                    Text("Copied. Paste it with ⌘V.")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(Theme.text)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                shortcutLine
                Button {
                    model.dismissSetupCard()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Theme.mutedText)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                .help("Close")
            }

            HStack(alignment: .center, spacing: 12) {
                Toggle(isOn: $openAtLogin) {
                    Text("Open at login")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.text)
                }
                .toggleStyle(.checkbox)
                .tint(Theme.accent)
                Spacer(minLength: 8)
                VStack(alignment: .center, spacing: 4) {
                    Button(findTitle) {
                        findStarted = true
                        model.findMyMemes()
                    }
                    .buttonStyle(PanelFilledButtonStyle(fontSize: 13, cornerRadius: 8))
                    .disabled(isFinding)
                    .opacity(isFinding ? 0.7 : 1)
                    Text("Downloads, Desktop, Screenshots · stays on this Mac")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.mutedText)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.surface)
        )
        .onAppear {
            openAtLogin = model.store.settings.openAtLogin
        }
        .onChange(of: openAtLogin) { _, wanted in
            guard wanted != model.store.settings.openAtLogin else { return }
            model.toggleOpenAtLogin()
            let actual = model.store.settings.openAtLogin
            if actual != wanted {
                openAtLogin = actual
            }
        }
    }

    /// "Next time, in any chat: ⌃ ⌘ M", or the warning when the hot key couldn't be registered.
    @ViewBuilder
    private var shortcutLine: some View {
        if model.hotKeyAvailable {
            HStack(spacing: 6) {
                Text("Next time, in any chat:")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.softText)
                    .lineLimit(1)
                KeycapRow(fontSize: 12, filled: true)
            }
        } else {
            Text("⌃⌘M is taken by another app.")
                .font(.system(size: 13))
                .foregroundColor(Theme.warning)
                .lineLimit(1)
        }
    }

    private var isFinding: Bool {
        if case .indexing = model.footer {
            return true
        }
        return findStarted
    }

    private var findTitle: String {
        if case .indexing(let count) = model.footer {
            return "Finding your memes… \(count.formatted())"
        }
        return findStarted ? "Finding your memes…" : "Find memes already on this Mac"
    }
}
