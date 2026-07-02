import SwiftUI

struct ShortcutVisualLabel: View {
    let shortcut: GlobalShortcut
    var fontSize: CGFloat = 11
    var foregroundColor: Color = .white.opacity(0.92)
    var keyBackground: Color = Color.black.opacity(0.26)
    var keyBorder: Color = Color.white.opacity(0.08)
    var keyMinWidth: CGFloat = 24
    var keyHorizontalPadding: CGFloat = 10
    var keyVerticalPadding: CGFloat = 7
    var keyCornerRadius: CGFloat = 12
    var compactSingleCharacterKeys = true

    var body: some View {
        HStack(spacing: 6) {
            ForEach(shortcut.displayParts, id: \.self) { part in
                Text(part)
                    .font(.system(size: fontSize, weight: .bold, design: .rounded))
                    .foregroundColor(foregroundColor)
                    .frame(minWidth: minimumWidth(for: part))
                    .padding(.horizontal, keyHorizontalPadding)
                    .padding(.vertical, keyVerticalPadding)
                    .background(
                        RoundedRectangle(cornerRadius: keyCornerRadius, style: .continuous)
                            .fill(keyBackground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: keyCornerRadius, style: .continuous)
                            .strokeBorder(keyBorder, lineWidth: 1)
                    )
            }
        }
    }

    private func minimumWidth(for part: String) -> CGFloat? {
        guard compactSingleCharacterKeys, part.count == 1 else {
            return nil
        }

        // `keyMinWidth` is intended to describe the final rendered key width.
        // Subtract the horizontal padding here so single-character keys do not
        // get widened twice by both the frame and the outer padding.
        return max(fontSize, keyMinWidth - (keyHorizontalPadding * 2))
    }
}

struct GlobalShortcutHintStrip: View {
    let actions: [GlobalShortcutAction]
    var title: String? = nil

    @ObservedObject private var settings = AppSettings.shared

    private var visibleActions: [(GlobalShortcutAction, GlobalShortcut)] {
        actions.compactMap { action in
            guard let shortcut = settings.shortcut(for: action) else { return nil }
            return (action, shortcut)
        }
    }

    var body: some View {
        if !visibleActions.isEmpty {
            HStack(alignment: .center, spacing: 12) {
                if let title {
                    Text(appLocalized: title)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(TerminalColors.green.opacity(0.9))
                }

                ForEach(visibleActions, id: \.0.id) { action, shortcut in
                    HStack(spacing: 8) {
                        Text(appLocalized: action.shortTitle)
                            .font(.system(size: 10, weight: .semibold))

                        ShortcutVisualLabel(shortcut: shortcut)
                    }
                    .foregroundColor(TerminalColors.green.opacity(0.96))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous)
                            .fill(TerminalColors.green.opacity(0.13))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(TerminalColors.green.opacity(0.34), lineWidth: 1)
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct GlobalShortcutFooterNote: View {
    let actions: [GlobalShortcutAction]
    var title: String = "快捷键提示"

    @ObservedObject private var settings = AppSettings.shared

    private var visibleActions: [(GlobalShortcutAction, GlobalShortcut)] {
        actions.compactMap { action in
            guard let shortcut = settings.shortcut(for: action) else { return nil }
            return (action, shortcut)
        }
    }

    var body: some View {
        if !visibleActions.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 8) {
                    Text(appLocalized: title)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.24))

                    ForEach(visibleActions, id: \.0.id) { action, shortcut in
                        HStack(spacing: 6) {
                            Text(appLocalized: action.shortTitle)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.white.opacity(0.32))

                            ShortcutVisualLabel(
                                shortcut: shortcut,
                                fontSize: 10,
                                foregroundColor: .white.opacity(0.34),
                                keyBackground: Color.white.opacity(0.025),
                                keyBorder: .clear,
                                keyHorizontalPadding: 7,
                                keyVerticalPadding: 4,
                                keyCornerRadius: 8
                            )
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
