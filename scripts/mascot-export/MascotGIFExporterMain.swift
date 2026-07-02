import AppKit
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

private struct ExportTarget {
    let outputName: String
    let kind: MascotKind
}

@MainActor
@main
struct MascotGIFExporterMain {
    static func main() throws {
        let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
        AppSettingsStore.shared.idleAutoRoutePromptsToTerminalActive = options.idleProtectionActive
        try options.prepareOutputDirectory()

        let targets = try options.exportTargets(availableThemes: MascotThemeScanner.shared.themes)
        let statuses = try options.exportStatuses()

        for target in targets {
            for status in statuses {
                let outputURL = options.outputURL(for: target.outputName, status: status, includeStatusSuffix: statuses.count > 1)
                try exportGIF(
                    kind: target.kind,
                    status: status,
                    size: options.size,
                    fps: options.fps(for: status),
                    duration: options.duration(for: status),
                    outputURL: outputURL
                )
                print("wrote \(outputURL.path)")
            }
        }
    }

    private static func exportGIF(
        kind: MascotKind,
        status: MascotStatus,
        size: Int,
        fps: Int,
        duration: TimeInterval,
        outputURL: URL
    ) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.gif.identifier as CFString,
            frameCount(duration: duration, fps: fps),
            nil
        ) else {
            throw ExportError.failedToCreateDestination(outputURL.path)
        }

        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: 0,
            ],
        ] as CFDictionary)

        let delay = 1.0 / Double(fps)

        for frameIndex in 0..<frameCount(duration: duration, fps: fps) {
            let time = Double(frameIndex) * delay
            guard let image = renderFrame(kind: kind, status: status, size: size, time: time) else {
                throw ExportError.failedToRenderFrame(kind.rawValue, status.rawValue, frameIndex)
            }

            CGImageDestinationAddImage(destination, image, [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: delay,
                    kCGImagePropertyGIFUnclampedDelayTime: delay,
                ],
            ] as CFDictionary)
        }

        guard CGImageDestinationFinalize(destination) else {
            throw ExportError.failedToFinalize(outputURL.path)
        }
    }

    private static func renderFrame(
        kind: MascotKind,
        status: MascotStatus,
        size: Int,
        time: TimeInterval
    ) -> CGImage? {
        let content = MascotView(
            kind: kind,
            status: status,
            size: CGFloat(size),
            animationTime: time
        )
        .frame(width: CGFloat(size), height: CGFloat(size))
        .background(Color.clear)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        renderer.proposedSize = .init(width: CGFloat(size), height: CGFloat(size))
        renderer.isOpaque = false
        return renderer.cgImage
    }

    private static func frameCount(duration: TimeInterval, fps: Int) -> Int {
        max(1, Int((duration * Double(fps)).rounded(.toNearestOrEven)))
    }
}

private struct Options {
    let outputDirectory: URL
    let size: Int
    let requestedKinds: [String]
    let requestedStatus: String
    let overrideFPS: Int?
    let overrideDuration: TimeInterval?
    let idleProtectionActive: Bool

