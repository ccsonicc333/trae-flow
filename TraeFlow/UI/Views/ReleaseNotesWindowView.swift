import AppKit
import SwiftUI

struct ReleaseNotesWindowView: View {
    let notes: UpdateReleaseNotes
    let onClose: () -> Void

    @Environment(\.locale) private var locale
    @State private var expandedSectionIDs: Set<String> = []
    @State private var celebrationStartedAt = Date()

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                appIcon
                versionBadge
                releaseNotesContent
            }
            .padding(.top, 18)
            .padding(.horizontal, 18)
            .padding(.bottom, 14)

            Divider()
                .overlay(Color.white.opacity(0.08))

            Button(action: onClose) {
                Text("好")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white.opacity(0.92))
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 16)
        }
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .overlay {
            EmojiBlastCelebrationOverlay(startedAt: celebrationStartedAt)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .allowsHitTesting(false)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if expandedSectionIDs.isEmpty {
                expandedSectionIDs = Set(displayedSections.map(\.id))
            }
            celebrationStartedAt = Date()
        }
    }

    private var appIcon: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: 60, height: 60)
            .shadow(color: .black.opacity(0.2), radius: 8, y: 5)
    }

    private var versionBadge: some View {
        HStack(spacing: 8) {
            Text(notes.currentVersion)
                .foregroundColor(.white.opacity(0.6))

            Image(systemName: "arrow.right")
                .foregroundColor(.white.opacity(0.35))

            Text(notes.targetVersion)
                .foregroundColor(.white.opacity(0.92))

            Text("🎉")
        }
        .font(.system(size: 14, weight: .semibold, design: .rounded))
        .padding(.horizontal, 16)
        .frame(height: 38)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var releaseNotesContent: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(displayedSections.isEmpty ? [fallbackSection] : displayedSections) { section in
                    ReleaseNotesSectionCard(
                        section: section,
                        isExpanded: expandedSectionIDs.contains(section.id),
                        toggle: { toggleSection(section.id) }
                    )
                }
            }
            .padding(.bottom, 2)
        }
        .frame(maxHeight: 464)
    }

    private var displayedSections: [UpdateReleaseNotesSection] {
        notes.sections(locale: locale)
    }

    private var fallbackSection: UpdateReleaseNotesSection {
        UpdateReleaseNotesSection(
            id: "fallback",
            title: AppLocalization.string("更新内容"),
            markdown: notes.localizedMarkdown(locale: locale)
        )
    }

    private var background: some View {
        LinearGradient(
            colors: [
                Color(red: 0.20, green: 0.21, blue: 0.24),
                Color(red: 0.15, green: 0.15, blue: 0.17)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.black.opacity(0.18))
        )
    }

    private func toggleSection(_ id: String) {
        if expandedSectionIDs.contains(id) {
            expandedSectionIDs.remove(id)
        } else {
            expandedSectionIDs.insert(id)
        }
    }
}

private struct ReleaseNotesSectionCard: View {
    let section: UpdateReleaseNotesSection
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 10) {
                    Image(systemName: section.iconSymbolName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.68))

                    Text(section.title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white.opacity(0.92))

                    Spacer()

                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.45))
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                    .overlay(Color.white.opacity(0.08))
                    .padding(.horizontal, 14)

                MarkdownContentView(
                    section.markdown,
                    color: .white.opacity(0.84),
                    fontSize: 12
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.18), value: isExpanded)
    }
}

private struct EmojiBlastCelebrationOverlay: View {
    let startedAt: Date

