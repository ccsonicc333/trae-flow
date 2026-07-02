//
//  NotchHeaderView.swift
//  TraeFlow
//
//  Header bar for the dynamic island
//

import Combine
import SwiftUI

enum NotchIndicatorTone: Equatable {
    case normal
    case claude
    case warning
    case intervention

    var emphasisColor: Color {
        switch self {
        case .normal:
            return TerminalColors.green
        case .claude:
            return Color(red: 0.98, green: 0.73, blue: 0.30)
        case .warning:
            return Color(red: 1.0, green: 0.66, blue: 0.18)
        case .intervention:
            return TerminalColors.prompt
        }
    }

}

// Removed: legacy NotchPetActivity / NotchPetIcon / NotchPetStyle / NotchPetPalette.
// Flow Island now uses the codex-compatible MascotView + MascotStatus system.
// NotchIndicatorTone is now only used for badge/indicator emphasis colors.

// Compact reminder icon used for manual-attention badges.
struct PermissionIndicatorIcon: View {
    let size: CGFloat
    let color: Color

    init(size: CGFloat = 14, color: Color = TerminalColors.prompt) {
        self.size = size
        self.color = color
    }

    var body: some View {
        Image(systemName: "bell.fill")
            .font(.system(size: size - 2, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
    }
}

// Pixel art "ready for input" indicator icon (checkmark/done shape)
struct ReadyForInputIndicatorIcon: View {
    let size: CGFloat
    let color: Color

    init(size: CGFloat = 14, color: Color = TerminalColors.green) {
        self.size = size
        self.color = color
    }

    // Checkmark shape pixel positions (at 30x30 scale)
    private let pixels: [(CGFloat, CGFloat)] = [
        (5, 15),                    // Start of checkmark
        (9, 19),                    // Down stroke
        (13, 23),                   // Bottom of checkmark
        (17, 19),                   // Up stroke begins
        (21, 15),                   // Up stroke
        (25, 11),                   // Up stroke
        (29, 7)                     // End of checkmark
    ]

    var body: some View {
        Canvas { context, canvasSize in
            let scale = size / 30.0
            let pixelSize: CGFloat = 4 * scale

            for (x, y) in pixels {
                let rect = CGRect(
                    x: x * scale - pixelSize / 2,
                    y: y * scale - pixelSize / 2,
                    width: pixelSize,
                    height: pixelSize
                )
                context.fill(Path(rect), with: .color(color))
            }
        }
        .frame(width: size, height: size)
    }
}

struct BellIndicatorIcon: View {
    let size: CGFloat
    let color: Color

    init(size: CGFloat = 14, color: Color = TerminalColors.prompt) {
        self.size = size
        self.color = color
    }

    var body: some View {
        Image(systemName: "bell.fill")
            .font(.system(size: size - 2, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
    }
}