    init(arguments: [String]) throws {
        var outputDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("docs/images/mascots", isDirectory: true)
        var size = 96
        var requestedKinds: [String] = []
        var requestedStatus = "working"
        var overrideFPS: Int?
        var overrideDuration: TimeInterval?
        var idleProtectionActive = false

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--output-dir":
                index += 1
                outputDirectory = URL(fileURLWithPath: try Self.value(after: argument, at: index, in: arguments), isDirectory: true)
            case "--size":
                index += 1
                size = try Self.intValue(after: argument, at: index, in: arguments)
            case "--kind":
                index += 1
                requestedKinds = try Self.value(after: argument, at: index, in: arguments)
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                    .filter { !$0.isEmpty }
            case "--status":
                index += 1
                requestedStatus = try Self.value(after: argument, at: index, in: arguments).lowercased()
            case "--fps":
                index += 1
                overrideFPS = try Self.intValue(after: argument, at: index, in: arguments)
            case "--duration":
                index += 1
                overrideDuration = try Self.doubleValue(after: argument, at: index, in: arguments)
            case "--idle-protection":
                idleProtectionActive = true
            case "--help", "-h":
                throw ExportError.helpText
            default:
                throw ExportError.unknownArgument(argument)
            }
            index += 1
        }

        guard size > 0 else {
            throw ExportError.invalidValue("--size", "\(size)")
        }

        self.outputDirectory = outputDirectory
        self.size = size
        self.requestedKinds = requestedKinds
        self.requestedStatus = requestedStatus
        self.overrideFPS = overrideFPS
        self.overrideDuration = overrideDuration
        self.idleProtectionActive = idleProtectionActive
    }

    func prepareOutputDirectory() throws {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    }

    func exportTargets(availableThemes: [MascotTheme]) throws -> [ExportTarget] {
        // 内置 claude 主题包作为第一个导出目标
        let builtinTarget = ExportTarget(outputName: "claude", kind: .claude)
        // 扫描到的其他主题包（排除 claude 避免重复）
        let themeTargets: [ExportTarget] = availableThemes
            .filter { $0.id != "claude" }
            .map { theme in
                ExportTarget(outputName: theme.id, kind: MascotKind(themeID: theme.id))
            }
        let allTargets = [builtinTarget] + themeTargets

        guard !requestedKinds.isEmpty else {
            return allTargets
        }

        let resolved = try requestedKinds.map { requested -> ExportTarget in
            guard let target = allTargets.first(where: { $0.outputName == requested }) else {
                throw ExportError.invalidValue("--kind", requested)
            }
            return target
        }

        return resolved
    }

    func exportStatuses() throws -> [MascotStatus] {
        if requestedStatus == "all" {
            return MascotStatus.allCases
        }
        if let status = MascotStatus(rawValue: requestedStatus) {
            return [status]
        }
        throw ExportError.invalidValue("--status", requestedStatus)
    }

    func fps(for status: MascotStatus) -> Int {
        if let overrideFPS {
            return overrideFPS
        }

        switch status {
        case .idle, .jumping, .waving, .dragging:
            return 16
        case .runRight, .runLeft, .running:
            return 24
        case .waiting, .review, .failed:
            return 18
        }
    }

    func duration(for status: MascotStatus) -> TimeInterval {
        if let overrideDuration {
            return overrideDuration
        }

        switch status {
        case .idle, .jumping, .waving, .dragging:
            return 3.0
        case .runRight, .runLeft, .running:
            return 1.8
        case .waiting, .review, .failed:
            return 1.5
        }
    }

    func outputURL(for baseName: String, status: MascotStatus, includeStatusSuffix: Bool) -> URL {
        let fileName = includeStatusSuffix ? "\(baseName)-\(status.rawValue).gif" : "\(baseName).gif"
        return outputDirectory.appendingPathComponent(fileName)
    }

    private static func value(after flag: String, at index: Int, in arguments: [String]) throws -> String {
        guard arguments.indices.contains(index) else {
            throw ExportError.missingValue(flag)
        }
        return arguments[index]
    }

    private static func intValue(after flag: String, at index: Int, in arguments: [String]) throws -> Int {
        let raw = try value(after: flag, at: index, in: arguments)
        guard let value = Int(raw) else {
            throw ExportError.invalidValue(flag, raw)
        }
        return value
    }

    private static func doubleValue(after flag: String, at index: Int, in arguments: [String]) throws -> TimeInterval {
        let raw = try value(after: flag, at: index, in: arguments)
        guard let value = Double(raw) else {
            throw ExportError.invalidValue(flag, raw)
        }
        return value
    }
}

private enum ExportError: Error, CustomStringConvertible {
    case missingValue(String)
    case invalidValue(String, String)
    case unknownArgument(String)
    case failedToCreateDestination(String)
    case failedToRenderFrame(String, String, Int)
    case failedToFinalize(String)
    case helpText

    var description: String {
        switch self {
        case .missingValue(let flag):
            return "missing value for \(flag)"
        case .invalidValue(let flag, let value):
            return "invalid value for \(flag): \(value)"
        case .unknownArgument(let argument):
            return "unknown argument: \(argument)"
        case .failedToCreateDestination(let path):
            return "failed to create GIF destination at \(path)"
        case .failedToRenderFrame(let kind, let status, let frame):
            return "failed to render \(kind) \(status) frame \(frame)"
        case .failedToFinalize(let path):
            return "failed to finalize GIF at \(path)"
        case .helpText:
            return """
                Usage: ./scripts/render-mascots.sh [options]

                Options:
                  --output-dir PATH      Output directory (default: docs/images/mascots)
                  --size N               Square frame size in pixels (default: 96)
                  --kind NAME[,NAME...]  Export only selected mascot names
                  --status idle|working|warning|all
                  --fps N                Override frames per second
                  --duration SECONDS     Override animation duration
                  --idle-protection      Show the idle route-to-terminal protection overlay
                """
        }
    }
}