    private let duration: TimeInterval = 4.9
    private let particles: [WindowBlastParticle] = WindowBlastParticle.defaultField
    private let palette: [Color] = [.pink, .orange, .yellow, .mint, .cyan, .white]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 40.0)) { context in
            let elapsed = context.date.timeIntervalSince(startedAt)
            let opacity = globalOpacity(for: elapsed)

            if elapsed < duration && opacity > 0 {
                GeometryReader { proxy in
                    Canvas { canvas, size in
                        drawBackdropFlash(elapsed: elapsed, in: canvas, size: size, opacity: opacity)

                        for particle in particles {
                            draw(particle: particle, elapsed: elapsed, in: canvas, size: size, opacity: opacity)
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
                .transition(.opacity)
            }
        }
    }

    private func draw(
        particle: WindowBlastParticle,
        elapsed: TimeInterval,
        in canvas: GraphicsContext,
        size: CGSize,
        opacity: Double
    ) {
        let progress = particle.progress(at: elapsed)
        guard progress > 0, progress <= 1 else { return }

        let easedProgress = 1 - pow(1 - progress, 2.15)
        let position = particle.position(in: size, progress: easedProgress)
        let previousProgress = max(0, progress - 0.055)
        let previousEasedProgress = 1 - pow(1 - previousProgress, 2.15)
        let previousPosition = particle.position(in: size, progress: previousEasedProgress)
        let particleOpacity = particle.opacity(at: progress) * opacity
        guard particleOpacity > 0.01 else { return }

        let color = palette[particle.colorIndex % palette.count].opacity(particleOpacity)

        var trail = Path()
        trail.move(to: previousPosition)
        trail.addLine(to: position)

        var trailContext = canvas
        trailContext.opacity = particleOpacity * 0.72
        trailContext.stroke(
            trail,
            with: .color(color),
            style: StrokeStyle(lineWidth: particle.lineWidth, lineCap: .round)
        )

        let sparkRect = CGRect(
            x: position.x - particle.sparkSize / 2,
            y: position.y - particle.sparkSize / 2,
            width: particle.sparkSize,
            height: particle.sparkSize
        )
        canvas.fill(Path(ellipseIn: sparkRect), with: .color(color))

        if let emoji = particle.emoji {
            let resolvedEmoji = canvas.resolve(
                Text(emoji)
                    .font(.system(size: particle.emojiSize))
            )
            var emojiContext = canvas
            let emojiScale = particle.startScale + (particle.endScale - particle.startScale) * CGFloat(progress)
            emojiContext.opacity = particleOpacity
            emojiContext.translateBy(x: position.x, y: position.y)
            emojiContext.rotate(by: .degrees(particle.spin * progress))
            emojiContext.scaleBy(x: emojiScale, y: emojiScale)
            emojiContext.draw(resolvedEmoji, at: .zero, anchor: .center)
        }
    }

    private func drawBackdropFlash(
        elapsed: TimeInterval,
        in canvas: GraphicsContext,
        size: CGSize,
        opacity: Double
    ) {
        let flashProgress = min(max(elapsed / 1.1, 0), 1)
        let flashOpacity = (1 - flashProgress) * 0.22 * opacity
        guard flashOpacity > 0.01 else { return }

        let center = CGPoint(x: size.width * 0.5, y: size.height * 0.38)
        let flashRect = CGRect(
            x: center.x - size.width * 0.34,
            y: center.y - size.height * 0.18,
            width: size.width * 0.68,
            height: size.height * 0.36
        )

        var glow = canvas
        glow.opacity = flashOpacity
        glow.addFilter(.blur(radius: 18))
        glow.fill(Path(ellipseIn: flashRect), with: .color(.white.opacity(0.95)))
    }

    private func globalOpacity(for elapsed: TimeInterval) -> Double {
        if elapsed < 3.6 { return 1 }
        return max(0, 1 - (elapsed - 3.6) / 1.3)
    }
}

private struct WindowBlastParticle {
    let start: CGPoint
    let end: CGPoint
    let controlOffset: CGSize
    let delay: TimeInterval
    let duration: TimeInterval
    let sparkSize: CGFloat
    let lineWidth: CGFloat
    let emojiSize: CGFloat
    let emoji: String?
    let colorIndex: Int
    let spin: Double
    let startScale: CGFloat
    let endScale: CGFloat

    func progress(at elapsed: TimeInterval) -> Double {
        let local = elapsed - delay
        guard local >= 0 else { return 0 }
        return min(1, local / duration)
    }

    func opacity(at progress: Double) -> Double {
        if progress < 0.10 {
            return progress / 0.10
        }
        if progress < 0.44 {
            return 1
        }
        return max(0, 1 - ((progress - 0.44) / 0.56))
    }

    func position(in size: CGSize, progress: Double) -> CGPoint {
        let startPoint = CGPoint(x: size.width * start.x, y: size.height * start.y)
        let endPoint = CGPoint(x: size.width * end.x, y: size.height * end.y)
        let controlPoint = CGPoint(
            x: (startPoint.x + endPoint.x) / 2 + size.width * controlOffset.width,
            y: (startPoint.y + endPoint.y) / 2 + size.height * controlOffset.height
        )

        let t = CGFloat(progress)
        let inverse = 1 - t
        return CGPoint(
            x: inverse * inverse * startPoint.x + 2 * inverse * t * controlPoint.x + t * t * endPoint.x,
            y: inverse * inverse * startPoint.y + 2 * inverse * t * controlPoint.y + t * t * endPoint.y
        )
    }

    static let defaultField: [WindowBlastParticle] = {
        let emojis = ["🎉", "✨", "💥", "🎊", "🌟", "💫", "🪩", "⭐️"]
        let center = CGPoint(x: 0.5, y: 0.38)

        return (0..<96).map { index in
            let angle = (CGFloat(index) / 96.0) * (.pi * 2) + CGFloat((index % 7)) * 0.06
            let startRadiusX = 0.04 + CGFloat((index * 17) % 15) / 100
            let startRadiusY = 0.03 + CGFloat((index * 11) % 11) / 100
            let startX = center.x + cos(angle) * startRadiusX
            let startY = center.y + sin(angle) * startRadiusY

            let endRadiusX = 0.30 + CGFloat((index * 19) % 24) / 100
            let endRadiusY = 0.24 + CGFloat((index * 23) % 22) / 100
            let rawEndX = center.x + cos(angle) * endRadiusX
            let rawEndY = center.y + sin(angle) * endRadiusY
            let endX = min(max(rawEndX, 0.03), 0.97)
            let endY = min(max(rawEndY, 0.05), 0.95)

            let controlX = CGFloat(cos(angle) * (0.03 + CGFloat((index * 7) % 8) / 100))
            let controlY = CGFloat(sin(angle) * (0.04 + CGFloat((index * 13) % 10) / 100))
            let delay = Double((index * 7) % 18) * 0.035
            let duration = 1.9 + Double((index * 5) % 8) * 0.14
            let sparkSize = CGFloat(2.0 + Double((index * 3) % 4) * 1.15)
            let lineWidth = CGFloat(1.0 + Double((index * 5) % 3) * 0.55)
            let emojiSize = CGFloat(12 + ((index * 7) % 5) * 2)
            let emoji = index % 4 == 0 ? nil : emojis[index % emojis.count]
            let colorIndex = index % 6
            let spin = Double(((index * 3) % 9) - 4) * 18
            let startScale = CGFloat(0.76 + Double((index * 2) % 3) * 0.08)
            let endScale = CGFloat(1.04 + Double((index * 5) % 4) * 0.08)

            return WindowBlastParticle(
                start: CGPoint(x: startX, y: startY),
                end: CGPoint(x: endX, y: endY),
                controlOffset: CGSize(width: controlX, height: controlY),
                delay: delay,
                duration: duration,
                sparkSize: sparkSize,
                lineWidth: lineWidth,
                emojiSize: emojiSize,
                emoji: emoji,
                colorIndex: colorIndex,
                spin: spin,
                startScale: startScale,
                endScale: endScale
            )
        }
    }()
}
